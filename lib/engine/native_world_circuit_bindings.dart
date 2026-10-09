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

class _SourceSha256Api {
  final int Function(Pointer<Uint32>) create;
  final int Function(int, Pointer<Uint8>, int) update;
  final int Function(int, Pointer<Uint8>) finish;
  final _OneD destroy;

  _SourceSha256Api(DynamicLibrary library)
    : create = library
          .lookupFunction<
            Int32 Function(Pointer<Uint32>),
            int Function(Pointer<Uint32>)
          >('abc_sha256_create'),
      update = library
          .lookupFunction<
            Int32 Function(Uint32, Pointer<Uint8>, Uint32),
            int Function(int, Pointer<Uint8>, int)
          >('abc_sha256_update'),
      finish = library
          .lookupFunction<
            Int32 Function(Uint32, Pointer<Uint8>),
            int Function(int, Pointer<Uint8>)
          >('abc_sha256_final'),
      destroy = library.lookupFunction<_OneC, _OneD>('abc_sha256_destroy');

  static _SourceSha256Api? load(DynamicLibrary library) {
    const names = ['create', 'update', 'final', 'destroy'];
    final available = names
        .where((name) => library.providesSymbol('abc_sha256_$name'))
        .length;
    if (available == 0) return null;
    if (available != names.length) {
      throw const EngineException('Incomplete streaming SHA-256 API');
    }
    return _SourceSha256Api(library);
  }
}

/// Instantiated and used exclusively inside the existing owning isolate.
/// Scratch/output use temporary random-access files, keeping the circuit's
/// bounded working set independent of world size. Files are never user paths.
class NativeWorldCircuitBindings {
  final DynamicLibrary library;
  final Map<String, Object?> _buildInfo;
  final void Function(Directory) _deleteOutputDirectory;
  final Allocator _hashAllocator;
  final Allocator _readAllocator;
  // Older engines and focused ABI stubs need no hashing symbols to open the
  // byte API. Resolve the optional extension only on the first ranged hash.
  late final _SourceSha256Api? _hashApi = _SourceSha256Api.load(library);
  final Map<int, _Session> _sessions = {};
  final Map<String, Directory> _outputs = {};
  int _outputSequence = 0;
  bool _cancelRequested = false;
  Map<String, Object?>? _progress;
  static const memoryBudget = 192 * 1024 * 1024;
  NativeWorldCircuitBindings(
    this.library, {
    void Function(Directory)? deleteOutputDirectory,
    Allocator? hashAllocator,
    Allocator? readAllocator,
  }) : _buildInfo = _readBuildInfo(library),
       _hashAllocator = hashAllocator ?? calloc,
       _readAllocator = readAllocator ?? calloc,
       _deleteOutputDirectory =
           deleteOutputDirectory ??
           ((directory) => directory.deleteSync(recursive: true));

  static Map<String, Object?> _readBuildInfo(DynamicLibrary library) {
    final pointer = library
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'abc_engine_build_info',
        )();
    if (pointer == nullptr) {
      throw const EngineException('Missing circuit build identity');
    }
    final decoded = jsonDecode(pointer.toDartString());
    if (decoded is! Map<String, dynamic>) {
      throw const EngineException('Invalid circuit build identity');
    }
    return Map<String, Object?>.unmodifiable(decoded);
  }

  void _requireCircuitAbi() {
    final version = _buildInfo['circuitWorldAbiVersion'];
    if (version is! int || version != 2) {
      throw EngineException(
        'Unsupported world circuit ABI: $version (expected 2)',
      );
    }
  }

  void _check(int status, {bool enablingOptimization = false}) {
    if (status == -7 && enablingOptimization) {
      throw const EngineException(
        '当前世界的像素接线拓扑不支持此模式；同色跨轴网络暂不支持，请保持电路优化关闭。',
        -7,
      );
    }
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
      final token = args[0] as String;
      final directory = _outputs[token];
      if (directory != null && directory.existsSync()) {
        _deleteOutputDirectory(directory);
      }
      _outputs.remove(token);
      return null;
    }
    if (method == 'worldCircuitOpenSource') {
      _cancelRequested = false;
      return _openSource(Map<String, Object?>.from(args[0] as Map));
    }
    if (method == 'worldCircuitOpen') {
      return _open(args[0] as Uint8List);
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
    if (session.closing) {
      throw const EngineException('Circuit session is closing');
    }
    final words = (args[1] as List).cast<int>(),
        records = (args[2] as List).cast<int>();
    validateWorldCircuitCommand(words, records);
    if (words[1] == 10 &&
        words[7] == 1 &&
        _buildInfo['circuitWorldWireHeadPixels'] != 1) {
      throw const EngineException('当前引擎不支持 WireHead 式像素规则，请更新引擎后再开启电路优化。');
    }
    _cancelRequested = false;
    if (words[1] == 7 || words[1] == 8) {
      if (words[1] == 7 &&
          List.generate(
            records.length ~/ 4,
            (i) => records[i * 4 + 3],
          ).any((anchor) => anchor != 0) &&
          _buildInfo['circuitWorldFragmentSupports'] != 1) {
        throw const EngineException(
          'Circuit placement supports are unavailable',
        );
      }
      if (words[1] == 8 &&
          words[12] == 1 &&
          _buildInfo['circuitWorldFragmentObjects'] != 1) {
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
        for (final id in [3]) {
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
        enablingOptimization: words[1] == 10 && words[7] == 1,
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

  Map<String, Object?> _open(Uint8List bytes) {
    _requireCircuitAbi();
    if (_sessions.isNotEmpty) {
      throw const EngineException('Close the existing world circuit first');
    }
    if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) {
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
      session = _Session(world);
      _check(
        library.lookupFunction<
          Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint32>),
          int Function(int, int, int, Pointer<Uint32>)
        >('abc_world_circuit_begin')(world, 2, memoryBudget, out),
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
    Uint8List Function(int, int) read, {
    required int Function(int, Uint8List, int) readInto,
  }) async {
    const chunkSize = 1024 * 1024;
    final api = _hashApi;
    final digest = _DigestCollector();
    // The collector and sink never retain source chunks.
    final sink = api == null ? sha256.startChunkedConversion(digest) : null;
    Pointer<Uint8> allocation = nullptr;
    var handle = 0;
    var failed = false, sinkClosed = false;
    try {
      if (api != null) {
        // The single allocation holds one reusable input window, a uint32
        // handle, and a 32-byte binary digest. No source-sized native buffer.
        allocation = _hashAllocator.allocate<Uint8>(chunkSize + 36);
        if (allocation == nullptr) {
          throw const EngineException('Circuit hash allocation failed');
        }
        final out = (allocation + chunkSize).cast<Uint32>();
        out.value = 0;
        final status = api.create(out);
        handle = out.value;
        _checkWorld(status);
        if (handle == 0) {
          throw const EngineException('Missing streaming SHA-256 context');
        }
      }
      for (var offset = 0; offset < size;) {
        _checkCancelled();
        final length = (size - offset).clamp(0, chunkSize);
        if (api != null) {
          if (readInto(offset, allocation.asTypedList(chunkSize), length) !=
              length) {
            throw const EngineException('Short hash source read');
          }
          _checkWorld(api.update(handle, allocation, length));
        } else {
          final bytes = read(offset, length);
          if (bytes.length != length) {
            throw const EngineException('Short hash source read');
          }
          sink!.add(bytes);
        }
        offset += length;
        _progress = {
          'stage': stage,
          'phase': 0,
          'completed': offset,
          'total': size,
        };
        await Future<void>.delayed(Duration.zero);
      }
      _checkCancelled();
      if (api != null) {
        final output = allocation + chunkSize + 4;
        _checkWorld(api.finish(handle, output));
        return output
            .asTypedList(32)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join();
      }
      sinkClosed = true;
      sink!.close();
      return digest.value.toString();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      Object? cleanupError;
      StackTrace? cleanupStack;
      void cleanup(void Function() release) {
        try {
          release();
        } catch (error, stack) {
          cleanupError ??= error;
          cleanupStack ??= stack;
        }
      }

      if (!sinkClosed && sink != null) cleanup(sink.close);
      if (handle != 0) cleanup(() => _checkWorld(api!.destroy(handle)));
      if (allocation != nullptr) cleanup(() => _hashAllocator.free(allocation));
      if (!failed && cleanupError != null) {
        Error.throwWithStackTrace(cleanupError!, cleanupStack!);
      }
    }
  }

  Future<Map<String, Object?>> _openSource(Map<String, Object?> source) async {
    _requireCircuitAbi();
    if (_sessions.isNotEmpty) {
      throw const EngineException('Close the existing world circuit first');
    }
    final worldSource = WorldCircuitSource.fromMap(source);
    worldSource.toFileMap();
    final session = _Session(0, streamed: true);
    final inputWindow = _ReadWindow(_readAllocator);
    final out = calloc<Uint32>(),
        event = calloc<Uint32>(12),
        data = calloc<Pointer<Uint8>>();
    int task = 0, id = 0;
    try {
      session.attach(1, worldSource);
      session.sourceSha256 = await _hashRange(
        'hash',
        worldSource.length,
        (offset, length) => session.read(1, offset, length),
        readInto: (offset, buffer, length) =>
            session.readInto(1, offset, buffer, length),
      );
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
          session.readInto(e[2], e[3], inputWindow.bytes, e[4]);
          _check(
            library.lookupFunction<
              Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32),
              int Function(int, int, int, Pointer<Uint8>, int)
            >('abc_world_stream_supply')(
              task,
              e[2],
              e[3],
              inputWindow.pointer,
              e[4],
            ),
          );
        } else if (e[1] != 0) {
          throw const EngineException('Unexpected stream-open event');
        }
        if (slice.elapsedMilliseconds >= 8) {
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      // Decode and compile own separate windows; do not retain both at once.
      inputWindow.close();
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
          Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint32>),
          int Function(int, int, int, Pointer<Uint32>)
        >('abc_world_circuit_begin')(session.world, 2, memoryBudget, out),
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
      inputWindow.close();
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
        fingerprint = await _hashRange(
          'hash-output',
          output.lengthSync(),
          (offset, length) {
            input.setPositionSync(offset);
            return input.readSync(length);
          },
          readInto: (offset, buffer, length) {
            input.setPositionSync(offset);
            return input.readIntoSync(buffer, 0, length);
          },
        );
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
    final inputWindow = _ReadWindow(_readAllocator);
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
        if (e[0] != 2 || e[5] != 0) {
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
          if (file.readIntoSync(inputWindow.bytes, 0, length) != length) {
            throw const EngineException('Short circuit read');
          }
          _check(
            library.lookupFunction<
              Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32),
              int Function(int, int, int, Pointer<Uint8>, int)
            >('abc_world_circuit_supply')(
              id,
              source,
              offset,
              inputWindow.pointer,
              length,
            ),
          );
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
            } else if (source != 2 && !(save && source == 3)) {
              throw const EngineException('Unexpected circuit output source');
            }
            final file = session.files[source];
            if (file == null) {
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
      if (save && session.files[3]!.lengthSync() != resultCount) {
        throw const EngineException('Incomplete circuit saved world');
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
      };
    } finally {
      inputWindow.close();
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
    final inputWindow = _ReadWindow(_readAllocator);
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
        if (e[0] != 2 || e[5] != 0) {
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
          session.readInto(source, offset, inputWindow.bytes, length);
          _check(
            library.lookupFunction<
              Int32 Function(Uint32, Uint32, Uint32, Pointer<Uint8>, Uint32),
              int Function(int, int, int, Pointer<Uint8>, int)
            >('abc_world_circuit_supply')(
              id,
              source,
              offset,
              inputWindow.pointer,
              length,
            ),
          );
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
            } else if (source != 2 && !(save && source == 3)) {
              throw const EngineException('Unexpected circuit output source');
            }
            final file = session.files[source];
            if (file == null) {
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
      if (save && session.files[3]!.lengthSync() != resultCount) {
        throw const EngineException('Incomplete circuit saved world');
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
        if (save) 'worldSource': await _leaseOutput(session, 3, 'world.wld'),
      };
    } catch (_) {
      _one('cancel')(id);
      if (commandKind == 8) session.files[6]!.truncateSync(0);
      rethrow;
    } finally {
      inputWindow.close();
      calloc.free(event);
      calloc.free(data);
      calloc.free(stats);
    }
  }

  void _dispose(int id, _Session session) {
    session.closing = true;
    if (!session.circuitClosed) {
      _check(_one('close')(id));
      session.circuitClosed = true;
    }
    Object? failure;
    StackTrace? failureStack;
    try {
      if (session.world != 0) {
        _checkWorld(
          library.lookupFunction<_OneC, _OneD>('abc_world_close')(
            session.world,
          ),
        );
        session.world = 0;
      }
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
    try {
      session.close();
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
    // Keep unfinished owners reachable for a close retry. Completed native
    // closes and file closes must not be repeated on that retry.
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    _sessions.remove(id);
  }
}

/// One bounded input window, allocated only if an operation requests READ.
/// Both native supply APIs copy synchronously and never retain this pointer.
class _ReadWindow {
  static const capacity = 1024 * 1024;
  final Allocator allocator;
  Pointer<Uint8> pointer = nullptr;
  Uint8List? _bytes;

  _ReadWindow(this.allocator);

  Uint8List get bytes {
    if (pointer == nullptr) {
      pointer = allocator.allocate<Uint8>(capacity);
      if (pointer == nullptr) {
        throw const EngineException('Circuit read allocation failed');
      }
      _bytes = pointer.asTypedList(capacity);
    }
    return _bytes!;
  }

  void close() {
    if (pointer == nullptr) return;
    final owned = pointer;
    pointer = nullptr;
    _bytes = null;
    allocator.free(owned);
  }
}

class _Session {
  int world;
  final bool streamed;
  bool closing = false, circuitClosed = false;
  String? sourceSha256;
  int readBytes = 0, readRequests = 0, maxReadBytes = 0;
  final Directory directory = Directory.systemTemp.createTempSync(
    'abc-circuit-',
  );
  final Map<int, RandomAccessFile> files = {};
  final Map<int, String> paths = {};
  final Map<int, FileStat> originals = {};
  _Session(this.world, {this.streamed = false}) {
    try {
      for (final id in [2, 3, 6]) {
        paths[id] = '${directory.path}/$id';
        files[id] = File(paths[id]!).openSync(mode: FileMode.write);
      }
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
  }

  Uint8List read(int id, int offset, int length) {
    final result = _readFile(id, offset, length).readSync(length);
    if (result.length != length) {
      throw const EngineException('Short ranged circuit read');
    }
    _recordRead(length);
    return result;
  }

  int readInto(int id, int offset, Uint8List buffer, int length) {
    final count = _readFile(id, offset, length).readIntoSync(buffer, 0, length);
    if (count != length) {
      throw const EngineException('Short ranged circuit read');
    }
    _recordRead(length);
    return count;
  }

  RandomAccessFile _readFile(int id, int offset, int length) {
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
    return file;
  }

  void _recordRead(int length) {
    readBytes += length;
    readRequests++;
    if (length > maxReadBytes) maxReadBytes = length;
  }

  void close() {
    Object? failure;
    StackTrace? failureStack;
    for (final entry in files.entries.toList()) {
      try {
        entry.value.closeSync();
        files.remove(entry.key);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
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
