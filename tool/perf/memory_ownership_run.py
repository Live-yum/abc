#!/usr/bin/env python3
"""Run one idle/probe process and one generic eight-cycle process, once each.

The fixed schedule is timing evidence from 9d4. It does not recreate CPU/Pong
work, add GC, or sample other processes. Every failure keeps partial evidence.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time

from computer_memory_run import sanitize, stop_group
from computerraria_provenance import record as record_build
from memory_probe_control_os import _OwnedProcess
from memory_ownership_preflight import BASE, ROOT, command, digest, native_settings
from memory_ownership_validate import validate_arm, validate_group

ARMS = ('probe-only', 'product-with-ownership')
BUILD_SECONDS, RUNTIME_SECONDS, DRIVER_SECONDS, GROUP_SECONDS = 300, 600, 900, 2000
MAX_LOG_BYTES, MAX_LINE_BYTES, MAX_JSON_BYTES = 8 * 1024 * 1024, 65536, 4 * 1024 * 1024
SCHEDULE = ROOT / 'tool/perf/memory_ownership_schedule.json'
TARGET = 'integration_test/computer_memory_ownership_test.dart'
WLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
AUTH = re.compile(r'(?i)(authorization\s*[:=]\s*(?:bearer\s+)?|(?:auth(?:entication)?[_ -]?(?:token|code)|access[_ -]?token)\s*[:=]\s*)[^\s,;"\']+')


def safe_text(value):
    return AUTH.sub(r'\1[redacted]', sanitize(str(value)))


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError('Missing, linked or oversized JSON evidence')
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('Expected evidence object')
    return value


def save(path, value, new=False):
    with path.open('x' if new else 'w') as stream:
        stream.write(safe_text(json.dumps(value, indent=2, allow_nan=False)) + '\n')


def drain_log(pipe, output, state):
    total = 0
    try:
        while True:
            line = pipe.readline(MAX_LINE_BYTES + 1)
            if not line:
                break
            if len(line) > MAX_LINE_BYTES:
                raise ValueError('Bounded diagnostic log line exceeded')
            total += len(line)
            if total > MAX_LOG_BYTES:
                raise ValueError('Bounded diagnostic log size exceeded')
            output.write(safe_text(line.decode('utf-8', 'replace')))
            output.flush()
    except Exception as error:
        state['error'] = safe_text(error)
    finally:
        state['finished'] = True


def validate_hello(value, arm, head):
    if (value.get('schema') != 'abc.memory-ownership-hello.v1' or
            value.get('arm') != arm or value.get('sourceCommit') != head or
            value.get('baseProductCommit') != BASE or
            type(value.get('hostPid')) is not int or value['hostPid'] <= 0 or
            type(value.get('startedUs')) is not int or value['startedUs'] < 0):
        raise ValueError('Fresh diagnostic target hello identity differs')


def validate_target(value, arm, head, pid):
    if (value.get('schema') != 'abc.memory-ownership.v1' or value.get('arm') != arm or
            value.get('workloadId') != 'generic-wld-controls-v1' or
            value.get('runtime', {}).get('commit') != head or value.get('hostPid') != pid or
            value.get('baseProductCommit') != BASE):
        raise ValueError('Completed diagnostic report does not match the owned target')


def verify_sources(proof, head):
    if (proof.get('schema') != 'abc.memory-ownership-source.v1' or
            proof.get('sourceCommit') != head or proof.get('baseProductCommit') != BASE or
            command('git', 'rev-parse', 'HEAD') != head or
            command('git', 'status', '--porcelain', '--untracked-files=all')):
        raise ValueError('Clean source preflight identity changed')
    # Check actual bytes, including index assume-unchanged/skip-worktree cases.
    from memory_ownership_preflight import file_identity
    for name, expected in proof['sourceFiles'].items():
        if file_identity(ROOT / name, expected) != expected:
            raise ValueError('Source changed after preflight')


def capture_build(folder, head, proof_sha, helper, native_proof):
    bundle = ROOT / 'build/linux/x64/profile/bundle'
    cache, ninja = bundle.parent / 'CMakeCache.txt', bundle.parent / 'build.ninja'
    artifacts = [bundle / 'terraforge', bundle / 'lib/libabc_engine.so', bundle / 'lib/libapp.so']
    code = folder / 'code'
    code.mkdir()
    for source in [*artifacts, helper]:
        shutil.copyfile(source, code / source.name)
    binary_hashes = {p.name: {'sha256': digest(p), 'bytes': p.stat().st_size}
                     for p in code.iterdir() if p.is_file()}
    save(code / 'manifest.json', {'sourceCommit': head,
                                'status': 'captured-before-identity-gate',
                                'binaries': binary_hashes}, new=True)
    settings, targets = native_settings(cache, ninja)
    path = folder / 'build.json'
    record_build([str(p) for p in artifacts], path, cache, ninja)
    build = read_json(path)
    build['cmake']['ABC_OWNER_DIAGNOSTICS'] = settings['ABC_OWNER_DIAGNOSTICS']
    build['actualOwnerCompilationTargets'] = targets
    build['ownershipProvenance'] = {'baseProductCommit': BASE,
                                   'sourceProvenanceSha256': proof_sha,
                                   'allocatorHelperSha256': digest(helper),
                                   'allocatorBuild': native_proof['allocatorBuild'],
                                   'allocatorBuildSha256': native_proof['allocatorBuildSha256'],
                                   'ownerAbi': 1, 'perfAbi': 1}
    save(path, build)
    if (binary_hashes['libabc_engine.so']['sha256'] != native_proof['nativeEngineSha256'] or
            binary_hashes[helper.name]['sha256'] != native_proof['allocatorHelperSha256']):
        raise ValueError('Actual native/helper binaries differ from ABI preflight')
    return build, digest(path), binary_hashes


def publish_ready(path, value):
    pending = path.with_suffix('.pending')
    with pending.open('x') as output:
        output.write(json.dumps(value, allow_nan=False))
        output.flush()
        os.fsync(output.fileno())
    # Atomic publication without replacing a pre-existing acknowledgement.
    os.link(pending, path)
    pending.unlink()


def require_equal_binaries(actual, expected):
    if expected is not None and actual != expected:
        raise ValueError('Second arm actual code differs; measurement is not released')


def loaded_executable(identity):
    """One pre-gauge hash from the verified child's already-pinned proc fd."""
    identity.verify()
    descriptor = os.open('exe', os.O_RDONLY | os.O_CLOEXEC, dir_fd=identity.fd)
    result, size = hashlib.sha256(), 0
    try:
        if os.fstat(descriptor).st_size > 64 * 1024 * 1024:
            raise ValueError('Owned executable exceeds the identity-read bound')
        while True:
            data = os.read(descriptor, 1024 * 1024)
            if not data:
                break
            size += len(data)
            if size > 64 * 1024 * 1024:
                raise ValueError('Owned executable changed beyond identity-read bound')
            result.update(data)
    finally:
        os.close(descriptor)
    identity.verify()
    return {'sha256': result.hexdigest(), 'bytes': size}


def run_arm(arm, output, head, version, proof, proof_sha, helper, native_proof, group_start, expected_binaries):
    folder = output / arm
    folder.mkdir()
    paths = {key: folder / name for key, name in {
        'report': 'report.json', 'standalone': 'standalone.json', 'raw': 'raw',
        'hello': 'hello.json', 'ready': 'ready.json', 'log': 'run.log', 'execution': 'execution.json',
        'summary': 'summary.json'}.items()}
    flutter = os.environ.get('FLUTTER_BIN', 'flutter')
    renderer = os.environ['TERRA_PERF_RENDERER']
    argv = [flutter, '--no-version-check', '--suppress-analytics', 'drive',
            '--no-pub', '--profile', '-d', 'linux', '--host-vmservice-port=0',
            '--driver=test_driver/ui_profile_driver.dart', f'--target={TARGET}',
            '--dart-define=ABC_MEMORY_OWNERSHIP=true',
            f'--dart-define=PERF_COMMIT={head}', f'--dart-define=PERF_CHECKED_OUT_HEAD={head}',
            '--dart-define=PERF_WORKTREE_DIRTY=false', f'--dart-define=PERF_FLUTTER_VERSION={version}',
            f'--dart-define=PERF_RENDERER={renderer}']
    env = dict(os.environ, MEMORY_OWNER_ARM=arm, ABC_OWNER_SCHEDULE=str(SCHEDULE), ABC_OWNER_LIBC_HELPER=str(helper),
               ABC_OWNER_HELLO=str(paths['hello']), ABC_OWNER_READY=str(paths['ready']),
               ABC_MEMORY_RAW_DIRECTORY=str(paths['raw']),
               TERRA_UI_PROFILE_OUTPUT=str(paths['report']),
               TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(paths['standalone']))
    if arm == 'probe-only':
        env.pop('COMPUTERRARIA_WLD', None)
    execution = {'schema': 'abc.memory-ownership-execution.v1', 'arm': arm, 'status': 'running',
                 'sourceCommit': head, 'baseProductCommit': BASE, 'processInvocations': 1,
                 'sourceProvenanceSha256': proof_sha, 'scheduleSha256': digest(SCHEDULE),
                 'nativeEngineSha256': native_proof['nativeEngineSha256'],
                 'allocatorHelperSha256': native_proof['allocatorHelperSha256'],
                 'allocatorBuildSha256': native_proof['allocatorBuildSha256'],
                 'symbols': native_proof['symbols'], 'ownedProcess': False,
                 'identityGatePassed': False, 'measurementReleased': False,
                 'timeoutSeconds': DRIVER_SECONDS, 'runtimeTimeoutSeconds': RUNTIME_SECONDS,
                 'buildHelloTimeoutSeconds': BUILD_SECONDS, 'command': argv,
                 'startedAt': datetime.now(timezone.utc).isoformat(),
                 'launchedMonotonicNs': time.monotonic_ns()}
    save(paths['execution'], execution, new=True)
    process, identity, reader, log = None, None, None, None
    state = {'finished': False}
    build, build_sha, binaries = None, None, None
    start, hello_at = time.monotonic(), None
    try:
        verify_sources(proof, head)
        log = paths['log'].open('x')
        process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        execution['driverPid'] = process.pid
        reader = threading.Thread(target=drain_log, args=(process.stdout, log, state), daemon=True)
        reader.start()
        while process.poll() is None:
            now = time.monotonic()
            if state.get('error'):
                raise ValueError(state['error'])
            if now - group_start > GROUP_SECONDS or now - start > DRIVER_SECONDS:
                raise TimeoutError('Fixed group/invocation timeout')
            if hello_at is None:
                if paths['hello'].exists():
                    hello = read_json(paths['hello'])
                    validate_hello(hello, arm, head)
                    identity = _OwnedProcess(hello['hostPid'], process.pid)
                    execution['processIdentity'] = dict(identity.identity)
                    execution['ownedProcess'] = True
                    execution['helloMonotonicNs'] = time.monotonic_ns()
                    hello_at = now
                    save(paths['execution'], execution)
                    verify_sources(proof, head)
                    build, build_sha, binaries = capture_build(folder, head, proof_sha, helper, native_proof)
                    execution.update({'buildSha256': build_sha,
                                      'binarySha256': binaries['terraforge']['sha256'], 'binaries': binaries})
                    require_equal_binaries(binaries, expected_binaries)
                    loaded = loaded_executable(identity)
                    execution.update({'loadedExecutableSha256': loaded['sha256'],
                                      'loadedExecutableBytes': loaded['bytes']})
                    if loaded != binaries['terraforge']:
                        raise ValueError('Owned child executable differs from recorded bundle')
                    if time.monotonic() - hello_at > 60:
                        raise TimeoutError('Pre-gauge binary identity gate exceeded 60 seconds')
                    execution['identityGatePassed'] = True
                    execution['identityGatePassedMonotonicNs'] = time.monotonic_ns()
                    publish_ready(paths['ready'], {'schema': 'abc.memory-ownership-ready.v1',
                                  'arm': arm, 'hostPid': hello['hostPid'], 'sourceCommit': head,
                                  'baseProductCommit': BASE, 'buildSha256': build_sha})
                    execution['measurementReleased'] = True
                    save(paths['execution'], execution)
                elif now - start > BUILD_SECONDS:
                    raise TimeoutError('Fixed build/hello timeout')
            elif now - hello_at > RUNTIME_SECONDS:
                raise TimeoutError('Fixed post-hello runtime timeout')
            # Process identity is pinned once; no new memory sampler is added.
            time.sleep(0.1)
        execution['exitCode'] = process.returncode
        if process.returncode != 0 or identity is None:
            raise ValueError('Diagnostic exited unsuccessfully or without owned hello')
        execution['status'] = 'completed'
    except (Exception, KeyboardInterrupt) as error:
        execution['status'] = 'timeout' if isinstance(error, TimeoutError) else 'failed'
        execution['error'] = safe_text(error)
    finally:
        if process is not None:
            stop_group(process)
            execution.setdefault('exitCode', process.returncode)
        if identity is not None:
            identity.close()
        if reader is not None:
            reader.join(timeout=10)
        if log is not None:
            log.close()
        execution['exitedMonotonicNs'] = time.monotonic_ns()
        execution['logReaderFinished'] = state['finished']
        if state.get('error') or not state['finished']:
            execution['status'] = 'failed'
            execution['logError'] = state.get('error', 'Reader did not terminate')
        save(paths['execution'], execution)
    result = {'evidenceValid': False, 'status': 'failed', 'arm': arm,
              'errors': [execution.get('error', 'No completed diagnostic evidence')]}
    try:
        if execution['status'] != 'completed':
            raise ValueError('Failed invocation cannot be reported as completed')
        verify_sources(proof, head)
        report = read_json(paths['report'])
        validate_target(report, arm, head, execution['processIdentity']['pid'])
        bundle = ROOT / 'build/linux/x64/profile/bundle'
        for name, location in {'terraforge': bundle / 'terraforge',
                               'libapp.so': bundle / 'lib/libapp.so',
                               'libabc_engine.so': bundle / 'lib/libabc_engine.so',
                               helper.name: helper}.items():
            if digest(location) != binaries[name]['sha256']:
                raise ValueError('Actual code changed after the pre-gauge identity gate')
        for report_path in (paths['report'], paths['standalone']):
            if report_path.exists():
                value = read_json(report_path)
                validate_target(value, arm, head, execution['processIdentity']['pid'])
                value['runtime'].update({'buildProvenanceSha256': build_sha,
                                         'sourceTreeSha256': build['sourceTreeSha256'],
                                         'provenanceAttachment': 'single-diagnostic-runner-after-process'})
                save(report_path, value)
        report = read_json(paths['report'])
        execution.update({'buildSha256': build_sha, 'reportSha256': digest(paths['report']),
                          'binarySha256': binaries['terraforge']['sha256'], 'binaries': binaries})
        save(paths['execution'], execution)
        result = validate_arm(report, paths['raw'], build, head, build_sha, execution,
                              read_json(SCHEDULE), digest(SCHEDULE), digest(paths['report']))
    except Exception as error:
        result['errors'] = [safe_text(error)]
    save(paths['summary'], result, new=True)
    return execution, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--source-proof', required=True, type=Path)
    parser.add_argument('--native-proof', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    proof, native = read_json(args.source_proof), read_json(args.native_proof)
    head = command('git', 'rev-parse', 'HEAD')
    helper = args.helper.resolve()
    verify_sources(proof, head)
    if native.get('sourceCommit') != head or native.get('symbols') != {
            'perfAbi': 1, 'ownerAbi': 1, 'requiredSymbolsVerified': True}:
        raise ValueError('Actual ABI preflight has not passed for this source')
    if digest(helper) != native['allocatorHelperSha256']:
        raise ValueError('Separate helper differs from preflight')
    world = Path(os.environ['COMPUTERRARIA_WLD'])
    if world.stat().st_size != 405983441 or digest(world) != WLD_SHA:
        raise ValueError('Fixed public WLD identity differs')
    flutter = os.environ.get('FLUTTER_BIN', 'flutter')
    version = json.loads(command(flutter, '--no-version-check', '--suppress-analytics', '--version', '--machine'))['frameworkVersion']
    if version != (ROOT / '.flutter-version').read_text().strip():
        raise ValueError('Pinned Flutter version differs')
    os.environ['ABC_PERF_COMMIT'] = head
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f'Signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    group = {'schema': 'abc.memory-ownership-group.v1', 'status': 'running',
             'sourceCommit': head, 'baseProductCommit': BASE,
             'sourceProvenanceSha256': digest(args.source_proof),
             'scheduleSha256': digest(SCHEDULE), 'armOrder': list(ARMS), 'executions': []}
    results, started = [], time.monotonic()
    save(output / 'group.json', group, new=True)
    for arm in ARMS:
        expected = group['executions'][0]['binaries'] if group['executions'] else None
        execution, result = run_arm(arm, output, head, version, proof, digest(args.source_proof), helper, native, started, expected)
        group['executions'].append(execution)
        results.append(result)
        save(output / 'group.json', group)
        if not result.get('evidenceValid'):
            break
    group['status'] = 'completed' if len(results) == 2 and all(r.get('evidenceValid') for r in results) else 'failed'
    save(output / 'group.json', group)
    validation = validate_group(group, results)
    save(output / 'group-summary.json', validation, new=True)
    print(json.dumps({'status': group['status'], 'armsStarted': len(results),
                      'evidenceValid': validation.get('evidenceValid'), 'stability': 'not-established'}))
    return 0 if validation.get('evidenceValid') else 1


if __name__ == '__main__':
    raise SystemExit(main())
