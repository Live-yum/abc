"""Only the checked-in synthetic Python stub is executed by these tests."""
import json
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import bounded_supervision as s
from application_contract import ContractError, RSS_STOP, OsLogTail

STUB = Path(__file__).parent / 'fixtures' / 'supervision_stub.py'


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.budget = s.PairBudget(0, clock=lambda: self.now)

    def start(self):
        return self.budget.start_arm('probe-only')

    def complete(self):
        self.budget.hello()
        self.budget.complete_arm(dict(workloadComplete=True, heapFilesComplete=True,
                                      stackAttributionAvailable=True))

    def test_exact_300_600_900_2000_deadlines(self):
        arm = self.start()
        self.assertEqual(arm['deadline'], 900)
        self.assertEqual(self.budget.deadline, 2000)
        self.assertEqual(self.budget.stage_deadline('build'), 300)
        self.now = 100
        self.budget.hello()
        self.assertEqual(self.budget.stage_deadline('runtime'), 700)
        self.assertEqual(self.budget.stage_deadline('identity', began=100), 160)
        self.assertEqual(self.budget.stage_deadline('hook', began=200), 210)
        self.assertEqual(self.budget.stage_deadline('ack', began=209, hook_began=200), 210)

    def test_first_failure_stops_second_and_preserves_unstarted(self):
        self.start()
        self.budget.fail('bad receipt')
        self.assertEqual(self.budget.report()['notStarted'], ['product-with-ownership'])
        for name in ('product-with-ownership', 'probe-only'):
            with self.assertRaisesRegex(ContractError, 'stopped'):
                self.budget.start_arm(name)

    def test_no_retry_no_reorder_incomplete_first_stops_second(self):
        with self.assertRaises(ContractError):
            self.budget.start_arm('product-with-ownership')
        self.start()
        with self.assertRaises(ContractError):
            self.budget.start_arm('product-with-ownership')
        self.complete()
        self.budget.start_arm('product-with-ownership')
        self.complete()
        with self.assertRaises(ContractError):
            self.budget.start_arm('probe-only')

    def test_two_modes_share_120_seconds_and_cannot_retry(self):
        self.start()
        first = self.budget.profile_analysis_deadline('q0', 'inuse_space')
        self.now = 80
        second = self.budget.profile_analysis_deadline('q0', 'inuse_objects')
        self.assertEqual((first, second), (120, 120))
        with self.assertRaisesRegex(ContractError, 'retry'):
            self.budget.profile_analysis_deadline('q0', 'inuse_space')
        self.now = 120
        with self.assertRaisesRegex(ContractError, 'expired'):
            self.budget.stage_deadline('analysis', began=0)

    def test_build_runtime_pair_expiry_not_reset(self):
        self.start()
        self.now = 300
        with self.assertRaises(ContractError):
            self.budget.hello()
        self.now = 2001
        with self.assertRaises(ContractError):
            self.budget.stage_deadline('analysis', began=2001)

    def test_ack_needs_enclosing_hook(self):
        self.start()
        self.budget.hello()
        with self.assertRaises(ContractError):
            self.budget.stage_deadline('ack', began=1)


class SupervisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_stub(self, mode, *, seconds=3, extra=(), **kw):
        return s.run_bounded([sys.executable, str(STUB.resolve()), mode, *map(str, extra)],
                             self.root / 'run', deadline=time.monotonic() + seconds, **kw)

    def test_success_clean_environment_child_limits_and_owned_cleanup(self):
        with patch.dict(os.environ, {'LD_PRELOAD': '/not/a/library', 'HEAPPROFILE': 'bad',
                                     'TCMALLOC_SAMPLE_PARAMETER': '1'}):
            result = self.run_stub('success')
        self.assertEqual(result['status'], 'complete', result)
        data = json.loads((self.root / 'run/stdout').read_text())
        self.assertEqual(data['pid'], data['pgid'])
        self.assertEqual(data['fileLimit'], 64 << 20)
        self.assertEqual(data['coreLimit'], 0)
        self.assertFalse({'LD_PRELOAD', 'HEAPPROFILE', 'TCMALLOC_SAMPLE_PARAMETER'} & set(data['envKeys']))
        self.assertTrue(result['cleanup']['groupGone'])
        self.assertTrue(all(item['leaderUnreaped'] for item in result['cleanup']['signals']))
        self.assertEqual(result['attempts'], 1)

    def test_fast_nonzero_keeps_output_code_error_and_cleanup(self):
        result = self.run_stub('fastfail')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['returnCode'], 7)
        self.assertIn('partial evidence', (self.root / 'run/stdout').read_text())
        self.assertTrue(result['cleanup']['groupGone'])
        self.assertTrue(result['stdout']['sha256'])
        self.assertEqual(json.loads((self.root / 'run/command.json').read_text()), result)

    def test_fast_exit_output_cap_checked_finally_and_preserved(self):
        result = self.run_stub('flood', extra=(4096,), stdout_cap=1024)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('cap' in error for error in result['errors']))
        self.assertGreater((self.root / 'run/stdout').stat().st_size, 1024)
        self.assertTrue(result['cleanup']['groupGone'])

    def test_hanging_ignores_term_then_killed_within_shared_deadline(self):
        start = time.monotonic()
        result = self.run_stub('hang', seconds=2)
        self.assertEqual(result['status'], 'failed')
        self.assertLess(time.monotonic() - start, 2)
        self.assertTrue(result['cleanup']['groupGone'])
        self.assertEqual(result['cleanup']['returnCode'], -signal.SIGKILL)
        self.assertTrue(any('deadline' in e for e in result['errors']))
        self.assertIn('before hang', (self.root / 'run/stdout').read_text())

    def test_retained_child_in_same_owned_group_is_cleaned(self):
        result = self.run_stub('child', seconds=2)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(result['cleanup']['groupGone'], result)
        child = json.loads((self.root / 'run/stdout').read_text())['child']
        with self.assertRaises(ProcessLookupError):
            os.kill(child, 0)

    def test_bad_receipt_watch_kills_child_and_keeps_first_error(self):
        def bad_receipt():
            raise ContractError('receipt corruption')
        result = self.run_stub('hang', watch=bad_receipt)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['errors'][0], 'receipt corruption')
        self.assertTrue(result['cleanup']['groupGone'])

    def test_existing_os_log_rss_stops_stub_without_new_sampler(self):
        path = self.root / 'os.jsonl'
        path.write_text(json.dumps({'type': 'os', 'sequence': 0, 'rssBytes': RSS_STOP + 1}) + '\n')
        tail = OsLogTail(path)
        result = self.run_stub('hang', watch=tail.read_new)
        self.assertEqual(result['status'], 'failed')
        self.assertTrue(any('2 GiB' in error for error in result['errors']))
        self.assertTrue(result['cleanup']['groupGone'])

    def test_no_start_without_cleanup_time_no_existing_output_reuse(self):
        with self.assertRaisesRegex(ContractError, 'No shared time'):
            self.run_stub('success', seconds=1)
        self.assertFalse((self.root / 'run').exists())
        (self.root / 'run').mkdir()
        with self.assertRaises(FileExistsError):
            self.run_stub('success')

    def test_no_signal_if_someone_already_reaped_leader(self):
        process = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        process.wait()
        with patch('bounded_supervision.os.killpg') as kill:
            with self.assertRaisesRegex(ContractError, 'already reaped'):
                s.cleanup_owned_group(process, deadline=time.monotonic() + 2)
        kill.assert_not_called()

    def test_clean_tool_env_refuses_injected_preload(self):
        for key in ('LD_PRELOAD', 'HEAPPROFILE', 'HEAPPROFILESIGNAL', 'TCMALLOC_SAMPLE_PARAMETER'):
            with self.assertRaises(ContractError):
                s.clean_tool_env({key: 'bad'})

    def test_target_proc_identity_fd_binding_and_wrong_group_sha(self):
        process = subprocess.Popen([sys.executable, str(STUB.resolve()), 'hang'],
                                   start_new_session=True, stdout=subprocess.DEVNULL,
                                   env=s.clean_tool_env())
        try:
            executable = Path(sys.executable).resolve()
            digest = hashlib.sha256(executable.read_bytes()).hexdigest()
            identity = s.TargetProcessIdentity(process.pid, owned_pgid=process.pid,
                                              expected_executable=executable, expected_sha256=digest)
            try:
                identity.verify()
                self.assertTrue(identity.evidence['procFdRetained'])
                self.assertTrue(identity.evidence['executableFdRetained'])
                self.assertEqual(identity.evidence['uid'], os.getuid())
            finally:
                identity.close()
            for group, sha in ((process.pid + 1, digest), (process.pid, '0' * 64)):
                with self.assertRaises(ContractError):
                    s.TargetProcessIdentity(process.pid, owned_pgid=group,
                                            expected_executable=executable, expected_sha256=sha)
        finally:
            self.assertTrue(s.cleanup_owned_group(process, deadline=time.monotonic() + 2)['groupGone'])


if __name__ == '__main__':
    unittest.main()
