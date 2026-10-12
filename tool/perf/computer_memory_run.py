#!/usr/bin/env python3
"""One fresh profile diagnostic host; never retry, concatenate or replace evidence."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

from computerraria_provenance import record as record_build


LOCAL_SERVICE = re.compile(r'(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?[^\s<>"\']*')


def sanitize(text):
    # No VM auth path is written to disk, stdout, execution metadata or reports.
    return LOCAL_SERVICE.sub('[redacted-local-service-url]', text)


def validate_target_identity(report, head):
    """Associate only an exact diagnostic target, never a stale bundled app."""
    schema = report.get('schema')
    generic = schema == 'abc.generic-world-memory.v1'
    if (schema not in ('abc.computer-memory-diagnostic.v1', 'abc.generic-world-memory.v1') or
            (generic and report.get('workloadId') != 'generic-wld-controls-v1') or
            (not generic and report.get('workloadId') not in (None, 'legacy-computerraria-memory-v1')) or
            report.get('runtime', {}).get('commit') != head or
            type(report.get('hostPid')) is not int or report['hostPid'] < 1):
        raise ValueError('Target identity is unverified; skip build/report association')
    return schema


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def capture(*argv):
    return subprocess.check_output(argv, text=True).strip()


def stop_group(process):
    """Stop only this invocation's process group, including a leftover VM service."""
    for sig, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 1)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            continue
        # A driver can exit with descendants still alive. Do not leave those
        # services running merely because wait() returned for the driver.
        if sig == signal.SIGTERM:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    process.wait()


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: computer_memory_run.py NEW_REPORT.json')
    report = Path(sys.argv[1]).resolve()
    if report.suffix != '.json':
        raise SystemExit('Report path must end in .json')
    related = {name: report.with_suffix(suffix) for name, suffix in (
        ('execution', '.execution.json'), ('log', '.log'), ('build', '.build.json'),
        ('summary', '.summary.json'), ('standalone', '.standalone.json'),
        ('raw', '.raw'))}
    if any(path.exists() for path in [report, *related.values()]):
        raise SystemExit('Use a new diagnostic path; prior evidence is immutable')
    report.parent.mkdir(parents=True, exist_ok=True)
    flutter = os.environ.get('FLUTTER_BIN', 'flutter')
    head = capture('git', 'rev-parse', '--verify', 'HEAD')
    if head != os.environ.get('ABC_PERF_COMMIT', head):
        raise SystemExit('Requested source commit differs from checkout')
    if capture('git', 'status', '--porcelain', '--untracked-files=normal'):
        raise SystemExit('A clean committed test and product snapshot is required')
    version = json.loads(capture(flutter, '--no-version-check', '--suppress-analytics', '--version', '--machine'))['frameworkVersion']
    if version != Path('.flutter-version').read_text().strip():
        raise SystemExit('Pinned Flutter version mismatch')
    source = Path(os.environ['COMPUTERRARIA_WLD'])
    if source.stat().st_size != 405983441:
        raise SystemExit('Pinned full WLD required')
    renderer = os.environ['TERRA_PERF_RENDERER']
    env = dict(os.environ, TERRA_UI_PROFILE_OUTPUT=str(report),
               TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(related['standalone']),
               ABC_MEMORY_RAW_DIRECTORY=str(related['raw']))
    argv = [flutter, '--no-version-check', '--suppress-analytics', 'drive',
            '--no-pub', '--profile', '-d', 'linux', '--host-vmservice-port=0',
            '--driver=test_driver/ui_profile_driver.dart',
            '--target=integration_test/computer_memory_diagnostic_test.dart',
            f'--dart-define=PERF_COMMIT={head}',
            f'--dart-define=PERF_CHECKED_OUT_HEAD={head}',
            '--dart-define=PERF_WORKTREE_DIRTY=false',
            f'--dart-define=PERF_FLUTTER_VERSION={version}',
            f'--dart-define=PERF_RENDERER={renderer}']
    record = {'schema': 'abc.memory-diagnostic-execution.v1', 'status': 'running',
              'sourceCommit': head, 'processInvocations': 1, 'plannedCycles': 8,
              'startedAt': datetime.now(timezone.utc).isoformat(),
              'command': argv, 'timeoutSeconds': 2700,
              'logSanitization': 'local-service-URLs-redacted-before-persistence',
              'github': {'runId': os.getenv('GITHUB_RUN_ID'), 'runAttempt': os.getenv('GITHUB_RUN_ATTEMPT')}}

    def save():
        related['execution'].write_text(json.dumps(record, indent=2) + '\n')

    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f'Invocation interrupted by signal {signum}')

    signal.signal(signal.SIGTERM, interrupted)
    save()
    started = time.monotonic()
    process = None
    try:
        with related['log'].open('x') as output:
            process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True,
                                       errors='replace', start_new_session=True)
            record['driverPid'] = process.pid
            save()

            def drain():
                for line in process.stdout:
                    output.write(sanitize(line))
                    output.flush()

            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            try:
                record['exitCode'] = process.wait(timeout=2700)
                record['status'] = 'completed' if process.returncode == 0 else 'failed'
            except subprocess.TimeoutExpired:
                record['status'] = 'timeout'
            except KeyboardInterrupt:
                record['status'] = 'interrupted'
            finally:
                stop_group(process)
                record.setdefault('exitCode', process.returncode)
                reader.join(timeout=10)
                record['logReaderFinished'] = not reader.is_alive()
                record['ownedProcessGroupTerminationAttempted'] = True
        launch_report = report if report.exists() else related['standalone']
        if not launch_report.exists():
            raise ValueError('No diagnostic target report: prior bundle must not be attributed to this invocation')
        launch_evidence = json.loads(launch_report.read_text())
        validate_target_identity(launch_evidence, head)
        record['applicationHostPid'] = launch_evidence['hostPid']
        record['diagnosticTargetReported'] = True
        bundle = Path('build/linux/x64/profile/bundle')
        artifacts = [bundle / 'terraforge', bundle / 'lib/libabc_engine.so', bundle / 'lib/libapp.so']
        record_build([str(path) for path in artifacts], related['build'],
                     Path('build/linux/x64/profile/CMakeCache.txt'),
                     Path('build/linux/x64/profile/build.ninja'))
        build = json.loads(related['build'].read_text())
        if build['cmake'].get('ABC_PERF_COUNTERS') != 'OFF':
            raise ValueError('Diagnostic requires the ordinary counter-disabled profile native library')
        for path in (report, related['standalone']):
            if not path.exists():
                continue
            payload = json.loads(path.read_text())
            validate_target_identity(payload, head)
            if payload['hostPid'] != launch_evidence['hostPid'] or payload['schema'] != launch_evidence['schema']:
                raise ValueError('Diagnostic report copies name different target processes or schemas')
            payload['runtime'].update({
                'buildProvenanceSha256': digest(related['build']),
                'sourceTreeSha256': build['sourceTreeSha256'],
                'provenanceAttachment': 'single-diagnostic-runner-after-process',
            })
            # Also remove service URLs if a VM error included its connection URI.
            path.write_text(sanitize(json.dumps(payload, indent=2)) + '\n')
        result = subprocess.run([
            sys.executable, 'tool/perf/computer_memory_validate.py', str(report),
            '--raw-directory', str(related['raw']), '--build', str(related['build']),
            '--expected-commit', head, '--output', str(related['summary']),
        ], check=False)
        record['validatorExitCode'] = result.returncode
        if result.returncode != 0 or not record.get('logReaderFinished'):
            record['status'] = 'failed'
    except (Exception, KeyboardInterrupt) as error:
        record['status'] = 'failed'
        record['failure'] = sanitize(str(error))
    finally:
        if process is not None and process.poll() is None:
            stop_group(process)
        if not related['summary'].exists():
            related['summary'].write_text(json.dumps({
                'schema': 'abc.memory-diagnostic-summary.v1',
                'status': 'invalid-evidence', 'trendStatus': 'not-evaluated',
                'failures': [record.get('failure', record['status'])],
            }, indent=2) + '\n')
        record['completedAt'] = datetime.now(timezone.utc).isoformat()
        record['elapsedSeconds'] = time.monotonic() - started
        record['files'] = {
            path.name: {'sha256': digest(path), 'bytes': path.stat().st_size}
            for path in [report, related['standalone'], related['log'], related['build'], related['summary']]
            if path.is_file()
        }
        record['rawFiles'] = {
            path.name: {'sha256': digest(path), 'bytes': path.stat().st_size}
            for path in sorted(related['raw'].glob('*.jsonl')) if path.is_file()
        }
        save()
    print(json.dumps({'status': record['status'], 'report': str(report),
                      'execution': str(related['execution'])}))
    return 0 if record['status'] == 'completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
