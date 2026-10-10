import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_session.dart';

class _HeldBackend implements WorldCircuitBackend {
  Completer<void>? holdClock, activeClock;
  int ticks = 0;
  WorldCircuitResult snapshot() {
    final stats = List<int>.filled(24, 0);
    stats[2] = 128;
    stats[3] = 96;
    stats[18] = ticks;
    return WorldCircuitResult(1, stats, Uint8List(0));
  }

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List world) async =>
      snapshot();
  @override
  Future<void> closeWorldCircuit(int session) async {}
  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    if (command.words[1] == 3) {
      final gate = holdClock;
      activeClock = gate;
      await gate?.future;
      ticks += command.words[8];
      activeClock = null;
    }
    return snapshot();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() complete,
  String label, {
  String Function()? diagnostics,
}) async {
  for (var turn = 0; turn < 200 && !complete(); turn++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(
    complete(),
    isTrue,
    reason:
        '$label did not finish in 200 pump turns'
        '${diagnostics == null ? '' : ': ${diagnostics()}'}',
  );
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
    final session = WorldCircuitSession(backend, Uint8List(1));
    await session.open();
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
      final before = backend.ticks, published = reasons.length;
      final publicationPulses = <int>[];
      final publicationBusy = <bool>[];
      void observePublication() {
        publicationPulses.add(backend.ticks);
        publicationBusy.add(session.busy);
      }

      String describe() =>
          'pulses=${backend.ticks} expected=${before + 6}, '
          'busy=${session.busy}, running=${session.running}, '
          'reasons=$reasons (before=$published), '
          'publicationPulses=$publicationPulses, '
          'publicationBusy=$publicationBusy, '
          'gateReleased=${gate.isCompleted}, '
          'activeClock=${backend.activeClock == null
              ? 'none'
              : identical(backend.activeClock, gate)
              ? 'released'
              : identical(backend.activeClock, backend.holdClock)
              ? 'next'
              : 'other'}, '
          'error=${session.error}';
      session.addListener(observePublication);
      try {
        backend.holdClock = Completer<void>();
        gate.complete();
        await _pumpUntil(
          tester,
          () =>
              backend.ticks == before + 6 &&
              reasons.length > published &&
              publicationBusy.isNotEmpty,
          'completed batch publishes',
          diagnostics: describe,
        );
        // The completed serial operation is idle when it publishes. A 1 ms
        // pump can also launch the next held batch, so idle must be observed
        // synchronously at publication instead of after the pump returns.
        expect(publicationPulses, everyElement(before + 6), reason: describe());
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
        expectSync(
          session.isRuntimeFramePublication,
          isTrue,
          reason: 'Outer synchronous notification reason restored',
        );
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
