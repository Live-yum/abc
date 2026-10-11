"""Independent heap_v2 sample integrity and estimates, never full-heap accounting.

The original full-profiler parser is not changed. Repeated stacks are individual
sample records and are weighted before aggregation, as official pprof does.
"""
from __future__ import annotations
import hashlib
import math
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'gperftools_application'))
import dependencies  # binds the already reviewed shared evidence contracts
from application_contract import (MAX_HEAP, MAX_MAPS, ascii_lines, bounded_bytes,
                                  parse_maps, require, validate_map_bracket)

PERIOD = 524288
COUNTS = r'\s*(\d+):\s*(\d+)\s+\[\s*(\d+):\s*(\d+)\s*\]\s+@'
HEADER = re.compile(r'heap profile:' + COUNTS + r' heap_v2/524288')
RECORD = re.compile(COUNTS + r'((?: 0x[0-9a-f]{1,16}){1,31})')
LIMITATIONS = (
    'sampled live allocations captured by this TCMalloc process only',
    'not complete malloc/mmap/Dart-object/GPU coverage',
    'replicated columns are not cumulative allocation or churn counters',
    'pprof applies probability weights automatically; do not weight twice',
    'size-class sampling versus requested sizes prevents exact unbiased claims',
    'no object identity, retaining-owner proof, glibc reconciliation or no-leak claim',
    'GetHeapSample internal dynamic allocation peak is not bounded by output cap',
)


def sample_counts(match):
    values = tuple(int(v) for v in match.groups()[:4])
    require(all(0 <= v < 2**63 for v in values), 'Sample counters outside supported integer range')
    require(values[:2] == values[2:], 'Sample replicated live columns differ; full-profiler format forbidden')
    require(values[0] > 0 or values == (0, 0, 0, 0), 'Sample bytes without objects')
    return values


def parse_sample_bytes(data):
    require(isinstance(data, bytes) and 0 < len(data) < MAX_HEAP,
            'Sample raw output must be complete and strictly below original 1 MiB cap')
    lines = ascii_lines(data)
    match = HEADER.fullmatch(lines[0])
    require(match is not None, 'Expected fixed heap_v2/524288 sampled header')
    header = sample_counts(match)
    require(lines.count('MAPPED_LIBRARIES:') == 1, 'Sample map section missing or duplicated')
    marker = lines.index('MAPPED_LIBRARIES:')
    require(marker >= 2 and lines[marker - 1] == '', 'Sample map separator missing')
    records = []
    for line in lines[1:marker - 1]:
        match = RECORD.fullmatch(line)
        require(match is not None, 'Malformed sampled record or unsupported stack')
        counts = sample_counts(match)
        require(counts[0] == 1, 'Official 2.15 raw record must be one sampled allocation; preaggregation forbidden')
        stack = tuple(int(pc, 16) for pc in match.group(5).split())
        require(all(stack), 'Null sampled PC cannot establish executable identity')
        records.append({'rawSampleCounts': counts, 'stack': stack})
    require(tuple(sum(r['rawSampleCounts'][i] for r in records) for i in range(4)) == header,
            'Incomplete sample: all raw sample columns must sum to header')
    map_bytes = ('\n'.join(lines[marker + 1:]) + '\n').encode()
    require(0 < len(map_bytes) <= MAX_MAPS, 'Sample maps exceed original per-file bound')
    maps = parse_maps(map_bytes, heap_format=True)
    # Never expose the full-profiler header/buckets schema to its integer-delta
    # pipeline. The sample records have a different, explicitly named schema.
    return {'schema': 'abc.tcmalloc-live-sample.v1', 'mode': 'sampled',
            'samplePeriodBytes': PERIOD, 'rawSampleHeader': header,
            'sampleRecords': records, 'maps': maps,
            'rawBytes': len(data), 'rawSha256': hashlib.sha256(data).hexdigest(),
            'rawSampleInternallyConsistent': True, 'mappingIdentityValidated': False,
            'fullHeapCoverage': False, 'limitations': list(LIMITATIONS)}


def parse_sample(path):
    return parse_sample_bytes(bounded_bytes(path, MAX_HEAP, exclusive=True))


def validate_sampled_bracket(sample, before_path, after_path, *, necessary_pcs=()):
    require(sample.get('schema') == 'abc.tcmalloc-live-sample.v1' and sample.get('mode') == 'sampled'
            and sample.get('samplePeriodBytes') == PERIOD, 'Sample schema differs')
    # The shared bracket consumes only maps and PCs. It is not an accounting
    # conversion and does not pass sampled counters to full-profiler consumers.
    bracket = validate_map_bracket({'maps': sample['maps'],
        'buckets': [{'stack': row['stack']} for row in sample['sampleRecords']]},
        before_path, after_path, necessary_pcs=necessary_pcs)
    return {'schema': 'abc.sampled-mapping-evidence.v1', 'mappingIdentityValidated': True,
            'rawSampleSha256': sample['rawSha256'], 'bracket': bracket,
            'fullHeapCoverage': False}


def estimate_samples(sample):
    require(sample.get('schema') == 'abc.tcmalloc-live-sample.v1'
            and sample.get('samplePeriodBytes') == PERIOD, 'Not a fixed sampled profile')
    groups = {}
    for row in sample['sampleRecords']:
        count, size = row['rawSampleCounts'][:2]
        require(count > 0 and size > 0, 'Zero requested size has no finite official Poisson weight')
        ratio = (size / count) / PERIOD
        probability = -math.expm1(-ratio)
        require(0 < probability <= 1, 'Invalid sample inclusion probability')
        weighted_count, weighted_size = count / probability, size / probability
        require(math.isfinite(weighted_count) and math.isfinite(weighted_size), 'Non-finite sample estimate')
        key = tuple(row['stack'])
        group = groups.setdefault(key, {'stack': key, 'records': 0, 'rawObjects': 0,
            'rawBytes': 0, 'estimatedObjects': 0.0, 'estimatedBytes': 0.0})
        group['records'] += 1; group['rawObjects'] += count; group['rawBytes'] += size
        group['estimatedObjects'] += weighted_count; group['estimatedBytes'] += weighted_size
    rows = [groups[key] for key in sorted(groups)]
    return {'schema': 'abc.poisson-live-estimates.v1', 'sourceSampleSha256': sample['rawSha256'],
            'samplingPeriodBytes': PERIOD, 'weighting': 'pprof-v2-reference-only; never reweight pprof output',
            'estimateNotExact': True, 'cumulativeAllocationEstimateAvailable': False,
            'estimatedObjects': sum(r['estimatedObjects'] for r in rows),
            'estimatedBytes': sum(r['estimatedBytes'] for r in rows), 'byStack': rows,
            'confidenceIntervalAvailable': False, 'fullHeapCoverage': False,
            'zeroMeansNoLeak': False, 'limitations': list(LIMITATIONS)}
