"""Cross-source sampling exceptions cannot relax actual memory invariants."""
import unittest
from memory_probe_control_rss import FLUTTER_REVISION, process_info_disagreement


class SamplingSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.vm = {'rssBytes': 200, 'maxRssBytes': 199,
                   'heapUsedBytes': 10, 'heapCapacityBytes': 20}
        self.point = {'atomic': False, 'cycle': 5, 'phase': 'after-close-retained',
                      'vmStartUs': 100, 'vmEndUs': 120}
        self.runtime = {'platform': 'linux', 'flutterRevisionPin': FLUTTER_REVISION}

    def test_atomic_contradiction_is_still_rejected(self):
        self.point['atomic'] = True
        with self.assertRaisesRegex(ValueError, 'unverified sampling source'):
            process_info_disagreement(self.vm, self.point, self.runtime)

    def test_unknown_platform_or_sdk_cannot_claim_verified_exception(self):
        for runtime in ({'platform': 'other', 'flutterRevisionPin': FLUTTER_REVISION},
                        {'platform': 'linux', 'flutterRevisionPin': 'unknown'}):
            with self.assertRaisesRegex(ValueError, 'unverified sampling source'):
                process_info_disagreement(self.vm, self.point, runtime)

    def test_missing_or_reversed_sampling_window_is_rejected(self):
        for point in ({'atomic': False}, {**self.point, 'vmStartUs': 121}):
            with self.assertRaisesRegex(ValueError, 'sampling window'):
                process_info_disagreement(self.vm, point, self.runtime)

    def test_heap_invalid_even_when_cross_source_rss_disagrees(self):
        self.vm['heapUsedBytes'] = 21
        with self.assertRaisesRegex(ValueError, 'heap capacity'):
            process_info_disagreement(self.vm, self.point, self.runtime)

    def test_known_sequential_pair_preserves_both_values_without_clamping(self):
        observed = process_info_disagreement(self.vm, self.point, self.runtime)
        self.assertEqual(observed['rssBytes'], 200)
        self.assertEqual(observed['maxRssBytes'], 199)
        self.assertEqual(observed['rssMinusReportedMaxBytes'], 1)
        self.assertEqual(self.vm['maxRssBytes'], 199)


if __name__ == '__main__':
    unittest.main()
