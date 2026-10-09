import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/diagnostics/host_stage_timings.dart';

void main() {
  test('recent windows are bounded and lifetime counters retain all calls', () {
    final timings = HostStageTimings();
    for (var i = 1; i <= 1000; i++) {
      timings.record('physical.command', i);
    }
    final snapshot = timings.snapshot();
    final row = (snapshot['stages'] as Map)['physical.command'] as Map;
    expect(row['count'], 1000);
    expect(row['totalUs'], 500500);
    expect(row['recentCount'], 128);
    expect(row['recentMeanUs'], 936.5);
    expect(row['recentP95Us'], 994);
    expect(row['recentMaxUs'], 1000);
    expect(snapshot['isFlutterFrameTiming'], isFalse);
    expect(snapshot['unit'], 'microseconds');
    expect(snapshot['stagesOverlap'], isTrue);
  });

  test('stage keys are bounded and reset releases all samples', () {
    final timings = HostStageTimings();
    for (var i = 0; i < 10000; i++) {
      timings.record('stage-$i', i);
    }
    expect((timings.snapshot()['stages'] as Map).length, 64);
    timings.reset();
    expect(timings.generation, 1);
    expect(timings.snapshot()['stages'], isEmpty);
  });

  test('instrumentation preserves return values and thrown errors', () {
    final timings = HostStageTimings();
    final value = Object();
    expect(identical(timings.measure('value', () => value), value), isTrue);
    expect(
      () => timings.measure('error', () => throw StateError('failed')),
      throwsStateError,
    );
    expect(((timings.snapshot()['stages'] as Map)['error'] as Map)['count'], 1);
  });

  test('worker values only record finite allowlisted durations', () {
    final timings = HostStageTimings();
    timings.recordBridge('physical.command', {
      'coreStepUs': 1234.5,
      'yieldWaitUs': double.infinity,
      'resultCopyUs': -1,
      'unboundedPayload': 20,
    });
    final rows = timings.snapshot()['stages'] as Map;
    expect(rows.keys, ['physical.command.coreStepUs']);
    expect((rows.values.single as Map)['totalUs'], 1235);
  });
}
