import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/circuit_display.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

const _region = CircuitDisplayRegion('Selected wiring', 37, 19, 23, 11);

/// Protocol fake for an arbitrary small world; no sample CPU layout or program.
class _DisplayBackend implements WorldCircuitSourceBackend {
  int frame = 0, opens = 0, closes = 0, cancels = 0, ticks = 0;
  bool optimized = false, failPixels = false;
  Completer<void>? holdPixels, holdMutation;
  final commands = <WorldCircuitCommand>[];

  List<int> get stats => List<int>.filled(24, 0)
    ..[0] = 2
    ..[2] = 180
    ..[3] = 140
    ..[18] = ticks;

  WorldCircuitResult reply(int id, {int kind = 0, Uint8List? records}) =>
      WorldCircuitResult(
        id,
        stats,
        records ?? Uint8List(0),
        resultKind: kind,
        resultCount: (records?.length ?? 0) ~/ 16,
        reserved: 4 | (optimized ? 10 : 0),
      );

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List bytes) async =>
      reply(++opens);

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async => reply(++opens);

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int id,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    final kind = command.words[1];
    if (kind == 2 || kind == 3) {
      await holdMutation?.future;
      frame++;
      if (kind == 3) ticks += command.words[8];
    }
    if (kind == 10) optimized = command.words[7] == 1;
    if (kind != 9) return reply(id, kind: kind);
    await holdPixels?.future;
    if (failPixels) throw StateError('pixel read failed');
    // A sparse actual PixelBox at the selected rectangle's bottom-right corner.
    final records = Uint8List(16);
    final data = ByteData.sublistView(records);
    data.setUint32(0, command.words[2] + command.words[4] - 1, Endian.little);
    data.setUint32(4, command.words[3] + command.words[5] - 1, Endian.little);
    data.setUint32(8, 445, Endian.little);
    data.setUint32(12, frame.isOdd ? 18 : 0, Endian.little);
    return reply(id, kind: kind, records: records);
  }

  @override
  Future<void> closeWorldCircuit(int id) async {
    closes++;
  }

  @override
  Future<void> cancelWorldCircuitOperation() async {
    cancels++;
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async => null;
  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {}
}

class _BatchBackend extends _DisplayBackend
    implements WorldCircuitBatchBackend {
  int batches = 0;
  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int id,
    WorldCircuitCommand command,
    WorldCircuitCommand pixels,
  ) async {
    batches++;
    final result = await commandWorldCircuit(id, command);
    try {
      return WorldCircuitBatchResult(
        command: result,
        pixels: await commandWorldCircuit(id, pixels),
      );
    } catch (error) {
      return WorldCircuitBatchResult(
        command: result,
        readError: error.toString(),
      );
    }
  }
}

/// Replies after an actual event turn, as a worker owner would.
class _EventOwnerBackend extends _BatchBackend
    implements WorldCircuitExternalOwnerBackend {
  @override
  bool get completesCircuitBatchFromExternalEvent => true;
  final responseHolds = <int, Completer<void>>{};
  int activeBatches = 0, maximumActiveBatches = 0;
  void Function(int)? onReply;
  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int id,
    WorldCircuitCommand command,
    WorldCircuitCommand pixels,
  ) async {
    activeBatches++;
    if (activeBatches > maximumActiveBatches) {
      maximumActiveBatches = activeBatches;
    }
    try {
      final result = await super.commandAndReadPixels(id, command, pixels);
      final ordinal = batches;
      await responseHolds[ordinal]?.future;
      await Future<void>.delayed(Duration.zero);
      onReply?.call(ordinal);
      return result;
    } finally {
      activeBatches--;
    }
  }
}

class _ImmediateGuardBackend extends _BatchBackend {
  void Function()? pauseAfterFirst;
  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int id,
    WorldCircuitCommand command,
    WorldCircuitCommand pixels,
  ) async {
    if (batches >= 4) throw StateError('Unexpected immediate batch burst');
    if (batches == 0) Timer.run(() => pauseAfterFirst?.call());
    return super.commandAndReadPixels(id, command, pixels);
  }
}

Future<WorldCircuitSession> _open(_DisplayBackend backend) async {
  final session = WorldCircuitSession.fromSource(
    backend,
    const WorldCircuitSource.file(
      path: '/fixture/wiring.wld',
      length: 1000,
      name: 'wiring.wld',
    ),
  );
  await session.open();
  await session.readDisplay(_region);
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
  backend.holdMutation = Completer<void>();
  session.run();
  await _until(() => backend.commands.any((c) => c.words[1] == 3));
  session.pause();
  backend.holdMutation!.complete();
  await _until(() => !session.busy);
  backend.holdMutation = null;
}

void main() {
  test(
    'event owner keeps generic tick batches and queued triggers ordered',
    () async {
      final backend = _EventOwnerBackend();
      final session = await _open(backend);
      final inputs = <Future<WorldCircuitResult>>[];
      backend.onReply = (ordinal) {
        if (ordinal == 1) {
          inputs.add(session.command(WorldCircuitCommand.trigger(17, 29)));
        }
        if (ordinal == 2) {
          inputs.add(session.command(WorldCircuitCommand.trigger(19, 31)));
          inputs.add(session.command(WorldCircuitCommand.trigger(21, 33)));
        }
        if (ordinal == 3) session.pause();
      };
      session.run();
      await _until(() => !session.running && !session.busy);
      await Future.wait(inputs);
      expect(backend.batches, 3);
      expect(backend.maximumActiveBatches, 1);
      expect(backend.ticks, 18);
      expect(backend.commands.map((c) => (c.words[1], c.words[2])), [
        (3, 0),
        (9, 37),
        (2, 17),
        (3, 0),
        (9, 37),
        (2, 19),
        (2, 21),
        (3, 0),
        (9, 37),
      ]);
      await session.close();
      session.dispose();
    },
  );

  test(
    'immediate owner yields to a queued pause without a batch burst',
    () async {
      final backend = _ImmediateGuardBackend();
      final session = await _open(backend);
      backend.pauseAfterFirst = session.pause;
      session.run();
      await _until(() => !session.running && !session.busy);
      expect(backend.batches, 1);
      expect(backend.ticks, 6);
      expect(session.error, isNull);
      await session.close();
      session.dispose();
    },
  );

  test('pause and restart never overlap a draining owner batch', () async {
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
    expect(backend.ticks, 12);
    await session.close();
    session.dispose();
  });

  for (final operation in ['display', 'mode']) {
    test(
      'pause invalidates runtime waiting for an earlier $operation',
      () async {
        final backend = _EventOwnerBackend();
        final session = await _open(backend);
        backend.holdPixels = Completer<void>();
        final selecting = operation == 'display'
            ? session.refreshDisplay()
            : session.setOptimization(true);
        await _until(() => session.busy);
        session.run();
        await Future<void>.delayed(const Duration(milliseconds: 110));
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
        expect(backend.commands.last.words, _region.command.words);
        await session.close();
        session.dispose();
      },
    );
  }

  for (final ending in ['close', 'cancel', 'read-error']) {
    test('no later ticks are scheduled after $ending', () async {
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
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(backend.batches, 1);
      expect(backend.ticks, 6);
      expect(session.dirty, isTrue);
      if (ending == 'cancel') expect(backend.cancels, 1);
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
        'selected pixels follow generic ticks: batch=$batched mode=$optimized',
        () async {
          final backend = batched ? _BatchBackend() : _DisplayBackend();
          final session = await _open(backend);
          await session.setOptimization(optimized);
          backend.commands.clear();
          await session.command(WorldCircuitCommand.trigger(17, 29, mask: 4));
          await _oneRuntimeBatch(session, backend);
          expect(backend.commands.map((c) => c.words[1]), [2, 3, 9]);
          expect(backend.commands[0].words[2], 17);
          expect(backend.commands[1].words, WorldCircuitCommand.ticks(6).words);
          expect(backend.commands[2].words, _region.command.words);
          expect(backend.ticks, 6);
          expect(session.optimizationEnabled, optimized);
          expect(session.dirty, isTrue);
          expect(session.displayPixelCount, 1);
          if (backend is _BatchBackend) expect(backend.batches, 1);
          await session.close();
          session.dispose();
        },
      );
    }

    for (final mutation in [
      WorldCircuitCommand.ticks(6),
      WorldCircuitCommand.trigger(43, 52, mask: 2),
    ]) {
      test(
        'accepted kind ${mutation.words[1]} survives read failure: batch=$batched',
        () async {
          final backend = batched ? _BatchBackend() : _DisplayBackend();
          final session = await _open(backend);
          backend.failPixels = true;
          await expectLater(
            session.command(mutation, refreshViewport: true),
            throwsStateError,
          );
          expect(session.result!.resultKind, mutation.words[1]);
          expect(session.dirty, isTrue);
          expect(session.running, isFalse);
          expect(session.error.toString(), contains('pixel read failed'));
          expect(backend.commands.where((c) => c.mutates).length, 1);
          await session.close();
          session.dispose();
        },
      );
    }
  }

  test(
    'an imported world runs without a program or selected PixelBox region',
    () async {
      final backend = _BatchBackend();
      final session = WorldCircuitSession(backend, Uint8List.fromList([1]));
      await session.open();
      await _oneRuntimeBatch(session, backend);
      expect(backend.commands.map((c) => c.words[1]), [3]);
      expect(backend.batches, 0);
      expect(backend.ticks, 6);
      expect(session.displayRegion, isNull);
      expect(session.displayFrame, isNull);
      expect(session.dirty, isTrue);
      await session.close();
      session.dispose();
    },
  );

  test(
    'refresh preserves the previous frame until the fresh read completes',
    () async {
      final backend = _BatchBackend();
      final session = await _open(backend);
      final previous = session.displayFrame;
      backend.frame++;
      backend.holdPixels = Completer<void>();
      final refreshing = session.refreshDisplay();
      await _until(() => backend.commands.isNotEmpty);
      expect(session.displayFrame, same(previous));
      backend.holdPixels!.complete();
      await refreshing;
      backend.holdPixels = null;
      expect(session.displayFrame, isNot(same(previous)));
      expect(session.displayFrame!.length, _region.width * _region.height * 4);
      expect(session.displayFrame!.sublist(0, 4), [0, 0, 0, 0]);
      expect(session.displayFrame!.sublist(session.displayFrame!.length - 4), [
        255,
        255,
        255,
        255,
      ]);
      backend.commands.clear();
      session.pause();
      await session.refreshDisplay();
      expect(backend.commands.map((c) => c.words[1]), [9]);
      backend.commands.clear();
      await session.command(WorldCircuitCommand.save());
      expect(backend.commands.map((c) => c.words[1]), [6]);
      await session.close();
      session.dispose();
    },
  );
}
