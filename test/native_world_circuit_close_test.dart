import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

void main() {
  group('native circuit close recovery', () {
    late Directory build;
    late _Stub stub;
    setUpAll(() async {
      build = await Directory.systemTemp.createTemp('abc-close-contract-');
      final path = '${build.path}/close.so';
      final result = await Process.run('cc', [
        '-std=c11',
        '-O2',
        '-Wall',
        '-Wextra',
        '-Werror',
        '-Wno-unused-parameter',
        '-shared',
        '-fPIC',
        'test/native_world_circuit_close_fixture.c',
        '-o',
        path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      stub = _Stub(DynamicLibrary.open(path));
    });
    tearDownAll(() => build.delete(recursive: true));

    for (final streamed in [false, true]) {
      test(
        'world close retry retains its owner (streamed: $streamed)',
        () async {
          await _withFixture(stub, streamed, (fixture) async {
            stub.configure(worldFailures: 1);
            await fixture.open();
            expect(fixture.close, throwsA(_status(-91)));
            expect(stub.metric(0), 1);
            expect(stub.metric(1), 1);
            expect(
              stub.metric(2),
              1,
              reason: 'The native world remains owned.',
            );
            expect(stub.metric(3), 0);
            fixture.expectFilesClosed();
            expect(fixture.io.sessionDirectory!.existsSync(), isFalse);
            fixture.expectClosingRejectsCommands();
            await expectLater(
              fixture.open(),
              throwsA(_message('Close the existing')),
            );
            fixture.close();
            expect(
              stub.metric(0),
              1,
              reason: 'Do not repeat a successful circuit close.',
            );
            expect(stub.metric(1), 2);
            fixture.expectReleased();
          });
        },
      );

      test(
        'circuit failure retains all dependencies (streamed: $streamed)',
        () async {
          await _withFixture(stub, streamed, (fixture) async {
            stub.configure(circuitFailures: 1);
            await fixture.open();
            expect(fixture.close, throwsA(_status(-81)));
            expect(
              stub.metric(1),
              0,
              reason: 'Do not close a world still used by its circuit.',
            );
            expect(stub.metric(2), 1);
            expect(stub.metric(3), 1);
            expect(
              fixture.io.handles.every((handle) => handle.closeCalls == 0),
              isTrue,
            );
            fixture.expectClosingRejectsCommands();
            fixture.close();
            expect(stub.metric(0), 2);
            expect(stub.metric(1), 1);
            fixture.expectReleased();
          });
        },
      );

      test(
        'repeated completed close never double-closes (streamed: $streamed)',
        () async {
          await _withFixture(stub, streamed, (fixture) async {
            await fixture.open();
            final id = fixture.session;
            fixture.close();
            expect(
              () => fixture.api.dispatch('worldCircuitClose', [id]),
              throwsA(_message('Circuit session is closed')),
            );
            expect(stub.metric(0), 1);
            expect(stub.metric(1), 1);
            expect(stub.metric(6), 0);
            await fixture.open();
            fixture.close();
            expect(stub.metric(0), 2);
            expect(stub.metric(1), 2);
            fixture.expectReleased();
          });
        },
      );

      test(
        'scratch close failure retries only the failed file (streamed: $streamed)',
        () async {
          await _withFixture(stub, streamed, (fixture) async {
            await fixture.open();
            final failed = fixture.io.handles.firstWhere(
              (file) => file.path.endsWith('/2'),
            );
            failed.failures = 1;
            expect(fixture.close, throwsA(same(failed.failure)));
            expect(stub.metric(0), 1);
            expect(stub.metric(1), 1);
            expect(stub.metric(2), 0);
            expect(failed.closed, isFalse);
            expect(
              fixture.io.handles
                  .where((file) => file != failed)
                  .every((file) => file.closed && file.closeCalls == 1),
              isTrue,
              reason: 'One file failure must not prevent closing later files.',
            );
            expect(fixture.io.sessionDirectory!.existsSync(), isTrue);
            fixture.expectClosingRejectsCommands();
            fixture.close();
            expect(failed.closeCalls, 2);
            expect(stub.metric(0), 1);
            expect(
              stub.metric(1),
              1,
              reason: 'The world already closed successfully.',
            );
            expect(fixture.io.sessionDirectory!.existsSync(), isFalse);
            fixture.expectReleased();
          });
        },
      );
    }

    test('multiple world failures keep the same retry boundary', () async {
      await _withFixture(stub, true, (fixture) async {
        stub.configure(worldFailures: 2);
        await fixture.open();
        for (var attempt = 1; attempt <= 2; attempt++) {
          expect(fixture.close, throwsA(_status(-91)));
          expect(stub.metric(0), 1);
          expect(stub.metric(1), attempt);
          expect(stub.metric(2), 1);
          fixture.expectFilesClosed();
        }
        fixture.close();
        expect(stub.metric(1), 3);
        expect(
          fixture.io.handles.every((file) => file.closeCalls == 1),
          isTrue,
        );
        fixture.expectReleased();
      });
    });

    for (final worldFailure in [false, true]) {
      test('original file close is retried and primary error is preserved '
          '(world failure: $worldFailure)', () async {
        await _withFixture(stub, true, (fixture) async {
          stub.configure(worldFailures: worldFailure ? 1 : 0);
          await fixture.open();
          final source = fixture.io.handles.singleWhere(
            (file) => file.path == fixture.source.path,
          );
          source.failures = 1;
          expect(
            fixture.close,
            throwsA(worldFailure ? _status(-91) : same(source.failure)),
          );
          expect(source.closed, isFalse);
          expect(
            fixture.io.handles
                .where((file) => file != source)
                .every((file) => file.closed && file.closeCalls == 1),
            isTrue,
          );
          fixture.close();
          expect(source.closeCalls, 2);
          expect(stub.metric(0), 1);
          expect(stub.metric(1), worldFailure ? 2 : 1);
          expect(fixture.source.readAsBytesSync(), [1, 2, 3]);
          fixture.expectReleased();
        });
      });
    }

    test('directory deletion can retry after all owners have closed', () async {
      await _withFixture(stub, true, (fixture) async {
        await fixture.open();
        fixture.io.deleteFailures = 1;
        expect(fixture.close, throwsA(same(fixture.io.deleteFailure)));
        fixture.expectFilesClosed();
        expect(stub.metric(2), 0);
        expect(stub.metric(3), 0);
        expect(fixture.io.sessionDirectory!.existsSync(), isTrue);
        fixture.close();
        expect(fixture.io.deleteCalls, 2);
        expect(stub.metric(0), 1);
        expect(stub.metric(1), 1);
        expect(
          fixture.io.handles.every((file) => file.closeCalls == 1),
          isTrue,
        );
        fixture.expectReleased();
      });
    });

    test(
      'published output lease survives close failure and closes on release',
      () async {
        await _withFixture(stub, true, (fixture) async {
          stub.configure(worldFailures: 1);
          await fixture.open();
          final command = WorldCircuitCommand.save();
          final result = await (fixture.api.dispatch('worldCircuitCommand', [
            fixture.session,
            command.words,
            command.records,
          ]) as Future<Map<String, Object?>>);
          final lease = result['worldSource'] as Map;
          final file = fixture.realFile(lease['path'] as String);
          fixture.tokens.add(lease['token'] as String);
          expect(file.readAsBytesSync(), [97, 98, 99]);
          expect(fixture.close, throwsA(_status(-91)));
          expect(file.existsSync(), isTrue);
          fixture.close();
          expect(
            file.existsSync(),
            isTrue,
            reason: 'Session close does not revoke a published lease.',
          );
          fixture.api.dispatch('worldCircuitReleaseSource', [lease['token']]);
          expect(file.existsSync(), isFalse);
          fixture.api.dispatch('worldCircuitReleaseSource', [lease['token']]);
          fixture.expectReleased();
        });
      },
    );
  }, skip: !Platform.isLinux);
}

Matcher _status(int status) => isA<EngineException>().having(
  (error) => error.code,
  'native status',
  status,
);
Matcher _message(String message) => isA<EngineException>().having(
  (error) => error.message,
  'diagnostic',
  contains(message),
);

Future<void> _withFixture(
  _Stub stub,
  bool streamed,
  Future<void> Function(_Fixture) body,
) async {
  final directory = await Directory.systemTemp.createTemp('abc-close-case-');
  final fixture = _Fixture(stub, streamed, directory);
  stub.configure();
  fixture.source.writeAsBytesSync([1, 2, 3]);
  try {
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
        'close_test_metric',
      );
  late final _configure = library
      .lookupFunction<Void Function(Uint32, Uint32), void Function(int, int)>(
        'close_test_configure',
      );
  _Stub(this.library);
  void configure({int circuitFailures = 0, int worldFailures = 0}) =>
      _configure(circuitFailures, worldFailures);
}

class _Fixture {
  final _Stub stub;
  final bool streamed;
  final Directory directory;
  late final io = _CloseOverrides(directory);
  late final api = NativeWorldCircuitBindings(stub.library);
  late final source = File('${directory.path}/source.wld');
  final tokens = <String>[];
  int? session;
  _Fixture(this.stub, this.streamed, this.directory);
  File realFile(String path) => io.realFile(path);
  Future<void> open() async {
    final result = await Future<Object?>.value(
      streamed
          ? api.dispatch('worldCircuitOpenSource', [
              {'path': source.path, 'length': 3, 'name': 'source.wld'},
            ])
          : api.dispatch('worldCircuitOpen', [
              Uint8List.fromList([1, 2, 3]),
            ]),
    ) as Map;
    session = result['session'] as int;
  }

  void close() {
    api.dispatch('worldCircuitClose', [session]);
    session = null;
  }

  void expectClosingRejectsCommands() {
    final calls = stub.metric(4);
    final command = WorldCircuitCommand.viewport(0, 0, 1, 1);
    expect(
      () => api.dispatch('worldCircuitCommand', [
        session,
        command.words,
        command.records,
      ]),
      throwsA(_message('Circuit session is closing')),
    );
    expect(stub.metric(4), calls);
  }

  void expectFilesClosed() =>
      expect(io.handles.every((file) => file.closed), isTrue);
  void expectReleased() {
    expect(stub.metric(2), 0);
    expect(stub.metric(3), 0);
    expect(
      stub.metric(6),
      0,
      reason: 'No successful native close was repeated.',
    );
    expectFilesClosed();
  }

  void dispose() {
    // Do not let a failed contract assertion leak real operating-system files.
    for (final handle in io.handles) {
      handle.failures = 0;
    }
    io.deleteFailures = 0;
    if (session != null) {
      try {
        close();
      } catch (_) {}
    }
    for (final token in tokens) {
      api.dispatch('worldCircuitReleaseSource', [token]);
    }
    for (final handle in io.handles) {
      if (!handle.closed) handle.delegate.closeSync();
    }
    if (stub.metric(3) != 0) {
      stub.library.lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'abc_world_circuit_close',
      )(7);
    }
    if (stub.metric(2) != 0) {
      stub.library.lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'abc_world_close',
      )(1);
    }
  }
}

final class _CloseOverrides extends IOOverrides {
  final Directory directory;
  final handles = <_CloseHandle>[];
  Directory? sessionDirectory;
  int deleteFailures = 0, deleteCalls = 0;
  final deleteFailure = const FileSystemException(
    'injected temporary-directory deletion failure',
  );
  _CloseOverrides(this.directory);
  File realFile(String path) => super.createFile(path);
  @override
  File createFile(String path) => _CloseFile(super.createFile(path), this);
  @override
  Directory getSystemTempDirectory() => _CloseDirectory(directory, this);
}

class _CloseDirectory implements Directory {
  final Directory delegate;
  final _CloseOverrides io;
  _CloseDirectory(this.delegate, this.io);
  @override
  String get path => delegate.path;
  @override
  Directory createTempSync([String? prefix]) {
    final result = delegate.createTempSync(prefix);
    if (prefix == 'abc-circuit-') io.sessionDirectory = result;
    return _CloseDirectory(result, io);
  }

  @override
  bool existsSync() => delegate.existsSync();
  @override
  void deleteSync({bool recursive = false}) {
    if (path == io.sessionDirectory?.path) {
      io.deleteCalls++;
      if (io.deleteFailures > 0) {
        io.deleteFailures--;
        throw io.deleteFailure;
      }
    }
    delegate.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CloseFile implements File {
  final File delegate;
  final _CloseOverrides io;
  _CloseFile(this.delegate, this.io);
  @override
  String get path => delegate.path;
  @override
  FileStat statSync() => delegate.statSync();
  @override
  int lengthSync() => delegate.lengthSync();
  @override
  File renameSync(String path) => _CloseFile(delegate.renameSync(path), io);
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    final handle = _CloseHandle(delegate.openSync(mode: mode));
    io.handles.add(handle);
    return handle;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CloseHandle implements RandomAccessFile {
  final RandomAccessFile delegate;
  int closeCalls = 0, failures = 0;
  bool closed = false;
  final failure = const FileSystemException('injected file close failure');
  _CloseHandle(this.delegate);
  @override
  String get path => delegate.path;
  @override
  void closeSync() {
    closeCalls++;
    if (failures > 0) {
      failures--;
      throw failure;
    }
    delegate.closeSync();
    closed = true;
  }

  @override
  Uint8List readSync(int length) => delegate.readSync(length);
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
  void flushSync() => delegate.flushSync();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
