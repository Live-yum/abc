import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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
        session.files[3]!.truncateSync(0);
        session.files[5]!.truncateSync(0);
      }
      if (words[1] == 8) session.files[6]!.truncateSync(0);
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Pointer<Uint32>, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>, Pointer<Uint32>)
        >('abc_world_circuit_command')(id, p, r),
      );
      return _pump(id, session, command: words);
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
          128 * 1024 * 1024,
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
  final int world;
  final bool hasTwld;
  final Directory directory = Directory.systemTemp.createTempSync(
    'abc-circuit-',
  );
  final Map<int, RandomAccessFile> files = {};
  _Session(this.world, Uint8List? twld) : hasTwld = twld != null {
    try {
      for (final id in [2, 3, 4, 5, 6]) {
        files[id] = File('${directory.path}/$id')
            .openSync(mode: FileMode.write);
      }
      if (twld != null) files[4]!.writeFromSync(twld);
    } catch (_) {
      close();
      rethrow;
    }
  }
  void close() {
    for (final f in files.values) {
      f.closeSync();
    }
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
