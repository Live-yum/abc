#!/usr/bin/env python3
"""Run independent benchmark processes sequentially, preserving every attempt."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time
import uuid


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def machine():
    cpu = next((line.split(':', 1)[1].strip() for line in
                Path('/proc/cpuinfo').read_text().splitlines()
                if line.startswith('model name')), 'unknown')
    return dict(system=platform.system(), release=platform.release(),
                architecture=platform.machine(), processors=os.cpu_count(),
                cpuModel=cpu, image=os.getenv('ImageOS'),
                imageVersion=os.getenv('ImageVersion'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--report-env')
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--timeout-seconds', type=int, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    words = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not words or not 1 <= args.runs <= 5 or args.timeout_seconds <= 0:
        parser.error('Provide a command, 1–5 runs, and a positive process timeout')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    failed = False
    for number in range(1, args.runs + 1):
        report = args.output_dir / f'{args.suite}.run-{number}.json'
        manifest = report.with_suffix('.execution.json')
        log = report.with_suffix('.log')
        # Reruns must use another directory; never overwrite failed evidence.
        if any(path.exists() for path in (report, manifest, log)):
            raise SystemExit(f'Refusing to overwrite existing attempt: {report}')
        env = dict(os.environ)
        if args.report_env:
            env[args.report_env] = str(report.resolve())
        env['ABC_PERF_RUN_ID'] = str(uuid.uuid4())
        argv = [word.replace('{report}', str(report.resolve())) for word in words]
        status = command('git', 'status', '--porcelain', '--untracked-files=normal')
        record = dict(schema='abc.performance-execution.v1',
                      runId=env['ABC_PERF_RUN_ID'], suite=args.suite,
                      report=report.name, command=argv, machine=machine(),
                      source=dict(commit=env.get('ABC_PERF_COMMIT'),
                                  checkedOutHead=command('git', 'rev-parse', 'HEAD'),
                                  dirty=None if status is None else bool(status)),
                      github=dict(repository=env.get('GITHUB_REPOSITORY'),
                                  runId=env.get('GITHUB_RUN_ID'),
                                  runAttempt=env.get('GITHUB_RUN_ATTEMPT')),
                      startedAt=datetime.now(timezone.utc).isoformat(),
                      status='running')
        def save():
            manifest.write_text(json.dumps(record, indent=2) + '\n')
        save()
        started = time.monotonic()
        print(f'{args.suite} fresh process {number}/{args.runs}: {report}', flush=True)
        with log.open('w') as output:
            process = subprocess.Popen(argv, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            record['pid'] = process.pid
            save()
            try:
                record['exitCode'] = process.wait(timeout=args.timeout_seconds)
                record['status'] = 'passed' if process.returncode == 0 else 'failed'
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                record.update(status='timeout', exitCode=process.returncode)
        record['elapsedSeconds'] = time.monotonic() - started
        record['completedAt'] = datetime.now(timezone.utc).isoformat()
        if report.exists():
            record['reportSha256'] = hashlib.sha256(report.read_bytes()).hexdigest()
        else:
            record['status'] = 'missing-report'
        save()
        if record['status'] != 'passed':
            failed = True
            print(log.read_text()[-12000:], flush=True)
        # Retain failures and finish remaining independent repetitions where time permits.
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
