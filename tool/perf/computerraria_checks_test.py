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
                'deterministicTrace': [{'pulses': pulse, 'mono': HASH, 'color': HASH, 'ram': HASH}
                                       for pulse in range(512, 5121, 512)],
                'inputEventsAtPhysicalClock': copy.deepcopy(checks.FIXED_INPUT_EVENTS),
                'steadyWindowMs': 30000, 'steadyPhysicalPulses': 10240,
                'observedDisplayChanges': 3, 'nativeActiveBytes': 50, 'nativePeakBytes': 100,
                'clockHz': 10240 / 30, 'displayPollHz': 20})
            for direction in ('up', 'down', 'left', 'right', 'touch-hold-down'):
                latencies.append({'cycle': cycle, 'mode': mode, 'input': direction,
                                  'pressToPhysicalSensorMs': 10, 'acceptedAtClock': 128,
                                  'releaseToVerifiedNoMorePulsesMs': 50,
                                  'visualLatencyClaim': False})
            for phase in ('paused-after-steady-run', 'after-close'):
                memory.append(snapshot(phase, cycle=cycle, mode=mode))
    return {
        'schema': 1, 'status': 'passed', 'buildMode': 'profile', 'cycles': 2,
        'steadySecondsPerMode': 30, 'modes': list(checks.MODES), 'clockBatchPulses': 128,
        'traceTotalPulses': 5120, 'excludedWarmupCycles': 0,
        'runtime': {'heapMeasurementMethod': checks.HEAP_MEASUREMENT_METHOD, 'commit': COMMIT, 'checkedOutHead': COMMIT, 'workingTreeDirty': False,
                    'platform': 'linux', 'flutterVersion': '3.47.6', 'renderer': 'llvmpipe',
                    'runner': 'test-fixture', 'dartVersion': 'test', 'osVersion': 'test'},
        'toolchain': {'flutterRevisionPin': checks.FLUTTER_REVISION},
        'viewport': {'physicalWidth': 1440, 'physicalHeight': 1000, 'devicePixelRatio': 1},
        'fixture': {'wldSha256': checks.WLD_SHA, 'twldSha256': checks.TWLD_SHA,
                    'wldBytes': 405983441, 'twldBytes': 427712},
        'displayRefreshRateHz': 60, 'frameBudgetUs': 1000000 / 60,
        'frameBudgetSource': 'observed-display-refresh-rate', 'operations': operations,
        'observations': observations, 'inputLatencies': latencies, 'memory': memory,
    }


class ProfileEvidenceTests(unittest.TestCase):
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
                       if row['id'] == 'computer.run-displayed-pong.standard')
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
        row = next(row for row in report['operations'] if row['id'] == 'computer.choose-pair.standard')
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

    def test_changed_physical_pixel_or_ram_checkpoint_is_rejected(self):
        for field in ('mono', 'color', 'ram'):
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


def backend_report():
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
    stats[2], stats[3], stats[10], stats[12] = 15200, 7200, 72939714, 13641575
    report = {'schema': 1, 'status': 'passed', 'optimizationEnabled': False,
              'defaultOptimization': False, 'activeOptimizationAtStart': False,
              'activeOptimizationAtEnd': False,
              'librarySha256': HASH, 'idleSwitchPreservesState': True,
              'nativeBytesAfterClose': 0,
              'import': {'sourceSha256': checks.WLD_SHA, 'twldSourceSha256': checks.TWLD_SHA,
                         'stats': stats, 'milliseconds': 100},
              'main': program(signatures),
              'negativeControl': program([0x7fffffff, *signatures[1:]]),
              'displayProgram': program([0x600dc0de]), 'inputProbes': probes,
              'display': {'mono': [[6485, 800, 0, 18]], 'color': [[7371, 1002, 0, 54]]},
              'correctness': {key: HASH for key in ('displayMonoSha256', 'displayColorSha256',
                                                   'pongFinalMonoSha256', 'pongFinalColorSha256')},
              'pong': {'binarySha256': checks.PONG_SHA, 'bytes': 2288, 'clocks': 384,
                       'frames': [{'clocks': clock, 'sha256': HASH, 'lit': [[2, 4]]}
                                  for clock in (128, 256, 384)],
                       'clockSamples': [{'pulses': 128, 'milliseconds': 10}]},
              'save': {'status': 'passed', 'worldBytes': 405983441, 'twldBytes': 427712,
                       'worldSha256': HASH, 'twldSha256': HASH, 'milliseconds': 100,
                       **{key: {'mono': HASH, 'color': HASH} for key in
                          ('beforeDisplaySha256', 'reopenedDisplaySha256', 'postProgramDisplaySha256')}}}
    return report, {'artifacts': {'libabc_engine.so': {'sha256': HASH}}}, signatures


def web_backend_report(optimized=False, compound=True):
    report, _, signatures = backend_report()
    report.update(schema='abc.computerraria.web-file-acceptance.v1',
                  requestedOptimization=optimized, defaultOptimization=False,
                  activeOptimizationAtStart=optimized, activeOptimizationAtEnd=optimized,
                  twldSha256=checks.TWLD_SHA, loaderSha256=HASH, wasmSha256=HASH,
                  bridgeBytesAfterClose=0, openFilesAfterClose=0,
                  clock128Timing={'measurement': checks.WEB_COMPOUND_CLOCK_MEASUREMENT if compound
                                  else checks.WEB_AWAITED_CLOCK_MEASUREMENT,
                                  'samples': [{'phase': 'pong', 'optimized': optimized,
                                               'milliseconds': 10} for _ in range(2)]})
    report['pong']['modeFlips'] = [
        {'clocks': clock, 'optimized': enabled, 'session': 1,
         'monoSha256': HASH, 'colorSha256': HASH, 'lampSha256': HASH}
        for clock, enabled in [(512, not optimized), (640, optimized)]]
    if compound:
        report['compoundFrame'] = {
            'status': 'passed', 'transport': checks.WEB_COMPOUND_TRANSPORT,
            'samples': [{'phase': 'pong', 'optimized': optimized,
                         'monitor': monitor, 'recordsBytes': count * 16,
                         'recordsSha256': HASH, 'clockCommandMilliseconds': 10,
                         'roundTripMilliseconds': 12}
                        for monitor, count in [('mono', 3072), ('color', 16896)]]}
    return report, {'artifacts': {name: {'sha256': HASH} for name in ('world.js', 'world.wasm')}}, signatures


class BackendEvidenceTests(unittest.TestCase):
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
                compound['samples'][1]['monitor'] = 'mono'
            elif failure == 'bytes':
                compound['samples'][1]['recordsBytes'] = 3072 * 16
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

    def test_reported_actual_mode_and_companion_digest_are_required(self):
        for mutate in ('default', 'start', 'end', 'twld'):
            report, build, signatures = backend_report()
            if mutate == 'twld':
                report['import']['twldSourceSha256'] = HASH
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
        report['save']['reopenedDisplaySha256']['color'] = 'c' * 64
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
            input_manifest = {'status': 'verified', 'sourceRevision': checks.REVISION,
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
                            report, _, _ = backend_report()
                            optimized = mode == 'optimized'
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
            report['correctness']['pongFinalColorSha256'] = 'c' * 64
            write(path, report)
            execution_path = path.with_suffix('.execution.json')
            execution = checks.load(execution_path)
            execution['reportSha256'] = checks.digest(path)
            write(execution_path, execution)
            result = checks.compare(root, COMMIT)
            self.assertEqual(result['status'], 'failed')
            self.assertTrue(any('exact deterministic states differ' in error for error in result['errors']))

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
        manifest = {'status': 'verified', 'sourceRevision': checks.REVISION,
                    'inputs': [{'name': name, 'bytes': size, 'sha256': sha}
                               for name, (size, sha) in checks.EXPECTED_INPUTS.items()],
                    'world': {'format': 279, 'width': 15200, 'height': 7200}}
        checks.validate_inputs(manifest)
        manifest['inputs'][1]['bytes'] = 1024
        with self.assertRaises(ValueError):
            checks.validate_inputs(manifest)


if __name__ == '__main__':
    unittest.main()
