#!/usr/bin/env python3
"""Synthetic safety, attribution and false-pass contracts. No Chrome is run."""
import io
import json
from contextlib import ExitStack
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import browser_load_diagnostic as diagnostic


class BrowserDiagnosticChecks(unittest.TestCase):
    def test_cycle_push_scope_uses_only_exact_branch_and_current_event_diff(self):
        before, head = 'a' * 40, 'b' * 40
        event = {'ref': 'refs/heads/codex/diagnostic-browser-cycles',
                 'deleted': False, 'before': before, 'after': head}
        changes = mock.Mock(return_value=['tool/perf/browser_load_diagnostic.py'])
        result = diagnostic.scope_for_event('push', event, head, lambda _sha: True, changes)
        self.assertTrue(result['run'])
        changes.assert_called_once_with(before, head)
        changes.return_value = ['lib/main.dart']
        self.assertFalse(diagnostic.scope_for_event('push', event, head,
                                                    lambda _sha: True, changes)['run'])

    def test_first_cycle_branch_push_does_not_resolve_zero_before(self):
        head = 'b' * 40
        checked = []
        def exists(sha):
            checked.append(sha)
            return sha == head
        event = {'ref': 'refs/heads/codex/diagnostic-browser-cycles',
                 'deleted': False, 'before': '0' * 40, 'after': head}
        changes = mock.Mock(side_effect=AssertionError('No historical diff on branch creation'))
        result = diagnostic.scope_for_event('push', event, head, exists, changes)
        self.assertTrue(result['run'])
        self.assertNotIn('0' * 40, checked)
        self.assertIsNone(result['before'])

    def test_cycle_push_rejects_wrong_branch_deletion_invalid_or_unavailable_heads(self):
        head = 'b' * 40
        valid = {'ref': 'refs/heads/codex/diagnostic-browser-cycles',
                 'deleted': False, 'before': 'a' * 40, 'after': head}
        for override in ({'ref': 'refs/heads/main'}, {'ref': 'refs/heads/codex/diagnostic-browser-cycles-extra'},
                         {'deleted': True}, {'after': '0' * 40}, {'after': 'B' * 40},
                         {'after': '--all'}, {'before': None}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                diagnostic.scope_for_event('push', {**valid, **override}, head,
                                            lambda sha: sha in ('a' * 40, head), lambda *_: [])
        with self.assertRaises(ValueError):
            diagnostic.scope_for_event('push', valid, head, lambda _sha: False, lambda *_: [])
        with self.assertRaises(ValueError):
            diagnostic.scope_for_event('push', valid, 'c' * 40, lambda _sha: True, lambda *_: [])

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

    def test_chrome_process_title_and_normal_argv_have_same_strict_type(self):
        for args in (['/opt/google/chrome/chrome', '--type=renderer', '--lang=en-US', ''],
                     ['/opt/google/chrome/chrome --type=renderer --lang=en-US', ''],
                     ['chrome\t--type=renderer\n--lang=en-US']):
            self.assertEqual(diagnostic.chrome_process_kind(args), 'renderer')
        self.assertEqual(diagnostic.chrome_process_kind(['chrome', '--type=gpu-process']), 'gpu-process')

    def test_process_type_rejects_embedded_and_ambiguous_flags(self):
        for args in (['chrome', 'prefix--type=renderer'], ['chrome', '--label=--type=renderer'],
                     ['chrome', '--type=renderer/suffix'], ['chrome', '--type=renderer=other'],
                     ['chrome', '--user-data-dir=/tmp/path --type=renderer'],
                     ['chrome --label=\"text --type=renderer\"']):
            self.assertNotEqual(diagnostic.chrome_process_kind(args), 'renderer')
        self.assertEqual(diagnostic.chrome_process_kind(['chrome --type=renderer --type=utility']), 'unknown')
        self.assertEqual(diagnostic.chrome_process_kind(['chrome', '--type=renderer', '--type=renderer']), 'unknown')

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


class CycleMemoryChecks(unittest.TestCase):
    SECOND = 1000000000

    def fixture(self):
        stages, samples = [], []
        for cycle in range(1, 4):
            base = cycle * 100 * self.SECOND
            stamps = [base + i * self.SECOND for i in range(len(diagnostic.CYCLE_STAGES))]
            stamps[-1] = stamps[-2] + diagnostic.CYCLE_AFTER_CLOSE_MS * 1000000
            stages.extend({'type': 'stage', 'cycle': cycle, 'name': name, 'hostMonoNs': stamp}
                          for name, stamp in zip(diagnostic.CYCLE_STAGES, stamps))
            for stamp in range(base + self.SECOND // 2, stamps[-1], self.SECOND):
                rss = cycle * 100 if stamp >= stamps[-2] else cycle * 1000
                samples.append({'monoNs': stamp, 'rssSumBytes': rss, 'pssSumBytes': rss // 2})
        return samples, stages

    def test_three_cycle_windows_and_identical_after_close_deltas(self):
        samples, stages = self.fixture()
        result = diagnostic.summarize_cycle_memory(samples, stages)
        self.assertEqual(result['status'], 'observed')
        self.assertEqual([row['stageStatus'] for row in result['cycles']], ['complete'] * 3)
        for cycle, row in enumerate(result['cycles'], 1):
            memory = row['memory']
            self.assertEqual(memory['afterClose'], {'rssSumBytes': cycle * 100, 'pssSumBytes': cycle * 50})
            self.assertEqual(memory['lifecyclePeak']['rssSumBytes'], cycle * 1000)
            self.assertEqual(memory['afterCloseWindow']['sampleCount'], 20)
        self.assertEqual([row['deltaBytes'] for row in result['successiveAfterCloseDeltas']],
                         [{'rssSumBytes': 100, 'pssSumBytes': 50}] * 2)
        self.assertIn('no leak or stability threshold verdict', result['interpretation'])

    def test_post_close_tail_beyond_common_window_cannot_change_delta(self):
        samples, stages = self.fixture()
        release = next(row for row in stages if row['cycle'] == 1 and row['name'] == 'release-complete')
        samples.append({'monoNs': release['hostMonoNs'] + self.SECOND, 'rssSumBytes': 999999, 'pssSumBytes': 999999})
        samples.sort(key=lambda row: row['monoNs'])
        release['hostMonoNs'] += 5 * self.SECOND
        result = diagnostic.summarize_cycle_memory(samples, stages)
        self.assertEqual(result['cycles'][0]['memory']['afterClose']['rssSumBytes'], 100)
        self.assertEqual(result['successiveAfterCloseDeltas'][0]['deltaBytes']['rssSumBytes'], 100)

    def test_missing_cycle_and_truncated_prefix_cannot_consume_next_cycle_samples(self):
        samples, stages = self.fixture()
        stages = [row for row in stages if row['cycle'] == 2 or
                  (row['cycle'] == 1 and row['name'] in ('baseline-start', 'load-start'))]
        result = diagnostic.summarize_cycle_memory(samples, stages)
        first, second, third = result['cycles']
        self.assertEqual([row['stageStatus'] for row in result['cycles']], ['incomplete', 'complete', 'missing'])
        self.assertLess(first['memory']['lifecyclePeak']['rssSumBytes'], 2000)
        self.assertEqual(first['memory']['measurementWindow']['endMonoNsExclusive'],
                         second['stages']['baseline-start'])
        self.assertIsNone(first['memory']['afterClose'])
        self.assertIsNone(third['memory'])
        self.assertTrue(all(row['deltaBytes'] is None for row in result['successiveAfterCloseDeltas']))

    def test_fault_preserves_partial_peak_and_never_invents_release(self):
        samples, stages = self.fixture()
        stages = stages[:2] + [{'type': 'stage', 'cycle': 1, 'name': 'driver-failed',
                               'hostMonoNs': 103 * self.SECOND}]
        result = diagnostic.summarize_cycle_memory(samples, stages)
        first = result['cycles'][0]
        self.assertEqual(first['stageStatus'], 'failed')
        self.assertEqual(first['memory']['loadingPeak']['rssSumBytes'], 1000)
        self.assertEqual(first['memory']['measurementWindowSampleCount'], 3)
        self.assertIsNone(first['memory']['afterClose'])

    def test_duplicate_skipped_and_backwards_markers_fail_closed(self):
        for mutation in ('duplicate', 'skipped', 'backwards', 'timestamp', 'no-cycle'):
            samples, stages = self.fixture()
            if mutation == 'duplicate':
                stages.insert(2, dict(stages[1]))
            elif mutation == 'skipped':
                stages.pop(2)
            elif mutation == 'backwards':
                stages[1], stages[2] = stages[2], stages[1]
            elif mutation == 'timestamp':
                stages[1]['hostMonoNs'] = '123'
            else:
                stages[1].pop('cycle')
            with self.subTest(mutation=mutation):
                result = diagnostic.summarize_cycle_memory(samples, stages)
                self.assertEqual(result['status'], 'inconclusive')
                self.assertEqual(result['cycles'][0]['stageStatus'], 'invalid')
                self.assertIsNone(result['cycles'][0]['memory'])
                self.assertIsNone(result['successiveAfterCloseDeltas'][0]['deltaBytes'])

    def test_missing_pss_at_end_of_common_window_stays_null(self):
        samples, stages = self.fixture()
        close_sample = [row for row in samples if 116 * self.SECOND <= row['monoNs'] < 136 * self.SECOND][-1]
        close_sample['pssSumBytes'] = None
        result = diagnostic.summarize_cycle_memory(samples, stages)
        first = result['cycles'][0]['memory']
        self.assertEqual(first['afterClose']['rssSumBytes'], 100)
        self.assertIsNone(first['afterClose']['pssSumBytes'])
        self.assertIsNone(result['successiveAfterCloseDeltas'][0]['deltaBytes']['pssSumBytes'])
        self.assertEqual(result['successiveAfterCloseDeltas'][0]['deltaBytes']['rssSumBytes'], 100)
        self.assertEqual(result['status'], 'inconclusive')

    def test_empty_samples_and_incomplete_release_tail_are_inconclusive(self):
        samples, stages = self.fixture()
        result = diagnostic.summarize_cycle_memory([], stages)
        self.assertEqual(result['status'], 'inconclusive')
        self.assertIsNone(result['cycles'][0]['memory']['afterClose'])
        stages[17]['hostMonoNs'] -= self.SECOND
        result = diagnostic.summarize_cycle_memory(samples, stages)
        self.assertIsNone(result['cycles'][0]['memory']['afterClose'])
        self.assertFalse(result['cycles'][0]['memory']['afterCloseWindow']['completeElapsedWindow'])

    def test_non_atomic_sample_spanning_phase_boundary_is_excluded(self):
        samples, stages = self.fixture()
        samples[1]['sampleStartMonoNs'] = 100 * self.SECOND
        samples[1]['rssSumBytes'] = 999999
        result = diagnostic.summarize_cycle_memory(samples, stages)
        first = result['cycles'][0]['memory']
        self.assertIsNone(first['loadingPeak'])
        self.assertEqual(first['baseline']['rssSumBytes'], 1000)

    def test_invalid_sample_and_non_object_rows_cannot_produce_observed_status(self):
        samples, stages = self.fixture()
        samples.insert(1, {'monoNs': -1, 'rssSumBytes': -100, 'pssSumBytes': 0})
        stages.append(None)
        result = diagnostic.summarize_cycle_memory(samples, stages)
        self.assertEqual(result['status'], 'inconclusive')
        self.assertEqual(len(result['streamErrors']), 2)
        self.assertTrue(all(row['deltaBytes'] is None for row in result['successiveAfterCloseDeltas']))

    def test_wholly_unavailable_pss_never_becomes_zero(self):
        samples, stages = self.fixture()
        for row in samples:
            row['pssSumBytes'] = None
        result = diagnostic.summarize_cycle_memory(samples, stages)
        self.assertTrue(all(row['memory']['lifecyclePeak']['pssSumBytes'] is None
                            for row in result['cycles']))


class CycleBudgetChecks(unittest.TestCase):
    def test_sampler_evidence_cap_stops_whole_rows_and_keeps_known_rss_lower_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'samples.ndjson'
            sampler = diagnostic.Sampler(999991, output, max_output_bytes=1)
            sample = {'monoNs': 1, 'rssSumBytes': None, 'pssSumBytes': None,
                      'processes': [{'state': 'S', 'rssBytes': diagnostic.CYCLE_MAX_RSS_BYTES},
                                    {'state': 'S', 'rssBytes': None}]}
            sampler.sample = lambda: sample
            sampler.loop()
            self.assertEqual(output.read_bytes(), b'')
            self.assertIn('evidence size limit', sampler.failure)
            self.assertEqual(sampler.max_owned_rss_bytes, diagnostic.CYCLE_MAX_RSS_BYTES)
            self.assertIsNone(sampler.latest['rssSumBytes'])

    def test_resource_limit_terminates_only_owned_processes_and_persists_partial_evidence(self):
        class OwnedProcess:
            def __init__(self, pid):
                self.pid, self.returncode = pid, None
                self.stdout, self.stderr = io.BytesIO(), io.BytesIO()
                self.terminated = False

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminated, self.returncode = True, -15

            def wait(self, timeout=None):
                if self.returncode is None:
                    raise AssertionError('A resource-limit failure must terminate before waiting')
                return self.returncode

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            base = root / 'cycle'
            evidence, web = base / 'evidence', base / 'web'
            evidence.mkdir(parents=True)
            web.mkdir()
            for name in diagnostic.WEB_HASHES:
                path = web / name
                path.parent.mkdir(exist_ok=True)
                path.write_text('immutable test build')
            files = {p.relative_to(web).as_posix(): diagnostic.describe(p)
                     for p in web.rglob('*') if p.is_file()}
            pin = {'schema': 'abc.browser-product-pin.v1', 'label': 'synthetic-cleanup-test',
                   'commit': diagnostic.WEB_COMMIT, 'runId': '1', 'artifactId': 1,
                   'artifactZip': {'bytes': 1, 'sha256': '0' * 64},
                   'archive': {'bytes': 1, 'sha256': '0' * 64}, 'webFiles': files}
            diagnostic.dump(evidence / 'build.json', {'status': 'verified',
                'artifactSourceCommit': diagnostic.WEB_COMMIT, 'diagnosticSourceCommit': 'a' * 40,
                'artifactRunId': pin['runId'], 'artifactId': pin['artifactId'],
                'artifactZip': pin['artifactZip'], 'archive': pin['archive'],
                'webFiles': files, 'productPin': pin})
            profile = root / 'profile'
            profile.mkdir()
            (profile / 'DevToolsActivePort').write_text('9222\n')
            chrome = root / 'chrome'
            chrome.write_text('mocked Chrome; never execute')
            chrome.chmod(0o700)
            driver_file = root / 'tool/perf/browser_load_driver.mjs'
            driver_file.parent.mkdir(parents=True)
            driver_file.write_text('mocked Node driver; never execute')
            driver_file.with_name('browser_load_cycles.mjs').write_text('mocked cycle module; never execute')
            journal = evidence / 'os-memory.ndjson'
            journal.write_text('{"monoNs":101,"rssSumBytes":42,"pssSumBytes":21}\n')
            (evidence / 'browser-events.ndjson').write_text(
                '{"type":"stage","cycle":1,"name":"baseline-start","hostMonoNs":100}\n'
                '{"type":"stage","cycle":1,"name":"load-start","hostMonoNs":102}\n')
            diagnostic.dump(evidence / 'driver-result.json', {'status': 'failed', 'failure': 'partial driver evidence'})
            browser, driver = OwnedProcess(999991), OwnedProcess(999992)
            sampler = SimpleNamespace(pid=browser.pid, output=journal, known={}, failure=None,
                max_owned_rss_bytes=0, stop=mock.Mock(),
                thread=SimpleNamespace(start=mock.Mock(), join=mock.Mock(), is_alive=lambda: False),
                latest={'pssSumBytes': 21, 'processes': [{'kind': 'renderer',
                    'sandbox': {'NoNewPrivs': '1', 'Seccomp': '2'}}]})
            original_describe = diagnostic.describe
            def describe(path):
                if str(path).endswith('/computerraria.wld'):
                    return {'bytes': diagnostic.WORLD_SIZE, 'sha256': diagnostic.WORLD_SHA}
                return original_describe(path)
            server = SimpleNamespace(server_port=12345, serve_forever=lambda: None,
                                     shutdown=lambda: None, server_close=lambda: None)
            with ExitStack() as patches:
                for target, name, value in (
                    (diagnostic, 'ROOT', root), (diagnostic, 'CYCLE_BASE', base),
                    (diagnostic, 'CHROME', chrome), (diagnostic, 'describe', describe),
                    (diagnostic, 'command', lambda _args: 'mocked version'),
                    (diagnostic.os, 'getuid', lambda: 1000),
                    (diagnostic.platform, 'system', lambda: 'Linux'),
                    (diagnostic.platform, 'platform', lambda: 'mocked Linux'),
                    (diagnostic, 'Sampler', mock.Mock(return_value=sampler)),
                    (diagnostic.subprocess, 'Popen', mock.Mock(side_effect=[browser, driver])),
                    (diagnostic.http.server, 'ThreadingHTTPServer', mock.Mock(return_value=server)),
                    (diagnostic.tempfile, 'TemporaryDirectory', mock.Mock(return_value=SimpleNamespace(
                        name=str(profile), cleanup=lambda: None))),
                    (diagnostic, 'wait_cycle_driver', mock.Mock(return_value=(None, 'cycle-owned-rss-limit-6-gib'))),
                ):
                    patches.enter_context(mock.patch.object(target, name, value))
                patches.enter_context(mock.patch('builtins.print'))
                self.assertEqual(diagnostic.run(cycles=True), 1)
            report = json.loads((evidence / 'execution.json').read_text())
            self.assertTrue(browser.terminated and driver.terminated, report)
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['terminationRequested'], 'cycle-owned-rss-limit-6-gib')
            self.assertEqual(report['driverExit'], -15)
            self.assertEqual(report['browserExit']['returncode'], -15)
            self.assertEqual(report['memory']['cycles'][0]['stageStatus'], 'incomplete')
            self.assertEqual(report['driverResult']['failure'], 'partial driver evidence')
            self.assertIn('os-memory.ndjson', report['evidenceFiles'])

    def test_watchdog_checks_global_time_peak_rss_sampler_and_evidence_growth(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            guard = diagnostic.CycleGuard(evidence, started=0)
            sampler = SimpleNamespace(failure=None, max_owned_rss_bytes=0)
            self.assertIsNone(guard.reason(sampler, now=0))
            self.assertEqual(guard.reason(sampler, now=3270), 'cycle-global-deadline-cleanup-reserve')
            sampler.max_owned_rss_bytes = diagnostic.CYCLE_MAX_RSS_BYTES
            self.assertEqual(guard.reason(sampler, now=1), 'cycle-owned-rss-limit-6-gib')
            sampler.max_owned_rss_bytes = 0
            sampler.failure = 'disk full'
            self.assertIn('sampler-failure', guard.reason(sampler, now=1))
            sampler.failure = None
            with (evidence / 'sparse-evidence').open('wb') as output:
                output.truncate(diagnostic.CYCLE_MAX_EVIDENCE_BYTES)
            self.assertEqual(guard.reason(sampler, now=1), 'cycle-total-evidence-limit-512-mib')

    def test_child_log_retention_is_bounded_and_failure_is_visible(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'driver.log'
            output = diagnostic.BoundedLog(io.BytesIO(b'x' * 128), path, max_bytes=31)
            output.close()
            self.assertEqual(path.read_bytes(), b'x' * 31)
            self.assertTrue(output.limit_reached)
            self.assertFalse(output.thread.is_alive())
            guard = diagnostic.CycleGuard(Path(temporary), started=0)
            self.assertEqual(guard.reason(logs=[output], now=1), 'cycle-log-evidence-limit-or-read-failure')

    def test_driver_wait_polls_every_half_second_and_returns_limit_for_cleanup(self):
        driver = SimpleNamespace(poll=mock.Mock(side_effect=[None, None, None]))
        guard = SimpleNamespace(reason=mock.Mock(side_effect=[None, None, 'limit']))
        waits = []
        self.assertEqual(diagnostic.wait_cycle_driver(driver, guard, None, [], waits.append), (None, 'limit'))
        self.assertEqual(waits, [0.5, 0.5])
        self.assertEqual(driver.poll.call_count, 2)

    def test_driver_wait_returns_real_exit_status_without_unnecessary_sleep(self):
        driver = SimpleNamespace(poll=lambda: 7)
        guard = SimpleNamespace(reason=lambda *_: None)
        wait = mock.Mock(side_effect=AssertionError('No sleep after exit'))
        self.assertEqual(diagnostic.wait_cycle_driver(driver, guard, None, [], wait), (7, None))

    def test_baseline_schema_and_cycle_failure_evidence_are_distinct_without_browser(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with mock.patch.object(diagnostic, 'EVIDENCE', root / 'baseline'), \
                 mock.patch.object(diagnostic, 'CYCLE_BASE', root / 'cycles'), \
                 mock.patch('builtins.print'), \
                 mock.patch.object(diagnostic.subprocess, 'Popen', side_effect=AssertionError('No browser allowed')):
                self.assertEqual(diagnostic.run(), 1)
                baseline = json.loads((root / 'baseline/execution.json').read_text())
                self.assertEqual(baseline['schema'], 'abc.browser-load-diagnostic.v1')
                self.assertNotIn('requestedCycles', baseline)
                self.assertEqual(diagnostic.run(cycles=True), 1)
                cycles = json.loads((root / 'cycles/evidence/execution.json').read_text())
                self.assertEqual(cycles['schema'], 'abc.browser-cycle-diagnostic.v1')
                self.assertEqual(cycles['status'], 'failed')
                self.assertEqual(cycles['requestedCycles'], 3)
                self.assertEqual(cycles['budgets']['globalSeconds'], 3300)
                self.assertIsNone(cycles['browserExit'])


if __name__ == '__main__':
    unittest.main()
