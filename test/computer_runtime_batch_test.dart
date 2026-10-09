import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

import 'support/computer_circuit_backend.dart';

class _DisplayBackend extends ComputerCircuitBackend {
  int frame = 0;
  bool failPixels = false;
  Completer<void>? holdPixels;
  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    final result = await super.commandWorldCircuit(session, command);
    if (command.words[1] == 2 && command.words[2] == 3194) frame++;
    if (command.words[1] == 9) {
      await holdPixels?.future;
      if (failPixels) throw StateError('pixel read failed');
      final data = ByteData.sublistView(result.records);
      for (var at = 12; at < result.records.length; at += 16) {
        data.setUint32(at, frame.isOdd ? 18 : 0, Endian.little);
      }
    }
    return result;
  }
}

class _BatchBackend extends _DisplayBackend
    implements WorldCircuitComputerBackend {
  int batches = 0;
  @override
  Future<WorldCircuitComputerFrame> clockAndReadDisplay(
    int id,
    WorldCircuitCommand clock,
    WorldCircuitCommand pixels,
  ) async {
    batches++;
    final result = await commandWorldCircuit(id, clock);
    try {
      return WorldCircuitComputerFrame(
        clock: result,
        display: await commandWorldCircuit(id, pixels),
      );
    } catch (error) {
      return WorldCircuitComputerFrame(
        clock: result,
        displayError: error.toString(),
      );
    }
  }
}

/// Completes every response after a real event-queue turn, like an RPC owner.
class _EventOwnerBackend extends _BatchBackend
    implements WorldCircuitExternalOwnerBackend {
  @override
  bool get completesComputerBatchFromExternalEvent => true;
  final responseHolds = <int, Completer<void>>{};
  int activeBatches = 0, maximumActiveBatches = 0, replies = 0;
  void Function(int)? onReply;
  @override
  Future<WorldCircuitComputerFrame> clockAndReadDisplay(
    int id,
    WorldCircuitCommand clock,
    WorldCircuitCommand pixels,
  ) async {
    activeBatches++;
    if (activeBatches > maximumActiveBatches) {
      maximumActiveBatches = activeBatches;
    }
    try {
      final frame = await super.clockAndReadDisplay(id, clock, pixels);
      final ordinal = batches;
      await responseHolds[ordinal]?.future;
      await Future<void>.delayed(Duration.zero);
      replies++;
      onReply?.call(ordinal);
      return frame;
    } finally {
      activeBatches--;
    }
  }
}

class _ImmediateGuardBackend extends _BatchBackend {
  void Function()? pauseAfterFirst;
  @override
  Future<WorldCircuitComputerFrame> clockAndReadDisplay(
    int id,
    WorldCircuitCommand clock,
    WorldCircuitCommand pixels,
  ) async {
    // Bound a regression so the test runner cannot hang on microtask starvation.
    if (batches >= 4) throw StateError('Unexpected immediate batch burst');
    if (batches == 0) Timer.run(() => pauseAfterFirst?.call());
    return super.clockAndReadDisplay(id, clock, pixels);
  }
}

Future<WorldCircuitSession> _open(_DisplayBackend backend) async {
  final session = WorldCircuitSession.fromSource(
    backend,
    const WorldCircuitSource.file(
      path: '/fixture/computer.wld',
      length: 405983441,
      name: 'computer.wld',
    ),
  );
  await session.open();
  await session.verifyComputer();
  await session.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
  backend.commands.clear();
  return session;
}

Future<void> _until(bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw StateError('Test condition did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _oneRuntimeBatch(
  WorldCircuitSession session,
  _DisplayBackend backend,
) async {
  backend.holdClock = Completer<void>();
  session.run();
  await _until(
    () => backend.commands.any((c) => c.words[1] == 2 && c.words[2] == 3194),
  );
  session.pause();
  backend.holdClock!.complete();
  await _until(() => !session.busy);
  backend.holdClock = null;
}

void main() {
  test(
    'event owner continues without a per-batch timer and retains input order',
    () async {
      final backend = _EventOwnerBackend();
      final session = await _open(backend);
      backend.onReply = (ordinal) {
        if (ordinal == 1) session.setComputerKey('up', true);
        if (ordinal == 2) {
          session.setComputerKey('up', false);
          session.setComputerKey('down', true);
          session.setComputerKey('down', false);
        }
        if (ordinal == 3) session.pause();
      };
      session.run();
      await _until(() => !session.running && !session.busy);
      expect(backend.batches, 3);
      expect(backend.maximumActiveBatches, 1);
      expect(session.physicalPulses, 384);
      expect(backend.commands.map((c) => (c.words[1], c.words[2])), [
        (2, 3194),
        (9, 6485),
        (2, 6516),
        (2, 3194),
        (9, 6485),
        (2, 6517),
        (2, 3194),
        (9, 6485),
      ]);
      final stages = session.hostStages.snapshot()['stages'] as Map;
      expect((stages['runtime.ownerContinuationGap'] as Map)['count'], 3);
      expect(stages.containsKey('runtime.timerWait'), isFalse);
      await session.close();
      session.dispose();
    },
  );

  test(
    'immediate fake keeps timer fairness and cannot starve a queued pause',
    () async {
      final backend = _ImmediateGuardBackend();
      final session = await _open(backend);
      backend.pauseAfterFirst = session.pause;
      session.run();
      await _until(() => !session.running && !session.busy);
      expect(backend.batches, 1);
      expect(session.physicalPulses, 128);
      expect(session.error, isNull);
      final stages = session.hostStages.snapshot()['stages'] as Map;
      expect(stages.containsKey('runtime.timerWait'), isTrue);
      expect(stages.containsKey('runtime.ownerContinuationGap'), isFalse);
      await session.close();
      session.dispose();
    },
  );

  test(
    'pause and restart replace a draining owner pump exactly once',
    () async {
      final backend = _EventOwnerBackend()
        ..responseHolds[1] = Completer<void>()
        ..responseHolds[2] = Completer<void>();
      final session = await _open(backend);
      session.run();
      await _until(() => backend.batches == 1);
      session.pause();
      session.run();
      session.run();
      backend.responseHolds[1]!.complete();
      await _until(() => backend.batches == 2);
      session.pause();
      backend.responseHolds[2]!.complete();
      await _until(() => !session.busy);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(backend.batches, 2);
      expect(backend.maximumActiveBatches, 1);
      expect(session.physicalPulses, 256);
      await session.close();
      session.dispose();
    },
  );

  for (final operation in ['monitor', 'mode']) {
    test(
      'pause invalidates an owner pump waiting for an earlier $operation operation',
      () async {
        final backend = _EventOwnerBackend();
        final session = await _open(backend);
        backend.holdPixels = Completer<void>();
        final selecting = operation == 'monitor'
            ? session.refreshComputerDisplays()
            : session.setOptimization(true);
        await _until(() => session.busy);
        session.run();
        await Future<void>.delayed(Duration.zero);
        expect(backend.batches, 0);
        session.pause();
        backend.holdPixels!.complete();
        await selecting;
        await Future<void>.delayed(Duration.zero);
        expect(backend.batches, 0);
        expect(session.optimizationEnabled, operation == 'mode');
        backend.holdPixels = null;
        backend.onReply = (_) => session.pause();
        session.run();
        await _until(() => !session.running && !session.busy);
        expect(backend.batches, 1);
        expect(backend.commands.last.words[2], 6485);
        await session.close();
        session.dispose();
      },
    );
  }

  for (final ending in ['close', 'cancel', 'read-error']) {
    test('event owner cannot schedule later clocks after $ending', () async {
      final backend = _EventOwnerBackend()
        ..responseHolds[1] = Completer<void>();
      final session = await _open(backend);
      backend.failPixels = ending == 'read-error';
      session.run();
      await _until(() => backend.batches == 1);
      Future<void>? closing;
      if (ending == 'close') closing = session.close();
      if (ending == 'cancel') await session.cancelOperation();
      backend.responseHolds[1]!.complete();
      if (closing != null) await closing;
      await _until(() => !session.running && !session.busy);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(backend.batches, 1);
      expect(session.physicalPulses, 128);
      expect(session.dirty, isTrue);
      if (ending == 'read-error') {
        expect(session.error.toString(), contains('pixel read failed'));
      }
      await session.close();
      session.dispose();
    });
  }

  for (final batched in [false, true]) {
    for (final optimized in [false, true]) {
      test(
        'runtime reads WLD monitor after identical input/clock order: batch=$batched mode=$optimized',
        () async {
          final backend = batched ? _BatchBackend() : _DisplayBackend();
          final session = await _open(backend);
          await session.setOptimization(optimized);
          await session.refreshComputerDisplays();
          backend.commands.clear();
          session.setComputerKey('up', true);
          await _oneRuntimeBatch(session, backend);
          expect(backend.commands.map((c) => c.words[1]), [2, 2, 9]);
          expect(backend.commands[0].words[2], 6516);
          expect(
            backend.commands[1].words,
            ComputerrariaComputer.clock(128).words,
          );
          expect(backend.commands[2].words[2], ComputerrariaComputer.mono.x);
          expect(session.physicalPulses, 128);
          expect(session.optimizationEnabled, optimized);
          expect(session.dirty, isTrue);
          if (backend is _BatchBackend) expect(backend.batches, 1);
          await session.close();
          session.dispose();
        },
      );
    }

    test(
      'accepted clock survives display failure without replay: batch=$batched',
      () async {
        final backend = batched ? _BatchBackend() : _DisplayBackend();
        final session = await _open(backend);
        backend.failPixels = true;
        await _oneRuntimeBatch(session, backend);
        expect(session.physicalPulses, 128);
        expect(session.dirty, isTrue);
        expect(session.running, isFalse);
        expect(session.error.toString(), contains('pixel read failed'));
        expect(backend.commands.where((c) => c.words[1] == 2).length, 1);
        await session.close();
        session.dispose();
      },
    );
  }

  test('refresh waits for fresh pixels and pause/explicit validation/export read WLD screen', () async {
    final backend = _BatchBackend();
    final session = await _open(backend);
    final previous = session.displayFrames[ComputerrariaComputer.mono.name];
    backend.frame++;
    backend.holdPixels = Completer<void>();
    final switchDisplay = session.refreshComputerDisplays();
    await _until(() => backend.commands.isNotEmpty);
    expect(
      session.displayFrames[ComputerrariaComputer.mono.name],
      same(previous),
    );
    backend.holdPixels!.complete();
    await switchDisplay;
    backend.holdPixels = null;
    expect(
      session.displayFrames[ComputerrariaComputer.mono.name],
      isNot(same(previous)),
    );
    for (final action in [
      session.pauseAndRefreshDisplays,
      session.refreshComputerDisplays,
    ]) {
      backend.commands.clear();
      await action();
      expect(backend.commands.map((c) => c.words[2]), [6485]);
    }
    backend.commands.clear();
    await session.command(WorldCircuitCommand.save());
    expect(backend.commands.map((c) => c.words[1]), [9, 6]);
    await session.close();
    session.dispose();
  });
}
