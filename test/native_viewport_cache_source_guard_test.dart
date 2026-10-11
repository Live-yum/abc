// Actual compiled engine + unchanged Dart source guard; no scripted ABI stub.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

void main() {
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  final input = Platform.environment['ABC_VIEWPORT_CACHE_FIXTURE'];
  final cached = Platform.environment['ABC_EXPECT_VIEWPORT_CACHE'] == '1';
  for (final failure in ['size', 'mtime', 'type', 'read', 'short']) {
    test('actual warm viewport preserves source $failure failure and cleanup', () async {
      final directory = await Directory.systemTemp.createTemp(
        'abc-source-guard-',
      );
      final source = File('${directory.path}/source.wld');
      await File(input!).copy(source.path);
      final originalStat = source.statSync();
      final allocator = _TrackedAllocator();
      final io = _SourceOverrides(source.path);
      final api = NativeWorldCircuitBindings(
        DynamicLibrary.open(library!),
        readAllocator: allocator,
      );
      int? session;
      final injected = FileSystemException(
        'injected original source read failure',
      );
      Future<Map> command() async {
        final query = WorldCircuitCommand.viewport(0, 8, 96, 42);
        return await Future<Object?>.value(
          api.dispatch('worldCircuitCommand', [
            session!,
            query.words,
            query.records,
          ]),
        ) as Map;
      }

      Map diagnostics() =>
          (api.dispatch('worldCircuitProgress', []) as Map)['diagnostics']
              as Map;
      try {
        await IOOverrides.runWithIOOverrides(() async {
          final opened = await Future<Object?>.value(
            api.dispatch('worldCircuitOpenSource', [
              {
                'path': source.path,
                'length': source.lengthSync(),
                'name': 'synthetic-cache-source.wld',
              },
            ]),
          ) as Map;
          session = opened['session'] as int;
          final cold = await command();
          final before = Map.of(diagnostics());
          final warm = await command();
          expect(warm['records'], orderedEquals(cold['records'] as Uint8List));
          final after = diagnostics();
          if (cached) {
            expect(
              (after['sourceReadRequests'] as int) -
                  (before['sourceReadRequests'] as int),
              1,
            );
            expect(
              (after['sourceReadBytes'] as int) -
                  (before['sourceReadBytes'] as int),
              1,
            );
          } else {
            expect(
              (after['sourceReadBytes'] as int) -
                  (before['sourceReadBytes'] as int),
              greaterThan(1),
            );
          }
          expect(allocator.live, isEmpty);
          if (failure == 'size') {
            source.writeAsBytesSync([0], mode: FileMode.append);
            source.setLastModifiedSync(originalStat.modified);
          }
          if (failure == 'mtime')
            source.setLastModifiedSync(DateTime.utc(2001));
          // Replacing a real file with a directory changes type and may also
          // change size/mtime. This tests that actual replacement is rejected,
          // not independent coverage of each metadata predicate.
          if (failure == 'type') {
            source.renameSync('${source.path}.held');
            Directory(source.path).createSync();
          }
          if (failure == 'read') io.failure = injected;
          if (failure == 'short') io.short = true;
          await expectLater(
            command(),
            throwsA(
              failure == 'read'
                  ? same(injected)
                  : isA<EngineException>().having(
                      (e) => e.message,
                      'source diagnostic',
                      contains(
                        failure == 'short'
                            ? 'Short ranged circuit read'
                            : 'original circuit source changed while open',
                      ),
                    ),
            ),
          );
          expect(
            allocator.live,
            isEmpty,
            reason: 'Failed warm READ releases the host window.',
          );
          io.failure = null;
          io.short = false;
          if (failure == 'size') {
            final handle = source.openSync(mode: FileMode.append);
            handle.truncateSync(originalStat.size);
            handle.closeSync();
          }
          if (failure == 'type') {
            Directory(source.path).deleteSync();
            File('${source.path}.held').renameSync(source.path);
          }
          source.setLastModifiedSync(originalStat.modified);
          final recovered = await command();
          expect(
            recovered['records'],
            orderedEquals(cold['records'] as Uint8List),
          );
          api.dispatch('worldCircuitClose', [session]);
          session = null;
          expect(allocator.live, isEmpty);
          expect(
            io.openSources,
            0,
            reason: 'The actual original file handle is closed.',
          );
          expect(allocator.allocations, allocator.frees);
        }, io);
      } finally {
        if (session != null) api.dispatch('worldCircuitClose', [session]);
        directory.deleteSync(recursive: true);
      }
    }, skip: !Platform.isLinux || library == null || input == null);
  }
}

class _TrackedAllocator implements Allocator {
  final live = <int>{};
  int allocations = 0, frees = 0;
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final pointer = calloc.allocate<T>(byteCount, alignment: alignment);
    expect(live.add(pointer.address), isTrue);
    allocations++;
    return pointer;
  }

  @override
  void free(Pointer pointer) {
    expect(live.remove(pointer.address), isTrue);
    frees++;
    calloc.free(pointer);
  }
}

final class _SourceOverrides extends IOOverrides {
  _SourceOverrides(this.source);
  final String source;
  Object? failure;
  bool short = false;
  int openSources = 0;
  @override
  File createFile(String path) => path == source
      ? _SourceFile(super.createFile(path), this)
      : super.createFile(path);
}

class _SourceFile implements File {
  _SourceFile(this.delegate, this.io);
  final File delegate;
  final _SourceOverrides io;
  @override
  String get path => delegate.path;
  @override
  FileStat statSync() => delegate.statSync();
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    io.openSources++;
    return _SourceHandle(delegate.openSync(mode: mode), io);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SourceHandle implements RandomAccessFile {
  _SourceHandle(this.delegate, this.io);
  final RandomAccessFile delegate;
  final _SourceOverrides io;
  @override
  int readIntoSync(List<int> bytes, [int start = 0, int? end]) {
    if (io.failure != null) throw io.failure!;
    if (io.short) return 0;
    return delegate.readIntoSync(bytes, start, end);
  }

  @override
  Uint8List readSync(int bytes) => delegate.readSync(bytes);
  @override
  int lengthSync() => delegate.lengthSync();
  @override
  void setPositionSync(int position) => delegate.setPositionSync(position);
  @override
  void closeSync() {
    delegate.closeSync();
    io.openSources--;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
