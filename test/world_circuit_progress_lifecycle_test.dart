import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/circuit_display.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

const _source = WorldCircuitSource.file(
  path: '/fixture/wiring.wld',
  length: 1000,
  name: 'wiring.wld',
);

const _ready = WorldCircuitProgress(
  stage: 'ready',
  phase: 1,
  completed: 1,
  total: 1,
);
const _hash = WorldCircuitProgress(
  stage: 'hash',
  phase: 1,
  completed: 1,
  total: 2,
);

const _region = CircuitDisplayRegion('Selected wiring', 37, 19, 23, 11);

/// Generic source ownership fake. No program loading or sample layout is needed.
class _SourceBackend implements WorldCircuitSourceBackend {
  int opens = 0, closes = 0, cancels = 0;
  Completer<void>? holdOpen;
  final commands = <WorldCircuitCommand>[];
  final released = <String?>[];

  WorldCircuitResult reply(int id, {int kind = 0}) => WorldCircuitResult(
    id,
    List<int>.filled(24, 0)
      ..[0] = 2
      ..[2] = 180
      ..[3] = 140,
    Uint8List(0),
    resultKind: kind,
    reserved: kind == 6 ? 0 : 4,
    worldSource: kind == 6
        ? const WorldCircuitSource.file(
            path: '/output/copy.wld',
            length: 100,
            name: 'copy.wld',
            token: 'wld',
          )
        : null,
  );

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List bytes) async =>
      reply(++opens);

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    final id = ++opens;
    await holdOpen?.future;
    return reply(id);
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    return reply(session, kind: command.words[1]);
  }

  @override
  Future<void> closeWorldCircuit(int session) async {
    closes++;
  }

  @override
  Future<void> cancelWorldCircuitOperation() async {
    cancels++;
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async => null;
  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {
    released.add(source.token);
  }
}

class _LifecycleBackend extends _SourceBackend
    implements WorldCircuitBatchBackend, WorldCircuitIdleCleanupBackend {
  final events = <String>[];
  final progressActiveAtClose = <int>[];
  Completer<void>? holdBatch, holdClose;
  Completer<WorldCircuitProgress?>? holdProgress;
  int batches = 0, polls = 0, activePolls = 0;
  int closeAttempts = 0, cleanupAttempts = 0;
  bool failOpen = false, failClose = false, failCleanup = false;

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    events.add('open:${opens + 1}');
    final result = await super.openWorldCircuitSource(
      world,
      onProgress: onProgress,
    );
    if (failOpen) throw StateError('open failed');
    return result;
  }

  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int session,
    WorldCircuitCommand command,
    WorldCircuitCommand pixels,
  ) async {
    batches++;
    events.add('batch:$session');
    await holdBatch?.future;
    return WorldCircuitBatchResult(
      command: await commandWorldCircuit(session, command),
      pixels: await commandWorldCircuit(session, pixels),
    );
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async {
    polls++;
    activePolls++;
    events.add('poll:$opens');
    try {
      final pending = holdProgress;
      return pending == null ? null : await pending.future;
    } finally {
      activePolls--;
    }
  }

  @override
  Future<void> closeWorldCircuit(int session) async {
    closeAttempts++;
    progressActiveAtClose.add(activePolls);
    events.add('close:$session');
    await holdClose?.future;
    if (failClose) throw StateError('close failed');
    await super.closeWorldCircuit(session);
  }

  @override
  Future<void> cleanupWorldCircuit() async {
    cleanupAttempts++;
    events.add('cleanup');
    if (failCleanup) throw StateError('cleanup failed');
  }
}

void main() {
  for (final duringProgress in [false, true]) {
    testWidgets(
      'cancel reset during ${duringProgress ? 'progress drain' : 'close ACK'} '
      'finishes teardown without reopening',
      (tester) async {
        final backend = _LifecycleBackend();
        final session = WorldCircuitSession.fromSource(backend, _source);
        await session.open();
        await session.readDisplay(_region);
        final saved = await session.command(WorldCircuitCommand.save());
        expect(saved.worldSource, isNotNull);
        backend.holdBatch = Completer<void>();
        backend.holdProgress = Completer<WorldCircuitProgress?>();
        backend.holdClose = Completer<void>();
        final stepping = session.command(
          WorldCircuitCommand.ticks(6),
          refreshViewport: true,
        );
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 250));
        expect(backend.activePolls, 1);
        final resetting = expectLater(
          session.reset(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'cancel message',
              contains('已取消'),
            ),
          ),
        );
        backend.holdBatch!.complete();
        await tester.pump();
        expect(backend.closeAttempts, 0);
        if (duringProgress) await session.cancelOperation();
        backend.holdProgress!.complete(_ready);
        await tester.pump();
        await stepping;
        expect(backend.closeAttempts, 1);
        expect(backend.opens, 1);
        if (!duringProgress) await session.cancelOperation();
        backend.holdClose!.complete();
        await tester.pump();
        await resetting;
        expect(backend.closes, 1);
        expect(
          backend.opens,
          1,
          reason: 'Cancellation cannot create a new owner.',
        );
        expect(session.result, isNull);
        expect(session.progress, isNull);
        expect(session.running, isFalse);
        expect(session.displayRegion, isNull);
        expect(session.displayFrame, isNull);
        expect(session.displayPixelCount, 0);
        expect(session.dirty, isFalse);
        expect(session.source, same(_source));
        expect(
          backend.released,
          isEmpty,
          reason: 'Independent outputs survive reset.',
        );

        // The drained session remains recoverable by either retry or close.
        if (duringProgress) {
          await session.reset();
          expect(backend.opens, 2);
          expect(session.error, isNull);
        }
        await session.close();
        await session.close();
        expect(backend.released, isEmpty);
        session.dispose();
      },
    );
  }

  testWidgets(
    'reset drains the accepted batch and progress before close and new hash',
    (tester) async {
      final backend = _LifecycleBackend();
      final session = WorldCircuitSession.fromSource(backend, _source);
      await session.open();
      await session.readDisplay(_region);
      backend.events.clear();
      backend.holdBatch = Completer<void>();
      backend.holdProgress = Completer<WorldCircuitProgress?>();
      backend.holdClose = Completer<void>();
      backend.holdOpen = Completer<void>();
      final published = <String?>[];
      session.addListener(() => published.add(session.progress?.stage));

      final stepping = session.command(
        WorldCircuitCommand.ticks(6),
        refreshViewport: true,
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(backend.batches, 1);
      await tester.pump(const Duration(milliseconds: 250));
      expect(backend.activePolls, 1);

      final resetting = session.reset();
      await tester.pump();
      expect(session.running, isFalse);
      expect(backend.closeAttempts, 0);
      backend.holdBatch!.complete();
      await tester.pump();
      expect(session.busy, isTrue);
      expect(backend.closeAttempts, 0);
      expect(backend.opens, 1);

      backend.holdProgress!.complete(_ready);
      await tester.pump();
      await stepping;
      expect(backend.progressActiveAtClose, [0]);
      expect(backend.opens, 1);
      expect(published, isNot(contains('ready')));
      await tester.pump(const Duration(seconds: 1));
      expect(backend.polls, 1, reason: 'No polls may start during teardown');

      backend.holdProgress = Completer<WorldCircuitProgress?>();
      backend.holdClose!.complete();
      await tester.pump();
      expect(backend.opens, 2);
      expect(session.progress, isNull);
      await tester.pump(const Duration(milliseconds: 250));
      expect(backend.events, [
        'batch:1',
        'poll:1',
        'close:1',
        'open:2',
        'poll:2',
      ]);
      backend.holdProgress!.complete(_hash);
      await tester.pump();
      expect(session.progress?.stage, 'hash');
      backend.holdOpen!.complete();
      await tester.pump();
      await resetting;
      expect(session.result!.session, 2);
      expect(backend.batches, 1);
      expect(published, isNot(contains('ready')));
      await session.close();
      session.dispose();
    },
  );

  for (final pollError in [
    StateError('progress rejected'),
    TimeoutException('progress timed out'),
  ]) {
    testWidgets(
      'serial completion drains failed progress without replacing its result: '
      '${pollError.runtimeType}',
      (tester) async {
        final backend = _LifecycleBackend()
          ..holdOpen = Completer<void>()
          ..holdProgress = Completer<WorldCircuitProgress?>();
        final session = WorldCircuitSession.fromSource(backend, _source);
        var finished = false;
        final opening = session.open().then((_) => finished = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(backend.activePolls, 1);
        backend.holdOpen!.complete();
        await tester.pump();
        expect(finished, isFalse);
        expect(session.busy, isTrue);
        backend.holdProgress!.completeError(pollError);
        await tester.pump();
        await opening;
        expect(session.busy, isFalse);
        expect(session.error, isNull);
        expect(session.result!.session, 1);
        await session.close();
        expect(backend.progressActiveAtClose, [0]);
        session.dispose();
      },
    );
  }

  testWidgets('close invalidates and drains progress before closing', (
    tester,
  ) async {
    final backend = _LifecycleBackend()
      ..holdOpen = Completer<void>()
      ..holdProgress = Completer<WorldCircuitProgress?>();
    final session = WorldCircuitSession.fromSource(backend, _source);
    final opening = session.open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final closing = session.close();
    backend.holdOpen!.complete();
    await tester.pump();
    expect(backend.closeAttempts, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(backend.polls, 1);
    backend.holdProgress!.complete(_ready);
    await tester.pump();
    await opening;
    await closing;
    expect(session.progress, isNull);
    expect(backend.progressActiveAtClose, [0]);
    expect(backend.closes, 1);
    session.dispose();
  });

  for (final cancelled in [false, true]) {
    testWidgets(
      '${cancelled ? 'cancelled' : 'failed'} open cleanup drains progress and '
      'retries without releasing exports',
      (tester) async {
        final backend = _LifecycleBackend()
          ..failOpen = !cancelled
          ..failCleanup = true
          ..holdOpen = Completer<void>()
          ..holdProgress = Completer<WorldCircuitProgress?>();
        final session = WorldCircuitSession.fromSource(backend, _source);
        final opening = expectLater(session.open(), throwsStateError);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        if (!cancelled) {
          backend.holdOpen!.complete();
          await tester.pump();
        }
        final closing = expectLater(session.close(), throwsStateError);
        await tester.pump();
        expect(backend.cleanupAttempts, 0);
        expect(backend.closeAttempts, 0);
        if (cancelled) {
          expect(backend.cancels, 1);
          backend.holdOpen!.completeError(StateError('open cancelled'));
          await tester.pump();
          expect(backend.cleanupAttempts, 0);
        }
        backend.holdProgress!.complete(_ready);
        await tester.pump();
        await opening;
        await closing;
        expect(backend.cleanupAttempts, 1);
        expect(session.result, isNull);
        expect(session.progress, isNull);
        expect(session.error.toString(), contains('cleanup failed'));
        await expectLater(
          session.command(WorldCircuitCommand.ticks(1)),
          throwsStateError,
        );
        await expectLater(session.open(), throwsStateError);
        expect(backend.commands, isEmpty);
        backend.failCleanup = false;
        await session.close();
        await session.close();
        expect(backend.cleanupAttempts, 2);
        expect(backend.released, isEmpty);
        session.dispose();
      },
    );
  }

  for (final reset in [false, true]) {
    test(
      'failed ${reset ? 'reset close' : 'close'} blocks commands until retry',
      () async {
        final backend = _LifecycleBackend();
        final session = WorldCircuitSession.fromSource(backend, _source);
        await session.open();
        final saved = await session.command(WorldCircuitCommand.save());
        expect(saved.worldSource, isNotNull);
        final commands = backend.commands.length;
        backend.failClose = true;
        await expectLater(
          reset ? session.reset() : session.close(),
          throwsStateError,
        );
        expect(session.result!.session, 1);
        expect(backend.opens, 1);
        await expectLater(
          session.command(WorldCircuitCommand.ticks(1)),
          throwsStateError,
        );
        session.run();
        expect(session.running, isFalse);
        expect(backend.commands.length, commands);
        backend.failClose = false;
        await session.close();
        expect(backend.closeAttempts, 2);
        expect(backend.closes, 1);
        expect(backend.released, isEmpty);
        session.dispose();
      },
    );
  }
}
