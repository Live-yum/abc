import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';
import 'support/computerraria/provenance.dart';

import 'support/computer_circuit_backend.dart';
import 'support/computerraria/fixture_driver.dart';

const source = WorldCircuitSource.file(
  path: '/fixture/computer.wld',
  length: 405983441,
  name: 'arbitrary.wld',
);

void main() {
  test(
    'fixture commands use the generic serial executor in physical packet order',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
      await driver.verifyFixture(session.result!);
      await driver.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
      backend.commands.clear();
      session.hostStages.reset();
      await driver.step(128);
      expect(backend.commands.map((c) => c.words[1]), [2, 9]);
      expect(backend.commands.first.words[8], 128);
      expect(driver.pixels, hasLength(64 * 48 * 4));
      await session.close();
      session.dispose();
    },
  );

  test('registered derived WLD restores ROM metadata without reset and clears a longer tail later', () async {
    final backend = ComputerCircuitBackend()
      ..digest = ComputerCircuitBackend.savedWldSha;
    final session = WorldCircuitSession.fromSource(backend, source);
    await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
    final provenance = ComputerProvenanceRecord(
      wldSha256: backend.digest,
      programName: 'long.bin',
      programImage: Uint8List.fromList([1, 0, 0, 0, 1, 0, 0, 0]),
      physicalPulses: 5120,
    );
    expect(await driver.verifyFixture(session.result!, provenance: provenance), isTrue);
    expect(backend.commands.where((c) => c.mutates), isEmpty);
    expect(driver.programName, 'long.bin');
    expect(driver.physicalPulses, 5120);
    expect(driver.canRun, isTrue);
    await driver.loadProgram('short.bin', Uint8List.fromList([1, 0, 0, 0]));
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
    'a different WLD never enables fixed controls with unrelated provenance',
    () async {
      final backend = ComputerCircuitBackend()
        ..digest = ComputerCircuitBackend.savedWldSha;
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
      expect(
        await driver.verifyFixture(session.result!,
          provenance: ComputerProvenanceRecord(
            wldSha256: 'b' * 64,
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

  test('mode defaults to vanilla and switching preserves the current ROM and frame snapshot', () async {
    final backend = ComputerCircuitBackend();
    final session = WorldCircuitSession.fromSource(backend, source);
    await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
    await driver.verifyFixture(session.result!);
    await driver.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
    expect(session.optimizationEnabled, isFalse);
    expect(session.optimizationSupported, isTrue);
    expect(session.wireHeadPixelRulesEnabled, isFalse);
    final before = Uint8List.fromList(driver.pixels!);
    backend.holdClock = Completer<void>();
    final stepping = driver.step(128);
    while (!backend.commands.any(
      (c) => c.words[1] == 2 && c.words[2] == 3194,
    )) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    driver.setKey('up', true);
    final mode = session.setOptimization(true);
    expect(session.running, isFalse);
    expect(backend.commands.where((c) => c.words[1] == 10), isEmpty);
    backend.holdClock!.complete();
    await stepping;
    await mode;
    expect(session.optimizationEnabled, isTrue);
    expect(session.wireHeadPixelRulesEnabled, isTrue);
    expect(driver.programName, 'p.bin');
    expect(driver.canRun, isTrue);
    expect(driver.heldKeys, {'up'});
    expect(driver.pixels, before);
    expect(driver.physicalPulses, 128);
    expect(backend.opens, 1);
    expect(backend.closes, 0);
    await session.command(WorldCircuitCommand.save());
    expect(session.result!.reserved, 0);
    expect(session.optimizationSupported, isTrue);
    expect(session.wireHeadPixelRulesEnabled, isTrue);
    await session.close();
    session.dispose();
  });

  for (final refusal in ['unsupported capability', 'engine refusal']) {
    test(
      'ON rejection preserves the paused computer state: $refusal',
      () async {
        final backend = ComputerCircuitBackend()
          ..optimizationSupported = refusal != 'unsupported capability'
          ..rejectOptimization = refusal == 'engine refusal';
        final session = WorldCircuitSession.fromSource(backend, source);
        await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
        await driver.verifyFixture(session.result!);
        await driver.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
        session.markSaved();
        final frames = Uint8List.fromList(driver.pixels!);
        final program = driver.programImage;
        final pulses = driver.physicalPulses;
        await expectLater(session.setOptimization(true), throwsA(anything));
        expect(session.optimizationEnabled, isFalse);
        expect(session.wireHeadPixelRulesEnabled, isFalse);
        expect(backend.optimized, isFalse);
        expect(session.running, isFalse);
        expect(driver.programImage, program);
        expect(driver.pixels, frames);
        expect(driver.physicalPulses, pulses);
        expect(session.dirty, isFalse);
        expect(session.error, isNotNull);
        if (refusal == 'unsupported capability') {
          expect(session.error.toString(), contains('同色跨轴网络'));
          expect(
            backend.commands.where((command) => command.words[1] == 10),
            isEmpty,
          );
        }
        await session.setOptimization(false);
        expect(session.error, isNull);
        expect(driver.canRun, isTrue);
        await session.close();
        session.dispose();
      },
    );
  }

  test(
    'held keys coalesce actual sensor pulses and release never pulses',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
      await driver.verifyFixture(session.result!);
      await driver.loadProgram('p.bin', Uint8List.fromList([1, 0, 0, 0]));
      for (var i = 0; i < 100; i++) {
        driver.setKey('up', true);
      }
      await driver.step();
      var keys = backend.commands
          .where((c) => c.words[1] == 2 && c.words[2] == 6516)
          .toList();
      expect(keys.length, 1);
      expect(keys.single.words[3], 851);
      expect(keys.single.words[7], 9);
      expect(keys.single.words[12], 0);
      await driver.step();
      driver.setKey('up', false);
      await driver.step();
      keys = backend.commands
          .where((c) => c.words[1] == 2 && c.words[2] == 6516)
          .toList();
      expect(keys.length, 2);
      driver.setKey('down', true);
      driver.setKey('down', false);
      await driver.step();
      expect(
        backend.commands
            .where((c) => c.words[1] == 2 && c.words[2] == 6517)
            .length,
        1,
      );
      driver.setKey('left', true);
      driver.releaseKeys();
      await driver.step();
      expect(
        backend.commands.where((c) => c.words[1] == 2 && c.words[2] == 6519),
        isEmpty,
      );
      await session.close();
      session.dispose();
    },
  );

  test('source content, not filename, gates fixed physical mapping', () async {
    final backend = ComputerCircuitBackend()..digest = 'other';
    final session = WorldCircuitSession.fromSource(backend, source);
    await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
    expect(await driver.verifyFixture(session.result!), isFalse);
    expect(backend.commands, isEmpty);
    await session.command(WorldCircuitCommand.ticks(1));
    expect(backend.commands.single.words[1], 3);
    await expectLater(driver.step(), throwsStateError);
    await session.close();
    session.dispose();
  });

  test(
    'real ROM lamp writes, physical reset controls, then yellow clock pulses',
    () async {
      final backend = ComputerCircuitBackend();
      final session = WorldCircuitSession.fromSource(backend, source);
      await session.open();
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
      expect(await driver.verifyFixture(session.result!), isTrue);
      expect(driver.canRun, isFalse);
      await expectLater(driver.step(), throwsStateError);
      await driver.loadProgram('marker.bin', Uint8List.fromList([1, 0, 0, 0]));
      expect(driver.canRun, isTrue);
      final write = backend.commands.singleWhere((c) => c.words[1] == 5);
      expect(write.records, [2853, 1236, 1, 0]);
      await driver.step();
      final clock = backend.commands.lastWhere((c) => c.words[1] == 2);
      expect(clock.words[2], 3194);
      expect(clock.words[3], 153);
      expect(clock.words[7], 8);
      expect(clock.words[8], 1);
      expect(clock.words[12], 0);
      expect(backend.commands.where((c) => c.words[1] == 3), isEmpty);
      final beforeProbe = backend.commands.where((c) => c.mutates).length;
      final signature = await driver.lampSignature([2853, 1236, 0, 0]);
      expect(signature, hasLength(16));
      expect(backend.commands.where((c) => c.mutates).length, beforeProbe);
      expect(driver.savedProvenance('a' * 64).programImage, [1, 0, 0, 0]);
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
      final driver = ComputerrariaFixtureDriver((command) => session.command(command));
      await driver.verifyFixture(session.result!);
      final load = driver.loadProgram(
        'p.bin',
        Uint8List.fromList([1, 0, 0, 0]),
      );
      final failed = expectLater(load, throwsStateError);
      while (!backend.commands.any((c) => c.words[1] == 5)) {
        await Future<void>.delayed(Duration.zero);
      }
      driver.cancel();
      await session.cancelOperation();
      backend.holdWrite!.complete();
      await failed;
      expect(driver.programIncomplete, isTrue);
      expect(driver.canRun, isFalse);
      expect(driver.programName, isNull);
      await expectLater(driver.verifyFixture(session.result!), throwsStateError);
      await expectLater(driver.step(), throwsStateError);
      await session.close();
      session.dispose();
    },
  );

  test('generic close drains the accepted command before owner teardown', () async {
    final backend = ComputerCircuitBackend()..holdClock = Completer<void>();
    final session = WorldCircuitSession.fromSource(backend, source);
    await session.open();
    final driver = ComputerrariaFixtureDriver((command) => session.command(command));
    await driver.verifyFixture(session.result!);
    // Use the ordinary command API directly: closing must drain the already
    // accepted operation, without creating a second fixture read after close.
    final pending = session.command(WorldCircuitCommand.trigger(3194, 153, mask: 8, pulses: 1, hitSwitch: false));
    while (!backend.commands.any((c) => c.words[1] == 2)) {
      await Future<void>.delayed(Duration.zero);
    }
    final closing = session.close();
    expect(backend.closes, 0);
    backend.holdClock!.complete();
    await pending;
    await closing;
    expect(backend.commands.where((c) => c.words[1] == 2).length, 1);
    expect(backend.closes, 1);
    session.dispose();
  });
}
