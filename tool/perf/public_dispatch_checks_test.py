"""Fail-closed report contract tests; these do not execute Flutter workloads."""
import copy
import unittest

from compare import validate
from public_dispatch_validate import REQUIRED


def report():
    rows = []
    for scenario, action in REQUIRED.items():
        for phase in ('cold', 'warm'):
            samples = [1] if phase == 'cold' else [1, 1, 1]
            rows.append({'id': f'workspace.{scenario}', 'controller': 'Workspace',
                'action': action, 'dispatchEvidence': 'awaited-production-dispatch',
                'completion': 'returned-and-state-asserted', 'phase': phase,
                'fixture': 'public-modern-world', 'iterations': len(samples),
                'warmup': 0 if phase == 'cold' else 1, 'samplesMs': samples,
                'medianMs': 1, 'p95Ms': 1, 'maxMs': 1})
    return {'schema': 'abc.performance.v1', 'suite': 'public-dispatch-actions',
        'status': 'passed', 'methodology': {'measuredCycles': 3, 'warmupCycles': 1},
        'fixtures': [{'id': name} for name in ('public-modern-world', 'public-catalog',
                      'public-player-v326', 'public-player-v279')],
        'operations': rows, 'memory': [{'cycle': cycle, 'phase': 'after-close',
            'ownedHandles': 0, 'rssBytes': 100} for cycle in range(-1, 4)]}


class PublicDispatchReportTests(unittest.TestCase):
    def test_complete_cold_warm_dispatch_and_memory_contract(self):
        validate(report())

    def test_no_core_alias_missing_phase_or_unmeasured_frame_can_pass(self):
        for failure in ('missing-variant', 'duplicate', 'identity', 'core-only',
                        'completion', 'fixture', 'repeat', 'warmup', 'frame',
                        'memory', 'owner', 'private-fixture'):
            data = report()
            row = data['operations'][0]
            if failure == 'missing-variant': data['operations'].pop()
            elif failure == 'duplicate': data['operations'].append(copy.deepcopy(row))
            elif failure == 'identity': row['action'] = 'different'
            elif failure == 'core-only': row.pop('dispatchEvidence')
            elif failure == 'completion': row['completion'] = 'returned'
            elif failure == 'fixture': row['fixture'] = 'unknown'
            elif failure == 'repeat': row['iterations'] = 2
            elif failure == 'warmup': row['warmup'] = 1
            elif failure == 'frame': row['frameCount'] = 0
            elif failure == 'memory': data['memory'].pop()
            elif failure == 'owner': data['memory'][-1]['ownedHandles'] = 1
            else: data['fixtures'].append({'id': 'private-world'})
            with self.assertRaises(AssertionError, msg=failure):
                validate(data)


if __name__ == '__main__':
    unittest.main()
