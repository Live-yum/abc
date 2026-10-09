"""Lifecycle/source-boundary contracts using tiny local synthetic files only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import native_retention_run as run


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


class RunnerContracts(unittest.TestCase):
    def test_compile_precedes_prebuilt_driver_without_security_overrides(self):
        build, drive = run.commands('flutter', 'a' * 40, '3.47.6', 'llvmpipe', Path('/bundle'))
        self.assertIn('build', build)
        self.assertNotIn('drive', build)
        self.assertIn('--use-application-binary=/bundle/terraforge', drive)
        self.assertIn('--host-vmservice-port=0', drive)
        self.assertNotIn('--use-existing-app', ' '.join(drive))
        self.assertNotIn('disable-service-auth', ' '.join(build + drive))
        self.assertEqual([x for x in build if x.startswith('--dart-define')],
                         [x for x in drive if x.startswith('--dart-define')])
        self.assertEqual((run.BUILD_SECONDS, run.RUNTIME_SECONDS, run.DRIVER_SECONDS), (300, 600, 900))

    def test_logged_failure_and_timeout_preserve_full_sanitized_output(self):
        with tempfile.TemporaryDirectory(prefix='abc-retention-runner-') as name:
            root = Path(name)
            failed = root / 'failed.log'
            code = run.logged_process([sys.executable, '-c',
                'print("first");print("http://127.0.0.1:9999/private-auth/");print("last");raise SystemExit(7)'],
                failed, dict(os.environ), time.monotonic() + 5)
            self.assertEqual(code, 7)
            self.assertEqual(failed.read_text().splitlines(),
                             ['first', '[redacted-local-service-url]', 'last'])
            timed = root / 'timed.log'
            with self.assertRaises(TimeoutError):
                run.logged_process([sys.executable, '-c',
                                    'import time;print("partial",flush=True);time.sleep(3)'],
                                   timed, dict(os.environ), time.monotonic() + 0.1)
            self.assertEqual(timed.read_text(), 'partial\n')

    def test_early_failure_records_incomplete_with_zero_application_invocations(self):
        with tempfile.TemporaryDirectory(prefix='abc-retention-runner-') as name:
            output = Path(name) / 'new'
            with mock.patch.dict(os.environ, {'CI': 'false'}):
                self.assertEqual(run.main([str(output)]), 1)
            execution = json.loads((output / 'execution.json').read_text())
            summary = json.loads((output / 'native-retention.summary.json').read_text())
            self.assertEqual(execution['processInvocations'], 0)
            self.assertFalse(summary['evidenceValid'])
            self.assertFalse(summary['allocatorAttributionAvailable'])
            with self.assertRaises(SystemExit):
                run.main([str(output)])


class SyntheticLifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='abc-retention-lifecycle-')
        self.addCleanup(self.temp.cleanup)
        self.top = Path(self.temp.name)
        self.root = self.top / 'source'
        self.root.mkdir()
        self.output = self.top / 'output'
        self.bundle = self.root / 'build/linux/x64/profile/bundle'
        (self.root / '.flutter-version').write_text('3.47.6\n')
        source = self.root / 'tool/perf/native_retention_probe.c'
        source.parent.mkdir(parents=True)
        source.write_text('// synthetic helper source; no application\n')
        self.helper_dir = self.top / 'helper'
        self.helper_dir.mkdir()
        self.helper = self.helper_dir / 'libabc_native_retention_probe.so'
        self.helper.write_bytes(b'synthetic bytes, never executed')
        self.helper_build = self.helper_dir / 'helper-build.json'
        write(self.helper_build, {'schema': 'abc.native-retention-helper-build.v1',
            'status': 'built', 'outsideApplicationCheckout': True,
            'applicationLaunched': False, 'downloadedDependencies': False,
            'helperPath': str(self.helper), 'helperFile': self.helper.name,
            'helperBytes': self.helper.stat().st_size, 'helperSha256': run.shared.digest(self.helper),
            'source': {'path': 'tool/perf/native_retention_probe.c', 'sha256': run.shared.digest(source)}})
        self.derive = self.top / 'derivation'
        self.derive.mkdir()
        write(self.derive / 'derivation.json', {'synthetic': True})
        (self.derive / 'diagnostic-overlay.patch').write_text('synthetic patch\n')
        self.world = self.root / 'build/public-computerraria/computerraria.wld'
        self.world.parent.mkdir(parents=True)
        self.world.write_bytes(b'synthetic marker; not a world')
        self.head = 'a' * 40
        self.provenance = {'baseCommit': run.PRODUCT_COMMIT, 'baseTree': run.PRODUCT_TREE,
                           'derivedCommit': self.head}
        self.calls = []

    def record_build(self, artifacts, output):
        write(output, {'artifacts': {p.name: {'bytes': p.stat().st_size,
             'sha256': run.shared.digest(p)} for p in artifacts},
             'cmake': {'ABC_PERF_COUNTERS': 'OFF'}, 'sourceTreeSha256': 'b' * 64})

    def invoke(self, mode):
        owner = self
        class FakeProtocol:
            def __init__(self, *_args):
                self.pid, self.sequence, self.finished = 124, 79, True
            def close(self):
                return self.descriptor()
            def descriptor(self):
                return {'synthetic': True, 'status': 'completed'}

        def process(argv, path, env, deadline, **kwargs):
            owner.calls.append(list(argv))
            path.write_text('complete synthetic log\n')
            if 'build' in argv:
                if mode == 'compile-fails': return 7
                for p in (owner.bundle / 'terraforge', owner.bundle / 'lib/libapp.so',
                          owner.bundle / 'lib/libabc_engine.so'):
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_bytes(('synthetic ' + p.name).encode())
                return 0
            if 'drive' in argv:
                kwargs['on_start'](type('Process', (), {'pid': 123})())
                (owner.output / 'native-retention-probes.jsonl').write_text('{"partial":true}\n')
                if mode == 'runtime-times-out':
                    raise TimeoutError('synthetic timeout after durable probe')
                write(owner.output / 'native-retention.raw-report.json', {
                    'schema': 'abc.native-retention.v1', 'baseProductCommit': run.PRODUCT_COMMIT,
                    'hostPid': 124, 'runtime': {'commit': owner.head}})
                if mode == 'binary-changes':
                    (owner.bundle / 'lib/libabc_engine.so').write_bytes(b'changed')
                return 0
            write(owner.output / 'native-retention.summary.json', {
                'status': 'unsupported' if mode == 'unsupported' else 'validated-retention-observation',
                'evidenceValid': True, 'allocatorAttributionAvailable': mode != 'unsupported'})
            return 0

        env = {'CI': 'true', 'ABC_RETENTION_DERIVATION': str(self.derive / 'derivation.json'),
               'ABC_RETENTION_HELPER_BUILD': str(self.helper_build), 'TERRA_PERF_RENDERER': 'synthetic'}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(run, 'ROOT', self.root), \
             mock.patch.object(run.source_checks, 'verify_source', return_value=self.provenance), \
             mock.patch.object(run.source_checks, 'check_source_unchanged'), \
             mock.patch.object(run.shared, 'capture', return_value='{"frameworkVersion":"3.47.6"}'), \
             mock.patch.object(run.shared, 'verify_world', return_value=self.world), \
             mock.patch.object(run.shared, 'record_provenance', side_effect=self.record_build), \
             mock.patch.object(run, 'RetentionRequestProtocol', FakeProtocol), \
             mock.patch.object(run, 'logged_process', side_effect=process):
            code = run.main([str(self.output)])
        return code, json.loads((self.output / 'execution.json').read_text())

    def test_compile_failure_does_not_launch_or_validate_application(self):
        code, record = self.invoke('compile-fails')
        self.assertEqual(code, 1)
        self.assertEqual(record['buildInvocations'], 1)
        self.assertEqual(record['processInvocations'], 0)
        self.assertEqual(len(self.calls), 1)
        self.assertTrue((self.output / 'compile.log').exists())

    def test_runtime_failure_preserves_partial_probe_without_retry(self):
        code, record = self.invoke('runtime-times-out')
        self.assertEqual(code, 1)
        self.assertEqual(record['processInvocations'], 1)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual((self.output / 'native-retention-probes.jsonl').read_text(), '{"partial":true}\n')
        self.assertFalse(json.loads((self.output / 'native-retention.summary.json').read_text())['evidenceValid'])

    def test_success_preserves_original_reports_and_verified_provenance_links(self):
        code, record = self.invoke('success')
        self.assertEqual(code, 0)
        self.assertEqual(record['status'], 'completed')
        self.assertEqual(record['processInvocations'], 1)
        raw = json.loads((self.output / 'native-retention.raw-report.json').read_text())
        enriched = json.loads((self.output / 'native-retention.json').read_text())
        self.assertNotIn('nativeRetentionProvenance', raw['runtime'])
        links = enriched['runtime']['nativeRetentionProvenance']
        self.assertEqual(links['helperSha256'], run.shared.digest(self.helper))
        self.assertEqual(links['nativeEngineSha256'], run.shared.digest(self.bundle / 'lib/libabc_engine.so'))
        self.assertTrue((self.output / 'helper' / self.helper.name).exists())
        self.assertFalse(record['memoryImprovementEstablished'])

    def test_unsupported_is_completed_inconclusive_and_never_improvement(self):
        code, record = self.invoke('unsupported')
        self.assertEqual(code, 0)
        self.assertEqual(record['status'], 'completed-inconclusive')
        self.assertFalse(record['allocatorAttributionAvailable'])
        self.assertFalse(record['memoryImprovementEstablished'])

    def test_after_run_binary_drift_cannot_be_rescued_by_validator_success(self):
        code, record = self.invoke('binary-changes')
        self.assertEqual(code, 1)
        self.assertEqual(record['status'], 'failed')
        self.assertIn('artifact changed', record['failure'])


if __name__ == '__main__':
    unittest.main()
