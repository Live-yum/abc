import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';

import 'engine.dart';
import 'world_circuit_backend.dart';

typedef _OneC = Int32 Function(Uint32);
typedef _OneD = int Function(int);

/// Instantiated and used exclusively inside the existing owning isolate.
/// Scratch/output use temporary random-access files, keeping the circuit's
/// bounded working set independent of world size. Files are never user paths.
class NativeWorldCircuitBindings {
  final DynamicLibrary library;
  final Map<int, _Session> _sessions = {};
  final Map<String, Directory> _outputs = {};
  int _outputSequence = 0;
  bool _cancelRequested = false;
  Map<String, Object?>? _progress;
  static const memoryBudget = 192 * 1024 * 1024;
  NativeWorldCircuitBindings(this.library);

  void _check(int status) {
    if (status < 0) {
      throw EngineException('World circuit engine status $status', status);
    }
  }

  void _checkWorld(int status) {
    if (status != 0) {
      throw EngineException('World decoder status $status', status);
    }
  }

  _OneD _one(String name) =>
      library.lookupFunction<_OneC, _OneD>('abc_world_circuit_$name');
  Object? dispatch(String method, List<dynamic> args) {
    if (method == 'worldCircuitProgress') return _progress;
    if (method == 'worldCircuitCancelOperation') {
      _cancelRequested = true;
      return null;
    }
    if (method == 'worldCircuitReleaseSource') {
      final directory = _outputs.remove(args[0] as String);
      if (directory != null && directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
      return null;
    }
    if (method == 'worldCircuitOpenSource') {
      _cancelRequested = false;
      return _openSource(
        Map<String, Object?>.from(args[0] as Map),
        args[1] == null ? null : Map<String, Object?>.from(args[1] as Map),
      );
    }
    if (method == 'worldCircuitOpen') {
      return _open(args[0] as Uint8List, args[1] as Uint8List?);
    }
    final id = args[0] as int;
    final session = _sessions[id];
    if (session == null) {
      throw const EngineException('Circuit session is closed');
    }
    if (method == 'worldCircuitClose') {
      _dispose(id, session);
      return null;
    }
    if (method != 'worldCircuitCommand') {
      throw const EngineException('Unknown circuit command');
    }
    final words = (args[1] as List).cast<int>(),
        records = (args[2] as List).cast<int>();
    validateWorldCircuitCommand(words, records);
    _cancelRequested = false;
    if (words[1] == 7 || words[1] == 8) {
      final infoPointer = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'abc_engine_build_info',
          )();
      if (infoPointer == nullptr) {
        throw const EngineException('Missing circuit build identity');
      }
      final info = jsonDecode(infoPointer.toDartString()) as Map;
      if (words[1] == 7 &&
          List.generate(
            records.length ~/ 4,
            (i) => records[i * 4 + 3],
          ).any((anchor) => anchor != 0) &&
          info['circuitWorldFragmentSupports'] != 1) {
        throw const EngineException(
          'Circuit placement supports are unavailable',
        );
      }
      if (words[1] == 8 &&
          words[12] == 1 &&
          info['circuitWorldFragmentObjects'] != 1) {
        throw const EngineException(
          'Circuit object companions are unavailable',
        );
      }
    }
    final p = calloc<Uint32>(16),
        r = calloc<Uint32>(records.isEmpty ? 1 : records.length);
    try {
      p.asTypedList(16).setAll(0, words);
      r.asTypedList(records.length).setAll(0, records);
      if (words[1] == 6) {
        for (final id in [3, 5]) {
          (session.files[id] ??= File(
            session.paths[id]!,
          ).openSync(mode: FileMode.write)).truncateSync(0);
        }
      }
      if (words[1] == 8) session.files[6]!.truncateSync(0);
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Pointer<Uint32>, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>, Pointer<Uint32>)
        >('abc_world_circuit_command')(id, p, r),
      );
      return session.streamed
          ? _pumpAsync(id, session, command: words)
          : _pump(id, session, command: words);
    } catch (_) {
      _one('cancel')(id);
      if (words[1] == 8) session.files[6]!.truncateSync(0);
      rethrow;
    } finally {
      calloc.free(p);
      calloc.free(r);
    }
  }

  Map<String, Object?> _open(Uint8List bytes, Uint8List? twld) {
    if (_sessions.isNotEmpty) {
      throw const EngineException('Close the existing world circuit first');
    }
    if (bytes.isEmpty ||
        bytes.length > 64 * 1024 * 1024 ||
        (twld?.length ?? 0) > 16 * 1024 * 1024) {
      throw const EngineException('World circuit input exceeds host budget');
    }
    final out = calloc<Uint32>(), input = calloc<Uint8>(bytes.length);
    _Session? session;
    int world = 0, id = 0;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      _checkWorld(
        library.lookupFunction<
          Int32 Function(Pointer<Uint8>, Uint32, Pointer<Uint32>),
          int Function(Pointer<Uint8>, int, Pointer<Uint32>)
        >('abc_world_open')(input, bytes.length, out),
      );
      world = out.value;
      session = _Session(world, twld);
      _check(
        library.lookupFunction<
          Int32 Function(
            Uint32,
            Uint32,
            Uint32,
            Uint32,
            Uint32,
            Pointer<Uint32>,
          ),
          int Function(int, int, int, int, int, Pointer<Uint32>)
        >('abc_world_circuit_begin')(
          world,
          2,
          twld == null ? 0 : 4,
          twld?.length ?? 0,
          memoryBudget,
          out,
        ),
      );
      id = out.value;
      _sessions[id] = session;
      return _pump(id, session);
    } catch (_) {
      if (id != 0) {
        _one('close')(id);
        _sessions.remove(id);
      }
      session?.close();
      if (world != 0) {
        library.lookupFunction<_OneC, _OneD>('abc_world_close')(world);
      }
      rethrow;
    } finally {
      calloc.free(out);
      calloc.free(input);
    }
  }

  void _checkCancelled() {
    if (_cancelRequested) {
      throw const EngineException('World circuit operation cancelled');
    }
  }

  Future<String> _hashRange(
    String stage,
    int size,
    Uint8List Function(int, int) read,
  ) async {
    final digest = _DigestCollector();
    // The collector and sink never retain source chunks.
    final sink = sha256.startChunkedConversion(digest);
    try {
      for (var offset = 0; offset < size;) {
        _checkCancelled();
        final length = (size - offset).clamp(0, 1024 * 1024),
            bytes = read(offset, length);
        if (bytes.length != length) {
          throw const EngineException('Short hash source read');
        }
        sink.add(bytes);
        offset += length;
        _progress = {
          'stage': stage,
          'phase': 0,
          'completed': offset,
          'total': size,
        };
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      sink.close();
    }
    return digest.value.toString();
  }

  Future<Map<String, Object?>> _openSource(
    Map<String, Object?> source,
    Map<String, Object?>? sidecar,
  ) async {
    if (_sessions.isNotEmpty) {
      throw const EngineException('Close the existing world circuit first');
    }
    final worldSource = WorldCircuitSource.fromMap(source);
    worldSource.toFileMap();
    final twldSource = sidecar == null
        ? null
        : WorldCircuitSource.fromMap(sidecar);
    if (twldSource != null &&
        (twldSource.length < 1 || twldSource.length > 16 * 1024 * 1024)) {
      throw const EngineException('TWLD source exceeds host budget');
    }
    final session = _Session(0, null, streamed: true);
    final out = calloc<Uint32>(),
        event = calloc<Uint32>(12),
        data = calloc<Pointer<Uint8>>();
    int task = 0, id = 0;
    try {
      session.attach(1, worldSource);
      if (twldSource != null) session.attach(4, twldSource);
      session.sourceSha256 = await _hashRange(
        'hash',
        worldSource.length,
        (offset, length) => session.read(1, offset, length),
      );
      if (twldSource != null) {
        session.twldSourceSha256 = await _hashRange(
          'hash-companion',
          twldSource.length,
          (offset, length) => session.read(4, offset, length),
        );
      }
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Uint32>)
        >('abc_world_stream_open_begin')(1, worldSource.length, out),
      );
      task = out.value;
      final slice = Stopwatch()..start();
      while (true) {
        _checkCancelled();
        _check(
          library.lookupFunction<
            Int32 Function(
              Uint32,
              Uint32,
              Pointer<Uint32>,
              Pointer<Pointer<Uint8>>,
            ),
            int Function(int, int, Pointer<Uint32>, Pointer<Pointer<Uint8>>)
          >('abc_world_stream_step')(task, 4096, event, data),
        );
        final e = event.asTypedList(12);
        if (e[0] != 1 || e[5] != 0) {
          throw const EngineException('Invalid stream event ABI');
        }
        _progress = {
          'stage': 'decode',
          'phase': 0,
          'completed': e[8],
          'total': e[9],
        };
        if (e[1] == 4) break;
        if (e[1] == 1) {
          if (e[4] > 1024 * 1024) {
            throw const EngineException('Stream input window exceeded');
          }
          final bytes = session.read(e[2], e[3], e[4]), p = calloc<Uint8>(e[4]);
          try {
            p.asTypedList(bytes.length).setAll(0, bytes);
            _check(
              library.lookupFunction<
                Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32),
                int Function(int, int, int, Pointer<Uint8>, int)
              >('abc_world_stream_supply')(task, e[2], e[3], p, bytes.length),
            );
          } finally {
            calloc.free(p);
          }
        } else if (e[1] != 0) {
          throw const EngineException('Unexpected stream-open event');
        }
        if (slice.elapsedMilliseconds >= 8) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Uint32>)
        >('abc_world_stream_adopt')(task, 1, out),
      );
      session.world = out.value;
      _check(
        library.lookupFunction<_OneC, _OneD>('abc_world_stream_close')(task),
      );
      task = 0;
      _check(
        library.lookupFunction<
          Int32 Function(
            Uint32,
            Uint32,
            Uint32,
            Uint32,
            Uint32,
            Pointer<Uint32>,
          ),
          int Function(int, int, int, int, int, Pointer<Uint32>)
        >('abc_world_circuit_begin')(
          session.world,
          2,
          twldSource == null ? 0 : 4,
          twldSource?.length ?? 0,
          memoryBudget,
          out,
        ),
      );
      id = out.value;
      _sessions[id] = session;
      return await _pumpAsync(id, session);
    } catch (_) {
      if (id != 0) {
        _one('close')(id);
        _sessions.remove(id);
      }
      if (session.world != 0) {
        library.lookupFunction<_OneC, _OneD>('abc_world_close')(session.world);
      }
      session.close();
      rethrow;
    } finally {
      if (task != 0) {
        library.lookupFunction<_OneC, _OneD>('abc_world_stream_cancel')(task);
        library.lookupFunction<_OneC, _OneD>('abc_world_stream_close')(task);
      }
      calloc.free(out);
      calloc.free(event);
      calloc.free(data);
    }
  }

  Future<Map<String, Object?>> _leaseOutput(
    _Session session,
    int id,
    String name,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'abc-circuit-output-',
    );
    try {
      session.files[id]!.flushSync();
      session.files.remove(id)!.closeSync();
      // Transfer an owned staged file on the same temporary filesystem instead
      // of allocating another whole-world disk copy for the output lease.
      final output = File(session.paths[id]!)
          .renameSync('${directory.path}/$name');
      session.files[id] = File(session.paths[id]!)
          .openSync(mode: FileMode.write);
      final input = output.openSync(mode: FileMode.read);
      late final String fingerprint;
      try {
        fingerprint = await _hashRange('hash-output', output.lengthSync(), (
          offset,
          length,
        ) {
          input.setPositionSync(offset);
          return input.readSync(length);
        });
      } finally {
        input.closeSync();
      }
      final token = 'native-${++_outputSequence}';
      _outputs[token] = directory;
      return {
        'path': output.path,
        'length': output.lengthSync(),
        'name': name,
        'token': token,
        'sha256': fingerprint,
      };
    } catch (_) {
      directory.deleteSync(recursive: true);
      rethrow;
    }
  }

  Future<Map<String, Object?>> _leaseOutputs(_Session session) async {
    Map<String, Object?>? world, twld;
    try {
      world = await _leaseOutput(session, 3, 'world.wld');
      if (session.hasTwld) twld = await _leaseOutput(session, 5, 'world.twld');
      final result = <String, Object?>{'worldSource': world};
      if (twld != null) result['twldSource'] = twld;
      return result;
    } catch (_) {
      for (final output in [world, twld]) {
        final directory = _outputs.remove(output?['token']);
        if (directory != null && directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      }
      rethrow;
    }
  }

  Map<String, Object?> _pump(int id, _Session session, {List<int>? command}) {
    final commandKind = command?[1] ?? 0, save = commandKind == 6;
    final fragments = commandKind == 7 || commandKind == 8;
    final withObjects = commandKind == 8 && command![12] == 1;
    final recordSize = fragments ? 32 : 16;
    final recordLimit = fragments ? command![8] : 8 * 1024 * 1024 ~/ 16;
    var resultKind = 0, resultCount = 0, reserved = 0, objectBytes = 0;
    final event = calloc<Uint32>(12),
        data = calloc<Pointer<Uint8>>(),
        stats = calloc<Uint32>(24);
    final records = BytesBuilder(copy: false);
    try {
      while (true) {
        _check(
          library.lookupFunction<
            Int32 Function(
              Uint32,
              Uint32,
              Pointer<Uint32>,
              Pointer<Pointer<Uint8>>,
            ),
            int Function(int, int, Pointer<Uint32>, Pointer<Pointer<Uint8>>)
          >('abc_world_circuit_step')(id, 4096, event, data),
        );
        final e = event.asTypedList(12),
            kind = e[1],
            source = e[2],
            offset = e[3],
            length = e[4];
        if (e[0] != 1 || e[5] != 0) {
          throw const EngineException('Invalid circuit event ABI');
        }
        if (kind == 4) {
          resultKind = e[9];
          resultCount = e[10];
          reserved = e[11];
          if (resultKind != commandKind ||
              (commandKind == 8 && resultCount * 32 != records.length) ||
              (commandKind == 7 && resultCount < records.length ~/ 32)) {
            throw const EngineException('Incomplete circuit result');
          }
          break;
        }
        if (kind == 0) continue;
        if (length > 1024 * 1024 || offset + length > 0xffffffff) {
          throw const EngineException('Invalid circuit I/O range');
        }
        if (kind == 1) {
          final file = session.files[source];
          if (file == null || offset + length > file.lengthSync()) {
            throw const EngineException('Circuit source unavailable');
          }
          file.setPositionSync(offset);
          final bytes = file.readSync(length);
          if (bytes.length != length) {
            throw const EngineException('Short circuit read');
          }
          final p = calloc<Uint8>(length);
          try {
            p.asTypedList(length).setAll(0, bytes);
            _check(
              library.lookupFunction<
                Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32),
                int Function(int, int, int, Pointer<Uint8>, int)
              >('abc_world_circuit_supply')(id, source, offset, p, length),
            );
          } finally {
            calloc.free(p);
          }
        } else if (kind == 2 || kind == 3) {
          if (data.value == nullptr && length > 0) {
            throw const EngineException('Missing circuit output');
          }
          final bytes = Uint8List.fromList(data.value.asTypedList(length));
          if (kind == 2) {
            if (source == 6) {
              if (!withObjects ||
                  offset != objectBytes ||
                  length > 65536 ||
                  offset + length > command[4]) {
                throw const EngineException('Invalid circuit companion output');
              }
              objectBytes += length;
            } else if (source != 2 && !(save && (source == 3 || source == 5))) {
              throw const EngineException('Unexpected circuit output source');
            }
            final file = session.files[source];
            if (file == null || source == 4) {
              throw const EngineException('Invalid circuit output source');
            }
            file.setPositionSync(offset);
            file.writeFromSync(bytes);
          } else {
            if (e[9] != commandKind ||
                length != e[10] * recordSize ||
                records.length + length > recordLimit * recordSize) {
              throw const EngineException('Circuit result exceeds host budget');
            }
            records.add(bytes);
          }
          _check(_one('ack')(id));
        } else {
          throw const EngineException('Unknown circuit event');
        }
      }
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)
        >('abc_world_circuit_stats')(id, stats),
      );
      if (save &&
          (session.files[3]!.lengthSync() != resultCount ||
              (session.hasTwld &&
                  session.files[5]!.lengthSync() != reserved))) {
        throw const EngineException('Incomplete circuit saved files');
      }
      Uint8List read(int source) {
        final f = session.files[source]!;
        f.setPositionSync(0);
        return f.readSync(f.lengthSync());
      }

      Uint8List? objects;
      if (withObjects) {
        objects = read(6);
        validateWorldCircuitObjects(
          objects,
          maxBytes: command[4],
          maxObjects: command[5],
        );
      }
      return {
        'session': id,
        'resultKind': resultKind,
        'resultCount': resultCount,
        'reserved': reserved,
        'objects': objects,
        'stats': stats.asTypedList(24).toList(),
        'records': records.takeBytes(),
        if (save) 'world': read(3),
        if (save && session.hasTwld) 'twld': read(5),
      };
    } finally {
      calloc.free(event);
      calloc.free(data);
      calloc.free(stats);
    }
  }

  Future<Map<String, Object?>> _pumpAsync(
    int id,
    _Session session, {
    List<int>? command,
  }) async {
    final commandKind = command?[1] ?? 0, save = commandKind == 6;
    final fragments = commandKind == 7 || commandKind == 8;
    final withObjects = commandKind == 8 && command![12] == 1;
    final recordSize = fragments ? 32 : 16;
    final recordLimit = fragments ? command![8] : 8 * 1024 * 1024 ~/ 16;
    var resultKind = 0, resultCount = 0, reserved = 0, objectBytes = 0;
    final event = calloc<Uint32>(12),
        data = calloc<Pointer<Uint8>>(),
        stats = calloc<Uint32>(24);
    final records = BytesBuilder(copy: false);
    try {
      final slice = Stopwatch()..start();
      while (true) {
        _checkCancelled();
        if (slice.elapsedMilliseconds >= 8) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
          _checkCancelled();
        }
        _check(
          library.lookupFunction<
            Int32 Function(
              Uint32,
              Uint32,
              Pointer<Uint32>,
              Pointer<Pointer<Uint8>>,
            ),
            int Function(int, int, Pointer<Uint32>, Pointer<Pointer<Uint8>>)
          >('abc_world_circuit_step')(id, 4096, event, data),
        );
        final e = event.asTypedList(12),
            kind = e[1],
            source = e[2],
            offset = e[3],
            length = e[4];
        _progress = {
          'stage': commandKind == 0 ? 'compile' : 'run',
          'phase': e[6],
          'completed': e[7],
          'total': e[8],
          'diagnostics': {
            'nativeBudgetBytes': memoryBudget,
            'sourceReadBytes': session.readBytes,
            'sourceReadRequests': session.readRequests,
            'maxReadBytes': session.maxReadBytes,
          },
        };
        if (e[0] != 1 || e[5] != 0) {
          throw const EngineException('Invalid circuit event ABI');
        }
        if (kind == 4) {
          resultKind = e[9];
          resultCount = e[10];
          reserved = e[11];
          if (resultKind != commandKind ||
              (commandKind == 8 && resultCount * 32 != records.length) ||
              (commandKind == 7 && resultCount < records.length ~/ 32)) {
            throw const EngineException('Incomplete circuit result');
          }
          break;
        }
        if (kind == 0) continue;
        if (length > 1024 * 1024 || offset + length > 0xffffffff) {
          throw const EngineException('Invalid circuit I/O range');
        }
        if (kind == 1) {
          final file = session.files[source];
          if (file == null || offset + length > file.lengthSync()) {
            throw const EngineException('Circuit source unavailable');
          }
          final bytes = session.read(source, offset, length);
          if (bytes.length != length) {
            throw const EngineException('Short circuit read');
          }
          final p = calloc<Uint8>(length);
          try {
            p.asTypedList(length).setAll(0, bytes);
            _check(
              library.lookupFunction<
                Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32),
                int Function(int, int, int, Pointer<Uint8>, int)
              >('abc_world_circuit_supply')(id, source, offset, p, length),
            );
          } finally {
            calloc.free(p);
          }
        } else if (kind == 2 || kind == 3) {
          if (data.value == nullptr && length > 0) {
            throw const EngineException('Missing circuit output');
          }
          final bytes = Uint8List.fromList(data.value.asTypedList(length));
          if (kind == 2) {
            if (source == 6) {
              if (!withObjects ||
                  offset != objectBytes ||
                  length > 65536 ||
                  offset + length > command[4]) {
                throw const EngineException('Invalid circuit companion output');
              }
              objectBytes += length;
            } else if (source != 2 && !(save && (source == 3 || source == 5))) {
              throw const EngineException('Unexpected circuit output source');
            }
            final file = session.files[source];
            if (file == null || source == 4) {
              throw const EngineException('Invalid circuit output source');
            }
            file.setPositionSync(offset);
            file.writeFromSync(bytes);
          } else {
            if (e[9] != commandKind ||
                length != e[10] * recordSize ||
                records.length + length > recordLimit * recordSize) {
              throw const EngineException('Circuit result exceeds host budget');
            }
            records.add(bytes);
          }
          _check(_one('ack')(id));
        } else {
          throw const EngineException('Unknown circuit event');
        }
      }
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)
        >('abc_world_circuit_stats')(id, stats),
      );
      if (save &&
          (session.files[3]!.lengthSync() != resultCount ||
              (session.hasTwld &&
                  session.files[5]!.lengthSync() != reserved))) {
        throw const EngineException('Incomplete circuit saved files');
      }
      Uint8List read(int source) {
        final f = session.files[source]!;
        f.setPositionSync(0);
        return f.readSync(f.lengthSync());
      }

      Uint8List? objects;
      if (withObjects) {
        objects = read(6);
        validateWorldCircuitObjects(
          objects,
          maxBytes: command[4],
          maxObjects: command[5],
        );
      }
      return {
        'session': id,
        'resultKind': resultKind,
        'resultCount': resultCount,
        'reserved': reserved,
        'objects': objects,
        'stats': stats.asTypedList(24).toList(),
        'records': records.takeBytes(),
        'sourceSha256': session.sourceSha256,
        'twldSourceSha256': session.twldSourceSha256,
        if (save) ...await _leaseOutputs(session),
      };
    } catch (_) {
      _one('cancel')(id);
      if (commandKind == 8) session.files[6]!.truncateSync(0);
      rethrow;
    } finally {
      calloc.free(event);
      calloc.free(data);
      calloc.free(stats);
    }
  }

  void _dispose(int id, _Session session) {
    _check(_one('close')(id));
    _sessions.remove(id);
    try {
      _checkWorld(
        library.lookupFunction<_OneC, _OneD>('abc_world_close')(session.world),
      );
    } finally {
      session.close();
    }
  }
}

class _Session {
  int world;
  bool hasTwld;
  final bool streamed;
  String? sourceSha256, twldSourceSha256;
  int readBytes = 0, readRequests = 0, maxReadBytes = 0;
  final Directory directory = Directory.systemTemp.createTempSync(
    'abc-circuit-',
  );
  final Map<int, RandomAccessFile> files = {};
  final Map<int, String> paths = {};
  final Map<int, FileStat> originals = {};
  _Session(this.world, Uint8List? twld, {this.streamed = false})
    : hasTwld = twld != null {
    try {
      for (final id in [2, 3, 4, 5, 6]) {
        paths[id] = '${directory.path}/$id';
        files[id] = File(paths[id]!).openSync(mode: FileMode.write);
      }
      if (twld != null) files[4]!.writeFromSync(twld);
    } catch (_) {
      close();
      rethrow;
    }
  }
  void attach(int id, WorldCircuitSource source) {
    final file = File(source.path!), stat = file.statSync();
    if (stat.type != FileSystemEntityType.file || stat.size != source.length) {
      throw const EngineException(
        'World source changed or is not a readable file',
      );
    }
    final handle = file.openSync(mode: FileMode.read);
    files.remove(id)?.closeSync();
    files[id] = handle;
    paths[id] = source.path!;
    originals[id] = stat;
    if (id == 4) hasTwld = true;
  }

  Uint8List read(int id, int offset, int length) {
    final file = files[id];
    if (file == null ||
        offset < 0 ||
        length < 0 ||
        length > 1024 * 1024 ||
        offset + length > file.lengthSync()) {
      throw const EngineException('Invalid ranged circuit read');
    }
    final original = originals[id];
    if (original != null) {
      final now = File(paths[id]!).statSync();
      if (now.size != original.size ||
          now.modified != original.modified ||
          now.type != original.type) {
        throw const EngineException(
          'The original circuit source changed while open',
        );
      }
    }
    file.setPositionSync(offset);
    final result = file.readSync(length);
    if (result.length != length) {
      throw const EngineException('Short ranged circuit read');
    }
    readBytes += length;
    readRequests++;
    if (length > maxReadBytes) maxReadBytes = length;
    return result;
  }

  void close() {
    for (final f in files.values) {
      f.closeSync();
    }
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
