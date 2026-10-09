#!/usr/bin/env python3
"""Validate a bounded diagnostic, without turning its trends into leak proof.

Only received FrameTiming records can be reconciled. Engine timings not yet
emitted at the recording deadline are unknowable. Raw JSONL is hashed and read
one line at a time; repeated engine frame numbers are counted, never discarded.
"""
import argparse
from bisect import bisect_right
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import sys

from memory_probe_control_rss import process_info_disagreement


WLD_BYTES = 405983441
WLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
PONG_SHA = 'd2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d'
SOURCE_REVISION = '0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8'
FLUTTER_REVISION = '5fc346839b5d0eef006ed8404392afb4dfae428d'
HEAP_METHOD = 'vm-service-isolate-groups-v1'
RECORD_TYPES = ('window', 'dispatch', 'viewportSnapshot', 'failureDiagnostic')
RETAINED_KEYS = dict(zip(RECORD_TYPES, ('windows', 'dispatches', 'viewportSnapshots', 'failureDiagnostics')))
FRAME_PHASES = ('vsyncStart', 'buildStart', 'buildFinish', 'rasterStart', 'rasterFinish', 'rasterFinishWallTime')
CACHE_FIELDS = ('layerCacheCount', 'layerCacheBytes', 'pictureCacheCount', 'pictureCacheBytes')
OS_FIELDS = ('rssBytes', 'processVmHwmBytes', 'smapsRssBytes', 'pssBytes', 'ussBytes')
VM_FIELDS = ('rssBytes', 'maxRssBytes', 'heapUsedBytes', 'heapCapacityBytes', 'externalBytes',
             'sampledIsolates', 'sampledIsolateGroups', 'exitedIsolatesDuringProbe', 'exitedIsolateGroupsDuringProbe')
REQUIRED_SOURCES = {
    'integration_test/computer_memory_diagnostic_test.dart',
    'integration_test/support/computer_memory_journal.dart',
    'integration_test/support/profile_memory_native.dart',
    'integration_test/support/profile_recorder.dart',
    'integration_test/support/profile_controller.dart',
    'lib/domain/computerraria_computer.dart',
    'assets/computer/pong.bin',
    '.flutter-version',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, label, minimum=0):
    require(type(value) is int and value >= minimum, f'{label}: integer >= {minimum} required')
    return value


def finite(value, label, minimum=0):
    require(type(value) in (int, float) and math.isfinite(value) and value >= minimum,
            f'{label}: finite number >= {minimum} required')
    return value


def sha(value):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'malformed SHA-256')
    return value


def load_json(path):
    def reject_constant(value):
        raise ValueError(f'non-JSON numeric constant: {value}')
    with Path(path).open(encoding='utf-8') as stream:
        result = json.load(stream, parse_constant=reject_constant)
    require(isinstance(result, dict), 'JSON object required')
    return result


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def trend(series, cycles=None):
    """Descriptive bounded-window statistics; nonmonotonicity proves no plateau."""
    cycles = list(range(len(series))) if cycles is None else list(cycles)
    result = {'series': list(series), 'cycles': cycles, 'sampleCount': len(series),
              'status': 'insufficient-evidence', 'plateauEstablished': False}
    if len(series) != len(cycles) or len(series) < 2 or any(
            type(value) not in (int, float) or not math.isfinite(value) for value in series):
        return result
    xmean, ymean = sum(cycles) / len(cycles), sum(series) / len(series)
    denominator = sum((value - xmean) ** 2 for value in cycles)
    slope = (sum((x - xmean) * (y - ymean) for x, y in zip(cycles, series)) / denominator
             if denominator else None)
    increasing = all(a < b for a, b in zip(series, series[1:]))
    result.update({'status': ('continued-growth-in-observed-window' if increasing else
                              'plateau-not-established-inconclusive'),
                   'strictlyIncreasing': increasing, 'first': series[0], 'last': series[-1],
                   'minimum': min(series), 'maximum': max(series), 'range': max(series) - min(series),
                   'netChange': series[-1] - series[0], 'slopePerCycle': slope})
    return result


def point_metrics(point):
    result = {}
    for section, names in (('vm', VM_FIELDS), ('osBefore', OS_FIELDS), ('osAfter', OS_FIELDS)):
        values = point.get(section) or {}
        result.update({f'{section}.{name}': values.get(name) for name in names})
    counts = point.get('recorder') or {}
    for name in ('frames', 'frameReceipts', *RETAINED_KEYS.values(), 'receivedFrames',
                 'persistedFrames', 'receivedBatches', 'chunkDescriptors', 'boundaryDescriptors'):
        result[f'recorder.{name}'] = counts.get(name)
    return result


def difference(after, before):
    return {key: (after[key] - before[key] if type(after[key]) in (int, float)
                  and type(before.get(key)) in (int, float) else None) for key in after}


def summarize_points(points):
    lookup = {(p.get('cycle'), p.get('phase')): p for p in points if isinstance(p, dict)}
    baseline = point_metrics(lookup.get((-1, 'baseline'), {}))
    cycles = []
    for cycle in range(8):
        retained = point_metrics(lookup.get((cycle, 'after-close-retained'), {}))
        released = point_metrics(lookup.get((cycle, 'after-close-released'), {}))
        cycles.append({'cycle': cycle, 'mode': 'optimized' if cycle % 2 else 'standard',
                       'scenario': 'reset-original' if cycle // 2 % 2 == 0 else 'save-reopen',
                       'retained': retained, 'released': released,
                       'releasedMinusRetained': difference(released, retained),
                       'retainedMinusBaseline': difference(retained, baseline),
                       'releasedMinusBaseline': difference(released, baseline)})
    trends = {}
    for group, selected in (('overall', cycles), ('standard', cycles[::2]), ('optimized', cycles[1::2])):
        trends[group] = {phase: {key: trend([row[phase][key] for row in selected],
                                           [row['cycle'] for row in selected])
                                 for key in baseline} for phase in ('retained', 'released')}
    pairs = [{'cycles': [a['cycle'], b['cycle']], 'scenario': a['scenario'],
              'releasedOptimizedMinusStandard': difference(b['released'], a['released'])}
             for a, b in zip(cycles[::2], cycles[1::2])]
    return {'baseline': baseline, 'cycles': cycles, 'trends': trends, 'modePairs': pairs}


class Validator:
    def __init__(self, report, raw_directory, build, expected_commit, build_sha256):
        self.report, self.root, self.build = report, Path(raw_directory), build
        self.expected_commit, self.build_sha256 = expected_commit, build_sha256
        self.errors, self.warnings, self.files = [], [], []
        self.rss_sampling_warnings = []
        self.records = {kind: [] for kind in RECORD_TYPES}
        self.frame_count = self.os_count = self.last_batch = 0
        self.last_batch = -1
        self.last_received = self.last_os_time = -1
        self.engine_frames, self.duplicate_numbers = set(), Counter()
        self.duplicate_count = 0
        self.frame_classification, self.late_boundaries = Counter(), Counter()
        self.os_phases, self.os_maxima, self.os_selected = Counter(), {}, {}
        self.os_periodic = self.os_smaps = 0
        raw = report.get('raw') if isinstance(report.get('raw'), dict) else {}
        self.boundaries = raw.get('boundaries', [])
        self.cycle_bounds = {}
        self.referenced_os = {row.get('sequence') for point in report.get('memoryPoints', [])
                              if isinstance(point, dict) for name in ('osBefore', 'osAfter')
                              if isinstance(row := point.get(name), dict)}

    def guard(self, label, function):
        try:
            return function()
        except (ValueError, TypeError, KeyError, IndexError, AttributeError, OSError, OverflowError) as error:
            if len(self.errors) < 500:
                self.errors.append(f'{label}: {error}')
            elif len(self.errors) == 500:
                self.errors.append('Additional errors omitted after the first 500 failures')
            return None

    def validate_provenance(self):
        report, build = self.report, self.build
        require(re.fullmatch('[0-9a-f]{40}', self.expected_commit or ''), 'full expected commit required')
        require(build['schema'] == 'abc.computerraria.build.v1', 'unknown build schema')
        source = build['source']
        require(source['commit'] == source['checkedOutHead'] == self.expected_commit,
                'build source does not match expected commit')
        require(source['dirty'] is False, 'build source is dirty or unknown')
        files = build['sourceFilesSha256']
        require(isinstance(files, dict) and REQUIRED_SOURCES <= set(files), 'required source hashes missing')
        for path, value in files.items():
            require(isinstance(path, str) and not Path(path).is_absolute() and '..' not in Path(path).parts,
                    'source manifest contains an unsafe path')
            sha(value)
        require(files['assets/computer/pong.bin'] == PONG_SHA, 'build Pong source hash differs')
        tree = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        require(tree == build['sourceTreeSha256'], 'source tree digest mismatch')
        require(build['cmake']['CMAKE_BUILD_TYPE'] == 'Profile', 'actual CMake build is not Profile')
        require(str(build['cmake']['ABC_PERF_COUNTERS']).upper() in ('OFF', 'FALSE', '0'),
                'native counter instrumentation unexpectedly enabled')
        flags = build['effectiveCompileFlags']
        require(set(flags) == {'abc_world_circuit.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o'},
                'actual wiring VM flags missing')
        for value in flags.values():
            require('-O3' in value.split() and '-DNDEBUG' in value.split(), 'wiring VM is not Release optimized')
        require({'terraforge', 'libabc_engine.so', 'libapp.so'} <= set(build['artifacts']), 'built artifacts missing')
        for artifact in build['artifacts'].values():
            sha(artifact['sha256'])
            integer(artifact['bytes'], 'artifact length', 1)
        runtime = report['runtime']
        require(runtime['commit'] == runtime['checkedOutHead'] == self.expected_commit,
                'report source revision differs from build/expected commit')
        require(runtime['workingTreeDirty'] is False, 'runtime source is dirty or unknown')
        require(runtime['buildProvenanceSha256'] == self.build_sha256, 'report/build file digest mismatch')
        require(runtime['sourceTreeSha256'] == tree, 'report/build source tree mismatch')
        require(runtime['provenanceAttachment'] == 'single-diagnostic-runner-after-process',
                'missing explicit runner provenance attachment method')
        require(runtime['platform'] == 'linux' and runtime['flutterRevisionPin'] == FLUTTER_REVISION,
                'wrong platform or Flutter revision')
        require(runtime.get('flutterVersion') and runtime.get('renderer'), 'toolchain version or renderer missing')
        require(hashlib.sha256((runtime['flutterVersion'] + '\n').encode()).hexdigest() == files['.flutter-version'],
                'runtime Flutter version differs from pinned source file')
        require(runtime['heapMeasurementMethod'] == HEAP_METHOD, 'wrong runtime heap method')

    def validate_header(self):
        report = self.report
        require(report['schema'] == 'abc.computer-memory-diagnostic.v1', 'unknown report schema')
        require(report['status'] == 'observed' and report.get('failure') is None
                and report.get('failureStack') is None, 'failed or partial run cannot pass')
        integer(report['hostPid'], 'host PID', 1)
        require(report['buildMode'] == 'profile' and report['inputFormat'] == 'wld-only'
                and report['circuitAbi'] == 2, 'real profile WLD ABI 2 required')
        require(report['plannedCycles'] == report['completedCycles'] == 8, 'exactly eight complete cycles required')
        require(report['physicalPulsesPerCycle'] == 4096 and report['excludedWarmupCycles'] == 0,
                'fixed 32 x 128 pulses and no excluded warmup required')
        fixture = report['fixture']
        require(fixture['wldBytes'] == WLD_BYTES and fixture['wldSha256'] == WLD_SHA
                and fixture['pongSha256'] == PONG_SHA, 'pinned full fixture bytes/hashes differ')
        require(fixture['sourceRevision'] == SOURCE_REVISION, 'pinned upstream source revision differs')
        require(self.root.is_dir() and report['raw']['directory'] == self.root.name,
                'raw directory is missing or belongs to a different run')
        drain = report['drainPolicy']
        require(drain['frameBarriers'] == 3 and drain['barrierDelayMs'] == 16
                and drain['quietMs'] == 1200 and drain['tailPrefixFlushesPerCycle'] == 2,
                'bounded drain policy differs')
        require(drain['capture'] == 'all-callbacks-received-until-recordingStoppedUs',
                'unsupported frame capture completeness claim')

    def validate_boundaries(self):
        require(isinstance(self.boundaries, list) and self.boundaries, 'missing reception boundaries')
        previous_time = previous_frames = previous_batches = -1
        for boundary in self.boundaries:
            time = integer(boundary['timeUs'], 'boundary timestamp')
            frames = integer(boundary['receivedFrames'], 'boundary received frames')
            batches = integer(boundary['receivedBatches'], 'boundary received batches')
            require(time >= previous_time and frames >= previous_frames and batches >= previous_batches,
                    'boundary clock or reception counts moved backwards')
            final = self.report['raw']['finalCounts']
            require(frames <= final['receivedFrames'] and batches <= final['receivedBatches'],
                    'boundary reception counters exceed final totals')
            previous_time, previous_frames, previous_batches = time, frames, batches
        stopped = integer(self.report['raw']['recordingStoppedUs'], 'recording stop timestamp')
        require(stopped >= previous_time, 'recording stopped before final boundary')
        previous_end = -1
        for cycle in range(8):
            rows = [row for row in self.boundaries if row['cycle'] == cycle]
            expected = ['cycle-start']
            if cycle == 0:
                expected += ['cancelled-import-start', 'cancelled-import-end']
            expected += ['initial-import-start', 'initial-import-ready']
            expected += (['reset-original-start', 'reset-original-ready'] if cycle // 2 % 2 == 0 else
                         ['export-close', 'saved-reopen-start', 'saved-reopen-ready'])
            expected += ['cycle-disposed', 'drain-start', 'drain-end', 'retained-point',
                         'released-prefix', 'drain-start', 'drain-end', 'released-point', 'cycle-end']
            require([row['phase'] for row in rows] == expected, f'cycle {cycle}: missing/duplicate/out-of-order phase')
            require(rows[0]['timeUs'] >= previous_end, 'cycles overlap')
            previous_end = rows[-1]['timeUs']
            self.cycle_bounds[cycle] = (rows[0], rows[-1])
        require([(b['cycle'], b['phase']) for b in self.boundaries if b['cycle'] not in range(8)]
                == [(8, 'drain-start'), (8, 'drain-end')], 'missing final drain or unknown cycle')
        drain_start = None
        for boundary in self.boundaries:
            if boundary['phase'] == 'drain-start':
                require(drain_start is None, 'overlapping drains')
                drain_start = boundary['timeUs']
            elif boundary['phase'] == 'drain-end':
                require(drain_start is not None and boundary['timeUs'] - drain_start >= 1200000,
                        'drain shorter than declared real quiet interval')
                drain_start = None
        require(drain_start is None, 'unfinished final drain')

    def validate_cycles(self):
        cycles = self.report['cycles']
        require(len(cycles) == 8 and [row['cycle'] for row in cycles] == list(range(8)),
                'cycles are missing, duplicated or out of order')
        for cycle, row in enumerate(cycles):
            self.guard(f'cycle {cycle}', lambda row=row, cycle=cycle: self.validate_cycle(row, cycle))

    def validate_cycle(self, row, cycle):
        mode = 'optimized' if cycle % 2 else 'standard'
        scenario = 'reset-original' if cycle // 2 % 2 == 0 else 'save-reopen'
        require(row['mode'] == mode and row['scenario'] == scenario, 'OFF/ON pair-matched workload differs')
        require(row['status'] == 'completed', 'cycle did not complete')
        for name in ('physicalPulseDelta', 'nativeClockDelta', 'modelPhysicalPulseDelta'):
            require(integer(row[name], name) == 4096, 'real fixed pulse evidence differs')
        require(row['pulseBatchCount'] == 32 and row['pulseBatchSize'] == 128, 'fixed pulse batch shape differs')
        for name in ('optimizationEnabledDuringPulse', 'nativeOptimizationEnabledDuringPulse',
                     'nativeWireHeadPixelRulesDuringPulse'):
            require(row[name] is bool(cycle % 2), 'model/native pulse mode differs')
        require(row['programName'] == 'Pong (upstream RV32I).bin', 'wrong program')
        sha(row['pausedMonoSha256'])
        if cycle == 0:
            require(row['cancelledImportObserved'] is True, 'first-cycle cancellation evidence missing')
            require(row['cancelRequestedAfterNativeOpenStarted'] is True, 'native import was not observed before cancellation')
        else:
            require(not row.get('cancelledImportObserved'), 'unexpected additional cancellation')
        if scenario == 'reset-original':
            require(row['resetRestoredOriginal'] is True, 'reset did not restore original')
        else:
            sha(row['savedWldSha256'])
            require(row['reopenPreservedPausedState'] is True, 'saved reopen did not preserve paused state')
        active = None
        active_cancelled = False
        opened = closed = cancelled = cancelled_ready = cancelled_closed = 0
        last_end = -1
        bounds = self.cycle_bounds.get(cycle)
        disposed = [boundary['timeUs'] for boundary in self.boundaries
                    if boundary['cycle'] == cycle and boundary['phase'] == 'cycle-disposed']
        for event_index, event in enumerate(row['events']):
            start, end = integer(event['startUs'], 'native event start'), integer(event['endUs'], 'native event end')
            require(last_end <= start <= end, 'native lifecycle events overlap or time moved backwards')
            if bounds:
                require(bounds[0]['timeUs'] <= start <= end <= bounds[1]['timeUs'], 'native event outside cycle')
            require(len(disposed) == 1 and end <= disposed[0], 'native cleanup extends past cycle disposal')
            last_end = end
            if event['kind'] == 'native-open':
                require(active is None, 'new open without preceding close')
                integer(event['sourceBytes'], 'native source bytes', 1)
                is_cancel_attempt = cycle == 0 and event_index == 0
                if is_cancel_attempt:
                    require(row['cancelledImportNativeOutcome'] == event['outcome'], 'cancelled native outcome differs')
                    cancellation = [boundary for boundary in self.boundaries
                                    if boundary['cycle'] == 0 and boundary['phase'] == 'cancelled-import-start']
                    initial = [boundary for boundary in self.boundaries
                               if boundary['cycle'] == 0 and boundary['phase'] == 'initial-import-start']
                    require(len(cancellation) == len(initial) == 1 and
                            cancellation[0]['timeUs'] <= start <= end <= initial[0]['timeUs'],
                            'cancelled native attempt not contained before planned initial import')
                    cancelled += 1
                if event['outcome'] == 'failed-or-cancelled':
                    require(is_cancel_attempt and event.get('error'),
                            'unexpected failed native open')
                    continue
                require(event['outcome'] == 'ready' and event['circuitAbi'] == 2, 'native open never reached ABI 2 ready')
                expected_hash = row['savedWldSha256'] if opened == 1 and scenario == 'save-reopen' else WLD_SHA
                require(event['sourceSha256'] == expected_hash, 'native source hash differs')
                if expected_hash == WLD_SHA:
                    require(event['sourceBytes'] == WLD_BYTES, 'native open is not full pinned WLD')
                active = integer(event['session'], 'native session', 1)
                active_cancelled = is_cancel_attempt
                if is_cancel_attempt:
                    cancelled_ready += 1
                else:
                    opened += 1
            elif event['kind'] == 'native-close':
                require(active is not None and event['session'] == active and event['outcome'] == 'acknowledged',
                        'unmatched or unacknowledged native close')
                active = None
                if active_cancelled:
                    require(end <= initial[0]['timeUs'], 'cancelled ready session not closed before planned import')
                    cancelled_closed += 1
                else:
                    closed += 1
            else:
                raise ValueError('unknown native lifecycle event')
        require(active is None and opened == closed == 2 and cancelled == (1 if cycle == 0 else 0)
                and cancelled_ready == cancelled_closed,
                'incomplete native lifecycle cleanup evidence')

    def scan_file(self, descriptor, consume):
        name = descriptor['file']
        require(isinstance(name, str) and Path(name).name == name and name.endswith('.jsonl'), 'unsafe raw file path')
        path = self.root / name
        require(not path.is_symlink() and path.is_file(), f'missing raw file {name}')
        require(name not in self.files, f'duplicate raw file {name}')
        self.files.append(name)
        hasher, byte_count, line_count = hashlib.sha256(), 0, 0
        with path.open('rb') as stream:
            for line in stream:
                byte_count += len(line)
                line_count += 1
                hasher.update(line)
                def parse():
                    require(line.endswith(b'\n'), 'incomplete JSONL final line')
                    row = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                    require(isinstance(row, dict), 'raw JSONL object required')
                    consume(row, line_count)
                self.guard(f'{name}:{line_count}', parse)
        require(byte_count == descriptor['bytes'] and hasher.hexdigest() == descriptor['sha256'],
                f'{name}: raw bytes/SHA-256 mismatch')
        require(line_count > 0, f'{name}: empty raw file')
        return hasher.hexdigest(), byte_count

    def validate_frames(self):
        chunks = self.report['raw']['frameChunks']
        expected_reasons = [reason for cycle in range(8)
                            for reason in (f'cycle-{cycle}.release-prefix', f'cycle-{cycle}.late-tail')]
        expected_reasons.append('final-received-tail')
        require([row['reason'] for row in chunks] == expected_reasons, 'missing or reordered raw frame chunks')
        previous_verified = -1
        for index, descriptor in enumerate(chunks):
            def check_chunk():
                nonlocal previous_verified
                first, count = self.frame_count, 0
                counts = Counter()
                require(descriptor['firstSequence'] == first, 'chunk first frame sequence has a gap')
                require(descriptor['hashVerifiedBeforeRelease'] is True, 'chunk released without reread verification')
                start, verified = descriptor['writeStartedUs'], descriptor['verifiedUs']
                require(previous_verified <= start <= verified, 'chunk write/verification order invalid')
                previous_verified = verified
                if index == 16:
                    require(start >= self.report['raw']['recordingStoppedUs'], 'final chunk preceded recording stop')
                else:
                    cycle = index // 2
                    points = [p for p in self.report['memoryPoints'] if p['cycle'] == cycle]
                    require(len(points) == 2 and points[0]['endUs'] <= start <= verified <= points[1]['startUs'],
                            'prefix chunk was not verified between retained/released checkpoints')

                def consume(row, line):
                    nonlocal count
                    kind = row['type']
                    if line == 1:
                        require(kind == 'chunk' and row['schema'] == 'abc.memory-raw.v1', 'raw chunk header missing')
                        require(row['hostPid'] == self.report['hostPid'], 'raw chunk PID mismatch')
                        for field in ('reason', 'firstSequence', 'frameCount', 'recordCounts'):
                            require(row[field] == descriptor[field], f'chunk header/descriptor {field} differs')
                        require(row['startedUs'] == start, 'chunk header write time differs')
                    elif kind == 'frame':
                        count += 1
                        require(row['receivedUs'] <= start, 'raw frame was received after its frozen flush prefix')
                        self.validate_frame(row)
                    elif kind in RECORD_TYPES:
                        counts[kind] += 1
                        require(isinstance(row['data'], dict), 'invalid recorder record')
                        self.records[kind].append(row['data'])
                    else:
                        raise ValueError('unexpected raw record type or repeated chunk header')
                observed_hash, observed_bytes = self.scan_file(descriptor, consume)
                require(count == descriptor['frameCount'], 'raw frame count differs from chunk descriptor')
                require(set(descriptor['recordCounts']) == set(RECORD_TYPES), 'record count types missing')
                require(dict((kind, counts[kind]) for kind in RECORD_TYPES) == descriptor['recordCounts'],
                        'window/dispatch/diagnostic records lost or duplicated')
                require(descriptor['writeSha256'] == descriptor['readSha256'] == observed_hash,
                        'write/read/raw hash verification mismatch')
                require(descriptor['writeBytes'] == descriptor['readBytes'] == observed_bytes,
                        'write/read/raw byte verification mismatch')
            self.guard(f'frame chunk {index}', check_chunk)
        final = self.report['raw']['finalCounts']
        require(self.frame_count > 0, 'no raw engine frames received')
        require(self.frame_count == final['receivedFrames'] == final['persistedFrames'], 'received/persisted frame totals differ')
        require(final['frames'] == final['frameReceipts'] == 0, 'unpersisted frame tail remains')
        require(final['chunkDescriptors'] == len(chunks) and final['boundaryDescriptors'] == len(self.boundaries),
                'final descriptor counts differ')
        require(self.last_batch < integer(final['receivedBatches'], 'received batches', 1), 'received batch count differs')
        for kind, key in RETAINED_KEYS.items():
            require(final[key] == 0 and len(self.records[kind]) == final['receivedRecords'][kind]
                    == final['persistedRecords'][kind], f'final {kind} accounting differs')

    def validate_frame(self, row):
        sequence = integer(row['sequence'], 'frame sequence')
        require(sequence == self.frame_count, 'dropped/repeated/out-of-order global received-frame sequence')
        self.frame_count += 1
        batch, received = integer(row['batch'], 'frame batch'), integer(row['receivedUs'], 'frame reception timestamp')
        require(batch >= self.last_batch and received >= self.last_received, 'frame receptions moved backwards')
        require(batch != self.last_batch or received == self.last_received, 'one callback batch has different reception times')
        self.last_batch, self.last_received = batch, received
        require(received <= self.report['raw']['recordingStoppedUs'], 'frame received after recording stopped')
        timestamps = row['timestampsUs']
        require(set(timestamps) == set(FRAME_PHASES), 'public FrameTiming timestamps missing')
        values = [integer(timestamps[phase], phase) for phase in FRAME_PHASES]
        require(values[:5] == sorted(values[:5]) and values[4] <= received, 'invalid monotonic frame/reception timestamps')
        require(values[5] > 0, 'rasterFinishWallTime missing')
        for field in CACHE_FIELDS:
            integer(row[field], field)
        number = integer(row['frameNumber'], 'engine frame number')
        if number in self.engine_frames:
            self.duplicate_count += 1
            if len(self.duplicate_numbers) < 100 or number in self.duplicate_numbers:
                self.duplicate_numbers[number] += 1
        self.engine_frames.add(number)
        timestamp_cycle = reception_cycle = 'outside-cycle'
        for cycle, (start, end) in self.cycle_bounds.items():
            if start['timeUs'] <= values[0] < end['timeUs']:
                timestamp_cycle = str(cycle)
            if start['receivedFrames'] <= sequence < end['receivedFrames']:
                reception_cycle = str(cycle)
        self.frame_classification[f'timestamp-cycle:{timestamp_cycle}/reception-cycle:{reception_cycle}'] += 1
        for index, boundary in enumerate(self.boundaries):
            before = sequence < boundary['receivedFrames']
            require(received <= boundary['timeUs'] if before else received >= boundary['timeUs'],
                    'frame reception contradicts boundary reception count')
            require(batch < boundary['receivedBatches'] if before else batch >= boundary['receivedBatches'],
                    'frame batch contradicts boundary reception count')
            if values[0] < boundary['timeUs'] and not before:
                self.late_boundaries[f'{index}:{boundary["cycle"]}:{boundary["phase"]}'] += 1

    def validate_records(self):
        require(not self.records['failureDiagnostic'], 'failure diagnostics were recorded')
        windows, dispatches = self.records['window'], self.records['dispatch']
        expected_windows = Counter()
        expected_dispatches = Counter()
        for cycle in range(8):
            mode = 'optimized' if cycle % 2 else 'standard'
            actions = ['worldCircuitChooseWorld', 'worldCircuitImport', 'worldCircuitLoadPong',
                       *(['worldCircuitStep'] * 32), 'worldCircuitPause', 'worldCircuitClose']
            if cycle == 0:
                actions.append('worldCircuitChooseWorld')
            if cycle % 2:
                actions.append('worldCircuitOptimization')
            actions += (['worldCircuitReset'] if cycle // 2 % 2 == 0 else
                        ['worldCircuitSave', 'worldCircuitClose', 'worldCircuitChooseWorld', 'worldCircuitImport'])
            expected_windows.update((cycle, f'{action}.{mode}') for action in actions)
            expected_dispatches.update((cycle, action, f'{action}.{mode}') for action in actions)
        expected_dispatches.update({(0, 'worldCircuitImport', None): 1, (0, 'worldCircuitCancel', None): 1})
        require(Counter((w['cycle'], w['id']) for w in windows) == expected_windows,
                'missing/duplicate action windows (including cancelled first lifecycle)')
        releases = [dispatch for dispatch in dispatches if dispatch['action'] == 'worldCircuitReleaseKeys']
        require(Counter((d['cycle'], d['action'], d['macroScope']) for d in dispatches
                        if d['action'] != 'worldCircuitReleaseKeys') == expected_dispatches,
                'missing/duplicate real controller dispatch records')
        for cycle in range(8):
            required_closes = 1 if cycle // 2 % 2 == 0 else 2
            require(sum(dispatch['cycle'] == cycle for dispatch in releases) >= required_closes,
                    'production panel disposal key-release dispatch missing')
        for release in releases:
            require(release['cycle'] in range(8) and (release['macroScope'] is None or
                    (release['cycle'], release['macroScope']) in expected_windows),
                    'key-release dispatch is attributed to unknown scope')
        previous_end = -1
        for window in windows:
            start, end = integer(window['startUs'], 'window start'), integer(window['endUs'], 'window end')
            require(previous_end <= start <= end, 'window timing overlaps or moved backwards')
            previous_end = end
            require(window['success'] is True and window['warmup'] is False, 'failed/excluded window')
            for name in ('rssBeforeBytes', 'rssAfterBytes'):
                integer(window[name], name, 1)
        for dispatch in dispatches:
            require(dispatch['completion'] == 'returned' and dispatch['warmup'] is False, 'failed/excluded dispatch')
            require(dispatch['variant']['profileMode'] == ('optimized' if dispatch['cycle'] % 2 else 'standard'),
                    'dispatch mode differs')
            finite(dispatch['durationMs'], 'dispatch duration')
        trace = self.records['viewportSnapshot']
        require([(row['cycle'], row['batch']) for row in trace] ==
                [(cycle, batch) for cycle in range(8) for batch in range(32)],
                'missing/duplicated/reordered raw display pulse batch trace')
        for cycle in range(8):
            rows = trace[cycle * 32:(cycle + 1) * 32]
            for batch, row in enumerate(rows):
                require(row['mode'] == ('optimized' if cycle % 2 else 'standard'), 'display trace mode differs')
                for name in ('physicalPulses', 'nativeClockDelta', 'modelPhysicalPulseDelta'):
                    require(integer(row[name], name) == (batch + 1) * 128, 'raw trace native/model physical pulse mismatch')
                sha(row['monoSha256'])
                require(integer(row['monoLitPixels'], 'lit pixels') <= 64 * 48, 'display pixel count exceeds viewport')
            evidence = self.report['cycles'][cycle]
            distinct, lit = len({row['monoSha256'] for row in rows}), max(row['monoLitPixels'] for row in rows)
            require(evidence['distinctMonoStates'] == distinct and evidence['maximumLitPixels'] == lit,
                    'raw display trace and cycle display summary differ')
            require(evidence['pausedMonoSha256'] == rows[-1]['monoSha256'], 'paused viewport differs from final pulse batch')
            require(not cycle % 2 or (distinct > 1 and lit > 0), 'ON workload lacks real changing/lit display evidence')

    def validate_os(self):
        os_report = self.report['raw']['os']
        require(os_report['hostPid'] == self.report['hostPid'], 'OS sampler is not the single report PID')
        require(os_report.get('error') is None, 'OS sampler failed or is incomplete')
        require(len(os_report['files']) == 9, 'missing OS rotation files')
        for index, descriptor in enumerate(os_report['files']):
            def check_file():
                count = 0
                def consume(row, line):
                    nonlocal count
                    count += 1
                    self.validate_os_row(row)
                self.scan_file(descriptor, consume)
                require(count == descriptor['sampleCount'], 'OS raw file sample count differs')
            self.guard(f'OS file {index}', check_file)
        require(self.os_count > 0 and self.os_count == os_report['sampleCount'], 'OS raw total count differs')
        require(self.os_periodic > 0 and self.os_smaps >= 34, 'missing periodic or checkpoint RSS/PSS/USS samples')
        expected_phases = Counter({'baseline.before-gc': 1, 'baseline.after-gc': 1,
                                   'after-close-retained.before-gc': 8, 'after-close-retained.after-gc': 8,
                                   'after-close-released.before-gc': 8, 'after-close-released.after-gc': 8,
                                   'cycle-0.cancelled-import-start': 1, 'cycle-0.cancelled-import-end': 1,
                                   'recording-stopped': 1})
        for cycle in range(8):
            for phase in ('initial-import-start', 'initial-import-ready', 'end'):
                expected_phases[f'cycle-{cycle}.{phase}'] += 1
            for phase in (('reset-original-start', 'reset-original-ready') if cycle // 2 % 2 == 0 else
                          ('export-close', 'saved-reopen-start', 'saved-reopen-ready')):
                expected_phases[f'cycle-{cycle}.{phase}'] += 1
        require({key: value for key, value in self.os_phases.items() if key != 'periodic'} == expected_phases,
                'OS boundary samples missing or duplicated')

    def validate_os_row(self, row):
        require(row['type'] == 'os', 'unknown OS raw record')
        sequence = integer(row['sequence'], 'OS sequence')
        require(sequence == self.os_count, 'dropped/repeated/out-of-order OS sample sequence')
        self.os_count += 1
        time, end = integer(row['timeUs'], 'OS time'), integer(row['statusEndUs'], 'status read end')
        require(self.last_os_time <= time <= end, 'OS status timestamp order invalid')
        self.last_os_time = end
        if 'hostPid' in row:
            require(row['hostPid'] == self.report['hostPid'], 'OS raw PID differs')
        for field in OS_FIELDS[:2]:
            integer(row[field], field, 1)
        require(row['processVmHwmBytes'] >= row['rssBytes'], 'process HWM below current status RSS')
        smaps_fields = ('smapsTimeUs', 'smapsEndUs', *OS_FIELDS[2:])
        if row['smapsTimeUs'] is None:
            require(all(row[field] is None for field in smaps_fields), 'partially missing smaps sample')
            require(row['phase'] == 'periodic', 'boundary sample lacks PSS/USS')
        else:
            for field in smaps_fields:
                integer(row[field], field, 1)
            require(end <= row['smapsTimeUs'] <= row['smapsEndUs'], 'sequential OS read brackets invalid')
            self.last_os_time = row['smapsEndUs']
            self.os_smaps += 1
        require(isinstance(row['phase'], str) and row['phase'], 'OS phase missing')
        self.os_phases[row['phase']] += 1
        self.os_periodic += row['phase'] == 'periodic'
        for field in OS_FIELDS:
            value = row[field]
            if value is not None and (field not in self.os_maxima or value > self.os_maxima[field]['value']):
                self.os_maxima[field] = {'value': value, 'sequence': sequence,
                                         'timeUs': time if field in OS_FIELDS[:2] else row['smapsTimeUs']}
        if sequence in self.referenced_os:
            self.os_selected[sequence] = row

    def validate_points(self):
        points = self.report['memoryPoints']
        expected = [(-1, 'baseline')] + [(cycle, phase) for cycle in range(8)
                                        for phase in ('after-close-retained', 'after-close-released')]
        require([(point['cycle'], point['phase']) for point in points] == expected, 'all 17 ordered checkpoints required')
        previous_end = -1
        for point in points:
            def check_point():
                nonlocal previous_end
                start, end = integer(point['startUs'], 'checkpoint start'), integer(point['endUs'], 'checkpoint end')
                vm_start, vm_end = integer(point['vmStartUs'], 'VM start'), integer(point['vmEndUs'], 'VM end')
                before, after = point['osBefore'], point['osAfter']
                require(previous_end <= start <= before['timeUs'] <= before['statusEndUs'] <= before['smapsTimeUs']
                        <= before['smapsEndUs'] <= vm_start <= vm_end <= after['timeUs'] <= after['statusEndUs']
                        <= after['smapsTimeUs'] <= after['smapsEndUs'] <= end,
                        'OS/GC/VM non-atomic bracket order invalid')
                previous_end = end
                require(point['atomic'] is False, 'OS/VM measurements cannot be atomic')
                for name, sample, suffix in (('before', before, 'before-gc'), ('after', after, 'after-gc')):
                    require(self.os_selected.get(sample['sequence']) == sample, f'{name} OS sample not identical to raw journal')
                    require(sample['phase'] == f'{point["phase"]}.{suffix}', 'OS checkpoint phase differs')
                retained = point['phase'] == 'after-close-retained'
                require(point['wrapperLatestRetained'] is retained, 'wrapper latest retained/released state differs')
                require(point['nativeCounters'] == {'status': 'not-exposed-by-counter-disabled-native-library', 'values': None},
                        'native counters unavailable; missing data must not become fake zero')
                vm = point['vm']
                require(vm['gc'] == 'requested-all-isolate-groups' and vm.get('heapUnavailable') is None
                        and vm['heapMeasurementMethod'] == HEAP_METHOD, 'actual GC/isolate-group heap observation missing')
                for field in VM_FIELDS:
                    integer(vm[field], field, 1 if field in ('rssBytes', 'maxRssBytes', 'heapUsedBytes',
                                                           'heapCapacityBytes', 'sampledIsolates', 'sampledIsolateGroups') else 0)
                disagreement = process_info_disagreement(vm, point, self.report['runtime'])
                if disagreement:
                    self.rss_sampling_warnings.append(disagreement)
                    self.warnings.append(f'Cycle {point["cycle"]} {point["phase"]}: non-atomic ProcessInfo RSS exceeds separately reported HWM by {disagreement["rssMinusReportedMaxBytes"]} bytes; raw values retained.')
                require(vm['sampledIsolateGroups'] <= vm['sampledIsolates'], 'more isolate groups than isolates')
                counts = point['recorder']
                for name in ('frames', 'frameReceipts', *RETAINED_KEYS.values(), 'receivedFrames', 'persistedFrames',
                             'receivedBatches', 'chunkDescriptors', 'boundaryDescriptors'):
                    integer(counts[name], f'recorder {name}')
                require(counts['frames'] == counts['frameReceipts'] == counts['receivedFrames'] - counts['persistedFrames'],
                        'checkpoint frame retention accounting differs')
                completed_chunks = [chunk for chunk in self.report['raw']['frameChunks'] if chunk['verifiedUs'] <= end]
                require(counts['chunkDescriptors'] == len(completed_chunks)
                        and counts['persistedFrames'] == sum(chunk['frameCount'] for chunk in completed_chunks),
                        'checkpoint persisted frame/chunk totals disagree with raw journal')
                require(counts['receivedFrames'] <= self.report['raw']['finalCounts']['receivedFrames'],
                        'checkpoint receives more frames than the final report')
                for kind, key in RETAINED_KEYS.items():
                    require(counts['receivedRecords'][kind] == counts['persistedRecords'][kind] + counts[key],
                            f'checkpoint {kind} retention accounting differs')
                    require(counts['persistedRecords'][kind] == sum(chunk['recordCounts'][kind] for chunk in completed_chunks),
                            f'checkpoint persisted {kind} total disagrees with raw journal')
                if point['cycle'] >= 0:
                    bounds = self.cycle_bounds.get(point['cycle'])
                    if bounds:
                        require(bounds[0]['timeUs'] <= start <= end <= bounds[1]['timeUs'], 'checkpoint outside cycle')
                    matching = [b for b in self.boundaries if b['cycle'] == point['cycle'] and b['phase'] ==
                                ('retained-point' if retained else 'released-point')]
                    require(len(matching) == 1 and matching[0]['timeUs'] <= start, 'checkpoint boundary missing')
            self.guard(f'checkpoint {point["cycle"]}/{point["phase"]}', check_point)

    def attribute_windows(self):
        """Second streaming pass, after the first pass has recovered all windows."""
        windows = sorted(self.records['window'], key=lambda row: row['startUs'])
        starts = [row['startUs'] for row in windows]
        counts, late, unmatched = Counter(), Counter(), 0
        for descriptor in self.report.get('raw', {}).get('frameChunks', []):
            path = self.root / descriptor['file']
            if descriptor['file'] not in self.files or not path.is_file() or path.is_symlink():
                continue
            with path.open('rb') as stream:
                for line in stream:
                    row = json.loads(line)
                    if row.get('type') != 'frame':
                        continue
                    time = row['timestampsUs']['vsyncStart']
                    index = bisect_right(starts, time) - 1
                    if index >= 0 and time < windows[index]['endUs']:
                        counts[index] += 1
                        if row['receivedUs'] >= windows[index]['endUs']:
                            late[index] += 1
                    else:
                        unmatched += 1
        return {'windows': [{'cycle': window['cycle'], 'id': window['id'],
                              'startUs': window['startUs'], 'endUs': window['endUs'],
                              'receivedFrameCount': counts[index], 'receivedAfterWindowEnd': late[index]}
                             for index, window in enumerate(windows)], 'outsideWindows': unmatched,
                'zeroFrameWindowsAreNotProofOfMissingCallbacks': True}

    def run(self):
        for name, method in (('report', self.validate_header), ('provenance', self.validate_provenance),
                             ('boundaries', self.validate_boundaries), ('cycles', self.validate_cycles),
                             ('frames', self.validate_frames), ('records', self.validate_records),
                             ('OS samples', self.validate_os), ('checkpoints', self.validate_points)):
            self.guard(name, method)
        extra = self.guard('raw inventory', lambda: sorted(path.name for path in self.root.glob('*.jsonl')
                                                          if path.name not in self.files))
        if extra:
            self.errors.append(f'Unreferenced raw JSONL files: {extra}')
        windows = self.guard('window attribution', self.attribute_windows)
        points = self.guard('point summary', lambda: summarize_points(self.report.get('memoryPoints', [])))
        if self.duplicate_count:
            self.warnings.append('Repeated engine frameNumber values were retained; received sequence is the record identity.')
        return {'schema': 'abc.computer-memory-validation.v1',
                'status': 'validated-bounded-observation' if not self.errors else 'failed',
                'evidenceValid': not self.errors, 'plateauEstablished': False,
                'reportedStatus': self.report.get('status'), 'reportedFailure': self.report.get('failure'),
                'reportedFailureStack': self.report.get('failureStack'),
                'expectedCommit': self.expected_commit, 'hostPid': self.report.get('hostPid'),
                'cancelledImportNativeOutcome': (self.report['cycles'][0].get('cancelledImportNativeOutcome')
                                                if self.report.get('cycles') else None),
                'errors': self.errors, 'warnings': self.warnings, 'measurements': points,
                'rssSamplingDisagreements': self.rss_sampling_warnings,
                'raw': {'verifiedOrInspectedFiles': self.files, 'receivedFrameCount': self.frame_count,
                        'uniqueEngineFrameNumbers': len(self.engine_frames),
                        'duplicateEngineFrameRecords': self.duplicate_count,
                        'duplicateFrameNumberExamples': dict(self.duplicate_numbers),
                        'duplicateExamplesTruncated': self.duplicate_count > sum(self.duplicate_numbers.values()),
                        'frameCycleAttribution': dict(self.frame_classification),
                        'lateReceivedFramesByBoundary': dict(self.late_boundaries),
                        'windowAttribution': windows, 'osSamples': self.os_count,
                        'periodicOsSamples': self.os_periodic, 'smapsSamples': self.os_smaps,
                        'osSampleMaxima': self.os_maxima,
                        'recordCounts': {kind: len(rows) for kind, rows in self.records.items()},
                        'productionKeyReleaseDispatchesByCycle': dict(Counter(
                            str(row.get('cycle')) for row in self.records['dispatch']
                            if row.get('action') == 'worldCircuitReleaseKeys')),
                        'allReceivedRecordsReconciled': not self.errors,
                        'engineUnemittedTimingCompleteness': 'unknown'},
                'limits': [
                    'Eight logical cycles, OFF/ON four each, are a bounded observation, not proof of leak freedom or a plateau.',
                    'Strictly increasing sampled windows are reported as continued growth. Other shapes remain inconclusive.',
                    'Raw sequence and hash reconciliation covers callbacks received by recordingStoppedUs only.',
                    'Duplicate engine frame numbers are retained. They neither establish missing callbacks nor increase independent sample count.',
                    'OS and GC/VM samples are bracketed sequential reads, not atomic or additive memory buckets.',
                    'Native allocator and graphics ownership remain unattributed; native counters are unavailable, not zero.',
                    'Reported slopes and pair differences are descriptive, without a causal attribution or absolute MB leak threshold.',
                ]}


def validate(report, raw_directory, build, expected_commit, build_sha256):
    return Validator(report, raw_directory, build, expected_commit, build_sha256).run()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--raw-directory', required=True, type=Path)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    options = parser.parse_args(argv)
    try:
        result = validate(load_json(options.report), options.raw_directory, load_json(options.build),
                          options.expected_commit, digest(options.build))
        result['inputs'] = {'report': options.report.name, 'reportSha256': digest(options.report),
                            'build': options.build.name, 'buildSha256': digest(options.build)}
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, OverflowError) as error:
        result = {'schema': 'abc.computer-memory-validation.v1', 'status': 'failed',
                  'evidenceValid': False, 'plateauEstablished': False, 'errors': [str(error)]}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(f'{result["status"]}: {len(result.get("errors", []))} validation error(s); {options.output}')
    return 0 if result['evidenceValid'] else 1


if __name__ == '__main__':
    sys.exit(main())
