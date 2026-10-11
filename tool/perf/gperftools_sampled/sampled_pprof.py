"""Validate official probability-weighted output without calling it exact heap.

The parser checks integer serialization of the official estimator, not actual
allocation counts. The untouched raw sample remains the primary evidence.
"""
from collections import defaultdict
import math

from sampled_contract import PERIOD, estimate_samples
from application_contract import require, raw_parser, _short_name, _SKIP


def validate_weighted_raw(path, binary, sample, mode):
    require(mode in ('inuse_space', 'inuse_objects'), 'Unsupported sampled estimate mode')
    raw = raw_parser.parse_pprof_raw(path, binary)
    estimate_samples(sample)  # rejects zero-size/non-finite weighting explicitly
    index = {'inuse_objects': 0, 'inuse_space': 1}[mode]
    grouped = defaultdict(float)
    removed = set()
    for record in sample['sampleRecords']:
        count, size = record['rawSampleCounts'][:2]
        # Reproduce official 2.15 expression and operation order, including its
        # exp subtraction rather than the numerically stronger expm1 reference.
        scale = 1.0 / (1.0 - math.exp(-((size * 1.0) / count) / PERIOD))
        keep = []
        for position, address in enumerate(record['stack']):
            pc = address if position == 0 else address - 1
            name = _short_name(raw['symbols'].get(pc, ''))
            if name in _SKIP or 'TCMalloc' in name or name.startswith('tcmalloc::'):
                removed.add(pc)
            else:
                keep.append(pc)
        require(keep, 'Official allocator filtering erased an entire sampled stack')
        grouped[tuple(keep)] += record['rawSampleCounts'][index] * scale
    expected = {stack: int(value) for stack, value in grouped.items()}
    require(all(0 <= value < 2**64 for value in expected.values()), 'Weighted estimate outside raw format')
    require(raw['stacks'] == expected and raw['total'] == sum(expected.values()),
            'Official weighted stack serialization differs; retain both raw outputs, no tolerance/retry')
    return {'schema': 'abc.sampled-official-estimate.v1', 'mode': mode,
            'estimateNotExact': True, 'fullHeapCoverage': False,
            'sourceSampleSha256': sample['rawSha256'],
            'serializedEstimatedTotal': raw['total'],
            'serializedEstimatedStacks': [{'stack': list(stack), 'value': value}
                for stack, value in sorted(raw['stacks'].items())],
            'allocatorFramePcsRemovedByOfficialTool': sorted(removed),
            'officialTruncatesEachAggregatedStackToInteger': True,
            'functionAttributionProvenByRawSymbols': False}


def check_sampled_diagnostics(data):
    """Preserve symbolization diagnostics; raw/exit gates prove estimator output.

System DWARF warnings do not establish a corrupt sampled profile. They remain
explicit unknown capability, never trusted function/holder evidence. Nonzero
official exit, missing sample notices, or mismatched raw accounting still fail.
"""
    require(len(data) <= 2 << 20, 'Official diagnostics exceed fixed log bound')
    lines = data.decode('utf-8', errors='strict').splitlines()
    required = {'Adjusting heap profiles for 1-in-524288 sampling rate', 'Heap version 2'}
    require(required <= set(lines), 'Official sampled mode notices absent')
    # The normal local-binary banner is provenance, not a profiler warning.
    unknown = [line for line in lines if line and line not in required
               and not line.startswith(('Using local file ', 'Using local file: '))]
    return {'sampledNotices': sorted(required), 'additionalDiagnostics': unknown,
            'symbolizationCompletenessProven': False,
            'decoratedSymbolsAreNotOwnershipEvidence': True}
