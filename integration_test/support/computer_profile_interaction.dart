import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/computer_display.dart';

/// Merged monitor semantics can cover the full-width Align, including blank
/// space. Pointer interactions must use the painted monitor's own bounds.
Finder findComputerProfileMonitor(String label) => find.byWidgetPredicate(
  (widget) => widget is ComputerDisplay && widget.label == label,
  description: 'painted ComputerDisplay with label "$label"',
);

/// Finish scroll layout before checking and using the actual pointer target.
/// A fixed pump also works while the physical clock continuously schedules work.
Future<void> revealComputerProfileTarget(
  WidgetTester tester,
  Finder target,
) async {
  expect(target, findsOneWidget);
  await tester.pump();
  await tester.ensureVisible(target);
  await tester.pump();
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason:
        'The revealed production control must receive a real pointer. '
        'Target ${tester.getRect(target)}, '
        'viewport ${MediaQuery.sizeOf(tester.element(target))}.',
  );
}

/// Acquire keyboard focus only through the production monitor's pointer handler.
Future<void> focusComputerProfileMonitor(
  WidgetTester tester,
  Finder monitor,
) async {
  await revealComputerProfileTarget(tester, monitor);
  await tester.tap(monitor);
  await tester.pump();
  expect(
    Focus.maybeOf(tester.element(monitor))?.hasPrimaryFocus,
    isTrue,
    reason: 'The real monitor tap must focus its production keyboard handler.',
  );
}

class ComputerProfileHeldInputSample {
  const ComputerProfileHeldInputSample({
    required this.sensorIndex,
    required this.releasedUs,
    required this.latencies,
  });

  final int sensorIndex;
  final int releasedUs;
  final Map<String, Object?> latencies;
}

/// A sensor acknowledgement is not proof that Pong has sampled that input.
/// Keep the real key/pointer held until its decoded paddle state changes, when
/// required, and release even if either observation fails. This is not a raster
/// or presentation-latency measurement.
Future<ComputerProfileHeldInputSample> observeComputerProfileHeldInput({
  required String input,
  required Future<void> Function() press,
  required Future<void> Function() release,
  required Future<void> Function() pump,
  required int Function() nowUs,
  required int Function() physicalClocks,
  required int Function() sensorIndex,
  required int Function(int) sensorAcknowledgedUs,
  required double Function() paddleCenter,
  required bool expectPaddleChange,
  String? Function()? error,
}) async {
  const boundUs = 5000000;
  final centerBefore = paddleCenter();
  if (expectPaddleChange) {
    expect(
      centerBefore,
      inInclusiveRange(0, 47),
      reason: '$input requires an observed initial decoded paddle state.',
    );
  }
  final clocksBefore = physicalClocks(), startedUs = nowUs();
  void checkDeadline(String phase, int observedUs) {
    final elapsedUs = observedUs - startedUs;
    if (elapsedUs > boundUs) {
      fail(
        'Input timeout: input=$input phase=$phase elapsedUs=$elapsedUs '
        'boundUs=$boundUs from=press clockCount=${physicalClocks()} '
        'clockDelta=${physicalClocks() - clocksBefore} '
        'centerBefore=$centerBefore centerNow=${paddleCenter()}.',
      );
    }
  }

  Future<void> waitFor(String phase, bool Function() condition) async {
    while (true) {
      checkDeadline(phase, nowUs());
      final problem = error?.call();
      if (problem != null) fail('$input phase=$phase: $problem');
      if (condition()) return;
      await pump();
    }
  }

  late final int event, acknowledgedUs, releasedUs;
  int? paddleObservedUs;
  double? centerObserved;
  await press();
  try {
    await waitFor('physical-sensor-acknowledgement', () => sensorIndex() >= 0);
    event = sensorIndex();
    acknowledgedUs = sensorAcknowledgedUs(event);
    if (expectPaddleChange) {
      await waitFor('decoded-paddle-state-change', () {
        final center = paddleCenter();
        if (center < 0 || center > 47 || center == centerBefore) return false;
        final observedUs = nowUs();
        checkDeadline('decoded-paddle-state-change', observedUs);
        centerObserved = center;
        paddleObservedUs = observedUs;
        return true;
      });
    }
  } finally {
    releasedUs = nowUs();
    await release();
  }
  return ComputerProfileHeldInputSample(
    sensorIndex: event,
    releasedUs: releasedUs,
    latencies: {
      'pressToPhysicalSensorMs': (acknowledgedUs - startedUs) / 1000,
      if (expectPaddleChange) ...{
        'pressToPaddleStateMs': (paddleObservedUs! - startedUs) / 1000,
        'paddleCenterBefore': centerBefore,
        'paddleCenterObservedAfter': centerObserved,
        'paddleStateLatencyMeasurement':
            'decoded-physical-monitor-state-not-raster-presentation',
        'paddleStateWaitBoundMs': boundUs ~/ 1000,
        'paddleStateWaitStartsAt': 'press',
      },
      'visualLatencyClaim': false,
    },
  );
}
