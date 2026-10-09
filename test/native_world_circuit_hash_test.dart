import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

const _chunkSize = 1024 * 1024;

void main() {
  group('native streamed world fingerprints', () {
    late Directory buildDirectory;
    final libraries = <int, _HashStub>{};

    setUpAll(() async {
      buildDirectory = await Directory.systemTemp.createTemp('abc-hash-test-');
      for (final symbols in [15, 0, 14, 13, 11, 7]) {
        final path = '${buildDirectory.path}/hash_$symbols.so';
        final compilation = await Process.run('cc', [
          '-std=c11',
          '-O2',
          '-shared',
          '-fPIC',
          '-DHASH_EXPORTS=$symbols',
          '-I',
          'native/vendor/TerraWasm/include',
          'test/native_world_circuit_hash_fixture.c',
          'native/vendor/TerraWasm/src/terra_hash.c',
          '-o',
          path,
        ]);
        expect(compilation.exitCode, 0, reason: '${compilation.stderr}');
        libraries[symbols] = _HashStub(DynamicLibrary.open(path));
      }
    });

    tearDownAll(() async {
      await buildDirectory.delete(recursive: true);
    });

    for (final size in [
      1,
      55,
      56,
      63,
      64,
      65,
      _chunkSize - 1,
      _chunkSize,
      _chunkSize + 1,
      3 * _chunkSize + 17,
    ]) {
      test(
        'hashes $size-byte input and output across native windows',
        () async {
          await _withFixture(libraries[15]!, (fixture) async {
            final source = _pattern(size, 31, 17);
            final opened = await fixture.open(source);
            expect(opened['sourceSha256'], sha256.convert(source).toString());
            fixture.expectSuccessfulHash(size);
            expect(fixture.allocator.allocations, [_chunkSize + 36]);

            fixture.stub.configure(outputLength: size);
            final saved = await fixture.save();
            final output = saved['worldSource'] as Map;
            final expected = _pattern(size, 13, 7);
            expect(output['length'], size);
            expect(output['sha256'], sha256.convert(expected).toString());
            expect(File(output['path'] as String).readAsBytesSync(), expected);
            expect(saved['sourceSha256'], opened['sourceSha256']);
            fixture.expectSuccessfulHash(size);
            expect(fixture.allocator.allocations, [
              _chunkSize + 36,
              _chunkSize + 36,
            ]);
            expect(fixture.allocator.peakLive, 1);
          });
        },
      );
    }

    test('empty saved output has the standard empty SHA-256 digest', () async {
      await _withFixture(libraries[15]!, (fixture) async {
        final opened = await fixture.open(Uint8List.fromList([97, 98, 99]));
        expect(
          opened['sourceSha256'],
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        );
        fixture.stub.configure(outputLength: 0);
        final saved = await fixture.save();
        expect(
          (saved['worldSource'] as Map)['sha256'],
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        );
        fixture.expectSuccessfulHash(0);
      });
    });

    test('empty input is rejected before allocating a hash context', () async {
      await _withFixture(libraries[15]!, (fixture) async {
        await expectLater(fixture.open(Uint8List(0)), throwsFormatException);
        expect(fixture.stub.metric(0), 0);
        expect(fixture.allocator.allocations, isEmpty);
      });
    });

    test(
      'legacy libraries hash source and output using Dart fallback',
      () async {
        await _withFixture(libraries[0]!, (fixture) async {
          final source = _pattern(2 * _chunkSize + 1, 31, 17);
          final opened = await fixture.open(source);
          expect(opened['sourceSha256'], sha256.convert(source).toString());
          fixture.stub.configure(outputLength: _chunkSize + 1);
          final saved = await fixture.save();
          expect(
            (saved['worldSource'] as Map)['sha256'],
            sha256.convert(_pattern(_chunkSize + 1, 13, 7)).toString(),
          );
          expect(fixture.allocator.allocations, isEmpty);
          expect(List.generate(5, fixture.stub.metric), everyElement(0));

          fixture.stub.configure(outputLength: 0);
          final empty = await fixture.save();
          expect(
            (empty['worldSource'] as Map)['sha256'],
            sha256.convert(const <int>[]).toString(),
          );
        });
      },
    );

    for (final missing in {
      14: 'create',
      13: 'update',
      11: 'final',
      7: 'destroy',
    }.entries) {
      test(
        'rejects missing ${missing.value} lazily without fallback',
        () async {
          await _withFixture(libraries[missing.key]!, (fixture) async {
            // Legacy byte opens do not need to resolve the streaming hash ABI.
            final opened = fixture.api.dispatch('worldCircuitOpen', [
              Uint8List.fromList([1]),
            ]) as Map;
            fixture.api.dispatch('worldCircuitClose', [opened['session']]);
            await expectLater(
              fixture.open(Uint8List.fromList([1])),
              throwsA(
                isA<EngineException>().having(
                  (error) => error.message,
                  'missing API diagnostic',
                  contains('Incomplete streaming SHA-256 API'),
                ),
              ),
            );
            expect(fixture.allocator.allocations, isEmpty);
            expect(List.generate(5, fixture.stub.metric), everyElement(0));
            expect(fixture.stub.metric(8), 0);
          });
        },
      );
    }

    for (final size in [1, _chunkSize + 1]) {
      test(
        'cancellation frees native ownership after a $size-byte source',
        () async {
          await _withFixture(libraries[15]!, (fixture) async {
            fixture.stub.configure(destroyStatus: -85);
            final pending = fixture.open(_pattern(size, 31, 17));
            expect(fixture.stub.metric(1), 1);
            fixture.api.dispatch('worldCircuitCancelOperation', const []);
            await expectLater(pending, throwsA(_messageContains('cancelled')));
            expect(fixture.stub.metric(2), 0);
            expect(fixture.stub.metric(3), 1);
            expect(fixture.stub.metric(8), 0);
            fixture.expectReleased();
          });
        },
      );
    }

    test('fallback checks cancellation after its final chunk too', () async {
      await _withFixture(libraries[0]!, (fixture) async {
        final pending = fixture.open(Uint8List.fromList([1]));
        fixture.api.dispatch('worldCircuitCancelOperation', const []);
        await expectLater(pending, throwsA(_messageContains('cancelled')));
        expect(fixture.stub.metric(8), 0);
        expect(fixture.allocator.allocations, isEmpty);
      });
    });

    test('changed-source read error survives a failing destroy', () async {
      await _withFixture(libraries[15]!, (fixture) async {
        fixture.stub.configure(destroyStatus: -85);
        final pending = fixture.open(_pattern(_chunkSize + 1, 31, 17));
        expect(fixture.stub.metric(1), 1);
        fixture.source.writeAsBytesSync(const []);
        await expectLater(
          pending,
          throwsA(_messageContains('Invalid ranged circuit read')),
        );
        expect(fixture.stub.metric(2), 0);
        expect(fixture.stub.metric(3), 1);
        expect(fixture.stub.metric(8), 0);
        fixture.expectReleased();
      });
    });

    for (final failure in [1, 2, 3, 4]) {
      for (final cleanupFails in [false, true]) {
        test('stage $failure failure preserves error and releases ownership '
            '(destroy fails: $cleanupFails)', () async {
          await _withFixture(libraries[15]!, (fixture) async {
            fixture.stub.configure(
              failure: failure,
              failureStatus: -80 - failure,
              destroyStatus: cleanupFails ? -85 : 0,
            );
            await expectLater(
              fixture.open(Uint8List.fromList([97, 98, 99])),
              throwsA(_status(-80 - failure)),
            );
            expect(fixture.stub.metric(0), 1);
            expect(fixture.stub.metric(1), failure >= 3 ? 1 : 0);
            expect(fixture.stub.metric(2), failure == 4 ? 1 : 0);
            expect(fixture.stub.metric(3), failure == 1 ? 0 : 1);
            expect(fixture.stub.metric(8), 0);
            expect(fixture.stub.metric(12), 0);
            expect(fixture.allocator.allocations, [_chunkSize + 36]);
            fixture.expectReleased();
          });
        });
      }
    }

    test('a positive native hash status is also an error', () async {
      await _withFixture(libraries[15]!, (fixture) async {
        fixture.stub.configure(failure: 3, failureStatus: 83);
        await expectLater(
          fixture.open(Uint8List.fromList([1])),
          throwsA(_status(83)),
        );
        expect(fixture.stub.metric(3), 1);
        fixture.expectReleased();
      });
    });

    test('successful create without a handle is rejected and freed', () async {
      await _withFixture(libraries[15]!, (fixture) async {
        fixture.stub.configure(failure: 5);
        await expectLater(
          fixture.open(Uint8List.fromList([1])),
          throwsA(_messageContains('Missing streaming SHA-256 context')),
        );
        expect(fixture.stub.metric(1), 0);
        expect(fixture.stub.metric(3), 0);
        fixture.expectReleased();
      });
    });

    test(
      'destroy error surfaces after an otherwise successful digest',
      () async {
        await _withFixture(libraries[15]!, (fixture) async {
          fixture.stub.configure(destroyStatus: -85);
          await expectLater(
            fixture.open(Uint8List.fromList([1])),
            throwsA(_status(-85)),
          );
          expect(fixture.stub.metric(2), 1);
          expect(fixture.stub.metric(3), 1);
          fixture.expectReleased();
        });
      },
    );

    test(
      'allocation failure creates no context or orphaned allocation',
      () async {
        await _withFixture(libraries[15]!, (fixture) async {
          final failure = StateError('injected hash allocation failure');
          fixture.allocator.allocateFailure = failure;
          await expectLater(
            fixture.open(Uint8List.fromList([1])),
            throwsA(same(failure)),
          );
          expect(fixture.stub.metric(0), 0);
          expect(fixture.allocator.frees, 0);
          fixture.expectReleased();
        });
      },
    );

    for (final nativeFailure in [false, true]) {
      test('allocator free is attempted and its error respects primary failure '
          '($nativeFailure)', () async {
        await _withFixture(libraries[15]!, (fixture) async {
          final failure = StateError('injected hash free failure');
          fixture.allocator.freeFailure = failure;
          fixture.stub.configure(
            failure: nativeFailure ? 3 : 0,
            failureStatus: -83,
          );
          await expectLater(
            fixture.open(Uint8List.fromList([1])),
            throwsA(nativeFailure ? _status(-83) : same(failure)),
          );
          expect(fixture.stub.metric(3), 1);
          expect(fixture.allocator.frees, 1);
          fixture.expectReleased();
        });
      });
    }

    for (final cancel in [false, true]) {
      test('failed output hash removes its unpublished lease '
          '(cancel: $cancel)', () async {
        await _withFixture(libraries[15]!, (fixture) async {
          await fixture.open(Uint8List.fromList([1]));
          fixture.stub.configure(
            failure: cancel ? 0 : 4,
            failureStatus: -84,
            destroyStatus: -85,
            outputLength: _chunkSize + 1,
          );
          Directory? output;
          fixture.allocator.onAllocate = () {
            output = fixture.outputDirectories.single;
            if (cancel) {
              // Run during the hash yield regardless of how often the circuit
              // I/O pump yielded before reaching the hashing stage.
              scheduleMicrotask(() {
                fixture.api.dispatch('worldCircuitCancelOperation', const []);
              });
            }
          };
          final pending = fixture.save();
          await expectLater(
            pending,
            throwsA(cancel ? _messageContains('cancelled') : _status(-84)),
          );
          expect(output, isNotNull);
          expect(output!.existsSync(), isFalse);
          expect(fixture.outputDirectories, isEmpty);
          expect(fixture.stub.metric(1), cancel ? 1 : 2);
          expect(fixture.stub.metric(3), 1);
          expect(fixture.stub.metric(11), 1);
          fixture.expectReleased();

          // Failed publication leaves the session reusable for another save.
          fixture.allocator.onAllocate = null;
          fixture.stub.configure(outputLength: 65);
          final saved = await fixture.save();
          expect((saved['worldSource'] as Map)['token'], 'native-1');
          expect(
            (saved['worldSource'] as Map)['sha256'],
            sha256.convert(_pattern(65, 13, 7)).toString(),
          );
          fixture.expectSuccessfulHash(65);
        });
      });
    }
  }, skip: !Platform.isLinux);
}

Matcher _status(int code) =>
    isA<EngineException>().having((error) => error.code, 'native status', code);

Matcher _messageContains(String text) => isA<EngineException>().having(
  (error) => error.message,
  'diagnostic',
  contains(text),
);

Uint8List _pattern(int length, int multiplier, int addend) =>
    Uint8List.fromList(
      List<int>.generate(length, (i) => (i * multiplier + addend) & 255),
    );

Future<void> _withFixture(
  _HashStub stub,
  Future<void> Function(_HashFixture) body,
) async {
  final directory = await Directory.systemTemp.createTemp('abc-hash-case-');
  try {
    await IOOverrides.runZoned(() async {
      expect(
        stub.metric(4),
        0,
        reason: 'The preceding hash released its context.',
      );
      stub.configure();
      final fixture = _HashFixture(stub, directory);
      try {
        await body(fixture);
      } finally {
        fixture.dispose();
      }
    }, getSystemTempDirectory: () => directory);
  } finally {
    await directory.delete(recursive: true);
  }
}

class _HashStub {
  final DynamicLibrary library;
  late final int Function(int) metric = library
      .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
        'hash_test_metric',
      );
  late final void Function(int, int, int, int) _configure = library
      .lookupFunction<
        Void Function(Uint32, Int32, Int32, Uint32),
        void Function(int, int, int, int)
      >('hash_test_configure');

  _HashStub(this.library);

  void configure({
    int failure = 0,
    int failureStatus = -83,
    int destroyStatus = 0,
    int outputLength = 0,
  }) {
    _configure(failure, failureStatus, destroyStatus, outputLength);
  }
}

class _HashFixture {
  final _HashStub stub;
  final Directory directory;
  final allocator = _TrackingAllocator();
  late final api = NativeWorldCircuitBindings(
    stub.library,
    hashAllocator: allocator,
  );
  late final source = File('${directory.path}/source.wld');
  int? session;
  final tokens = <String>[];

  _HashFixture(this.stub, this.directory);

  Future<Map<String, Object?>> open(Uint8List bytes) async {
    source.writeAsBytesSync(bytes);
    final result = await (api.dispatch('worldCircuitOpenSource', [
      {
        'path': source.path,
        'length': bytes.length,
        'name': 'source.wld',
        'sha256': '0' * 64,
      },
    ]) as Future<Map<String, Object?>>);
    session = result['session'] as int;
    return result;
  }

  Future<Map<String, Object?>> save() async {
    final command = WorldCircuitCommand.save();
    final result = await (api.dispatch('worldCircuitCommand', [
      session!,
      command.words,
      command.records,
    ]) as Future<Map<String, Object?>>);
    tokens.add((result['worldSource'] as Map)['token'] as String);
    return result;
  }

  List<Directory> get outputDirectories => directory
      .listSync()
      .whereType<Directory>()
      .where((entry) => entry.path.contains('/abc-circuit-output-'))
      .toList();

  void expectSuccessfulHash(int size) {
    expect(stub.metric(0), 1);
    expect(stub.metric(1), (size + _chunkSize - 1) ~/ _chunkSize);
    expect(stub.metric(2), 1);
    expect(stub.metric(3), 1);
    expect(stub.metric(5), size);
    expect(stub.metric(6), size.clamp(0, _chunkSize));
    expect(
      stub.metric(7),
      0,
      reason: 'All chunks reuse the same native buffer.',
    );
    expect(stub.metric(12), 0, reason: 'The create output is initialized.');
    expectReleased();
  }

  void expectReleased() {
    expect(
      stub.metric(4),
      0,
      reason: 'No native SHA-256 context remains live.',
    );
    expect(allocator.live, isEmpty);
    expect(allocator.frees, allocator.allocations.length);
  }

  void dispose() {
    if (session != null) api.dispatch('worldCircuitClose', [session]);
    for (final token in tokens) {
      api.dispatch('worldCircuitReleaseSource', [token]);
    }
    // Keep a failed ownership assertion from leaking actual test allocations.
    allocator.releaseRemaining();
  }
}

class _TrackingAllocator implements Allocator {
  final allocations = <int>[];
  final live = <int>{};
  int frees = 0;
  int peakLive = 0;
  Object? allocateFailure;
  Object? freeFailure;
  void Function()? onAllocate;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    final failure = allocateFailure;
    if (failure != null) throw failure;
    final pointer = calloc.allocate<T>(byteCount, alignment: alignment);
    // Poisoning catches code that assumes an arbitrary Allocator zeroes memory.
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
    final failure = freeFailure;
    if (failure != null) throw failure;
  }

  void releaseRemaining() {
    for (final address in live) {
      calloc.free(Pointer<Void>.fromAddress(address));
    }
    live.clear();
  }
}
