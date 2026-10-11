#!/usr/bin/env python3
"""Synthetic false-pass contracts only. No measured results or native execution."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import computer_memory_checks_test as fixture_source
import computer_memory_validate as original
import memory_ownership_validate as checks


def encoded(value):
    return (json.dumps(value, separators=(',', ':'), allow_nan=False) + '\n').encode()


def h(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def allocator_build():
    # Fabricated metadata mirrors the fixed build producer's JSON format only.
    package = {'status': 'available', 'packages': ['synthetic-libc'],
               'metadata': 'synthetic-libc\t2.39\tamd64\tglibc\t2.39', 'queryReturnCode': 0}
    header = {'sha256': '1' * 64, 'bytes': 100}
    return {'schema': 'abc.native-retention-helper-build.v1', 'status': 'built',
            'outsideApplicationCheckout': True, 'applicationLaunched': False, 'downloadedDependencies': False,
            'source': {'path': 'tool/perf/native_owner_libc_probe.c', 'sha256': checks.LIBC_HELPER_SOURCE_SHA256},
            'helperSha256': 'e' * 64, 'helperBytes': 100,
            'compiler': {'sha256': '2' * 64, 'version': 'synthetic cc', 'target': 'x86_64', 'package': copy.deepcopy(package)},
            'headers': {'/usr/include/malloc.h': header},
            'mallocHeader': {'path': '/usr/include/malloc.h', **header, 'package': copy.deepcopy(package)},
            'dependencySha256': '3' * 64,
            'buildContract': {'sourceSha256': '4' * 64, 'executableSha256': '5' * 64},
            'runtime': {'scope': 'fresh-native-build-contract-process-only', 'libcSha256': '6' * 64,
                        'runtimeLibcVersion': '2.39', 'headerGlibcMajor': 2, 'headerGlibcMinor': 39,
                        'sizeTBytes': 8, 'mallinfo2StructBytes': 80, 'helperStatus': 0,
                        'abiContractMatched': True, 'inspectedUpstreamFamily': True,
                        'sourceReviewRequired': False, 'package': copy.deepcopy(package)}}


def helper_build_hash(build):
    return hashlib.sha256((json.dumps(build, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()).hexdigest()


def native(at):
    values = [0, 0, 0, 100, 0, 0, 0, 0, 0]
    return {'status': 'available', 'abiVersion': 1, 'wordCount': 16, 'censoredMask': 0,
            'values': dict(zip(checks.NATIVE_FIELDS, values)), 'observerBufferBytes': 128,
            'rawWords': [1, 16, *values, 0, 0, 0, 0, 0], 'startUs': at, 'endUs': at + 1}


def worker(at, available):
    result = {'status': 'acknowledged' if available else 'worker-not-started',
              'workerGeneration': 1 if available else None, 'requestUs': at, 'ackUs': at + 9,
              'productionPendingBefore': 0, 'productionPendingAfter': 0, 'owner': None}
    if available:
        host = {field: 0 for field in checks.HOST_FIELDS}
        host.update(startUs=at + 2, endUs=at + 3)
        for kind in ('Hash', 'Read'):
            host[f'ffi{kind}WindowAccountingCertain'] = True
        result.update(diagnosticRequestExcluded=True, owner={
            'startUs': at + 1, 'endUs': at + 8, 'ordinaryDocumentHandles': 0,
            'worldCircuitBindingInitialized': True, 'host': host, 'native': native(at + 4)})
    return result


def write_allocator_captures(root, report):
    rows = []
    reasons = [None, 'unsupported-build-headers', 'runtime-mallinfo2-unavailable',
               'allocator-symbols-interposed', 'libc-symbol-identity-unverified']
    for gauge_row in report['ownershipGauges']:
        a = gauge_row['allocator']
        status = reasons.index(a['reason'])
        major, minor = [int(value) for value in a['glibcVersion'].split('.')] if a['glibcVersion'] else [0, 0]
        words = [1, status, a['sizeTBytes'], a['mallinfo2StructBytes'] or 0, major, minor]
        words += [a['fields'][name] for name in checks.MALLINFO_FIELDS] if not status else [2 ** 64 - 1] * 10
        rows.append({'sequence': a['sequence'], 'startUs': a['startUs'], 'endUs': a['endUs'],
                     'statusCode': status, 'rawWords': [str(word) for word in words],
                     'rawWordEncoding': 'unsigned-decimal-string'})
    report['raw']['allocatorCaptures'] = {'file': 'allocator-captures.jsonl', 'sampleCount': len(rows)}
    fixture_source.write_rows(root, report['raw']['allocatorCaptures'], rows)


def gauge_writes(report):
    return [{'id': row['id'], 'sequence': index, 'startUs': row['endUs'], 'endUs': row['endUs'],
             'bytes': len(encoded(row)), 'status': 'written'}
            for index, row in enumerate(report['ownershipGauges'])]


def gauge(index, id, cycle, phase, at, arm, serialized=None):
    after = phase.endswith('after-gc')
    worker_at = at + (3 if after else 1)
    main_at = worker_at + 10
    fd_at = main_at + 2
    allocator_at = at if after else fd_at + 5
    capture_end = fd_at + 6
    serialized = capture_end + 1 if serialized is None else serialized
    present = arm == checks.ARMS[1] and ('.after-close-retained.' in id or phase == 'retained-quiet-end')
    handles = index if arm == checks.ARMS[1] else 0
    return {'id': id, 'sequence': index, 'cycle': cycle, 'phase': phase,
            'startUs': at, 'mainStartUs': main_at, 'mainEndUs': main_at + 1,
            'captureEndUs': capture_end, 'serializedAfterUs': serialized, 'endUs': serialized + 1,
            'atomic': False,
            'images': {'installedUs': 1, 'stoppedUs': None, 'createdHandles': handles,
                       'disposedHandles': handles, 'observedHandleBalance': 0,
                       'peakObservedHandleBalance': min(handles, 1), 'active': True,
                       'callbacksIntact': True, 'everReplaced': False, 'priorCallbackFailures': 0,
                       'preInstallationHandlesUnknown': True},
            'imageCache': dict.fromkeys(('currentSize', 'currentSizeBytes', 'liveImageCount', 'pendingImageCount'), 0),
            'wrapper': {'present': present, 'recordsLength': 0, 'worldLength': 0, 'objectsLength': 0,
                        'statsLength': 24 if present else 0, 'worldSourcePresent': present, 'sourceTokenPresent': False},
            'worker': worker(worker_at, arm == checks.ARMS[1] and index >= 3),
            'fd': {'status': 'observed', 'hostPid': 123, 'startUs': fd_at,
                   'enumerationEndUs': fd_at + 1, 'classificationStartUs': fd_at + 2, 'endUs': fd_at + 3,
                   'fdEntriesEnumerated': 7, 'categories': {'socket': 2, 'pipe': 1, 'anonymous-inode': 1,
                                                         'path-like': 2, 'other': 0},
                   'vanished': 1, 'unreadable': 0, 'ignoredNonnumeric': 0, 'atomic': False,
                   'probeDescriptorMayBeIncluded': True, 'maximumEntries': 4096, 'errorKind': None, 'errorCode': None},
            'allocator': {'schema': 'abc.native-retention-mallinfo2.v1', 'sequence': index,
                          'status': 'available', 'reason': None, 'startUs': allocator_at, 'endUs': allocator_at + 1,
                          'clockDomain': checks.CLOCK, 'atomic': False, 'sizeTBytes': 8,
                          'observerWireBufferBytes': 52 * 128,
                          'mallinfo2StructBytes': 80, 'glibcVersion': '2.39',
                          'fields': dict.fromkeys(checks.MALLINFO_FIELDS, 0)}}


def fixture(root, arm=checks.ARMS[1]):
    report, build, _ = fixture_source.fixture(root, generic=True)
    for cycle in report['cycles']:
        cycle.update(worldWidth=15200, worldHeight=7200,
                     displayRegion=copy.deepcopy(checks.FIXED_REGION), trigger=copy.deepcopy(checks.FIXED_TRIGGER))
    schedule = checks.load_json(Path(checks.__file__).with_name('memory_ownership_schedule.json'))
    report.update(schema=checks.REPORT_SCHEMA, arm=arm, baseProductCommit=checks.BASE_COMMIT,
                  plannedCheckpoints=17, vmProbeCalls=17, plannedOwnershipGauges=52,
                  expectedNativeWorkers=0 if arm == checks.ARMS[0] else 1,
                  inProcessOsSamplerRetained=True, externalOsSamplerEnabled=False,
                  scheduleSha256=checks.SCHEDULE_SHA256, scheduleOriginUs=2000, scheduleObservations=[])
    build['cmake'].update(ABC_PERF_COUNTERS='ON', ABC_OWNER_DIAGNOSTICS='ON')
    build['actualOwnerCompilationTargets'] = {name: {'FLAGS': '-O3 -DNDEBUG', 'DEFINES': '-DABC_OWNER_DIAGNOSTICS=1'}
        for name in ('abc_owner_diagnostics.c.o', 'abc_perf.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o')}
    build['ownershipProvenance'] = {'baseProductCommit': checks.BASE_COMMIT,
        'sourceProvenanceSha256': 'd' * 64, 'allocatorHelperSha256': 'e' * 64, 'ownerAbi': 1, 'perfAbi': 1}
    build['ownershipProvenance']['allocatorBuild'] = allocator_build()
    build['ownershipProvenance']['allocatorBuildSha256'] = helper_build_hash(build['ownershipProvenance']['allocatorBuild'])
    for path in ('integration_test/computer_memory_ownership_test.dart',
                 'tool/perf/memory_ownership_validate.py', 'tool/perf/memory_ownership_run.py'):
        build['sourceFilesSha256'][path] = 'b' * 64
    build['sourceFilesSha256']['tool/perf/memory_ownership_schedule.json'] = checks.SCHEDULE_SHA256
    build['sourceTreeSha256'] = hashlib.sha256(json.dumps(build['sourceFilesSha256'], sort_keys=True,
                                                        separators=(',', ':')).encode()).hexdigest()
    if arm == checks.ARMS[0]:
        report.update(inputFormat='none', ticksPerCycle=0, fixture=None)
        report['cycles'] = [{'cycle': cycle, 'mode': 'optimized' if cycle % 2 else 'standard',
                             'scenario': 'no-world-no-edit', 'status': 'completed', 'productOperations': 0}
                            for cycle in range(8)]
        allowed = {'cycle-start', 'cycle-disposed', 'drain-start', 'drain-end', 'retained-point',
                   'released-prefix', 'released-point', 'cycle-end'}
        report['raw']['boundaries'] = [row for row in report['raw']['boundaries'] if row['phase'] in allowed]
        for descriptor in report['raw']['frameChunks']:
            rows = [json.loads(line) for line in (root / descriptor['file']).read_bytes().splitlines()]
            rows = [row for row in rows if row['type'] in ('chunk', 'frame')]
            descriptor['recordCounts'] = dict.fromkeys(original.RECORD_TYPES, 0)
            rows[0]['recordCounts'] = descriptor['recordCounts'].copy()
            fixture_source.write_rows(root, descriptor, rows)
        for point in report['memoryPoints']:
            point['wrapperLatestRetained'] = False
        for counts in [report['raw']['finalCounts'], *[point['recorder'] for point in report['memoryPoints']]]:
            counts.update({field: 0 for field in original.RETAINED_KEYS.values()})
            counts['receivedRecords'] = dict.fromkeys(original.RECORD_TYPES, 0)
            counts['persistedRecords'] = dict.fromkeys(original.RECORD_TYPES, 0)
        report['raw']['finalCounts']['boundaryDescriptors'] = len(report['raw']['boundaries'])
        os_rows = []
        for descriptor in report['raw']['os']['files']:
            rows = [json.loads(line) for line in (root / descriptor['file']).read_bytes().splitlines()]
            os_rows += [row for row in rows if not row['phase'].startswith('cycle-') or row['phase'].endswith('.end')]
        old_new = {}
        for sequence, row in enumerate(os_rows):
            old_new[row['sequence']] = sequence
            row['sequence'] = sequence
        for point in report['memoryPoints']:
            for field in ('osBefore', 'osAfter'):
                point[field]['sequence'] = old_new[point[field]['sequence']]
        for index, descriptor in enumerate(report['raw']['os']['files']):
            before = ((index + 1) * 10000 + 3000) * fixture_source.SCALE if index < 8 else float('inf')
            after = (index * 10000 + 3000) * fixture_source.SCALE if index > 0 else -1
            rows = [row for row in os_rows if after < row['timeUs'] <= before]
            descriptor['sampleCount'] = len(rows)
            fixture_source.write_rows(root, descriptor, rows)
        report['raw']['os']['sampleCount'] = len(os_rows)
        planned = [(-1, 'baseline', schedule['points'][0]['offsetUs'], report['memoryPoints'][0]['startUs'])]
        for cycle, scheduled in enumerate(schedule['cycles']):
            boundaries = [row for row in report['raw']['boundaries'] if row['cycle'] == cycle]
            for phase, source, key in (('cycle-start', 'cycle-start', 'startOffsetUs'),
                                       ('idle-workload-slot-end', 'cycle-disposed', 'workloadEndOffsetUs')):
                planned.append((cycle, phase, scheduled[key], next(row['timeUs'] for row in boundaries if row['phase'] == source)))
            for index, phase in enumerate(('retained', 'released')):
                quiet = next(row for row in schedule['quietWindows'] if row['cycle'] == cycle and row['phase'] == phase)
                at = [row['timeUs'] for row in boundaries if row['phase'] == 'drain-start'][index]
                planned.append((cycle, f'{phase}-quiet-start', quiet['startOffsetUs'], at))
                point = next(row for row in report['memoryPoints'] if row['cycle'] == cycle and row['phase'] == f'after-close-{phase}')
                planned_point = next(row for row in schedule['points'] if row['cycle'] == cycle and row['phase'] == point['phase'])
                planned.append((cycle, point['phase'], planned_point['offsetUs'], point['startUs']))
        planned.append((8, 'final-quiet-start', schedule['quietWindows'][-1]['startOffsetUs'],
                        next(row['timeUs'] for row in report['raw']['boundaries'] if row['cycle'] == 8 and row['phase'] == 'drain-start')))
        report['scheduleObservations'] = [{'cycle': cycle, 'phase': phase, 'plannedOffsetUs': target,
            'actualOffsetUs': at - report['scheduleOriginUs'], 'lateUs': at - report['scheduleOriginUs'] - target}
            for cycle, phase, target, at in planned]
    gauges = []
    for index, (id, cycle, phase) in enumerate(checks.gauge_plan()):
        serialized = None
        if phase.endswith(('.before-gc', '.after-gc')):
            point = next(row for row in report['memoryPoints'] if row['cycle'] == cycle and row['phase'] == phase.rsplit('.', 1)[0])
            if phase.endswith('before-gc'):
                at = point['osBefore']['smapsEndUs'] + 1
                serialized = point['osAfter']['smapsEndUs'] + 1
            else:
                at = point['vmEndUs'] + 1
                serialized = point['osAfter']['smapsEndUs'] + 3
        elif phase == 'initialization':
            at = 1000
        else:
            drains = [row for row in report['raw']['boundaries'] if row['cycle'] == cycle and row['phase'] == 'drain-end']
            at = drains[1 if phase == 'released-quiet-end' else 0]['timeUs'] + 1
        gauges.append(gauge(index, id, cycle, phase, at, arm, serialized))
    report['ownershipGauges'] = gauges
    report['allocatorInitialization'] = {'startUs': 10, 'endUs': 11, 'statusCode': 0,
        'status': 'available', 'reason': None, 'clockDomain': checks.CLOCK}
    report['ownershipGaugeWrites'] = gauge_writes(report)
    report['raw']['ownershipGauges'] = {'file': 'ownership-gauges.jsonl', 'sampleCount': 52}
    fixture_source.write_rows(root, report['raw']['ownershipGauges'], gauges)
    write_allocator_captures(root, report)
    summary = copy.deepcopy(gauges[-1]['images'])
    summary.update(active=False, restorationComplete=True, stoppedUs=report['raw']['recordingStoppedUs'] + 1)
    report['imageObserverSummary'] = summary
    for point in report['memoryPoints']:
        prefix = point['phase'] if point['cycle'] < 0 else f'cycle-{point["cycle"]}.{point["phase"]}'
        point.update(gaugeBeforeId=prefix + '.before-gc', gaugeAfterId=prefix + '.after-gc')
        point['nativeCounters'] = {'status': 'recorded-in-owner-gauges', 'values': None,
                                   'gaugeBeforeId': point['gaugeBeforeId'], 'gaugeAfterId': point['gaugeAfterId']}
        start, end = point['vmStartUs'] + 1, point['vmEndUs'] - 1
        point['probeTelemetry'] = {'measurementStartUs': start, 'measurementEndUs': end,
            'responseMessages': 12, 'responseWireUtf8Bytes': 1000, 'largestResponseWireUtf8Bytes': 500,
            'responseScope': 'all VM-service responses during this checkpoint', 'retainedResponseBodies': 0,
            'gcGuarantee': 'request-only; dateLastServiceGC is recorded when available',
            'allocationProfiles': [{'startUs': start + 1 + index * 10, 'endUs': start + 5 + index * 10,
                'gcRequested': True, 'classCount': 50, 'dateLastServiceGC': 1,
                'profileReportedHeapUsage': 100, 'profileReportedHeapCapacity': 200,
                'profileReportedExternalUsage': 10} for index in range(2)]}
    build_sha = h(build)
    report['runtime'].update(buildProvenanceSha256=build_sha, sourceTreeSha256=build['sourceTreeSha256'])
    report['startupIdentityGate'] = {'schema': 'abc.memory-ownership-ready.v1', 'arm': arm,
        'hostPid': report['hostPid'], 'sourceCommit': fixture_source.COMMIT,
        'baseProductCommit': checks.BASE_COMMIT, 'buildSha256': build_sha, 'readyReceivedUs': 100}
    execution = {'schema': 'abc.memory-ownership-execution.v1', 'arm': arm, 'status': 'completed',
        'exitCode': 0, 'processInvocations': 1, 'ownedProcess': True,
        'timeoutSeconds': 900, 'runtimeTimeoutSeconds': 600, 'buildHelloTimeoutSeconds': 300,
        'sourceCommit': fixture_source.COMMIT, 'buildSha256': build_sha, 'scheduleSha256': checks.SCHEDULE_SHA256,
        'reportSha256': h(report), 'binarySha256': build['artifacts']['terraforge']['sha256'],
        'nativeEngineSha256': build['artifacts']['libabc_engine.so']['sha256'], 'allocatorHelperSha256': 'e' * 64,
        'sourceProvenanceSha256': 'd' * 64,
        'loadedExecutableSha256': build['artifacts']['terraforge']['sha256'],
        'loadedExecutableBytes': build['artifacts']['terraforge']['bytes'],
        'identityGatePassed': True, 'measurementReleased': True, 'helloMonotonicNs': 1_000_001,
        'identityGatePassedMonotonicNs': 1_000_002,
        'binaries': {**copy.deepcopy(build['artifacts']), 'libabc_native_owner_libc.so': {'sha256': 'e' * 64, 'bytes': 100}},
        'allocatorBuildSha256': build['ownershipProvenance']['allocatorBuildSha256'],
        'symbols': {'perfAbi': 1, 'ownerAbi': 1, 'requiredSymbolsVerified': True},
        'launchedMonotonicNs': 1_000_000, 'exitedMonotonicNs': 880_001_000_000,
        'processIdentity': {'pid': 123, 'uid': 1000, 'starttimeTicks': 700, 'processGroupId': 122,
                            'groupLeaderStarttimeTicks': 600, 'runnerPid': 120, 'runnerStarttimeTicks': 500}}
    return report, build, execution, schedule


class OwnershipChecksTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / 'product.raw'
        self.report, self.build, self.execution, self.schedule = fixture(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def validate(self, rehash=True):
        if rehash:
            self.execution['reportSha256'] = h(self.report)
        return checks.validate_arm(self.report, self.root, self.build, fixture_source.COMMIT,
            h(self.build), self.execution, self.schedule, checks.SCHEDULE_SHA256, h(self.report))

    def flush_gauges(self):
        fixture_source.write_rows(self.root, self.report['raw']['ownershipGauges'], self.report['ownershipGauges'])
        self.report['ownershipGaugeWrites'] = gauge_writes(self.report)

    def assert_rejected(self, expected=None):
        result = self.validate()
        self.assertFalse(result['evidenceValid'], result['errors'])
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['plateauEstablished'])
        self.assertFalse(result['stabilityEstablished'])
        if expected:
            self.assertIn(expected, '\n'.join(result['errors']))
        return result

    def test_valid_synthetic_product_is_integrity_only(self):
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['causalAttribution'], 'inconclusive')
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['plateauEstablished'])

    def test_valid_synthetic_idle_probe(self):
        self.root = Path(self.temporary.name) / 'probe.raw'
        self.report, self.build, self.execution, self.schedule = fixture(self.root, checks.ARMS[0])
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])

    def test_original_counter_off_policy_unchanged(self):
        root = Path(self.temporary.name) / 'original.raw'
        report, build, build_sha = fixture_source.fixture(root, generic=True)
        self.assertTrue(original.validate(report, root, build, fixture_source.COMMIT, build_sha)['evidenceValid'])
        build['cmake']['ABC_PERF_COUNTERS'] = 'ON'
        result = original.validate(report, root, build, fixture_source.COMMIT, build_sha)
        self.assertFalse(result['evidenceValid'])
        self.assertIn('native counter instrumentation unexpectedly enabled', '\n'.join(result['errors']))
        self.assertFalse(original.validate(self.report, self.root, self.build, fixture_source.COMMIT,
                                          h(self.build))['evidenceValid'])

    def test_missing_duplicate_reordered_gauges(self):
        saved = copy.deepcopy(self.report)
        for mutation in ('missing', 'duplicate', 'reorder'):
            with self.subTest(mutation=mutation):
                self.report = copy.deepcopy(saved)
                rows = self.report['ownershipGauges']
                if mutation == 'missing': rows.pop()
                if mutation == 'duplicate': rows[4] = copy.deepcopy(rows[3])
                if mutation == 'reorder': rows[4], rows[5] = rows[5], rows[4]
                self.flush_gauges()
                self.assert_rejected('gauge')

    def test_raw_gauge_tampering_even_with_rehashed_descriptor(self):
        self.report['ownershipGauges'][5]['fd']['fdEntriesEnumerated'] += 1
        self.assert_rejected('differs from raw journal')
        self.flush_gauges()
        self.assert_rejected('do not reconcile')

    def test_native_abi_mask_reserved_and_named_corruptions(self):
        saved = copy.deepcopy(self.report)
        mutations = [lambda n: n['rawWords'].__setitem__(12, 1),
                     lambda n: n.__setitem__('abiVersion', True),
                     lambda n: n.__setitem__('censoredMask', 1),
                     lambda n: n['values'].__setitem__('nativeTotalLiveBytes', 1),
                     lambda n: n['rawWords'].__setitem__(10, 5),
                     lambda n: n.__setitem__('status', 'symbols-unavailable')]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                self.report = copy.deepcopy(saved)
                mutate(self.report['ownershipGauges'][3]['worker']['owner']['native'])
                self.flush_gauges()
                self.assert_rejected()

    def test_optional_allocator_unsupported_is_null_and_inconclusive(self):
        for row in self.report['ownershipGauges']:
            row['allocator'].update(status='unsupported', reason='runtime-mallinfo2-unavailable',
                                    fields=dict.fromkeys(checks.MALLINFO_FIELDS, None))
        self.report['allocatorInitialization'].update(statusCode=2, status='unsupported', reason='runtime-mallinfo2-unavailable')
        self.flush_gauges()
        write_allocator_captures(self.root, self.report)
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertIn('allocator-unsupported', result['inconclusiveMetrics'])
        self.report['ownershipGauges'][0]['allocator']['fields']['arena'] = 0
        self.flush_gauges()
        self.assert_rejected('null')

    def test_fd_privacy_pid_categories_and_incomplete_fail(self):
        saved = copy.deepcopy(self.report)
        for field, value in (('target', '/private/path'), ('hostPid', 456),
                             ('fdEntriesEnumerated', 6), ('status', 'incomplete'), ('errorKind', 'secret path')):
            with self.subTest(field=field):
                self.report = copy.deepcopy(saved)
                self.report['ownershipGauges'][4]['fd'][field] = value
                self.flush_gauges()
                self.assert_rejected()

    def test_callback_replacement_failure_and_missing_restore_rejected(self):
        saved = copy.deepcopy(self.report)
        for field, value in (('callbacksIntact', False), ('everReplaced', True),
                             ('priorCallbackFailures', 1), ('observedHandleBalance', -1)):
            with self.subTest(field=field):
                self.report = copy.deepcopy(saved)
                self.report['ownershipGauges'][4]['images'][field] = value
                self.flush_gauges()
                self.assert_rejected()
        self.report = copy.deepcopy(saved)
        self.flush_gauges()
        self.report['imageObserverSummary']['restorationComplete'] = False
        self.assert_rejected('restoration')

    def test_preinstallation_image_disposals_allow_negative_observed_balance(self):
        for row in self.report['ownershipGauges'][4:]:
            row['images']['disposedHandles'] += 2
            row['images']['observedHandleBalance'] = -2
        self.report['imageObserverSummary']['disposedHandles'] += 3
        self.report['imageObserverSummary']['observedHandleBalance'] = -3
        self.flush_gauges()
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['stabilityEstablished'])

    def test_image_balance_float_and_boolean_rejected_in_gauge_and_summary(self):
        saved = copy.deepcopy(self.report)
        for location in ('gauge', 'summary'):
            for value in (0.0, False):
                with self.subTest(location=location, value=value):
                    self.report = copy.deepcopy(saved)
                    images = (self.report['ownershipGauges'][4]['images'] if location == 'gauge'
                              else self.report['imageObserverSummary'])
                    images['observedHandleBalance'] = value
                    self.flush_gauges()
                    self.assert_rejected('observedHandleBalance: signed integer required')

    def test_image_cumulative_counts_and_peak_still_reject_negative_values(self):
        saved = copy.deepcopy(self.report)
        for location in ('gauge', 'summary'):
            for field in ('createdHandles', 'disposedHandles', 'peakObservedHandleBalance'):
                with self.subTest(location=location, field=field):
                    self.report = copy.deepcopy(saved)
                    images = (self.report['ownershipGauges'][4]['images'] if location == 'gauge'
                              else self.report['imageObserverSummary'])
                    images[field] = -1
                    self.flush_gauges()
                    self.assert_rejected(f'{field}: integer >= 0 required')

    def test_fresh_worker_switch_and_probe_worker_initialization_rejected(self):
        self.report['ownershipGauges'][5]['worker']['workerGeneration'] = 2
        self.flush_gauges()
        self.assert_rejected('silently restarted')

    def test_slots_extra_profile_and_vm_response_body_rejected(self):
        saved = copy.deepcopy(self.report)
        for change in ('duplicate-slot', 'extra-slot', 'extra-profile', 'response-body', 'retained-body'):
            with self.subTest(change=change):
                self.report = copy.deepcopy(saved)
                point = self.report['memoryPoints'][2]
                if change == 'duplicate-slot': point['gaugeBeforeId'] = self.report['memoryPoints'][1]['gaugeBeforeId']
                if change == 'extra-slot': self.report['vmProbeCalls'] = 18
                if change == 'extra-profile': point['probeTelemetry']['allocationProfiles'].append(copy.deepcopy(point['probeTelemetry']['allocationProfiles'][-1]))
                if change == 'response-body': point['probeTelemetry']['responseBody'] = {'members': []}
                if change == 'retained-body': point['probeTelemetry']['retainedResponseBodies'] = 1
                self.assert_rejected()

    def test_group_profile_exit_bounds_are_not_fixed_rpc_count(self):
        point = self.report['memoryPoints'][2]
        point['vm']['sampledIsolateGroups'] = 1
        point['vm']['exitedIsolateGroupsDuringProbe'] = 1
        self.assertTrue(self.validate()['evidenceValid'])
        point['probeTelemetry']['allocationProfiles'].pop()
        self.assertTrue(self.validate()['evidenceValid'])

    def test_corrupt_product_lifecycle_remains_rejected(self):
        self.report['cycles'][2]['reopenPreservedSelectedPixels'] = False
        self.assert_rejected('reopen')

    def test_timestamp_serialization_and_libc_vm_order_rejected(self):
        self.report['ownershipGauges'][2]['allocator']['startUs'] = self.report['memoryPoints'][0]['vmStartUs']
        self.flush_gauges()
        self.assert_rejected()

    def test_binary_mode_and_actual_report_hash_rejected(self):
        saved = copy.deepcopy(self.execution)
        for field, value in (('binarySha256', 'f' * 64), ('processInvocations', 2),
                             ('processInvocations', True), ('sourceCommit', checks.BASE_COMMIT)):
            with self.subTest(field=field, value=value):
                self.execution = copy.deepcopy(saved)
                self.execution[field] = value
                self.assert_rejected()
        self.execution = copy.deepcopy(saved)
        self.execution['reportSha256'] = 'f' * 64
        self.assertFalse(self.validate(rehash=False)['evidenceValid'])

    def test_historical_schedule_and_source_rejected(self):
        self.schedule['source']['commit'] = '51bc8eaa76b145b0d9bec3c95977779af43b676c'
        self.assert_rejected('schedule document differs')

    def test_raw_missing_hash_corruption_duplicate_json_and_extra_file(self):
        descriptor = self.report['raw']['ownershipGauges']
        path = self.root / descriptor['file']
        path.write_bytes(path.read_bytes() + b'{}\n')
        self.assert_rejected()
        self.flush_gauges()
        path.write_bytes(path.read_bytes().replace(b'"id":', b'"id":"fake","id":', 1))
        descriptor.update(sha256=checks.digest(path), bytes=path.stat().st_size)
        self.assert_rejected('duplicate JSON key')
        self.flush_gauges()
        (self.root / 'unreported.jsonl').write_bytes(b'{}\n')
        self.assert_rejected('Unreferenced')

    def test_strict_json_rejects_duplicate_keys_and_nonfinite(self):
        for payload in ('{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}'):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                checks.strict_json(payload)

    def test_fixed_world_roi_trigger_and_on_flags_required(self):
        saved = copy.deepcopy(self.report)
        for field, value in (('worldWidth', 120), ('displayRegion', {'x': 0, 'y': 0, 'width': 32, 'height': 32}),
                             ('trigger', {'x': 1, 'y': 1, 'mask': 15, 'direct': True})):
            with self.subTest(field=field):
                self.report = copy.deepcopy(saved)
                self.report['cycles'][0][field] = value
                self.assert_rejected()
        self.report = copy.deepcopy(saved)
        self.build['cmake']['ABC_OWNER_DIAGNOSTICS'] = 'OFF'
        self.assert_rejected('must be explicitly enabled')

    def test_raw_allocator_status_words_and_nulls_reconcile(self):
        descriptor = self.report['raw']['allocatorCaptures']
        path = self.root / descriptor['file']
        rows = [json.loads(line) for line in path.read_bytes().splitlines()]
        rows[3]['rawWords'][6] = '99'
        fixture_source.write_rows(self.root, descriptor, rows)
        self.assert_rejected('raw metric values differ')
        write_allocator_captures(self.root, self.report)
        descriptor = self.report['raw']['allocatorCaptures']
        rows = [json.loads(line) for line in path.read_bytes().splitlines()]
        rows[3]['rawWords'][6] = '-1'
        fixture_source.write_rows(self.root, descriptor, rows)
        self.assert_rejected('unsigned word malformed')

    def test_ffi_cleanup_uncertainty_cannot_be_labeled_certain(self):
        for row in self.report['ownershipGauges'][3:]:
            host = row['worker']['owner']['host']
            host.update(ffiReadWindowAllocatedBytes=1, ffiReadWindowOutstandingBytes=1,
                        ffiReadWindowCleanupFailures=1, ffiReadWindowAccountingCertain=False)
        self.flush_gauges()
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertIn('ffi-read-cleanup-uncertain', result['inconclusiveMetrics'])
        self.report['ownershipGauges'][4]['worker']['owner']['host']['ffiReadWindowAccountingCertain'] = True
        self.flush_gauges()
        self.assert_rejected('cleanup ambiguity')

    def test_censored_native_bytes_preserved_as_inconclusive(self):
        for row in self.report['ownershipGauges'][3:]:
            n = row['worker']['owner']['native']
            for index in (2, 3, 5): n['rawWords'][index] = checks.UINT32_MAX
            n['rawWords'][11] = n['censoredMask'] = 11
            n['values'] = dict(zip(checks.NATIVE_FIELDS, n['rawWords'][2:11]))
        self.flush_gauges()
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertIn('native-uint32-censored', result['inconclusiveMetrics'])

    def test_unavailable_worker_is_null_and_never_synthetic_zero(self):
        self.root = Path(self.temporary.name) / 'probe.raw'
        self.report, self.build, self.execution, self.schedule = fixture(self.root, checks.ARMS[0])
        self.report['ownershipGauges'][3]['worker']['owner'] = {'hostSessionCount': 0}
        self.flush_gauges()
        self.assert_rejected('unavailable/null')

    def test_response_body_hidden_at_point_or_report_rejected(self):
        self.report['memoryPoints'][0]['allocationProfile'] = {'members': []}
        self.assert_rejected('VM point')
        del self.report['memoryPoints'][0]['allocationProfile']
        self.report['imageResources'] = []
        self.assert_rejected('outside scalar')

    def group_fixture(self):
        probe_root = Path(self.temporary.name) / 'group-probe.raw'
        report, build, execution, schedule = fixture(probe_root, checks.ARMS[0])
        probe = checks.validate_arm(report, probe_root, build, fixture_source.COMMIT,
                                   h(build), execution, schedule, checks.SCHEDULE_SHA256, h(report))
        self.assertTrue(probe['evidenceValid'], probe['errors'])
        self.execution['launchedMonotonicNs'] = probe['execution']['exitedMonotonicNs'] + 1
        self.execution['exitedMonotonicNs'] = self.execution['launchedMonotonicNs'] + 880_000_000_000
        self.execution['helloMonotonicNs'] = self.execution['launchedMonotonicNs'] + 1
        self.execution['identityGatePassedMonotonicNs'] = self.execution['launchedMonotonicNs'] + 2
        self.execution['processIdentity'].update(starttimeTicks=900, groupLeaderStarttimeTicks=800)
        product = self.validate()
        self.assertTrue(product['evidenceValid'], product['errors'])
        group = {'schema': 'abc.memory-ownership-group.v1', 'status': 'completed',
                 'sourceCommit': fixture_source.COMMIT, 'sourceProvenanceSha256': 'd' * 64,
                 'scheduleSha256': checks.SCHEDULE_SHA256, 'armOrder': list(checks.ARMS),
                 'executions': [probe['execution'], product['execution']]}
        return group, [probe, product]

    def test_two_fresh_serial_process_group_validates(self):
        group, results = self.group_fixture()
        result = checks.validate_group(group, results)
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertFalse(result['stabilityEstablished'])

    def test_group_reused_process_reordered_arms_and_changed_binaries_rejected(self):
        base, results = self.group_fixture()
        for mutation in ('same-process', 'overlap', 'order', 'native-binary', 'libapp-binary',
                         'renderer', 'third-arm', 'failed-arm', 'different-runner'):
            with self.subTest(mutation=mutation):
                group, arms = copy.deepcopy(base), copy.deepcopy(results)
                if mutation == 'same-process': arms[1]['execution']['processIdentity'] = copy.deepcopy(arms[0]['execution']['processIdentity'])
                if mutation == 'overlap': arms[1]['execution']['launchedMonotonicNs'] = arms[0]['execution']['launchedMonotonicNs']
                if mutation == 'order': arms.reverse()
                if mutation == 'native-binary': arms[1]['execution']['nativeEngineSha256'] = 'f' * 64
                if mutation == 'libapp-binary': arms[1]['binaryDigests']['libapp.so'] = 'f' * 64
                if mutation == 'renderer': arms[1]['runtime']['renderer'] = 'other'
                if mutation == 'third-arm': arms.append(copy.deepcopy(arms[1]))
                if mutation == 'failed-arm': arms[1]['evidenceValid'] = False
                if mutation == 'different-runner': arms[1]['execution']['processIdentity']['runnerPid'] = 888
                group['executions'] = [arm['execution'] for arm in arms]
                result = checks.validate_group(group, arms)
                self.assertFalse(result['evidenceValid'], mutation)

    def test_cli_exact_bytes_success_and_corrupt_input_exit_failure(self):
        folder = Path(self.temporary.name)
        paths = {key: folder / f'{key}.json' for key in ('report', 'build', 'execution', 'output')}
        for key, value in (('report', self.report), ('build', self.build), ('execution', self.execution)):
            paths[key].write_bytes(encoded(value))
        args = [str(paths['report']), '--raw-directory', str(self.root), '--build', str(paths['build']),
                '--execution', str(paths['execution']), '--expected-commit', fixture_source.COMMIT,
                '--schedule', str(Path(checks.__file__).with_name('memory_ownership_schedule.json')),
                '--output', str(paths['output'])]
        self.assertEqual(checks.main(args), 0)
        output = checks.load_json(paths['output'])
        self.assertEqual(len(output['observerOverhead']['rows']), 52)
        self.assertEqual(output['observerOverhead']['summary']['serializedRecordBytes']['sampleCount'], 52)
        paths['report'].write_bytes(paths['report'].read_bytes() + b' ')
        self.assertEqual(checks.main(args), 1)
        self.assertIn('report/schedule identity differs', '\n'.join(checks.load_json(paths['output'])['errors']))

    def test_owner_source_macro_and_overlay_hash_mismatch_rejected(self):
        self.build['actualOwnerCompilationTargets']['terra_circuit_world.c.o']['DEFINES'] = ''
        self.report['runtime']['buildProvenanceSha256'] = self.execution['buildSha256'] = h(self.build)
        self.assert_rejected('owner macro missing')
        self.build['actualOwnerCompilationTargets']['terra_circuit_world.c.o']['DEFINES'] = '-DABC_OWNER_DIAGNOSTICS=1'
        self.report['runtime']['buildProvenanceSha256'] = self.execution['buildSha256'] = h(self.build)
        self.execution['sourceProvenanceSha256'] = 'f' * 64
        self.assert_rejected('source-overlay/helper provenance')

    def test_partial_gauges_and_fewer_allocator_captures_rejected(self):
        self.report['ownershipGauges'][3]['partial'] = True
        self.flush_gauges()
        self.assert_rejected('ownership gauge')
        del self.report['ownershipGauges'][3]['partial']
        self.flush_gauges()
        descriptor = self.report['raw']['allocatorCaptures']
        rows = [json.loads(line) for line in (self.root / descriptor['file']).read_bytes().splitlines()][:-1]
        descriptor['sampleCount'] = 51
        fixture_source.write_rows(self.root, descriptor, rows)
        self.assert_rejected('52 raw allocator captures')

    def test_timeout_expansion_fails_without_new_measurements(self):
        self.execution['runtimeTimeoutSeconds'] = 1200
        self.assert_rejected('timeout budgets differ')

    def test_preserved_frame_and_os_journal_corruption_rejected(self):
        descriptor = self.report['raw']['frameChunks'][0]
        rows = [json.loads(line) for line in (self.root / descriptor['file']).read_bytes().splitlines()]
        next(row for row in rows if row['type'] == 'frame')['sequence'] = 99
        fixture_source.write_rows(self.root, descriptor, rows)
        self.assert_rejected('frame sequence')

    def test_symlink_raw_evidence_and_empty_profile_list_rejected(self):
        descriptor = self.report['raw']['ownershipGauges']
        path = self.root / descriptor['file']
        target = self.root.parent / 'copied.jsonl'
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_rejected('unsafe raw file')
        path.unlink()
        self.flush_gauges()
        self.report['memoryPoints'][0]['probeTelemetry']['allocationProfiles'] = []
        self.assert_rejected('isolate groups')

    def test_boolean_and_float_metadata_cannot_impersonate_integers(self):
        saved = copy.deepcopy(self.report)
        for mutation in ('gauge-cycle', 'native-value', 'summary-count', 'worker-budget'):
            with self.subTest(mutation=mutation):
                self.report = copy.deepcopy(saved)
                if mutation == 'gauge-cycle': self.report['ownershipGauges'][3]['cycle'] = False
                if mutation == 'native-value': self.report['ownershipGauges'][3]['worker']['owner']['native']['values']['nativeTotalLiveBytes'] = False
                if mutation == 'summary-count': self.report['imageObserverSummary']['priorCallbackFailures'] = False
                if mutation == 'worker-budget': self.report['expectedNativeWorkers'] = True
                self.flush_gauges()
                self.assert_rejected('integer')

    def test_missing_required_sections_fail_without_crashing(self):
        saved = copy.deepcopy(self.report)
        for section, key in (('report', 'imageObserverSummary'), ('gauge', 'mainStartUs'),
                             ('fd', 'categories'), ('native', 'rawWords'), ('point', 'probeTelemetry')):
            with self.subTest(section=section, key=key):
                self.report = copy.deepcopy(saved)
                target = {'report': self.report, 'gauge': self.report['ownershipGauges'][3],
                          'fd': self.report['ownershipGauges'][3]['fd'],
                          'native': self.report['ownershipGauges'][3]['worker']['owner']['native'],
                          'point': self.report['memoryPoints'][0]}[section]
                del target[key]
                self.flush_gauges()
                self.assert_rejected()

    def test_optional_fd_unsupported_is_explicit_inconclusive_not_zero(self):
        for row in self.report['ownershipGauges']:
            fd = row['fd']
            fd.update(status='unsupported', errorKind='platform', errorCode=None)
            for name in ('enumerationEndUs', 'classificationStartUs', 'fdEntriesEnumerated',
                         'categories', 'vanished', 'unreadable', 'ignoredNonnumeric'):
                fd[name] = None
        self.flush_gauges()
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertIn('fd-unsupported', result['inconclusiveMetrics'])
        self.report['ownershipGauges'][0]['fd']['fdEntriesEnumerated'] = 0
        self.flush_gauges()
        self.assert_rejected('must remain null')

    def refresh_build_identity(self):
        metadata = self.build['ownershipProvenance']
        metadata['allocatorBuildSha256'] = helper_build_hash(metadata['allocatorBuild'])
        self.execution['allocatorBuildSha256'] = metadata['allocatorBuildSha256']
        self.execution['buildSha256'] = self.report['runtime']['buildProvenanceSha256'] = h(self.build)
        self.report['startupIdentityGate']['buildSha256'] = h(self.build)

    def test_allocator_build_source_header_runtime_identity_corruption_rejected(self):
        saved = copy.deepcopy(self.build)
        for mutation in ('source', 'header', 'runtime-scope', 'helper-binary', 'abi', 'package'):
            with self.subTest(mutation=mutation):
                self.build = copy.deepcopy(saved)
                helper = self.build['ownershipProvenance']['allocatorBuild']
                if mutation == 'source': helper['source']['sha256'] = 'f' * 64
                if mutation == 'header': helper['mallocHeader']['sha256'] = 'f' * 64
                if mutation == 'runtime-scope': helper['runtime']['scope'] = 'measured-Dart-process'
                if mutation == 'helper-binary': helper['helperSha256'] = 'f' * 64
                if mutation == 'abi': helper['runtime']['abiContractMatched'] = False
                if mutation == 'package': helper['runtime']['package']['metadata'] = ''
                self.refresh_build_identity()
                self.assert_rejected()

    def test_unreviewed_libc_family_is_explicitly_inconclusive(self):
        runtime = self.build['ownershipProvenance']['allocatorBuild']['runtime']
        runtime.update(runtimeLibcVersion='2.42', inspectedUpstreamFamily=False, sourceReviewRequired=True)
        for row in self.report['ownershipGauges']:
            row['allocator']['glibcVersion'] = '2.42'
        self.refresh_build_identity()
        self.flush_gauges()
        write_allocator_captures(self.root, self.report)
        result = self.validate()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertIn('libc-source-family-unreviewed', result['inconclusiveMetrics'])

    def test_actual_gauge_write_bytes_spans_and_initialization_are_required(self):
        saved = copy.deepcopy(self.report)
        for mutation in ('missing-write', 'write-bytes', 'early-write', 'failed-write', 'late-initialization', 'changed-support'):
            with self.subTest(mutation=mutation):
                self.report = copy.deepcopy(saved)
                if mutation == 'missing-write': self.report['ownershipGaugeWrites'].pop()
                if mutation == 'write-bytes': self.report['ownershipGaugeWrites'][0]['bytes'] += 1
                if mutation == 'early-write': self.report['ownershipGaugeWrites'][1]['startUs'] = self.report['memoryPoints'][0]['vmEndUs']
                if mutation == 'failed-write': self.report['ownershipGaugeWrites'][1]['status'] = 'failed'
                if mutation == 'late-initialization': self.report['allocatorInitialization']['endUs'] = self.report['scheduleOriginUs'] + 1
                if mutation == 'changed-support': self.report['allocatorInitialization'].update(statusCode=2, status='unsupported', reason='runtime-mallinfo2-unavailable')
                self.assert_rejected()

    def test_unreferenced_non_json_resource_is_not_silently_retained(self):
        (self.root / 'unexpected-resource.bin').write_bytes(b'synthetic forbidden extra artifact')
        self.assert_rejected('Unreferenced raw files/resources')

    def test_measurement_must_follow_owned_binary_ready_acknowledgement(self):
        saved = copy.deepcopy(self.report), copy.deepcopy(self.execution)
        for mutation in ('released-false', 'gate-before-hello', 'wrong-ready-build', 'gauge-before-ready', 'binary-copy'):
            with self.subTest(mutation=mutation):
                self.report, self.execution = copy.deepcopy(saved)
                if mutation == 'released-false': self.execution['measurementReleased'] = False
                if mutation == 'gate-before-hello': self.execution['identityGatePassedMonotonicNs'] = 0
                if mutation == 'wrong-ready-build': self.report['startupIdentityGate']['buildSha256'] = 'f' * 64
                if mutation == 'gauge-before-ready': self.report['startupIdentityGate']['readyReceivedUs'] = 100_000
                if mutation == 'binary-copy': self.execution['binaries']['libapp.so']['sha256'] = 'f' * 64
                self.assert_rejected()

    def test_loaded_owned_child_executable_must_match_archived_build(self):
        for field, value in (('loadedExecutableSha256', 'f' * 64), ('loadedExecutableBytes', 999)):
            with self.subTest(field=field):
                saved = self.execution[field]
                self.execution[field] = value
                self.assert_rejected('actual owned child executable')
                self.execution[field] = saved


if __name__ == '__main__':
    unittest.main()
