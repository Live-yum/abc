#!/usr/bin/env python3
"""Synthetic full-evidence/tampering tests; no Flutter, world or network run.

The fixture extends the unchanged OS-only fixture. Its tiny fabricated frame,
process, allocator and helper records are unit-test values, never observations.
"""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import computer_memory_checks_test as original_fixture
import memory_probe_control_validate_test as control_fixture
import native_retention_validate as checks

encoded, write_rows = original_fixture.encoded, original_fixture.write_rows
COMMIT = original_fixture.COMMIT


def put_json(root, name, value):
    path = root / name
    path.write_bytes(encoded(value))
    return checks.digest(path)


def sample(index, at):
    return {'schema': 'abc.native-retention-mallinfo2.v1', 'sequence': index,
            'status': 'available', 'reason': None, 'startUs': at, 'endUs': at + 1,
            'clockDomain': checks.DART_CLOCK, 'atomic': False, 'sizeTBytes': 8,
            'mallinfo2StructBytes': 80, 'glibcVersion': '2.39',
            'fields': {**dict.fromkeys(checks.protocol.FIELDS, 0), 'arena': 160,
                       'uordblks': 120, 'fordblks': 40}}


def refresh_provenance(root, report, build):
    helper = checks.load_json(root / 'helper-build.json')
    links = {key: checks.digest(root / name) for key, name in (
        ('sourceSha256', 'source.json'), ('derivationSha256', 'derivation.json'),
        ('helperBuildSha256', 'helper-build.json'))}
    links.update(helperSha256=helper['helperSha256'],
                 nativeEngineSha256=build['artifacts']['libabc_engine.so']['sha256'])
    build['nativeRetentionProvenance'] = links
    report['runtime']['nativeRetentionProvenance'] = links.copy()
    build['sourceTreeSha256'] = hashlib.sha256(json.dumps(build['sourceFilesSha256'],
        sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    report['runtime']['sourceTreeSha256'] = build['sourceTreeSha256']
    build_sha = hashlib.sha256(encoded(build)).hexdigest()
    report['runtime']['buildProvenanceSha256'] = build_sha
    return build_sha


def provenance_fixture(root, report, build):
    repo = Path(checks.__file__).resolve().parents[2]
    for name in checks.source_names():
        build['sourceFilesSha256'][name] = checks.digest(repo / name)
    overlay = {name: {'mode': '100644', 'gitBlob': 'd' * 40, 'sha256': value,
                       'bytes': (repo / name).stat().st_size}
               for name, value in build['sourceFilesSha256'].items() if name in checks.source_names()}
    product = {name: {'mode': '100644', 'gitBlob': 'e' * 40, 'sha256': value, 'bytes': 100}
               for name, value in build['sourceFilesSha256'].items() if name not in overlay}
    patch = root / 'diagnostic-overlay.patch'
    patch.write_bytes(b'synthetic unit-test patch, not a runnable product\n')
    derivation = {'schema': 'abc.native-retention-derivation.v1',
                  'baseCommit': checks.PRODUCT_COMMIT, 'baseTree': checks.PRODUCT_TREE,
                  'derivedCommit': COMMIT, 'derivedTree': 'f' * 40, 'overlaySourceCommit': '1' * 40,
                  'patchFile': patch.name, 'patchSha256': checks.digest(patch),
                  'schedule': 'tool/perf/memory_probe_control_schedule.json',
                  'scheduleSha256': checks.SCHEDULE_SHA256, 'changedPaths': sorted(overlay),
                  'overlayFiles': overlay, 'overlayFilesSha256': {name: item['sha256'] for name, item in overlay.items()},
                  'productChangesAllowed': False, 'localCommitOnly': True}
    derivation_sha = put_json(root, 'derivation.json', derivation)
    source = {**derivation, 'schema': 'abc.native-retention-source.v1', 'productFiles': product,
              'productPathsUnchanged': True, 'derivationSha256': derivation_sha}
    put_json(root, 'source.json', source)
    helper_root = root / 'helper'
    helper_root.mkdir()
    binary = helper_root / 'libabc_native_retention_probe.so'
    binary.write_bytes(b'unit-test bytes, not executable\n')
    compiler = {'path': '/usr/bin/cc', 'sha256': 'a' * 64, 'version': 'unit-test compiler',
                'target': 'unit-test', 'package': {'status': 'unavailable', 'reason': 'unit-test'}}
    header = {'path': '/usr/include/malloc.h', 'sha256': 'b' * 64, 'bytes': 100,
              'package': {'status': 'unavailable', 'reason': 'unit-test'}}
    runtime = {'runtimeLibcVersion': '2.39', 'headerGlibcMajor': 2, 'headerGlibcMinor': 39,
               'sizeTBytes': 8, 'mallinfo2StructBytes': 80, 'helperStatus': 0,
               'abiContractMatched': True, 'libcPath': '/usr/lib/libc.so.6', 'libcSha256': 'c' * 64,
               'package': {'status': 'unavailable', 'reason': 'unit-test'},
               'scope': 'fresh-native-build-contract-process-only',
               'inspectedUpstreamFamily': True, 'sourceReviewRequired': False}
    commands = []
    for name in ('compiler-version', 'compiler-target', 'compile-helper',
                 'compile-build-contract', 'run-build-contract'):
        row = {'name': name, 'argv': ['/usr/bin/cc', name], 'returnCode': 0, 'timeoutSeconds': 60}
        for stream in ('stdout', 'stderr'):
            path = helper_root / (name + '.' + stream + '.txt')
            path.write_bytes(b'synthetic test metadata\n')
            row[stream + 'File'], row[stream + 'Sha256'] = path.name, checks.digest(path)
        commands.append(row)
    contract = {}
    for key, name in (('source', 'native-retention-build-contract.c'),
                      ('executable', 'native-retention-build-contract')):
        path = helper_root / name
        path.write_bytes(b'synthetic ABI contract test data\n')
        contract[key + 'File'], contract[key + 'Sha256'] = name, checks.digest(path)
    dependency = helper_root / 'helper.d'
    dependency.write_bytes(b'synthetic unit-test dependency manifest\n')
    helper = {'schema': 'abc.native-retention-helper-build.v1', 'status': 'built',
              'helperFile': binary.name, 'helperPath': str(binary),
              'dependencyFile': dependency.name, 'dependencySha256': checks.digest(dependency),
              'helperSha256': checks.digest(binary), 'helperBytes': binary.stat().st_size,
              'source': {'path': 'tool/perf/native_retention_probe.c',
                         'sha256': overlay['tool/perf/native_retention_probe.c']['sha256']},
              'compiler': compiler, 'mallocHeader': header,
              'headers': {header['path']: {key: header[key] for key in ('sha256', 'bytes')}},
              'runtime': runtime, 'commands': commands,
              'helperCommand': commands[2]['argv'], 'buildContract': contract,
              'outsideApplicationCheckout': True, 'applicationLaunched': False,
              'downloadedDependencies': False}
    put_json(root, 'helper-build.json', helper)
    return refresh_provenance(root, report, build)


def original_reports(root, report, build):
    report['runtime']['nativeRetentionExecution'] = {
        'sourceUnchangedAfterRun': True, 'helperUnchangedAfterRun': True,
        'productBinariesUnchangedAfterRun': True, 'buildExitCode': 0,
        'driverExitCode': 0, 'processInvocations': 1}
    raw_target = copy.deepcopy(report)
    raw_target.pop('externalOs')
    for key in ('buildProvenanceSha256', 'sourceTreeSha256', 'provenanceAttachment',
                'nativeRetentionProvenance', 'nativeRetentionExecution', 'rawTargetReport'):
        raw_target['runtime'].pop(key, None)
    name = 'native-retention.raw-report.json'
    digest = put_json(root, name, raw_target)
    report['runtime']['rawTargetReport'] = {'file': name, 'sha256': digest}
    compiler_build = copy.deepcopy(build)
    compiler_build.pop('nativeRetentionProvenance')
    put_json(root, 'native-retention.compiler-build.json', compiler_build)


def fixture(root):
    report, build, _, external = control_fixture.fixture(root, 'product-os-only')
    report.update(schema='abc.native-retention.v1', arm=checks.ARM,
                  baseProductCommit=checks.PRODUCT_COMMIT, plannedAllocatorBoundaries=18,
                  plannedAllocatorCalls=37, allocatorBufferBytes=128, warmupCycles=[0, 1, 2, 3],
                  repeatCycles=[4, 5, 6, 7], plateauEstablished=False)
    for index, cycle in enumerate(report['cycles']):
        cycle['predeclaredRole'] = 'warm-up-variant' if index < 4 else 'single-repeat-variant'
    external.update(arm=checks.ARM, baseProductCommit=checks.PRODUCT_COMMIT)
    rows = [json.loads(line) for line in (root.parent / external['file']).read_text().splitlines()]
    for row in rows:
        if 'metadata' in row:
            row['metadata']['controlArm'] = checks.ARM
    for endpoint in report['externalEndpoints']:
        endpoint['os']['metadata']['controlArm'] = checks.ARM
    write_rows(root.parent, external, rows)
    calls = [sample(0, report['externalEndpoints'][0]['dartTimeUs'] - 100)]
    categories = []
    for endpoint in report['externalEndpoints']:
        if not checks.protocol.allocator_boundary(endpoint['phase']):
            endpoint.update(allocatorBefore=None, allocatorAfter=None, mappingCategories=None)
            continue
        before = sample(len(calls), endpoint['dartTimeUs'] - 10)
        after = sample(len(calls) + 1, endpoint['dartTimeUs'] + 20)
        calls.extend([before, after])
        row = {'schema': 'abc.native-retention-categories.v1', 'sequence': len(categories),
               'externalOsSequence': endpoint['os']['sequence'], 'phase': endpoint['phase'],
               'metadata': {**{key: endpoint[key] for key in checks.REQUEST_FIELDS}, 'controlArm': checks.ARM},
               'clockDomain': checks.PYTHON_CLOCK, 'atomic': False,
               'startNs': endpoint['os']['smapsEndNs'] + 1,
               'endNs': endpoint['os']['smapsEndNs'] + 2,
               **dict.fromkeys(checks.CATEGORY_REQUIRED + checks.CATEGORY_OPTIONAL, 1024)}
        endpoint.update(allocatorBefore=before, allocatorAfter=after, mappingCategories=row)
        categories.append(row)
    report.update(allocatorInitialization=calls[0], allocatorCalls=calls,
                  allocatorJournal={'file': 'native-retention-probes.jsonl', 'count': 37})
    write_rows(root.parent, report['allocatorJournal'], calls)
    external['retentionCategories'] = {'file': 'native-retention-categories.jsonl', 'count': 18,
                                       'complete': True, 'rawAddressesOrPaths': False}
    write_rows(root.parent, external['retentionCategories'], categories)
    build_sha = provenance_fixture(root.parent, report, build)
    original_reports(root.parent, report, build)
    return report, build, build_sha, external


class RetentionChecksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'native-retention.raw'
        self.report, self.build, self.build_sha, self.external = fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def run_validation(self):
        if getattr(self, 'update_original_fixtures', True):
            original_reports(self.root.parent, self.report, self.build)
        return checks.validate(self.report, self.root, self.build, COMMIT,
                               self.build_sha, self.external, self.root.parent)

    def assert_failed(self, message):
        result = self.run_validation()
        self.assertFalse(result['evidenceValid'], result)
        self.assertIn(message, '\n'.join(result['errors']))
        self.assertEqual(result['status'], 'failed')
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['plateauEstablished'])
        self.assertFalse(result['improvementEstablished'])
        self.assertFalse(result['attribution']['available'])
        return result

    edit_chunk = control_fixture.ControlChecksTest.edit_chunk
    edit_external = control_fixture.ControlChecksTest.edit_external

    def rewrite_allocator(self):
        write_rows(self.root.parent, self.report['allocatorJournal'], self.report['allocatorCalls'])

    def rewrite_categories(self):
        rows = [point['mappingCategories'] for point in self.report['externalEndpoints']
                if point['mappingCategories'] is not None]
        write_rows(self.root.parent, self.external['retentionCategories'], rows)

    def edit_manifest(self, name, change, *, refresh=True):
        value = checks.load_json(self.root.parent / name)
        change(value)
        put_json(self.root.parent, name, value)
        if refresh:
            self.build_sha = refresh_provenance(self.root.parent, self.report, self.build)

    def selected(self):
        return [row for row in self.report['externalEndpoints'] if row['mappingCategories'] is not None]

    def test_complete_observation_retains_all_frames_calls_and_matching_pairs(self):
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['status'], 'validated-retention-observation')
        self.assertEqual(result['schema'], checks.SCHEMA)
        self.assertEqual(result['arm'], 'native-retention')
        self.assertEqual(result['baseProductCommit'], checks.PRODUCT_COMMIT)
        self.assertEqual(result['raw']['receivedFrameCount'], 16)
        self.assertEqual(result['externalOs']['acknowledgedEndpoints'], 79)
        self.assertEqual(result['retention']['allocatorCalls'], 37)
        self.assertEqual(result['retention']['matchedBoundaryPairs'], 18)
        self.assertEqual([row['cycles'] for row in result['retention']['sameVariantPairs']],
                         [[0, 4], [1, 5], [2, 6], [3, 7]])
        self.assertIsNone(result['measurements']['baseline']['vm.heapCapacityBytes'])
        self.assertGreater(result['raw']['recordCounts']['dispatch'], 0)
        self.assertFalse(result['acceptanceEvidence'])
        self.assertFalse(result['plateauEstablished'])
        self.assertFalse(result['improvementEstablished'])
        self.assertFalse(result['attribution']['ownershipEstablished'])

    def test_old_validators_reject_new_identity(self):
        result = checks.control.validate(self.report, self.root, self.build, COMMIT,
                                         self.build_sha, self.external, self.root.parent)
        self.assertFalse(result['evidenceValid'])
        self.assertIn('unknown control report schema', '\n'.join(result['errors']))

    def test_product_operation_body_checks_remain(self):
        self.report['cycles'][3]['physicalPulseDelta'] = 4095
        self.assert_failed('real fixed pulse evidence differs')

    def test_product_vm_fake_zero_cannot_pass(self):
        self.report['memoryPoints'][0]['vm'] = {'heapUsedBytes': 0}
        self.assert_failed('must be null')

    def test_product_probe_invocation_cannot_pass(self):
        self.report['memoryPoints'][0]['vmProbeInvoked'] = True
        self.assert_failed('zero VM invocations')

    def test_product_shortened_slot_cannot_pass(self):
        self.report['memoryPoints'][0]['slotEndUs'] = self.report['memoryPoints'][0]['slotStartUs']
        self.assert_failed('nominal VM slot was compressed')

    def test_old_product_cannot_be_relabelled_as_new_product(self):
        self.report['baseProductCommit'] = checks.control.BASE_COMMIT
        self.assert_failed('native retention product identity differs')

    def test_old_external_arm_cannot_be_relabelled(self):
        self.external['arm'] = 'product-os-only'
        self.assert_failed('owned-process control descriptor differs')

    def test_native_allocator_hash_tamper(self):
        path = self.root.parent / self.report['allocatorJournal']['file']
        path.write_bytes(path.read_bytes().replace(b'"arena":160', b'"arena":161', 1))
        self.assert_failed('allocator report differs from raw journal')

    def test_native_allocator_descriptor_hash_tamper(self):
        self.report['allocatorJournal']['sha256'] = '0' * 64
        self.assert_failed('retention raw bytes/SHA-256 mismatch')

    def test_native_allocator_report_tamper_with_valid_hash_still_fails_accounting(self):
        self.report['allocatorCalls'][2]['fields']['arena'] += 1
        self.rewrite_allocator()
        self.assert_failed('arena accounting identity mismatch')

    def test_allocator_missing_raw_initialization(self):
        rows = self.report['allocatorCalls'][1:]
        write_rows(self.root.parent, self.report['allocatorJournal'], rows)
        self.assert_failed('allocator report differs from raw journal')

    def test_allocator_missing_last_call(self):
        self.report['allocatorCalls'].pop()
        self.rewrite_allocator()
        self.assert_failed('Complete raw allocator call list required')

    def test_allocator_raw_extra_row(self):
        write_rows(self.root.parent, self.report['allocatorJournal'],
                   self.report['allocatorCalls'] + [self.report['allocatorCalls'][-1]])
        self.assert_failed('retention raw has extra rows')

    def test_allocator_sequence_boolean(self):
        self.report['allocatorCalls'][0]['sequence'] = False
        self.rewrite_allocator()
        self.assert_failed('allocator sequence: integer')

    def test_allocator_calls_cannot_overlap(self):
        self.report['allocatorCalls'][1]['startUs'] = self.report['allocatorCalls'][0]['startUs']
        self.rewrite_allocator()
        self.assert_failed('allocator call timestamps overlap')

    def test_allocator_initialization_after_hello(self):
        at = self.report['externalEndpoints'][0]['dartTimeUs']
        self.report['allocatorCalls'][0].update(startUs=at, endUs=at + 1)
        self.rewrite_allocator()
        self.assert_failed('initialization must precede hello')

    def test_allocator_earlier_than_previous_endpoint(self):
        endpoint = self.selected()[0]
        endpoint['allocatorBefore']['startUs'] = self.report['externalEndpoints'][0]['dartTimeUs']
        self.rewrite_allocator()
        self.assert_failed('overlaps the preceding endpoint')

    def test_allocator_cannot_leave_request_ack_bracket(self):
        endpoint = self.selected()[0]
        endpoint['allocatorAfter']['endUs'] = endpoint['acknowledgedDartTimeUs'] + 1
        self.rewrite_allocator()
        self.assert_failed('do not bracket external request/ack')

    def test_allocator_metadata_cannot_include_paths(self):
        self.report['allocatorCalls'][0]['path'] = '/tmp/private'
        self.rewrite_allocator()
        self.assert_failed('only fixed scalar metadata')

    def test_allocator_unbounded_machine_word_rejected(self):
        self.report['allocatorCalls'][0]['fields']['hblkhd'] = 1 << 64
        self.rewrite_allocator()
        self.assert_failed('exceeds official size_t width')

    def test_allocator_abi_cannot_change_between_samples(self):
        self.report['allocatorCalls'][1].update(sizeTBytes=4, mallinfo2StructBytes=40)
        self.rewrite_allocator()
        self.assert_failed('identity changed within one process')

    def test_allocator_status_failure_cannot_be_unsupported(self):
        self.report['allocatorCalls'][0]['status'] = 'failed'
        self.rewrite_allocator()
        self.assert_failed('Unknown allocator availability status')

    def test_unsupported_is_valid_raw_evidence_but_inconclusive(self):
        for call in self.report['allocatorCalls']:
            call.update(status='unsupported', reason='allocator-symbols-interposed',
                        fields=dict.fromkeys(checks.protocol.FIELDS))
        self.rewrite_allocator()
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['status'], 'unsupported-inconclusive')
        self.assertFalse(result['attribution']['available'])
        self.assertFalse(result['retention']['runtimeSemanticsVerified'])
        self.assertFalse(result['plateauEstablished'])
        self.assertFalse(result['improvementEstablished'])
        self.assertTrue(all(value is None for value in
            result['retention']['sameVariantPairs'][0]['allocatorBeforeDelta'].values()))

    def test_unsupported_build_headers_preserve_explicit_null_abi(self):
        for call in self.report['allocatorCalls']:
            call.update(status='unsupported', reason='unsupported-build-headers',
                        fields=dict.fromkeys(checks.protocol.FIELDS),
                        mallinfo2StructBytes=None, glibcVersion=None)
        self.rewrite_allocator()
        self.edit_manifest('helper-build.json', lambda value: value['runtime'].update(
            runtimeLibcVersion='2.31', headerGlibcMinor=31, mallinfo2StructBytes=0,
            helperStatus=1, abiContractMatched=None, inspectedUpstreamFamily=False,
            sourceReviewRequired=True))
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['status'], 'unsupported-inconclusive')
        self.assertFalse(result['allocatorAttributionAvailable'])
        self.assertFalse(result['memoryImprovementEstablished'])

    def test_external_hwm_cannot_fall_below_rss(self):
        self.edit_external(lambda rows: rows[1].update(processVmHwmBytes=rows[1]['rssBytes'] - 1))
        self.assert_failed('external HWM below RSS')

    def test_missing_category_file_is_failed_not_unsupported(self):
        (self.root.parent / self.external['retentionCategories']['file']).unlink()
        self.assert_failed('retention raw file missing')

    def test_missing_allocator_file_is_failed_not_unsupported(self):
        (self.root.parent / self.report['allocatorJournal']['file']).unlink()
        self.assert_failed('retention raw file missing')

    def test_raw_metadata_boolean_cycle_is_rejected(self):
        # The old equality comparisons alone would treat False as cycle 0.
        self.report['externalEndpoints'][4]['cycle'] = False
        self.assert_failed('request metadata cycle: integer')

    def test_unsupported_never_accepts_zero_fabrication(self):
        for call in self.report['allocatorCalls']:
            call.update(status='unsupported', reason='allocator-symbols-interposed')
        self.rewrite_allocator()
        self.assert_failed('Unsupported allocator data must be explicit null')

    def test_uninspected_libc_retained_without_semantics_attribution(self):
        for call in self.report['allocatorCalls']:
            call['glibcVersion'] = '2.42'
        self.rewrite_allocator()
        self.edit_manifest('helper-build.json', lambda value: value['runtime'].update(
            runtimeLibcVersion='2.42', inspectedUpstreamFamily=False, sourceReviewRequired=True))
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['status'], 'unsupported-inconclusive')
        self.assertFalse(result['attribution']['available'])
        self.assertFalse(result['retention']['runtimeSemanticsVerified'])

    def test_absent_optional_categories_retained_as_null(self):
        for endpoint in self.selected():
            endpoint['mappingCategories']['pssFileBytes'] = None
        self.rewrite_categories()
        result = self.run_validation()
        self.assertTrue(result['evidenceValid'], result['errors'])
        self.assertEqual(result['status'], 'unsupported-inconclusive')
        self.assertFalse(result['attribution']['available'])

    def test_category_hash_tamper(self):
        self.external['retentionCategories']['sha256'] = '0' * 64
        self.assert_failed('retention raw bytes/SHA-256 mismatch')

    def test_category_count_mismatch(self):
        self.external['retentionCategories']['count'] = 17
        self.assert_failed('retention raw declared count differs')

    def test_category_raw_row_mismatch(self):
        self.selected()[0]['mappingCategories']['pssFileBytes'] += 1024
        self.assert_failed('category report differs from raw journal')

    def test_category_required_scalar_cannot_be_null(self):
        self.selected()[0]['mappingCategories']['pssBytes'] = None
        self.rewrite_categories()
        self.assert_failed('pssBytes: integer')

    def test_category_negative_scalar(self):
        self.selected()[0]['mappingCategories']['pssAnonymousBytes'] = -1
        self.rewrite_categories()
        self.assert_failed('pssAnonymousBytes: integer')

    def test_category_boolean_not_integer(self):
        self.selected()[0]['mappingCategories']['pssSharedMemoryBytes'] = True
        self.rewrite_categories()
        self.assert_failed('pssSharedMemoryBytes: integer')

    def test_category_must_follow_original_os_read(self):
        endpoint = self.selected()[0]
        endpoint['mappingCategories']['startNs'] = endpoint['os']['smapsEndNs'] - 1
        self.rewrite_categories()
        self.assert_failed('must follow original OS observation')

    def test_category_cannot_overlap_next_os_read(self):
        endpoint = self.selected()[0]
        endpoint['mappingCategories']['endNs'] = self.report['externalEndpoints'][2]['os']['timeNs'] + 1
        self.rewrite_categories()
        self.assert_failed('overlaps next external OS observation')

    def test_category_sequence_tamper(self):
        self.selected()[0]['mappingCategories']['sequence'] = 1
        self.rewrite_categories()
        self.assert_failed('category observation')

    def test_category_wrong_external_os_sequence(self):
        self.selected()[0]['mappingCategories']['externalOsSequence'] += 1
        self.rewrite_categories()
        self.assert_failed('category observation')

    def test_category_metadata_wrong_arm(self):
        self.selected()[0]['mappingCategories']['metadata']['controlArm'] = 'product-os-only'
        self.rewrite_categories()
        self.assert_failed('metadata differs from Dart request')

    def test_category_metadata_extra_field(self):
        self.selected()[0]['mappingCategories']['metadata']['address'] = '0x1234'
        self.rewrite_categories()
        self.assert_failed('metadata differs from Dart request')

    def test_category_extra_path_field(self):
        self.selected()[0]['mappingCategories']['path'] = '/tmp/private'
        self.rewrite_categories()
        self.assert_failed('only fixed scalar metadata')

    def test_new_journal_symlink_rejected(self):
        for descriptor in (self.report['allocatorJournal'], self.external['retentionCategories']):
            with self.subTest(file=descriptor['file']):
                path = self.root.parent / descriptor['file']
                data = path.read_bytes()
                backup = path.with_suffix('.backup')
                backup.write_bytes(data)
                path.unlink()
                path.symlink_to(backup.name)
                self.assert_failed('raw file missing or symbolic link')
                path.unlink()
                path.write_bytes(data)

    def test_new_journal_unsafe_filename(self):
        self.report['allocatorJournal']['file'] = '../native-retention-probes.jsonl'
        self.assert_failed('unsafe retention raw filename')

    def test_duplicate_json_key_rejected(self):
        path = self.root.parent / self.report['allocatorJournal']['file']
        data = path.read_bytes().replace(b'"sequence":0', b'"sequence":0,"sequence":0', 1)
        path.write_bytes(data)
        self.report['allocatorJournal'].update(bytes=len(data), sha256=checks.digest(path))
        self.assert_failed('duplicate JSON object key')

    def test_partial_new_journal_line(self):
        path = self.root.parent / self.report['allocatorJournal']['file']
        data = path.read_bytes()[:-1]
        path.write_bytes(data)
        self.report['allocatorJournal'].update(bytes=len(data), sha256=checks.digest(path))
        self.assert_failed('line oversized or incomplete')

    def test_source_manifest_hash_link_cannot_be_rewritten_silently(self):
        self.edit_manifest('source.json', lambda value: value.update(verification='changed'), refresh=False)
        self.assert_failed('provenance links differ')

    def test_old_base_tree_cannot_pass_source_identity(self):
        self.edit_manifest('source.json', lambda value: value.update(baseTree='0' * 40))
        self.assert_failed('source/derivation identity differs')

    def test_build_source_hash_must_match_verified_source_manifest(self):
        self.build['sourceFilesSha256']['lib/domain/computerraria_computer.dart'] = '0' * 64
        self.build_sha = refresh_provenance(self.root.parent, self.report, self.build)
        self.assert_failed('build/source exact file hash differs')

    def test_patch_digest_tamper(self):
        (self.root.parent / 'diagnostic-overlay.patch').write_bytes(b'changed\n')
        self.assert_failed('patch missing or digest differs')

    def test_missing_helper_binary_is_invalid_evidence(self):
        (self.root.parent / 'helper/libabc_native_retention_probe.so').unlink()
        self.assert_failed('helper evidence missing or digest differs')

    def test_helper_binary_hash_tamper(self):
        (self.root.parent / 'helper/libabc_native_retention_probe.so').write_bytes(b'changed\n')
        self.assert_failed('helper evidence missing or digest differs')

    def test_helper_log_hash_tamper(self):
        (self.root.parent / 'helper/compile-helper.stdout.txt').write_bytes(b'changed\n')
        self.assert_failed('helper evidence missing or digest differs')

    def test_failed_helper_command_rejected_even_with_new_manifest_hash(self):
        self.edit_manifest('helper-build.json', lambda value: value['commands'][2].update(returnCode=1))
        self.assert_failed('required helper build command failed')

    def test_uninspected_libc_cannot_claim_reviewed(self):
        self.edit_manifest('helper-build.json', lambda value: value['runtime'].update(runtimeLibcVersion='2.42'))
        self.assert_failed('semantics claims differ')

    def test_runtime_helper_native_binary_links_must_match(self):
        self.report['runtime']['nativeRetentionProvenance']['nativeEngineSha256'] = '0' * 64
        self.assert_failed('provenance links differ')

    def test_failed_post_run_integrity_never_validates_observed_target(self):
        self.update_original_fixtures = False
        self.report['runtime']['nativeRetentionExecution']['sourceUnchangedAfterRun'] = None
        self.assert_failed('post-run source/helper/product verification')

    def test_failed_driver_never_validates_observed_target(self):
        self.update_original_fixtures = False
        self.report['runtime']['nativeRetentionExecution']['driverExitCode'] = 1
        self.assert_failed('single-process execution failed')

    def test_raw_target_report_hash_tamper(self):
        self.update_original_fixtures = False
        self.report['runtime']['rawTargetReport']['sha256'] = '0' * 64
        self.assert_failed('raw target report SHA-256 mismatch')

    def test_enrichment_cannot_rewrite_target_values(self):
        self.update_original_fixtures = False
        self.report['scope'] = 'silently rewritten'
        self.assert_failed('enriched report changed original target evidence')

    def test_enrichment_cannot_rewrite_compiler_build(self):
        self.update_original_fixtures = False
        value = checks.load_json(self.root.parent / 'native-retention.compiler-build.json')
        value['artifacts']['libabc_engine.so']['bytes'] += 1
        put_json(self.root.parent, 'native-retention.compiler-build.json', value)
        self.assert_failed('enriched build changed original compiler evidence')

    def test_cli_writes_new_schema_and_fails_closed(self):
        report_path, build_path = self.root.parent / 'report.json', self.root.parent / 'build.json'
        external_path, output_path = self.root.parent / 'external.json', self.root.parent / 'summary.json'
        build_path.write_bytes(encoded(self.build))
        external_path.write_bytes(encoded(self.external))
        args = [str(report_path), '--raw-directory', str(self.root), '--build', str(build_path),
                '--external-os', str(external_path), '--expected-commit', COMMIT, '--output', str(output_path)]
        report_path.write_bytes(encoded(self.report))
        self.assertEqual(checks.main(args), 0)
        self.assertEqual(checks.load_json(output_path)['status'], 'validated-retention-observation')
        self.report['status'] = 'failed'
        original_reports(self.root.parent, self.report, self.build)
        report_path.write_bytes(encoded(self.report))
        self.assertEqual(checks.main(args), 1)
        self.assertFalse(checks.load_json(output_path)['evidenceValid'])


# These exact unchanged mutations exercise all control checks applicable to the
# OS-only workload. Probe-only mutations concern a different experiment.
for _name in (
        'test_original_validator_rejects_control_schema',
        'test_partial_report_cannot_pass', 'test_missing_checkpoint_cannot_pass',
        'test_reordered_points_cannot_pass', 'test_changed_pinned_schedule_cannot_pass',
        'test_hidden_lateness_cannot_pass', 'test_missing_raw_chunk_cannot_pass',
        'test_raw_hash_tampering_cannot_pass', 'test_frame_sequence_gap_cannot_pass_even_with_new_hash',
        'test_duplicate_engine_number_remains_record_not_identity', 'test_short_drain_cannot_pass',
        'test_inprocess_point_must_equal_raw_row', 'test_failed_external_sampler_cannot_pass',
        'test_external_other_pid_cannot_pass', 'test_external_partial_protocol_cannot_pass',
        'test_external_reordered_protocol_cannot_pass', 'test_external_raw_sequence_gap_cannot_pass',
        'test_external_raw_hash_mismatch_cannot_pass', 'test_external_ack_must_equal_raw_row',
        'test_external_cannot_mix_clock_domains', 'test_external_pid_reuse_cannot_pass',
        'test_external_missing_uss_cannot_pass', 'test_external_manifest_must_match_report',
        'test_external_more_than_one_process_attempt_cannot_pass', 'test_dirty_build_cannot_pass'):
    setattr(RetentionChecksTest, _name, getattr(control_fixture.ControlChecksTest, _name))


for _name in (
        'test_same_status_hwm_below_rss_remains_failure',
        'test_dropped_frame_even_with_rehashed_raw_file_fails', 'test_corrupted_raw_hash_fails',
        'test_unverified_write_read_digest_fails', 'test_missing_os_raw_file_fails',
        'test_dropped_os_sample_even_with_updated_hash_fails', 'test_missing_phase_fails',
        'test_missing_checkpoint_fails', 'test_duplicate_engine_number_is_reported_without_dropping',
        'test_missing_public_frame_field_fails', 'test_lost_dispatch_cannot_hide_by_rehashing',
        'test_production_disposal_release_keys_are_required', 'test_fixed_real_pulse_and_cleanup_are_required',
        'test_missing_display_batch_and_static_on_display_fail', 'test_on_display_must_change_and_have_lit_pixels'):
    setattr(RetentionChecksTest, _name, getattr(original_fixture.MemoryChecksTest, _name))


if __name__ == '__main__':
    unittest.main()
