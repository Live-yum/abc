"""False-pass contracts for diagnostic identity, flags and process attribution."""
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import memory_ownership_preflight as preflight
import memory_ownership_run as runner
import memory_ownership_schedule as schedule


def producer_fixture():
    """Synthetic corruption-test input, never a substitute for Dart CI exports."""
    cycles = [{'cycle': index, 'mode': 'optimized' if index % 2 else 'standard',
               'scenario': 'no-world-no-edit', 'status': 'completed', 'productOperations': 0}
              for index in range(8)]
    interrupted = copy.deepcopy(cycles)
    interrupted[-1]['status'] = 'running'
    return {'schema': 'abc.memory-ownership-producer-contract.v1', 'arm': 'probe-only',
            'completed': {'plannedCycles': 8, 'completedCycles': 8, 'cycles': cycles},
            'interrupted': {'plannedCycles': 8, 'completedCycles': 7, 'cycles': interrupted}}


class ProducerProtocol(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.first, self.second = self.root / 'default.json', self.root / 'opt-in.json'
        self.output = self.root / 'proof.json'
        self.fixture = producer_fixture()
        self.store(self.fixture)

    def store(self, fixture):
        content = (json.dumps(fixture, separators=(',', ':'), allow_nan=False) + '\n').encode()
        self.first.write_bytes(content)
        self.second.write_bytes(content)
        return content

    def reject(self):
        with self.assertRaises((ValueError, OSError)):
            preflight.producer_preflight(self.first, self.second, self.output)
        self.assertFalse(self.output.exists())

    def test_valid_pair_uses_actual_strict_consumer_and_git_head(self):
        import hashlib
        from memory_ownership_validate import OwnershipValidator
        original = OwnershipValidator.validate_cycle
        calls = []
        def consumer(context, row, cycle):
            calls.append(row['status'])
            return original(context, row, cycle)
        with mock.patch.object(OwnershipValidator, 'validate_cycle', consumer), \
                mock.patch.object(preflight, 'command', return_value='a' * 40) as head:
            result = preflight.producer_preflight(self.first, self.second, self.output)
        head.assert_called_once_with('git', 'rev-parse', 'HEAD')
        self.assertEqual(calls.count('completed'), 30)
        self.assertEqual(calls.count('running'), 2)
        self.assertEqual(result, json.loads(self.output.read_text()))
        self.assertEqual(result, {'schema': 'abc.memory-ownership-producer-preflight.v1',
            'sourceCommit': 'a' * 40,
            'fixtureSha256': hashlib.sha256(self.first.read_bytes()).hexdigest(),
            'optInFixtureSha256': hashlib.sha256(self.second.read_bytes()).hexdigest(),
            'contractPassed': True, 'completedAccepted': True, 'interruptedRejected': True,
            'exportsIdentical': True, 'proofScope': 'producer-cycle-protocol-only'})

    def test_old_idle_rows_and_zero_completed_count_rejected(self):
        for change in ('idle', 'zero', 'both'):
            with self.subTest(change=change):
                fixture = producer_fixture()
                if change in ('idle', 'both'):
                    for row in fixture['completed']['cycles']:
                        row['status'] = 'idle'
                if change in ('zero', 'both'):
                    fixture['completed']['completedCycles'] = 0
                self.store(fixture)
                self.reject()

    def test_boolean_float_and_incorrect_counts_rejected(self):
        for section in ('completed', 'interrupted'):
            for field in ('plannedCycles', 'completedCycles'):
                for value in (True, False, 8.0, 7.0, 0, 9):
                    with self.subTest(section=section, field=field, value=value):
                        fixture = producer_fixture()
                        fixture[section][field] = value
                        self.store(fixture)
                        self.reject()

    def test_wrong_cycle_protocol_fields_rejected(self):
        for section in ('completed', 'interrupted'):
            for field, value in (('mode', 'optimized'), ('scenario', 'reset-original'),
                                 ('productOperations', 1), ('productOperations', False),
                                 ('productOperations', 0.0), ('cycle', False), ('cycle', 0.0)):
                with self.subTest(section=section, field=field, value=value):
                    fixture = producer_fixture()
                    fixture[section]['cycles'][0][field] = value
                    self.store(fixture)
                    self.reject()

    def test_missing_duplicate_and_out_of_order_rows_rejected(self):
        for section in ('completed', 'interrupted'):
            for change in ('missing', 'duplicate', 'reordered'):
                with self.subTest(section=section, change=change):
                    fixture = producer_fixture()
                    rows = fixture[section]['cycles']
                    if change == 'missing': rows.pop()
                    if change == 'duplicate': rows[3] = copy.deepcopy(rows[2])
                    if change == 'reordered': rows[2], rows[3] = rows[3], rows[2]
                    self.store(fixture)
                    self.reject()

    def test_partial_completion_cannot_be_disguised(self):
        for change in ('promoted-count', 'promoted-row', 'wrong-running-position',
                       'completed-still-running', 'last-index-float', 'last-ops-bool'):
            with self.subTest(change=change):
                fixture = producer_fixture()
                rows = fixture['interrupted']['cycles']
                if change == 'promoted-count': fixture['interrupted']['completedCycles'] = 8
                if change == 'promoted-row': rows[-1]['status'] = 'completed'
                if change == 'wrong-running-position':
                    rows[-1]['status'], rows[6]['status'] = 'completed', 'running'
                if change == 'completed-still-running': fixture['completed']['cycles'][-1]['status'] = 'running'
                if change == 'last-index-float': rows[-1]['cycle'] = 7.0
                if change == 'last-ops-bool': rows[-1]['productOperations'] = False
                self.store(fixture)
                self.reject()

    def test_exact_keys_and_identity_at_every_level(self):
        for level in ('top', 'section', 'row'):
            for change in ('missing', 'extra'):
                with self.subTest(level=level, change=change):
                    fixture = producer_fixture()
                    target = (fixture if level == 'top' else fixture['completed'] if level == 'section'
                              else fixture['completed']['cycles'][0])
                    if change == 'missing': target.pop(next(iter(target)))
                    else: target['unexpected'] = None
                    self.store(fixture)
                    self.reject()
        for field, value in (('schema', 'abc.memory-ownership.v1'), ('arm', 'product-with-ownership')):
            fixture = producer_fixture()
            fixture[field] = value
            self.store(fixture)
            self.reject()

    def test_duplicate_json_keys_and_nonfinite_numbers_rejected(self):
        valid = self.first.read_bytes()
        for content in (valid.replace(b'"plannedCycles":8', b'"plannedCycles":0,"plannedCycles":8', 1),
                        valid.replace(b'"productOperations":0', b'"productOperations":NaN', 1),
                        valid.replace(b'"productOperations":0', b'"productOperations":Infinity', 1),
                        b'[]', b'not json', b'\xff'):
            with self.subTest(content=content[:30]):
                self.first.write_bytes(content)
                self.second.write_bytes(content)
                self.reject()

    def test_independent_exports_require_different_file_identity(self):
        with self.assertRaisesRegex(ValueError, 'independent'):
            preflight.producer_preflight(self.first, self.first, self.output)
        self.second.unlink()
        os.link(self.first, self.second)
        self.reject()

    def test_symlink_directory_fifo_and_missing_file_rejected(self):
        self.second.unlink()
        self.second.symlink_to(self.first)
        self.reject()
        self.second.unlink()
        self.second.mkdir()
        self.reject()
        self.second.rmdir()
        os.mkfifo(self.second)
        self.reject()
        self.second.unlink()
        self.reject()

    def test_empty_and_oversized_files_rejected_at_bounded_read(self):
        for content in (b'', b' ' * (preflight.PRODUCER_FIXTURE_LIMIT + 1)):
            self.first.write_bytes(content)
            self.reject()

    def test_byte_limit_accepts_exact_boundary_and_exports_must_match_bytes(self):
        content = self.first.read_bytes()
        self.first.write_bytes(content + b' ' * (preflight.PRODUCER_FIXTURE_LIMIT - len(content)))
        bounded, _ = preflight.read_producer_fixture(self.first)
        preflight.validate_producer_fixture(bounded)
        self.reject()  # Both JSON objects are valid, but exports are not byte-identical.

    def test_opt_in_export_is_checked_independently(self):
        fixture = producer_fixture()
        fixture['completed']['completedCycles'] = 0
        self.second.write_text(json.dumps(fixture))
        self.reject()

    def test_accepting_interrupted_cycle_or_rejecting_completed_cycle_fails_gate(self):
        from memory_ownership_validate import OwnershipValidator
        with mock.patch.object(OwnershipValidator, 'validate_cycle', return_value=None):
            self.reject()
        with mock.patch.object(OwnershipValidator, 'validate_cycle', side_effect=ValueError('consumer rejects')):
            self.reject()

    def test_invalid_git_identity_and_existing_proof_rejected(self):
        with mock.patch.object(preflight, 'command', return_value='not-a-commit'):
            self.reject()
        self.output.write_text('existing proof')
        with mock.patch.object(preflight, 'command', return_value='a' * 40), self.assertRaises(FileExistsError):
            preflight.producer_preflight(self.first, self.second, self.output)
        self.assertEqual(self.output.read_text(), 'existing proof')

    def test_cli_dispatches_both_required_exports(self):
        with mock.patch('sys.argv', ['preflight', 'producer', '--fixture', str(self.first),
                        '--opt-in-fixture', str(self.second), '--output', str(self.output)]), \
                mock.patch.object(preflight, 'command', return_value='a' * 40):
            preflight.main()
        self.assertTrue(json.loads(self.output.read_text())['contractPassed'])


class SourceIdentity(unittest.TestCase):
    def setUp(self):
        self.old = {'lib/unchanged.dart': {'mode': '100644', 'blob': '1' * 40},
                    'native/CMakeLists.txt': {'mode': '100644', 'blob': '2' * 40}}
        self.new = copy.deepcopy(self.old)
        self.new['native/CMakeLists.txt']['blob'] = '3' * 40
        self.new[preflight.MANIFEST] = {'mode': '100644', 'blob': '4' * 40}
        self.manifest = {'files': [{'path': 'native/CMakeLists.txt',
                                  'before': copy.deepcopy(self.old['native/CMakeLists.txt']),
                                  'after': copy.deepcopy(self.new['native/CMakeLists.txt'])}]}

    def test_exact_overlay_is_accepted(self):
        preflight.validate_delta(self.old, self.new, self.manifest)

    def test_unlisted_product_change_rejected(self):
        self.new['lib/unchanged.dart']['blob'] = '5' * 40
        with self.assertRaises(ValueError):
            preflight.validate_delta(self.old, self.new, self.manifest)

    def test_manifest_does_not_authorize_replacing_runtime(self):
        path = 'web/engine/world.wasm'
        self.new[path] = {'mode': '100644', 'blob': '6' * 40}
        self.manifest['files'].append({'path': path, 'before': None, 'after': self.new[path]})
        with self.assertRaises(ValueError):
            preflight.validate_delta(self.old, self.new, self.manifest)

    def test_mode_and_base_identity_rejected(self):
        for field, value in (('mode', '100755'), ('blob', '0' * 40)):
            changed = copy.deepcopy(self.manifest)
            changed['files'][0]['before'][field] = value
            with self.assertRaises(ValueError):
                preflight.validate_delta(self.old, self.new, changed)

    def test_unsafe_paths_and_duplicate_rows_rejected(self):
        for path in ('../x', '/x', 'a/../b', 'a\\b', 'a//b'):
            with self.assertRaises(ValueError):
                preflight.safe_path(path)
        self.manifest['files'] *= 2
        with self.assertRaises(ValueError):
            preflight.validate_delta(self.old, self.new, self.manifest)

    def test_actual_blob_bytes_checked(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source'
            path.write_bytes(b'expected')
            blob = hashlib.sha1(b'blob 8\0expected').hexdigest()
            identity = {'mode': '100644', 'blob': blob}
            self.assertEqual(preflight.file_identity(path, identity)['bytes'], 8)
            path.write_bytes(b'modified')
            with self.assertRaises(ValueError):
                preflight.file_identity(path, identity)


class NativeFlags(unittest.TestCase):
    def test_actual_targets_and_explicit_options(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache, ninja = root / 'CMakeCache.txt', root / 'build.ninja'
            good_cache = 'CMAKE_BUILD_TYPE:STRING=Profile\nABC_OWNER_DIAGNOSTICS:BOOL=ON\nABC_PERF_COUNTERS:BOOL=ON\n'
            good_ninja = ''.join(f'build dir/{name}: C_COMPILER\n  DEFINES = -DABC_OWNER_DIAGNOSTICS=1\n  FLAGS = -O3 -DNDEBUG -fPIC\n'
                                 for name in ('abc_owner_diagnostics.c.o', 'abc_perf.c.o',
                                              'terra_circuit_world.c.o', 'terra_circuit_vm.c.o'))
            cache.write_text(good_cache)
            ninja.write_text(good_ninja)
            preflight.native_settings(cache, ninja)
            for broken in (good_ninja.replace('-O3', '-O0'),
                           good_ninja.replace('-DABC_OWNER_DIAGNOSTICS=1', ''),
                           good_ninja.replace('terra_circuit_world.c.o', 'unrelated.c.o')):
                ninja.write_text(broken)
                with self.assertRaises(ValueError):
                    preflight.native_settings(cache, ninja)
            ninja.write_text(good_ninja)
            for broken in (good_cache.replace('COUNTERS:BOOL=ON', 'COUNTERS:BOOL=OFF'),
                           good_cache.replace('DIAGNOSTICS:BOOL=ON', 'DIAGNOSTICS:BOOL=OFF')):
                cache.write_text(broken)
                with self.assertRaises(ValueError):
                    preflight.native_settings(cache, ninja)


class TargetAttribution(unittest.TestCase):
    def test_executable_hash_is_bounded_and_bracketed_by_owned_identity(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'exe').write_bytes(b'fixture executable')
            class OwnedFixture:
                calls = 0
                fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                def verify(self):
                    self.calls += 1
            owned = OwnedFixture()
            try:
                result = runner.loaded_executable(owned)
                self.assertEqual(result, {'sha256': hashlib.sha256(b'fixture executable').hexdigest(), 'bytes': 18})
                self.assertEqual(owned.calls, 2)
            finally:
                os.close(owned.fd)

    def test_ready_is_atomic_new_file_and_cannot_replace_prior_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ready.json'
            runner.publish_ready(path, {'sourceCommit': 'a' * 40})
            self.assertEqual(json.loads(path.read_text()), {'sourceCommit': 'a' * 40})
            with self.assertRaises(FileExistsError):
                runner.publish_ready(path, {'sourceCommit': 'b' * 40})
            self.assertEqual(json.loads(path.read_text()), {'sourceCommit': 'a' * 40})

    def test_changed_second_binary_is_rejected_before_ready(self):
        first = {'libapp.so': {'sha256': 'a' * 64, 'bytes': 100}}
        runner.require_equal_binaries(first, None)
        runner.require_equal_binaries(copy.deepcopy(first), first)
        for field, value in (('sha256', 'b' * 64), ('bytes', 101)):
            other = copy.deepcopy(first)
            other['libapp.so'][field] = value
            with self.assertRaises(ValueError):
                runner.require_equal_binaries(other, first)

    def test_hello_must_identify_exact_arm_product_and_source(self):
        row = {'schema': 'abc.memory-ownership-hello.v1', 'arm': 'probe-only',
               'sourceCommit': 'a' * 40, 'baseProductCommit': preflight.BASE,
               'hostPid': 1234, 'startedUs': 1}
        runner.validate_hello(row, 'probe-only', 'a' * 40)
        for field, value in (('arm', 'product-with-ownership'), ('sourceCommit', 'b' * 40),
                             ('baseProductCommit', 'c' * 40), ('hostPid', True), ('startedUs', -1)):
            broken = {**row, field: value}
            with self.assertRaises(ValueError):
                runner.validate_hello(broken, 'probe-only', 'a' * 40)

    def test_target_report_cannot_be_attributed_to_stale_binary(self):
        row = {'schema': 'abc.memory-ownership.v1', 'arm': 'probe-only',
               'workloadId': 'generic-wld-controls-v1', 'runtime': {'commit': 'a' * 40},
               'hostPid': 1234, 'baseProductCommit': preflight.BASE}
        runner.validate_target(row, 'probe-only', 'a' * 40, 1234)
        for key, value in (('schema', 'abc.generic-world-memory.v1'), ('hostPid', 1235),
                           ('workloadId', 'legacy-computerraria-memory-v1')):
            with self.assertRaises(ValueError):
                runner.validate_target({**row, key: value}, 'probe-only', 'a' * 40, 1234)

    def test_log_redacts_local_service_secrets_before_persistence(self):
        output, state = io.StringIO(), {}
        runner.drain_log(io.BytesIO(b'http://127.0.0.1:1234/secret-token/\nAuthorization: Bearer secret\n'), output, state)
        self.assertNotIn('secret', output.getvalue())
        self.assertTrue(state['finished'])

    def test_log_limit_failure_is_explicit(self):
        output, state = io.StringIO(), {}
        runner.drain_log(io.BytesIO(b'x' * (runner.MAX_LINE_BYTES + 1)), output, state)
        self.assertIn('error', state)
        self.assertEqual(output.getvalue(), '')


class FrozenSchedule(unittest.TestCase):
    def test_exact_public_report_and_protocol(self):
        path = Path(__file__).with_name('memory_ownership_schedule.json')
        data = json.loads(path.read_text())
        self.assertEqual(preflight.digest(path), 'fd5b0ca2ab01d96923512d6574ffc49c7318ebe1e23e315215251b70669ef5e0')
        self.assertEqual(data['source']['commit'], preflight.BASE)
        self.assertEqual(data['source']['reportSha256'], schedule.REPORT_SHA256)
        self.assertEqual((len(data['points']), len(data['gaugeSchedule']), len(data['cycles'])), (17, 52, 8))
        self.assertEqual(len(set(row['id'] for row in data['gaugeSchedule'])), 52)
        self.assertEqual(data['sourceDurationUs'], 417896362)
        self.assertEqual(data['drainPolicy']['frameBarriers'], 3)

    def test_foreign_artifact_rejected_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'wrong.zip'
            path.write_bytes(b'not official bytes')
            with self.assertRaises(ValueError):
                schedule.from_archive(path)


if __name__ == '__main__':
    unittest.main()
