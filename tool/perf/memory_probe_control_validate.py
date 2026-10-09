#!/usr/bin/env python3
"""Validate separate measurement controls, never original acceptance evidence.

Raw frame hashing, received-frame sequence reconciliation, window attribution,
and product action checks reuse the original public validator unchanged. The
new schema deliberately cannot pass as the original eight-cycle diagnostic.
Python OS timestamps and Dart Timeline timestamps remain separate clocks.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

import computer_memory_validate as original
from computer_memory_validate import digest, integer, load_json, require, sha

BASE_COMMIT = '51bc8eaa76b145b0d9bec3c95977779af43b676c'
SCHEDULE_SHA256 = 'bedae8b1416f4124160c4e75323436e3b04df4fc1b709c89a04a34070087657a'
ARMS = ('probe-only', 'product-os-only')
SCHEMA = 'abc.memory-probe-control-validation.v1'
PYTHON_CLOCK = 'python.time.monotonic_ns'
DART_CLOCK = 'dart:developer.Timeline.now'
CONTROL_SOURCES = {
    'integration_test/computer_memory_probe_control_test.dart',
    'integration_test/support/computer_memory_probe_telemetry.dart',
    'tool/perf/memory_probe_control_manifest.json',
    'tool/perf/memory_probe_control_schedule.json',
    'tool/perf/memory_probe_control_os.py',
    'tool/perf/memory_probe_control_validate.py',
}
POINT_KEYS = [(-1, 'baseline')] + [(cycle, phase) for cycle in range(8)
             for phase in ('after-close-retained', 'after-close-released')]
REQUEST_FIELDS = ('kind', 'sequence', 'hostPid', 'phase', 'cycle', 'dartTimeUs')


def endpoint_plan():
    result = [(-1, 'hello', 'hello'), (-1, 'baseline.pre', 'point'),
              (-1, 'baseline.post', 'point'), (-1, 'pre-next-work', 'point')]
    for cycle in range(8):
        result.extend((cycle, phase, 'point') for phase in (
            'retained-quiet.start', 'retained-quiet.end',
            'after-close-retained.pre', 'after-close-retained.post',
            'released-quiet.start', 'released-quiet.end',
            'after-close-released.pre', 'after-close-released.post', 'pre-next-work'))
    result.extend([(8, 'final-quiet.start', 'point'), (8, 'final-quiet.end', 'point'),
                   (8, 'recording-stopped', 'finish')])
    return result


def scheduled_waits(schedule, arm):
    boundary = {(row['cycle'], row['phase']): row['offsetUs']
                for row in schedule['boundaries'] if row['phase'] in ('cycle-start', 'cycle-disposed')}
    result = [(-1, 'baseline', schedule['points'][0]['startOffsetUs'])]
    for cycle in range(8):
        result.append((cycle, 'cycle-start', boundary[cycle, 'cycle-start']))
        if arm == 'probe-only':
            result.append((cycle, 'idle-workload-slot-end', boundary[cycle, 'cycle-disposed']))
        result.extend((point['cycle'], point['phase'], point['startOffsetUs'])
                      for point in schedule['points'] if point['cycle'] == cycle)
    return result


def metrics(row):
    return {name: row.get(name) for name in original.OS_FIELDS}


class ControlValidator(original.Validator):
    def __init__(self, report, raw_directory, build, expected_commit, build_sha256,
                 external, external_directory, schedule=None):
        super().__init__(report, raw_directory, build, expected_commit, build_sha256)
        self.arm = report.get('arm')
        self.external = external
        self.external_root = Path(external_directory)
        self.schedule = schedule if schedule is not None else load_json(
            Path(__file__).with_name('memory_probe_control_schedule.json'))
        self.external_summary = None

    def validate_header(self):
        report = self.report
        require(report['schema'] == 'abc.memory-probe-control.v1', 'unknown control report schema')
        require(report['status'] == 'observed' and report.get('failure') is None
                and report.get('failureStack') is None, 'failed or partial control run cannot pass')
        require(self.arm in ARMS, 'exactly one named control arm required')
        require(report['baseProductCommit'] == BASE_COMMIT, 'control product base differs')
        require(self.expected_commit != BASE_COMMIT, 'a clean derived diagnostic commit is required')
        integer(report['hostPid'], 'host PID', 1)
        require(report['buildMode'] == 'profile', 'real profile build required')
        require(report['inputFormat'] == ('none' if self.arm == 'probe-only' else 'wld-only'),
                'arm input contract differs')
        require(report['plannedCycles'] == report['completedCycles'] == 8,
                'exactly eight complete control cycles required')
        require(report['plannedCheckpoints'] == len(report['memoryPoints']) == 17,
                'exactly 17 control checkpoints required')
        require(report['vmProbeCalls'] == (17 if self.arm == 'probe-only' else 0),
                'VM probe invocation count differs from control arm')
        require(report['expectedNativeWorkers'] == (0 if self.arm == 'probe-only' else 1),
                'native worker topology declaration differs')
        require(report['inProcessOsSamplerRetained'] is True and report['externalOsSamplerEnabled'] is True,
                'both original in-process and external OS samplers must be retained')
        require(self.root.is_dir() and report['raw']['directory'] == self.root.name,
                'raw directory missing or belongs to another run')
        require(report['drainPolicy'] == self.schedule['drainPolicy'], 'fixed drain policy differs')
        require(report['scheduleSha256'] == SCHEDULE_SHA256, 'report schedule hash is not the pinned schedule')
        require(self.schedule['schema'] == 'abc.memory-probe-control-schedule.v1'
                and self.schedule['source']['commit'] == BASE_COMMIT,
                'invalid reference schedule')
        integer(report['scheduleOriginUs'], 'Dart schedule origin', 1)

    def validate_provenance(self):
        super().validate_provenance()
        files = self.build['sourceFilesSha256']
        require(CONTROL_SOURCES <= set(files), 'control source hashes missing from build provenance')
        require(files['tool/perf/memory_probe_control_schedule.json'] == SCHEDULE_SHA256,
                'build did not use the pinned control schedule')
        schedule_path = Path(__file__).with_name('memory_probe_control_schedule.json')
        require(digest(schedule_path) == SCHEDULE_SHA256,
                'validator reference schedule bytes differ from pinned source')
        manifest_path = Path(__file__).with_name('memory_probe_control_manifest.json')
        manifest = load_json(manifest_path)
        require(files['tool/perf/memory_probe_control_manifest.json'] == digest(manifest_path),
                'build/control manifest hash differs')
        require(manifest['baseCommit'] == BASE_COMMIT and manifest['productChangeAllowed'] is False
                and manifest['scheduleSha256'] == SCHEDULE_SHA256 and manifest['arms'] == list(ARMS),
                'control manifest contract differs')

    def validate_boundaries(self):
        if self.arm == 'product-os-only':
            super().validate_boundaries()
            return
        require(self.arm == 'probe-only', 'unknown control arm')
        require(isinstance(self.boundaries, list) and self.boundaries, 'missing reception boundaries')
        expected = [(cycle, phase) for cycle in range(8) for phase in (
            'cycle-start', 'cycle-disposed', 'drain-start', 'drain-end', 'retained-point',
            'released-prefix', 'drain-start', 'drain-end', 'released-point', 'cycle-end')]
        expected.extend([(8, 'drain-start'), (8, 'drain-end')])
        require([(row['cycle'], row['phase']) for row in self.boundaries] == expected,
                'probe-only boundary order differs or product operation boundary present')
        previous = (-1, -1, -1)
        drain_start = None
        final = self.report['raw']['finalCounts']
        for row in self.boundaries:
            values = tuple(integer(row[key], key) for key in ('timeUs', 'receivedFrames', 'receivedBatches'))
            require(all(a <= b for a, b in zip(previous, values)), 'boundary clock or counters moved backwards')
            require(values[1] <= final['receivedFrames'] and values[2] <= final['receivedBatches'],
                    'boundary counts exceed final totals')
            previous = values
            if row['phase'] == 'drain-start':
                require(drain_start is None, 'overlapping quiet drains')
                drain_start = row['timeUs']
            elif row['phase'] == 'drain-end':
                require(drain_start is not None and row['timeUs'] - drain_start >= 1_200_000,
                        'drain shorter than declared real quiet interval')
                drain_start = None
        require(drain_start is None, 'unfinished quiet drain')
        require(integer(self.report['raw']['recordingStoppedUs'], 'recording stop') >= previous[0],
                'recording stopped before final quiet boundary')
        for cycle in range(8):
            rows = [row for row in self.boundaries if row['cycle'] == cycle]
            self.cycle_bounds[cycle] = (rows[0], rows[-1])

    def validate_cycle(self, row, cycle):
        if self.arm == 'product-os-only':
            super().validate_cycle(row, cycle)
            return
        require(self.arm == 'probe-only', 'unknown control arm')
        require(set(row) <= {'cycle', 'mode', 'scenario', 'status', 'productOperations', 'events'},
                'probe-only cycle contains product operation evidence')
        require(row['cycle'] == cycle and row['mode'] == ('optimized' if cycle % 2 else 'standard'),
                'probe-only cycle identity differs')
        require(row['scenario'] == 'no-world-no-edit' and row['status'] == 'completed'
                and integer(row['productOperations'], 'product operations') == 0,
                'probe-only arm performed product work or did not complete')
        require(row.get('events', []) == [], 'probe-only arm contains native lifecycle events')

    def validate_records(self):
        if self.arm == 'product-os-only':
            super().validate_records()
        else:
            require(self.arm == 'probe-only', 'unknown control arm')
            require(all(not rows for rows in self.records.values()),
                    'probe-only arm recorded product actions, viewport evidence or failures')

    def validate_os(self):
        report = self.report['raw']['os']
        require(report['hostPid'] == self.report['hostPid'], 'in-process OS PID differs')
        require(report.get('error') is None, 'in-process sampler failed or is incomplete')
        require(len(report['files']) == 9, 'nine in-process OS rotations required')
        for index, descriptor in enumerate(report['files']):
            def check_file():
                count = 0
                def consume(row, line):
                    nonlocal count
                    count += 1
                    self.validate_os_row(row)
                self.scan_file(descriptor, consume)
                require(count == descriptor['sampleCount'], 'OS raw file sample count differs')
            self.guard(f'in-process OS file {index}', check_file)
        require(self.os_count == report['sampleCount'] > 0, 'OS raw total sample count differs')
        require(self.os_periodic > 0 and self.os_smaps >= 34, 'missing periodic or checkpoint OS samples')
        expected = Counter({'baseline.before-slot': 1, 'baseline.after-slot': 1,
                            'after-close-retained.before-slot': 8, 'after-close-retained.after-slot': 8,
                            'after-close-released.before-slot': 8, 'after-close-released.after-slot': 8,
                            'recording-stopped': 1})
        for cycle in range(8):
            expected[f'cycle-{cycle}.end'] += 1
            if self.arm == 'product-os-only':
                phases = ['initial-import-start', 'initial-import-ready']
                phases += (['reset-original-start', 'reset-original-ready'] if cycle // 2 % 2 == 0 else
                           ['export-close', 'saved-reopen-start', 'saved-reopen-ready'])
                if cycle == 0:
                    phases += ['cancelled-import-start', 'cancelled-import-end']
                expected.update(f'cycle-{cycle}.{phase}' for phase in phases)
        require(Counter({key: value for key, value in self.os_phases.items() if key != 'periodic'}) == expected,
                'in-process OS boundary samples missing, duplicated or wrong arm')

    def validate_schedule(self):
        points = self.report['memoryPoints']
        require([(point['cycle'], point['phase']) for point in points] == POINT_KEYS,
                'all 17 ordered checkpoints required')
        require(len(self.schedule['points']) == 17, 'reference schedule checkpoint count differs')
        for point, planned in zip(points, self.schedule['points']):
            require(point['planned'] == planned, 'checkpoint planned offsets differ from pinned schedule')
            require(point['startUs'] - self.report['scheduleOriginUs'] >= planned['startOffsetUs'],
                    'checkpoint compressed or started before its fixed slot')
        expected = scheduled_waits(self.schedule, self.arm)
        observations = self.report['scheduleObservations']
        require([(row['cycle'], row['phase'], row['plannedOffsetUs']) for row in observations] == expected,
                'schedule waits missing, duplicated, reordered or changed')
        previous = -1
        for row in observations:
            actual = integer(row['actualOffsetUs'], 'actual schedule offset')
            late = integer(row['lateUs'], 'schedule lateness')
            require(actual >= previous and actual >= row['plannedOffsetUs'], 'schedule wait compressed or reordered')
            # Dart reads Timeline.now separately for actualOffsetUs and lateUs.
            require(late >= actual - row['plannedOffsetUs'], 'reported schedule lateness hides observed delay')
            previous = actual
            phase = row['phase']
            if phase in ('cycle-start', 'idle-workload-slot-end'):
                boundary_phase = 'cycle-start' if phase == 'cycle-start' else 'cycle-disposed'
                matches = [b for b in self.boundaries if b['cycle'] == row['cycle'] and b['phase'] == boundary_phase]
                require(len(matches) == 1 and matches[0]['timeUs'] >= self.report['scheduleOriginUs'] + actual,
                        'schedule observation follows its corresponding boundary')
            else:
                point = next(p for p in points if p['cycle'] == row['cycle'] and p['phase'] == phase)
                require(point['startUs'] >= self.report['scheduleOriginUs'] + actual,
                        'schedule observation follows checkpoint start')

    def validate_probe(self, point):
        if self.arm == 'product-os-only':
            require(point['vmProbeInvoked'] is False and point['vm'] is None and point['probeTelemetry'] is None,
                    'product-os-only VM/probe fields must be null with zero VM invocations, never fake zero')
            planned = point['planned']
            require(point['slotEndUs'] - point['slotStartUs'] >= planned['vmEndOffsetUs'] - planned['vmStartOffsetUs'],
                    'product-os-only nominal VM slot was compressed')
            return
        require(self.arm == 'probe-only' and point['vmProbeInvoked'] is True, 'probe-only VM invocation missing')
        vm, telemetry = point['vm'], point['probeTelemetry']
        require(vm['gc'] == 'requested-all-isolate-groups' and vm.get('heapUnavailable') is None
                and vm['heapMeasurementMethod'] == original.HEAP_METHOD,
                'actual GC-requested isolate-group memory observation missing')
        for name in original.VM_FIELDS:
            integer(vm[name], name, 1 if name in ('rssBytes', 'maxRssBytes', 'heapUsedBytes', 'heapCapacityBytes',
                                                'sampledIsolates', 'sampledIsolateGroups') else 0)
        require(vm['heapUsedBytes'] <= vm['heapCapacityBytes'] and vm['rssBytes'] <= vm['maxRssBytes'],
                'VM heap capacity or RSS high-water bound invalid')
        require(vm['sampledIsolateGroups'] <= vm['sampledIsolates'], 'more isolate groups than isolates')
        start = integer(telemetry['measurementStartUs'], 'probe start')
        end = integer(telemetry['measurementEndUs'], 'probe end')
        require(point['slotStartUs'] <= start <= end <= point['slotEndUs'], 'probe telemetry outside measured slot')
        messages = integer(telemetry['responseMessages'], 'VM response count', 1)
        wire = integer(telemetry['responseWireUtf8Bytes'], 'VM response bytes', 1)
        largest = integer(telemetry['largestResponseWireUtf8Bytes'], 'largest VM response bytes', 1)
        require(largest <= wire and messages <= wire, 'VM response byte totals inconsistent')
        require(telemetry['responseScope'] == 'all VM-service responses during this checkpoint'
                and telemetry['retainedResponseBodies'] == 0,
                'response payload retention or measurement scope differs')
        require(telemetry['gcGuarantee'] == 'request-only; dateLastServiceGC is recorded when available',
                'requested GC must not be described as guaranteed collection')
        profiles = telemetry['allocationProfiles']
        require(isinstance(profiles, list) and len(profiles) >= vm['sampledIsolateGroups']
                and messages >= len(profiles), 'allocation-profile response telemetry missing')
        previous = start
        allowed = {'startUs', 'endUs', 'gcRequested', 'classCount', 'dateLastServiceGC',
                   'profileReportedHeapUsage', 'profileReportedHeapCapacity', 'profileReportedExternalUsage'}
        for profile in profiles:
            require(set(profile) == allowed, 'allocation-profile telemetry must contain scalar metadata only')
            a, b = integer(profile['startUs'], 'allocation profile start'), integer(profile['endUs'], 'allocation profile end')
            require(previous <= a <= b <= end, 'allocation profile timestamps overlap or leave probe interval')
            previous = b
            require(profile['gcRequested'] is True, 'allocation profile did not request GC')
            integer(profile['classCount'], 'allocation profile class count', 1)
            for field in allowed - {'startUs', 'endUs', 'gcRequested', 'classCount'}:
                if profile[field] is not None:
                    integer(profile[field], field)

    def validate_points(self):
        previous = -1
        for point in self.report['memoryPoints']:
            def check():
                nonlocal previous
                start, end = integer(point['startUs'], 'checkpoint start'), integer(point['endUs'], 'checkpoint end')
                slot_start, slot_end = integer(point['slotStartUs'], 'slot start'), integer(point['slotEndUs'], 'slot end')
                before, after = point['osBefore'], point['osAfter']
                require(previous <= start <= before['timeUs'] <= before['statusEndUs'] <= before['smapsTimeUs']
                        <= before['smapsEndUs'] <= slot_start <= slot_end <= after['timeUs'] <= after['statusEndUs']
                        <= after['smapsTimeUs'] <= after['smapsEndUs'] <= end,
                        'OS/probe non-atomic bracket order invalid')
                previous = end
                require(point['atomic'] is False, 'sequential observations cannot be atomic')
                for name, sample, suffix in (('before', before, 'before-slot'), ('after', after, 'after-slot')):
                    require(self.os_selected.get(sample['sequence']) == sample,
                            f'{name} in-process OS sample differs from raw journal')
                    require(sample['phase'] == f'{point["phase"]}.{suffix}', 'OS checkpoint phase differs')
                retained = point['phase'] == 'after-close-retained'
                require(point['wrapperLatestRetained'] is (retained and self.arm == 'product-os-only'),
                        'wrapper retention differs from arm and checkpoint')
                self.validate_probe(point)
                self.validate_retained_counts(point)
                if point['cycle'] >= 0:
                    bounds = self.cycle_bounds.get(point['cycle'])
                    require(bounds is not None and bounds[0]['timeUs'] <= start <= end <= bounds[1]['timeUs'],
                            'checkpoint outside cycle')
                    matching = [b for b in self.boundaries if b['cycle'] == point['cycle'] and b['phase'] ==
                                ('retained-point' if retained else 'released-point')]
                    require(len(matching) == 1 and matching[0]['timeUs'] <= start, 'checkpoint boundary missing')
                for key, suffix in (('externalBefore', 'pre'), ('externalAfter', 'post')):
                    endpoint = point[key]
                    require(endpoint in self.report['externalEndpoints'], 'checkpoint endpoint absent from protocol')
                    require(endpoint['phase'] == f'{point["phase"]}.{suffix}' and endpoint['cycle'] == point['cycle'],
                            'checkpoint external endpoint belongs to a different stage')
                    require(start <= endpoint['dartTimeUs'] <= endpoint['acknowledgedDartTimeUs'] <= end,
                            'checkpoint external endpoint leaves Dart checkpoint bracket')
                require(point['externalBefore']['acknowledgedDartTimeUs'] <= before['timeUs']
                        and after['smapsEndUs'] <= point['externalAfter']['dartTimeUs'],
                        'external endpoint and in-process checkpoint order differs')
            self.guard(f'checkpoint {point.get("cycle")}/{point.get("phase")}', check)

    def validate_retained_counts(self, point):
        counts = point['recorder']
        for name in ('frames', 'frameReceipts', *original.RETAINED_KEYS.values(), 'receivedFrames',
                     'persistedFrames', 'receivedBatches', 'chunkDescriptors', 'boundaryDescriptors'):
            integer(counts[name], f'recorder {name}')
        require(counts['frames'] == counts['frameReceipts'] == counts['receivedFrames'] - counts['persistedFrames'],
                'checkpoint frame retention accounting differs')
        chunks = [chunk for chunk in self.report['raw']['frameChunks'] if chunk['verifiedUs'] <= point['endUs']]
        require(counts['chunkDescriptors'] == len(chunks)
                and counts['persistedFrames'] == sum(chunk['frameCount'] for chunk in chunks),
                'checkpoint persisted frame/chunk totals disagree with journal')
        require(counts['receivedFrames'] <= self.report['raw']['finalCounts']['receivedFrames']
                and counts['receivedBatches'] <= self.report['raw']['finalCounts']['receivedBatches'],
                'checkpoint reception exceeds final totals')
        require(counts['boundaryDescriptors'] == sum(b['timeUs'] <= point['endUs'] for b in self.boundaries),
                'checkpoint boundary count differs')
        for kind, key in original.RETAINED_KEYS.items():
            received = integer(counts['receivedRecords'][kind], f'received {kind}')
            persisted = integer(counts['persistedRecords'][kind], f'persisted {kind}')
            require(received == persisted + counts[key], f'checkpoint {kind} retention accounting differs')
            require(persisted == sum(chunk['recordCounts'][kind] for chunk in chunks),
                    f'checkpoint persisted {kind} total disagrees with journal')

    def validate_external(self):
        """Stream one owned PID; only small acknowledged endpoint rows are kept."""
        manifest, endpoints = self.external, self.report['externalEndpoints']
        require(manifest['schema'] == 'abc.memory-probe-control-os-manifest.v1', 'unknown external OS schema')
        require(manifest['status'] == 'completed' and manifest['complete'] is True
                and manifest.get('failure') is None, 'external failure or partial sampler cannot pass')
        require(manifest['arm'] == self.arm and manifest['baseProductCommit'] == BASE_COMMIT
                and manifest['processInvocations'] == 1 and manifest['ownedProcess'] is True
                and manifest['endpointRequests'] == 79, 'external owned-process control descriptor differs')
        require(self.report['externalOs'] == manifest, 'report/external sampler manifests differ')
        require(manifest['clockDomain'] == PYTHON_CLOCK and manifest['timeUnit'] == 'nanoseconds'
                and manifest['crossClockSubtractionAllowed'] is False, 'external clock domains not explicit')
        require(manifest['targetStatusIntervalNs'] == 10_000_000
                and manifest['targetSmapsIntervalNs'] == 100_000_000, 'external target cadence differs')
        require(manifest['integrityScope'] == 'successfully-flushed-rows', 'external integrity scope differs')
        identity = manifest['processIdentity']
        require(identity['pid'] == self.report['hostPid'], 'external sampler selected another PID')
        for key in ('pid', 'processGroupId', 'starttimeTicks', 'groupLeaderStarttimeTicks',
                    'runnerPid', 'runnerStarttimeTicks'):
            integer(identity[key], f'external process {key}', 1)
        integer(identity['uid'], 'external process UID')
        require(identity['pid'] != identity['runnerPid'] and identity['processGroupId'] != identity['runnerPid'],
                'external sampler is not a distinct runner-owned process group')
        require(len(endpoints) == 79 and [(p['cycle'], p['phase'], p['kind']) for p in endpoints] == endpoint_plan(),
                'all 79 ordered external protocol endpoints required')
        wanted, previous_ack = {}, -1
        for sequence, endpoint in enumerate(endpoints):
            require(endpoint['sequence'] == sequence and endpoint['hostPid'] == identity['pid'],
                    'external request sequence or PID differs')
            at = integer(endpoint['dartTimeUs'], 'endpoint Dart request time')
            ack = integer(endpoint['acknowledgedDartTimeUs'], 'endpoint Dart acknowledgement time')
            require(previous_ack <= at <= ack, 'external endpoint Dart request/acknowledgement order invalid')
            previous_ack = ack
            sample_sequence = integer(endpoint['os']['sequence'], 'external raw sample sequence')
            require(sample_sequence not in wanted, 'external endpoints reuse one OS raw sample')
            wanted[sample_sequence] = endpoint
        name = manifest['file']
        require(isinstance(name, str) and Path(name).name == name and name.endswith('.jsonl'),
                'unsafe external raw filename')
        path = self.external_root / name
        require(path.is_file() and not path.is_symlink(), 'external raw file missing or symbolic link')
        require(path.resolve() not in {(self.root / file).resolve() for file in self.files},
                'external and in-process raw files cannot be the same')
        hasher, byte_count, count, smaps_count, periodic = hashlib.sha256(), 0, 0, 0, 0
        previous_end = previous_start = first = None
        maximum_gap = 0
        seen = set()
        with path.open('rb') as stream:
            for line in stream:
                require(line.endswith(b'\n'), 'external raw JSONL line incomplete')
                hasher.update(line)
                byte_count += len(line)
                row = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                require(isinstance(row, dict), 'external raw object required')
                require(row['schema'] == 'abc.memory-probe-control-os.v1' and row['type'] == 'os'
                        and integer(row['sequence'], 'external sequence') == count,
                        'external raw sequence dropped, repeated or reordered')
                require(row['pid'] == identity['pid'] and row['starttimeTicks'] == identity['starttimeTicks'],
                        'external raw identity differs (possible PID reuse)')
                require(row['clockDomain'] == PYTHON_CLOCK and row['timeUnit'] == 'nanoseconds'
                        and row['atomic'] is False, 'external raw clock or atomicity differs')
                at, end = integer(row['timeNs'], 'external time', 1), integer(row['statusEndNs'], 'external status end', 1)
                require(at <= end and (previous_end is None or at >= previous_end),
                        'external OS timestamp order invalid')
                if first is None:
                    first = at
                if previous_start is not None:
                    maximum_gap = max(maximum_gap, at - previous_start)
                previous_start, previous_end = at, end
                for field in original.OS_FIELDS[:2]:
                    integer(row[field], field, 1)
                require(row['rssBytes'] <= row['processVmHwmBytes'], 'external HWM below RSS')
                smaps_fields = ('smapsTimeNs', 'smapsEndNs', *original.OS_FIELDS[2:],
                                'privateCleanBytes', 'privateDirtyBytes', 'privateHugetlbBytes',
                                'ussIncludesPrivateHugetlb')
                if 'smapsTimeNs' in row:
                    a, b = integer(row['smapsTimeNs'], 'external smaps start', 1), integer(row['smapsEndNs'], 'external smaps end', 1)
                    require(end <= a <= b, 'external status/smaps brackets invalid')
                    previous_end = b
                    for field in (*original.OS_FIELDS[2:], 'privateCleanBytes', 'privateDirtyBytes'):
                        integer(row[field], field)
                    huge = row['privateHugetlbBytes']
                    if huge is not None:
                        integer(huge, 'private huge pages')
                    require(row['ussIncludesPrivateHugetlb'] is (huge is not None), 'external huge-page availability differs')
                    require(row['ussBytes'] == row['privateCleanBytes'] + row['privateDirtyBytes'] + (huge or 0),
                            'external USS components differ')
                    smaps_count += 1
                else:
                    require(not any(key in row for key in smaps_fields), 'partially absent external smaps fields')
                    require(row['phase'] == 'periodic', 'named external endpoint lacks smaps observation')
                if count == 0:
                    require(row['phase'] == 'sampler-start' and 'metadata' not in row,
                            'external sampler-start row missing')
                elif row['phase'] == 'periodic':
                    require('metadata' not in row, 'periodic sample has endpoint metadata')
                    periodic += 1
                else:
                    require(count in wanted, 'unacknowledged or unknown external endpoint row')
                    endpoint = wanted[count]
                    require(endpoint['os'] == row, 'external acknowledged OS row differs from raw journal')
                    require(row['phase'] == endpoint['phase']
                            and row['metadata'] == {**{key: endpoint[key] for key in REQUEST_FIELDS},
                                                   'controlArm': self.arm},
                            'external raw metadata differs from Dart request')
                    require(row['metadataClockDomains'] == {'dartTimeUs': DART_CLOCK},
                            'Dart metadata clock must remain distinct from Python sampler clock')
                    seen.add(count)
                count += 1
        require(hasher.hexdigest() == sha(manifest['sha256']) and byte_count == manifest['bytes'],
                'external raw bytes/SHA-256 mismatch')
        require(count == manifest['statusSamples'] and smaps_count == manifest['smapsSamples']
                and len(seen) == manifest['namedPointSamples'] == len(endpoints) and seen == set(wanted),
                'external sample, smaps or acknowledged endpoint totals differ')
        require(periodic > 0 and first == manifest['firstTimeNs'] and previous_start == manifest['lastTimeNs']
                and maximum_gap == manifest['maximumObservedStatusGapNs'],
                'external periodic observations or timing summary differs')
        integer(manifest['missedPeriodicStatusTicks'], 'missed periodic external ticks')
        self.validate_endpoint_boundaries(endpoints)
        self.external_summary = {
            'file': name, 'sha256': manifest['sha256'], 'bytes': byte_count,
            'clockDomain': PYTHON_CLOCK, 'correlationClockDomain': DART_CLOCK,
            'crossClockSubtractionAllowed': False, 'processIdentity': identity,
            'statusSamples': count, 'periodicSamples': periodic, 'smapsSamples': smaps_count,
            'acknowledgedEndpoints': len(seen), 'maximumObservedStatusGapNs': maximum_gap,
            'missedPeriodicStatusTicks': manifest['missedPeriodicStatusTicks'],
            'endpoints': [{'cycle': point['cycle'], 'phase': point['phase'],
                           'sequence': point['sequence'], 'osSequence': point['os']['sequence'],
                           'pythonTimeNs': point['os']['timeNs'], 'dartRequestUs': point['dartTimeUs'],
                           'dartAcknowledgedUs': point['acknowledgedDartTimeUs'],
                           **metrics(point['os'])} for point in endpoints],
        }

    def validate_endpoint_boundaries(self, endpoints):
        lookup = {(p['cycle'], p['phase']): p for p in endpoints}
        require(lookup[-1, 'hello']['acknowledgedDartTimeUs'] <= self.report['scheduleOriginUs'],
                'external hello acknowledgement follows schedule origin')
        for cycle in range(9):
            rows = [row for row in self.boundaries if row['cycle'] == cycle and row['phase'].startswith('drain-')]
            labels = ['retained-quiet', 'released-quiet'] if cycle < 8 else ['final-quiet']
            require(len(rows) == 2 * len(labels), 'quiet boundaries missing for external comparison')
            for index, name in enumerate(labels):
                start, end = lookup[cycle, name + '.start'], lookup[cycle, name + '.end']
                a, b = rows[index * 2:index * 2 + 2]
                require(a['timeUs'] <= start['dartTimeUs'] <= start['acknowledgedDartTimeUs']
                        <= b['timeUs'] <= end['dartTimeUs'] <= end['acknowledgedDartTimeUs'],
                        'external quiet endpoints do not bracket the original quiet phase')
                require(end['dartTimeUs'] - start['acknowledgedDartTimeUs'] >= 1_200_000,
                        'external quiet interval shorter than real quiet policy')
        for cycle in range(-1, 8):
            phase = 'baseline.post' if cycle == -1 else 'after-close-released.post'
            point, next_work = lookup[cycle, phase], lookup[cycle, 'pre-next-work']
            require(point['acknowledgedDartTimeUs'] <= next_work['dartTimeUs'],
                    'pre-next-work endpoint precedes checkpoint completion')
            if cycle < 7:
                require(next_work['acknowledgedDartTimeUs'] <= self.cycle_bounds[cycle + 1][0]['timeUs'],
                        'next cycle started before pre-next-work acknowledgement')
        stopped = lookup[8, 'recording-stopped']
        require(self.report['raw']['recordingStoppedUs'] <= stopped['dartTimeUs'],
                'external recording-stopped endpoint preceded recording stop')

    def summarize(self):
        points = self.report.get('memoryPoints', [])
        baseline = original.point_metrics(points[0]) if points else {}
        observations = []
        for point in points:
            current = original.point_metrics(point)
            observations.append({'cycle': point['cycle'], 'phase': point['phase'], 'metrics': current,
                                 'minusBaseline': original.difference(current, baseline),
                                 'slotDurationUs': point['slotEndUs'] - point['slotStartUs'],
                                 'probeTelemetry': point['probeTelemetry']})
        released = [row for row in observations if row['phase'] == 'after-close-released']
        return {'baseline': baseline, 'points': observations,
                'releasedTrends': {key: original.trend([row['metrics'][key] for row in released],
                                                     [row['cycle'] for row in released]) for key in baseline},
                'scheduleObservations': self.report.get('scheduleObservations', [])}

    def run(self):
        for name, method in (('report', self.validate_header), ('provenance', self.validate_provenance),
                             ('boundaries', self.validate_boundaries), ('cycles', self.validate_cycles),
                             ('frames', self.validate_frames), ('records', self.validate_records),
                             ('in-process OS', self.validate_os), ('schedule', self.validate_schedule),
                             ('checkpoints', self.validate_points), ('external OS', self.validate_external)):
            self.guard(name, method)
        extra = self.guard('raw inventory', lambda: sorted(path.name for path in self.root.glob('*.jsonl')
                                                          if path.name not in self.files))
        if extra:
            self.errors.append(f'Unreferenced in-process raw JSONL files: {extra}')
        windows = self.guard('window attribution', self.attribute_windows)
        measurements = self.guard('control measurements', self.summarize)
        return {
            'schema': SCHEMA, 'status': 'validated-control-observation' if not self.errors else 'failed',
            'evidenceValid': not self.errors, 'acceptanceEvidence': False, 'plateauEstablished': False,
            'causalAttribution': 'unresolved', 'originalGrowthStillUnresolved': True,
            'arm': self.arm, 'expectedCommit': self.expected_commit, 'baseProductCommit': BASE_COMMIT,
            'hostPid': self.report.get('hostPid'), 'reportedStatus': self.report.get('status'),
            'reportedFailure': self.report.get('failure'), 'reportedFailureStack': self.report.get('failureStack'),
            'errors': self.errors, 'warnings': self.warnings, 'measurements': measurements,
            'externalOs': self.external_summary,
            'topology': {'nativeWorkersExpected': self.report.get('expectedNativeWorkers'),
                         'inProcessOsSamplerRetained': self.report.get('inProcessOsSamplerRetained'),
                         'externalOsSamplerEnabled': self.report.get('externalOsSamplerEnabled'),
                         'vmProbeCalls': self.report.get('vmProbeCalls'),
                         'heapFieldsMeasured': self.arm == 'probe-only'},
            'raw': {'verifiedOrInspectedFiles': self.files, 'receivedFrameCount': self.frame_count,
                    'uniqueEngineFrameNumbers': len(self.engine_frames), 'duplicateEngineFrameRecords': self.duplicate_count,
                    'lateReceivedFramesByBoundary': dict(self.late_boundaries),
                    'frameCycleAttribution': dict(self.frame_classification), 'windowAttribution': windows,
                    'inProcessOsSamples': self.os_count, 'inProcessPeriodicSamples': self.os_periodic,
                    'inProcessSmapsSamples': self.os_smaps, 'inProcessOsMaxima': self.os_maxima,
                    'recordCounts': {kind: len(rows) for kind, rows in self.records.items()},
                    'allReceivedRecordsReconciled': not self.errors, 'engineUnemittedTimingCompleteness': 'unknown'},
            'limits': [
                'The original observed growth remains unresolved; these control measurements are separate evidence.',
                'These two interventions differ in product work, VM probing and native-worker topology; they do not isolate every owner.',
                'Both arms retain the original in-process OS sampler and raw journal, and add an external Python sampler.',
                'Heap used, heap capacity and external bytes are measured only in probe-only; unavailable fields remain null.',
                'GC was requested; response decoding allocates in the measured process and collection is not guaranteed.',
                'Only callbacks received before recordingStoppedUs are reconciled; engine-unemitted timings remain unknown.',
                'Python monotonic_ns and Dart Timeline.now have different clock domains; never subtract their timestamps.',
                'RSS, PSS, USS and VM bytes are sequential non-atomic observations, not additive ownership buckets.',
                'No jank/FPS acceptance budget, absolute leak threshold, plateau pass or no-leak conclusion is produced.',
            ],
        }


def validate(report, raw_directory, build, expected_commit, build_sha256, external, external_directory):
    return ControlValidator(report, raw_directory, build, expected_commit, build_sha256,
                            external, external_directory).run()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--raw-directory', required=True, type=Path)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--external-os', required=True, type=Path)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', required=True, type=Path)
    options = parser.parse_args(argv)
    try:
        result = validate(load_json(options.report), options.raw_directory, load_json(options.build),
                          options.expected_commit, digest(options.build), load_json(options.external_os),
                          options.external_os.parent)
        result['inputs'] = {name: {'file': path.name, 'sha256': digest(path)}
                            for name, path in (('report', options.report), ('build', options.build),
                                               ('externalOs', options.external_os))}
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, OverflowError) as error:
        result = {'schema': SCHEMA, 'status': 'failed', 'evidenceValid': False, 'acceptanceEvidence': False,
                  'plateauEstablished': False, 'originalGrowthStillUnresolved': True, 'errors': [str(error)]}
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(f'{result["status"]}: {len(result.get("errors", []))} validation error(s); {options.output}')
    return 0 if result['evidenceValid'] else 1


if __name__ == '__main__':
    sys.exit(main())
