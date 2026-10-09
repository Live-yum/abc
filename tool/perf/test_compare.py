"""Meaningful regression-classifier checks independent of the benchmark code."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('compare', pathlib.Path(__file__).with_name('compare.py'))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


class ComparisonTest(unittest.TestCase):
    def test_cold_and_warm_operation_metrics_do_not_collide(self):
        report = {'operations': [
            {'id': 'wld.open', 'fixture': 'synthetic', 'phase': 'cold', 'medianMs': 100, 'p95Ms': 100},
            {'id': 'wld.open', 'fixture': 'synthetic', 'phase': 'warm', 'medianMs': 10, 'p95Ms': 12},
        ]}
        self.assertEqual(compare.aggregate(report), {
            'wld.open|synthetic|cold|medianMs': 100,
            'wld.open|synthetic|cold|p95Ms': 100,
            'wld.open|synthetic|warm|medianMs': 10,
            'wld.open|synthetic|warm|p95Ms': 12,
        })

    def test_cold_only_regression_remains_visible_with_stable_warm_calls(self):
        baseline, candidate = [], []
        for cold in [99, 100, 101]:
            def report(value):
                return {'operations': [
                    {'id': 'wld.open', 'fixture': 'synthetic', 'phase': 'cold', 'medianMs': value, 'p95Ms': value},
                    {'id': 'wld.open', 'fixture': 'synthetic', 'phase': 'warm', 'medianMs': 10, 'p95Ms': 10},
                ]}
            baseline.append(compare.aggregate(report(cold)))
            candidate.append(compare.aggregate(report(cold + 100)))
        cold_key, warm_key = 'wld.open|synthetic|cold|medianMs', 'wld.open|synthetic|warm|medianMs'
        self.assertEqual(compare.compare_values([r[cold_key] for r in baseline], [r[cold_key] for r in candidate])['status'], 'regression')
        self.assertEqual(compare.compare_values([r[warm_key] for r in baseline], [r[warm_key] for r in candidate])['status'], 'within-observed-noise')

    def test_separated_repeated_slowdown_is_reported(self):
        self.assertEqual(compare.compare_values([9, 10, 11], [19, 20, 21])['status'], 'regression')

    def test_one_slow_run_is_not_discarded_or_claimed_conclusive(self):
        result = compare.compare_values([9, 10, 11], [9, 10, 90])
        self.assertEqual(result['status'], 'within-observed-noise')
        self.assertEqual(result['candidateRuns'], [9, 10, 90])

    def test_no_fixed_relative_budget(self):
        self.assertEqual(compare.compare_values([1, 1, 1], [1.01, 1.01, 1.01])['status'], 'regression')
        self.assertEqual(compare.compare_values([1, 10, 100], [2, 20, 200])['status'], 'within-observed-noise')

    def test_negative_memory_growth_can_improve(self):
        self.assertEqual(compare.compare_values([10, 11, 12], [-2, -1, 0])['status'], 'improvement')


if __name__ == '__main__':
    unittest.main()
