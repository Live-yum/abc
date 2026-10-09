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
LOADING_MEMORY_SCHEMA = 'abc.profile-loading-os-memory.v1'
LOADING_MEMORY_SCOPE = 'single-flutter-application-process-including-sampler-isolate'
OS_MEMORY_FIELDS = ('rssBytes', 'smapsRssBytes', 'pssBytes', 'ussBytes')
INTERVAL_BUCKETS = ('<=10000', '<=20000', '<=50000', '<=100000',
                    '<=250000', '<=1000000', '>1000000')
PADDLE_STATE_INPUTS = ('up', 'down', 'touch-hold-down')
PADDLE_STATE_MEASUREMENT = 'decoded-physical-monitor-state-not-raster-presentation'
PADDLE_STATE_WAIT_BOUND_MS = 5000
PADDLE_STATE_FIELDS = ('pressToPaddleStateMs', 'paddleCenterBefore',
                       'paddleCenterObservedAfter', 'paddleStateLatencyMeasurement',
                       'paddleStateWaitBoundMs', 'paddleStateWaitStartsAt')
WEB_AWAITED_CLOCK_MEASUREMENT = 'Only the awaited128-clock command, including bounded owner dispatch; excludes ROM loading, state reads and rendering'
WEB_COMPOUND_CLOCK_MEASUREMENT = 'Only the worker bridge clock command hostStagesUs.commandWallUs; excludes compound display read and loopback round trip, and is not the legacy externally-awaited timing'
WEB_COMPOUND_TRANSPORT = 'Actual RPC client/host and structuredClone ArrayBuffer transfers in a Node loopback, both endpoints on one thread; immutable fs.openAsBlob handles preserved by identity because Node24 forbids cloning them; not browser File transfer, threading or timing proof'

REVISION = '0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8'
WLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
PONG_SHA = 'd2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d'
FLUTTER_REVISION = '5fc346839b5d0eef006ed8404392afb4dfae428d'
EXPECTED_INPUTS = {
    'computerraria.tar.gz': (2871121, '31423b4f7ebbecceeaa54f982f02980efa5b8edccede5456456d892b0452ea1a'),
    'computerraria.wld': (405983441, WLD_SHA),
}
MODES = ('standard', 'optimized')
CORE_OPERATIONS = ('choose-world', 'import', 'load-pong',
                   'same-program-input-trace',
                   'idle-mode-roundtrip', 'run-physical-program',
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
    require(manifest.get('schema') == 'abc.public-computerraria-inputs.v2'
            and manifest['status'] == 'verified' and manifest['sourceRevision'] == REVISION,
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
        require(frame['monitor'] == 'mono' and frame['recordsBytes'] == 3072 * 16,
                'Compound monochrome record scope or length is wrong')
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
    require({row['monitor'] for row in pong} == {'mono'},
            'Actual Pong must exercise compound monochrome reads')
    values = [row['roundTripMilliseconds'] for row in pong if row['optimized'] is optimized]
    require(values, 'Missing requested-mode compound Pong roundtrips')
    return 'node-bridge-clock-stage-v1', {
        'scope': 'node-loopback-clock-and-selected-display-v1',
        'samples': len(values), 'medianMs': statistics.median(values),
        'p95Ms': sorted(values)[math.ceil(len(values) * .95) - 1],
        'maxMs': max(values),
    }


def validate_pixel_rule(report, optimized):
    require(report.get('pixelRule') == ('wirehead-color-pair-wave' if optimized else 'game-tripwire-crossing'),
            'Missing or contradictory physical PixelBox rule')
    require(report.get('displayCompatibility') == {
        'status': 'supported' if optimized else 'unsupported-under-game-rules',
        'expectedBehavior': 'moving-pong' if optimized else 'recorded-without-pong-display-claim'},
        'Display compatibility must distinguish game-rule limitations from working Pong')
    require(report.get('readyMetadata') == {
        'flags': 14 if optimized else 4, 'optimizationEnabled': optimized,
        'topologyEligible': True, 'wireHeadPixelRulesEnabled': optimized},
        'Actual READY flags must confirm topology qualification and the selected rule')


def backend_cpu_projection(state):
    return {key: state[key] for key in ('main', 'negativeControl', 'inputProbes', 'displayProgram')} | {
        'pong': {key: state['pong'][key] for key in ('binarySha256', 'bytes', 'clocks', 'cpuTrace')},
        'savedRam': {key: state['save'][key] for key in ('beforeRamSha256', 'reopenedRamSha256')}}


def validate_backend(report, backend, mode, build, expected_signatures, *, require_compound=False):
    require(report['status'] == 'passed', 'Physical acceptance did not pass')
    require(report.get('inputFormat') == 'wld-only' and report.get('circuitAbi') == 2,
            'Fresh single-WLD ABI2 acceptance is required')
    optimized = mode == 'optimized'
    validate_pixel_rule(report, optimized)
    require(report['defaultOptimization'] is False
            and report['activeOptimizationAtStart'] is optimized
            and report['activeOptimizationAtEnd'] is optimized,
            'Default or observed active optimization state is wrong')
    if backend == 'native':
        require(report['schema'] == 2 and report['optimizationEnabled'] is optimized,
                'Wrong Native schema or optimization mode')
        require(report['librarySha256'] == build['artifacts']['libabc_engine.so']['sha256'],
                'Native report did not use the recorded artifact')
        require(report['idleSwitchPreservesState'] is True, 'Idle switch preservation missing')
    else:
        require(report['schema'] == 'abc.computerraria.web-file-acceptance.v2'
                and report['requestedOptimization'] is optimized,
                'Wrong Web schema or optimization mode')
        for field, filename in [('loaderSha256', 'world.js'), ('wasmSha256', 'world.wasm')]:
            require(report[field] == build['artifacts'][filename]['sha256'],
                    'Web report did not use the recorded release artifacts')
        require(report['bridgeBytesAfterClose'] == 0 and report['openFilesAfterClose'] == 0,
                'Web owners/files remain after close')
    require(report['nativeBytesAfterClose'] == 0, 'Native allocations remain after close')
    opened = report['import']
    require(opened['stats'][0] == report['circuitAbi'], 'Reported ABI differs from actual circuit stats')
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
    for key in ('displayMonoSha256', 'pongFinalMonoSha256'):
        sha(correctness[key])
    pong = report['pong']
    require(pong['binarySha256'] == PONG_SHA and pong['bytes'] == 2288,
            'Pong is not the pinned upstream program')
    require(pong['clocks'] == 1536, 'Both modes require the same fixed 1536 physical clocks')
    require(pong.get('cpuTraceMeasurement') == 'passive-ready-and-1088-ram-bytes-no-reset-bus',
            'CPU/RAM trace must be passive and include the Pong stack')
    trace = pong['cpuTrace']
    require([r['clocks'] for r in trace] == list(range(128, 1537, 128)), 'Missing physical CPU checkpoints')
    for row in trace:
        sha(row['ramSha256'])
        require(type(row['ready']) is bool, 'Missing actual ready lamp')
    require(len({r['ramSha256'] for r in trace}) > 1, 'Equal but halted Pong RAM traces cannot pass')
    require(pong.get('displayStatus') == ('moving' if optimized else 'expected-dark'),
            'Pong display outcome must be explicit')
    if optimized:
        require([[r[0], r[1], r[3]] for r in report['display']['mono']] ==
                [[6485, 800, 18], [6516, 800, 18]], 'Physical two-pixel test did not work')
        require(sum(any(1 < p[0] < 62 for p in r['lit']) for r in pong['frames']) >= 3,
                'Missing three real moving-ball monitor states')
    else:
        require(report['display']['mono'] == [] and pong['frames'] and
                all(r['lit'] == [] for r in pong['frames']),
                'Standard-rule actual observations differ from the bounded dark-monitor fixture')
    previous = 0
    for frame in pong['frames']:
        require(frame['clocks'] > previous, 'Pong checkpoint clocks must increase')
        previous = frame['clocks']
        sha(frame['sha256'])
        require(isinstance(frame['lit'], list), 'Actual lit-pixel coordinates missing')
    saved = report['save']
    require(saved['status'] == 'passed', 'Complete single-WLD save/reopen was not verified')
    for key in ('worldBytes',):
        number(saved[key], key, 1)
    for key in ('worldSha256',):
        sha(saved[key])
    for phase in ('beforeDisplaySha256', 'reopenedDisplaySha256', 'postProgramDisplaySha256'):
        for display in ('mono',):
            sha(saved[phase][display])
    sha(saved['beforeRamSha256']); sha(saved['reopenedRamSha256'])
    require(saved['beforeRamSha256'] == saved['reopenedRamSha256'], 'Saved physical RAM/stack changed')
    require(saved['beforeDisplaySha256'] == saved['reopenedDisplaySha256'],
            'WLD save changed complete physical display records')
    projection = {
        'pixelRule': report['pixelRule'], 'displayCompatibility': report['displayCompatibility'],
        'main': main, 'negativeControl': negative, 'inputProbes': probes,
        'displayProgram': program_projection(report['displayProgram']),
        'display': {'mono': report['display']['mono']},
        'correctness': correctness,
        'pong': {key: pong[key] for key in ('binarySha256', 'bytes', 'clocks', 'frames', 'cpuTrace')},
        'save': {key: saved[key] for key in ('worldBytes', 'worldSha256',
                  'beforeDisplaySha256', 'reopenedDisplaySha256',
                  'postProgramDisplaySha256', 'beforeRamSha256', 'reopenedRamSha256')},
    }
    if backend == 'web':
        flips = pong['modeFlips']
        require(len(flips) == 2 and [row['optimized'] for row in flips] == [not optimized, optimized],
                'Missing both live Pong idle mode transitions')
        require(flips[0]['session'] == flips[1]['session'], 'Idle toggle replaced the active session')
        for row in flips:
            for key in ('monoSha256', 'lampSha256'):
                sha(row[key])
        projection['idleModeFlipStates'] = [{key: row[key] for key in
                                           ('clocks', 'monoSha256', 'lampSha256')}
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
                        'pixelRule': report['pixelRule'], 'displayCompatibility': report['displayCompatibility'],
                        'clockMeasurementScope': clock_scope,
                        'compoundRoundTrip': compound_metrics,
                        'measuredClockSamples': len(samples),
                        'clockPulsesPerSecond': pulses * 1000 / milliseconds,
                        'importMs': number(opened['milliseconds'], 'import time'),
                        'saveMs': number(saved['milliseconds'], 'save time')}


def integer(value, label, minimum=0):
    require(isinstance(value, int) and not isinstance(value, bool) and value >= minimum,
            f'Invalid {label}')
    return value


def validate_os_memory_sample(sample):
    require(isinstance(sample, dict), 'Missing OS memory boundary sample')
    integer(sample.get('timeUs'), 'OS sample time')
    integer(sample.get('rssBytes'), 'OS RSS', 1)
    integer(sample.get('processVmHwmBytes'), 'cumulative process VmHWM', 1)
    smaps = [sample.get(field) for field in OS_MEMORY_FIELDS[1:]]
    if all(value is None for value in smaps):
        require(sample.get('smapsTimeUs') is None, 'Missing smaps values have a timestamp')
        require(isinstance(sample.get('smapsUnavailable'), str) and sample['smapsUnavailable'],
                'Unavailable boundary PSS/USS requires an explicit reason')
    else:
        for field in OS_MEMORY_FIELDS[1:]:
            integer(sample.get(field), 'OS ' + field)
        require(integer(sample.get('smapsTimeUs'), 'smaps sample time') >= sample['timeUs'],
                'Sequential smaps read precedes status sample')
        require(sample.get('smapsUnavailable') is None, 'Successful smaps sample claims unavailable')
    return sample


def validate_os_intervals(intervals, sample_count, duration=None):
    require(isinstance(intervals, dict), 'Missing actual OS sample interval distribution')
    count = integer(intervals.get('count'), 'OS interval count')
    require(count == max(0, sample_count - 1), 'OS interval and sample counts differ')
    buckets = intervals.get('nonOverlappingBuckets')
    require(isinstance(buckets, dict) and set(buckets) <= set(INTERVAL_BUCKETS),
            'Unknown or overlapping OS interval buckets')
    require(sum(integer(value, 'interval bucket count', 1) for value in buckets.values()) == count,
            'OS interval histogram does not account for every observed gap')
    if count == 0:
        require(all(intervals.get(key) is None for key in ('min', 'mean', 'max')),
                'No intervals were observed but timing statistics were reported')
    else:
        low, mean, high = (number(intervals.get(key), 'OS interval ' + key)
                           for key in ('min', 'mean', 'max'))
        require(low <= mean <= high, 'OS interval min/mean/max contradict each other')
        if duration is not None:
            require(math.isclose(mean * count, duration, rel_tol=1e-9, abs_tol=1e-6),
                    'Status intervals do not span the declared loading window')


def validate_loading_os_memory(data, cycles):
    require(isinstance(data, dict) and data.get('schema') == LOADING_MEMORY_SCHEMA
            and data.get('status') == 'observed', 'Complete observed Flutter loading OS memory is required')
    integer(data.get('hostPid'), 'Flutter application PID', 1)
    require(data.get('scope') == LOADING_MEMORY_SCOPE
            and data.get('samplingActiveOnlyDuringLoad') is True,
            'OS memory must cover only the application process, with periodic sampling limited to loads')
    require(data.get('clock') == 'dart-Timeline.now-monotonic-microseconds'
            and data.get('statusTargetIntervalUs') == 10000
            and data.get('smapsTargetIntervalUs') == 100000,
            'Unknown OS sampling clock or declared target cadence')
    require(data.get('errors') == [], 'OS loading sampler reported errors')
    windows, closes = data.get('windows'), data.get('closeSamples')
    expected = [('cancelled-import', 0, 'standard')]
    expected += [(kind, cycle, mode) for cycle in range(cycles) for mode in MODES
                 for kind in ('initial-import', 'exported-reimport')]
    require(isinstance(windows, list) and len(windows) == len(expected),
            'Incomplete cancelled/initial/reimport loading windows')
    previous_end, smaps_total = -1, 0
    for attempt, (window, identity) in enumerate(zip(windows, expected)):
        require((window.get('kind'), window.get('cycle'), window.get('mode')) == identity
                and integer(window.get('hostLoadAttempt'), 'host load attempt') == attempt,
                'Loading windows are missing, duplicated or reordered')
        cancelled = attempt == 0
        context = ('cancelled-load-attempt' if cancelled else
                   'fresh-host-first-complete-load' if attempt == 1 else 'repeat-in-same-host')
        require(window.get('priorCancelledLoad') is (not cancelled)
                and window.get('hostLoadContext') == context and window.get('cacheState') == 'uncontrolled',
                'First/repeat/cancelled-load context or uncontrolled cache state is mislabeled')
        require(window.get('outcome') == ('cancelled' if cancelled else 'ready'),
                'A failed or aborted load cannot satisfy loading evidence')
        baseline = validate_os_memory_sample(window.get('baseline'))
        terminal = validate_os_memory_sample(window.get('terminal'))
        duration = integer(window.get('durationUs'), 'loading duration', 1)
        require(baseline['timeUs'] >= previous_end
                and terminal['timeUs'] - baseline['timeUs'] == duration,
                'Loading windows overlap or duration disagrees with monotonic boundary samples')
        previous_end = max(terminal['timeUs'], terminal.get('smapsTimeUs') or terminal['timeUs'])
        if cancelled:
            require(window.get('ready') is None and window.get('readyEvidence') == {},
                    'Cancelled load cannot claim ready displays')
        else:
            require(window.get('ready') == terminal, 'Ready sample differs from load terminal sample')
            evidence = window.get('readyEvidence', {})
            require(evidence.get('completeWldVerified') is True
                    and evidence.get('monoDisplayInitialized') is True
                    and evidence.get('monoRgbaBytes') == 12288,
                    'Load readiness requires the verified complete WLD and actual monochrome RGBA plane')
        status_count = integer(window.get('statusSampleCount'), 'status sample count', 2)
        periodic = integer(window.get('periodicStatusSampleCount'), 'periodic status sample count')
        require(periodic == status_count - 2 and (cancelled or periodic > 0),
                'Complete load needs real periodic samples in addition to both boundaries')
        smaps_count = integer(window.get('smapsSampleCount'), 'smaps sample count')
        require(smaps_count <= status_count, 'More smaps samples than status samples')
        require(smaps_count >= sum(sample['smapsRssBytes'] is not None for sample in (baseline, terminal)),
                'Smaps count omits available boundary samples')
        smaps_total += smaps_count
        validate_os_intervals(window.get('statusIntervalUs'), status_count, duration)
        validate_os_intervals(window.get('smapsIntervalUs'), smaps_count)
        maxima, times = window.get('sampleMax'), window.get('sampleMaxAtUs')
        require(isinstance(maxima, dict) and set(maxima) == set(OS_MEMORY_FIELDS)
                and isinstance(times, dict), 'Missing per-source sampled maxima and times')
        require(set(times) == {field for field, value in maxima.items() if value is not None},
                'Sample maxima and their timestamps differ')
        for field in OS_MEMORY_FIELDS:
            value = maxima[field]
            if value is None:
                require(field != 'rssBytes' and smaps_count == 0,
                        'Available OS samples are missing their maximum')
            else:
                integer(value, 'sample maximum ' + field, 1 if field == 'rssBytes' else 0)
                require(field == 'rssBytes' or smaps_count > 0,
                        'Smaps maximum is reported without any smaps sample')
                observed_end = terminal['timeUs'] if field == 'rssBytes' else max(terminal['timeUs'], terminal.get('smapsTimeUs') or terminal['timeUs'])
                require(baseline['timeUs'] <= integer(times[field], 'sample maximum timestamp') <= observed_end,
                        'Sample maximum timestamp lies outside its loading window')
                require(all(sample[field] is None or sample[field] <= value for sample in (baseline, terminal)),
                        'Sample maximum is smaller than a recorded boundary')
        require(window.get('processVmHwmAtBaselineBytes') == baseline['processVmHwmBytes']
                and window.get('processVmHwmAtEndBytes') == terminal['processVmHwmBytes']
                and terminal['processVmHwmBytes'] >= baseline['processVmHwmBytes'],
                'Lifetime cumulative VmHWM disagrees with its boundaries or moves backwards')
    expected_closes = [(phase, cycle, mode) for cycle in range(cycles) for mode in MODES
                       for phase in ('after-export-close', 'after-cycle-close')]
    require(isinstance(closes, list) and len(closes) == len(expected_closes),
            'Missing independent post-close OS memory samples')
    for index, (close, identity) in enumerate(zip(closes, expected_closes)):
        require((close.get('phase'), close.get('cycle'), close.get('mode')) == identity,
                'Post-close OS memory samples are missing, duplicated or reordered')
        sample = validate_os_memory_sample(close.get('sample'))
        preceding = windows[index + 1]
        require(sample['timeUs'] >= preceding['terminal']['timeUs'],
                'Post-close sample precedes the corresponding load')
        if index + 2 < len(windows):
            require(sample['timeUs'] <= windows[index + 2]['baseline']['timeUs'],
                    'Post-close sample overlaps the next load')
    available = data.get('pssUssAvailability')
    expected_availability = ('available' if data.get('smapsUnavailable') is None else 'partial') if smaps_total else 'unavailable'
    require(available == expected_availability, 'PSS/USS availability contradicts actual sample counts')
    if available == 'available':
        require(all(sample['smapsRssBytes'] is not None
                    for sample in [s for w in windows for s in (w['baseline'], w['terminal'])]
                    + [c['sample'] for c in closes]), 'Available PSS/USS lacks forced boundary samples')
    else:
        require(isinstance(data.get('smapsUnavailable'), str) and data['smapsUnavailable'],
                'Unavailable or partial PSS/USS needs an explicit reason')
    return data


def validate_display_calibration(report):
    """Retain unavailable display metadata without inventing a measured budget."""
    refresh = number(report.get('displayRefreshRateHz'), 'reported display refresh rate')
    budget = number(report.get('frameBudgetUs'), 'reported frame budget', .001)
    source = report.get('frameBudgetSource')
    if refresh > 0:
        number(refresh, 'observed display refresh rate', .001)
        require(source == 'observed-display-refresh-rate'
                and math.isclose(budget, 1000000 / refresh),
                'Refresh budget must derive from observed display metadata')
    else:
        require(source == 'explicit-60hz-fallback'
                and math.isclose(budget, 1000000 / 60),
                'Unavailable refresh requires an explicit nominal 60 Hz fallback budget')
    return {'status': 'observed' if refresh > 0 else 'unavailable',
            'displayRefreshRateHz': refresh, 'frameBudgetSource': source,
            'reportedFrameBudgetUs': budget,
            'observedRefreshRateHz': refresh if refresh > 0 else None,
            'observedFrameBudgetUs': budget if refresh > 0 else None,
            'referenceFrameBudgetUs': None if refresh > 0 else budget,
            'reason': None if refresh > 0 else 'Display reports 0 Hz; nominal 60 Hz is a reference only.'}


def validate_profile(report, commit, cycles=2):
    require(report['schema'] == 2 and report.get('inputFormat') == 'wld-only'
            and report.get('circuitAbi') == 2 and report['status'] == 'passed'
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
    require(fixture['wldSha256'] == WLD_SHA and fixture['wldBytes'] == 405983441,
            'Profile did not use the complete pinned WLD input')
    calibration = validate_display_calibration(report)
    budget = calibration['observedFrameBudgetUs']
    operations = {row['id']: row for row in report['operations']}
    require(len(operations) == len(report['operations']), 'Duplicate operation summaries')
    for row in operations.values():
        require(row['samples'] and all(sample['success'] is True for sample in row['samples']),
                'Failed or missing raw operation samples')
        for sample in row['samples']:
            number(sample['latencyMs'], 'operation latency')
    for mode in MODES:
        for action in CORE_OPERATIONS:
            operation_id = f'computer.{action}.{mode}'
            require(operation_id in operations, f'Missing operation {operation_id}')
            row = operations[operation_id]
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
            optimized = mode == 'optimized'
            validate_pixel_rule(observed, optimized)
            trace = observed['deterministicTrace']
            require([row['pulses'] for row in trace] == list(range(512, 5121, 512)),
                    'Missing exact 5120-pulse fixed trace checkpoints')
            for row in trace:
                for key in ('mono', 'ram', 'cpuProbe'):
                    sha(row[key])
                integer(row['monoLitPixels'], 'Actual lit monitor pixels')
            events = observed['inputEventsAtPhysicalClock']
            require(events == FIXED_INPUT_EVENTS,
                    'Actual sensor acknowledgements differ from the required UP/DOWN physical clock trace')
            standard = indexed[cycle, 'standard']
            cpu_trace = lambda rows: [{key: r[key] for key in ('pulses', 'cpuProbe', 'ram')} for r in rows]
            require(cpu_trace(trace) == cpu_trace(standard['deterministicTrace'])
                    and events == standard['inputEventsAtPhysicalClock'],
                    'OFF/ON fixed CPU/RAM trace or input delivery differs')
            require(trace == indexed[0, mode]['deterministicTrace'], 'Same-mode profile trace differs across lifecycles')
            projections.append({'cycle': cycle, 'mode': mode, 'trace': trace, 'inputs': events})
            duration = number(observed['steadyWindowMs'], 'steady observation duration', 30000)
            pulses = number(observed['steadyPhysicalPulses'], 'steady physical pulses', 1)
            number(observed['observedDisplayChanges'], 'observed display changes', 2 if optimized else 0)
            require(type(observed['allDarkSamples']) is bool and (not optimized or not observed['allDarkSamples']),
                    'Actual display darkness must be observed; ON must display changing Pong')
            live = observed['cpuRamLiveness']
            require(live['measurement'] == 'passive-lamp-queries-no-reset-bus' and live['ramProbeBytes'] == 1088,
                    'CPU liveness requires passive register/RAM/stack queries')
            integer(live['cpuProbeCount'], 'Physical CPU probe count', 1)
            cpu_states = len({r['cpuProbe'] for r in trace}); ram_states = len({r['ram'] for r in trace})
            require(live['distinctCpuStates'] == cpu_states and live['distinctRamStates'] == ram_states
                    and max(cpu_states, ram_states) > 1, 'Equal halted CPU/RAM trace cannot pass')
            number(observed['nativeActiveBytes'], 'active Native memory')
            number(observed['nativePeakBytes'], 'peak Native memory', 1)
            require(math.isclose(observed['clockHz'], pulses * 1000 / duration),
                    'Claimed clock rate does not match measured pulses/time')
            sample = next(s for s in operations[f'computer.run-physical-program.{mode}']['samples']
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
                            'displayCompatibility': observed['displayCompatibility'],
                            'frameCount': len(ui), 'frameBudgetUs': budget,
                            'displayCalibrationStatus': calibration['status'],
                            'frameBudgetSource': calibration['frameBudgetSource'],
                            'referenceFrameBudgetUs': calibration['referenceFrameBudgetUs'],
                            'uiMedianUs': statistics.median(ui), 'uiP95Us': percentile(ui, .95),
                            'rasterMedianUs': statistics.median(raster), 'rasterP95Us': percentile(raster, .95),
                            'overBudgetFrames': None if budget is None else
                                sum(u > budget or r > budget for u, r in zip(ui, raster))})
    # The complete raw samples are authoritative; claimed summary counts cannot substitute.
    for mode in MODES:
        row = operations[f'computer.run-physical-program.{mode}']
        actual_count = sum(len(s['uiUs']) for s in row['samples'])
        require(row['frameCount'] == actual_count, 'Declared FrameTiming count differs from raw samples')
    inputs = report['inputLatencies']
    expected = {(cycle, mode, direction) for cycle in range(cycles) for mode in MODES
                for direction in ('up', 'down', 'left', 'right', 'touch-hold-down')}
    require(len(inputs) == len(expected) and
            {(row['cycle'], row['mode'], row['input']) for row in inputs} == expected,
            'Missing actual keyboard/touch sensor latency samples')
    for row in inputs:
        sensor_ms = number(row['pressToPhysicalSensorMs'], 'input to physical sensor time')
        number(row['releaseToVerifiedNoMorePulsesMs'], 'input release observation time')
        number(row['acceptedAtClock'], 'input acknowledgement clock')
        require(row['visualLatencyClaim'] is False, 'Input acknowledgement is not pixel presentation latency')
        if row['input'] in PADDLE_STATE_INPUTS and row['mode'] == 'optimized':
            require(row.get('paddleStateLatencyStatus') == 'observed' and 'paddleStateLatencyReason' not in row,
                    'ON paddle latency must contain actual state evidence')
            state_ms = number(row.get('pressToPaddleStateMs'), 'input to decoded paddle-state time')
            require(row.get('paddleStateLatencyMeasurement') == PADDLE_STATE_MEASUREMENT,
                    'Paddle latency must identify decoded physical monitor state, not raster presentation')
            require(row.get('paddleStateWaitBoundMs') == PADDLE_STATE_WAIT_BOUND_MS
                    and row.get('paddleStateWaitStartsAt') == 'press',
                    'Paddle observation must retain the shared five-second deadline from press')
            require(sensor_ms <= state_ms <= PADDLE_STATE_WAIT_BOUND_MS,
                    'Paddle observation precedes sensor acknowledgement or exceeds its deadline')
            before = number(row.get('paddleCenterBefore'), 'initial paddle center')
            after = number(row.get('paddleCenterObservedAfter'), 'observed changed paddle center')
            require(before <= 47 and after <= 47 and before != after,
                    'Paddle evidence requires two valid, different physical monitor positions')
        else:
            require(row.get('paddleStateLatencyStatus') == 'notApplicable' and
                    row.get('paddleStateLatencyReason') == ('game-tripwire-display-not-supported'
                        if row['input'] in PADDLE_STATE_INPUTS else 'pong-ignores-direction'),
                    'Inapplicable paddle observations require the explicit mode/direction reason')
            require(not any(field in row for field in PADDLE_STATE_FIELDS),
                    'Sensor-only input must not claim paddle or raster latency')
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
    loading_memory = validate_loading_os_memory(report.get('loadingOsMemory'), cycles)
    return projections, {'displayCalibration': calibration,
                         'frames': metrics, 'inputLatencies': inputs, 'memory': memory,
                         'loadingOsMemory': loading_memory,
                         'operationLatencies': {key: [sample['latencyMs'] for sample in row['samples']]
                                                for key, row in operations.items()}}


def percentile(values, fraction):
    ordered = sorted(values)
    at = (len(ordered) - 1) * fraction
    low, high = math.floor(at), math.ceil(at)
    return ordered[low] + (ordered[high] - ordered[low]) * (at - low)


def performance_summary(measurements):
    calibration = [value['displayCalibration'] for value in measurements.values()
                   if 'displayCalibration' in value]
    observed = sum(row['status'] == 'observed' for row in calibration)
    unavailable = len(calibration) - observed
    status = ('missing' if not calibration else 'partial' if observed and unavailable
              else 'unavailable' if unavailable else 'observed')
    return {'performanceStatus': ('first-calibration-no-historical-baseline' if status == 'observed'
                                 else f'first-calibration-display-refresh-{status}-no-historical-baseline'),
            'historicalRegressionStatus': 'no-historical-baseline',
            'targetDeviceFluencyStatus': 'not-established',
            'displayCalibration': {'status': status, 'observedReports': observed,
                                   'unavailableReports': unavailable,
                                   'acceptedProfileReports': len(calibration)}}


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
        standard = states.get(f'computerraria-{lane}-standard.run-1.json')
        for mode in MODES:
            reference = states.get(f'computerraria-{lane}-{mode}.run-1.json')
            for run in range(1, 4):
                name = f'computerraria-{lane}-{mode}.run-{run}.json'
                if name in states and states[name] != reference:
                    errors.append(f'{name}: exact same-mode deterministic states differ from run 1')
                if name in states and standard and backend_cpu_projection(states[name]) != backend_cpu_projection(standard):
                    errors.append(f'{name}: physical CPU/RAM/input trace differs from OFF run 1')
    for mode in MODES:
        native = states.get(f'computerraria-native-{mode}.run-1.json')
        web = states.get(f'computerraria-web-{mode}.run-1.json')
        if native and web and native != {k:v for k,v in web.items() if k != 'idleModeFlipStates'}:
            errors.append(f'{mode}: Native/Web same-mode complete deterministic projections differ')
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
            'statusScope': 'report-validity-and-deterministic-correctness',
            **performance_summary(measurements),
            'acceptedReports': len(states), 'errors': errors,
            'measurements': measurements,
            'correctnessDigests': {name: hashlib.sha256(json.dumps(state, sort_keys=True)
                                   .encode()).hexdigest() for name, state in states.items()},
            'limits': ['Physical clock throughput is not screen FPS.',
                       'Node WASM timings are not browser UI timings.',
                       'Web compound RPC runs in a same-thread Node loopback; file-backed Blob handles use identity because Node cannot clone them. Browser File transfer and threading are not established.',
                       'Web clock-stage throughput excludes selected-display reads and loopback roundtrips; those durations are reported separately and cannot be pooled with legacy externally-awaited clock timings.',
                       'Linux Xvfb software rendering is not target-device fluidity.',
                       'A 0 Hz display with explicit-60hz-fallback has unavailable refresh calibration; its nominal 16.67 ms reference cannot establish measured budget misses or fluency.',
                       'Sensor acknowledgement and held-input decoded paddle-state latency are reported separately; neither includes OS input or raster presentation.',
                       'Shared group cache/lazy parity operates in both modes. ON adds generation deduplication and explicitly different WireHead-style PixelBox wave pairing; OFF does not claim working Pong display.',
                       'Every first/repeat lifecycle is retained; filesystem cache state is uncontrolled.',
                       'Loading OS memory includes the sampler isolate in the application process; compiler, driver and Xvfb are excluded. Sampled peaks may miss between-sample peaks; VmHWM is cumulative since process start.',
                       'Memory deltas are observations, not a calibrated leak/regression threshold.']}


def markdown(result):
    data = result['measurements']
    performance = performance_summary(data)
    calibration = performance['displayCalibration']
    lines = ['# Complete Computerraria acceptance', '',
             f"Report validity and deterministic correctness: **{result['status']}**. Accepted process reports: {result['acceptedReports']}/15.",
             f"Commit: `{result['commit']}`.", '',
             'Performance: first calibration; no historical regression or target-device fluency claim.', '',
             f'Display refresh calibration: **{calibration["status"]}** '
             f'({calibration["observedReports"]} observed, {calibration["unavailableReports"]} unavailable accepted profile reports).', '',
             'OFF/ON compares physical CPU/RAM and input/pulse checkpoints. Pixel records and saved files compare exactly within each declared mode across repetitions and runtimes; OFF display limitations remain explicit. Timing is excluded from equality.', '']
    if calibration['status'] != 'observed':
        lines += ['Measured refresh budgets and budget-miss conclusions are unavailable for uncalibrated windows. '
                  'The explicit nominal 60 Hz / 16.67 ms fallback is a reference only; accepting report correctness does not pass display calibration or fluency.', '']
    if result['errors']:
        lines += ['## Blockers', ''] + [f'- {error}' for error in result['errors']] + ['']
    lines += ['## Display refresh metadata and calibration', '',
              '| Process | Calibration | Reported refresh Hz | Raw budget source | Observed budget µs | Nominal reference budget µs |',
              '|---|---|---:|---|---:|---:|']
    for name, value in data.items():
        if 'displayCalibration' in value:
            row = value['displayCalibration']
            observed = 'unavailable' if row['observedFrameBudgetUs'] is None else f'{row["observedFrameBudgetUs"]:.2f}'
            reference = 'not used' if row['referenceFrameBudgetUs'] is None else f'{row["referenceFrameBudgetUs"]:.2f} (reference only)'
            lines.append(f'| {name} | {row["status"]} | {row["displayRefreshRateHz"]:g} | '
                         f'{row["frameBudgetSource"]} | {observed} | {reference} |')
    lines += ['']
    lines += ['## Declared display compatibility', '',
              '| Runtime | Mode | Pixel rule | Display result |', '|---|---|---|---|']
    for lane in ('native', 'web'):
        for mode in MODES:
            rows = [v for v in data.values() if v.get('backend') == lane and v.get('mode') == mode]
            if rows:
                lines.append(f'| {lane} | {mode} | {rows[0]["pixelRule"]} | {rows[0]["displayCompatibility"]["status"]} |')
    lines += ['']
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
              '| Mode | Calibration | Windows | Raw frames | UI p95 µs (median/window) | Raster p95 µs (median/window) | Frames over observed refresh budget |',
              '|---|---|---:|---:|---:|---:|---:|']
    for mode in MODES:
        for status in ('observed', 'unavailable'):
            rows = [row for row in frames if row['mode'] == mode and row['displayCalibrationStatus'] == status]
            if rows:
                misses = 'unavailable' if status == 'unavailable' else str(sum(r['overBudgetFrames'] for r in rows))
                lines.append(f'| {mode} | {status} | {len(rows)} | {sum(r["frameCount"] for r in rows)} | '
                             f'{statistics.median(r["uiP95Us"] for r in rows):.1f} | '
                             f'{statistics.median(r["rasterP95Us"] for r in rows):.1f} | {misses} |')
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
    lines += ['', '## Held input to decoded physical paddle state', '',
              'First changed decoded monitor state while held, not raster presentation. Shared deadline: 5,000 ms from press. Standard mode and LEFT/RIGHT have explicit not-applicable paddle evidence; sensor acknowledgements remain required.', '',
              '| Mode | Input | Actual samples | Median ms | p95 ms |',
              '|---|---|---:|---:|---:|']
    for mode in MODES:
        for direction in PADDLE_STATE_INPUTS:
            values = [row['pressToPaddleStateMs'] for row in inputs
                      if row['mode'] == mode and row['input'] == direction and row.get('paddleStateLatencyStatus') == 'observed']
            if values:
                lines.append(f'| {mode} | {direction} | {len(values)} | '
                             f'{statistics.median(values):.2f} | {percentile(values, .95):.2f} |')
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
    lines += ['', '## Application OS memory during loading', '',
              'Per-window sampled maxima are separate from cumulative process VmHWM. The first complete load follows a cancelled attempt; filesystem cache state is uncontrolled. Mode labels identify the later lifecycle run, not a different import strategy.', '',
              '| Process | Attempt / outcome | Cycle / mode / kind | RSS baseline / sampled peak / terminal MiB | Smaps RSS / PSS / USS sampled peak MiB | Cumulative VmHWM baseline / end MiB |',
              '|---|---|---|---|---|---|']
    def mib(value):
        return 'unavailable' if value is None else f'{value / 2**20:.2f}'
    loading = [(name, value['loadingOsMemory']) for name, value in data.items()
               if 'loadingOsMemory' in value]
    for name, observed in loading:
        for window in observed['windows']:
            peaks = window['sampleMax']
            lines.append(f'| {name} | {window["hostLoadAttempt"]} / {window["outcome"]} | '
                         f'{window["cycle"]} / {window["mode"]} / {window["kind"]} | '
                         f'{mib(window["baseline"]["rssBytes"])} / {mib(peaks["rssBytes"])} / {mib(window["terminal"]["rssBytes"])} | '
                         f'{mib(peaks["smapsRssBytes"])} / {mib(peaks["pssBytes"])} / {mib(peaks["ussBytes"])} | '
                         f'{mib(window["processVmHwmAtBaselineBytes"])} / {mib(window["processVmHwmAtEndBytes"])} |')
    lines += ['', '### Actual loading sample counts and intervals', '',
              'Target intervals: status 10 ms, smaps 100 ms. Observed gaps and counts are reported without a performance threshold.', '',
              '| Process | Attempt | Duration ms | Status / periodic / smaps samples | Status min / mean / max ms | Smaps min / mean / max ms |',
              '|---|---:|---:|---|---|---|']
    def gaps(row):
        return ' / '.join('unavailable' if row[key] is None else f'{row[key] / 1000:.2f}'
                          for key in ('min', 'mean', 'max'))
    for name, observed in loading:
        for window in observed['windows']:
            lines.append(f'| {name} | {window["hostLoadAttempt"]} | {window["durationUs"] / 1000:.2f} | '
                         f'{window["statusSampleCount"]} / {window["periodicStatusSampleCount"]} / {window["smapsSampleCount"]} | '
                         f'{gaps(window["statusIntervalUs"])} | {gaps(window["smapsIntervalUs"])} |')
        reason = str(observed['smapsUnavailable'] or 'no read failure').replace('\n', ' ').replace('|', '/')
        lines += ['', f'{name}: PSS/USS {observed["pssUssAvailability"]}; {reason}.']
    lines += ['', '### Independent OS samples after close', '',
              '| Process | Cycle / mode / phase | RSS / smaps RSS / PSS / USS MiB | Cumulative VmHWM MiB |',
              '|---|---|---|---|']
    for name, observed in loading:
        for close in observed['closeSamples']:
            sample = close['sample']
            lines.append(f'| {name} | {close["cycle"]} / {close["mode"]} / {close["phase"]} | '
                         f'{" / ".join(mib(sample[field]) for field in OS_MEMORY_FIELDS)} | '
                         f'{mib(sample["processVmHwmBytes"])} |')
    lines += ['', 'Full raw frame arrays, per-input latencies, first/repeat RSS and VM heap samples, bounded OS loading observations, import/save timings, and per-window display-change/pulse rates are retained in the JSON and original artifacts.', '', '## Interpretation', '']
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
    print(f"Computerraria report validity/correctness: {result['status']}; {result['acceptedReports']}/15 reports; "
          f"display calibration: {result['displayCalibration']['status']}; target-device fluency: not established")
    return result['status'] != 'passed'


if __name__ == '__main__':
    raise SystemExit(main())
