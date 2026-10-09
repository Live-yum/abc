#!/usr/bin/env python3
"""Compare independent profile runs on matching devices using measured noise.

Uses run-level medians, not pooled correlated frames. A simultaneous bootstrap
interval (Bonferroni corrected across metrics) must exclude zero before a
regression is reported. Missing/mismatched/too-few evidence is inconclusive,
never a pass. No fixed millisecond or megabyte threshold is invented.
"""
import argparse
from collections import Counter
from fractions import Fraction
import json
import math
from pathlib import Path
import statistics

from ui_validate import validate

MATCH_FIELDS = ('platform', 'osVersion', 'dartVersion', 'processors', 'processorModel',
                'flutterVersion', 'runner', 'renderer', 'physicalWidth',
                'physicalHeight', 'devicePixelRatio', 'refreshRateHz')


def signature(report):
    return ({key: report['runtime'].get(key) for key in MATCH_FIELDS},
            report.get('tier'), report.get('fixtures'), report.get('iterations'),
            report.get('warmup'), report.get('tracing', False))


def metrics(report):
    result = {}
    for row in report['operations']:
        for field in ('medianMs', 'p95Ms'):
            result[f"{row['id']}.{field}"] = row[field]
        for stage in ('ui', 'raster'):
            result[f"{row['id']}.{stage}.p95Us"] = row[stage]['p95Us']
        result[f"{row['id']}.budgetMissFraction"] = row['overBudgetFrames'] / row['frameCount']
    for row in report.get('controllerOperations', []):
        for field in ('medianMs', 'p95Ms'):
            result[f"{row['id']}.{field}"] = row[field]
    memory = [row for row in report['memory'] if not row.get('warmup')]
    for field in ('rssBytes', 'heapUsedBytes', 'externalBytes'):
        values = [row[field] for row in memory if row.get(field) is not None]
        if len(values) >= 3:
            # The median of pairwise slopes resists a one-time allocator spike.
            slopes = [(b - a) / (j - i) for i, a in enumerate(values)
                      for j, b in enumerate(values) if j > i]
            result[f'memory.{field}.bytesPerCycle'] = statistics.median(slopes)
            result[f'memory.{field}.tailMedian'] = statistics.median(values[len(values)//2:])
    return result


def median_rank_masses(n):
    """Exact counts among all n**n ordered bootstrap samples.

    Odd n uses differences of the binomial order-statistic CDF. For even n,
    distinct middle ranks split the sample into equal halves with no draw
    between the ranks; equal middle ranks enumerate counts below/above that
    rank. Integer arithmetic avoids rare-tail cancellation.
    """
    masses = {}
    middle = n // 2
    if n % 2:
        previous = 0
        for rank in range(n):
            cumulative = sum(math.comb(n, count) * (rank + 1)**count *
                             (n - rank - 1)**(n - count)
                             for count in range(middle + 1, n + 1))
            masses[(rank, rank)] = cumulative - previous
            previous = cumulative
    else:
        for low in range(n):
            for high in range(low, n):
                if low < high:
                    count = (math.comb(n, middle) *
                             ((low + 1)**middle - low**middle) *
                             ((n - high)**middle - (n - high - 1)**middle))
                else:
                    count = sum(math.comb(n, below) * math.comb(n - below, above) *
                                low**below * (n - low - 1)**above
                                for below in range(middle)
                                for above in range(middle))
                masses[(low, high)] = count
    assert sum(masses.values()) == n**n
    return masses


def compare(baselines, candidates, confidence=.95):
    if min(len(baselines), len(candidates)) < 5:
        return {'status': 'inconclusive', 'reason': 'At least five independent process runs per revision are required.'}
    reports = baselines + candidates
    run_ids = [report.get('runId') for report in reports]
    if None in run_ids or len(set(run_ids)) != len(run_ids):
        return {'status': 'inconclusive', 'reason': 'Missing or duplicated process run IDs; repeated files are not independent evidence'}
    for group in (baselines, candidates):
        for field in ('commit', 'checkedOutHead'):
            if len({report.get('runtime', {}).get(field) for report in group}) != 1:
                return {'status': 'inconclusive', 'reason': 'Each comparison group must contain one declared and checked-out source revision'}
    for report in reports:
        errors = validate(report)
        if errors:
            return {'status': 'inconclusive', 'reason': 'Incomplete evidence', 'errors': errors}
        if signature(report) != signature(reports[0]):
            return {'status': 'inconclusive', 'reason': 'Device/build/renderer/fixture/iteration mismatch'}
        if report['runtime'].get('renderer') in (None, '', 'unspecified'):
            return {'status': 'inconclusive', 'reason': 'Renderer provenance not recorded'}
    measurements = [metrics(report) for report in reports]
    keys = set(measurements[0])
    if any(set(row) != keys for row in measurements):
        return {'status': 'inconclusive', 'reason': 'Operation or memory metric coverage changed'}
    alpha = (1 - Fraction(str(confidence))) / max(1, len(keys))
    # Reuse the exact middle-rank distribution across every app metric.
    nb, nc = len(baselines), len(candidates)
    before_masses, after_masses = median_rank_masses(nb), median_rank_masses(nc)
    ranks = {(bl, bh, cl, ch): before_count * after_count
             for (bl, bh), before_count in before_masses.items()
             for (cl, ch), after_count in after_masses.items()}
    total_mass = nb**nb * nc**nc
    lower, upper = alpha / 2, 1 - alpha / 2
    results = []
    for key in sorted(keys):
        before = [row[key] for row in measurements[:len(baselines)]]
        after = [row[key] for row in measurements[len(baselines):]]
        if any(v is None or not math.isfinite(v) for v in before + after):
            return {'status': 'inconclusive', 'reason': f'Non-finite metric: {key}'}
        observed = statistics.median(after) - statistics.median(before)
        ordered_before, ordered_after = sorted(before), sorted(after)
        deltas = Counter()
        for (bl, bh, cl, ch), count in ranks.items():
            delta = (ordered_after[cl] + ordered_after[ch] - ordered_before[bl] - ordered_before[bh]) / 2
            deltas[delta] += count
        cumulative = 0
        low = high = None
        for delta, count in sorted(deltas.items()):
            cumulative += count
            if low is None and cumulative * lower.denominator >= lower.numerator * total_mass:
                low = delta
            if cumulative * upper.denominator >= upper.numerator * total_mass:
                high = delta
                break
        results.append({'metric': key, 'baselineMedian': statistics.median(before),
                        'candidateMedian': statistics.median(after),
                        'difference': observed, 'simultaneousInterval': [low, high],
                        'status': 'regression' if low > 0 else 'no-detected-regression'})
    return {'schema': 'abc.ui-comparison.v1',
            'status': 'regression' if any(r['status'] == 'regression' for r in results) else 'no-detected-regression',
            'confidence': confidence, 'bootstrap': 'exact discrete median-rank distribution',
            'jointRankPairs': len(ranks),
            'independentBaselineRuns': len(baselines), 'independentCandidateRuns': len(candidates),
            'method': 'run-level median difference; exact bootstrap; Bonferroni simultaneous intervals',
            'caution': 'No detected regression is not proof of equivalence or absence of leaks. Review tail frames and positive memory slopes.',
            'metrics': results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', nargs='+', required=True, type=Path)
    parser.add_argument('--candidate', nargs='+', required=True, type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = compare([json.loads(p.read_text()) for p in args.baseline],
                     [json.loads(p.read_text()) for p in args.candidate])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(result['status'])
    raise SystemExit(1 if result['status'] == 'regression' else
                     2 if result['status'] == 'inconclusive' else 0)


if __name__ == '__main__':
    main()
