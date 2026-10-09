#!/usr/bin/env python3
"""Synthetic safety, attribution and false-pass contracts. No Chrome is run."""
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

import browser_load_diagnostic as diagnostic


class BrowserDiagnosticChecks(unittest.TestCase):
    def test_synchronize_uses_event_diff_and_skips_unrelated_change(self):
        before, head, base = 'a' * 40, 'b' * 40, 'c' * 40
        event = {'action': 'synchronize', 'before': before,
                 'pull_request': {'head': {'sha': head}, 'base': {'sha': base}}}
        observed = []
        def changes(left, right):
            observed.append((left, right))
            return ['README.md', 'lib/main.dart']
        result = diagnostic.scope_for_event('pull_request', event, None,
                                             lambda _sha: True, changes)
        self.assertEqual(observed, [(before, head)])
        self.assertFalse(result['run'])
        self.assertEqual(result['reason'], 'unrelated-event-diff-no-measurement')

    def test_opened_uses_base_to_head_and_manual_dispatch_is_explicit(self):
        before, head = 'a' * 40, 'b' * 40
        event = {'action': 'opened', 'pull_request': {
            'head': {'sha': head}, 'base': {'sha': before}}}
        pairs = []
        def changes(left, right):
            pairs.append((left, right))
            return ['tool/perf/browser_load_driver.mjs']
        self.assertTrue(diagnostic.scope_for_event('pull_request', event, None,
                                                   lambda _sha: True, changes)['run'])
        self.assertEqual(pairs, [(before, head)])
        self.assertTrue(diagnostic.scope_for_event('workflow_dispatch', {}, head,
                                                   lambda _sha: True, changes)['run'])
        self.assertEqual(pairs, [(before, head)])

    def test_unresolved_or_malformed_scope_commit_fails_closed(self):
        for before in (None, '', '--all', 'a' * 39, 'A' * 40):
            event = {'action': 'synchronize', 'before': before,
                     'pull_request': {'head': {'sha': 'b' * 40}}}
            with self.subTest(before=before), self.assertRaises(ValueError):
                diagnostic.scope_for_event('pull_request', event, None,
                                            lambda _sha: True, lambda *_args: [])
        with self.assertRaises(ValueError):
            diagnostic.scope_for_event('workflow_dispatch', {}, 'a' * 40,
                                        lambda _sha: False, lambda *_args: [])
        with self.assertRaises(ValueError):
            diagnostic.scope_for_event('pull_request', {'action': 'reopened'}, None,
                                        lambda _sha: True, lambda *_args: [])

    def test_kib_fields_remain_independent(self):
        actual = diagnostic.parse_kib('VmRSS: 12 kB\nVmHWM: 99 kB\nPss: 8 kB\nSeccomp: 2\n')
        self.assertEqual(actual, {'VmRSS': 12288, 'VmHWM': 101376, 'Pss': 8192})

    def test_missing_pss_is_null_not_zero_or_partial_sum(self):
        rows = [{'state': 'S', 'rssBytes': 100, 'pssBytes': 60},
                {'state': 'S', 'rssBytes': 200, 'pssBytes': None}]
        self.assertEqual(diagnostic.aggregate(rows),
                         {'processCount': 2, 'rssSumBytes': 300, 'pssSumBytes': None})

    def test_zombie_is_not_live_memory(self):
        self.assertEqual(diagnostic.aggregate([{'state': 'Z', 'rssBytes': None, 'pssBytes': None}]),
                         {'processCount': 0, 'rssSumBytes': None, 'pssSumBytes': None})

    def test_proc_identity_handles_spaces_and_parentheses(self):
        fields = ['S', '25'] + ['0'] * 17 + ['123456'] + ['0'] * 30
        self.assertEqual(diagnostic.proc_stat('101 (chrome (worker)) ' + ' '.join(fields)),
                         {'state': 'S', 'ppid': 25, 'startTicks': 123456})

    def test_no_renderer_or_unverified_sandbox_does_not_pass(self):
        self.assertFalse(diagnostic.sandbox_verified(None))
        self.assertFalse(diagnostic.sandbox_verified({'processes': []}))
        row = {'kind': 'renderer', 'sandbox': {'NoNewPrivs': '1', 'Seccomp': '2'}}
        self.assertTrue(diagnostic.sandbox_verified({'processes': [row]}))
        row['sandbox']['NoNewPrivs'] = '0'
        self.assertFalse(diagnostic.sandbox_verified({'processes': [row]}))

    def test_measurement_window_not_process_lifetime_hwm(self):
        samples = [{'monoNs': t, 'rssSumBytes': rss, 'pssSumBytes': pss}
                   for t, rss, pss in [(0, None, None), (11, 100, 80), (25, 400, 220),
                                        (35, 200, 120), (41, 120, 90), (55, None, None)]]
        stages = [{'type': 'stage', 'name': name, 'hostMonoNs': t} for name, t in
                  [('baseline-start', 10), ('load-start', 20), ('ready', 30), ('close-start', 40),
                   ('close-complete', 40), ('release-complete', 50)]]
        result = diagnostic.summarize_memory(samples, stages)
        self.assertEqual(result['baseline'], {'rssSumBytes': 100, 'pssSumBytes': 80})
        self.assertEqual(result['loadingPeak'], {'rssSumBytes': 400, 'pssSumBytes': 220})
        self.assertEqual(result['loadingPeakMinusBaseline'], {'rssSumBytes': 300, 'pssSumBytes': 140})
        self.assertEqual(result['releaseFromLifecyclePeak'], {'rssSumBytes': 280, 'pssSumBytes': 130})
        self.assertEqual(result['incompleteSampleCount'], 0)
        self.assertEqual(result['measurementWindowSampleCount'], 4)

    def test_failed_load_preserves_partial_peak_without_inventing_release(self):
        samples = [{'monoNs': 15, 'rssSumBytes': 100, 'pssSumBytes': 80},
                   {'monoNs': 25, 'rssSumBytes': 400, 'pssSumBytes': 220}]
        stages = [{'type': 'stage', 'name': n, 'hostMonoNs': t} for n, t in
                  [('baseline-start', 10), ('load-start', 20), ('driver-failed', 30)]]
        result = diagnostic.summarize_memory(samples, stages)
        self.assertEqual(result['loadingPeak']['rssSumBytes'], 400)
        self.assertIsNone(result['releaseFromLifecyclePeak'])
        self.assertIsNone(result['afterClose'])

    def test_strict_loading_excludes_later_idle_and_close_spikes(self):
        samples = [{'monoNs': t, 'rssSumBytes': amount, 'pssSumBytes': amount // 2}
                   for t, amount in [(11, 100), (20, 300), (29, 400), (30, 900),
                                      (35, 800), (40, 1200), (49, 200), (50, 150)]]
        stages = [{'type': 'stage', 'name': name, 'hostMonoNs': t} for name, t in
                  [('baseline-start', 10), ('load-start', 20), ('ready', 30),
                   ('close-start', 40), ('close-complete', 45), ('release-complete', 50)]]
        result = diagnostic.summarize_memory(samples, stages)
        self.assertEqual(result['loadingPeak']['rssSumBytes'], 400)
        self.assertEqual(result['readyIdlePeak']['rssSumBytes'], 900)
        self.assertEqual(result['lifecyclePeak']['rssSumBytes'], 1200)
        self.assertEqual(result['loadingPeakMinusBaseline']['rssSumBytes'], 300)
        self.assertEqual(result['lifecyclePeakMinusBaseline']['rssSumBytes'], 1100)
        self.assertEqual(result['releaseFromLifecyclePeak']['rssSumBytes'], 1050)
        self.assertEqual(result['phaseSampleCounts']['loading'], 2)
        self.assertEqual(result['phaseSampleCounts']['readyIdle'], 2)

    def test_unavailable_pss_does_not_discard_available_rss(self):
        samples = [{'monoNs': 15, 'rssSumBytes': 100, 'pssSumBytes': None},
                   {'monoNs': 25, 'rssSumBytes': 400, 'pssSumBytes': None}]
        stages = [{'type': 'stage', 'name': n, 'hostMonoNs': t} for n, t in
                  [('baseline-start', 10), ('load-start', 20), ('driver-failed', 30)]]
        result = diagnostic.summarize_memory(samples, stages)
        self.assertEqual(result['loadingPeak']['rssSumBytes'], 400)
        self.assertIsNone(result['loadingPeak']['pssSumBytes'])
        self.assertEqual(result['loadingPeakMinusBaseline']['rssSumBytes'], 300)
        self.assertEqual(result['incompleteSampleCount'], 2)

    def test_truncated_stream_keeps_received_rows_and_reports_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            journal = Path(temporary) / 'events.ndjson'
            journal.write_text('{"monoNs":12}\n{"monoNs":')
            rows, errors = diagnostic.read_rows(journal)
            self.assertEqual(rows, [{'monoNs': 12}])
            self.assertEqual(errors, ['invalid-json-line-2'])

    def test_malformed_archive_cannot_escape_destination(self):
        for name, kind in [('../outside', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('link', tarfile.SYMTYPE), ('fifo', tarfile.FIFOTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as output:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = '../../outside'
                    output.addfile(member)
                with self.assertRaises(ValueError):
                    diagnostic.extract(archive, Path(temporary) / 'destination')

    def test_regular_archive_extracts_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'web.tar.gz'
            with tarfile.open(archive, 'w:gz') as output:
                member = tarfile.TarInfo('./index.html')
                member.size = 4
                output.addfile(member, io.BytesIO(b'test'))
            diagnostic.extract(archive, root / 'web')
            self.assertEqual((root / 'web/index.html').read_bytes(), b'test')


if __name__ == '__main__':
    unittest.main()
