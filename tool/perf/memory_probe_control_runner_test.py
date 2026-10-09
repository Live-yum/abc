#!/usr/bin/env python3
"""Focused runner tests. No Flutter, benchmark, network or GitHub execution."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import memory_probe_control_run as runner


class FakeSampler:
    def __init__(self, pid, pgid, output):
        if pid != 1234 or pgid != 123:
            raise ValueError('Host is not an owned descendant')
        self.pid, self.pgid, self.output = pid, pgid, output
        self.rows = []
        self.started = self.finished = False

    def start(self):
        self.started = True

    def check(self):
        if not self.started:
            raise ValueError('Not started')

    def point(self, phase, metadata=None):
        row = {'phase': phase, 'metadata': metadata, 'timeNs': 987654321}
        self.rows.append(row)
        return row

    def finish(self):
        self.finished = True
        return self.manifest

    @property
    def manifest(self):
        return {'file': self.output.name, 'complete': self.finished,
                'processIdentity': {'pid': self.pid, 'processGroupId': self.pgid}}


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'acks').mkdir()
        self.requests = self.root / 'requests.jsonl'
        self.protocol = runner.RequestProtocol(self.requests, self.root / 'acks',
                                               self.root / 'external-os.jsonl',
                                               123, 'probe-only', FakeSampler)

    def request(self, sequence=0, kind='hello', **overrides):
        return {'kind': kind, 'sequence': sequence, 'hostPid': 1234,
                'phase': kind, 'cycle': -1, 'dartTimeUs': 456789, **overrides}

    def append(self, value):
        with self.requests.open('a') as output:
            output.write(json.dumps(value) + '\n')

    def test_exact_handshake_point_finish_and_metadata(self):
        hello = self.request()
        point = self.request(1, 'point', phase='baseline.pre')
        finish = self.request(2, 'finish', cycle=8, phase='recording-stopped')
        for value in (hello, point, finish):
            self.append(value)
            self.protocol.poll()
        self.protocol.poll(final=True)
        self.assertEqual(self.protocol.sequence, 3)
        self.assertTrue(self.protocol.finished)
        self.assertTrue(self.protocol.descriptor()['ownedProcess'])
        self.assertEqual(self.protocol.descriptor()['endpointRequests'], 3)
        row = json.loads((self.root / 'acks/ack-1.json').read_text())
        self.assertEqual(row['row']['metadata'], {**point, 'controlArm': 'probe-only'})
        self.assertEqual(row['row']['timeNs'], 987654321)
        self.assertEqual(list((self.root / 'acks').glob('*.tmp')), [])

    def test_partial_line_is_not_consumed(self):
        line = json.dumps(self.request()).encode()
        self.requests.write_bytes(line[:30])
        self.protocol.poll()
        self.assertEqual(self.protocol.sequence, 0)
        with self.requests.open('ab') as output:
            output.write(line[30:] + b'\n')
        self.protocol.poll()
        self.assertEqual(self.protocol.sequence, 1)

    def test_unowned_pid_gets_negative_ack(self):
        self.append(self.request(hostPid=9999))
        with self.assertRaisesRegex(ValueError, 'owned descendant'):
            self.protocol.poll()
        ack = json.loads((self.root / 'acks/ack-0.json').read_text())
        self.assertFalse(ack['ok'])

    def test_duplicate_sequence_cannot_overwrite_ack(self):
        self.append(self.request())
        self.protocol.poll()
        ack = (self.root / 'acks/ack-0.json').read_bytes()
        self.append(self.request())
        with self.assertRaisesRegex(ValueError, 'duplicated'):
            self.protocol.poll()
        self.assertEqual((self.root / 'acks/ack-0.json').read_bytes(), ack)

    def test_changed_pid_rejected(self):
        self.append(self.request())
        self.protocol.poll()
        self.append(self.request(1, 'point', hostPid=4321))
        with self.assertRaisesRegex(ValueError, 'verified hello host'):
            self.protocol.poll()
        self.assertFalse(json.loads((self.root / 'acks/ack-1.json').read_text())['ok'])

    def test_no_finish_rejected(self):
        self.append(self.request())
        self.protocol.poll()
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            self.protocol.poll(final=True)

    def test_oversize_unterminated_line_rejected(self):
        self.requests.write_bytes(b'x' * (runner.MAX_LINE_BYTES + 1))
        with self.assertRaisesRegex(ValueError, 'byte budget'):
            self.protocol.poll()

    def test_replaced_or_truncated_file_rejected(self):
        self.append(self.request())
        self.protocol.poll()
        self.requests.write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'truncated'):
            self.protocol.poll()

    def test_extra_fields_rejected(self):
        self.append(self.request(secret='must-not-be-copied'))
        with self.assertRaisesRegex(ValueError, 'six protocol fields'):
            self.protocol.poll()
        self.assertNotIn('must-not-be-copied', (self.root / 'acks/ack-0.json').read_text())

    def test_symlink_request_rejected(self):
        other = self.root / 'other'
        other.write_text(json.dumps(self.request()) + '\n')
        self.requests.symlink_to(other)
        with self.assertRaises(OSError):
            self.protocol.poll()


class InvariantTests(unittest.TestCase):
    def test_only_allowed_diagnostic_paths(self):
        for path in (runner.ORIGINAL_TEST, runner.TARGET,
                     'tool/perf/memory_probe_control_run.py',
                     '.github/workflows/memory-probe-control.yml'):
            self.assertTrue(runner.overlay_allowed(path))
        for path in ('lib/main.dart', 'tool/perf/computer_memory_run.py',
                     'tool/perf/memory_probe_control/../../native/engine.c',
                     '.github/workflows/ci.yml'):
            self.assertFalse(runner.overlay_allowed(path))

    def test_only_exact_original_rename_and_lint_comment(self):
        before = b'Future<_ObservedBackend> _cycle({\n}\nawait _cycle(\n);\n'
        expected = before.replace(b'_cycle(', b'runComputerMemoryDiagnosticCycle(')
        expected = b'// ignore: library_private_types_in_public_api\n' + expected
        sha = hashlib.sha256(before).hexdigest()
        runner.validate_original_change(before, expected, sha)
        with self.assertRaises(runner.InvariantError):
            runner.validate_original_change(before, expected + b'// another edit\n', sha)

    def test_current_product_bytes_must_match_base_blob(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'product.dart'
            data = b'unchanged product source\n'
            path.write_bytes(data)
            oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            self.assertEqual(runner.product_hash(path, '100644', oid), hashlib.sha256(data).hexdigest())
            path.write_bytes(b'changed product source\n')
            with self.assertRaises(runner.InvariantError):
                runner.product_hash(path, '100644', oid)

    def test_sensitive_driver_lines_are_redacted(self):
        source = io.BytesIO(b'VM: http://127.0.0.1:1234/SECRET=/ws\nAuthorization: Bearer SECRET\n')
        output, state = io.StringIO(), {}
        runner.drain_log(source, output, state)
        self.assertNotIn('SECRET', output.getvalue())
        self.assertNotIn('http://127.0.0.1', output.getvalue())
        self.assertNotIn('error', state)

    def test_old_output_is_never_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(SystemExit, 'immutable'):
                runner.main([temporary])

    def test_timeout_is_preserved_without_unsafe_flag_or_retry(self):
        class Process:
            pid = 123
            returncode = None
            stdout = io.BytesIO(b'Driver started\n')
            def poll(self):
                return self.returncode
        process = Process()
        def terminate(value):
            value.returncode = -15
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source.json').write_text('{}')
            with patch.object(runner, 'ROOT', root), patch.object(runner, 'BUILD_SECONDS', -1), \
                    patch.object(runner, 'check_source_unchanged'), \
                    patch.object(runner.subprocess, 'Popen', return_value=process) as launch, \
                    patch.object(runner, 'stop_group', side_effect=terminate) as stop:
                record, unsafe = runner.run_arm('probe-only', root, 'a' * 40,
                                                {'scheduleSha256': 'b' * 64}, 'flutter', '3.47.6',
                                                'llvmpipe', time.monotonic() + 2000)
            self.assertEqual(record['status'], 'timeout')
            self.assertFalse(unsafe)
            self.assertEqual(record['processInvocations'], 1)
            launch.assert_called_once()
            stop.assert_called_once()
            self.assertTrue((root / 'probe-only/control.execution.json').is_file())
            self.assertTrue((root / 'probe-only/control.summary.json').is_file())


class SourcePreflightTests(unittest.TestCase):
    """A tiny temporary Git repository exercises real derivation/hash checks."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repo = self.directory / 'repo'
        self.repo.mkdir()
        self.output = self.directory / 'evidence'
        self.output.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Runner unit test')
        self.git('config', 'user.email', 'runner-test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.write('lib/product.dart', b'product bytes\n')
        self.write('.flutter-version', b'3.47.6\n')
        original = b'Future<_ObservedBackend> _cycle({\n}\nawait _cycle(\n);\n'
        self.write(runner.ORIGINAL_TEST, original)
        self.git('add', '.')
        self.git('commit', '-qm', 'Test product base')
        self.base = self.git('rev-parse', 'HEAD').decode().strip()
        replacement = original.replace(b'_cycle(', b'runComputerMemoryDiagnosticCycle(')
        self.write(runner.ORIGINAL_TEST,
                   b'// ignore: library_private_types_in_public_api\n' + replacement)
        for name in (runner.TARGET, 'tool/perf/memory_probe_control_run.py',
                     'tool/perf/memory_probe_control_os.py',
                     'tool/perf/memory_probe_control_rss.py',
                     'tool/perf/memory_probe_control_validate.py',
                     'integration_test/support/computer_memory_probe_telemetry.dart'):
            self.write(name, b'diagnostic overlay\n')
        schedule = {'schema': 'abc.memory-probe-control-schedule.v1',
                    'source': {'commit': self.base}, 'plannedCycles': 8,
                    'plannedVmProbes': 17, 'points': [{}] * 17}
        self.write(runner.SCHEDULE, json.dumps(schedule).encode())
        schedule_hash = runner.digest(self.repo / runner.SCHEDULE)
        manifest = {'schema': 'abc.memory-probe-control-manifest.v1', 'baseCommit': self.base,
                    'productChangeAllowed': False, 'arms': list(runner.ARMS),
                    'processInvocationsPerArm': 1, 'runtimeSecondsPerArm': 600,
                    'buildSecondsPerArm': 300, 'plannedCycles': 8, 'plannedCheckpoints': 17,
                    'schedule': runner.SCHEDULE, 'scheduleSha256': schedule_hash,
                    'vmCallsByArm': {'probe-only': 17, 'product-os-only': 0},
                    'originalTestBaseSha256': hashlib.sha256(original).hexdigest()}
        self.write('tool/perf/memory_probe_control_manifest.json', json.dumps(manifest).encode())
        self.git('add', '.')
        self.git('commit', '-qm', 'Test diagnostic overlay')
        self.head = self.git('rev-parse', 'HEAD').decode().strip()
        derivation = {'schema': 'abc.memory-probe-control-derivation.v1', 'baseCommit': self.base,
                      'derivedCommit': self.head, 'overlaySourceCommit': 'b' * 40,
                      'derivedTree': self.git('rev-parse', 'HEAD^{tree}').decode().strip(),
                      'scheduleSha256': schedule_hash,
                      'patchSha256': hashlib.sha256(self.git('diff', '--no-color', '--binary',
                                                            '--full-index', self.base, self.head)).hexdigest(),
                      'overlayFilesSha256': {
                          str(path.relative_to(self.repo)): runner.digest(path)
                          for path in self.repo.rglob('*') if path.is_file()
                          and runner.overlay_allowed(str(path.relative_to(self.repo)))}}
        self.derivation = self.directory / 'derivation.json'
        self.derivation.write_text(json.dumps(derivation))
        self.addCleanup(patch.stopall)
        patch.object(runner, 'ROOT', self.repo).start()
        patch.object(runner, 'BASE_COMMIT', self.base).start()
        patch.dict(os.environ, {'ABC_CONTROL_BASE_COMMIT': self.base,
                                'ABC_CONTROL_DERIVED_COMMIT': self.head,
                                'ABC_CONTROL_MANIFEST': str(self.repo / 'tool/perf/memory_probe_control_manifest.json'),
                                'ABC_CONTROL_DERIVATION': str(self.derivation)}).start()

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=10, check=True).stdout

    def write(self, name, data):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_clean_derived_snapshot_passes_and_records_product_hashes(self):
        head, provenance = runner.source_preflight(self.output)
        self.assertEqual(head, self.head)
        self.assertTrue(provenance['productPathsUnchanged'])
        self.assertIn('lib/product.dart', provenance['productFiles'])
        self.assertTrue((self.output / 'derivation.json').is_file())

    def test_assume_unchanged_does_not_hide_product_edits(self):
        self.git('update-index', '--assume-unchanged', 'lib/product.dart')
        self.write('lib/product.dart', b'changed bytes\n')
        self.assertFalse(self.git('status', '--porcelain'))
        with self.assertRaisesRegex(runner.InvariantError, 'bytes differ'):
            runner.source_preflight(self.output)

    def test_tampered_derivation_is_rejected(self):
        value = json.loads(self.derivation.read_text())
        value['patchSha256'] = '0' * 64
        self.derivation.write_text(json.dumps(value))
        with self.assertRaisesRegex(runner.InvariantError, 'derivation manifest'):
            runner.source_preflight(self.output)


if __name__ == '__main__':
    unittest.main()
