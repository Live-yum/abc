#!/usr/bin/env python3
"""GitHub-only prepared experiment. No automatic retries or remote writes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
C = json.loads((HERE / 'contract.json').read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def command(argv, cwd=None, env=None):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True, check=True)
    return (result.stdout or result.stderr).strip()


def source(root):
    return {'commit': command(['git', 'rev-parse', 'HEAD'], root),
            'tree': command(['git', 'rev-parse', 'HEAD^{tree}'], root),
            'dirty': bool(command(['git', 'status', '--porcelain'], root))}


def benchmark_environment(identity):
    env = dict(os.environ, ABC_PERF_COMMIT=identity['commit'], ABC_PERF_TIER='ci', CI='true')
    for name in ['ABC_PERF_WORLD', 'ABC_PERF_WORLD2', 'ABC_PERF_PLAYER', 'ABC_PRIVATE_PACK']:
        env.pop(name, None)
    return env


def machine():
    cpu = next(x.split(':', 1)[1].strip() for x in Path('/proc/cpuinfo').read_text().splitlines()
               if x.startswith('model name'))
    return {'system': platform.system(), 'release': platform.release(),
            'architecture': platform.machine(), 'processors': os.cpu_count(), 'cpuModel': cpu,
            'image': os.getenv('ImageOS'), 'imageVersion': os.getenv('ImageVersion'),
            'runner': os.getenv('RUNNER_NAME'), 'bootId': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'runId': os.getenv('GITHUB_RUN_ID'), 'runAttempt': os.getenv('GITHUB_RUN_ATTEMPT')}


def os_sample(pid):
    # Observational only; never clear_refs, force GC, or alter process settings.
    row = {'epochMs': time.time_ns() / 1e6, 'monotonicNs': time.monotonic_ns(), 'pid': pid}
    try:
        status = {}
        for line in Path(f'/proc/{pid}/status').read_text().splitlines():
            key, _, value = line.partition(':')
            status[key] = value.strip()
        row.update(status='ok', rssBytes=int(status['VmRSS'].split()[0]) * 1024,
                   rssHwmBytes=int(status['VmHWM'].split()[0]) * 1024,
                   threads=int(status['Threads']))
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        row['processStartTicks'] = int(fields[19])
        row['fdCount'] = len(list(Path(f'/proc/{pid}/fd').iterdir()))
        try:
            rollup = {}
            for line in Path(f'/proc/{pid}/smaps_rollup').read_text().splitlines():
                key, _, value = line.partition(':')
                if value and value.strip().split()[0].isdigit():
                    rollup[key] = int(value.strip().split()[0]) * 1024
            row.update(pssBytes=rollup['Pss'], ussBytes=rollup.get('Private_Clean', 0) + rollup.get('Private_Dirty', 0))
        except (OSError, KeyError, ValueError) as error:
            row.update(pssBytes=None, ussBytes=None, rollupError=f'{type(error).__name__}: {error}')
    except (OSError, KeyError, ValueError) as error:
        row.update(status='unavailable', reason=f'{type(error).__name__}: {error}')
    return row


def terminate_owned_tree(process):
    # The frozen driver gives its child a separate process group. Terminating
    # only the outer group would leave that measurement running after a timeout.
    parents = {}
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields = path.read_text().rsplit(')', 1)[1].split()
            parents[int(path.parent.name)] = int(fields[1])
        except (OSError, ValueError, IndexError):
            continue
    owned, frontier = {process.pid}, {process.pid}
    while frontier:
        frontier = {pid for pid, parent in parents.items() if parent in frontier} - owned
        owned |= frontier
    groups = set()
    for pid in owned:
        try:
            groups.add(os.getpgid(pid))
        except ProcessLookupError:
            pass
    for group in groups:
        if group == os.getpgrp():
            raise RuntimeError('Refuse to terminate the experiment controller group')
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


class Experiment:
    def __init__(self, args):
        self.args = args
        self.deadline = time.monotonic() + C['runnerBudgetSeconds']
        self.state = {'schema': 'abc.map-thumbnail-session.v1', 'status': 'preparing',
                      'contract': C, 'machine': machine(), 'workflowSource': source(HERE.parents[2]),
                      'variants': {}, 'commands': [], 'attempts': [], 'oracles': {},
                      'scope': 'Absolute local candidate benefit; never historical identical-binary regression repair'}
        for runtime in C['runtimes']:
            for group, fixtures in [('frozen', [None]), ('memory', C['memoryFixtures'])]:
                for fixture in fixtures:
                    for i, variant in enumerate(C['order'], 1):
                        self.state['attempts'].append({'runtime': runtime, 'group': group, 'fixture': fixture,
                            'slot': f'{i:02d}-{variant}', 'variant': variant, 'status': 'planned'})
        self.persist()

    def persist(self):
        save(self.args.output / 'session.json', self.state)

    def execute(self, argv, cwd, relative, timeout, env=None, sample=False):
        location = self.args.output / relative
        location.mkdir(parents=True, exist_ok=False)
        row = {'id': str(uuid.uuid4()), 'command': [str(x) for x in argv], 'cwd': str(cwd),
               'output': relative, 'status': 'unstarted', 'timeoutSeconds': timeout,
               'startedAt': datetime.now(timezone.utc).isoformat()}
        self.state['commands'].append(row)
        if time.monotonic() + timeout + C['cleanupReserveSeconds'] > self.deadline:
            row['reason'] = 'Full timeout plus cleanup reserve does not fit shared budget'
            self.persist()
            return row
        self.persist()
        start = time.monotonic()
        try:
            with (location / 'stdout.log').open('x') as stdout, (location / 'stderr.log').open('x') as stderr:
                process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=stdout, stderr=stderr,
                                           start_new_session=True)
                row.update(pid=process.pid, status='running')
                self.persist()
                with (location / 'os.jsonl').open('x') as journal:
                    while process.poll() is None and time.monotonic() - start < timeout:
                        if sample:
                            journal.write(json.dumps(os_sample(process.pid)) + '\n')
                            journal.flush()
                        time.sleep(C['osSampleIntervalMs'] / 1000 if sample else .1)
                    if process.poll() is None:
                        row['status'] = 'timeout'
                        terminate_owned_tree(process)
                    else:
                        row['status'] = 'passed' if process.returncode == 0 else 'failed'
                    row['exitCode'] = process.returncode
        except OSError as error:
            row.update(status='failed', reason=f'{type(error).__name__}: {error}')
        row['elapsedSeconds'] = time.monotonic() - start
        row['files'] = {p.name: {'bytes': p.stat().st_size, 'sha256': sha(p)}
                        for p in location.iterdir() if p.is_file()}
        save(location / 'execution.json', row)
        self.persist()
        return row

    def prepare(self):
        base = source(self.args.base)
        assert base == {'commit': C['baseCommit'], 'tree': C['baseTree'], 'dirty': False}
        assert sha(HERE / 'candidate.patch') == C['patchSha256']
        for path, expected in C['frozenFiles'].items():
            assert sha(self.args.base / path) == expected, f'Frozen source mismatch: {path}'
        archive = self.args.output / 'harness'
        shutil.copytree(HERE, archive)
        shutil.copyfile(HERE.parents[2] / '.github/workflows/map-thumbnail-candidate.yml', archive / 'workflow.yml')
        for path in C['frozenFiles']:
            target = archive / 'frozen' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.args.base / path, target)
        self.state['harnessHashes'] = {str(p.relative_to(archive)): sha(p) for p in archive.rglob('*') if p.is_file()}
        self.state['toolchain'] = {name: command(argv) for name, argv in {
            'dart': ['dart', '--version'], 'node': ['node', '--version'],
            'python': [sys.executable, '--version']}.items()}
        for variant in ['A', 'B']:
            root = self.args.work / variant
            command(['git', 'clone', '--no-hardlinks', '--no-checkout', str(self.args.base), str(root)])
            command(['git', 'checkout', '--detach', C['baseCommit']], root)
            if variant == 'B':
                command(['git', 'apply', str(HERE / 'candidate.patch')], root)
                assert command(['git', 'diff', '--name-only'], root).splitlines() == [C['candidatePath']]
                assert sha(root / C['candidatePath']) == C['candidateSha256']
                formatted = self.execute(['dart', 'format', C['candidatePath']], root,
                    'build/B/format-renderer', C['buildCommandTimeoutSeconds'])
                assert formatted['status'] == 'passed', 'Candidate formatting failed'
                assert command(['git', 'diff', '--name-only'], root).splitlines() == [C['candidatePath']]
                # Formatting must not introduce unrelated edits elsewhere in
                # the same file. The accepted change stays inside this method.
                original = (self.args.base / C['candidatePath']).read_text()
                changed = (root / C['candidatePath']).read_text()
                marker = '  TerrariaMapRaster renderExplorationRgba('
                old_prefix, old_method = original.split(marker, 1)
                new_prefix, new_method = changed.split(marker, 1)
                assert old_prefix == new_prefix
                assert old_method.split('\n  }', 1)[1] == new_method.split('\n  }', 1)[1]
                command(['git', 'add', '--', C['candidatePath']], root)
                tree = command(['git', 'write-tree'], root)
                env = dict(os.environ, GIT_AUTHOR_NAME='ABC local diagnostic', GIT_AUTHOR_EMAIL='diagnostic@example.invalid',
                    GIT_COMMITTER_NAME='ABC local diagnostic', GIT_COMMITTER_EMAIL='diagnostic@example.invalid',
                    GIT_AUTHOR_DATE='2026-10-10T00:00:00+00:00', GIT_COMMITTER_DATE='2026-10-10T00:00:00+00:00')
                commit = command(['git', 'commit-tree', tree, '-p', C['baseCommit'], '-m',
                    'Local MAP thumbnail candidate; never product main'], root, env)
                command(['git', 'checkout', '--detach', commit], root)
            identity = source(root)
            assert identity['dirty'] is False
            env = benchmark_environment(identity)
            row = {'source': identity, 'root': str(root), 'builds': {}, 'rendererSha256': sha(root / C['candidatePath'])}
            self.state['variants'][variant] = row
            actual_patch = subprocess.check_output(['git', 'diff', '--binary', C['baseCommit'], 'HEAD'], cwd=root)
            patch_target = self.args.output / 'variants' / variant / 'executed.patch'
            patch_target.parent.mkdir(parents=True)
            patch_target.write_bytes(actual_patch)
            row['executedPatchSha256'] = sha(patch_target)
            dependency = self.execute(['flutter', 'pub', 'get', '--enforce-lockfile'], root,
                f'build/{variant}/dependencies', C['buildCommandTimeoutSeconds'], env)
            row['dependencies'] = dependency['status']
            if dependency['status'] != 'passed':
                row['reason'] = 'Dependency setup failed; all affected planned slots remain explicit'
                self.persist()
                continue
            assert source(root) == identity, 'Dependency setup changed tracked source'
            generated = root / 'build/map-thumbnail-observer'
            generated.mkdir(parents=True)
            for name in ['observer_native.dart', 'observer_web.dart']:
                shutil.copyfile(HERE / name, generated / name)
            observer = (HERE / 'observer.dart.template').read_text().replace('__FIXTURE_URI__', '../../tool/perf/map_fixture.dart')
            (generated / 'observer.dart').write_text(observer)
            formatted = self.execute(['dart', 'format', str(generated)], root,
                f'build/{variant}/format-observer', C['buildCommandTimeoutSeconds'], env)
            assert formatted['status'] == 'passed', 'Observer formatting failed'
            row['executedObserverHashes'] = {p.name: sha(p) for p in generated.glob('*.dart')}
            builds = {
                'frozen-aot': ['dart', 'compile', 'exe', '-DABC_MAP_BUILD_MODE=aot', 'tool/perf/map_actions.dart', '-o', 'build/map-thumbnail-observer/frozen-aot'],
                'frozen-dart2js': ['dart', 'compile', 'js', '-O2', 'tool/perf/map_actions_web.dart', '-o', 'build/map-thumbnail-observer/frozen.js'],
                'memory-aot': ['dart', 'compile', 'exe', 'build/map-thumbnail-observer/observer.dart', '-o', 'build/map-thumbnail-observer/memory-aot'],
                'memory-dart2js': ['dart', 'compile', 'js', '-O2', 'build/map-thumbnail-observer/observer.dart', '-o', 'build/map-thumbnail-observer/memory.js'],
            }
            for name, argv in builds.items():
                built = self.execute(argv, root, f'build/{variant}/{name}', C['buildCommandTimeoutSeconds'], env)
                row['builds'][name] = built['status']
            fixture = self.execute(['dart', 'run', 'tool/perf/write_map_fixture.dart', 'build/map-thumbnail-observer/synthetic.map'],
                root, f'build/{variant}/fixture', C['buildCommandTimeoutSeconds'], env)
            row['fixture'] = fixture['status']
            retained = self.args.output / 'products' / variant
            shutil.copytree(generated, retained)
            row['artifacts'] = {str(p.relative_to(retained)): {'bytes': p.stat().st_size, 'sha256': sha(p)}
                                for p in retained.rglob('*') if p.is_file()}
            shutil.copyfile(root / C['candidatePath'], retained / 'renderer.dart')
            assert source(root) == identity
            self.persist()
        if all('executedObserverHashes' in self.state['variants'].get(v, {}) for v in ['A', 'B']):
            assert self.state['variants']['A']['executedObserverHashes'] == self.state['variants']['B']['executedObserverHashes'], 'Observer source differs between variants'

    def oracle(self):
        # Put the shared oracle under A, so Dart uses the baseline package
        # configuration. Both product libraries are imported by exact URI.
        root = self.args.work / 'A'
        if any(self.state['variants'].get(v, {}).get('dependencies') != 'passed' for v in ['A', 'B']):
            self.state['oracles'] = {r: {'status': 'unstarted', 'reason': 'Dependency setup incomplete'} for r in C['runtimes']}
            self.persist()
            return
        text = (HERE / 'oracle.dart.template').read_text()
        for key, path in {'__BASELINE_MAP_URI__': self.args.work / 'A' / C['candidatePath'],
                          '__CANDIDATE_MAP_URI__': self.args.work / 'B' / C['candidatePath'],
                          '__FIXTURE_URI__': root / 'tool/perf/map_fixture.dart'}.items():
            text = text.replace(key, path.as_uri())
        target = root / 'build/map-thumbnail-observer/oracle.dart'
        target.write_text(text)
        formatted = self.execute(['dart', 'format', str(target)], root,
            'oracle/format', C['buildCommandTimeoutSeconds'])
        if formatted['status'] != 'passed':
            self.state['oracles'] = {r: {'status': 'unstarted', 'reason': 'Oracle formatting failed'} for r in C['runtimes']}
            self.persist()
            return
        shutil.copyfile(target, self.args.output / 'harness/executed-oracle.dart')
        self.state['executedOracleSha256'] = sha(target)
        for runtime, suffix in [('aot', 'exe'), ('dart2js', 'js')]:
            program = target.with_suffix('.' + suffix)
            argv = ['dart', 'compile', 'exe' if runtime == 'aot' else 'js']
            if runtime == 'dart2js': argv += ['-O2']
            build = self.execute(argv + [str(target), '-o', str(program)], root,
                f'oracle/{runtime}/build', C['buildCommandTimeoutSeconds'])
            row = {'buildStatus': build['status'], 'status': 'unstarted'}
            if build['status'] == 'passed':
                run = [str(program)] if runtime == 'aot' else ['node', str(HERE / 'run_js.cjs'), str(program)]
                result = self.execute(run, root, f'oracle/{runtime}/run', C['oracleTimeoutSeconds'])
                row.update(status=result['status'], output=result['output'])
                if result['status'] == 'passed':
                    lines = (self.args.output / result['output'] / 'stdout.log').read_text().splitlines()
                    try:
                        report = json.loads(lines[-1])
                        assert len(lines) == 1 and report['status'] == 'passed'
                        assert all(report[k] == v for k, v in C['oracleExpected'].items())
                        row['report'] = report
                    except (IndexError, KeyError, ValueError, AssertionError) as error:
                        row.update(status='failed', reason=f'Invalid oracle receipt: {error}')
                archived = self.args.output / 'oracle' / runtime / 'executed-program'
                shutil.copyfile(program, archived)
                row['programSha256'] = sha(archived)
            else:
                row['reason'] = 'Oracle compilation failed'
            self.state['oracles'][runtime] = row
            self.persist()

    def run(self):
        for attempt in self.state['attempts']:
            runtime, group, variant = (attempt[k] for k in ['runtime', 'group', 'variant'])
            buildkey = f'{group}-{runtime}'
            available = all(self.state['variants'].get(v, {}).get('builds', {}).get(buildkey) == 'passed' for v in ['A', 'B'])
            if runtime == 'dart2js' and group == 'frozen':
                available &= all(self.state['variants'].get(v, {}).get('fixture') == 'passed' for v in ['A', 'B'])
            if not available or self.state['oracles'].get(runtime, {}).get('status') != 'passed':
                attempt.update(status='unstarted', reason='Both variant builds and this runtime oracle must pass')
                self.persist()
                continue
            root = self.args.work / variant
            identity = self.state['variants'][variant]['source']
            assert source(root) == identity
            env = benchmark_environment(identity)
            program = root / 'build/map-thumbnail-observer'
            product_name = ('frozen-aot' if runtime == 'aot' else 'frozen.js') if group == 'frozen' else ('memory-aot' if runtime == 'aot' else 'memory.js')
            artifact = self.state['variants'][variant]['artifacts'][product_name]
            attempt['program'] = product_name
            attempt['programSha256Before'] = sha(program / product_name)
            assert attempt['programSha256Before'] == artifact['sha256'], 'Program changed since compilation'
            suffix = attempt['fixture'] or 'latency'
            relative = f'raw/{runtime}/{group}/{suffix}/{attempt["slot"]}'
            if group == 'frozen':
                reportdir = self.args.output / 'reports' / runtime / attempt['slot']
                suite = 'map-aot' if runtime == 'aot' else 'map-dart2js'
                argv = [sys.executable, str(root / 'tool/perf/run_ci_suite.py'), '--suite', suite,
                    '--runs', '1', '--timeout-seconds', str(C['frozenProcessTimeoutSeconds'] - 20),
                    '--output-dir', str(reportdir), '--']
                if runtime == 'aot':
                    argv += [str(program / 'frozen-aot'), '--iterations', '26', '--output', '{report}']
                else:
                    argv += ['node', str(root / 'tool/perf/run_map_web.cjs'), str(program / 'frozen.js'),
                             '{report}', str(program / 'synthetic.map'), 'repository-authored', '26']
                attempt['reportDirectory'] = str(reportdir.relative_to(self.args.output))
                timeout = C['frozenProcessTimeoutSeconds']
            else:
                argv = ([str(program / 'memory-aot'), attempt['fixture']] if runtime == 'aot' else
                        ['node', str(HERE / 'run_js.cjs'), str(program / 'memory.js'), attempt['fixture']])
                timeout = C['memoryProcessTimeoutSeconds']
            attempt['before'] = {'source': source(root), 'machine': machine()}
            result = self.execute(argv, root, relative, timeout, env, sample=group == 'memory')
            attempt.update(status=result['status'], execution=result['output'])
            if result['status'] != 'passed':
                attempt['reason'] = result.get('reason', f'Process {result["status"]}; inspect retained execution and logs')
            attempt['after'] = {'source': source(root), 'machine': machine()}
            attempt['programSha256After'] = sha(program / product_name)
            assert attempt['programSha256After'] == attempt['programSha256Before'], 'Program changed during measurement'
            assert attempt['before'] == attempt['after'], 'Source/runner changed during process'
            self.persist()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ['base', 'work', 'output']:
        p.add_argument('--' + key, type=lambda x: Path(x).resolve(), required=True)
    args = p.parse_args()
    assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('CI') == 'true', 'Prepared for official GitHub CI only'
    assert not args.work.exists() and not args.output.exists(), 'Fresh paths required; never replace old evidence'
    args.work.mkdir(parents=True)
    args.output.mkdir(parents=True)
    experiment = Experiment(args)
    try:
        experiment.prepare()
        experiment.oracle()
        experiment.run()
        experiment.state['status'] = 'completed' if all(x['status'] == 'passed' for x in experiment.state['attempts']) else 'incomplete'
    except Exception as error:
        experiment.state.update(status='failed', reason=f'{type(error).__name__}: {error}')
        for row in experiment.state['attempts']:
            if row['status'] == 'planned':
                row.update(status='unstarted', reason='Preparation or identity failure; see session reason')
    finally:
        experiment.persist()
    return int(experiment.state['status'] != 'completed')


if __name__ == '__main__':
    raise SystemExit(main())
