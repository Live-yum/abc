#!/usr/bin/env python3
"""Compare independent performance runs without invented absolute time budgets.

At least three fresh-process baseline and candidate runs are required. The
process run, not each correlated operation inside it, is the statistical unit.
All runs are retained; the tool never removes a slow/outlier run. Bootstrap CIs
are descriptive, and independent reruns must also completely separate before a
regression is reported. A missing baseline is explicitly inconclusive.
"""
import argparse
import json
import math
import pathlib
import random
import re
import statistics


def median(xs):
    return statistics.median(xs)


def validate(report):
    assert report['schema'] == 'abc.performance.v1', 'Unexpected report schema'
    assert report['status'] == 'passed', 'The measured workload failed correctness checks'
    assert report['operations'], 'No measured operations'
    for row in report['operations']:
        samples = row['samplesMs']
        assert samples and all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in samples), 'Invalid raw timing sample'
        assert row['iterations'] == len(samples), 'Iteration count does not match raw samples'
        assert math.isclose(row['medianMs'], median(samples), abs_tol=1e-6), 'Median does not match samples'
        assert math.isclose(row['maxMs'], max(samples), abs_tol=1e-6), 'Maximum does not match samples'
        assert math.isclose(row['p95Ms'], sorted(samples)[math.ceil(len(samples) * .95)-1], abs_tol=1e-6), 'p95 does not match samples'
    after = [m for m in report.get('memory', []) if m['phase'].startswith('after-close')]
    assert after, 'Missing after-close memory samples'
    assert all(m.get('ownedHandles') in (0, None) for m in after), 'An explicitly observed owner remained open'
    for field in ('wasmNativeLiveBytes', 'wasmBridgeLiveBytes', 'nativeTotalLiveBytes', 'nativeBridgeLiveBytes', 'nativeWorldOpenCount'):
        assert all(m.get(field) in (0, None) for m in after), f'Observed {field} remained live after complete owner closure'


def identity(report):
    machine = report.get('machine', {})
    return {
        'suite': report['suite'], 'runtime': report['runtime'], 'buildMode': report['buildMode'],
        'tier': report['tier'], 'machine': machine,
        'fixtures': report.get('fixtures', []),
        'warmupCycles': report.get('methodology', {}).get('warmupCycles'),
        'measuredCycles': report.get('methodology', {}).get('measuredCycles'),
        'gcDiagnosticEnabled': report.get('methodology', {}).get('gcDiagnosticEnabled'),
        'heapMeasurementMethods': sorted({row.get('heapMeasurementMethod', 'unreported')
                                          for row in report.get('memory', [])
                                          if row.get('heapUsedBytes') is not None}),
    }


def aggregate(report):
    rows = {}
    for row in report['operations']:
        for metric in ('medianMs', 'p95Ms'):
            # First-use and repeated calls are independent metric families.
            # Retain both; the whole process remains the statistical unit.
            key = f"{row['id']}|{row['fixture']}|{row['phase']}|{metric}"
            rows[key] = row[metric]
    memory = report.get('memory', [])
    phase = 'after-close-gc' if any(m['phase'] == 'after-close-gc' for m in memory) else 'after-close'
    warmup = report.get('methodology', {}).get('warmupCycles', 0)
    memory = [m for m in memory if m['phase'] == phase and m['cycle'] >= warmup]
    if len(memory) >= 3:
        for metric in ('rssBytes', 'heapUsedBytes', 'wasmCapacityBytes', 'wasmNativeLiveBytes', 'wasmBridgeLiveBytes', 'nativeTotalLiveBytes', 'nativeLiveBytes', 'nativeBridgeLiveBytes'):
            if all(m.get(metric) is not None for m in memory):
                # Tail minus start median dampens collection noise; raw cycle
                # samples remain available, including any intermediate peak.
                span = max(1, len(memory) // 3)
                rows[f'memory|{phase}|{metric}Growth'] = median([m[metric] for m in memory[-span:]]) - median([m[metric] for m in memory[:span]])
    return rows


def compare_values(old, new, seed=1776):
    rng = random.Random(seed)
    distribution = sorted(
        median(rng.choices(new, k=len(new))) - median(rng.choices(old, k=len(old)))
        for _ in range(5000)
    )
    low, high = distribution[124], distribution[4874]
    # No fixed milliseconds, percentage, or RSS threshold. Variability of
    # independent whole-process runs determines the observable change.
    slower = low > 0 and min(new) > max(old)
    faster = high < 0 and max(new) < min(old)
    return {
        'baselineRuns': old, 'candidateRuns': new,
        'baselineMedian': median(old), 'candidateMedian': median(new),
        'deltaMedian': median(new) - median(old), 'delta95PercentInterval': [low, high],
        'status': 'regression' if slower else 'improvement' if faster else 'within-observed-noise',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='append', default=[], help='One independent baseline JSON; repeat at least three times')
    parser.add_argument('--candidate', action='append', required=True, help='One independent candidate JSON; repeat at least three times')
    parser.add_argument('--output', required=True)
    parser.add_argument('--require-baseline', action='store_true', help='Return nonzero when insufficient comparable repeats are provided')
    args = parser.parse_args()
    result = {'schema': 'abc.performance-comparison.v1', 'method': 'Independent process cold and warm medians/p95, kept as separate phase metrics; deterministic 5000-resample percentile bootstrap of difference of run medians; 95% interval plus complete observed run separation; no outlier removal', 'status': 'inconclusive', 'rows': [], 'limitations': ['Statistical separation is a regression signal requiring diagnosis, not a universal human-perceived slowdown threshold.', 'Cold means first use within each process; OS caches are not flushed. Its p95 may have only one within-process sample.', 'Small-sample p95 is an order statistic; use more cycles and profile frame reports for interaction smoothness.', 'RSS includes allocator/runtime retention. Increasing WASM capacity alone does not prove live leaks.']}
    try:
        baseline = [json.loads(pathlib.Path(p).read_text()) for p in args.baseline]
        candidate = [json.loads(pathlib.Path(p).read_text()) for p in args.candidate]
        for report in baseline + candidate:
            validate(report)
        assert all(re.fullmatch(r'[0-9a-f]{64}', str(f.get('sha256', ''))) for r in baseline + candidate for f in r.get('fixtures', [])), 'A fixture content hash is absent; byte length alone does not establish a comparable workload'
        assert all(r.get('source', {}).get('dirty') is False and re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', str(r.get('source', {}).get('commit', ''))) and re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', str(r.get('source', {}).get('worktreeCommit', ''))) for r in baseline + candidate), 'Source revision is unknown or worktree was dirty. Retain as smoke evidence, not a controlled acceptance baseline.'
        for group in (baseline, candidate):
            if group:
                assert len({(r['source']['commit'], r['source']['worktreeCommit']) for r in group}) == 1, 'One comparison group contains mixed supplied or actual worktree revisions'
        expected = identity(candidate[0])
        assert all(identity(r) == expected for r in baseline + candidate), 'Reports differ in machine, runtime, tier, fixture sizes/provenance, warmup, or cycles'
        result['identity'] = expected
        result['baselineRunCount'], result['candidateRunCount'] = len(baseline), len(candidate)
        if len(baseline) < 3 or len(candidate) < 3:
            result['reason'] = 'Need at least three fresh-process baseline runs and three candidate runs on the same controlled machine/configuration. Correctness/report validation passed; performance acceptance remains unestablished.'
        else:
            old, new = [aggregate(r) for r in baseline], [aggregate(r) for r in candidate]
            keys = set(new[0])
            assert all(set(r) == keys for r in old + new), 'Operation or memory coverage changed; measure missing operations before comparing'
            for key in sorted(keys):
                result['rows'].append({'id': key, **compare_values([r[key] for r in old], [r[key] for r in new])})
            result['status'] = 'regression' if any(r['status'] == 'regression' for r in result['rows']) else 'no-observed-regression'
    except (AssertionError, KeyError, TypeError, ValueError, OSError) as error:
        result['status'] = 'invalid'
        result['reason'] = str(error)
    destination = pathlib.Path(args.output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, indent=2) + '\n')
    print(result['status'])
    return 1 if result['status'] in ('invalid', 'regression') or (args.require_baseline and result['status'] == 'inconclusive') else 0


if __name__ == '__main__':
    raise SystemExit(main())
