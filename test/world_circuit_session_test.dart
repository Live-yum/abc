import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

class _Backend implements WorldCircuitBackend {
  int opens = 0, closes = 0;
  bool fail = false;
  List<int> ticks = [];
  final kinds = <int>[];
  final originals = <Uint8List>[];
  @override
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List world, {
    Uint8List? twld,
  }) async {
    opens++;
    originals.add(Uint8List.fromList(world));
    return WorldCircuitResult(opens, List.filled(24, 0), Uint8List(0));
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    if (fail) throw StateError('engine rejected');
    kinds.add(command.words[1]);
    if (command.words[1] == 3) ticks.add(command.words[8]);
    return WorldCircuitResult(
      session,
      List.filled(24, 0),
      command.words[1] == 1
          ? Uint8List.fromList([ticks.fold(0, (a, b) => a + b)])
          : Uint8List(0),
    );
  }

  @override
  Future<void> closeWorldCircuit(int session) async {
    closes++;
  }
}

void main() {
  test('queries stay clean; real mutation marks dirty; reset uses immutable original', () async {
    final backend = _Backend(), original = Uint8List.fromList([1, 2, 3]);
    final session = WorldCircuitSession(backend, original);
    original[0] = 9;
    await session.open();
    await session.command(WorldCircuitCommand.viewport(0, 0, 1, 1));
    expect(session.dirty, false);
    await session.command(WorldCircuitCommand.trigger(0, 0));
    expect(session.dirty, true);
    await session.reset();
    expect(session.dirty, false);
    expect(backend.originals.last, [1, 2, 3]);
    expect(backend.closes, 1);
    await session.close();
    session.dispose();
    expect(backend.closes, 2);
  });
  test('rejected engine command does not claim dirty state', () async {
    final backend = _Backend();
    final session = WorldCircuitSession(backend, Uint8List(1));
    await session.open();
    backend.fail = true;
    await expectLater(
      session.command(WorldCircuitCommand.ticks(1)),
      throwsStateError,
    );
    expect(session.dirty, false);
    expect(session.error, isStateError);
    expect(session.running, false);
    await session.close();
    session.dispose();
  });
  testWidgets(
    'run dispatches six actual VM ticks per 100ms; pause stops dispatch',
    (tester) async {
      final backend = _Backend();
      final session = WorldCircuitSession(backend, Uint8List(1));
      await session.open();
      session.run();
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.ticks, [6]);
      session.pause();
      await tester.pump(const Duration(seconds: 1));
      expect(backend.ticks, [6]);
      await session.close();
      session.dispose();
    },
  );
  testWidgets(
    'run refreshes last viewport after ticks inside the same serial operation',
    (tester) async {
      final backend = _Backend();
      final session = WorldCircuitSession(backend, Uint8List(1));
      await session.open();
      await session.command(WorldCircuitCommand.viewport(2, 3, 4, 5));
      expect(session.result!.records, [0]);
      session.run();
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.kinds, [1, 3, 1]);
      expect(session.result!.records, [6]);
      expect(session.busy, false);
      await session.close();
      session.dispose();
    },
  );
}
