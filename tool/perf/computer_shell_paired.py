#!/usr/bin/env python3
"""Fixed six-process full-shell A/B; no OS/VM sampling during frame windows."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import threading
import time

import memory_probe_control_run as shared

BASE = 'cf36cd2bf1d447a887d3ea4d19611020368de22c'
TREE = '9ff4ca286afa3e545901c498de167ee0c5dfc61d'
ROOT = Path(__file__).resolve().parents[2]
TARGET = 'integration_test/computer_shell_profile_test.dart'
PRODUCT = (
    'lib/ui/terra_contract.dart', 'lib/ui/terra_app.dart',
    'lib/application/workspace.dart', 'lib/engine/world_circuit_session.dart',
    'integration_test/support/profile_controller.dart',
)
ORDER = ('B', 'A', 'A', 'B', 'B', 'A')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def command(argv, cwd, output, timeout, env):
    """Capture bounded sanitized output and reap only this owned process group."""
    state = {}
    with Path(output).open('x') as log:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        thread = threading.Thread(target=shared.drain_log,
                                  args=(process.stdout, log, state), daemon=True)
        thread.start()
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if state.get('error'):
                    raise RuntimeError(state['error'])
                if time.monotonic() > deadline:
                    raise TimeoutError('Bounded command exceeded deadline')
                time.sleep(.1)
            code = process.returncode
        finally:
            shared.stop_group(process)
            thread.join(timeout=10)
            process.stdout.close()
        if thread.is_alive() or state.get('error'):
            raise RuntimeError(state.get('error', 'Log reader did not finish'))
    if code:
        raise RuntimeError(f'Command exited {code}: {argv[0:3]}')


def source_manifest(stage):
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=stage).decode().split('\0')
    return [{'path': name, 'bytes': (stage / name).stat().st_size,
             'sha256': sha(stage / name)}
            for name in sorted(set(filter(None, names)) | {TARGET})]


def artifact_manifest(bundle):
    return [{'path': str(p.relative_to(bundle)), 'bytes': p.stat().st_size,
             'sha256': sha(p)} for p in sorted(bundle.rglob('*')) if p.is_file()]


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))]


def summarize(data):
    if (data.get('schema') != 1 or data.get('scenario') != 'full-terraforge-shell-physical-pong'
            or data.get('buildMode') != 'profile' or data.get('inputFormat') != 'wld-only'
            or data.get('worldSha256') != '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
            or data.get('worldBytes') != 405983441 or data.get('mode') != 'optimized'):
        raise ValueError('Wrong scenario, build mode or public fixture identity')
    if data.get('status') != 'success' or data.get('closed') is not True:
        raise ValueError('Application scenario or close failed')
    if data.get('cleanup') != 'closed' or data.get('droppedFrames') != 0:
        raise ValueError('Cleanup or frame recorder was incomplete')
    window = data['window']
    elapsed = (window['endUs'] - window['startUs']) / 1000000
    if not 30 <= elapsed <= 40:
        raise ValueError('Steady window outside its bounded schedule')
    frames = [f for f in data['frames'] if f['inWindow']]
    if not frames or len(frames) != data['windowFrameCount']:
        raise ValueError('Missing actual frame window')
    stamps = [f['vsyncStartUs'] for f in frames]
    if any(a >= b for a, b in zip(stamps, stamps[1:])):
        raise ValueError('Frame timestamps are not strictly increasing')
    if len({f['frameNumber'] for f in frames}) != len(frames):
        raise ValueError('Duplicate actual frame numbers')
    if any(not window['startUs'] <= t < window['endUs'] for t in stamps):
        raise ValueError('Reported frame membership disagrees with its timestamp')
    if len(data.get('keys', [])) != 4:
        raise ValueError('Missing bounded framework key sequence')
    progress = data['progress']
    pulses = progress['pulsesAfter'] - progress['pulsesBefore']
    reads = progress['displayReadsAfter'] - progress['displayReadsBefore']
    if pulses <= 0 or reads <= 0:
        raise ValueError('No physical computer progress')
    metrics = {'elapsedSeconds': elapsed, 'frameCount': len(frames),
               'observedFramesPerSecond': len(frames) / elapsed,
               'physicalPulses': pulses, 'displayReads': reads,
               'pulsesPerWindowSecondIncludingDrain': pulses / elapsed,
               'fullViewReads': window['fullViewReads'],
               'lastVsyncGapUs': data['lastWindowVsyncGapUs'],
               'refreshCalibration': data['refreshCalibration']}
    groups = {name: [f[name] for f in frames]
              for name in ('buildUs', 'rasterUs', 'totalSpanUs')}
    groups['vsyncIntervalUs'] = [b - a for a, b in zip(stamps, stamps[1:])]
    for name, values in groups.items():
        metrics[name] = {'median': percentile(values, .5),
                         'p95': percentile(values, .95),
                         'max': max(values) if values else None}
    hz = data.get('refreshRateHz')
    metrics['overObservedFrameBudgetFraction'] = (
        sum(f['totalSpanUs'] > 1000000 / hz for f in frames) / len(frames)
        if isinstance(hz, (int, float)) and hz > 0 else None)
    return metrics


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: computer_shell_paired.py NEW_OUTPUT_DIRECTORY')
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env['CI'] = 'true'
    if not env.get('COMPUTERRARIA_WLD'):
        raise SystemExit('Pinned public WLD environment variable required')
    actual_tree = subprocess.check_output(['git', 'rev-parse', BASE + '^{tree}'], cwd=ROOT).decode().strip()
    if actual_tree != TREE:
        raise SystemExit('Fixed base source tree differs')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip()
    stage = Path(env['RUNNER_TEMP']) / ('abc-shell-pair-' + head[:12])
    if stage.exists():
        raise SystemExit('Refusing to reuse an old measurement checkout')
    subprocess.run(['git', 'worktree', 'add', '--detach', str(stage), BASE], cwd=ROOT, check=True)
    shutil.copy2(ROOT / TARGET, stage / TARGET)
    flutter = shutil.which('flutter')
    if not flutter:
        raise SystemExit('Official pinned Flutter setup required')
    summary = {'schema': 1, 'status': 'preparing', 'baseCommit': BASE,
               'baseTree': TREE, 'diagnosticHead': head, 'order': list(ORDER),
               'productPaths': list(PRODUCT), 'runs': [], 'acceptedAsOptimization': False,
               'method': 'Two profile builds; same C library; six fresh hosts in BAABBA order. No sampling or snapshots in steady frame windows.'}
    summary['environment'] = {
        'os': platform.platform(), 'architecture': platform.machine(),
        'cpuCount': os.cpu_count(), 'libc': platform.libc_ver(),
        'renderer': env.get('TERRA_PERF_RENDERER'),
        'githubRunId': env.get('GITHUB_RUN_ID'),
        'githubRunAttempt': env.get('GITHUB_RUN_ATTEMPT'),
        'lscpu': json.loads(subprocess.check_output(['lscpu', '--json']).decode()),
        'flutter': json.loads(subprocess.check_output(
            [flutter, '--no-version-check', '--suppress-analytics', '--version', '--machine'],
            cwd=stage, env=env).decode()),
    }
    write(output / 'summary.json', summary)
    try:
        command([flutter, 'pub', 'get', '--enforce-lockfile'], stage,
                output / 'pub-get.log', 300, env)
        builds = {}
        for arm in ('A', 'B'):
            if arm == 'B':
                for name in PRODUCT:
                    shutil.copy2(ROOT / name, stage / name)
            sources = source_manifest(stage)
            write(output / f'{arm}-sources.json', sources)
            source_hash = sha(output / f'{arm}-sources.json')
            common = [f'--target={TARGET}', f'--dart-define=PERF_COMMIT={BASE}',
                      f'--dart-define=SHELL_PROFILE_ARM={arm}',
                      f'--dart-define=SHELL_DIAGNOSTIC_HEAD={head}',
                      f'--dart-define=SHELL_SOURCE_MANIFEST_SHA256={source_hash}']
            command([flutter, '--no-version-check', '--suppress-analytics', 'build',
                     'linux', '--no-pub', '--profile', *common], stage,
                    output / f'{arm}-build.log', 600, env)
            bundle = output / f'{arm}-bundle'
            shutil.copytree(stage / 'build/linux/x64/profile/bundle', bundle)
            artifacts = artifact_manifest(bundle)
            write(output / f'{arm}-artifacts.json', artifacts)
            builds[arm] = {'bundle': bundle, 'common': common, 'sources': sources,
                           'sourceManifestSha256': source_hash}
        if sha(builds['A']['bundle'] / 'lib/libabc_engine.so') != sha(builds['B']['bundle'] / 'lib/libabc_engine.so'):
            raise ValueError('Native engine bytes differ; not the declared UI-only pairing')
        a_sources = {row['path']: row for row in builds['A']['sources']}
        b_sources = {row['path']: row for row in builds['B']['sources']}
        if a_sources.keys() != b_sources.keys():
            raise ValueError('Arm source inventories differ')
        differences = {name for name in a_sources if a_sources[name] != b_sources[name]}
        if differences != set(PRODUCT):
            raise ValueError('Arm differences are not exactly the reviewed five product files')
        summary['builds'] = {arm: {
            'sourceManifestSha256': builds[arm]['sourceManifestSha256'],
            'artifactManifestSha256': sha(output / f'{arm}-artifacts.json'),
        } for arm in ('A', 'B')}
        summary['status'] = 'measuring'
        for index, arm in enumerate(ORDER, 1):
            prefix = f'{index:02}-{arm}'
            report_path = output / f'{prefix}.json'
            run_env = env | {'TERRA_UI_PROFILE_OUTPUT': str(report_path)}
            bundle = builds[arm]['bundle']
            before = artifact_manifest(bundle)
            command([flutter, '--no-version-check', '--suppress-analytics', 'drive',
                     '--no-pub', '--profile', '-d', 'linux', '--host-vmservice-port=0',
                     '--driver=test_driver/ui_profile_driver.dart',
                     f'--use-application-binary={bundle / "terraforge"}',
                     *builds[arm]['common']], stage, output / f'{prefix}.log', 720, run_env)
            if before != artifact_manifest(bundle):
                raise ValueError('Prebuilt application changed while running')
            data = json.loads(report_path.read_text())
            if (data.get('arm') != arm or data.get('sourceBaseCommit') != BASE
                    or data.get('diagnosticHead') != head
                    or data.get('armSourceManifestSha256') != builds[arm]['sourceManifestSha256']):
                raise ValueError('Actual application identity differs from planned arm')
            metrics = summarize(data)
            summary['runs'].append({'index': index, 'arm': arm,
                                    'report': report_path.name, 'reportSha256': sha(report_path),
                                    'checkpoint': data['fixedCheckpoint'], 'metrics': metrics})
            write(output / 'summary.json', summary)
        if len({json.dumps(r['checkpoint'], sort_keys=True) for r in summary['runs']}) != 1:
            raise ValueError('Fixed physical pulse / display checkpoint differs across arms')
        summary['status'] = 'complete-measurements-not-performance-acceptance'
        summary['pairs'] = [{'A': a, 'B': b} for a, b in ((2, 1), (3, 4), (6, 5))]
    except Exception as error:
        summary['status'] = 'failed-or-incomplete'
        summary['failure'] = shared.safe_text(error)
        raise
    finally:
        write(output / 'summary.json', summary)


if __name__ == '__main__':
    main()
