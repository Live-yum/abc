import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

import 'support/computer_circuit_backend.dart';

void main() {
  testWidgets('dirty, reentrant ordinary, pause and close preserve routing', (
    tester,
  ) async {
    final backend = ComputerCircuitBackend();
    final session = WorldCircuitSession.fromSource(
      backend,
      const WorldCircuitSource.file(path: '/fixture.wld', length: 1, name: 'wld'),
    );
    await session.open();
    await session.verifyComputer();
    await session.loadProgram('loop.bin', Uint8List.fromList([0x6f, 0, 0, 0]));
    session.markSaved();
    final reasons = <bool>[];
    session.addListener(() => reasons.add(session.isRuntimeFramePublication));
    backend.holdClock = Completer<void>();
    session.run();
    reasons.clear();

    Future<void> complete() async {
      final gate = backend.holdClock!;
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 20),
      ));
      backend.holdClock = Completer<void>();
      gate.complete();
      await tester.pump();
    }

    await complete();
    expect(reasons, [false], reason: 'First dirty transition remains ordinary');
    expect(session.dirty, isTrue);
    // Model a mutation from an earlier throttled batch: it changed dirty but
    // emitted no event. The next publication must still be ordinary.
    session.markSaved();
    reasons.clear();
    session.dirty = true;
    await complete();
    expect(reasons, [false]);
    reasons.clear();
    var nested = false;
    session.addListener(() {
      if (session.isRuntimeFramePublication && !nested) {
        nested = true;
        session.notifyListeners();
        expect(session.isRuntimeFramePublication, isTrue,
            reason: 'Outer synchronous notification reason restored');
      }
    });
    await complete();
    expect(reasons, [true, false]);
    expect(session.isRuntimeFramePublication, isFalse);

    reasons.clear();
    await tester.pump(const Duration(milliseconds: 1));
    session.pause();
    backend.holdClock!.complete();
    backend.holdClock = null;
    await tester.pump();
    await session.close();
    expect(reasons, isNotEmpty);
    expect(reasons, everyElement(isFalse));
    session.dispose();
  });
}
