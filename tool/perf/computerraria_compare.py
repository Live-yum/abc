#!/usr/bin/env python3
"""Fail closed on incomplete full-world evidence; compare states, not timings."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics

from computerraria_provenance import digest

HEAP_MEASUREMENT_METHOD = 'vm-service-isolate-groups-v1'
WEB_AWAITED_CLOCK_MEASUREMENT = 'Only the awaited128-clock command, including bounded owner dispatch; excludes ROM loading, state reads and rendering'
WEB_COMPOUND_CLOCK_MEASUREMENT = 'Only the worker bridge clock command hostStagesUs.commandWallUs; excludes compound display read and loopback round trip, and is not the legacy externally-awaited timing'
WEB_COMPOUND_TRANSPORT = 'Actual RPC client/host and structuredClone ArrayBuffer transfers in a Node loopback, both endpoints on one thread; immutable fs.openAsBlob handles preserved by identity because Node24 forbids cloning them; not browser File transfer, threading or timing proof'

REVISION = '0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8'
WLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
TWLD_SHA = 'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8'
PONG_SHA = 'd2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d'
FLUTTER_REVISION = '5fc346839b5d0eef006ed8404392afb4dfae428d'
EXPECTED_INPUTS = {
    'computerraria.tar.gz': (2871121, '31423b4f7ebbecceeaa54f982f02980efa5b8edccede5456456d892b0452ea1a'),
    'computerraria.wld': (405983441, WLD_SHA),
    'computerraria.twld': (427712, TWLD_SHA),
}
MODES = ('standard', 'optimized')
CORE_OPERATIONS = ('choose-pair', 'import', 'load-pong', 'same-program-input-trace',
                   'idle-mode-roundtrip', 'run-displayed-pong',
                   'single-physical-clock', 'reset-original', 'close',
                   'keyboard-up', 'keyboard-down', 'keyboard-left',
                   'keyboard-right', 'touch-hold-down')
FIXED_INPUT_EVENTS = [
    {'atClock': batch * 128, 'x': x, 'y': y, 'mask': mask}
    for batches, x, y, mask in ((range(8, 12), 6516, 851, 9),
                                (range(20, 26), 6517, 866, 5))
    for batch in batches
]


def require(value, message):
    if not value:
        raise ValueError(message)


def number(value, label, minimum=0):
    require(isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value >= minimum, f'Invalid {label}')
    return value


def sha(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value),
            'Missing or malformed SHA-256')
    return value


def load(path):
    with Path(path).open() as source:
        data = json.load(source)
    require(isinstance(data, dict), f'{path}: object report required')
    return data


def validate_source(source, commit):
    require(source.get('commit') == commit and source.get('checkedOutHead') == commit,
            'Evidence was not generated from the requested exact HEAD')
    require(source.get('dirty') is False, 'Dirty or unknown source state')


def validate_build(build, commit, configuration):
    require(build['schema'] == 'abc.computerraria.build.v1', 'Unknown build schema')
    validate_source(build['source'], commit)
    files = build['sourceFilesSha256']
    require(files and all(sha(value) for value in files.values()), 'Missing source hashes')
    require(hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':'))
                           .encode()).hexdigest() == build['sourceTreeSha256'],
            'Build source tree digest mismatch')
    require(build['artifacts'], 'Missing built artifact hashes')
    for artifact in build['artifacts'].values():
        sha(artifact['sha256'])
        number(artifact['bytes'], 'artifact length', 1)
    require(build['cmake']['CMAKE_BUILD_TYPE'] == configuration,
            'Actual CMake configuration differs from required build mode')
    if configuration == 'Profile':
        flags = build['effectiveCompileFlags']
        require(set(flags) == {'abc_world_circuit.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o'},
                'Missing actual generated wiring VM compiler flags')
        require(all('-O3' in value.split() and '-DNDEBUG' in value.split() for value in flags.values()),
                'Flutter profile must use Release-optimized C wiring VM flags')


def validate_inputs(manifest):
    require(manifest['status'] == 'verified' and manifest['sourceRevision'] == REVISION,
            'Pinned public input manifest missing or changed')
    actual = {entry['name']: (entry['bytes'], entry['sha256'])
              for entry in manifest['inputs']}
    require(actual == EXPECTED_INPUTS, 'Public inputs do not match all pinned bytes/hashes')
    require(manifest['world'] == {'format': 279, 'width': 15200, 'height': 7200},
            'Fixture is not the complete format-279 15200×7200 world')


def validate_execution(path, report_path, suite, commit):
    record = load(path)
    require(record['schema'] == 'abc.performance-execution.v1', 'Missing execution schema')
    require(record['suite'] == suite and record['report'] == report_path.name,
            'Execution manifest names a different report/suite')
    require(record['status'] == 'passed' and record['exitCode'] == 0,
            'Process failed, timed out or did not finish')
    validate_source(record['source'], commit)
    require(record.get('runId') and record.get('pid') and record.get('completedAt'),
            'Missing independent process completion metadata')
    require(record['reportSha256'] == digest(report_path), 'Raw report digest mismatch')
    require(report_path.with_suffix('.log').is_file(), 'Missing retained process log')
    number(record['elapsedSeconds'], 'execution wall time', .001)
    return record


def program_projection(value):
    require(isinstance(value['signature'], list) and value['signature'], 'Missing physical RAM signature')
    require(all(type(word) is int and 0 <= word <= 0xffffffff
                for word in value['signature']), 'Invalid physical RAM words')
    number(value['clocks'], 'executed physical clocks', 1)
    return {'signature': value['signature'], 'clocks': value['clocks']}


def validate_compound_frames(report, optimized, required=False):
    timing = report['clock128Timing']
    compound = report.get('compoundFrame')
    if compound is None:
        require(not required, 'CI Web evidence must exercise compound RPC')
        require(timing.get('measurement') == WEB_AWAITED_CLOCK_MEASUREMENT,
                'Unknown legacy Web clock measurement scope')
        return 'node-awaited-clock-command-v1', None
    require(compound.get('status') == 'passed'
            and compound.get('transport') == WEB_COMPOUND_TRANSPORT,
            'Compound evidence must label Node loopback and file-Blob identity limits')
    require(timing.get('measurement') == WEB_COMPOUND_CLOCK_MEASUREMENT,
            'Compound clock-only scope must exclude display and roundtrip time')
    frames, clocks = compound['samples'], timing['samples']
    require(isinstance(frames, list) and len(frames) == len(clocks) and len(frames) >= 2,
            'Every clock batch must have compound selected-monitor evidence')
    for index, (frame, clock) in enumerate(zip(frames, clocks)):
        monitor = 'mono' if index % 2 == 0 else 'color'
        require(frame['monitor'] == monitor
                and frame['recordsBytes'] == (3072 if monitor == 'mono' else 16896) * 16,
                'Compound monitor alternation or record length is wrong')
        require(frame['phase'] == clock['phase']
                and type(frame['optimized']) is bool
                and frame['optimized'] is clock['optimized'],
                'Compound and clock samples describe different batches')
        sha(frame['recordsSha256'])
        clock_ms = number(frame['clockCommandMilliseconds'], 'compound clock-only time', .000001)
        roundtrip_ms = number(frame['roundTripMilliseconds'], 'compound loopback roundtrip', .000001)
        require(clock_ms == clock['milliseconds'] and roundtrip_ms + .000001 >= clock_ms,
                'Clock-only and compound roundtrip timings were mixed')
    pong = [row for row in frames if row['phase'] == 'pong']
    require({row['monitor'] for row in pong} == {'mono', 'color'},
            'Actual Pong must exercise both compound monitor selections')
    values = [row['roundTripMilliseconds'] for row in pong if row['optimized'] is optimized]
    require(values, 'Missing requested-mode compound Pong roundtrips')
    return 'node-bridge-clock-stage-v1', {
        'scope': 'node-loopback-clock-and-selected-display-v1',
        'samples': len(values), 'medianMs': statistics.median(values),
        'p95Ms': sorted(values)[math.ceil(len(values) * .95) - 1],
        'maxMs': max(values),
    }


def validate_backend(report, backend, mode, build, expected_signatures, *, require_compound=False):
    require(report['status'] == 'passed', 'Physical acceptance did not pass')
    optimized = mode == 'optimized'
    require(report['defaultOptimization'] is False
            and report['activeOptimizationAtStart'] is optimized
            and report['activeOptimizationAtEnd'] is optimized,
            'Default or observed active optimization state is wrong')
    if backend == 'native':
        require(report['schema'] == 1 and report['optimizationEnabled'] is optimized,
                'Wrong Native schema or optimization mode')
        require(report['librarySha256'] == build['artifacts']['libabc_engine.so']['sha256'],
                'Native report did not use the recorded artifact')
        require(report['idleSwitchPreservesState'] is True, 'Idle switch preservation missing')
        require(report['import']['twldSourceSha256'] == TWLD_SHA, 'Wrong Native TWLD identity')
    else:
        require(report['schema'] == 'abc.computerraria.web-file-acceptance.v1'
                and report['requestedOptimization'] is optimized,
                'Wrong Web schema or optimization mode')
        require(report['twldSha256'] == TWLD_SHA, 'Wrong Web TWLD')
        for field, filename in [('loaderSha256', 'world.js'), ('wasmSha256', 'world.wasm')]:
            require(report[field] == build['artifacts'][filename]['sha256'],
                    'Web report did not use the recorded release artifacts')
        require(report['bridgeBytesAfterClose'] == 0 and report['openFilesAfterClose'] == 0,
                'Web owners/files remain after close')
    require(report['nativeBytesAfterClose'] == 0, 'Native allocations remain after close')
    opened = report['import']
    require(opened['sourceSha256'] == WLD_SHA, 'Report did not open the complete original WLD')
    require([opened['stats'][i] for i in (2, 3, 10, 12)] ==
            [15200, 7200, 72939714, 13641575], 'Whole-world import counts mismatch')
    main = program_projection(report['main'])
    negative = program_projection(report['negativeControl'])
    require(main['signature'] == expected_signatures and len(expected_signatures) == 48,
            '48 physical CPU checks missing or incorrect')
    require(negative['signature'] == [0x7fffffff, *expected_signatures[1:]],
            'Actual ROM negative control missing or incorrect')
    probes = []
    require(len(report['inputProbes']) == 23, 'Incomplete sticky/read-clear input probe trace')
    for row in report['inputProbes']:
        probes.append({key: value for key, value in row.items() if key != 'run'} |
                      {'run': program_projection(row['run'])})
    # The original world's four input latches are initially set. Only the low
    # four bits are input state; the verified source contains other bus bits.
    expected_probes = [(None, None, 15)]
    for sensor, bit in (([6516, 851, 9], 8), ([6517, 866, 5], 1),
                        ([6519, 858, 10], 2), ([6520, 857, 5], 4)):
        expected_probes += [(sensor, pulse, bit if pulse else 0) for pulse in (1, 2, 3, 0, 1)]
    expected_probes += [('up+down', None, 9), ('all+idleSwitch', None, 15)]
    for actual, (sensor, pulse, bits) in zip(probes, expected_probes):
        require(actual.get('sensor') == sensor and actual.get('pulse') == pulse,
                'Physical sensor probe sequence changed')
        require(len(actual['run']['signature']) == 2
                and actual['run']['signature'][0] & 15 == bits
                and actual['run']['signature'][1] == 0x600dc0de,
                'Sticky/read-clear physical keyboard signature mismatch')
    correctness = report['correctness']
    for key in ('displayMonoSha256', 'displayColorSha256',
                'pongFinalMonoSha256', 'pongFinalColorSha256'):
        sha(correctness[key])
    pong = report['pong']
    require(pong['binarySha256'] == PONG_SHA and pong['bytes'] == 2288,
            'Pong is not the pinned upstream program')
    number(pong['clocks'], 'Pong physical clocks', 1)
    require(len(pong['frames']) >= 3, 'Missing real moving Pong states')
    previous = 0
    for frame in pong['frames']:
        require(frame['clocks'] > previous, 'Pong checkpoint clocks must increase')
        previous = frame['clocks']
        sha(frame['sha256'])
        require(isinstance(frame['lit'], list), 'Actual lit-pixel coordinates missing')
    saved = report['save']
    require(saved['status'] == 'passed', 'Complete paired save/reopen was not verified')
    for key in ('worldBytes', 'twldBytes'):
        number(saved[key], key, 1)
    for key in ('worldSha256', 'twldSha256'):
        sha(saved[key])
    for phase in ('beforeDisplaySha256', 'reopenedDisplaySha256', 'postProgramDisplaySha256'):
        for display in ('mono', 'color'):
            sha(saved[phase][display])
    require(saved['beforeDisplaySha256'] == saved['reopenedDisplaySha256'],
            'Paired save changed complete physical display records')
    projection = {
        'main': main, 'negativeControl': negative, 'inputProbes': probes,
        'displayProgram': program_projection(report['displayProgram']),
        'display': {'mono': report['display']['mono'], 'color': report['display']['color']},
        'correctness': correctness,
        'pong': {key: pong[key] for key in ('binarySha256', 'bytes', 'clocks', 'frames')},
        'save': {key: saved[key] for key in ('worldBytes', 'twldBytes', 'worldSha256',
                  'twldSha256', 'beforeDisplaySha256', 'reopenedDisplaySha256',
                  'postProgramDisplaySha256')},
    }
    if backend == 'web':
        flips = pong['modeFlips']
        require(len(flips) == 2 and [row['optimized'] for row in flips] == [not optimized, optimized],
                'Missing both live Pong idle mode transitions')
        require(flips[0]['session'] == flips[1]['session'], 'Idle toggle replaced the active session')
        for row in flips:
            for key in ('monoSha256', 'colorSha256', 'lampSha256'):
                sha(row[key])
        projection['idleModeFlipStates'] = [{key: row[key] for key in
                                           ('clocks', 'monoSha256', 'colorSha256', 'lampSha256')}
                                          for row in flips]
    if backend == 'native':
        samples = pong['clockSamples']
        pulses = sum(number(row['pulses'], 'clock sample pulses', 1) for row in samples)
        clock_scope, compound_metrics = 'native-awaited-clock-command-v1', None
    else:
        clock_scope, compound_metrics = validate_compound_frames(report, optimized, require_compound)
        samples = [row for row in report['clock128Timing']['samples']
                   if row['phase'] == 'pong' and row['optimized'] is optimized]
        pulses = len(samples) * 128
    require(samples, 'Missing raw physical-clock timing samples')
    milliseconds = sum(number(row['milliseconds'], 'clock sample time', .000001)
                       for row in samples)
    return projection, {'backend': backend, 'mode': mode,
                        'clockMeasurementScope': clock_scope,
                        'compoundRoundTrip': compound_metrics,
                        'measuredClockSamples': len(samples),
                        'clockPulsesPerSecond': pulses * 1000 / milliseconds,
                        'importMs': number(opened['milliseconds'], 'import time'),
                        'saveMs': number(saved['milliseconds'], 'save time')}


def validate_profile(report, commit, cycles=2):
    require(report['schema'] == 1 and report['status'] == 'passed'
            and report['buildMode'] == 'profile', 'Actual successful Flutter profile report required')
    require(report['cycles'] == cycles and report['steadySecondsPerMode'] == 30
            and report['modes'] == list(MODES) and report['clockBatchPulses'] == 128
            and report['traceTotalPulses'] == 5120 and report['excludedWarmupCycles'] == 0,
            'Declared profile protocol differs from required independent lifecycle protocol')
    runtime = report['runtime']
    validate_source({'commit': runtime['commit'], 'checkedOutHead': runtime['checkedOutHead'],
                     'dirty': runtime['workingTreeDirty']}, commit)
    require(runtime['platform'] == 'linux' and runtime['flutterVersion'] == '3.47.6',
            'Wrong profile platform or Flutter pin')
    require(report['toolchain']['flutterRevisionPin'] == FLUTTER_REVISION,
            'Wrong Flutter revision')
    require(runtime.get('heapMeasurementMethod') == HEAP_MEASUREMENT_METHOD,
            'Native heap evidence must count unique isolate groups')
    for key in ('renderer', 'runner', 'dartVersion', 'osVersion'):
        require(runtime.get(key) not in (None, '', 'unspecified'), f'Missing runtime {key}')
    for key in ('physicalWidth', 'physicalHeight', 'devicePixelRatio'):
        number(report['viewport'][key], key, .001)
    fixture = report['fixture']
    require(fixture['wldSha256'] == WLD_SHA and fixture['twldSha256'] == TWLD_SHA
            and fixture['wldBytes'] == 405983441 and fixture['twldBytes'] == 427712,
            'Profile did not use the complete pinned input pair')
    refresh = number(report['displayRefreshRateHz'], 'observed display refresh rate', .001)
    budget = number(report['frameBudgetUs'], 'derived refresh frame budget', .001)
    require(report['frameBudgetSource'] == 'observed-display-refresh-rate'
            and math.isclose(budget, 1000000 / refresh),
            'Refresh budget must derive from observed display metadata')
    operations = {row['id']: row for row in report['operations']}
    require(len(operations) == len(report['operations']), 'Duplicate operation summaries')
    for row in operations.values():
        require(row['samples'] and all(sample['success'] is True for sample in row['samples']),
                'Failed or missing raw operation samples')
        for sample in row['samples']:
            number(sample['latencyMs'], 'operation latency')
    for mode in MODES:
        for action in CORE_OPERATIONS:
            row = operations[f'computer.{action}.{mode}']
            samples = row['samples']
            require(len(samples) == cycles and {s['cycle'] for s in samples} == set(range(cycles)),
                    f'{action}.{mode}: missing lifecycle repetition')
            require(all(s['success'] is True for s in samples), f'{action}.{mode}: failed operation')
            require(row['status'] in ('passed', 'missing-frames'), f'{action}.{mode}: failed summary')
            require(row['iterations'] == cycles and row['warmup'] == 0,
                    'No lifecycle may be silently excluded as warmup')
            for sample in samples:
                number(sample['latencyMs'], 'operation latency')
                number(sample['rssBeforeBytes'], 'operation RSS before', 1)
                number(sample['rssAfterBytes'], 'operation RSS after', 1)
    require(len(operations['computer.cancel-import.standard']['samples']) == 1,
            'Interrupted full import was not exercised')
    require(len(operations['computer.enable-optimization.optimized']['samples']) == cycles,
            'Default OFF to ON transitions were not exercised')
    observations = report['observations']
    require(len(observations) == cycles * 2, 'Missing whole-world lifecycle observations')
    indexed = {(row['cycle'], row['mode']): row for row in observations}
    require(set(indexed) == {(cycle, mode) for cycle in range(cycles) for mode in MODES},
            'Missing or duplicate mode/cycle observation')
    projections, metrics = [], []
    for cycle in range(cycles):
        for mode in MODES:
            observed = indexed[cycle, mode]
            trace = observed['deterministicTrace']
            require([row['pulses'] for row in trace] == list(range(512, 5121, 512)),
                    'Missing exact 5120-pulse fixed trace checkpoints')
            for row in trace:
                for key in ('mono', 'color', 'ram'):
                    sha(row[key])
            events = observed['inputEventsAtPhysicalClock']
            require(events == FIXED_INPUT_EVENTS,
                    'Actual sensor acknowledgements differ from the required UP/DOWN physical clock trace')
            standard = indexed[cycle, 'standard']
            require(trace == standard['deterministicTrace']
                    and events == standard['inputEventsAtPhysicalClock'],
                    'OFF/ON fixed trace state or input delivery differs')
            projections.append({'cycle': cycle, 'mode': mode, 'trace': trace, 'inputs': events})
            duration = number(observed['steadyWindowMs'], 'steady observation duration', 30000)
            pulses = number(observed['steadyPhysicalPulses'], 'steady physical pulses', 1)
            number(observed['observedDisplayChanges'], 'observed display changes', 2)
            number(observed['nativeActiveBytes'], 'active Native memory')
            number(observed['nativePeakBytes'], 'peak Native memory', 1)
            require(math.isclose(observed['clockHz'], pulses * 1000 / duration),
                    'Claimed clock rate does not match measured pulses/time')
            sample = next(s for s in operations[f'computer.run-displayed-pong.{mode}']['samples']
                          if s['cycle'] == cycle)
            ui, raster = sample['uiUs'], sample['rasterUs']
            require(ui and len(ui) == len(raster) == len(sample['totalSpanUs']),
                    'Steady profile window has no matching actual engine frame timings')
            for value in ui + raster + sample['totalSpanUs']:
                number(value, 'raw FrameTiming duration')
            metrics.append({'mode': mode, 'cycle': cycle, 'windowMs': duration,
                            'physicalClockHz': pulses * 1000 / duration,
                            'displayPollHz': number(observed['displayPollHz'], 'display poll rate', .001),
                            'observedDisplayChanges': observed['observedDisplayChanges'],
                            'frameCount': len(ui), 'frameBudgetUs': budget,
                            'uiMedianUs': statistics.median(ui), 'uiP95Us': percentile(ui, .95),
                            'rasterMedianUs': statistics.median(raster), 'rasterP95Us': percentile(raster, .95),
                            'overBudgetFrames': sum(u > budget or r > budget for u, r in zip(ui, raster))})
    # The complete raw samples are authoritative; claimed summary counts cannot substitute.
    for mode in MODES:
        row = operations[f'computer.run-displayed-pong.{mode}']
        actual_count = sum(len(s['uiUs']) for s in row['samples'])
        require(row['frameCount'] == actual_count, 'Declared FrameTiming count differs from raw samples')
    inputs = report['inputLatencies']
    expected = {(cycle, mode, direction) for cycle in range(cycles) for mode in MODES
                for direction in ('up', 'down', 'left', 'right', 'touch-hold-down')}
    require(len(inputs) == len(expected) and
            {(row['cycle'], row['mode'], row['input']) for row in inputs} == expected,
            'Missing actual keyboard/touch sensor latency samples')
    for row in inputs:
        number(row['pressToPhysicalSensorMs'], 'input to physical sensor time')
        number(row['releaseToVerifiedNoMorePulsesMs'], 'input release observation time')
        number(row['acceptedAtClock'], 'input acknowledgement clock')
        require(row['visualLatencyClaim'] is False, 'Input acknowledgement is not pixel presentation latency')
    memory = report['memory']
    expected_memory = {(phase, cycle, mode) for phase in ('paused-after-steady-run', 'after-close')
                       for cycle in range(cycles) for mode in MODES} | {('baseline', None, None)}
    require(len(memory) == len(expected_memory) and
            {(row['phase'], row.get('cycle'), row.get('mode')) for row in memory} == expected_memory,
            'Incomplete baseline/import/close memory series')
    for row in memory:
        for key in ('rssBytes', 'maxRssBytes', 'heapUsedBytes', 'heapCapacityBytes', 'externalBytes'):
            number(row[key], 'observed ' + key)
        number(row['sampledIsolates'], 'sampled VM isolates', 1)
        groups = number(row.get('sampledIsolateGroups'), 'sampled VM isolate groups', 1)
        require(groups <= row['sampledIsolates'], 'More sampled groups than isolates')
        require(row.get('heapMeasurementMethod') == HEAP_MEASUREMENT_METHOD and
                row['gc'] == 'requested-all-isolate-groups',
                'Heap sample must use unique isolate groups after GC')
    return projections, {'frames': metrics, 'inputLatencies': inputs, 'memory': memory,
                         'operationLatencies': {key: [sample['latencyMs'] for sample in row['samples']]
                                                for key, row in operations.items()}}


def percentile(values, fraction):
    ordered = sorted(values)
    at = (len(ordered) - 1) * fraction
    low, high = math.floor(at), math.ceil(at)
    return ordered[low] + (ordered[high] - ordered[low]) * (at - low)


def compare(reports, commit, require_jobs=False):
    errors, measurements, executions, states = [], {}, [], {}
    build_trees = set()
    expected = [row['expected'] for row in load(
        Path(__file__).resolve().parents[2] / 'native/fixtures/computerraria/programs.json')['main']['checks']]
    for lane in ('native', 'web', 'ui'):
        directory = reports / f'computerraria-raw-{lane}'
        try:
            validate_inputs(load(directory / 'input-manifest.json'))
            if lane != 'ui':
                build = load(directory / 'build.json')
                validate_build(build, commit, 'Release')
                build_trees.add(build['sourceTreeSha256'])
                if lane == 'web':
                    engine_manifest = load(directory / 'engine-manifest.json')
                    require(engine_manifest['emscripten'] == '5.0.7', 'Wrong Emscripten build')
                    require(all(engine_manifest['artifacts'][name] == artifact
                                for name, artifact in build['artifacts'].items()),
                            'WASM build manifest and tested artifact hashes differ')
            else:
                require((directory / 'glxinfo.txt').is_file(), 'Missing observed renderer log')
        except (ValueError, OSError, KeyError, TypeError) as error:
            errors.append(f'{lane}: {error}')
            continue
        suites = [f'computerraria-{lane}'] if lane == 'ui' else [f'computerraria-{lane}-{mode}' for mode in MODES]
        for suite in suites:
            for run in range(1, 4):
                path = directory / f'{suite}.run-{run}.json'
                try:
                    execution = validate_execution(path.with_suffix('.execution.json'), path, suite, commit)
                    require(execution['runId'] not in {e['runId'] for e in executions},
                            'Independent processes reused a run ID')
                    executions.append(execution)
                    report = load(path)
                    if lane == 'ui':
                        ui_build = load(path.with_suffix('.build.json'))
                        validate_build(ui_build, commit, 'Profile')
                        require(set(ui_build['artifacts']) == {'terraforge', 'libapp.so', 'libabc_engine.so'},
                                'Missing actual Flutter profile app and Native artifact hashes')
                        build_trees.add(ui_build['sourceTreeSha256'])
                        state, metrics = validate_profile(report, commit)
                    else:
                        state, metrics = validate_backend(report, lane, suite.rsplit('-', 1)[1], build, expected,
                                                          require_compound=lane == 'web')
                    states[path.name] = state
                    measurements[path.name] = metrics
                except (ValueError, OSError, KeyError, TypeError, IndexError, StopIteration) as error:
                    errors.append(f'{path.name}: {error}')
    for lane in ('native', 'web'):
        reference = states.get(f'computerraria-{lane}-standard.run-1.json')
        for mode in MODES:
            for run in range(1, 4):
                name = f'computerraria-{lane}-{mode}.run-{run}.json'
                if name in states and states[name] != reference:
                    errors.append(f'{name}: exact deterministic states differ from {lane} OFF run 1')
    reference = states.get('computerraria-ui.run-1.json')
    for run in (2, 3):
        name = f'computerraria-ui.run-{run}.json'
        if name in states and states[name] != reference:
            errors.append(f'{name}: fixed profile trace differs across independent processes')
    if require_jobs:
        for lane in ('NATIVE', 'WEB', 'UI'):
            if os.environ.get(lane + '_JOB_RESULT') != 'success':
                errors.append(f'{lane.lower()}: workflow job did not complete successfully')
    if len(build_trees) > 1:
        errors.append('The builds did not use identical recorded source files')
    require(len(states) <= 15, 'Unexpected accepted process count')
    if len(states) != 15:
        errors.append(f'Expected 15 complete process reports; accepted {len(states)}')
    return {'schema': 'abc.computerraria.comparison.v1',
            'status': 'failed' if errors else 'passed', 'commit': commit,
            'performanceStatus': 'first-calibration-no-historical-baseline',
            'acceptedReports': len(states), 'errors': errors,
            'measurements': measurements,
            'correctnessDigests': {name: hashlib.sha256(json.dumps(state, sort_keys=True)
                                   .encode()).hexdigest() for name, state in states.items()},
            'limits': ['Physical clock throughput is not screen FPS.',
                       'Node WASM timings are not browser UI timings.',
                       'Web compound RPC runs in a same-thread Node loopback; file-backed Blob handles use identity because Node cannot clone them. Browser File transfer and threading are not established.',
                       'Web clock-stage throughput excludes selected-display reads and loopback roundtrips; those durations are reported separately and cannot be pooled with legacy externally-awaited clock timings.',
                       'Linux Xvfb software rendering is not target-device fluidity.',
                       'Input latency ends at native sensor acknowledgement, not OS input or pixel presentation.',
                       'Shared existing group cache/lazy parity operates in both modes; ON adds generation deduplication.',
                       'Every first/repeat lifecycle is retained; filesystem cache state is uncontrolled.',
                       'Memory deltas are observations, not a calibrated leak/regression threshold.']}


def markdown(result):
    lines = ['# Complete Computerraria acceptance', '',
             f"Status: **{result['status']}**. Accepted process reports: {result['acceptedReports']}/15.",
             f"Commit: `{result['commit']}`.", '',
             'Performance: first calibration; no historical regression or target-device fluency claim.', '',
             'OFF/ON correctness compares physical CPU signatures, identical input/pulse checkpoints, full display record hashes, and paired save/reopen outputs. Timing is excluded from equality.', '']
    if result['errors']:
        lines += ['## Blockers', ''] + [f'- {error}' for error in result['errors']] + ['']
    data = result['measurements']
    lines += ['## Physical clock commands', '', '| Runtime | Mode | Measurement scope | Processes | Median pulses/s |',
              '|---|---|---|---:|---:|']
    for lane in ('native', 'web'):
        for mode in MODES:
            rows = [v for v in data.values() if v.get('backend') == lane and v.get('mode') == mode]
            for scope in sorted({row['clockMeasurementScope'] for row in rows}):
                values = [row['clockPulsesPerSecond'] for row in rows if row['clockMeasurementScope'] == scope]
                lines.append(f'| {lane} | {mode} | {scope} | {len(values)} | {statistics.median(values):.1f} |')
    lines += ['', '## Node loopback clock plus selected-display roundtrip', '',
              'Protocol/transfer correctness timing only: same-thread Node with file-backed Blob identity adaptation. This is not browser threading, rendering or FPS.', '',
              '| Mode | Processes | Median batch ms (median/process) | p95 batch ms (median/process) |',
              '|---|---:|---:|---:|']
    for mode in MODES:
        rows = [value['compoundRoundTrip'] for value in data.values()
                if value.get('mode') == mode and value.get('compoundRoundTrip')]
        if rows:
            lines.append(f'| {mode} | {len(rows)} | {statistics.median(row["medianMs"] for row in rows):.2f} | '
                         f'{statistics.median(row["p95Ms"] for row in rows):.2f} |')
    frames = [row for value in data.values() for row in value.get('frames', [])]
    lines += ['', '## Actual Flutter profile frame windows', '',
              '| Mode | Windows | Raw frames | UI p95 µs (median/window) | Raster p95 µs (median/window) | Frames over observed refresh budget |',
              '|---|---:|---:|---:|---:|---:|']
    for mode in MODES:
        rows = [row for row in frames if row['mode'] == mode]
        if rows:
            lines.append(f'| {mode} | {len(rows)} | {sum(r["frameCount"] for r in rows)} | '
                         f'{statistics.median(r["uiP95Us"] for r in rows):.1f} | '
                         f'{statistics.median(r["rasterP95Us"] for r in rows):.1f} | '
                         f'{sum(r["overBudgetFrames"] for r in rows)} |')
    inputs = [row for value in data.values() for row in value.get('inputLatencies', [])]
    lines += ['', '## Flutter input to physical sensor acknowledgement', '',
              '| Mode | Actual samples | Median ms | p95 ms | Median release-to-quiescence ms |',
              '|---|---:|---:|---:|---:|']
    for mode in MODES:
        rows = [row for row in inputs if row['mode'] == mode]
        if rows:
            press = [row['pressToPhysicalSensorMs'] for row in rows]
            lines.append(f'| {mode} | {len(rows)} | {statistics.median(press):.2f} | '
                         f'{percentile(press, .95):.2f} | '
                         f'{statistics.median(r["releaseToVerifiedNoMorePulsesMs"] for r in rows):.2f} |')
    memories = [row for value in data.values() for row in value.get('memory', [])]
    lines += ['', '## Observed memory after close', '',
              '| Mode | Cycle | Samples | Median RSS MiB | Median VM heap MiB after GC |',
              '|---|---|---:|---:|---:|']
    for mode in MODES:
        for cycle in (0, 1):
            rows = [r for r in memories if r.get('mode') == mode and r.get('cycle') == cycle
                    and r['phase'] == 'after-close']
            if rows:
                label = 'first' if cycle == 0 else 'repeat'
                lines.append(f'| {mode} | {label} | {len(rows)} | '
                             f'{statistics.median(r["rssBytes"] for r in rows) / 2**20:.2f} | '
                             f'{statistics.median(r["heapUsedBytes"] for r in rows) / 2**20:.2f} |')
    lines += ['', 'Full raw frame arrays, per-input latencies, first/repeat RSS and VM heap samples, import/save timings, and per-window display-change/pulse rates are retained in the JSON and original artifacts.', '', '## Interpretation', '']
    lines += ['- ' + limitation for limitation in result['limits']]
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--require-job-results', action='store_true')
    options = parser.parse_args()
    require(re.fullmatch(r'[0-9a-f]{40}', options.expected_commit), 'Expected immutable commit SHA')
    result = compare(options.reports, options.expected_commit, options.require_job_results)
    options.output.mkdir(parents=True, exist_ok=True)
    (options.output / 'comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    (options.output / 'comparison.md').write_text(markdown(result))
    print(f"Computerraria acceptance: {result['status']}; {result['acceptedReports']}/15 reports")
    return result['status'] != 'passed'


if __name__ == '__main__':
    raise SystemExit(main())
