import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

import 'support/computer_circuit_backend.dart';

class _HeldBackend extends ComputerCircuitBackend {
  Completer<void>? activeClock;

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    final clock = command.words[1] == 2 && command.words[2] == 3194;
    if (clock) activeClock = holdClock;
    final result = await super.commandWorldCircuit(session, command);
    if (clock) activeClock = null;
    return result;
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() complete,
  String label, {
  String Function()? diagnostics,
}) async {
  for (var turn = 0; turn < 100 && !complete(); turn++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(complete(), isTrue, reason: '$label did not finish in 100 pump turns'
      '${diagnostics == null ? '' : ': ${diagnostics()}'}');
}

Future<void> _pumpOperation(
  WidgetTester tester,
  Future<void> operation,
  String label,
) async {
  var complete = false;
  Object? failure;
  StackTrace? failureStack;
  final tracked = operation.then<void>(
    (_) {
      complete = true;
    },
    onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      complete = true;
    },
  );
  await _pumpUntil(tester, () => complete, label);
  await tracked;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

void main() {
  testWidgets('dirty, reentrant ordinary, pause and close preserve routing', (
    tester,
  ) async {
    final backend = _HeldBackend();
    final session = WorldCircuitSession.fromSource(
      backend,
      const WorldCircuitSource.file(path: '/fixture.wld', length: 1, name: 'wld'),
    );
    await session.open();
    await session.verifyComputer();
    // Keep the session queue, its timer yields and continuations in the same
    // FakeAsync zone. A runAsync call cannot migrate an existing future chain.
    await _pumpOperation(
      tester,
      session.loadProgram('loop.bin', Uint8List.fromList([0x6f, 0, 0, 0])),
      'program load',
    );
    expect(session.canRunComputer, isTrue);
    session.markSaved();
    final reasons = <bool>[];
    session.addListener(() => reasons.add(session.isRuntimeFramePublication));
    backend.holdClock = Completer<void>();
    session.run();
    reasons.clear();

    Future<void> complete() async {
      final gate = backend.holdClock!;
      await _pumpUntil(
        tester,
        () => identical(backend.activeClock, gate),
        'clock accepts held gate',
      );
      // This real-zone wait touches no product futures or state. Stopwatch's
      // existing publication interval elapses while the fake-zone gate is held.
      await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 20),
      ));
      final before = session.physicalPulses, published = reasons.length;
      final publicationPulses = <int>[];
      final publicationBusy = <bool>[];
      void observePublication() {
        publicationPulses.add(session.physicalPulses);
        publicationBusy.add(session.busy);
      }
      String describe() =>
          'pulses=${session.physicalPulses} expected=${before + 128}, '
          'busy=${session.busy}, running=${session.running}, '
          'reasons=$reasons (before=$published), '
          'publicationPulses=$publicationPulses, '
          'publicationBusy=$publicationBusy, '
          'gateReleased=${gate.isCompleted}, '
          'activeClock=${backend.activeClock == null ? 'none' : identical(backend.activeClock, gate) ? 'released' : identical(backend.activeClock, backend.holdClock) ? 'next' : 'other'}, '
          'error=${session.error}';
      session.addListener(observePublication);
      try {
        backend.holdClock = Completer<void>();
        gate.complete();
        await _pumpUntil(
          tester,
          () => session.physicalPulses == before + 128 &&
              reasons.length > published && publicationBusy.isNotEmpty,
          'completed batch publishes',
          diagnostics: describe,
        );
        // The completed serial operation is idle when it publishes. A 1 ms
        // pump can also launch the next held batch, so idle must be observed
        // synchronously at publication instead of after the pump returns.
        expect(publicationPulses, everyElement(before + 128),
            reason: describe());
        expect(publicationBusy, everyElement(isFalse), reason: describe());
      } finally {
        session.removeListener(observePublication);
      }
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
    await _pumpUntil(
      tester,
      () => identical(backend.activeClock, backend.holdClock),
      'last clock accepts held gate',
    );
    session.pause();
    backend.holdClock!.complete();
    backend.holdClock = null;
    await _pumpOperation(tester, session.close(), 'session close');
    expect(reasons, isNotEmpty);
    expect(reasons, everyElement(isFalse));
    session.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
