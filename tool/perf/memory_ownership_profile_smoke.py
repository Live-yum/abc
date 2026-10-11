#!/usr/bin/env python3
"""Run the tiny independent Profile-hook preflight, retaining sanitized output."""
import argparse
import os
from pathlib import Path
import subprocess
import threading
import time

from computer_memory_run import stop_group
from memory_ownership_preflight import ROOT
from memory_ownership_run import drain_log, read_json, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report, standalone = output / 'report.json', output / 'standalone.json'
    env = dict(os.environ, TERRA_UI_PROFILE_OUTPUT=str(report),
               TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(standalone))
    argv = [os.getenv('FLUTTER_BIN', 'flutter'), '--no-version-check', '--suppress-analytics',
            'drive', '--profile', '--no-pub', '-d', 'linux', '--host-vmservice-port=0',
            '--driver=test_driver/ui_profile_driver.dart',
            '--target=integration_test/memory_ownership_profile_smoke_test.dart',
            '--dart-define=ABC_MEMORY_OWNERSHIP=true']
    state, process, reader = {'finished': False}, None, None
    started = time.monotonic()
    with (output / 'profile-smoke.log').open('x') as log:
        try:
            process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            reader = threading.Thread(target=drain_log, args=(process.stdout, log, state), daemon=True)
            reader.start()
            while process.poll() is None:
                if state.get('error') or time.monotonic() - started > 360:
                    raise ValueError(state.get('error', 'Profile smoke hard timeout'))
                time.sleep(.1)
            if process.returncode != 0:
                raise ValueError('Profile smoke process failed')
        finally:
            if process:
                stop_group(process)
            if reader:
                reader.join(timeout=10)
        if state.get('error') or not state['finished']:
            raise ValueError('Profile smoke log is incomplete')
    payload = read_json(report)
    if payload.get('schema') != 'abc.memory-ownership-profile-smoke.v1' or payload.get('status') != 'passed':
        raise ValueError('Profile hook smoke result missing or invalid')
    save(output / 'execution.json', {'status': 'passed', 'processInvocations': 1,
                                   'measurementArm': False, 'timeoutSeconds': 360}, new=True)


if __name__ == '__main__':
    main()
