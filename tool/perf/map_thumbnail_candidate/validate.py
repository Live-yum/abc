#!/usr/bin/env python3
"""Validate all fixed slots; preserve failures and expose absolute differences."""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def contained(root, relative):
    assert not Path(relative).is_absolute() and '..' not in Path(relative).parts
    result = (root / relative).resolve()
    assert result.is_relative_to(root.resolve())
    return result


def median_field(rows, field):
    values = [x[field] for x in rows if isinstance(x.get(field), (int, float))]
    return statistics.median(values) if len(values) == len(rows) and values else None


def inspect_memory(location, fixture, runtime, contract):
    events = [json.loads(line) for line in (location / 'stdout.log').read_text().splitlines()]
    assert events and all(r['schema'] == 'abc.map-thumbnail-memory-event.v1' for r in events)
    assert all(a['elapsedUs'] <= b['elapsedUs'] for a, b in zip(events, events[1:]))
    final = events[-1]
    assert final['stage'] == 'complete' and final['status'] == 'passed'
    assert final['fixture'] == fixture and final['cycles'] == 26 and final['ownedBytes'] == 0 and final['sourcePreserved'] is True
    for key in ['sourceSha256', 'outputSha256']:
        assert re.fullmatch('[0-9a-f]{64}', final[key])
    cycles = [r for r in events if r['stage'] == 'render-cycle']
    assert [r['cycle'] for r in cycles] == list(range(26))
    dimensions = contract['fixtures'][fixture]
    fixture_id = 'synthetic-map-legacy319' if fixture == 'legacy' else 'synthetic-map-chunk315'
    expected_source = next(r for r in contract['frozenFixtures'][runtime] if r['id'] == fixture_id)
    input_event = next(r for r in events if r['stage'] == 'fixture-ready')
    assert input_event['sourceBytes'] == expected_source['bytes']
    assert input_event['sourceSha256'] == final['sourceSha256'] == expected_source['sha256']
    decoded = next(r for r in events if r['stage'] == 'decoded')
    assert (decoded['width'], decoded['height']) == (dimensions['width'], dimensions['height'])
    assert all((r['width'], r['height'], r['rgbaBytes']) ==
        (dimensions['outputWidth'], dimensions['outputHeight'], dimensions['rgbaBytes']) for r in cycles)
    before = [r for r in events if r['stage'] == 'baseline-quiet']
    after = [r for r in events if r['stage'] == 'released-quiet']
    assert [r['nominalOffsetMs'] for r in before] == list(range(0, 501, 100))
    assert [r['nominalOffsetMs'] for r in after] == list(range(0, 1501, 100))
    assert before[-1]['elapsedUs'] - before[0]['elapsedUs'] >= 500000
    assert after[-1]['elapsedUs'] - after[0]['elapsedUs'] >= 1500000
    assert all(r['ownedBytes'] == 0 for r in events if r['stage'] == 'closed')
    assert len([r for r in events if r['stage'] == 'closed']) == 1
    start = next(r for r in events if r['stage'] == 'render-start')['epochMs']
    end = next(r for r in events if r['stage'] == 'render-end')['epochMs']
    osrows = [json.loads(line) for line in (location / 'os.jsonl').read_text().splitlines()]
    good = [r for r in osrows if r['status'] == 'ok']
    assert good and len({r['processStartTicks'] for r in good}) == 1, 'Missing/reused OS process'
    during = [r for r in good if start <= r['epochMs'] <= end]
    quiet = [r for r in after if r['nominalOffsetMs'] >= 1000]
    quiet_os = [r for r in good if quiet[0]['epochMs'] <= r['epochMs'] <= quiet[-1]['epochMs']]
    baseline_os = [r for r in good if before[0]['epochMs'] <= r['epochMs'] <= before[-1]['epochMs']]
    complete = bool(during) and len(quiet_os) >= 3 and len(baseline_os) >= 3
    metric = {
        'processSampledRssPeakBytes': max(r['rssBytes'] for r in good),
        'processRssHwmBytes': max(r['rssHwmBytes'] for r in good),
        'renderSampledRssPeakBytes': max((r['rssBytes'] for r in during), default=None),
        'renderCheckpointRssPeakBytes': max(r['rssBytes'] for r in cycles),
        'quietRssBytes': median_field(quiet_os, 'rssBytes'),
        'quietPssBytes': median_field(quiet_os, 'pssBytes'),
        'quietUssBytes': median_field(quiet_os, 'ussBytes'),
        'quietFdCount': median_field(quiet_os, 'fdCount'),
        'quietThreads': median_field(quiet_os, 'threads'),
    }
    for name in ['rssBytes', 'heapUsedBytes', 'externalBytes', 'arrayBufferBytes']:
        old, new = median_field(before, name), median_field(quiet, name)
        metric['quiet-' + name] = new
        metric['quiet-minus-baseline-' + name] = None if old is None or new is None else new - old
    for name in ['pssBytes', 'ussBytes']:
        old, new = median_field(baseline_os, name), median_field(quiet_os, name)
        metric['quiet-minus-baseline-' + name] = None if old is None or new is None else new - old
    return {'fixture': fixture, 'sourceSha256': final['sourceSha256'], 'outputSha256': final['outputSha256'],
        'completeSampleWindows': complete, 'metrics': metric,
        'observations': {'allOsRows': len(osrows), 'validOsRows': len(good),
            'unavailableOsRows': [r for r in osrows if r['status'] != 'ok'],
            'baselineWindowRows': len(baseline_os), 'renderWindowRows': len(during),
            'releasedWindowRows': len(quiet_os),
            'maxSamplerGapMs': max((b['monotonicNs'] - a['monotonicNs']) / 1e6 for a, b in zip(good, good[1:])) if len(good) > 1 else None},
        'limitations': ['OS peaks are sampled; a short transient can be missed.',
            'VmHWM is whole-process and includes fixture generation, decode and verification, not just rendering.',
            'Quiet is the fixed 1000–1500ms released window, not proof that GC or RSS recovery has completed.',
            'Observers and OS polling can perturb execution; never pool this group with frozen latency.']}


def validate(root):
    summary = {'schema': 'abc.map-thumbnail-summary.v1', 'status': 'invalid',
        'adoption': 'undecided-requires-review', 'historicalGateChanged': False,
        'errors': [], 'comparisons': {}, 'memory': {}, 'memoryComparisons': {}}
    try:
        state = read(root / 'session.json')
        summary['executionStatus'] = state['status']
        summary['executionReason'] = state.get('reason')
        summary['attempts'] = [{k: v for k, v in row.items() if k in
            ['runtime', 'group', 'fixture', 'slot', 'variant', 'status', 'reason', 'execution', 'reportDirectory']}
            for row in state['attempts']]
        summary['oracles'] = state.get('oracles', {})
        summary['builds'] = {v: {k: row.get(k) for k in ['dependencies', 'builds', 'fixture', 'reason']}
            for v, row in state['variants'].items()}
        c = state['contract']
        assert c == read(root / 'harness/contract.json')
        assert state['workflowSource']['dirty'] is False
        assert state['toolchain']['node'] == 'v' + c['toolchainPins']['node']
        assert 'Dart SDK version: ' + c['toolchainPins']['dart'] in state['toolchain']['dart']
        for relative, expected in state['harnessHashes'].items():
            assert sha(contained(root / 'harness', relative)) == expected
        assert sha(root / 'harness/executed-oracle.dart') == state['executedOracleSha256']
        for path, expected in c['frozenFiles'].items():
            assert sha(contained(root / 'harness/frozen', path)) == expected
        a = state['variants']['A']
        b = state['variants']['B']
        assert a['source'] == {'commit': c['baseCommit'], 'tree': c['baseTree'], 'dirty': False}
        assert b['source']['commit'] != a['source']['commit'] and b['source']['dirty'] is False
        assert a['rendererSha256'] == c['frozenFiles'][c['candidatePath']]
        assert a['executedObserverHashes'] == b['executedObserverHashes']
        for variant in ['A', 'B']:
            row = state['variants'][variant]
            for relative, expected in row['artifacts'].items():
                p = contained(root / 'products' / variant, relative)
                assert {'bytes': p.stat().st_size, 'sha256': sha(p)} == expected
            assert sha(root / 'products' / variant / 'renderer.dart') == row['rendererSha256']
            patch = root / 'variants' / variant / 'executed.patch'
            assert sha(patch) == row['executedPatchSha256']
            if variant == 'A':
                assert not patch.read_bytes()
            else:
                paths = re.findall(r'^diff --git a/(.*?) b/(.*?)$', patch.read_text(), flags=re.M)
                assert paths == [(c['candidatePath'], c['candidatePath'])]
        for row in state['commands']:
            if row['status'] == 'unstarted':
                assert row.get('reason')
                continue
            location = contained(root, row['output'])
            assert read(location / 'execution.json') == row
            for name, expected in row['files'].items():
                p = contained(location, name)
                assert {'bytes': p.stat().st_size, 'sha256': sha(p)} == expected
        for runtime in c['runtimes']:
            oracle = state['oracles'][runtime]
            assert oracle['status'] == 'passed', f'{runtime} oracle failed/unrun'
            assert oracle['report']['status'] == 'passed'
            assert all(oracle['report'][k] == v for k, v in c['oracleExpected'].items())
            assert sha(root / 'oracle' / runtime / 'executed-program') == oracle['programSha256']
        if state['status'] != 'completed':
            summary['errors'].append('Session failed or some fixed slots were unstarted; every slot remains in attempts')
        expected = [(runtime, group, fixture, f'{i:02d}-{v}', v)
            for runtime in c['runtimes'] for group, fixtures in [('frozen', [None]), ('memory', c['memoryFixtures'])]
            for fixture in fixtures for i, v in enumerate(c['order'], 1)]
        actual = [tuple(row[k] for k in ['runtime', 'group', 'fixture', 'slot', 'variant']) for row in state['attempts']]
        assert actual == expected and len(actual) == 36, 'Order, fixture or planned count changed'
        comparator = root / 'harness/frozen/tool/perf/compare.py'
        spec = importlib.util.spec_from_file_location('frozen_thumbnail_compare', comparator)
        compare = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(compare)
        reports = {r: {'A': [], 'B': []} for r in c['runtimes']}
        memories = {r: {f: {'A': [], 'B': []} for f in c['memoryFixtures']} for r in c['runtimes']}
        ids = set()
        machine_fields = ['system', 'release', 'architecture', 'processors', 'cpuModel', 'image', 'imageVersion']
        for row in state['attempts']:
            if row['status'] != 'passed':
                summary['errors'].append(f'Incomplete fixed slot: {row["runtime"]}/{row["group"]}/{row["fixture"]}/{row["slot"]}: {row["status"]}')
                continue
            assert row['before'] == row['after'] == {'source': state['variants'][row['variant']]['source'], 'machine': state['machine']}
            runtime, variant = row['runtime'], row['variant']
            assert row['programSha256Before'] == row['programSha256After'] == state['variants'][variant]['artifacts'][row['program']]['sha256']
            execution = read(contained(root, row['execution']) / 'execution.json')
            assert execution['id'] not in ids
            ids.add(execution['id'])
            if row['group'] == 'memory':
                memory = inspect_memory(contained(root, row['execution']), row['fixture'], runtime, c)
                memory.update(slot=row['slot'], variant=variant)
                memories[runtime][row['fixture']][variant].append(memory)
                continue
            directory = contained(root, row['reportDirectory'])
            manifests = list(directory.glob('*.execution.json'))
            assert len(manifests) == 1
            manifest = read(manifests[0])
            assert manifest['status'] == 'passed' and manifest['exitCode'] == 0
            assert manifest['runId'] not in ids
            ids.add(manifest['runId'])
            assert manifest['source'] == {'commit': state['variants'][variant]['source']['commit'],
                'checkedOutHead': state['variants'][variant]['source']['commit'], 'dirty': False}
            assert manifest['machine'] == {k: state['machine'][k] for k in machine_fields}
            path = contained(directory, manifest['report'])
            assert sha(path) == manifest['reportSha256']
            report = read(path)
            compare.validate(report)
            assert report['fixtures'] == c['frozenFixtures'][runtime]
            assert report['toolchain']['flutterPinned'] == c['toolchainPins']['flutter']
            if runtime == 'aot':
                assert report['toolchain']['dart'].startswith(c['toolchainPins']['dart'] + ' ')
            else:
                assert report['toolchain']['node'] == c['toolchainPins']['node']
            assert report['source']['commit'] == report['source']['worktreeCommit'] == manifest['source']['commit']
            assert report['source']['dirty'] is False and report['sourcePreserved'] is True
            assert report['methodology']['totalCycles'] == 26 and report['methodology']['measuredCycles'] == 25
            artifact_id, product_name = ('executing-binary', 'frozen-aot') if runtime == 'aot' else ('compiled-map-benchmark', 'frozen.js')
            artifact = next(x for x in report['toolchain']['artifacts'] if x['id'] == artifact_id)
            assert artifact['sha256'] == state['variants'][variant]['artifacts'][product_name]['sha256']
            reports[runtime][variant].append(path)
        for runtime, grouped in reports.items():
            if not all(len(grouped[v]) == 3 for v in ['A', 'B']):
                summary['comparisons'][runtime] = {'status': 'incomplete-fixed-group',
                    'validRuns': {v: len(grouped[v]) for v in ['A', 'B']},
                    'reason': 'No comparison using a selected subset of fixed slots'}
                continue
            output = root / f'frozen-{runtime}.comparison.json'
            assert not output.exists(), 'Never overwrite previous comparison'
            argv = [sys.executable, str(comparator), '--require-baseline', '--output', str(output)]
            for v, flag in [('A', '--baseline'), ('B', '--candidate')]:
                for p in grouped[v]: argv += [flag, str(p)]
            result = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=60)
            detail = read(output)
            assert detail['status'] in ['regression', 'no-observed-regression']
            render_rows = [r for r in detail['rows'] if r['id'].startswith('map.render_exploration|')]
            assert len(render_rows) == len(c['frozenFixtures'][runtime]) * 4
            summary['comparisons'][runtime] = {'status': detail['status'], 'exitCode': result.returncode,
                'report': output.name, 'sha256': sha(output),
                'renderUnit': 'ms', 'renderRows': render_rows,
                'renderRawMaximaMs': {v: [{'report': str(p.relative_to(root)),
                    'rows': [{'fixture': x['fixture'], 'phase': x['phase'], 'maxMs': max(x['samplesMs'])}
                        for x in read(p)['operations'] if x['id'] == 'map.render_exploration']}
                    for p in grouped[v]] for v in ['A', 'B']}}
        summary['memory'] = memories
        for runtime, fixtures in memories.items():
            summary['memoryComparisons'][runtime] = {}
            for fixture, groups in fixtures.items():
                if not all(len(groups[v]) == 3 for v in ['A', 'B']):
                    summary['memoryComparisons'][runtime][fixture] = {'status': 'incomplete-fixed-group',
                        'validRuns': {v: len(groups[v]) for v in ['A', 'B']}}
                    continue
                assert len({r['sourceSha256'] for v in groups for r in groups[v]}) == 1
                assert len({r['outputSha256'] for v in groups for r in groups[v]}) == 1
                rows = []
                for key in groups['A'][0]['metrics']:
                    old = [r['metrics'][key] for r in groups['A']]
                    new = [r['metrics'][key] for r in groups['B']]
                    if any(x is None for x in old + new):
                        rows.append({'id': key, 'status': 'unavailable', 'baselineRuns': old, 'candidateRuns': new})
                    else:
                        assert all(math.isfinite(x) for x in old + new)
                        rows.append({'id': key, 'unit': 'bytes' if key.endswith('Bytes') else 'count',
                            **compare.compare_values(old, new)})
                summary['memoryComparisons'][runtime][fixture] = rows
        complete = all(r['completeSampleWindows'] for runtime in memories.values() for fixture in runtime.values() for group in fixture.values() for r in group)
        summary['status'] = 'invalid' if summary['errors'] else 'incomplete-memory-sampling' if not complete else 'latency-regression' if any(r['status'] == 'regression' for r in summary['comparisons'].values()) else 'valid-diagnostic-review-required'
        summary['processes'] = {'planned': {'frozen': 12, 'memory': 24, 'oracle': 2},
            'passed': {group: sum(r['status'] == 'passed' and r['group'] == group for r in state['attempts'])
                for group in ['frozen', 'memory']}}
        summary['memoryRegressionRows'] = [
            {'runtime': runtime, 'fixture': fixture, **row}
            for runtime, fixtures in summary['memoryComparisons'].items()
            for fixture, rows in fixtures.items() if isinstance(rows, list)
            for row in rows if row['status'] == 'regression']
        summary['adoptionReview'] = [
            'Review absolute render medians/p95 and every raw maximum, separately for each runtime and fixture.',
            'Review every original comparator regression, including non-render operations; no row is excluded from its outcome.',
            'Review all memoryRegressionRows and unavailable metrics; diagnostic success does not approve adoption.',
            'Adopt only the archived products/B/renderer.dart after evidence review, preserving formatted execution bytes.']
        summary['limitations'] = ['No automatic adoption or historical gate rewrite.',
            'Fixed same job/boot reduces cross-host confounding, not ambient load or runtime state.',
            'Frozen cold p95 repeats the single cold sample; do not count it as independent evidence.',
            'Node Dart2JS is not a browser/Flutter frame measurement; UI look and layout are unchanged.',
            'Memory observations use separate processes and never enter frozen latency comparisons.']
    except (AssertionError, OSError, KeyError, TypeError, ValueError, StopIteration, subprocess.SubprocessError) as error:
        summary['errors'].append(f'{type(error).__name__}: {error}')
    save(root / 'summary.json', summary)
    print(summary['status'])
    return int(summary['status'] != 'valid-diagnostic-review-required')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=lambda x: Path(x).resolve(), required=True)
    root = parser.parse_args().output
    root.mkdir(parents=True, exist_ok=True)
    assert not (root / 'summary.json').exists(), 'Never replace previous diagnostic result'
    return validate(root)


if __name__ == '__main__':
    raise SystemExit(main())
