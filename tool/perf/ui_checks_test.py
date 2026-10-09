"""Evidence gate tests, including false-pass prevention."""
from collections import Counter
from itertools import count, product
import unittest
from unittest.mock import patch

import ui_compare
import ui_validate


_run_ids = count()


def report(value=10):
    return {
        'schema': 'abc.performance.v1', 'suite': 'flutter-ui',
        'runId': f'test-{next(_run_ids)}',
        'buildMode': 'profile', 'status': 'passed', 'tier': 'synthetic-small-ui',
        'iterations': 3, 'warmup': 1,
        'runtime': {'platform': 'linux', 'osVersion': 'test', 'dartVersion': 'test',
                    'flutterVersion': 'test', 'commit': 'test-revision', 'runner': 'test-runner',
                    'checkedOutHead': 'test-checkout', 'workingTreeDirty': False,
                    'renderer': 'measured-software-renderer', 'physicalWidth': 1280,
                    'physicalHeight': 720, 'devicePixelRatio': 1},
        'fixtures': [{'id': 'synthetic'}],
        'operations': [{
            'id': op, 'iterations': 3, 'status': 'passed', 'frameCount': 9,
            'medianMs': value, 'p95Ms': value, 'overBudgetFrames': 0,
            'ui': {'p95Us': value}, 'raster': {'p95Us': value},
            'samples': [{'success': True, 'uiUs': [value], 'rasterUs': [value]}] * 3,
        } for op in sorted(ui_validate.REQUIRED)],
        'memory': [{'cycle': cycle, 'warmup': cycle == 0,
                    'rssBytes': 100, 'heapUsedBytes': 50, 'externalBytes': 0}
                   for cycle in range(4)],
        'controllerOperations': [{'id': 'dispatch.' + action, 'action': action,
                                 'sampleCount': 3, 'samples': [{'durationMs': value}] * 3,
                                 'medianMs': value, 'p95Ms': value}
                                for action in sorted(ui_validate.REQUIRED_DISPATCHES)],
    }


class EvidenceGateTests(unittest.TestCase):
    def test_complete_structural_report(self):
        self.assertEqual(ui_validate.validate(report()), [])

    def test_debug_or_missing_frames_cannot_pass(self):
        candidate = report()
        candidate['buildMode'] = 'debug-smoke-not-performance'
        self.assertTrue(ui_validate.validate(candidate))
        candidate = report()
        candidate['operations'][0]['frameCount'] = 0
        self.assertTrue(ui_validate.validate(candidate))

    def test_missing_operation_or_heap_cannot_pass(self):
        candidate = report()
        candidate['operations'].pop()
        self.assertTrue(ui_validate.validate(candidate))
        candidate = report()
        candidate['memory'][-1]['heapUsedBytes'] = None
        self.assertTrue(ui_validate.validate(candidate))

    def test_missing_renderer_cannot_pass(self):
        candidate = report()
        candidate['runtime']['renderer'] = 'unspecified'
        self.assertTrue(ui_validate.validate(candidate))

    def test_macro_coverage_cannot_replace_controller_samples(self):
        candidate = report()
        candidate['controllerOperations'] = []
        self.assertTrue(ui_validate.validate(candidate))

    def test_missing_baseline_is_inconclusive(self):
        self.assertEqual(ui_compare.compare([report()], [report()])['status'], 'inconclusive')

    def test_device_mismatch_is_inconclusive(self):
        candidate = report()
        candidate['runtime']['renderer'] = 'different-gpu'
        self.assertEqual(ui_compare.compare([report()] * 5, [candidate] * 5)['status'], 'inconclusive')

    def test_measured_noise_and_regression(self):
        # Exercise the statistical decision independently of the number of app actions.
        with patch.object(ui_compare, 'metrics', lambda r: {'latency': r['operations'][0]['medianMs']}):
            baseline = [report(v) for v in [9, 10, 11, 10, 9]]
            same = [report(v) for v in [9, 10, 11, 10, 9]]
            slow = [report(v) for v in [30, 31, 29, 32, 30]]
            self.assertEqual(ui_compare.compare(baseline, same)['status'], 'no-detected-regression')
            self.assertEqual(ui_compare.compare(baseline, slow)['status'], 'regression')

    def test_repeated_report_is_not_independent_evidence(self):
        self.assertEqual(ui_compare.compare([report()] * 5, [report()] * 5)['status'], 'inconclusive')

    def test_exact_bootstrap_matches_exhaustive_odd_and_even_samples(self):
        for n in range(1, 6):
            expected = Counter()
            for sample in product(range(n), repeat=n):
                ordered = sorted(sample)
                expected[(ordered[(n - 1)//2], ordered[n//2])] += 1
            self.assertEqual(ui_compare.median_rank_masses(n), expected)


if __name__ == '__main__':
    unittest.main()
