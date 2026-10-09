#!/usr/bin/env python3
"""Validate all public CI process evidence and compare explicitly chosen baselines."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from compare import identity, validate as validate_core
from ui_compare import signature as ui_signature
from ui_validate import validate as validate_ui

SUITES = {'native': 3, 'wasm': 3, 'cloud': 3, 'resources': 3,
          'map-aot': 3, 'map-dart2js': 3, 'map-owner': 3, 'map-generation': 3,
          'ui-profile': 5}


def load_group(root, suite, required):
    entries = []
    for path in sorted(root.rglob(f'{suite}.run-*.execution.json')):
        execution = json.loads(path.read_text())
        report_path = path.parent / execution['report']
        assert execution['status'] == 'passed', f'Unfinished/failed process: {path}'
        assert execution['reportSha256'] == hashlib.sha256(report_path.read_bytes()).hexdigest(), f'Report digest mismatch: {path}'
        source = execution['source']
        assert source['dirty'] is False, f'Dirty execution snapshot: {path}'
        assert re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', str(source['commit'])), 'Unknown source commit'
        assert source['commit'] == source['checkedOutHead'], f'Requested head was not checked out: {path}'
        report = json.loads(report_path.read_text())
        if suite == 'ui-profile':
            assert not validate_ui(report), f'Invalid profile report: {report_path}: {validate_ui(report)}'
            observed = report['runtime']
            assert observed['commit'] == source['commit'] and observed['checkedOutHead'] == source['checkedOutHead'], 'Profile/execution revision disagreement'
        else:
            validate_core(report)
            assert report.get('fixtures') and all(re.fullmatch(r'[0-9a-f]{64}', str(f.get('sha256', ''))) for f in report['fixtures']), 'Missing fixture SHA-256'
            observed = report['source']
            assert observed['commit'] == source['commit'] and observed['worktreeCommit'] == source['checkedOutHead'], 'Core/execution revision disagreement'
            assert observed['dirty'] is False, 'Report observed a dirty source tree'
        entries.append((report_path, report, execution))
    assert len(entries) == required, f'{suite}: expected {required} independent runs, found {len(entries)}; all attempts must be retained'
    ids = [row[2]['runId'] for row in entries]
    assert len(set(ids)) == len(ids), f'{suite}: duplicate process execution IDs'
    reported_ids = [row[1].get('runId') for row in entries if row[1].get('runId')]
    assert len(set(reported_ids)) == len(reported_ids), f'{suite}: duplicate raw report run IDs'
    assert len({row[2]['source']['commit'] for row in entries}) == 1, f'{suite}: mixed revisions'
    signature = ui_signature if suite == 'ui-profile' else identity
    assert all(signature(row[1]) == signature(entries[0][1]) and environment(row) == environment(entries[0]) for row in entries), f'{suite}: conditions changed between independent runs'
    return entries


def environment(entry):
    _, report, execution = entry
    # Built program hashes are preserved as provenance, but legitimately change
    # across revisions. Toolchain versions and observed runner hardware must match.
    toolchain = {key: value for key, value in report.get('toolchain', {}).items()
                 if key not in ('artifacts', 'nativeLibrarySha256')}
    return execution['machine'], toolchain


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--baseline-requested', action='store_true')
    parser.add_argument('--baseline-run-metadata', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rows, failed = [], False
    for suite, required in SUITES.items():
        result = {'suite': suite, 'status': 'inconclusive'}
        try:
            candidate = load_group(args.candidate, suite, required)
            result['candidateRuns'] = [str(row[0]) for row in candidate]
            if not args.baseline_requested:
                result['reason'] = 'First calibration: no baseline run selected. Workloads passed; regression acceptance remains unestablished.'
            else:
                assert args.baseline is not None, 'Requested baseline was not downloaded'
                baseline = load_group(args.baseline, suite, required)
                result['baselineRuns'] = [str(row[0]) for row in baseline]
                if args.baseline_run_metadata is not None:
                    selected = json.loads(args.baseline_run_metadata.read_text())
                    assert selected['status'] == 'completed' and selected['conclusion'] == 'success', 'Unverified baseline run metadata'
                    assert all(row[2]['source']['commit'] == selected['head_sha'] for row in baseline), 'Downloaded baseline commit differs from verified run'
                    result['baselineRunId'] = selected['id']
                    result['baselineCommit'] = selected['head_sha']
                assert not ({row[2]['runId'] for row in candidate} & {row[2]['runId'] for row in baseline}), 'Baseline and candidate reuse an execution'
                assert baseline[0][2]['source']['commit'] != candidate[0][2]['source']['commit'], 'Baseline and candidate are the same revision'
                if any(environment(row) != environment(candidate[0]) for row in candidate + baseline):
                    result['reason'] = 'Observed runner hardware/image or toolchain differs; comparison is inconclusive.'
                    failed = True
                else:
                    comparison = args.output / f'{suite}.comparison.json'
                    script = 'ui_compare.py' if suite == 'ui-profile' else 'compare.py'
                    argv = [sys.executable, str(Path(__file__).with_name(script))]
                    if suite == 'ui-profile':
                        argv += ['--baseline', *[str(row[0]) for row in baseline],
                                 '--candidate', *[str(row[0]) for row in candidate]]
                    else:
                        for group, entries in [('baseline', baseline), ('candidate', candidate)]:
                            for entry in entries:
                                argv += [f'--{group}', str(entry[0])]
                        argv += ['--require-baseline']
                    completed = subprocess.run(argv + ['--output', str(comparison)], check=False, timeout=180)
                    detail = json.loads(comparison.read_text())
                    result.update(status=detail['status'], comparison=str(comparison))
                    if 'reason' in detail:
                        result['reason'] = detail['reason']
                    failed |= completed.returncode != 0
        except (AssertionError, KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
            result.update(status='invalid', reason=str(error))
            failed = True
        rows.append(result)
    status = ('failed' if failed else 'inconclusive' if not args.baseline_requested
              else 'no-detected-regression')
    summary = {'schema': 'abc.performance-ci-comparison.v1', 'status': status,
               'baselineRequested': args.baseline_requested, 'suites': rows,
               'limitations': ['Hosted runner metadata cannot prove the same physical machine or ambient load.',
                              'Keep every raw process, journal and outlier; no detected regression is not equivalence.',
                              'Linux software-renderer frames do not establish mobile, macOS or Web smoothness.']}
    (args.output / 'comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
    markdown = ['# Performance comparison', '', f'Status: **{status}**', '',
                '| Suite | Result | Detail |', '|---|---|---|']
    markdown += [f"| {row['suite']} | {row['status']} | {row.get('reason', row.get('comparison', ''))} |" for row in rows]
    markdown += ['', *summary['limitations']]
    (args.output / 'comparison.md').write_text('\n'.join(markdown) + '\n')
    print(status)
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
