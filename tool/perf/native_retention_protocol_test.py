"""Synthetic protocol/error contracts; no Flutter or world invocation."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import native_retention_protocol as protocol
from memory_probe_control_os import SamplerError


def sample(sequence, start=10):
    return {'schema': 'abc.native-retention-mallinfo2.v1',
            'sequence': sequence, 'status': 'unsupported',
            'reason': 'runtime-mallinfo2-unavailable',
            'atomic': False, 'clockDomain': 'dart:developer.Timeline.now',
            'startUs': start, 'endUs': start + 1,
            'fields': dict.fromkeys(protocol.FIELDS)}


def valid_report():
    report = {
        'schema': 'abc.native-retention.v1', 'baseProductCommit': protocol.PRODUCT_COMMIT,
        'arm': 'native-retention', 'status': 'observed', 'plannedCycles': 8,
        'completedCycles': 8, 'plannedAllocatorBoundaries': 18,
        'plannedAllocatorCalls': 37, 'allocatorBufferBytes': 128,
        'warmupCycles': [0, 1, 2, 3], 'repeatCycles': [4, 5, 6, 7],
        'plateauEstablished': False, 'vmProbeCalls': 0,
        'allocatorInitialization': sample(0), 'cycles': [], 'externalEndpoints': [],
        'allocatorCalls': [sample(0)],
    }
    for i in range(8):
        report['cycles'].append({
            'cycle': i, 'status': 'completed',
            'mode': 'optimized' if i % 2 else 'standard',
            'scenario': 'save-reopen' if i // 2 % 2 else 'reset-original',
            'predeclaredRole': 'warm-up-variant' if i < 4 else 'single-repeat-variant',
        })
    points = [(-1, 'baseline.pre')]
    points += [(i, phase) for i in range(8)
               for phase in ('retained-quiet.end', 'released-quiet.end')]
    points += [(8, 'final-quiet.end')]
    for index, (cycle, phase) in enumerate(points):
        report['allocatorCalls'].extend([sample(index * 2 + 1), sample(index * 2 + 2, 14)])
        report['externalEndpoints'].append({
            'cycle': cycle, 'phase': phase, 'dartTimeUs': 12,
            'acknowledgedDartTimeUs': 16,
            'allocatorBefore': sample(index * 2 + 1),
            'allocatorAfter': sample(index * 2 + 2, 14),
            'os': {'sequence': index},
            'mappingCategories': {
                'schema': 'abc.native-retention-categories.v1', 'sequence': index,
                'externalOsSequence': index, 'phase': phase, 'atomic': False,
                'clockDomain': 'python.time.monotonic_ns', 'startNs': 1, 'endNs': 2,
            },
        })
    return report


class ProtocolTests(unittest.TestCase):
    def test_missing_optional_categories_stay_null(self):
        text = 'Rss: 20 kB\nPss: 18 kB\nPrivate_Clean: 1 kB\nPrivate_Dirty: 2 kB\n'
        row = protocol.parse_rollup_categories(text)
        self.assertIsNone(row['pssAnonymousBytes'])
        self.assertIsNone(row['pssFileBytes'])
        self.assertIsNone(row['pssSharedMemoryBytes'])
        row = protocol.parse_rollup_categories(text + 'Pss_Anon: 11 kB\nPss_File: 7 kB\nPss_Shmem: 0 kB\n')
        self.assertEqual(row['pssAnonymousBytes'], 11 * 1024)
        self.assertEqual(row['pssFileBytes'], 7 * 1024)
        self.assertEqual(row['pssSharedMemoryBytes'], 0)
        with self.assertRaises(SamplerError):
            protocol.parse_rollup_categories(text + 'Pss_Anon: -1 kB\n')

    def test_all_eight_cycles_and_explicit_unsupported_are_valid(self):
        result = protocol.validate_report_contract(valid_report())
        self.assertEqual(result['allocatorCalls'], 37)
        self.assertFalse(result['plateauEstablished'])

    def test_dropped_relabelled_or_reordered_evidence_fails(self):
        for mutate in (
                lambda x: x['cycles'].pop(0),
                lambda x: x.update(warmupCycles=[0, 1]),
                lambda x: x.update(baseProductCommit='1' * 40),
                lambda x: x.update(plateauEstablished=True),
                lambda x: x['externalEndpoints'].pop(5),
                lambda x: x['externalEndpoints'].reverse(),
                lambda x: x['externalEndpoints'][1]['allocatorBefore']['fields'].update(arena=0),
                lambda x: x['externalEndpoints'][1]['allocatorBefore'].update(endUs=100),
                lambda x: x['externalEndpoints'][1]['mappingCategories'].update(externalOsSequence=99)):
            report = valid_report()
            mutate(report)
            with self.assertRaises(ValueError):
                protocol.validate_report_contract(report)

    def test_extra_read_observes_only_an_owned_child_and_persists_before_ack(self):
        with tempfile.TemporaryDirectory(prefix='abc-retention-protocol-') as directory:
            child = subprocess.Popen([sys.executable, '-c',
                                      'import sys; print("ready",flush=True);sys.stdin.readline()'],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, start_new_session=True)
            sampler = None
            try:
                self.assertEqual(child.stdout.readline().strip(), 'ready')
                sampler = protocol.RetentionOsSampler(child.pid, child.pid,
                                                      Path(directory) / 'os.jsonl').start()
                reply = sampler.point('baseline.pre', {'sequence': 1, 'cycle': -1})
                rows = [json.loads(line) for line in sampler.category_file.read_text().splitlines()]
                self.assertEqual(rows, [reply['categories']])
                self.assertEqual(reply['os']['sequence'], rows[0]['externalOsSequence'])
                self.assertLessEqual(reply['os']['smapsEndNs'], rows[0]['startNs'])
                self.assertEqual(sampler.point('ordinary', {})['categories'], None)
                manifest = sampler.finish()
                self.assertEqual(manifest['retentionCategories']['count'], 1)
                self.assertFalse(manifest['retentionCategories']['complete'])
                self.assertFalse(manifest['retentionCategories']['rawAddressesOrPaths'])
            finally:
                if sampler is not None:
                    sampler.finish()
                child.stdin.close()
                child.wait(timeout=5)
                child.stdout.close()


if __name__ == '__main__':
    unittest.main()
