#!/usr/bin/env python3
"""Small synthetic controls and tampering tests; no Flutter or native workload.

Reuse the original tiny JSONL fixture's lifecycle records. These are fabricated
unit-test values and are never control observations or benchmark results.
"""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import computer_memory_checks_test as fixture_source
import memory_probe_control_validate as checks


def write_rows(root, descriptor, rows):
    fixture_source.write_rows(root, descriptor, rows)


def scale_times(value, key=''):
    if isinstance(value, dict):
        return {name: scale_times(item, name) for name, item in value.items()}
    if isinstance(value, list):
        return [scale_times(item, key) for item in value]
    if type(value) is int and (key.endswith('Us') or key in checks.original.FRAME_PHASES):
        return value * 3 // 5
    return value


def fixture(root, arm='probe-only'):
    report, build, _ = fixture_source.fixture(root)
    report = scale_times(report)
    schedule = checks.load_json(Path(checks.__file__).with_name('memory_probe_control_schedule.json'))
    probe_only = arm == 'probe-only'
    report.update({'schema': 'abc.memory-probe-control.v1', 'arm': arm,
                   'baseProductCommit': checks.BASE_COMMIT, 'inputFormat': 'none' if probe_only else 'wld-only',
                   'plannedCheckpoints': 17, 'vmProbeCalls': 17 if probe_only else 0,
                   'expectedNativeWorkers': 0 if probe_only else 1,
                   'inProcessOsSamplerRetained': True, 'externalOsSamplerEnabled': True,
                   'scheduleSha256': checks.SCHEDULE_SHA256,
                   'scheduleOriginUs': report['memoryPoints'][0]['startUs'] - 1000})
    if probe_only:
        report['cycles'] = [{'cycle': cycle, 'mode': 'optimized' if cycle % 2 else 'standard',
                             'scenario': 'no-world-no-edit', 'status': 'completed', 'productOperations': 0}
                            for cycle in range(8)]
        keep = {'cycle-start', 'cycle-disposed', 'drain-start', 'drain-end', 'retained-point',
                'released-prefix', 'released-point', 'cycle-end'}
        report['raw']['boundaries'] = [row for row in report['raw']['boundaries'] if row['phase'] in keep]
    boundaries = report['raw']['boundaries']
    report['raw']['finalCounts']['boundaryDescriptors'] = len(boundaries)

    # Preserve the original 17 raw chunks, frame sequences and late receptions.
    for descriptor in report['raw']['frameChunks']:
        rows = [scale_times(json.loads(line)) for line in (root / descriptor['file']).read_text().splitlines()]
        if probe_only:
            rows = [row for row in rows if row['type'] in ('chunk', 'frame')]
            descriptor['recordCounts'] = dict.fromkeys(checks.original.RECORD_TYPES, 0)
            rows[0]['recordCounts'] = descriptor['recordCounts'].copy()
        write_rows(root, descriptor, rows)
    if probe_only:
        final = report['raw']['finalCounts']
        final['receivedRecords'] = dict.fromkeys(checks.original.RECORD_TYPES, 0)
        final['persistedRecords'] = final['receivedRecords'].copy()

    os_rows = [scale_times(json.loads(line)) for descriptor in report['raw']['os']['files']
               for line in (root / descriptor['file']).read_text().splitlines()]
    original_os = {row['sequence']: row for row in os_rows}
    for point, planned in zip(report['memoryPoints'], schedule['points']):
        point['planned'] = copy.deepcopy(planned)
        point['vmProbeInvoked'] = probe_only
        point['wrapperLatestRetained'] = not probe_only and point['phase'] == 'after-close-retained'
        before = original_os[point['osBefore']['sequence']]
        after = original_os[point['osAfter']['sequence']]
        point['osBefore'], point['osAfter'] = before, after
        point['slotStartUs'] = before['smapsEndUs'] + 100
        point['slotEndUs'] = point['slotStartUs'] + planned['vmEndOffsetUs'] - planned['vmStartOffsetUs'] + 1000
        after['timeUs'] = point['slotEndUs'] + 100
        after['statusEndUs'] = after['timeUs'] + 100
        after['smapsTimeUs'] = after['timeUs'] + 200
        after['smapsEndUs'] = after['timeUs'] + 300
        point['endUs'] = point['startUs'] + 500_000
        counts = point['recorder']
        counts['boundaryDescriptors'] = sum(b['timeUs'] <= point['endUs'] for b in boundaries)
        if probe_only:
            counts['receivedRecords'] = dict.fromkeys(checks.original.RECORD_TYPES, 0)
            counts['persistedRecords'] = counts['receivedRecords'].copy()
            counts.update(dict.fromkeys(checks.original.RETAINED_KEYS.values(), 0))
            start = point['slotStartUs'] + 100
            point['probeTelemetry'] = {
                'measurementStartUs': start, 'measurementEndUs': point['slotEndUs'] - 100,
                'responseMessages': 8, 'responseWireUtf8Bytes': 12345,
                'largestResponseWireUtf8Bytes': 12000,
                'responseScope': 'all VM-service responses during this checkpoint',
                'retainedResponseBodies': 0,
                'gcGuarantee': 'request-only; dateLastServiceGC is recorded when available',
                'allocationProfiles': [{'startUs': start + 1000 * group, 'endUs': start + 1000 * group + 100,
                                        'gcRequested': True, 'classCount': 123,
                                        'dateLastServiceGC': None,
                                        'profileReportedHeapUsage': None,
                                        'profileReportedHeapCapacity': None,
                                        'profileReportedExternalUsage': None} for group in range(2)]}
        else:
            point['vm'] = point['probeTelemetry'] = None
    for row in os_rows:
        row['phase'] = row['phase'].replace('.before-gc', '.before-slot').replace('.after-gc', '.after-slot')
    if probe_only:
        os_rows = [row for row in os_rows if not row['phase'].startswith('cycle-') or row['phase'].endswith('.end')]
    os_rows.sort(key=lambda row: row['timeUs'])
    for sequence, row in enumerate(os_rows):
        row['sequence'] = sequence
    cycle_ends = {b['cycle']: b['timeUs'] for b in boundaries if b['phase'] == 'cycle-end'}
    for index, descriptor in enumerate(report['raw']['os']['files']):
        start = cycle_ends[index - 1] if index else -1
        end = cycle_ends[index] if index < 8 else float('inf')
        rows = [row for row in os_rows if start < row['timeUs'] <= end]
        descriptor['sampleCount'] = len(rows)
        write_rows(root, descriptor, rows)
    report['raw']['os']['sampleCount'] = len(os_rows)

    report['scheduleObservations'] = []
    for cycle, phase, offset in checks.scheduled_waits(schedule, arm):
        if phase in ('cycle-start', 'idle-workload-slot-end'):
            boundary_phase = 'cycle-start' if phase == 'cycle-start' else 'cycle-disposed'
            at = next(b['timeUs'] for b in boundaries if b['cycle'] == cycle and b['phase'] == boundary_phase) - 100
        else:
            at = next(p['startUs'] for p in report['memoryPoints'] if p['cycle'] == cycle and p['phase'] == phase) - 100
        actual = at - report['scheduleOriginUs']
        report['scheduleObservations'].append({'cycle': cycle, 'phase': phase, 'plannedOffsetUs': offset,
                                               'actualOffsetUs': actual, 'lateUs': actual - offset})

    endpoints = []
    point_lookup = {(p['cycle'], p['phase']): p for p in report['memoryPoints']}
    for sequence, (cycle, phase, kind) in enumerate(checks.endpoint_plan()):
        if phase == 'hello':
            at = report['scheduleOriginUs'] - 2000
        elif phase == 'pre-next-work':
            at = point_lookup[cycle, 'baseline' if cycle == -1 else 'after-close-released']['endUs'] + 1000
        elif phase == 'recording-stopped':
            at = report['raw']['recordingStoppedUs'] + 200_000
        elif '-quiet.' in phase:
            index = 2 if phase.startswith('released-') else 0
            index += phase.endswith('.end')
            drains = [b for b in boundaries if b['cycle'] == cycle and b['phase'].startswith('drain-')]
            at = drains[index]['timeUs'] + 1000
        else:
            name, side = phase.rsplit('.', 1)
            point = point_lookup[cycle, name]
            at = point['startUs'] + 1000 if side == 'pre' else point['osAfter']['smapsEndUs'] + 1000
        endpoint = {'kind': kind, 'sequence': sequence, 'hostPid': report['hostPid'], 'phase': phase,
                    'cycle': cycle, 'dartTimeUs': at, 'acknowledgedDartTimeUs': at + 100}
        endpoints.append(endpoint)
        if phase.endswith(('.pre', '.post')):
            name, side = phase.rsplit('.', 1)
            point_lookup[cycle, name]['externalBefore' if side == 'pre' else 'externalAfter'] = endpoint
    report['externalEndpoints'] = endpoints
    identity = {'pid': 123, 'uid': 1000, 'processGroupId': 122, 'starttimeTicks': 777,
                'groupLeaderStarttimeTicks': 700, 'runnerPid': 120, 'runnerStarttimeTicks': 600}
    external_rows = []

    def sample(phase, dart_time, endpoint=None):
        # Deliberately different numerical epoch and unit from Dart timestamps.
        at = 10 ** 15 + dart_time * 1000
        row = {'schema': 'abc.memory-probe-control-os.v1', 'type': 'os', 'sequence': len(external_rows),
               'phase': phase, 'pid': 123, 'starttimeTicks': 777, 'clockDomain': checks.PYTHON_CLOCK,
               'timeUnit': 'nanoseconds', 'timeNs': at, 'statusEndNs': at + 1000, 'atomic': False,
               'rssBytes': 1_000_000, 'processVmHwmBytes': 2_000_000,
               'smapsTimeNs': at + 2000, 'smapsEndNs': at + 3000,
               'smapsRssBytes': 999_000, 'pssBytes': 998_000, 'ussBytes': 997_000,
               'privateCleanBytes': 1000, 'privateDirtyBytes': 996_000,
               'privateHugetlbBytes': None, 'ussIncludesPrivateHugetlb': False}
        if endpoint is not None:
            row['metadata'] = {**{key: endpoint[key] for key in checks.REQUEST_FIELDS}, 'controlArm': arm}
            row['metadataClockDomains'] = {'dartTimeUs': checks.DART_CLOCK}
            endpoint['os'] = row
        external_rows.append(row)

    sample('sampler-start', endpoints[0]['dartTimeUs'] - 20_000)
    sample('periodic', endpoints[0]['dartTimeUs'] - 10_000)
    for endpoint in endpoints:
        sample(endpoint['phase'], endpoint['dartTimeUs'], endpoint)
    external = {'schema': 'abc.memory-probe-control-os-manifest.v1', 'status': 'completed', 'complete': True,
                'failure': None, 'file': 'external-os.jsonl', 'integrityScope': 'successfully-flushed-rows',
                'processIdentity': identity, 'clockDomain': checks.PYTHON_CLOCK, 'timeUnit': 'nanoseconds',
                'crossClockSubtractionAllowed': False, 'targetStatusIntervalNs': 10_000_000,
                'targetSmapsIntervalNs': 100_000_000, 'statusSamples': len(external_rows),
                'smapsSamples': len(external_rows), 'namedPointSamples': 79,
                'firstTimeNs': external_rows[0]['timeNs'], 'lastTimeNs': external_rows[-1]['timeNs'],
                'maximumObservedStatusGapNs': max(b['timeNs'] - a['timeNs'] for a, b in zip(external_rows, external_rows[1:])),
                'missedPeriodicStatusTicks': 0, 'arm': arm, 'baseProductCommit': checks.BASE_COMMIT,
                'processInvocations': 1, 'ownedProcess': True, 'endpointRequests': 79}
    write_rows(root.parent, external, external_rows)
    report['externalOs'] = external
    for name in checks.CONTROL_SOURCES:
        build['sourceFilesSha256'][name] = 'b' * 64
    build['sourceFilesSha256']['tool/perf/memory_probe_control_schedule.json'] = checks.SCHEDULE_SHA256
    build['sourceFilesSha256']['tool/perf/memory_probe_control_manifest.json'] = checks.digest(
        Path(checks.__file__).with_name('memory_probe_control_manifest.json'))
    build['sourceTreeSha256'] = hashlib.sha256(json.dumps(build['sourceFilesSha256'], sort_keys=True,
                                                        separators=(',', ':')).encode()).hexdigest()
    build_sha = hashlib.sha256(fixture_source.encoded(build)).hexdigest()
    report['runtime']['sourceTreeSha256'] = build['sourceTreeSha256']
    report['runtime']['buildProvenanceSha256'] = build_sha
    report['runtime']['controlProvenanceAttachment'] = 'paired-control-runner-after-owned-process'
    return report, build, build_sha, external


class ControlChecksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'probe-only.raw'
        self.report, self.build, self.build_sha, self.external = fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def run_validation(self):
        return checks.validate(self.report, self.root, self.build, fixture_source.COMMIT,
                               self.build_sha, self.external, self.root.parent)

    def assert_failed(self, message):
        result = self.run_validation()
        self.assertFalse(result['evidenceValid'], result)
        self.assertIn(message, '\n'.join(result['errors']))
        self.assertEqual(result['status'], 'failed')
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['plateauEstablished'])
        return result

    def edit_external(self, edit):
        rows = [json.loads(line) for line in (self.root.parent / self.external['file']).read_text().splitlines()]
        edit(rows)
        write_rows(self.root.parent, self.external, rows)

    def edit_chunk(self, index, edit):
        descriptor = self.report['raw']['frameChunks'][index]
        rows = [json.loads(line) for line in (self.root / descriptor['file']).read_text().splitlines()]
        edit(rows)
        write_rows(self.root, descriptor, rows)

    def test_complete_probe_control_is_separate_observation(self):
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['status'], 'validated-control-observation')
        self.assertEqual(result['schema'], checks.SCHEMA)
        self.assertEqual(result['raw']['receivedFrameCount'], 16)
        self.assertEqual(result['externalOs']['acknowledgedEndpoints'], 79)
        self.assertEqual(result['externalOs']['clockDomain'], checks.PYTHON_CLOCK)
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['plateauEstablished'])
        self.assertTrue(result['originalGrowthStillUnresolved'])
        self.assertIn('vm.heapCapacityBytes', result['measurements']['baseline'])
        self.assertIn('vm.externalBytes', result['measurements']['baseline'])

    def test_probe_rss_disagreement_preserves_control_limits(self):
        point = self.report['memoryPoints'][2]
        point['vm']['maxRssBytes'] = point['vm']['rssBytes'] - 806912
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        warning, = result['rssSamplingDisagreements']
        self.assertEqual(warning['rssMinusReportedMaxBytes'], 806912)
        self.assertEqual(warning['samplingWindowUs'], [point['slotStartUs'], point['slotEndUs']])
        self.assertFalse(result['plateauEstablished'])
        self.assertFalse(result['acceptanceEvidence'])
        self.assertTrue(result['originalGrowthStillUnresolved'])

    def test_probe_heap_contradiction_remains_failure(self):
        point = self.report['memoryPoints'][2]
        point['vm']['heapUsedBytes'] = point['vm']['heapCapacityBytes'] + 1
        self.assert_failed('heap capacity bound')

    def test_complete_product_control_reuses_original_action_validation(self):
        self.root = Path(self.temp.name) / 'product-os-only.raw'
        self.report, self.build, self.build_sha, self.external = fixture(self.root, 'product-os-only')
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertIsNone(result['measurements']['baseline']['vm.heapCapacityBytes'])
        self.assertGreater(result['raw']['recordCounts']['dispatch'], 0)
        self.report['cycles'][3]['physicalPulseDelta'] = 4095
        self.assert_failed('real fixed pulse evidence differs')

    def test_original_validator_rejects_control_schema(self):
        result = checks.original.validate(self.report, self.root, self.build, fixture_source.COMMIT, self.build_sha)
        self.assertFalse(result['evidenceValid'])
        self.assertIn('unknown report schema', '\n'.join(result['errors']))

    def test_partial_report_cannot_pass(self):
        self.report['status'] = 'failed'
        self.assert_failed('failed or partial control run')

    def test_missing_checkpoint_cannot_pass(self):
        self.report['memoryPoints'].pop()
        self.assert_failed('17 control checkpoints')

    def test_reordered_points_cannot_pass(self):
        self.report['memoryPoints'][1:3] = reversed(self.report['memoryPoints'][1:3])
        self.assert_failed('17 ordered checkpoints')

    def test_changed_pinned_schedule_cannot_pass(self):
        self.report['memoryPoints'][2]['planned']['startOffsetUs'] += 1
        self.assert_failed('planned offsets differ')

    def test_hidden_lateness_cannot_pass(self):
        self.report['scheduleObservations'][1]['lateUs'] = 0
        self.assert_failed('lateness hides')

    def test_probe_control_cannot_record_product_actions(self):
        self.report['cycles'][0]['productOperations'] = 1
        self.assert_failed('probe-only arm performed product work')

    def test_probe_control_cannot_open_native_owner(self):
        self.report['cycles'][0]['events'] = [{'kind': 'native-open'}]
        self.assert_failed('native lifecycle events')

    def test_probe_gc_request_missing_cannot_pass(self):
        self.report['memoryPoints'][0]['probeTelemetry']['allocationProfiles'][0]['gcRequested'] = False
        self.assert_failed('did not request GC')

    def test_probe_response_size_missing_cannot_pass(self):
        self.report['memoryPoints'][0]['probeTelemetry']['responseWireUtf8Bytes'] = None
        self.assert_failed('VM response bytes')

    def test_probe_class_count_missing_cannot_pass(self):
        self.report['memoryPoints'][0]['probeTelemetry']['allocationProfiles'][0]['classCount'] = None
        self.assert_failed('class count')

    def test_probe_response_payload_must_not_be_retained(self):
        self.report['memoryPoints'][0]['probeTelemetry']['allocationProfiles'][0]['members'] = []
        self.assert_failed('scalar metadata only')

    def test_product_vm_fake_zero_cannot_pass(self):
        self.root = Path(self.temp.name) / 'product-os-only.raw'
        self.report, self.build, self.build_sha, self.external = fixture(self.root, 'product-os-only')
        self.report['memoryPoints'][0]['vm'] = {'heapUsedBytes': 0}
        self.assert_failed('must be null')

    def test_product_probe_invocation_cannot_pass(self):
        self.root = Path(self.temp.name) / 'product-os-only.raw'
        self.report, self.build, self.build_sha, self.external = fixture(self.root, 'product-os-only')
        self.report['memoryPoints'][0]['vmProbeInvoked'] = True
        self.assert_failed('zero VM invocations')

    def test_product_shortened_slot_cannot_pass(self):
        self.root = Path(self.temp.name) / 'product-os-only.raw'
        self.report, self.build, self.build_sha, self.external = fixture(self.root, 'product-os-only')
        self.report['memoryPoints'][0]['slotEndUs'] = self.report['memoryPoints'][0]['slotStartUs']
        self.assert_failed('nominal VM slot was compressed')

    def test_missing_raw_chunk_cannot_pass(self):
        self.report['raw']['frameChunks'].pop()
        self.assert_failed('missing or reordered raw frame chunks')

    def test_raw_hash_tampering_cannot_pass(self):
        path = self.root / 'frames-0.jsonl'
        path.write_bytes(path.read_bytes() + b'{}\n')
        self.assert_failed('raw bytes/SHA-256 mismatch')

    def test_frame_sequence_gap_cannot_pass_even_with_new_hash(self):
        self.edit_chunk(0, lambda rows: rows[1].update(sequence=9))
        self.assert_failed('global received-frame sequence')

    def test_duplicate_engine_number_remains_record_not_identity(self):
        self.edit_chunk(1, lambda rows: rows[1].update(frameNumber=100))
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['raw']['duplicateEngineFrameRecords'], 1)
        self.assertEqual(result['raw']['receivedFrameCount'], 16)

    def test_short_drain_cannot_pass(self):
        start = next(row for row in self.report['raw']['boundaries'] if row['phase'] == 'drain-start')
        end = next(row for row in self.report['raw']['boundaries'] if row['phase'] == 'drain-end')
        end['timeUs'] = start['timeUs'] + 1_199_999
        self.assert_failed('drain shorter')

    def test_inprocess_point_must_equal_raw_row(self):
        self.report['memoryPoints'][0]['osBefore']['rssBytes'] += 1024
        self.assert_failed('in-process OS sample differs')

    def test_failed_external_sampler_cannot_pass(self):
        self.external['failure'] = 'read failed'
        self.external['status'] = 'failed'
        self.external['complete'] = False
        self.assert_failed('external failure or partial')

    def test_external_other_pid_cannot_pass(self):
        self.external['processIdentity']['pid'] += 1
        self.assert_failed('selected another PID')

    def test_external_partial_protocol_cannot_pass(self):
        self.report['externalEndpoints'].pop()
        self.assert_failed('79 ordered external')

    def test_external_reordered_protocol_cannot_pass(self):
        self.report['externalEndpoints'][4:6] = reversed(self.report['externalEndpoints'][4:6])
        self.assert_failed('79 ordered external')

    def test_external_raw_sequence_gap_cannot_pass(self):
        self.edit_external(lambda rows: rows[1].update(sequence=4))
        self.assert_failed('external raw sequence')

    def test_external_raw_hash_mismatch_cannot_pass(self):
        path = self.root.parent / self.external['file']
        path.write_bytes(path.read_bytes().replace(b'1000000', b'1000001', 1))
        self.assert_failed('external raw bytes/SHA-256 mismatch')

    def test_external_ack_must_equal_raw_row(self):
        self.report['externalEndpoints'][1]['os']['rssBytes'] += 1000
        self.assert_failed('acknowledged OS row differs')

    def test_external_cannot_mix_clock_domains(self):
        self.external['crossClockSubtractionAllowed'] = True
        self.assert_failed('clock domains not explicit')

    def test_external_pid_reuse_cannot_pass(self):
        self.edit_external(lambda rows: rows[1].update(starttimeTicks=778))
        self.assert_failed('possible PID reuse')

    def test_external_missing_uss_cannot_pass(self):
        self.edit_external(lambda rows: rows[1].pop('ussBytes'))
        self.assert_failed('ussBytes')

    def test_external_manifest_must_match_report(self):
        self.report['externalOs'] = copy.deepcopy(self.external)
        self.report['externalOs']['statusSamples'] += 1
        self.assert_failed('manifests differ')

    def test_external_more_than_one_process_attempt_cannot_pass(self):
        self.external['processInvocations'] = 2
        self.assert_failed('owned-process control descriptor differs')

    def test_cli_writes_control_summary_and_fails_closed(self):
        report_path, build_path = self.root.parent / 'report.json', self.root.parent / 'build.json'
        external_path, output_path = self.root.parent / 'external.json', self.root.parent / 'summary.json'
        build_path.write_bytes(fixture_source.encoded(self.build))
        external_path.write_bytes(fixture_source.encoded(self.external))
        args = [str(report_path), '--raw-directory', str(self.root), '--build', str(build_path),
                '--external-os', str(external_path), '--expected-commit', fixture_source.COMMIT,
                '--output', str(output_path)]
        report_path.write_bytes(fixture_source.encoded(self.report))
        self.assertEqual(checks.main(args), 0)
        self.assertEqual(checks.load_json(output_path)['status'], 'validated-control-observation')
        self.report['status'] = 'failed'
        report_path.write_bytes(fixture_source.encoded(self.report))
        self.assertEqual(checks.main(args), 1)
        self.assertFalse(checks.load_json(output_path)['evidenceValid'])

    def test_dirty_build_cannot_pass(self):
        self.build['source']['dirty'] = True
        self.assert_failed('build source is dirty')


if __name__ == '__main__':
    unittest.main()
