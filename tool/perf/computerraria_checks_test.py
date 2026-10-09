#!/usr/bin/env python3
"""Small synthetic report tests; these do not claim to execute Computerraria."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import computerraria_compare as checks
import computerraria_provenance as provenance

COMMIT = 'a' * 40
HASH = 'b' * 64


def loading_memory_report(cycles=2):
    mib = 1024 * 1024
    def sample(time, rss):
        return {'timeUs': time, 'rssBytes': rss * mib,
                'processVmHwmBytes': 512 * mib, 'smapsTimeUs': time + 1,
                'smapsRssBytes': (rss - 10) * mib, 'pssBytes': (rss - 20) * mib,
                'ussBytes': (rss - 30) * mib, 'smapsUnavailable': None}
    def intervals(count, gap):
        bucket = next((key for key in checks.INTERVAL_BUCKETS[:-1]
                       if gap <= int(key[2:])), '>1000000')
        return {'count': count, 'min': gap if count else None,
                'max': gap if count else None, 'mean': gap if count else None,
                'nonOverlappingBuckets': {bucket: count} if count else {}}
    identities = [('cancelled-import', 0, 'standard')]
    identities += [(kind, cycle, mode) for cycle in range(cycles) for mode in checks.MODES
                   for kind in ('initial-import', 'exported-reimport')]
    windows, closes = [], []
    for attempt, (kind, cycle, mode) in enumerate(identities):
        cancelled = attempt == 0
        start, duration = attempt * 1000000, 10000 if cancelled else 200000
        baseline, terminal = sample(start, 100), sample(start + duration, 200)
        peak = terminal if cancelled else sample(start + duration // 2, 300)
        count = 2 if cancelled else 3
        windows.append({
            'kind': kind, 'cycle': cycle, 'mode': mode, 'hostLoadAttempt': attempt,
            'priorCancelledLoad': not cancelled,
            'hostLoadContext': 'cancelled-load-attempt' if cancelled else
                               'fresh-host-first-complete-load' if attempt == 1 else 'repeat-in-same-host',
            'cacheState': 'uncontrolled', 'outcome': 'cancelled' if cancelled else 'ready',
            'baseline': baseline, 'terminal': terminal, 'ready': None if cancelled else terminal,
            'readyEvidence': {} if cancelled else {'completeWldVerified': True,
                              'monoDisplayInitialized': True, 'monoRgbaBytes': 12288},
            'durationUs': duration,
            'sampleMax': {key: peak[key] for key in checks.OS_MEMORY_FIELDS},
            'sampleMaxAtUs': {key: peak['timeUs'] for key in checks.OS_MEMORY_FIELDS},
            'processVmHwmAtBaselineBytes': baseline['processVmHwmBytes'],
            'processVmHwmAtEndBytes': terminal['processVmHwmBytes'],
            'statusSampleCount': count, 'periodicStatusSampleCount': count - 2,
            'smapsSampleCount': count, 'statusIntervalUs': intervals(count - 1, duration // (count - 1)),
            'smapsIntervalUs': intervals(count - 1, duration // (count - 1)),
        })
        if not cancelled:
            closes.append({'phase': 'after-export-close' if kind == 'initial-import' else 'after-cycle-close',
                           'cycle': cycle, 'mode': mode, 'sample': sample(start + duration + 1000, 120)})
    return {'schema': checks.LOADING_MEMORY_SCHEMA, 'status': 'observed', 'hostPid': 1234,
            'scope': checks.LOADING_MEMORY_SCOPE, 'clock': 'dart-Timeline.now-monotonic-microseconds',
            'statusTargetIntervalUs': 10000, 'smapsTargetIntervalUs': 100000,
            'samplingActiveOnlyDuringLoad': True, 'pssUssAvailability': 'available',
            'smapsUnavailable': None, 'errors': [], 'windows': windows, 'closeSamples': closes}


def profile_report():
    operations = []
    for mode in checks.MODES:
        for action in checks.CORE_OPERATIONS:
            samples = [{'cycle': cycle, 'success': True, 'latencyMs': 30100,
                        'rssBeforeBytes': 200, 'rssAfterBytes': 210,
                        'uiUs': [1000, 2000], 'rasterUs': [1500, 20000],
                        'totalSpanUs': [2000, 22000]} for cycle in range(2)]
            operations.append({'id': f'computer.{action}.{mode}', 'samples': samples,
                               'iterations': 2, 'warmup': 0, 'frameCount': 4, 'status': 'passed'})
    operations += [
        {'id': 'computer.cancel-import.standard', 'samples': [{'success': True, 'latencyMs': 1}]},
        {'id': 'computer.enable-optimization.optimized', 'samples': [{'success': True, 'latencyMs': 1}, {'success': True, 'latencyMs': 1}]},
    ]
    observations, latencies, memory = [], [], []
    def snapshot(phase, **extra):
        return {'phase': phase, 'rssBytes': 250, 'maxRssBytes': 500,
                'heapUsedBytes': 50, 'heapCapacityBytes': 100, 'externalBytes': 15,
                'sampledIsolates': 2, 'sampledIsolateGroups': 1,
                'heapMeasurementMethod': checks.HEAP_MEASUREMENT_METHOD,
                'gc': 'requested-all-isolate-groups', **extra}
    memory.append(snapshot('baseline'))
    for cycle in range(2):
        for mode in checks.MODES:
            observations.append({
                'cycle': cycle, 'mode': mode,
                'pixelRule': 'wirehead-color-pair-wave' if mode == 'optimized' else 'game-tripwire-crossing',
                'displayCompatibility': {'status': 'supported' if mode == 'optimized' else 'unsupported-under-game-rules',
                    'expectedBehavior': 'moving-pong' if mode == 'optimized' else 'recorded-without-pong-display-claim'},
                'readyMetadata': {'flags': 14 if mode == 'optimized' else 4, 'optimizationEnabled': mode == 'optimized',
                    'topologyEligible': True, 'wireHeadPixelRulesEnabled': mode == 'optimized'},
                'allDarkSamples': mode == 'standard',
                'cpuRamLiveness': {'measurement': 'passive-lamp-queries-no-reset-bus', 'cpuProbeCount': 12,
                    'ramProbeBytes': 1088, 'distinctCpuStates': 10, 'distinctRamStates': 10},
                'deterministicTrace': [{'pulses': pulse, 'mono': HASH, 'monoLitPixels': 0 if mode == 'standard' else 22,
                    'ram': f'{pulse:064x}', 'cpuProbe': f'{pulse:064x}'}
                                       for pulse in range(512, 5121, 512)],
                'inputEventsAtPhysicalClock': copy.deepcopy(checks.FIXED_INPUT_EVENTS),
                'steadyWindowMs': 30000, 'steadyPhysicalPulses': 10240,
                'observedDisplayChanges': 3 if mode == 'optimized' else 0, 'nativeActiveBytes': 50, 'nativePeakBytes': 100,
                'clockHz': 10240 / 30, 'displayPollHz': 20})
            for direction in ('up', 'down', 'left', 'right', 'touch-hold-down'):
                latency = {'cycle': cycle, 'mode': mode, 'input': direction,
                           'pressToPhysicalSensorMs': 10, 'acceptedAtClock': 128,
                           'releaseToVerifiedNoMorePulsesMs': 50,
                           'visualLatencyClaim': False}
                if direction in checks.PADDLE_STATE_INPUTS and mode == 'optimized':
                    latency['paddleStateLatencyStatus'] = 'observed'
                    latency.update(pressToPaddleStateMs=125, paddleCenterBefore=24,
                                   paddleCenterObservedAfter=23 if direction == 'up' else 25,
                                   paddleStateLatencyMeasurement=checks.PADDLE_STATE_MEASUREMENT,
                                   paddleStateWaitBoundMs=5000, paddleStateWaitStartsAt='press')
                else:
                    latency.update(paddleStateLatencyStatus='notApplicable',
                        paddleStateLatencyReason='game-tripwire-display-not-supported' if direction in checks.PADDLE_STATE_INPUTS else 'pong-ignores-direction')
                latencies.append(latency)
            for phase in ('paused-after-steady-run', 'after-close'):
                memory.append(snapshot(phase, cycle=cycle, mode=mode))
    return {
        'schema': 2, 'inputFormat': 'wld-only', 'circuitAbi': 2, 'status': 'passed', 'buildMode': 'profile', 'cycles': 2,
        'steadySecondsPerMode': 30, 'modes': list(checks.MODES), 'clockBatchPulses': 128,
        'traceTotalPulses': 5120, 'excludedWarmupCycles': 0,
        'runtime': {'heapMeasurementMethod': checks.HEAP_MEASUREMENT_METHOD, 'commit': COMMIT, 'checkedOutHead': COMMIT, 'workingTreeDirty': False,
                    'platform': 'linux', 'flutterVersion': '3.47.6', 'renderer': 'llvmpipe',
                    'runner': 'test-fixture', 'dartVersion': 'test', 'osVersion': 'test'},
        'toolchain': {'flutterRevisionPin': checks.FLUTTER_REVISION},
        'viewport': {'physicalWidth': 1440, 'physicalHeight': 1000, 'devicePixelRatio': 1},
        'fixture': {'wldSha256': checks.WLD_SHA, 'wldBytes': 405983441},
        'displayRefreshRateHz': 60, 'frameBudgetUs': 1000000 / 60,
        'frameBudgetSource': 'observed-display-refresh-rate', 'operations': operations,
        'observations': observations, 'inputLatencies': latencies, 'memory': memory,
        'loadingOsMemory': loading_memory_report(),
    }


class ProfileEvidenceTests(unittest.TestCase):
    def test_mode_rule_and_not_applicable_paddle_evidence_are_required(self):
        for failure in ('rule', 'ready', 'compatibility', 'halted', 'false-paddle', 'missing-reason'):
            report = profile_report()
            row = report['observations'][0]
            if failure == 'rule': row['pixelRule'] = 'wirehead-color-pair-wave'
            elif failure == 'ready': row['readyMetadata']['flags'] = 14
            elif failure == 'compatibility': row['displayCompatibility']['status'] = 'supported'
            elif failure == 'halted': row['cpuRamLiveness']['distinctCpuStates'] = 1
            elif failure == 'false-paddle': report['inputLatencies'][0]['pressToPaddleStateMs'] = 100
            else: report['inputLatencies'][0].pop('paddleStateLatencyReason')
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)

    def test_standard_pixels_are_observed_without_a_pong_success_claim(self):
        report = profile_report()
        for row in report['observations']:
            if row['mode'] == 'standard':
                row['allDarkSamples'] = False
                row['observedDisplayChanges'] = 2
                for point in row['deterministicTrace']:
                    point['monoLitPixels'] = 1
                    point['mono'] = 'c' * 64
        checks.validate_profile(report, COMMIT)

    def test_terminal_smaps_time_uses_its_own_observed_boundary(self):
        report = profile_report()
        window = report['loadingOsMemory']['windows'][0]
        for key in ('smapsRssBytes', 'pssBytes', 'ussBytes'):
            window['sampleMaxAtUs'][key] = window['terminal']['smapsTimeUs']
        checks.validate_profile(report, COMMIT)
        window['sampleMaxAtUs']['pssBytes'] += 1
        with self.assertRaises(ValueError): checks.validate_profile(report, COMMIT)

    def test_only_fresh_single_wld_abi2_reports_are_accepted(self):
        for field, value in (('schema', 1), ('inputFormat', 'legacy'), ('circuitAbi', 1)):
            report = profile_report()
            report[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)

    def test_loading_os_memory_requires_complete_sampled_lifecycles(self):
        for failure in ('missing', 'incomplete', 'scope', 'periodic', 'window', 'close',
                        'ready', 'cache', 'cancel-context', 'duration', 'count', 'peak', 'hwm'):
            report = profile_report()
            data = report['loadingOsMemory']
            if failure == 'missing': report.pop('loadingOsMemory')
            elif failure == 'incomplete': data['status'] = 'incomplete'
            elif failure == 'scope': data['scope'] = 'compiler-plus-application'
            elif failure == 'periodic': data['windows'][1]['periodicStatusSampleCount'] = 0
            elif failure == 'window': data['windows'].pop()
            elif failure == 'close': data['closeSamples'].pop()
            elif failure == 'ready': data['windows'][1]['readyEvidence']['monoRgbaBytes'] = 0
            elif failure == 'cache': data['windows'][1]['cacheState'] = 'cold'
            elif failure == 'cancel-context': data['windows'][1]['priorCancelledLoad'] = False
            elif failure == 'duration': data['windows'][1]['durationUs'] += 1
            elif failure == 'count': data['windows'][1]['statusIntervalUs']['count'] += 1
            elif failure == 'peak': data['windows'][1]['sampleMax']['rssBytes'] = 1
            else: data['windows'][1]['processVmHwmAtEndBytes'] += 1
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)

    def test_loading_summary_keeps_sampled_peak_and_lifetime_hwm_separate(self):
        _, metrics = checks.validate_profile(profile_report(), COMMIT)
        text = checks.markdown({'status': 'passed', 'acceptedReports': 1, 'commit': COMMIT,
                                'errors': [], 'limits': [], 'measurements': {'ui': metrics}})
        self.assertIn('RSS baseline / sampled peak / terminal MiB', text)
        self.assertIn('Cumulative VmHWM baseline / end MiB', text)
        self.assertIn('100.00 / 300.00 / 200.00', text)
        self.assertIn('512.00 / 512.00', text)
        self.assertIn('Status / periodic / smaps samples', text)
        self.assertIn('Independent OS samples after close', text)
        self.assertIn('first complete load follows a cancelled attempt', text)


    def test_pss_uss_unavailability_is_explicit_and_does_not_invent_values(self):
        report = profile_report()
        data = report['loadingOsMemory']
        data['pssUssAvailability'], data['smapsUnavailable'] = 'unavailable', 'Access denied'
        for window in data['windows']:
            window['smapsSampleCount'] = 0
            window['smapsIntervalUs'] = {'count': 0, 'min': None, 'max': None,
                                        'mean': None, 'nonOverlappingBuckets': {}}
            for field in checks.OS_MEMORY_FIELDS[1:]:
                window['sampleMax'][field] = None
                window['sampleMaxAtUs'].pop(field)
        samples = [sample for window in data['windows'] for sample in
                   (window['baseline'], window['terminal'])] + [row['sample'] for row in data['closeSamples']]
        for sample in samples:
            sample.update(smapsRssBytes=None, pssBytes=None, ussBytes=None,
                          smapsTimeUs=None, smapsUnavailable='Access denied')
        checks.validate_profile(report, COMMIT)
        data['smapsUnavailable'] = None
        with self.assertRaises(ValueError): checks.validate_profile(report, COMMIT)

    def test_paddle_latency_requires_changed_state_and_explicit_bounded_scope(self):
        mutations = [(field, None) for field in checks.PADDLE_STATE_FIELDS] + [
            ('pressToPaddleStateMs', 9), ('pressToPaddleStateMs', 5001),
            ('pressToPaddleStateMs', float('nan')),
            ('paddleCenterObservedAfter', 24), ('paddleCenterBefore', -1),
            ('paddleCenterObservedAfter', 48),
            ('paddleStateLatencyMeasurement', 'presented-pixel'),
            ('paddleStateWaitBoundMs', 10000),
            ('paddleStateWaitStartsAt', 'physical-sensor-acknowledgement'),
            ('visualLatencyClaim', True),
        ]
        for direction in checks.PADDLE_STATE_INPUTS:
            for field, value in mutations:
                report = profile_report()
                row = next(row for row in report['inputLatencies'] if row['input'] == direction and row['mode'] == 'optimized')
                if value is None:
                    row.pop(field)
                else:
                    row[field] = value
                with self.subTest(direction=direction, field=field, value=value), self.assertRaises(ValueError):
                    checks.validate_profile(report, COMMIT)

    def test_left_right_require_only_sensor_evidence_and_reject_paddle_claims(self):
        report = profile_report()
        checks.validate_profile(report, COMMIT)
        for direction in ('left', 'right'):
            for field in checks.PADDLE_STATE_FIELDS:
                mutated = copy.deepcopy(report)
                row = next(row for row in mutated['inputLatencies'] if row['input'] == direction)
                row[field] = 125
                with self.subTest(direction=direction, field=field), self.assertRaises(ValueError):
                    checks.validate_profile(mutated, COMMIT)

    def test_summary_separates_sensor_and_decoded_paddle_state_latency(self):
        _, metrics = checks.validate_profile(profile_report(), COMMIT)
        text = checks.markdown({'status': 'passed', 'acceptedReports': 1, 'commit': COMMIT,
                                'errors': [], 'limits': [], 'measurements': {'ui': metrics}})
        self.assertIn('Flutter input to physical sensor acknowledgement', text)
        self.assertIn('Held input to decoded physical paddle state', text)
        self.assertIn('not raster presentation', text)
        self.assertIn('| optimized | up | 2 | 125.00 | 125.00 |', text)
        self.assertNotIn('| standard | left |', text)

    def test_complete_raw_profile_derives_counts_and_budget(self):
        state, metrics = checks.validate_profile(profile_report(), COMMIT)
        self.assertEqual(len(state), 4)
        self.assertEqual(metrics['frames'][0]['frameCount'], 2)
        self.assertEqual(metrics['frames'][0]['overBudgetFrames'], 1)

    def test_old_per_isolate_heap_reports_are_rejected(self):
        report = profile_report()
        report['runtime'].pop('heapMeasurementMethod')
        with self.assertRaises(ValueError):
            checks.validate_profile(report, COMMIT)
        report = profile_report()
        report['memory'][-1]['gc'] = 'requested-all-isolates'
        with self.assertRaises(ValueError):
            checks.validate_profile(report, COMMIT)

    def test_debug_failed_dirty_or_wrong_commit_is_rejected(self):
        for key, value in [('buildMode', 'debug'), ('status', 'failed')]:
            report = profile_report()
            report[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)
        report = profile_report()
        report['runtime']['workingTreeDirty'] = True
        with self.assertRaises(ValueError):
            checks.validate_profile(report, COMMIT)
        with self.assertRaises(ValueError):
            checks.validate_profile(profile_report(), 'c' * 40)

    def test_declared_frames_cannot_replace_actual_samples(self):
        for mutate in ('empty', 'mismatch', 'nan', 'count'):
            report = profile_report()
            row = next(row for row in report['operations']
                       if row['id'] == 'computer.run-physical-program.standard')
            if mutate == 'empty':
                row['samples'][0]['uiUs'] = []
            elif mutate == 'mismatch':
                row['samples'][0]['rasterUs'] = [1000]
            elif mutate == 'nan':
                row['samples'][0]['uiUs'][0] = float('nan')
            else:
                row['frameCount'] = 100
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)

    def test_quick_successful_operation_can_have_no_engine_frame(self):
        report = profile_report()
        row = next(row for row in report['operations'] if row['id'] == 'computer.choose-world.standard')
        row['status'] = 'missing-frames'
        for sample in row['samples']:
            sample['uiUs'] = sample['rasterUs'] = sample['totalSpanUs'] = []
        checks.validate_profile(report, COMMIT)

    def test_equal_but_wrong_input_trace_is_rejected(self):
        report = profile_report()
        for row in report['observations']:
            row['inputEventsAtPhysicalClock'] = [{'atClock': 0, 'x': 6516, 'y': 851, 'mask': 9}]
        with self.assertRaises(ValueError):
            checks.validate_profile(report, COMMIT)

    def test_changed_cpu_or_ram_checkpoint_is_rejected(self):
        for field in ('cpuProbe', 'ram'):
            report = profile_report()
            report['observations'][1]['deterministicTrace'][3][field] = 'c' * 64
            with self.subTest(field=field), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)

    def test_missing_keyboard_touch_heap_or_repeated_close_is_rejected(self):
        for mutate in ('keyboard', 'touch', 'heap', 'close'):
            report = profile_report()
            if mutate in ('keyboard', 'touch'):
                report['inputLatencies'].pop(0 if mutate == 'keyboard' else -1)
            elif mutate == 'heap':
                report['memory'][-1]['heapUsedBytes'] = None
            else:
                report['memory'].pop()
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                checks.validate_profile(report, COMMIT)


def backend_report(optimized=False):
    signatures = [row['expected'] for row in checks.load(
        Path(__file__).resolve().parents[2] / 'native/fixtures/computerraria/programs.json')['main']['checks']]
    def program(values):
        return {'signature': values, 'clocks': 128, 'milliseconds': 100}
    probes = [{'sensor': None, 'run': program([15, 0x600dc0de])}]
    for sensor, bits in (([6516, 851, 9], 8), ([6517, 866, 5], 1),
                         ([6519, 858, 10], 2), ([6520, 857, 5], 4)):
        for pulse in (1, 2, 3, 0, 1):
            probes.append({'sensor': sensor, 'pulse': pulse,
                           'run': program([bits if pulse else 0, 0x600dc0de])})
    probes += [{'sensor': sensor, 'run': program([bits, 0x600dc0de])}
               for sensor, bits in [('up+down', 9), ('all+idleSwitch', 15)]]
    stats = [0] * 13
    stats[0] = 2
    stats[2], stats[3], stats[10], stats[12] = 15200, 7200, 72939714, 13641575
    report = {'schema': 2, 'inputFormat': 'wld-only', 'circuitAbi': 2, 'status': 'passed', 'optimizationEnabled': optimized,
              'defaultOptimization': False, 'activeOptimizationAtStart': optimized,
              'activeOptimizationAtEnd': optimized,
              'pixelRule': 'wirehead-color-pair-wave' if optimized else 'game-tripwire-crossing',
              'displayCompatibility': {'status': 'supported' if optimized else 'unsupported-under-game-rules',
                  'expectedBehavior': 'moving-pong' if optimized else 'recorded-without-pong-display-claim'},
              'readyMetadata': {'flags': 14 if optimized else 4, 'optimizationEnabled': optimized,
                  'topologyEligible': True, 'wireHeadPixelRulesEnabled': optimized},
              'librarySha256': HASH, 'idleSwitchPreservesState': True,
              'nativeBytesAfterClose': 0,
              'import': {'sourceSha256': checks.WLD_SHA,
                         'stats': stats, 'milliseconds': 100},
              'main': program(signatures),
              'negativeControl': program([0x7fffffff, *signatures[1:]]),
              'displayProgram': program([0x600dc0de]), 'inputProbes': probes,
              'display': {'mono': [[6485, 800, 0, 18], [6516, 800, 0, 18]] if optimized else []},
              'correctness': {key: HASH for key in ('displayMonoSha256', 'pongFinalMonoSha256')},
              'pong': {'binarySha256': checks.PONG_SHA, 'bytes': 2288, 'clocks': 1536,
                       'cpuTraceMeasurement': 'passive-ready-and-1088-ram-bytes-no-reset-bus',
                       'cpuTrace': [{'clocks': n, 'ready': True, 'ramSha256': f'{n:064x}'} for n in range(128,1537,128)],
                       'displayStatus': 'moving' if optimized else 'expected-dark',
                       'frames': [{'clocks': clock, 'sha256': HASH, 'lit': [[2, 4]] if optimized else []}
                                  for clock in (128, 256, 384)],
                       'clockSamples': [{'pulses': 128, 'milliseconds': 10}]},
              'save': {'status': 'passed', 'worldBytes': 405983441,
                       'worldSha256': HASH, 'milliseconds': 100, 'beforeRamSha256': HASH, 'reopenedRamSha256': HASH,
                       **{key: {'mono': HASH} for key in
                          ('beforeDisplaySha256', 'reopenedDisplaySha256', 'postProgramDisplaySha256')}}}
    return report, {'artifacts': {'libabc_engine.so': {'sha256': HASH}}}, signatures


def web_backend_report(optimized=False, compound=True):
    report, _, signatures = backend_report(optimized)
    report.update(schema='abc.computerraria.web-file-acceptance.v2',
                  requestedOptimization=optimized, defaultOptimization=False,
                  activeOptimizationAtStart=optimized, activeOptimizationAtEnd=optimized,
                  loaderSha256=HASH, wasmSha256=HASH,
                  bridgeBytesAfterClose=0, openFilesAfterClose=0,
                  clock128Timing={'measurement': checks.WEB_COMPOUND_CLOCK_MEASUREMENT if compound
                                  else checks.WEB_AWAITED_CLOCK_MEASUREMENT,
                                  'samples': [{'phase': 'pong', 'optimized': optimized,
                                               'milliseconds': 10} for _ in range(2)]})
    report['pong']['modeFlips'] = [
        {'clocks': clock, 'optimized': enabled, 'session': 1,
         'monoSha256': HASH, 'lampSha256': HASH}
        for clock, enabled in [(512, not optimized), (640, optimized)]]
    if compound:
        report['compoundFrame'] = {
            'status': 'passed', 'transport': checks.WEB_COMPOUND_TRANSPORT,
            'samples': [{'phase': 'pong', 'optimized': optimized,
                         'monitor': monitor, 'recordsBytes': count * 16,
                         'recordsSha256': HASH, 'clockCommandMilliseconds': 10,
                         'roundTripMilliseconds': 12}
                        for monitor, count in [('mono', 3072), ('mono', 3072)]]}
    return report, {'artifacts': {name: {'sha256': HASH} for name in ('world.js', 'world.wasm')}}, signatures


class BackendEvidenceTests(unittest.TestCase):
    def test_mode_pixel_difference_does_not_hide_cpu_divergence(self):
        off, build, signatures = backend_report(False)
        on, _, _ = backend_report(True)
        a, _ = checks.validate_backend(off, 'native', 'standard', build, signatures)
        b, _ = checks.validate_backend(on, 'native', 'optimized', build, signatures)
        self.assertNotEqual(a, b)
        self.assertEqual(checks.backend_cpu_projection(a), checks.backend_cpu_projection(b))
        b['pong']['cpuTrace'][0]['ramSha256'] = 'c' * 64
        self.assertNotEqual(checks.backend_cpu_projection(a), checks.backend_cpu_projection(b))

    def test_missing_rule_liveness_or_successful_off_display_claim_is_rejected(self):
        for failure in ('rule', 'ready', 'compatibility', 'halted', 'missing-point', 'saved-ram'):
            report, build, signatures = backend_report()
            if failure == 'rule': report.pop('pixelRule')
            elif failure == 'ready': report['readyMetadata']['flags'] = 2
            elif failure == 'compatibility': report['displayCompatibility']['status'] = 'supported'
            elif failure == 'halted':
                for row in report['pong']['cpuTrace']: row['ramSha256'] = HASH
            elif failure == 'missing-point': report['pong']['cpuTrace'].pop()
            else: report['save']['reopenedRamSha256'] = 'c' * 64
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                checks.validate_backend(report, 'native', 'standard', build, signatures)

    def test_legacy_abi_or_non_wld_report_cannot_supply_new_golden(self):
        for key, value in (('schema', 1), ('inputFormat', 'legacy'), ('circuitAbi', 1)):
            report, build, signatures = backend_report()
            report[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                checks.validate_backend(report, 'native', 'standard', build, signatures)

    def test_compound_scope_and_roundtrip_are_separate_from_clock_time(self):
        report, build, signatures = web_backend_report()
        _, metrics = checks.validate_backend(report, 'web', 'standard', build, signatures,
                                             require_compound=True)
        self.assertEqual(metrics['clockMeasurementScope'], 'node-bridge-clock-stage-v1')
        self.assertEqual(metrics['clockPulsesPerSecond'], 12800)
        self.assertEqual(metrics['compoundRoundTrip']['medianMs'], 12)

    def test_ci_requires_compound_but_historical_scope_stays_explicit(self):
        report, build, signatures = web_backend_report(compound=False)
        _, metrics = checks.validate_backend(report, 'web', 'standard', build, signatures)
        self.assertEqual(metrics['clockMeasurementScope'], 'node-awaited-clock-command-v1')
        with self.assertRaises(ValueError):
            checks.validate_backend(report, 'web', 'standard', build, signatures, require_compound=True)

    def test_compound_missing_selection_or_misleading_measurement_is_rejected(self):
        for failure in ('transport', 'scope', 'count', 'monitor', 'bytes', 'mixed-time', 'short-roundtrip'):
            report, build, signatures = web_backend_report()
            compound = report['compoundFrame']
            if failure == 'transport':
                compound['transport'] = 'Actual browser worker FPS'
            elif failure == 'scope':
                report['clock128Timing']['measurement'] = checks.WEB_AWAITED_CLOCK_MEASUREMENT
            elif failure == 'count':
                compound['samples'].pop()
            elif failure == 'monitor':
                compound['samples'][1]['monitor'] = 'unsupported'
            elif failure == 'bytes':
                compound['samples'][1]['recordsBytes'] = 16
            elif failure == 'mixed-time':
                report['clock128Timing']['samples'][0]['milliseconds'] = 12
            else:
                compound['samples'][0]['roundTripMilliseconds'] = 9
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                checks.validate_backend(report, 'web', 'standard', build, signatures, require_compound=True)

    def test_summary_does_not_pool_different_clock_measurement_scopes(self):
        values = {}
        for compound in (False, True):
            report, build, signatures = web_backend_report(compound=compound)
            _, values[str(compound)] = checks.validate_backend(report, 'web', 'standard', build, signatures)
        text = checks.markdown({'status': 'passed', 'acceptedReports': 2, 'commit': COMMIT,
                                'errors': [], 'limits': [], 'measurements': values})
        self.assertIn('| web | standard | node-awaited-clock-command-v1 | 1 |', text)
        self.assertIn('| web | standard | node-bridge-clock-stage-v1 | 1 |', text)
        self.assertIn('same-thread Node', text)
        self.assertIn('not browser threading, rendering or FPS', text)

    def test_reported_actual_mode_and_wld_digest_are_required(self):
        for mutate in ('default', 'start', 'end', 'wld'):
            report, build, signatures = backend_report()
            if mutate == 'wld':
                report['import']['sourceSha256'] = HASH
            else:
                key = {'default': 'defaultOptimization', 'start': 'activeOptimizationAtStart',
                       'end': 'activeOptimizationAtEnd'}[mutate]
                report[key] = True
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                checks.validate_backend(report, 'native', 'standard', build, signatures)

    def test_only_timing_changes_are_excluded_from_exact_state_comparison(self):
        report, build, signatures = backend_report()
        before, _ = checks.validate_backend(report, 'native', 'standard', build, signatures)
        before = copy.deepcopy(before)
        report['main']['milliseconds'] = 900
        report['save']['milliseconds'] = 700
        report['pong']['clockSamples'][0]['milliseconds'] = 20
        after, metrics = checks.validate_backend(report, 'native', 'standard', build, signatures)
        self.assertEqual(before, after)
        self.assertEqual(metrics['clockPulsesPerSecond'], 6400)
        report['save']['postProgramDisplaySha256']['mono'] = 'c' * 64
        changed, _ = checks.validate_backend(report, 'native', 'standard', build, signatures)
        self.assertNotEqual(before, changed)

    def test_original_latched_inputs_and_direction_bits_are_enforced(self):
        for index, wrong in ((0, 0), (1, 1), (6, 8)):
            report, build, signatures = backend_report()
            report['inputProbes'][index]['run']['signature'][0] = wrong
            with self.subTest(index=index), self.assertRaises(ValueError):
                checks.validate_backend(report, 'native', 'standard', build, signatures)

    def test_save_reopen_must_preserve_complete_records(self):
        report, build, signatures = backend_report()
        report['save']['reopenedDisplaySha256']['mono'] = 'c' * 64
        with self.assertRaises(ValueError):
            checks.validate_backend(report, 'native', 'standard', build, signatures)


class ManifestTests(unittest.TestCase):
    def test_actual_profile_c_compiler_flags_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder) / 'CMakeCache.txt'
            cache.write_text('CMAKE_BUILD_TYPE:STRING=Profile\nCMAKE_C_FLAGS_PROFILE:STRING=-O3 -DNDEBUG\n')
            self.assertEqual(provenance.cmake_settings(cache)['CMAKE_BUILD_TYPE'], 'Profile')
            ninja = Path(folder) / 'build.ninja'
            names = ('abc_world_circuit.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o')
            ninja.write_text('\n'.join(f'build obj/{name}: C_COMPILER source.c\n  FLAGS = -O3 -DNDEBUG -fPIC'
                                       for name in names))
            flags = provenance.ninja_flags(ninja)
            self.assertEqual(set(flags), set(names))
            ninja.write_text('build unrelated.o: C_COMPILER source.c\n  FLAGS = -O3 -DNDEBUG\n')
            with self.assertRaises(ValueError):
                provenance.ninja_flags(ninja)

    def test_full_campaign_accepts_then_detects_one_changed_mode_state(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = {'commit': COMMIT, 'checkedOutHead': COMMIT, 'dirty': False}
            files = {'native/test-only-source': HASH}
            tree_hash = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            input_manifest = {'schema': 'abc.public-computerraria-inputs.v2', 'status': 'verified', 'sourceRevision': checks.REVISION,
                              'inputs': [{'name': name, 'bytes': size, 'sha256': sha}
                                         for name, (size, sha) in checks.EXPECTED_INPUTS.items()],
                              'world': {'format': 279, 'width': 15200, 'height': 7200}}
            def write(path, value):
                path.write_text(json.dumps(value))
            for lane in ('native', 'web', 'ui'):
                directory = root / f'computerraria-raw-{lane}'
                directory.mkdir()
                write(directory / 'input-manifest.json', input_manifest)
                names = {'native': ['libabc_engine.so'], 'web': ['world.js', 'world.wasm'],
                         'ui': ['terraforge', 'libapp.so', 'libabc_engine.so']}[lane]
                build = {'schema': 'abc.computerraria.build.v1', 'source': source,
                         'sourceFilesSha256': files, 'sourceTreeSha256': tree_hash,
                         'cmake': {'CMAKE_BUILD_TYPE': 'Profile' if lane == 'ui' else 'Release'},
                         'artifacts': {name: {'sha256': HASH, 'bytes': 100} for name in names}}
                if lane == 'ui':
                    build['effectiveCompileFlags'] = {name: '-O3 -DNDEBUG' for name in
                        ('abc_world_circuit.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o')}
                    (directory / 'glxinfo.txt').write_text('test-only software renderer')
                else:
                    write(directory / 'build.json', build)
                if lane == 'web':
                    write(directory / 'engine-manifest.json', {'emscripten': '5.0.7', 'artifacts': build['artifacts']})
                for mode in (['ui'] if lane == 'ui' else checks.MODES):
                    suite = f'computerraria-{lane}' + ('' if lane == 'ui' else f'-{mode}')
                    for run in range(1, 4):
                        path = directory / f'{suite}.run-{run}.json'
                        if lane == 'ui':
                            report = profile_report()
                            write(path.with_suffix('.build.json'), build)
                        else:
                            optimized = mode == 'optimized'
                            report, _, _ = backend_report(optimized)
                            report['optimizationEnabled'] = optimized
                            report['activeOptimizationAtStart'] = optimized
                            report['activeOptimizationAtEnd'] = optimized
                            if lane == 'web':
                                report, _, _ = web_backend_report(optimized)
                        write(path, report)
                        path.with_suffix('.log').write_text('Synthetic helper fixture only\n')
                        write(path.with_suffix('.execution.json'), {
                            'schema': 'abc.performance-execution.v1', 'suite': suite, 'report': path.name,
                            'status': 'passed', 'exitCode': 0, 'source': source, 'runId': path.name,
                            'pid': run, 'completedAt': 'test-only', 'elapsedSeconds': 1,
                            'reportSha256': checks.digest(path)})
            result = checks.compare(root, COMMIT)
            self.assertEqual(result['errors'], [])
            self.assertEqual(result['acceptedReports'], 15)
            path = root / 'computerraria-raw-web/computerraria-web-optimized.run-3.json'
            report = checks.load(path)
            report['correctness']['pongFinalMonoSha256'] = 'c' * 64
            write(path, report)
            execution_path = path.with_suffix('.execution.json')
            execution = checks.load(execution_path)
            execution['reportSha256'] = checks.digest(path)
            write(execution_path, execution)
            result = checks.compare(root, COMMIT)
            self.assertEqual(result['status'], 'failed')
            self.assertTrue(any('exact same-mode deterministic states differ' in error for error in result['errors']))

    def test_missing_reports_are_blockers_and_still_render_summary(self):
        with tempfile.TemporaryDirectory() as folder:
            result = checks.compare(Path(folder), COMMIT)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['acceptedReports'], 0)
        self.assertIn('0/15', checks.markdown(result))

    def test_execution_status_and_exact_report_hash_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'example.run-1.json'
            path.write_text('{"status":"passed"}')
            path.with_suffix('.log').write_text('synthetic helper test\n')
            manifest = {'schema': 'abc.performance-execution.v1', 'suite': 'example',
                        'report': path.name, 'status': 'passed', 'exitCode': 0,
                        'source': {'commit': COMMIT, 'checkedOutHead': COMMIT, 'dirty': False},
                        'runId': 'one', 'pid': 123, 'completedAt': 'time', 'elapsedSeconds': 1,
                        'reportSha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            record_path = path.with_suffix('.execution.json')
            record_path.write_text(json.dumps(manifest))
            checks.validate_execution(record_path, path, 'example', COMMIT)
            for key, value in [('status', 'timeout'), ('exitCode', 1), ('reportSha256', HASH)]:
                bad = dict(manifest, **{key: value})
                record_path.write_text(json.dumps(bad))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    checks.validate_execution(record_path, path, 'example', COMMIT)

    def test_pinned_input_identity_rejects_small_or_substituted_world(self):
        manifest = {'schema': 'abc.public-computerraria-inputs.v2', 'status': 'verified', 'sourceRevision': checks.REVISION,
                    'inputs': [{'name': name, 'bytes': size, 'sha256': sha}
                               for name, (size, sha) in checks.EXPECTED_INPUTS.items()],
                    'world': {'format': 279, 'width': 15200, 'height': 7200}}
        checks.validate_inputs(manifest)
        manifest['inputs'][1]['bytes'] = 1024
        with self.assertRaises(ValueError):
            checks.validate_inputs(manifest)


if __name__ == '__main__':
    unittest.main()
