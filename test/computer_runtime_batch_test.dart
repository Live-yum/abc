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
  for (final batched in [false, true]) {
    for (final optimized in [false, true]) {
      test(
        'runtime reads selected monitor after identical input/clock order: batch=$batched mode=$optimized',
        () async {
          final backend = batched ? _BatchBackend() : _DisplayBackend();
          final session = await _open(backend);
          await session.setOptimization(optimized);
          await session.selectComputerDisplay(true);
          backend.commands.clear();
          session.setComputerKey('up', true);
          await _oneRuntimeBatch(session, backend);
          expect(backend.commands.map((c) => c.words[1]), [2, 2, 9]);
          expect(backend.commands[0].words[2], 6516);
          expect(
            backend.commands[1].words,
            ComputerrariaComputer.clock(128).words,
          );
          expect(backend.commands[2].words[2], ComputerrariaComputer.color.x);
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
      'accepted clock survives selected-display failure without replay: batch=$batched',
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

  test('selection waits for fresh pixels and pause/explicit validation/export read both screens', () async {
    final backend = _BatchBackend();
    final session = await _open(backend);
    final previous = session.displayFrames[ComputerrariaComputer.color.name];
    backend.frame++;
    backend.holdPixels = Completer<void>();
    final switchDisplay = session.selectComputerDisplay(true);
    await _until(() => backend.commands.isNotEmpty);
    expect(session.selectedDisplay, ComputerrariaComputer.mono);
    expect(
      session.displayFrames[ComputerrariaComputer.color.name],
      same(previous),
    );
    backend.holdPixels!.complete();
    await switchDisplay;
    backend.holdPixels = null;
    expect(session.selectedDisplay, ComputerrariaComputer.color);
    expect(
      session.displayFrames[ComputerrariaComputer.color.name],
      isNot(same(previous)),
    );
    for (final action in [
      session.pauseAndRefreshDisplays,
      session.refreshComputerDisplays,
    ]) {
      backend.commands.clear();
      await action();
      expect(backend.commands.map((c) => c.words[2]), [6485, 7371]);
    }
    backend.commands.clear();
    await session.command(WorldCircuitCommand.save());
    expect(backend.commands.map((c) => c.words[1]), [9, 9, 6]);
    await session.close();
    session.dispose();
  });
}
