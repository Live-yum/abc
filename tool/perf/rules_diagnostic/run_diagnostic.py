#!/usr/bin/env python3
"""Validate by default. Only --execute starts exactly six fixed ABBAAB processes."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SEQUENCE = ['baseline', 'candidate', 'candidate', 'baseline', 'baseline', 'candidate']
COMMITS = {'baseline': 'a5612b474fc8dc50d41b3bc6b87234d30ba97e02',
           'candidate': 'cddd936f95d31b14a76503e13ffc89173110a057'}
SOURCE_FILES = ['prepare_inputs.py', 'run_diagnostic.py', 'runner.template.mjs',
                'rules_runner.mjs', 'diagnostic_probe.mjs', 'test_probe.mjs',
                'test_diagnostic.py', 'README.md', 'input-manifest.json']

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(path):
    return json.loads(path.read_text())

def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')

def validate_inputs():
    from prepare_inputs import COMMON, EXPECTED, PINS, fragment
    manifest = read(ROOT / 'input-manifest.json')
    assert manifest['sequence'] == SEQUENCE
    assert (manifest['coldCycles'], manifest['warmupCycles'], manifest['measuredCycles']) == (1, 5, 25)
    for role in COMMITS:
        assert manifest['roles'][role]['sourceCommit'] == COMMITS[role]
        assert manifest['roles'][role]['sourceTree'] == PINS[role][1]
        assert manifest['roles'][role]['sourceOrigin'] == {'repository': 'Live-yum/abc', 'commit': COMMITS[role]}
        assert manifest['roles'][role]['gitVerified'] == manifest['sourceGitVerified']
        expected = {**COMMON, **EXPECTED[role]}
        assert set(manifest['roles'][role]['files']) == set(expected)
        for relative, sha in expected.items():
            path = ROOT / 'inputs' / role / relative
            entry = manifest['roles'][role]['files'][relative]
            assert entry['sha256'] == sha == digest(path), f'Input changed: {role}/{relative}'
            assert path.stat().st_size == entry['bytes']
    original = (ROOT / 'inputs/baseline/tool/perf/benchmark_wasm.mjs').read_text()
    snippet = fragment(original)
    assert hashlib.sha256(snippet.encode()).hexdigest() == manifest['rulesCycleSha256']
    generated = (ROOT / 'runner.template.mjs').read_text().replace('/* ORIGINAL_RULES_CYCLE */', snippet)
    assert (ROOT / 'rules_runner.mjs').read_text() == generated, 'Rules extraction/template changed'
    for relative, entry in manifest['generated'].items():
        assert digest(ROOT / relative) == entry['sha256']
    source_manifest = read(ROOT / 'source-manifest.json')
    assert set(source_manifest['files']) == set(SOURCE_FILES), 'Source manifest coverage differs'
    for relative, entry in source_manifest['files'].items():
        assert digest(ROOT / relative) == entry['sha256'], f'Diagnostic source changed: {relative}'
        assert (ROOT / relative).stat().st_size == entry['bytes']
    return manifest

def comparison_module():
    source = ROOT / 'inputs/baseline/tool/perf/compare.py'
    spec = importlib.util.spec_from_file_location('original_comparator', source)
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    return module

def host():
    env = dict(os.environ)
    env.pop('NODE_OPTIONS', None)
    return {'system': platform.system(), 'kernel': platform.release(), 'architecture': platform.machine(),
            'processors': os.cpu_count(), 'bootId': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'cpuModel': next(line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),
            'node': subprocess.check_output(['node', '--version'], text=True, env=env).strip(),
            'v8': subprocess.check_output(['node', '-p', 'process.versions.v8'], text=True, env=env).strip()}

def validate_report(report, role, observations, manifest):
    comparator = comparison_module()
    comparator.validate(report)
    assert report['suite'] == 'wasm-rules-only-diagnostic'
    assert report['source']['commit'] == COMMITS[role]
    assert report['source']['worktreeCommit'] is None and report['source']['dirty'] is None
    assert report['source']['sourceProof'] == manifest['roles'][role]
    assert report['methodology']['measuredCycles'] == 25 and report['methodology']['warmupCycles'] == 5
    assert report['methodology']['diagnosticObservation'] == observations
    assert all(row['id'].startswith('circuit.') for row in report['operations'])
    for row in report['operations']:
        assert row['phase'] in ('cold', 'warm')
        repeats = 2 if row['id'] == 'circuit.place' else 1
        assert row['iterations'] == repeats * (1 if row['phase'] == 'cold' else 25)
    expected = manifest['roles'][role]['files']
    assert report['toolchain']['artifacts'] == [{'id': 'wld-wasm', 'bytes': expected['web/engine/world.wasm']['bytes'],
        'sha256': expected['web/engine/world.wasm']['sha256'], 'loaderSha256': expected['web/engine/world.js']['sha256']}]
    assert {m['cycle'] for m in report['memory'] if m['phase'] == 'after-close-gc'} == set(range(-1, 30))

def compare_reports(paths, observations, manifest):
    comparator = comparison_module()
    groups = {'baseline': [], 'candidate': []}
    for role, path in paths:
        report = read(path)
        validate_report(report, role, observations, manifest)
        groups[role].append(report)
    reports = groups['baseline'] + groups['candidate']
    assert all(comparator.identity(r) == comparator.identity(reports[0]) for r in reports), 'Diagnostic report identity differs'
    old = [comparator.aggregate(r) for r in groups['baseline']]
    new = [comparator.aggregate(r) for r in groups['candidate']]
    assert all(set(r) == set(old[0]) for r in old + new), 'Diagnostic coverage differs'
    rows = [{'id': key, **comparator.compare_values([r[key] for r in old], [r[key] for r in new])} for key in sorted(old[0])]
    return {'schema': 'abc.rules-only-comparison.v1',
            'status': 'regression' if any(r['status'] == 'regression' for r in rows) else 'no-observed-regression',
            'scope': 'Auxiliary fixed-file diagnostic; original full-suite gate remains failed/unestablished',
            'method': 'Unmodified compare.py validate/identity/aggregate/compare_values; 5000 resamples, 95% CI, complete process separation, no exclusions',
            'sourceProof': 'Verified SHA-256 snapshots; NOT the original comparator clean-Git acceptance path',
            'observationMode': observations, 'baselineRunCount': 3, 'candidateRunCount': 3,
            'originalFailure': manifest['originalFailure'], 'overallAcceptance': 'unestablished', 'rows': rows}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--observations', choices=['off', 'auxiliary'], default='off')
    parser.add_argument('--timeout-seconds', type=int, default=300)
    args = parser.parse_args()
    manifest = validate_inputs()
    if not args.execute:
        print('PASS fixed inputs, exact rulesCycle and generated runner; no benchmark executed.')
        return 0
    if args.output_dir is None or not 1 <= args.timeout_seconds <= 300:
        parser.error('--execute requires a fresh --output-dir and timeout 1..300 seconds')
    if not manifest['sourceGitVerified']:
        raise SystemExit('Validator-only snapshots cannot execute; prepare from both verified clean Git pins.')
    machine = host()
    if machine['node'] != 'v22.23.3' or machine['v8'] != '12.4.254.21-node.57':
        raise SystemExit('Need original Node v22.23.3 / V8 12.4.254.21-node.57; no processes started.')
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    session = {'schema': 'abc.rules-only-session.v1', 'status': 'running', 'scope': manifest['scope'],
               'machine': machine, 'sequence': SEQUENCE, 'observations': args.observations,
               'inputManifestSha256': digest(ROOT / 'input-manifest.json'),
               'sourceManifestSha256': digest(ROOT / 'source-manifest.json'),
               'sourceFiles': read(ROOT / 'source-manifest.json')['files'],
               'runs': [], 'startedAt': datetime.now(timezone.utc).isoformat(), 'overallAcceptance': 'unestablished',
               'budgetSeconds': 1500, 'perProcessTimeoutSeconds': args.timeout_seconds,
               'expectedTotalSeconds': 600, 'timingBasis': 'Original full-suite processes were 95.8..97.8 seconds; six totaled approximately 582 seconds.'}
    paths = []
    session_begin = time.monotonic()
    def cancelled(_signal, _frame):
        raise KeyboardInterrupt('Diagnostic cancelled')
    previous_sigterm = signal.signal(signal.SIGTERM, cancelled)
    try:
        for number, role in enumerate(SEQUENCE, 1):
            remaining = 1500 - (time.monotonic() - session_begin)
            if remaining < args.timeout_seconds:
                raise TimeoutError('Remaining diagnostic budget cannot admit another complete process timeout; no replacement runs')
            validate_inputs()
            assert host() == machine, 'Host/toolchain changed'
            slot = f'{number:02d}-{role}'
            directory = output / slot
            directory.mkdir()
            report = directory / 'rules.json'
            argv = ['node', '--expose-gc', str(ROOT / 'rules_runner.mjs'), role, str(report), args.observations]
            env = dict(os.environ)
            # Prevent caller preloads/engine flags from silently changing a run.
            env.pop('NODE_OPTIONS', None)
            env.update(ABC_PERF_TIER='ci', ABC_PERF_CYCLES='25', ABC_PERF_WARMUP='5', ABC_PERF_COMMIT=COMMITS[role])
            record = {'slot': slot, 'role': role, 'command': ['node', '--expose-gc', 'rules_runner.mjs', role, f'{slot}/rules.json', args.observations],
                      'status': 'running', 'report': str(report.relative_to(output)), 'startedAt': datetime.now(timezone.utc).isoformat()}
            session['runs'].append(record)
            write(output / 'session.json', session)
            begin = time.monotonic()
            with (directory / 'process.log').open('x') as log:
                process = subprocess.Popen(argv, cwd=ROOT / 'inputs' / role, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                record['pid'] = process.pid
                write(output / 'session.json', session)
                try:
                    record['exitCode'] = process.wait(timeout=args.timeout_seconds)
                except BaseException:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    record['status'] = 'interrupted-or-timeout'
                    record['exitCode'] = process.returncode
                    record['elapsedSeconds'] = time.monotonic() - begin
                    record['completedAt'] = datetime.now(timezone.utc).isoformat()
                    raise
            record['elapsedSeconds'] = time.monotonic() - begin
            projected = (time.monotonic() - session_begin) / number * len(SEQUENCE)
            if projected > 1200:
                warning = f'Projected six-process duration {projected:.0f}s exceeds the 1200s warning budget; hard diagnostic budget remains 1500s.'
                record['timingWarning'] = warning
                print('::warning::' + warning, flush=True)
            record['status'] = 'passed' if record['exitCode'] == 0 else 'failed'
            record['completedAt'] = datetime.now(timezone.utc).isoformat()
            if report.exists():
                record['reportSha256'] = digest(report)
            write(output / 'session.json', session)
            assert record['exitCode'] == 0, f'Workload failed in {slot}; retained without retry'
            validate_inputs()
            validate_report(read(report), role, args.observations, manifest)
            paths.append((role, report))
        assert host() == machine, 'Host/toolchain changed'
        comparison = compare_reports(paths, args.observations, manifest)
        write(output / 'comparison.json', comparison)
        session['status'] = comparison['status']
        session['comparisonSha256'] = digest(output / 'comparison.json')
    except BaseException as error:
        session['status'] = 'failed-or-incomplete'
        # Reports use relative paths; do not publish executor absolute paths.
        session['blocker'] = f'{type(error).__name__}: {error}'.replace(str(ROOT), '<prepared-package>').replace(str(output), '<diagnostic-output>')
        raise
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        session['completedAt'] = datetime.now(timezone.utc).isoformat()
        write(output / 'session.json', session)
    print(f"{session['status']}; auxiliary only; original gate unchanged")
    return int(session['status'] != 'no-observed-regression')

if __name__ == '__main__':
    raise SystemExit(main())
