#!/usr/bin/env python3
"""Small proc/serialization tests; no Flutter, native build, or workload run."""

from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

import memory_probe_control_os as sampler


class ParsingTests(unittest.TestCase):
    def test_stat_command_parentheses_do_not_move_starttime(self):
        fields = ['S', '123', '456'] + ['0'] * 16 + ['987654']
        value = sampler._parse_stat('789 (name (spaces) )) ' + ' '.join(fields), 789)
        self.assertEqual((value.pid, value.ppid, value.pgid, value.starttime),
                         (789, 123, 456, 987654))
        with self.assertRaises(sampler.ProcessOwnershipError):
            sampler._parse_stat('789 (name) S 123 456', 789)
        with self.assertRaises(sampler.ProcessOwnershipError):
            sampler._parse_stat('789 (name) ' + ' '.join(fields), 790)

    def test_status_requires_valid_memory_fields_and_exact_uid(self):
        text = 'Uid:\t42\t42\t42\t42\nVmRSS:\t123 kB\nVmHWM:\t456 kB\n'
        self.assertEqual(sampler._status_values(text, 42),
                         {'rssBytes': 123 * 1024, 'processVmHwmBytes': 456 * 1024})
        for invalid in (text.replace('VmRSS', 'Other'), text.replace('123 kB', '-1 kB'),
                        text.replace('123 kB', '123 MB'), text + 'VmRSS: 1 kB\n',
                        text.replace('Uid:\t42', 'Uid:\t43')):
            with self.subTest(invalid=invalid), self.assertRaises(sampler.SamplerError):
                sampler._status_values(invalid, 42)

    def test_rollup_uss_and_unknown_optional_hugetlb(self):
        text = 'Rss: 100 kB\nPss: 80 kB\nPrivate_Clean: 11 kB\nPrivate_Dirty: 12 kB\n'
        old = sampler._smaps_values(text)
        self.assertEqual(old['ussBytes'], 23 * 1024)
        self.assertIsNone(old['privateHugetlbBytes'])
        self.assertFalse(old['ussIncludesPrivateHugetlb'])
        current = sampler._smaps_values(text + 'Private_Hugetlb: 13 kB\n')
        self.assertEqual(current['ussBytes'], 36 * 1024)
        self.assertTrue(current['ussIncludesPrivateHugetlb'])
        with self.assertRaises(sampler.SamplerError):
            sampler._smaps_values(text.replace('Pss:', 'Other:'))

    def test_endpoint_metadata_is_bounded_and_scalar(self):
        original = {'sequence': 7, 'cycle': -1, 'dartTimeUs': 123, 'flag': True,
                    'label': 'baseline', 'ratio': 0.5, 'unknown': None}
        self.assertEqual(sampler._point_metadata('baseline', original), original)
        for metadata in ({'rows': []}, {'value': float('nan')}, {'value': float('inf')},
                         {'value': 'x' * 257}, {'value': 2 ** 63},
                         {str(index): index for index in range(17)}):
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                sampler._point_metadata('baseline', metadata)
        for phase in ('', 'x' * 129, 'line\nbreak'):
            with self.assertRaises(ValueError):
                sampler._point_metadata(phase, None)


@unittest.skipUnless(sys.platform.startswith('linux') and Path('/proc/self/smaps_rollup').exists(),
                     'Linux proc status and smaps_rollup are required')
class OwnedProcessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / 'application.os.jsonl'
        self.children = []
        self.samplers = []
        self.addCleanup(self.stop_owned_children)

    def stop_owned_children(self):
        for value in self.samplers:
            try:
                value.finish()
            except sampler.SamplerError:
                pass
        for child in self.children:
            if not child.stdin.closed:
                child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()

    def launch(self, descendant=False):
        code = ('import sys; print("ready", flush=True); sys.stdin.readline()')
        if descendant:
            code = ('import subprocess, sys; '
                    'p=subprocess.Popen([sys.executable,"-c",'
                    '"import sys; sys.stdin.readline()"], stdin=subprocess.PIPE); '
                    'print(p.pid, flush=True); sys.stdin.readline(); '
                    'p.stdin.close(); p.wait()')
        child = subprocess.Popen([sys.executable, '-u', '-c', code],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.children.append(child)
        line = child.stdout.readline().strip()
        return child, int(line) if descendant else child.pid

    def start_sampler(self):
        child, pid = self.launch()
        value = sampler.ExternalOsSampler(pid, child.pid, self.output)
        self.samplers.append(value)
        value.start()
        return child, value

    def test_direct_child_and_descendant_are_verified(self):
        for descendant in (False, True):
            child, pid = self.launch(descendant)
            identity = sampler.process_identity(pid, child.pid)
            self.assertEqual(identity['pid'], pid)
            self.assertEqual(identity['uid'], os.getuid())
            self.assertEqual(identity['processGroupId'], child.pid)
            self.assertEqual(identity['runnerPid'], os.getpid())
            self.assertGreater(identity['starttimeTicks'], 0)

    def test_self_wrong_group_and_non_descendant_are_rejected_before_memory_reads(self):
        child, pid = self.launch()
        other, _ = self.launch()
        original = sampler._read_fd_text
        accessed = []

        def record(directory_fd, name):
            accessed.append(name)
            return original(directory_fd, name)

        with mock.patch.object(sampler, '_read_fd_text', side_effect=record):
            for target, group in ((os.getpid(), child.pid), (pid, other.pid),
                                  (pid, os.getpgrp()), (True, child.pid), (pid, 0)):
                with self.subTest(target=target, group=group):
                    with self.assertRaises(sampler.ProcessOwnershipError):
                        sampler.process_identity(target, group)
            # Simulate a selected child's ancestry becoming unrelated, while
            # keeping its target stat/UID/group otherwise valid.
            original_stat = sampler._parse_stat

            def detached(text, expected_pid):
                value = original_stat(text, expected_pid)
                return replace(value, ppid=0) if expected_pid == pid else value

            with mock.patch.object(sampler, '_parse_stat', side_effect=detached):
                with self.assertRaises(sampler.ProcessOwnershipError):
                    sampler.process_identity(pid, child.pid)
        self.assertTrue(accessed)
        self.assertEqual(set(accessed), {'stat'})

    def test_endpoint_flushes_rows_with_independent_clocks_and_bounded_manifest(self):
        _child, value = self.start_sampler()
        row = value.point('after-close', {'sequence': 2, 'cycle': 0, 'dartTimeUs': 999})
        # The endpoint is persisted before returning, so an ack is safe now.
        rows = [json.loads(line) for line in self.output.read_text().splitlines()]
        self.assertIn(row, rows)
        self.assertEqual(row['metadata']['sequence'], 2)
        self.assertEqual(row['clockDomain'], 'python.time.monotonic_ns')
        self.assertEqual(row['metadataClockDomains']['dartTimeUs'], 'dart:developer.Timeline.now')
        self.assertLessEqual(row['timeNs'], row['statusEndNs'])
        self.assertLessEqual(row['statusEndNs'], row['smapsTimeNs'])
        self.assertLessEqual(row['smapsTimeNs'], row['smapsEndNs'])
        self.assertGreater(row['rssBytes'], 0)
        self.assertGreater(row['pssBytes'], 0)
        manifest = value.finish()
        payload = self.output.read_bytes()
        self.assertEqual(manifest['status'], 'completed')
        self.assertTrue(manifest['complete'])
        self.assertEqual(manifest['file'], self.output.name)
        self.assertNotIn(str(self.output.parent), json.dumps(manifest))
        self.assertEqual(manifest['sha256'], hashlib.sha256(payload).hexdigest())
        self.assertEqual(manifest['bytes'], len(payload))
        self.assertEqual(manifest['namedPointSamples'], 1)
        self.assertEqual(manifest['statusSamples'], len(payload.splitlines()))
        self.assertFalse(manifest['crossClockSubtractionAllowed'])
        self.assertEqual(value.finish(), manifest)
        self.assertFalse(any(isinstance(item, list) for item in vars(value).values()))
        with self.assertRaises(sampler.SamplerError):
            value.point('too-late')

    def test_periodic_status_and_rollup_rows_are_streamed(self):
        _child, value = self.start_sampler()
        periodic_rollup = threading.Event()
        original = value._sample

        def observe(phase, metadata, include_smaps, point):
            row = original(phase, metadata, include_smaps, point)
            if phase == 'periodic' and include_smaps:
                periodic_rollup.set()
            return row

        with mock.patch.object(value, '_sample', side_effect=observe):
            self.assertTrue(periodic_rollup.wait(timeout=2))
            manifest = value.finish()
        rows = [json.loads(line) for line in self.output.read_text().splitlines()]
        self.assertEqual([row['sequence'] for row in rows], list(range(len(rows))))
        self.assertGreater(manifest['statusSamples'], manifest['smapsSamples'])
        self.assertGreaterEqual(manifest['smapsSamples'], 2)
        self.assertEqual(manifest['targetStatusIntervalNs'], 10_000_000)
        self.assertEqual(manifest['targetSmapsIntervalNs'], 100_000_000)

    def test_pid_reuse_is_rejected_without_another_memory_read(self):
        child, value = self.start_sampler()
        original = sampler._parse_stat
        memory_reads = []
        original_read = sampler._read_fd_text

        def reused(text, expected_pid):
            result = original(text, expected_pid)
            return replace(result, starttime=result.starttime + 1) if expected_pid == child.pid else result

        def record(directory_fd, name):
            if name != 'stat':
                memory_reads.append(name)
            return original_read(directory_fd, name)

        with mock.patch.object(sampler, '_parse_stat', side_effect=reused), \
                mock.patch.object(sampler, '_read_fd_text', side_effect=record):
            with self.assertRaisesRegex(sampler.SamplerError, 'identity changed'):
                value.point('must-fail')
            with self.assertRaises(sampler.SamplerError):
                value.finish()
        self.assertEqual(memory_reads, [])
        self.assertFalse(value.manifest['complete'])
        self.assertEqual(value.manifest['status'], 'failed')
        self.assertTrue(self.output.read_bytes())

    def test_background_error_propagates_and_preserves_successful_raw(self):
        _child, value = self.start_sampler()
        failed = threading.Event()

        def fail(_name):
            failed.set()
            raise OSError('simulated proc read failure')

        with mock.patch.object(value._process, 'read', side_effect=fail):
            self.assertTrue(failed.wait(timeout=2))
            with self.assertRaisesRegex(sampler.SamplerError, 'simulated proc read failure'):
                value.check()
            with self.assertRaises(sampler.SamplerError):
                value.point('cannot-ack')
            with self.assertRaises(sampler.SamplerError):
                value.finish()
        rows = [json.loads(line) for line in self.output.read_text().splitlines()]
        self.assertTrue(rows)
        self.assertTrue(all(row['rssBytes'] > 0 for row in rows))
        self.assertFalse(any(row['phase'] == 'cannot-ack' for row in rows))
        self.assertEqual(value.manifest['status'], 'failed')

    def test_identity_change_during_memory_read_discards_the_unverified_row(self):
        child, value = self.start_sampler()
        original_stat = sampler._parse_stat
        original_read = sampler._read_fd_text
        changed = threading.Event()

        def reuse_after_read(directory_fd, name):
            text = original_read(directory_fd, name)
            if name == 'status':
                changed.set()
            return text

        def changed_identity(text, expected_pid):
            result = original_stat(text, expected_pid)
            if expected_pid == child.pid and changed.is_set():
                return replace(result, starttime=result.starttime + 1)
            return result

        with value._lock:
            prior = self.output.read_bytes()
            with mock.patch.object(sampler, '_parse_stat', side_effect=changed_identity), \
                    mock.patch.object(sampler, '_read_fd_text', side_effect=reuse_after_read):
                with self.assertRaisesRegex(sampler.SamplerError, 'identity changed'):
                    value.point('unverified-read')
        with self.assertRaises(sampler.SamplerError):
            value.finish()
        self.assertTrue(changed.is_set())
        self.assertEqual(self.output.read_bytes(), prior)

    def test_application_exit_is_failure_and_existing_evidence_is_immutable(self):
        child, value = self.start_sampler()
        child.stdin.close()
        child.wait(timeout=5)
        with self.assertRaises(sampler.SamplerError):
            value.point('after-exit')
        with self.assertRaises(sampler.SamplerError):
            value.finish()
        preserved = self.output.read_bytes()
        fresh_child, pid = self.launch()
        another = sampler.ExternalOsSampler(pid, fresh_child.pid, self.output)
        self.samplers.append(another)
        with self.assertRaisesRegex(sampler.SamplerError, 'new writable file'):
            another.start()
        self.assertEqual(self.output.read_bytes(), preserved)


if __name__ == '__main__':
    unittest.main()
