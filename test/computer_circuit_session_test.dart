import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';
import 'package:terraforge/domain/computer_provenance.dart';

import 'support/computer_circuit_backend.dart';

const source = WorldCircuitSource.file(
  path: '/fixture/computer.wld',
  length: 405983441,
  name: 'arbitrary.wld',
);

void main() {
  test(
    'timing observes commands without changing physical and full-display order',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      await session.verifyComputer();
      await session.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
      backend.commands.clear();
      session.hostStages.reset();
      await session.stepComputer(128);
      expect(backend.commands.map((c) => c.words[1]), [2, 9, 9]);
      expect(backend.commands.first.words[8], 128);
      expect(session.displayFrames.length, 2);
      final stages = session.hostStages.snapshot()['stages'] as Map;
      for (final key in ['physical.command', 'mono.query', 'color.query']) {
        expect((stages[key] as Map)['count'], 1);
      }
      expect((stages['display.rgbaDecode'] as Map)['count'], 2);
      expect((stages['display.listEquals'] as Map)['count'], 2);
      await session.close();
      session.dispose();
    },
  );

  test('registered derived pair restores ROM metadata without reset and clears a longer tail later', () async {
    final backend = ComputerCircuitBackend()
      ..digest = ComputerCircuitBackend.savedWldSha
      ..twldDigest = ComputerCircuitBackend.savedTwldSha;
    final session = WorldCircuitSession.fromSource(backend, source);
    await session.open();
    final provenance = ComputerProvenanceRecord(
      wldSha256: backend.digest,
      twldSha256: backend.twldDigest,
      programName: 'long.bin',
      programImage: Uint8List.fromList([1, 0, 0, 0, 1, 0, 0, 0]),
      physicalPulses: 5120,
    );
    expect(await session.verifyComputer(provenance: provenance), isTrue);
    expect(backend.commands.where((c) => c.mutates), isEmpty);
    expect(session.programName, 'long.bin');
    expect(session.physicalPulses, 5120);
    expect(session.canRunComputer, isTrue);
    await session.loadProgram('short.bin', Uint8List.fromList([1, 0, 0, 0]));
    expect(backend.commands.singleWhere((c) => c.words[1] == 5).records, [
      2855,
      1236,
      0,
      0,
    ]);
    await session.close();
    session.dispose();
  });

  test(
    'a registered WLD with a different TWLD never enables fixed controls',
    () async {
      final backend = ComputerCircuitBackend()
        ..digest = ComputerCircuitBackend.savedWldSha;
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      expect(
        await session.verifyComputer(
          provenance: ComputerProvenanceRecord(
            wldSha256: backend.digest,
            twldSha256: ComputerCircuitBackend.savedTwldSha,
            programName: null,
            programImage: Uint8List(0),
          ),
        ),
        isFalse,
      );
      expect(backend.commands, isEmpty);
      await session.close();
      session.dispose();
    },
  );

  test('optimization defaults off and drains clock before preserving state on switch', () async {
    final backend = ComputerCircuitBackend();
    final session = WorldCircuitSession.fromSource(backend, source);
    await session.open();
    await session.verifyComputer();
    await session.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
    expect(session.optimizationEnabled, isFalse);
    final before = Map.of(session.displayFrames);
    backend.holdClock = Completer<void>();
    session.run();
    while (!backend.commands.any(
      (c) => c.words[1] == 2 && c.words[2] == 3194,
    )) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    session.setComputerKey('up', true);
    final mode = session.setOptimization(true);
    expect(session.running, isFalse);
    expect(backend.commands.where((c) => c.words[1] == 10), isEmpty);
    backend.holdClock!.complete();
    await mode;
    expect(session.optimizationEnabled, isTrue);
    expect(session.programName, 'p.bin');
    expect(session.canRunComputer, isTrue);
    expect(session.heldKeys, {'up'});
    expect(session.displayFrames, before);
    expect(session.physicalPulses, 128);
    expect(backend.opens, 1);
    expect(backend.closes, 0);
    await session.close();
    session.dispose();
  });

  test(
    'held keys coalesce actual sensor pulses and release never pulses',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      await session.verifyComputer();
      await session.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
      for (var i = 0; i < 100; i++) {
        session.setComputerKey('up', true);
      }
      await session.stepComputer();
      var keys = backend.commands
          .where((c) => c.words[1] == 2 && c.words[2] == 6516)
          .toList();
      expect(keys.length, 1);
      expect(keys.single.words[3], 851);
      expect(keys.single.words[7], 9);
      expect(keys.single.words[12], 0);
      await session.stepComputer();
      session.setComputerKey('up', false);
      await session.stepComputer();
      keys = backend.commands
          .where((c) => c.words[1] == 2 && c.words[2] == 6516)
          .toList();
      expect(keys.length, 2);
      session.setComputerKey('down', true);
      session.setComputerKey('down', false);
      await session.stepComputer();
      expect(
        backend.commands
            .where((c) => c.words[1] == 2 && c.words[2] == 6517)
            .length,
        1,
      );
      session.setComputerKey('left', true);
      session.releaseComputerKeys();
      await session.stepComputer();
      expect(
        backend.commands.where((c) => c.words[1] == 2 && c.words[2] == 6519),
        isEmpty,
      );
      await session.close();
      session.dispose();
    },
  );

  test(
    'source content/profile, not filename, gates fixed physical mapping',
    () async {
      final backend = ComputerCircuitBackend()..digest = 'other';
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      expect(await session.verifyComputer(), isFalse);
      expect(backend.commands, isEmpty);
      await session.close();
      session.dispose();
    },
  );

  test(
    'real ROM lamp writes, physical reset controls, then yellow clock pulses',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      expect(await session.verifyComputer(), isTrue);
      expect(session.canRunComputer, isFalse);
      expect(() => session.run(), throwsStateError);
      await session.loadProgram('marker.bin', Uint8List.fromList([1, 0, 0, 0]));
      expect(session.canRunComputer, isTrue);
      final write = backend.commands.singleWhere((c) => c.words[1] == 5);
      expect(write.records, [2853, 1236, 1, 0]);
      await session.stepComputer();
      final clock = backend.commands.lastWhere((c) => c.words[1] == 2);
      expect(clock.words[2], 3194);
      expect(clock.words[3], 153);
      expect(clock.words[7], 8);
      expect(clock.words[8], 1);
      expect(clock.words[12], 0);
      expect(backend.commands.where((c) => c.words[1] == 3), isEmpty);
      await session.close();
      session.dispose();
    },
  );

  test(
    'cancelled ROM load cannot claim a program ready or run partial writes',
    () async {
      final backend = ComputerCircuitBackend()..holdWrite = Completer<void>();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      await session.verifyComputer();
      final load = session.loadProgram(
        'p.bin',
        Uint8List.fromList([1, 0, 0, 0]),
      );
      final failed = expectLater(load, throwsStateError);
      while (!backend.commands.any((c) => c.words[1] == 5)) {
        await Future<void>.delayed(Duration.zero);
      }
      await session.cancelOperation();
      backend.holdWrite!.complete();
      await failed;
      expect(session.programIncomplete, isTrue);
      expect(session.canRunComputer, isFalse);
      expect(session.programName, isNull);
      await session.close();
      session.dispose();
    },
  );

  test(
    'pause bounds queued physical clocks and close drains the accepted batch',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      await session.verifyComputer();
      await session.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
      backend.holdClock = Completer<void>();
      session.run();
      while (!backend.commands.any(
        (c) => c.words[1] == 2 && c.words[2] == 3194,
      )) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      session.pause();
      final closing = session.close();
      expect(backend.closes, 0);
      backend.holdClock!.complete();
      await closing;
      final clocks = backend.commands
          .where((c) => c.words[1] == 2 && c.words[2] == 3194)
          .toList();
      expect(clocks.length, 1);
      expect(clocks.single.words[8], 128);
      expect(backend.closes, 1);
      session.dispose();
    },
  );
}
