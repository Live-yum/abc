import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

const _window = 1024 * 1024;
const _readBytes = 2 * _window + 38;

void main() {
  group('native reusable READ windows', () {
    late Directory build;
    late _Stub stub;

    setUpAll(() async {
      build = await Directory.systemTemp.createTemp('abc-read-contract-');
      final path = '${build.path}/read.so';
      final result = await Process.run('cc', [
        '-std=c11',
        '-O2',
        '-shared',
        '-fPIC',
        'test/native_world_circuit_read_buffer_fixture.c',
        '-o',
        path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      stub = _Stub(DynamicLibrary.open(path));
    });
    tearDownAll(() => build.delete(recursive: true));

    for (final mode in ['sync', 'decode', 'async']) {
      test(
        '$mode reuses one bounded window for different READ sizes',
        () async {
          await _withFixture(stub, mode, (fixture) async {
            final result = await fixture.open();
            expect(fixture.allocator.allocations, [_window]);
            expect(fixture.allocator.peakLive, 1);
            fixture.expectReleased();
            expect(stub.metric(mode == 'decode' ? 0 : 2), 4);
            expect(stub.metric(mode == 'decode' ? 1 : 3), _readBytes);
            expect(
              stub.metric(4),
              0,
              reason: 'The supply pointer stays stable.',
            );
            expect(fixture.io.buffers.length, 4);
            expect(
              fixture.io.buffers.every(
                (buffer) => identical(buffer, fixture.io.buffers.first),
              ),
              isTrue,
            );
            expect(fixture.io.buffers.first.length, _window);
            if (mode != 'sync') {
              expect(
                result['sourceSha256'],
                sha256.convert(fixture.bytes).toString(),
              );
              final progress =
                  fixture.api.dispatch('worldCircuitProgress', []) as Map;
              final diagnostics = progress['diagnostics'] as Map;
              expect(diagnostics['sourceReadRequests'], 2 + 4);
              expect(
                diagnostics['sourceReadBytes'],
                fixture.bytes.length + _readBytes,
              );
              expect(diagnostics['maxReadBytes'], _window);
            }
          });
        },
      );

      for (final failure in ['short', 'read', 'supply', 'allocation', 'null']) {
        test('$mode releases its window after $failure failure', () async {
          await _withFixture(stub, mode, (fixture) async {
            final injected = FileSystemException('injected read failure');
            if (failure == 'short') fixture.io.shortRead = true;
            if (failure == 'read') fixture.io.readFailure = injected;
            if (failure == 'supply') fixture.configure(failSupply: true);
            if (failure == 'allocation') fixture.allocator.failure = injected;
            if (failure == 'null') fixture.allocator.returnNull = true;
            await expectLater(
              fixture.open(),
              throwsA(
                failure == 'read' || failure == 'allocation'
                    ? same(injected)
                    : isA<EngineException>().having(
                        (error) => error.message,
                        'diagnostic',
                        contains(
                          failure == 'short'
                              ? 'Short'
                              : failure == 'null'
                              ? 'allocation failed'
                              : '-92',
                        ),
                      ),
              ),
            );
            fixture.expectReleased();
            expect(
              stub.metric(mode == 'decode' ? 0 : 2),
              failure == 'supply' ? 1 : 0,
            );
            expect(stub.metric(mode == 'decode' ? 6 : 8), 1);
            expect(stub.metric(9), mode == 'decode' ? 0 : 1);
          });
        });
      }

      test('$mode rejects oversized READ before allocating', () async {
        await _withFixture(stub, mode, (fixture) async {
          fixture.configure(badRange: true);
          await expectLater(fixture.open(), throwsA(isA<EngineException>()));
          expect(fixture.allocator.allocations, isEmpty);
          fixture.expectReleased();
        });
      });

      if (mode != 'sync') {
        test('$mode cancellation frees the already supplied window', () async {
          await _withFixture(stub, mode, (fixture) async {
            fixture.allocator.onAllocate = () {
              fixture.api.dispatch('worldCircuitCancelOperation', []);
            };
            await expectLater(
              fixture.open(),
              throwsA(
                isA<EngineException>().having(
                  (error) => error.message,
                  'diagnostic',
                  contains('cancelled'),
                ),
              ),
            );
            expect(stub.metric(mode == 'decode' ? 0 : 2), 1);
            fixture.expectReleased();
          });
        });
      }
    }

    test('decode releases its window before compile starts', () async {
      await _withFixture(stub, 'both', (fixture) async {
        await fixture.open();
        expect(fixture.allocator.allocations, [_window, _window]);
        expect(fixture.allocator.peakLive, 1);
        expect(stub.metric(0), 4);
        expect(stub.metric(2), 4);
        fixture.expectReleased();
      });
    });

    for (final mode in ['sync', 'async']) {
      test(
        '$mode open and commands without READ never allocate a window',
        () async {
          await _withFixture(stub, mode, (fixture) async {
            stub.configure();
            await fixture.open();
            final command = WorldCircuitCommand.viewport(0, 0, 1, 1);
            await Future<Object?>.value(
              fixture.api.dispatch('worldCircuitCommand', [
                fixture.session,
                command.words,
                command.records,
              ]),
            );
            expect(fixture.allocator.allocations, isEmpty);
            fixture.expectReleased();
          });
        },
      );
    }

    test(
      'changed original is rejected before directly reading or supplying',
      () async {
        await _withFixture(stub, 'decode', (fixture) async {
          fixture.allocator.onAllocate = () {
            fixture.source.setLastModifiedSync(DateTime.utc(2001));
          };
          await expectLater(
            fixture.open(),
            throwsA(
              isA<EngineException>().having(
                (error) => error.message,
                'diagnostic',
                contains('original circuit source changed'),
              ),
            ),
          );
          expect(fixture.io.buffers, isEmpty);
          expect(stub.metric(0), 0);
          fixture.expectReleased();
        });
      },
    );
  }, skip: !Platform.isLinux);
}

Future<void> _withFixture(
  _Stub stub,
  String mode,
  Future<void> Function(_Fixture) body,
) async {
  final directory = await Directory.systemTemp.createTemp('abc-read-case-');
  final fixture = _Fixture(stub, mode, directory);
  try {
    fixture.source.writeAsBytesSync(fixture.bytes);
    fixture.configure();
    await IOOverrides.runWithIOOverrides(() async {
      try {
        await body(fixture);
      } finally {
        fixture.dispose();
      }
    }, fixture.io);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

class _Stub {
  final DynamicLibrary library;
  late final metric = library
      .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'read_test_metric',
      );
  late final _configure = library
      .lookupFunction<
        Void Function(Uint32, Uint32, Uint32, Uint32),
        void Function(int, int, int, int)
      >('read_test_configure');
  _Stub(this.library);
  void configure({
    bool decode = false,
    bool circuit = false,
    bool badRange = false,
    bool failSupply = false,
  }) => _configure(
    decode ? 1 : 0,
    circuit ? 1 : 0,
    badRange ? 1 : 0,
    failSupply ? 1 : 0,
  );
}

class _Fixture {
  final _Stub stub;
  final String mode;
  final Directory directory;
  final allocator = _ReadAllocator();
  late final io = _ReadOverrides(directory);
  late final api = NativeWorldCircuitBindings(
    stub.library,
    readAllocator: allocator,
  );
  late final source = File('${directory.path}/source.wld');
  final bytes = Uint8List.fromList(
    List<int>.generate(_window + 8, (i) => (i * 31 + 17) & 255),
  );
  int? session;
  _Fixture(this.stub, this.mode, this.directory);
  void configure({bool badRange = false, bool failSupply = false}) =>
      stub.configure(
        decode: mode == 'decode' || mode == 'both',
        circuit: mode != 'decode',
        badRange: badRange,
        failSupply: failSupply,
      );
  Future<Map> open() async {
    final result = await Future<Object?>.value(
      mode == 'sync'
          ? api.dispatch('worldCircuitOpen', [bytes])
          : api.dispatch('worldCircuitOpenSource', [
              {
                'path': source.path,
                'length': bytes.length,
                'name': 'source.wld',
              },
            ]),
    ) as Map;
    session = result['session'] as int;
    return result;
  }

  void expectReleased() {
    expect(allocator.live, isEmpty);
    expect(allocator.frees, allocator.allocations.length);
  }

  void dispose() {
    if (session != null) api.dispatch('worldCircuitClose', [session]);
    for (final address in allocator.live) {
      calloc.free(Pointer<Void>.fromAddress(address));
    }
    allocator.live.clear();
  }
}

class _ReadAllocator implements Allocator {
  final allocations = <int>[];
  final live = <int>{};
  int frees = 0, peakLive = 0;
  Object? failure;
  bool returnNull = false;
  void Function()? onAllocate;
  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    if (failure != null) throw failure!;
    if (returnNull) return nullptr;
    final pointer = calloc.allocate<T>(byteCount, alignment: alignment);
    pointer.cast<Uint8>().asTypedList(byteCount).fillRange(0, byteCount, 0xa5);
    allocations.add(byteCount);
    live.add(pointer.address);
    if (live.length > peakLive) peakLive = live.length;
    onAllocate?.call();
    return pointer;
  }

  @override
  void free(Pointer pointer) {
    expect(live.remove(pointer.address), isTrue, reason: 'Free exactly once.');
    calloc.free(pointer);
    frees++;
  }
}

final class _ReadOverrides extends IOOverrides {
  final Directory directory;
  final buffers = <List<int>>[];
  bool shortRead = false;
  Object? readFailure;
  _ReadOverrides(this.directory);
  @override
  Directory getSystemTempDirectory() => directory;
  @override
  File createFile(String path) => _ReadFile(super.createFile(path), this);
}

class _ReadFile implements File {
  final File delegate;
  final _ReadOverrides io;
  _ReadFile(this.delegate, this.io);
  @override
  String get path => delegate.path;
  @override
  FileStat statSync() => delegate.statSync();
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _ReadHandle(delegate.openSync(mode: mode), io);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReadHandle implements RandomAccessFile {
  final RandomAccessFile delegate;
  final _ReadOverrides io;
  _ReadHandle(this.delegate, this.io);
  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    io.buffers.add(buffer);
    if (io.readFailure != null) throw io.readFailure!;
    return delegate.readIntoSync(buffer, start, io.shortRead ? end! - 1 : end);
  }

  @override
  Uint8List readSync(int bytes) => delegate.readSync(bytes);
  @override
  int lengthSync() => delegate.lengthSync();
  @override
  void setPositionSync(int position) => delegate.setPositionSync(position);
  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      delegate.writeFromSync(buffer, start, end);
  @override
  void truncateSync(int length) => delegate.truncateSync(length);
  @override
  void closeSync() => delegate.closeSync();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
