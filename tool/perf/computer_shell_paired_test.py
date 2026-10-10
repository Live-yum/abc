import copy
import unittest

from computer_shell_paired import summarize


def report():
    return {
        'schema': 1, 'scenario': 'full-terraforge-shell-physical-pong',
        'buildMode': 'profile', 'inputFormat': 'wld-only', 'mode': 'optimized',
        'worldSha256': '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33',
        'worldBytes': 405983441, 'status': 'success', 'closed': True,
        'cleanup': 'closed', 'droppedFrames': 0,
        'window': {'startUs': 1000000, 'endUs': 31000000, 'fullViewReads': 7},
        'progress': {'pulsesBefore': 5120, 'pulsesAfter': 5248,
                     'displayReadsBefore': 40, 'displayReadsAfter': 41},
        'frames': [
            {'inWindow': True, 'frameNumber': i, 'vsyncStartUs': 1000000 + i * 1000000,
             'buildUs': 30000, 'rasterUs': 40000, 'totalSpanUs': 70000}
            for i in range(1, 4)
        ],
        'keys': [{}, {}, {}, {}], 'windowFrameCount': 3,
        'lastWindowVsyncGapUs': 27000000,
        'refreshCalibration': 'unavailable', 'refreshRateHz': None,
    }


class ShellSummaryTest(unittest.TestCase):
    def test_slow_valid_measurement_is_not_relabelled_fluent(self):
        result = summarize(report())
        self.assertEqual(result['observedFramesPerSecond'], .1)
        self.assertEqual(result['lastVsyncGapUs'], 27000000)
        self.assertIsNone(result['overObservedFrameBudgetFraction'])
        self.assertNotIn('passed', result)

    def test_observed_refresh_budget_retains_bad_frames(self):
        data = report()
        data.update(refreshRateHz=60, refreshCalibration='observed')
        self.assertEqual(summarize(data)['overObservedFrameBudgetFraction'], 1)

    def test_identity_failures(self):
        for key, value in [('buildMode', 'debug'), ('worldBytes', 1),
                           ('inputFormat', 'twld'), ('mode', 'standard'),
                           ('scenario', 'panel-only')]:
            data = report()
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                summarize(data)

    def test_lifecycle_and_incomplete_capture_failures(self):
        for key, value in [('closed', False), ('cleanup', 'failed'),
                           ('status', 'failed'), ('droppedFrames', 1)]:
            data = report()
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                summarize(data)

    def test_frame_integrity(self):
        for mutation in [
            lambda d: d.update(frames=[]),
            lambda d: d['frames'][1].update(frameNumber=1),
            lambda d: d['frames'][1].update(vsyncStartUs=1000000),
            lambda d: d['frames'][-1].update(vsyncStartUs=31000000),
            lambda d: d.update(keys=[]),
            lambda d: d['progress'].update(pulsesAfter=5120),
            lambda d: d['window'].update(endUs=1500000),
        ]:
            data = copy.deepcopy(report())
            mutation(data)
            with self.assertRaises(ValueError):
                summarize(data)


if __name__ == '__main__':
    unittest.main()
