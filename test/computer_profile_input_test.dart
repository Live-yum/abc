import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/computer_profile_interaction.dart';

// Deterministic measurement-control regressions only. These observations are
// deliberately synthetic and are never counted as actual Pong execution proof.
void main() {
  test(
    'sensor acknowledgement keeps input held until decoded paddle changes',
    () async {
      var nowUs = 0, clocks = 0;
      var center = 20.0, held = false;
      final transitions = <String>[];
      final sample = await observeComputerProfileHeldInput(
        input: 'up',
        press: () async {
          held = true;
          transitions.add('press');
        },
        release: () async {
          held = false;
          transitions.add('release');
          center = 17; // A later observation must not replace the held result.
        },
        pump: () async {
          expect(held, isTrue);
          nowUs += 100000;
          clocks += 128;
          transitions.add('clock-$clocks');
          if (clocks == 512) center = 18;
        },
        nowUs: () => nowUs,
        physicalClocks: () => clocks,
        sensorIndex: () => clocks >= 128 ? 0 : -1,
        sensorAcknowledgedUs: (_) => 100000,
        paddleCenter: () => center,
        expectPaddleChange: true,
      );
      expect(transitions, [
        'press',
        'clock-128',
        'clock-256',
        'clock-384',
        'clock-512',
        'release',
      ]);
      expect(held, isFalse);
      expect(sample.latencies['pressToPhysicalSensorMs'], 100);
      expect(sample.latencies['pressToPaddleStateMs'], 400);
      expect(sample.latencies['paddleCenterBefore'], 20);
      expect(sample.latencies['paddleCenterObservedAfter'], 18);
      expect(sample.latencies['paddleStateWaitBoundMs'], 5000);
      expect(sample.latencies['paddleStateWaitStartsAt'], 'press');
      expect(
        sample.latencies['paddleStateLatencyMeasurement'],
        'decoded-physical-monitor-state-not-raster-presentation',
      );
      expect(sample.latencies['visualLatencyClaim'], isFalse);
      expect(sample.releasedUs, 400000);
    },
  );

  test('Pong-ignored direction requires only sensor acknowledgement', () async {
    var nowUs = 0, clocks = 0, releases = 0;
    final sample = await observeComputerProfileHeldInput(
      input: 'left',
      press: () async {},
      release: () async {
        releases++;
      },
      pump: () async {
        nowUs += 100000;
        clocks += 128;
      },
      nowUs: () => nowUs,
      physicalClocks: () => clocks,
      sensorIndex: () => clocks >= 128 ? 0 : -1,
      sensorAcknowledgedUs: (_) => 100000,
      paddleCenter: () => 20,
      expectPaddleChange: false,
    );
    expect(clocks, 128);
    expect(releases, 1);
    expect(
      sample.latencies.keys.where(
        (key) => key.toLowerCase().contains('paddle'),
      ),
      isEmpty,
    );
    expect(sample.latencies['pressToPhysicalSensorMs'], 100);
    expect(sample.latencies['visualLatencyClaim'], isFalse);
  });

  for (final changesAfterDeadline in [false, true]) {
    test(
      'shared press deadline releases input; late change=$changesAfterDeadline',
      () async {
        var nowUs = 0, clocks = 0, releases = 0;
        var center = 20.0;
        final observation = observeComputerProfileHeldInput(
          input: 'touch-hold-down',
          press: () async {},
          release: () async {
            releases++;
          },
          pump: () async {
            nowUs += 2000000;
            clocks += 128;
            if (changesAfterDeadline && nowUs > 5000000) center = 21;
          },
          nowUs: () => nowUs,
          physicalClocks: () => clocks,
          sensorIndex: () => clocks >= 128 ? 0 : -1,
          sensorAcknowledgedUs: (_) => 2000000,
          paddleCenter: () => center,
          expectPaddleChange: true,
        );
        await expectLater(
          observation,
          throwsA(
            isA<TestFailure>().having(
              (failure) => failure.message,
              'phase and physical-state diagnostic',
              allOf(
                contains('phase=decoded-paddle-state-change'),
                contains('clockCount=384'),
                contains('centerBefore=20.0'),
                contains('from=press'),
              ),
            ),
          ),
        );
        expect(releases, 1);
      },
    );
  }
}
