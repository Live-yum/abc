import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/profile_os_memory_native.dart';

Map<String, Object?> sample(int time, int rss, {bool smaps = true}) => {
  'timeUs': time,
  'rssBytes': rss,
  'processVmHwmBytes': 900000,
  'smapsTimeUs': smaps ? time + 1 : null,
  'smapsRssBytes': smaps ? rss + 100 : null,
  'pssBytes': smaps ? rss - 100 : null,
  'ussBytes': smaps ? rss - 200 : null,
};

void main() {
  test('proc parser converts kB without inventing absent values', () {
    expect(
      parseProcMemory('VmRSS:\t123 kB\nVmHWM: 456 kB\n', ['VmRSS', 'VmHWM']),
      {'VmRSS': 123 * 1024, 'VmHWM': 456 * 1024},
    );
    for (final invalid in [
      '',
      'VmRSS: -1 kB\n',
      'VmRSS: 1 MB\n',
      'VmRSS: 1 kB\nVmRSS: 2 kB\n',
    ]) {
      expect(() => parseProcMemory(invalid, ['VmRSS']), throwsFormatException);
    }
  });

  test(
    'interior load maximum remains separate from lifetime HWM and boundaries',
    () {
      final window = OsMemoryWindow({'kind': 'initial-import'})
        ..add(sample(100, 1000))
        ..add(sample(10100, 5000), periodic: true)
        ..add(sample(30100, 2000));
      final report = window.end('ready', {'monoDisplayInitialized': true});
      expect((report['baseline'] as Map)['rssBytes'], 1000);
      expect((report['ready'] as Map)['rssBytes'], 2000);
      expect((report['sampleMax'] as Map)['rssBytes'], 5000);
      expect((report['sampleMax'] as Map)['smapsRssBytes'], 5100);
      expect((report['sampleMaxAtUs'] as Map)['rssBytes'], 10100);
      expect((report['sampleMaxAtUs'] as Map)['pssBytes'], 10101);
      expect(report['processVmHwmAtBaselineBytes'], 900000);
      expect(report['processVmHwmAtEndBytes'], 900000);
      expect(report['statusSampleCount'], 3);
      expect(report['periodicStatusSampleCount'], 1);
      expect(report['durationUs'], 30000);
      expect(report['statusIntervalUs'], {
        'count': 2,
        'min': 10000,
        'max': 20000,
        'mean': 15000.0,
        'nonOverlappingBuckets': {'<=10000': 1, '<=20000': 1},
      });
      // A close snapshot must never be added to a completed load's maximum.
      expect(() => window.add(sample(40000, 999999)), throwsStateError);
      expect(() => window.end('ready', {}), throwsStateError);
    },
  );

  test('repeat window resets sample maxima while HWM may stay high', () {
    final first = OsMemoryWindow({})..add(sample(10, 8000));
    first.end('ready', {});
    final repeat = OsMemoryWindow({})..add(sample(20, 1000));
    final report = repeat.end('ready', {});
    expect((report['sampleMax'] as Map)['rssBytes'], 1000);
    expect(report['processVmHwmAtEndBytes'], 900000);
  });

  test('missing smaps and empty windows stay null rather than zero', () {
    final window = OsMemoryWindow({})..add(sample(10, 1000, smaps: false));
    final report = window.end('cancelled', {});
    expect(report['ready'], isNull);
    expect(report['smapsSampleCount'], 0);
    expect((report['sampleMax'] as Map)['pssBytes'], isNull);
    expect((report['sampleMax'] as Map)['ussBytes'], isNull);
    final empty = OsMemoryWindow({}).end('failed', {});
    expect(empty['baseline'], isNull);
    expect(empty['statusSampleCount'], 0);
    expect((empty['sampleMax'] as Map)['rssBytes'], isNull);
  });

  test(
    'own-host isolate samples a bounded load and retains separate close point',
    () async {
      final probe = await OsLoadingMemoryProbe.start();
      try {
        await probe.begin({'kind': 'unit-lifecycle'});
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await probe.end('ready');
        await probe.closePoint({'phase': 'after-close'});
        final report = await probe.finish();
        expect(report['status'], 'observed');
        expect(report['hostPid'], pid);
        final row = (report['windows'] as List).single as Map;
        expect(row['periodicStatusSampleCount'], greaterThan(0));
        expect(row['statusSampleCount'], greaterThan(2));
        expect((row['sampleMax'] as Map)['rssBytes'], greaterThan(0));
        final close =
            ((report['closeSamples'] as List).single as Map)['sample'] as Map;
        expect(
          close['timeUs'],
          greaterThanOrEqualTo((row['terminal'] as Map)['timeUs']),
        );
        expect(await probe.finish(), report);
      } finally {
        await probe.finish();
      }
    },
    skip: !Platform.isLinux,
  );

  test('zero-window probe cannot claim loading memory was observed', () async {
    final probe = await OsLoadingMemoryProbe.start();
    final report = await probe.finish();
    expect(report['status'], 'incomplete');
    expect(report['pssUssAvailability'], 'unavailable');
    expect(report['windows'], isEmpty);
  }, skip: !Platform.isLinux);

  test('shutdown marks an unfinished load aborted and incomplete', () async {
    final probe = await OsLoadingMemoryProbe.start();
    await probe.begin({'kind': 'interrupted'});
    final report = await probe.finish();
    expect(report['status'], 'incomplete');
    expect(((report['windows'] as List).single as Map)['outcome'], 'aborted');
    expect(report['errors'], isNotEmpty);
  }, skip: !Platform.isLinux);
}
