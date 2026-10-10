#!/usr/bin/env python3
"""Small synthetic journal tests. No Flutter, compiler or native workload runs."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import computer_memory_validate as checks
from computer_memory_run import sanitize, validate_target_identity


COMMIT = 'a' * 40
SCALE = 10000


def encoded(value):
    return (json.dumps(value, separators=(',', ':')) + '\n').encode()


def write_rows(root, descriptor, rows):
    payload = b''.join(encoded(row) for row in rows)
    (root / descriptor['file']).write_bytes(payload)
    descriptor.update({'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload)})
    if descriptor['file'].startswith('frames-'):
        descriptor.update({'writeSha256': descriptor['sha256'], 'readSha256': descriptor['sha256'],
                           'writeBytes': len(payload), 'readBytes': len(payload)})


def fixture(root, generic=False):
    root.mkdir(exist_ok=True)
    source_files = {name: 'b' * 64 for name in (checks.GENERIC_REQUIRED_SOURCES if generic else checks.REQUIRED_SOURCES)}
    if not generic:
        source_files['assets/computer/pong.bin'] = checks.PONG_SHA
    source_files['.flutter-version'] = hashlib.sha256(b'3.35.0\n').hexdigest()
    tree = hashlib.sha256(json.dumps(source_files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    build = {'schema': 'abc.computerraria.build.v1',
             'source': {'commit': COMMIT, 'checkedOutHead': COMMIT, 'dirty': False},
             'sourceFilesSha256': source_files, 'sourceTreeSha256': tree,
             'cmake': {'CMAKE_BUILD_TYPE': 'Profile', 'ABC_PERF_COUNTERS': 'OFF'},
             'effectiveCompileFlags': {name: '-O3 -DNDEBUG' for name in
                                      ('abc_world_circuit.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o')},
             'artifacts': {name: {'sha256': 'c' * 64, 'bytes': 1000} for name in
                           ('terraforge', 'libabc_engine.so', 'libapp.so')}}
    build_sha = hashlib.sha256(encoded(build)).hexdigest()
    boundaries, frames, cycles, points, os_rows, chunk_rows = [], [], [], [], [], []
    chunks = []
    all_records = {kind: [] for kind in checks.RECORD_TYPES}

    def os_sample(time, phase, size=1000000):
        row = {'type': 'os', 'phase': phase, 'timeUs': time * SCALE, 'statusEndUs': (time + 1) * SCALE,
               'rssBytes': size, 'processVmHwmBytes': size + 100000,
               'smapsTimeUs': (time + 2) * SCALE, 'smapsEndUs': (time + 3) * SCALE,
               'smapsRssBytes': size + 1000, 'pssBytes': size - 1000, 'ussBytes': size - 2000}
        os_rows.append(row)
        return row

    def point(cycle, phase, time):
        size = 1000000 + (cycle + 1) * 10000 + (1000 if phase == 'after-close-retained' else 0)
        before = os_sample(time + 1, phase + '.before-gc', size)
        after = os_sample(time + 30, phase + '.after-gc', size - 100)
        row = {'cycle': cycle, 'phase': phase, 'startUs': time * SCALE, 'endUs': (time + 50) * SCALE,
               'vmStartUs': (time + 10) * SCALE, 'vmEndUs': (time + 20) * SCALE,
               'osBefore': before, 'osAfter': after, 'atomic': False,
               'wrapperLatestRetained': phase == 'after-close-retained',
               'nativeCounters': {'status': 'not-exposed-by-counter-disabled-native-library', 'values': None},
               'vm': {'rssBytes': size, 'maxRssBytes': size + 100000, 'heapUsedBytes': size // 5,
                      'heapCapacityBytes': size // 2, 'externalBytes': size // 10,
                      'sampledIsolates': 4, 'sampledIsolateGroups': 2,
                      'exitedIsolatesDuringProbe': 0, 'exitedIsolateGroupsDuringProbe': 0,
                      'heapMeasurementMethod': checks.HEAP_METHOD, 'gc': 'requested-all-isolate-groups'}}
        points.append(row)
        return row

    def boundary(cycle, phase, time):
        boundaries.append({'cycle': cycle, 'phase': phase, 'timeUs': time * SCALE})

    def frame(sequence, start, received):
        return {'type': 'frame', 'sequence': sequence, 'batch': sequence, 'receivedUs': received * SCALE,
                'frameNumber': sequence + 100, 'timestampsUs': {
                    **{phase: (start + index) * SCALE for index, phase in enumerate(checks.FRAME_PHASES[:5])},
                    'rasterFinishWallTime': 1700000000000000 + start * SCALE},
                'layerCacheCount': 1, 'layerCacheBytes': 100, 'pictureCacheCount': 1, 'pictureCacheBytes': 200}

    point(-1, 'baseline', 1000)
    os_sample(2000, 'periodic')
    for cycle in range(8):
        start = (cycle + 1) * 10000
        mode = 'optimized' if cycle % 2 else 'standard'
        scenario = 'reset-original' if cycle // 2 % 2 == 0 else 'save-reopen'
        boundary(cycle, 'cycle-start', start)
        if cycle == 0:
            for phase, offset in (('cancelled-import-start', 10), ('cancelled-import-end', 90)):
                boundary(cycle, phase, start + offset)
                os_sample(start + offset + 2, f'cycle-{cycle}.{phase}')
        for phase, offset in (('initial-import-start', 100), ('initial-import-ready', 400)):
            boundary(cycle, phase, start + offset)
            os_sample(start + offset + 2, f'cycle-{cycle}.{phase}')
        middle = ([('reset-original-start', 500), ('reset-original-ready', 900)] if scenario == 'reset-original' else
                  [('export-close', 500), ('saved-reopen-start', 600), ('saved-reopen-ready', 900)])
        for phase, offset in middle:
            boundary(cycle, phase, start + offset)
            os_sample(start + offset + 2, f'cycle-{cycle}.{phase}')
        for phase, offset in (('cycle-disposed', 1000), ('drain-start', 1050), ('drain-end', 1450),
                              ('retained-point', 1490), ('released-prefix', 1750),
                              ('drain-start', 1800), ('drain-end', 2750), ('released-point', 2890), ('cycle-end', 3000)):
            boundary(cycle, phase, start + offset)
        point(cycle, 'after-close-retained', start + 1500)
        point(cycle, 'after-close-released', start + 2900)
        os_sample(start + 2990, f'cycle-{cycle}.end')
        os_sample(start + 1200, 'periodic', 1020000 + cycle * 10000)
        events = []
        if cycle == 0:
            events.append({'kind': 'native-open', 'startUs': (start + 15) * SCALE, 'endUs': (start + 70) * SCALE,
                           'sourceBytes': checks.WLD_BYTES, 'outcome': 'failed-or-cancelled', 'error': 'cancelled'})
        for index in range(2):
            session = cycle * 2 + index + 1
            events.append({'kind': 'native-open', 'startUs': (start + (150 if index == 0 else 650)) * SCALE,
                           'endUs': (start + (350 if index == 0 else 850)) * SCALE,
                           'sourceBytes': checks.WLD_BYTES, 'session': session, 'outcome': 'ready', 'circuitAbi': 2,
                           'sourceSha256': 'd' * 64 if index == 1 and scenario == 'save-reopen' else checks.WLD_SHA})
            events.append({'kind': 'native-close', 'startUs': (start + (460 if index == 0 else 950)) * SCALE,
                           'endUs': (start + (470 if index == 0 else 960)) * SCALE,
                           'session': session, 'outcome': 'acknowledged'})
        cycle_row = {'cycle': cycle, 'mode': mode, 'scenario': scenario, 'status': 'completed',
                     'physicalPulseDelta': 4096, 'nativeClockDelta': 4096, 'modelPhysicalPulseDelta': 4096,
                     'pulseBatchCount': 32, 'pulseBatchSize': 128, 'distinctMonoStates': 2 if cycle % 2 else 1,
                     'maximumLitPixels': 10 if cycle % 2 else 0,
                     'optimizationEnabledDuringPulse': bool(cycle % 2), 'programName': 'Pong (upstream RV32I).bin',
                     'nativeOptimizationEnabledDuringPulse': bool(cycle % 2),
                     'nativeWireHeadPixelRulesDuringPulse': bool(cycle % 2),
                     'pausedMonoSha256': 'e' * 64, 'events': events}
        cycle_row.update({'resetRestoredOriginal': True} if scenario == 'reset-original' else
                         {'savedWldSha256': 'd' * 64, 'reopenPreservedPausedState': True})
        if cycle == 0:
            cycle_row['cancelledImportObserved'] = True
            cycle_row['cancelRequestedAfterNativeOpenStarted'] = True
            cycle_row['cancelledImportNativeOutcome'] = 'failed-or-cancelled'
        if generic:
            for key in ('physicalPulseDelta', 'nativeClockDelta', 'modelPhysicalPulseDelta',
                        'pulseBatchCount', 'pulseBatchSize', 'distinctMonoStates',
                        'optimizationEnabledDuringPulse', 'nativeOptimizationEnabledDuringPulse',
                        'nativeWireHeadPixelRulesDuringPulse', 'programName', 'pausedMonoSha256'):
                cycle_row.pop(key)
            cycle_row.update(tickDelta=32, nativeTickDelta=32, modelTickDelta=32,
                             tickBatchCount=32, tickBatchSize=1, distinctPixelStates=1,
                             maximumLitPixels=0, pausedPixelSha256='e' * 64,
                             optimizationEnabledDuringTicks=bool(cycle % 2),
                             nativeOptimizationEnabledDuringTicks=bool(cycle % 2),
                             nativeWireHeadPixelRulesDuringTicks=bool(cycle % 2),
                             worldWidth=120, worldHeight=90,
                             displayRegion={'x': 17, 'y': 29, 'width': 23, 'height': 11},
                             trigger={'x': 19, 'y': 31, 'mask': 4, 'direct': True})
            if 'reopenPreservedPausedState' in cycle_row:
                cycle_row['reopenPreservedSelectedPixels'] = cycle_row.pop('reopenPreservedPausedState')
        cycles.append(cycle_row)
        actions = ['worldCircuitChooseWorld', 'worldCircuitImport', 'worldCircuitLoadPong',
                   *(['worldCircuitStep'] * 32), 'worldCircuitPause', 'worldCircuitClose']
        if cycle == 0:
            actions.append('worldCircuitChooseWorld')
        if cycle % 2:
            actions.append('worldCircuitOptimization')
        actions += (['worldCircuitReset'] if scenario == 'reset-original' else
                    ['worldCircuitSave', 'worldCircuitClose', 'worldCircuitChooseWorld', 'worldCircuitImport'])
        if generic:
            actions = [entry for action in actions for entry in
                       (['worldCircuitViewport', 'worldCircuitReadDisplay', 'worldCircuitTrigger']
                        if action == 'worldCircuitLoadPong' else [action])]
            actions.extend(['worldCircuitViewport', 'worldCircuitReadDisplay'])
        records = {kind: [] for kind in checks.RECORD_TYPES}
        records['viewportSnapshot'] = [
            {'cycle': cycle, 'mode': mode, 'batch': batch, 'physicalPulses': (batch + 1) * 128,
             'nativeClockDelta': (batch + 1) * 128, 'modelPhysicalPulseDelta': (batch + 1) * 128,
             'monoSha256': 'f' * 64 if cycle % 2 and batch % 2 == 0 else 'e' * 64,
             'monoLitPixels': 10 if cycle % 2 else 0} for batch in range(32)]
        if generic:
            records['viewportSnapshot'] = [
                {'cycle': cycle, 'mode': mode, 'batch': batch, 'ticks': batch + 1,
                 'nativeTickDelta': batch + 1, 'modelTickDelta': batch + 1,
                 'pixelSha256': 'e' * 64, 'litPixels': 0} for batch in range(32)]
        for index, action in enumerate(actions):
            records['window'].append({'id': f'{action}.{mode}', 'cycle': cycle, 'warmup': False,
                                      'success': True, 'startUs': (start + 100 + index * 30) * SCALE,
                                      'endUs': (start + 120 + index * 30) * SCALE,
                                      'rssBeforeBytes': 1000000, 'rssAfterBytes': 1000000})
            records['dispatch'].append({'action': action, 'cycle': cycle, 'warmup': False,
                                        'variant': {'profileMode': mode}, 'macroScope': f'{action}.{mode}',
                                        'durationMs': 1.2, 'completion': 'returned'})
        if cycle == 0:
            for action in ('worldCircuitImport', 'worldCircuitCancel'):
                records['dispatch'].append({'action': action, 'cycle': cycle, 'warmup': False,
                                            'variant': {'profileMode': mode}, 'macroScope': None,
                                            'durationMs': 1, 'completion': 'returned'})
        records['dispatch'].extend({'action': 'worldCircuitReleaseKeys', 'cycle': cycle, 'warmup': False,
                                    'variant': {'profileMode': mode}, 'macroScope': None,
                                    'durationMs': 0.1, 'completion': 'returned'}
                                   for _ in range(0 if generic else 1 if scenario == 'reset-original' else 2))
        for kind in checks.RECORD_TYPES:
            all_records[kind].extend(records[kind])
        cycle_frames = [frame(cycle * 2, start + 200, start + 300),
                        frame(cycle * 2 + 1, start + 400, start + 2600)]
        frames.extend(cycle_frames)
        for index, (reason, offset) in enumerate((('release-prefix', 1700), ('late-tail', 2800))):
            counts = {kind: len(records[kind]) if index == 0 else 0 for kind in checks.RECORD_TYPES}
            descriptor = {'file': f'frames-{len(chunks)}.jsonl', 'reason': f'cycle-{cycle}.{reason}',
                          'firstSequence': cycle * 2 + index, 'frameCount': 1, 'recordCounts': counts,
                          'writeStartedUs': (start + offset) * SCALE, 'verifiedUs': (start + offset + 1) * SCALE,
                          'hashVerifiedBeforeRelease': True}
            rows = [{'type': 'chunk', 'schema': 'abc.memory-raw.v1', 'hostPid': 123,
                     'reason': descriptor['reason'], 'startedUs': descriptor['writeStartedUs'],
                     'firstSequence': descriptor['firstSequence'], 'frameCount': 1, 'recordCounts': counts},
                    cycle_frames[index]]
            if index == 0:
                rows.extend({'type': kind, 'data': row} for kind in checks.RECORD_TYPES for row in records[kind])
            chunks.append(descriptor)
            chunk_rows.append(rows)
    boundary(8, 'drain-start', 84000)
    boundary(8, 'drain-end', 85000)
    os_sample(85030, 'recording-stopped')
    descriptor = {'file': 'frames-16.jsonl', 'reason': 'final-received-tail', 'firstSequence': 16,
                  'frameCount': 0, 'recordCounts': dict.fromkeys(checks.RECORD_TYPES, 0),
                  'writeStartedUs': 85020 * SCALE, 'verifiedUs': 85021 * SCALE, 'hashVerifiedBeforeRelease': True}
    chunks.append(descriptor)
    chunk_rows.append([{'type': 'chunk', 'schema': 'abc.memory-raw.v1', 'hostPid': 123,
                        'reason': 'final-received-tail', 'startedUs': descriptor['writeStartedUs'],
                        'firstSequence': 16, 'frameCount': 0, 'recordCounts': descriptor['recordCounts']}])
    for boundary_row in boundaries:
        boundary_row['receivedFrames'] = sum(frame_row['receivedUs'] <= boundary_row['timeUs'] for frame_row in frames)
        boundary_row['receivedBatches'] = boundary_row['receivedFrames']
    for descriptor, rows in zip(chunks, chunk_rows):
        write_rows(root, descriptor, rows)
    os_rows.sort(key=lambda row: row['timeUs'])
    for sequence, row in enumerate(os_rows):
        row['sequence'] = sequence
    os_files = []
    for index in range(9):
        before = ((index + 1) * 10000 + 3000) * SCALE if index < 8 else float('inf')
        after = (index * 10000 + 3000) * SCALE if index > 0 else -1
        rows = [row for row in os_rows if after < row['timeUs'] <= before]
        descriptor = {'file': f'os-{index}.jsonl', 'sampleCount': len(rows)}
        write_rows(root, descriptor, rows)
        os_files.append(descriptor)
    for point_row in points:
        time = point_row['endUs']
        completed = [chunk for chunk in chunks if chunk['verifiedUs'] <= time]
        persisted = sum(chunk['frameCount'] for chunk in completed)
        received = sum(frame_row['receivedUs'] <= time for frame_row in frames)
        persisted_records = {kind: sum(chunk['recordCounts'][kind] for chunk in completed) for kind in checks.RECORD_TYPES}
        received_records = {kind: sum(row['cycle'] <= point_row['cycle'] for row in all_records[kind]) for kind in checks.RECORD_TYPES}
        point_row['recorder'] = {'frames': received - persisted, 'frameReceipts': received - persisted,
                                 'receivedFrames': received, 'persistedFrames': persisted, 'receivedBatches': received,
                                 'chunkDescriptors': len(completed),
                                 'boundaryDescriptors': sum(row['timeUs'] <= time for row in boundaries),
                                 'receivedRecords': received_records, 'persistedRecords': persisted_records,
                                 **{checks.RETAINED_KEYS[kind]: received_records[kind] - persisted_records[kind]
                                    for kind in checks.RECORD_TYPES}}
    totals = {kind: len(rows) for kind, rows in all_records.items()}
    final_counts = {'frames': 0, 'frameReceipts': 0, 'receivedFrames': 16, 'persistedFrames': 16,
                    'receivedBatches': 16, 'chunkDescriptors': 17, 'boundaryDescriptors': len(boundaries),
                    'receivedRecords': totals, 'persistedRecords': totals.copy(),
                    **dict.fromkeys(checks.RETAINED_KEYS.values(), 0)}
    report = {'schema': 'abc.computer-memory-diagnostic.v1', 'status': 'observed', 'hostPid': 123,
              'buildMode': 'profile', 'inputFormat': 'wld-only', 'circuitAbi': 2,
              'plannedCycles': 8, 'completedCycles': 8, 'physicalPulsesPerCycle': 4096, 'excludedWarmupCycles': 0,
              'fixture': {'wldBytes': checks.WLD_BYTES, 'wldSha256': checks.WLD_SHA,
                          'pongSha256': checks.PONG_SHA, 'sourceRevision': checks.SOURCE_REVISION},
              'runtime': {'commit': COMMIT, 'checkedOutHead': COMMIT, 'workingTreeDirty': False,
                          'buildProvenanceSha256': build_sha, 'sourceTreeSha256': tree,
                          'provenanceAttachment': 'single-diagnostic-runner-after-process',
                          'platform': 'linux', 'flutterRevisionPin': checks.FLUTTER_REVISION,
                          'flutterVersion': '3.35.0', 'renderer': 'synthetic renderer', 'heapMeasurementMethod': checks.HEAP_METHOD},
              'cycles': cycles, 'memoryPoints': points,
              'raw': {'directory': root.name, 'frameChunks': chunks, 'boundaries': boundaries,
                      'finalCounts': final_counts, 'recordingStoppedUs': 85010 * SCALE,
                      'os': {'hostPid': 123, 'sampleCount': len(os_rows), 'files': os_files, 'error': None}},
              'drainPolicy': {'frameBarriers': 3, 'barrierDelayMs': 16, 'quietMs': 1200,
                              'tailPrefixFlushesPerCycle': 2, 'capture': 'all-callbacks-received-until-recordingStoppedUs'},
              'failure': None, 'failureStack': None}
    if generic:
        report['schema'] = checks.GENERIC_SCHEMA
        report['workloadId'] = checks.GENERIC_WORKLOAD
        report['ticksPerCycle'] = 32
        del report['physicalPulsesPerCycle']
        del report['fixture']['pongSha256']
    return report, build, build_sha


class GenericMemoryChecksTest(unittest.TestCase):
    def test_runner_only_associates_exact_schema_workload_and_process(self):
        for schema in ('abc.computer-memory-diagnostic.v1', checks.GENERIC_SCHEMA):
            report = {'schema': schema, 'hostPid': 12, 'runtime': {'commit': COMMIT}}
            if schema == checks.GENERIC_SCHEMA: report['workloadId'] = checks.GENERIC_WORKLOAD
            self.assertEqual(validate_target_identity(report, COMMIT), schema)
            for key, value in (('hostPid', True), ('hostPid', 0), ('schema', 'unknown'), ('workloadId', 'wrong')):
                broken = {**report, key: value}
                with self.assertRaises(ValueError): validate_target_identity(broken, COMMIT)
            with self.assertRaises(ValueError): validate_target_identity(report, 'f' * 40)

    def test_complete_static_or_empty_display_is_valid_but_not_fluency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, build, build_sha = fixture(root, generic=True)
            result = checks.validate(report, root, build, COMMIT, build_sha)
            self.assertTrue(result['evidenceValid'], result['errors'])
            self.assertFalse(result['plateauEstablished'])
            self.assertEqual(result['targetDeviceFluencyStatus'], 'not-established')
            self.assertEqual(result['workloadId'], checks.GENERIC_WORKLOAD)
            self.assertEqual(result['raw']['receivedFrameCount'], 16)

    def test_generic_missing_wrong_or_legacy_evidence_fails(self):
        import copy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, build, build_sha = fixture(root, generic=True)
            cases = {
                'workload': lambda r: r.update(workloadId='legacy-cpu'),
                'partial': lambda r: r.update(completedCycles=7),
                'failed': lambda r: r.update(status='failed', failure='retained failure'),
                'ticks': lambda r: r['cycles'][0].update(nativeTickDelta=31),
                'mode': lambda r: r['cycles'][1].update(nativeOptimizationEnabledDuringTicks=False),
                'bounds': lambda r: r['cycles'][0]['displayRegion'].update(x=120),
                'mask': lambda r: r['cycles'][0]['trigger'].update(mask=0),
                'program': lambda r: r['cycles'][0].update(programName='Pong'),
                'reopen': lambda r: r['cycles'][2].update(reopenPreservedSelectedPixels=False),
                'close': lambda r: r['cycles'][0]['events'][-1].update(outcome='failed'),
                'raw-sha': lambda r: r['raw']['frameChunks'][0].update(sha256='0' * 64),
                'drop-cycle': lambda r: r['cycles'].pop(),
            }
            for name, mutate in cases.items():
                broken = copy.deepcopy(report); mutate(broken)
                result = checks.validate(broken, root, build, COMMIT, build_sha)
                self.assertFalse(result['evidenceValid'], name)
                if name == 'failed': self.assertEqual(result['reportedFailure'], 'retained failure')

    def test_generic_protocol_records_cannot_drop_or_substitute_actions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, build, build_sha = fixture(root, generic=True)
            validator = checks.Validator(report, root, build, COMMIT, build_sha)
            validator.validate_header(); validator.validate_boundaries(); validator.validate_frames()
            validator.validate_generic_records()
            for action in ('worldCircuitViewport', 'worldCircuitReadDisplay', 'worldCircuitTrigger', 'worldCircuitStep'):
                item = next(row for row in validator.records['dispatch'] if row['action'] == action)
                item['action'] = 'worldCircuitLoadPong'
                with self.assertRaises(ValueError): validator.validate_generic_records()
                item['action'] = action

    def test_legacy_artifact_after_fixture_relocation_remains_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report, build, _ = fixture(root)
            files = build['sourceFilesSha256']
            files['test/support/computerraria/layout.dart'] = files.pop('lib/domain/computerraria_computer.dart')
            files['test/fixtures/computerraria/pong.bin'] = files.pop('assets/computer/pong.bin')
            tree = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            build['sourceTreeSha256'] = tree
            build_sha = hashlib.sha256(encoded(build)).hexdigest()
            report['runtime'].update(sourceTreeSha256=tree, buildProvenanceSha256=build_sha)
            result = checks.validate(report, root, build, COMMIT, build_sha)
            self.assertTrue(result['evidenceValid'], result['errors'])
            self.assertEqual(result['workloadId'], 'legacy-computerraria-memory-v1')


class MemoryChecksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'diagnostic.raw'
        self.report, self.build, self.build_sha = fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def run_validation(self):
        return checks.validate(self.report, self.root, self.build, COMMIT, self.build_sha)

    def assert_failed(self, text):
        result = self.run_validation()
        self.assertFalse(result['evidenceValid'], result)
        self.assertIn(text, '\n'.join(result['errors']))
        self.assertFalse(result['plateauEstablished'])
        return result

    def edit_chunk(self, index, edit):
        descriptor = self.report['raw']['frameChunks'][index]
        rows = [json.loads(line) for line in (self.root / descriptor['file']).read_bytes().splitlines()]
        edit(rows)
        write_rows(self.root, descriptor, rows)

    def test_complete_received_evidence_is_valid_but_does_not_prove_plateau(self):
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['raw']['receivedFrameCount'], 16)
        self.assertEqual(result['raw']['engineUnemittedTimingCompleteness'], 'unknown')
        self.assertTrue(result['raw']['lateReceivedFramesByBoundary'])
        self.assertFalse(result['plateauEstablished'])
        self.assertEqual(len(result['measurements']['cycles']), 8)
        self.assertEqual(len(result['measurements']['trends']['standard']['released']['vm.heapUsedBytes']['series']), 4)

    def test_non_atomic_process_info_disagreement_retains_raw_and_growth(self):
        before = self.run_validation()['measurements']
        point = self.report['memoryPoints'][2]
        rss = point['vm']['rssBytes']
        point['vm']['maxRssBytes'] = rss - 806912
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        warning, = result['rssSamplingDisagreements']
        self.assertEqual(warning['rssBytes'], rss)
        self.assertEqual(warning['maxRssBytes'], rss - 806912)
        self.assertEqual(warning['rssMinusReportedMaxBytes'], 806912)
        self.assertIn('/proc/self/statm', warning['rssSource'])
        self.assertIn('getrusage', warning['maxRssSource'])
        self.assertEqual(warning['samplingWindowUs'], [point['vmStartUs'], point['vmEndUs']])
        self.assertFalse(result['plateauEstablished'])
        self.assertEqual(result['measurements']['trends']['overall']['released']['vm.rssBytes'],
                         before['trends']['overall']['released']['vm.rssBytes'])
        self.assertEqual(point['vm']['maxRssBytes'], rss - 806912)

    def test_heap_capacity_contradiction_remains_failure(self):
        point = self.report['memoryPoints'][2]
        point['vm']['heapUsedBytes'] = point['vm']['heapCapacityBytes'] + 1
        self.assert_failed('heap capacity bound')

    def test_same_status_hwm_below_rss_remains_failure(self):
        descriptor = self.report['raw']['os']['files'][0]
        rows = [json.loads(line) for line in (self.root / descriptor['file']).read_text().splitlines()]
        rows[0]['processVmHwmBytes'] = rows[0]['rssBytes'] - 1
        write_rows(self.root, descriptor, rows)
        self.assert_failed('process HWM below current status RSS')

    def test_dropped_frame_even_with_rehashed_raw_file_fails(self):
        self.edit_chunk(0, lambda rows: rows.pop(1))
        self.assert_failed('raw frame count differs')

    def test_corrupted_raw_hash_fails(self):
        self.report['raw']['frameChunks'][0]['sha256'] = '0' * 64
        self.assert_failed('raw bytes/SHA-256 mismatch')

    def test_unverified_write_read_digest_fails(self):
        self.report['raw']['frameChunks'][0]['writeSha256'] = '0' * 64
        self.assert_failed('write/read/raw hash')

    def test_missing_os_raw_file_fails(self):
        (self.root / 'os-3.jsonl').unlink()
        self.assert_failed('missing raw file')

    def test_dropped_os_sample_even_with_updated_hash_fails(self):
        descriptor = self.report['raw']['os']['files'][0]
        rows = [json.loads(line) for line in (self.root / descriptor['file']).read_bytes().splitlines()]
        rows.pop(2)
        write_rows(self.root, descriptor, rows)
        self.assert_failed('OS sample sequence')

    def test_missing_phase_fails(self):
        self.report['raw']['boundaries'].pop(3)
        self.assert_failed('missing/duplicate/out-of-order phase')

    def test_missing_checkpoint_fails(self):
        self.report['memoryPoints'].pop(4)
        self.assert_failed('all 17 ordered checkpoints')

    def test_gc_and_native_counter_fabrication_fail(self):
        self.report['memoryPoints'][0]['nativeCounters']['values'] = 0
        self.assert_failed('fake zero')
        self.report['memoryPoints'][0]['nativeCounters']['values'] = None
        self.report['memoryPoints'][0]['vm']['gc'] = 'not-requested'
        self.assert_failed('actual GC')

    def test_non_atomic_bracket_corruption_fails(self):
        self.report['memoryPoints'][0]['vmStartUs'] = 1
        self.assert_failed('non-atomic bracket order')

    def test_wrapper_latest_must_be_released(self):
        self.report['memoryPoints'][2]['wrapperLatestRetained'] = True
        self.assert_failed('wrapper latest')

    def test_duplicate_engine_number_is_reported_without_dropping(self):
        self.edit_chunk(1, lambda rows: rows[1].update(frameNumber=100))
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['raw']['receivedFrameCount'], 16)
        self.assertEqual(result['raw']['duplicateEngineFrameRecords'], 1)
        self.assertEqual(result['raw']['uniqueEngineFrameNumbers'], 15)

    def test_cancellation_ready_race_must_include_acknowledged_close(self):
        cycle = self.report['cycles'][0]
        event = cycle['events'][0]
        event.update(outcome='ready', session=100, circuitAbi=2, sourceSha256=checks.WLD_SHA)
        event.pop('error')
        cycle['cancelledImportNativeOutcome'] = 'ready'
        cycle['events'].insert(1, {'kind': 'native-close', 'startUs': event['endUs'] + SCALE,
                                   'endUs': event['endUs'] + 2 * SCALE, 'session': 100, 'outcome': 'acknowledged'})
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['cancelledImportNativeOutcome'], 'ready')
        cycle['events'].pop(1)
        self.assert_failed('new open without preceding close')

    def test_missing_public_frame_field_fails(self):
        self.edit_chunk(0, lambda rows: rows[1]['timestampsUs'].pop('rasterFinishWallTime'))
        self.assert_failed('public FrameTiming timestamps missing')

    def test_lost_dispatch_cannot_hide_by_rehashing(self):
        self.edit_chunk(0, lambda rows: rows.pop(next(index for index, row in enumerate(rows) if row['type'] == 'dispatch')))
        self.assert_failed('records lost or duplicated')

    def test_production_disposal_release_keys_are_required(self):
        self.edit_chunk(0, lambda rows: rows.pop(next(index for index, row in enumerate(rows)
                                                    if row['type'] == 'dispatch'
                                                    and row['data']['action'] == 'worldCircuitReleaseKeys')))
        self.assert_failed('production panel disposal key-release dispatch missing')

    def test_additional_focus_release_dispatch_is_benign(self):
        validator = checks.Validator(self.report, self.root, self.build, COMMIT, self.build_sha)
        result = validator.run()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['raw']['productionKeyReleaseDispatchesByCycle']['2'], 2)
        validator.records['dispatch'].append({'action': 'worldCircuitReleaseKeys', 'cycle': 1,
                                               'warmup': False, 'completion': 'returned', 'durationMs': 0.01,
                                               'variant': {'profileMode': 'optimized'},
                                               'macroScope': 'worldCircuitPause.optimized'})
        validator.validate_records()

    def test_other_pid_and_wrong_provenance_fail(self):
        self.report['raw']['os']['hostPid'] = 987
        self.assert_failed('single report PID')
        self.report['runtime']['commit'] = 'f' * 40
        self.assert_failed('source revision')

    def test_failed_partial_report_retains_measurement_summary(self):
        self.report['status'] = 'failed'
        self.report['failure'] = 'native operation failed'
        result = self.assert_failed('failed or partial run')
        self.assertIsNotNone(result['measurements'])
        self.assertEqual(result['raw']['receivedFrameCount'], 16)
        self.assertEqual(result['reportedFailure'], 'native operation failed')

    def test_fixed_real_pulse_and_cleanup_are_required(self):
        self.report['cycles'][2]['nativeClockDelta'] = 127
        self.assert_failed('real fixed pulse')
        self.report['cycles'][2]['nativeClockDelta'] = 4096
        self.report['cycles'][2]['events'].pop()
        self.assert_failed('incomplete native lifecycle cleanup')

    def test_missing_values_never_become_zero_in_summary(self):
        self.report['memoryPoints'][2]['vm']['heapUsedBytes'] = None
        result = self.assert_failed('heapUsedBytes')
        row = result['measurements']['cycles'][0]
        self.assertIsNone(row['released']['vm.heapUsedBytes'])
        self.assertIsNone(row['releasedMinusRetained']['vm.heapUsedBytes'])
        self.assertEqual(result['measurements']['trends']['overall']['released']['vm.heapUsedBytes']['status'],
                         'insufficient-evidence')

    def test_missing_display_batch_and_static_on_display_fail(self):
        self.edit_chunk(2, lambda rows: rows.pop(next(index for index, row in enumerate(rows)
                                                    if row['type'] == 'viewportSnapshot')))
        self.assert_failed('raw display pulse batch trace')

    def test_on_display_must_change_and_have_lit_pixels(self):
        def make_static(rows):
            for row in rows:
                if row['type'] == 'viewportSnapshot':
                    row['data'].update(monoSha256='e' * 64, monoLitPixels=0)
        self.edit_chunk(2, make_static)
        self.report['cycles'][1].update(distinctMonoStates=1, maximumLitPixels=0)
        self.assert_failed('ON workload lacks real changing/lit display evidence')

    def test_cli_writes_useful_failure_output_for_invalid_json(self):
        report_path, build_path, output = (Path(self.temp.name) / name for name in ('bad.json', 'build.json', 'summary.json'))
        report_path.write_text('{broken')
        build_path.write_bytes(encoded(self.build))
        code = checks.main([str(report_path), '--raw-directory', str(self.root), '--build', str(build_path),
                            '--expected-commit', COMMIT, '--output', str(output)])
        self.assertEqual(code, 1)
        self.assertFalse(json.loads(output.read_text())['evidenceValid'])

    def test_cli_valid_report_produces_serializable_summary(self):
        report_path, build_path, output = (Path(self.temp.name) / name for name in ('report.json', 'build.json', 'summary.json'))
        report_path.write_bytes(encoded(self.report))
        build_path.write_bytes(encoded(self.build))
        code = checks.main([str(report_path), '--raw-directory', str(self.root), '--build', str(build_path),
                            '--expected-commit', COMMIT, '--output', str(output)])
        self.assertEqual(code, 0)
        summary = json.loads(output.read_text())
        self.assertTrue(summary['evidenceValid'])
        self.assertFalse(summary['plateauEstablished'])
        self.assertEqual(summary['inputs']['buildSha256'], self.build_sha)


class TrendChecksTest(unittest.TestCase):
    def test_strictly_increasing_is_continued_growth_even_for_tiny_deltas(self):
        result = checks.trend([10, 11, 12, 13], [0, 2, 4, 6])
        self.assertEqual(result['status'], 'continued-growth-in-observed-window')
        self.assertEqual(result['slopePerCycle'], 0.5)
        self.assertEqual(result['range'], 3)
        self.assertFalse(result['plateauEstablished'])

    def test_nonmonotonic_is_inconclusive_even_with_positive_slope(self):
        result = checks.trend([10, 9, 15, 20])
        self.assertEqual(result['status'], 'plateau-not-established-inconclusive')
        self.assertGreater(result['slopePerCycle'], 0)
        self.assertFalse(result['plateauEstablished'])

    def test_flat_or_decreasing_does_not_establish_plateau(self):
        for series in ([10, 10, 10, 10], [20, 17, 11, 5]):
            self.assertEqual(checks.trend(series)['status'], 'plateau-not-established-inconclusive')

    def test_missing_values_are_incomplete(self):
        self.assertEqual(checks.trend([10, None, 20])['status'], 'insufficient-evidence')


class SanitizationTest(unittest.TestCase):
    def test_local_vm_auth_urls_are_removed_before_storage(self):
        value = sanitize('VM http://127.0.0.1:1234/secret=/ ws://localhost:5678/token=/ws https://[::1]:8/key=/')
        self.assertNotIn('secret', value)
        self.assertNotIn('token', value)
        self.assertNotIn('key=', value)
        self.assertEqual(value.count('[redacted-local-service-url]'), 3)

    def test_public_urls_are_preserved(self):
        value = 'See https://docs.flutter.dev/perf and https://github.com/Live-yum/exploreTV'
        self.assertEqual(sanitize(value), value)


if __name__ == '__main__':
    unittest.main()
