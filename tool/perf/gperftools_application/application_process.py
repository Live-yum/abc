"""Owned-process supervision for the reviewed application CI only.

Unlike the offline allowlist runner, preserve CI, Flutter engine switches and
original workload variables. Strip profiler/loader variables for every compiler,
driver and analyst; only the sealed native launcher injects the target.
"""
from __future__ import annotations
import hashlib
import json
import os
import resource
from pathlib import Path
import subprocess
import time

from application_contract import bounded_bytes, require
from bounded_supervision import (_child_limits, _peek_exit, cleanup_owned_group,
                                 CLEANUP_RESERVE_SECONDS, CHILD_FILE_BYTES)

PROFILER_PREFIXES = ('LD_', 'HEAP', 'TCMALLOC', 'CPUPROFILE', 'MALLOC')


def clean_environment(source):
    result = {key: value for key, value in source.items()
              if not key.startswith(PROFILER_PREFIXES) and key != 'ABC_STACK_OUTPUT'}
    result.update(LC_ALL='C', LANG='C', DEBUGINFOD_URLS='')
    return result


def save(path, value, *, new=False):
    path = Path(path)
    data = (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()
    require(len(data) <= 4 << 20, 'Application JSON evidence exceeds 4 MiB')
    if new:
        with path.open('xb') as stream:
            stream.write(data)
    else:
        pending = path.with_name(path.name + '.pending')
        with pending.open('xb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(pending, path)


def read_json(path):
    value = json.loads(bounded_bytes(path, 4 << 20))
    require(isinstance(value, dict), 'Expected bounded evidence object')
    return value


class LineBudget:
    """Check new log bytes once, including fast exits, without a log reader thread."""
    def __init__(self, path, cap):
        self.path, self.cap, self.offset, self.line_bytes = Path(path), cap, 0, 0

    def check(self, final=False):
        size = self.path.stat().st_size
        require(self.offset <= size <= self.cap, 'Command log cap/truncation')
        with self.path.open('rb') as stream:
            stream.seek(self.offset)
            # A log never exceeds 8 MiB; each sweep still reads at most 1 MiB.
            data = stream.read(1 << 20)
        self.offset += len(data)
        for part in data.splitlines(keepends=True):
            self.line_bytes += len(part)
            require(self.line_bytes <= 65536, 'Command log line exceeds 64 KiB')
            if part.endswith(b'\n'):
                self.line_bytes = 0
        if final and self.offset < size:
            return False
        return True


def application_limits():
    # Original application saves/reopens the unchanged ~406 MB WLD. Never
    # impose the auxiliary 64 MiB file limit on Flutter or its application.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_command(argv, directory, *, cwd, environment, deadline, watch=None,
                log_cap=2 << 20, stdout=None, stdout_cap=None, application=False):
    """Exactly one command, dynamic deadline, WNOWAIT until owned-group cleanup.

    watch(process) can shorten the deadline after hello and receives the actual
    leader before any reaping. It must not call poll/wait/communicate. Raw stdout
    can be redirected to an evidence path with its independent parser cap.
    """
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    outpath = Path(stdout) if stdout is not None else directory / 'stdout.log'
    errpath = directory / 'stderr.log'
    cap = stdout_cap if stdout_cap is not None else log_cap
    require(0 < cap <= CHILD_FILE_BYTES and log_cap <= 8 << 20, 'Command log acceptance cap')
    record = {'argv': list(map(str, argv)), 'attempts': 1, 'status': 'running',
              'started': time.monotonic(), 'errors': [], 'cleanup': None,
              'fileLimitPolicy': 'inherited-original-application' if application else 'auxiliary-64MiB',
              'environmentPolicy': 'retain-original-CI-workload-strip-profiler-loader'}
    process = None
    command_report = directory / 'command.json'
    save(command_report, record, new=True)
    outguard, errguard = LineBudget(outpath, cap), LineBudget(errpath, log_cap)

    def check(final=False):
        if application and stdout is None:
            require(outpath.stat().st_size + errpath.stat().st_size <= log_cap,
                    'Original combined application log budget exceeded')
        if stdout is None:
            done = outguard.check(final)
        else:
            require(outpath.stat().st_size <= cap, 'Command stdout acceptance cap')
            done = True
        done = errguard.check(final) and done
        if watch is not None:
            watch(process)
        require(time.monotonic() < deadline() - CLEANUP_RESERVE_SECONDS,
                'Shared command deadline reached; cleanup reserve retained')
        return done

    try:
        require(time.monotonic() + CLEANUP_RESERVE_SECONDS < deadline(), 'No command/cleanup budget')
        with outpath.open('xb') as out, errpath.open('xb') as err:
            process = subprocess.Popen(record['argv'], cwd=cwd, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=err,
                                       env=clean_environment(environment),
                                       start_new_session=True, preexec_fn=application_limits if application else _child_limits)
            record['ownedProcessGroup'] = process.pid
            save(command_report, record)
            while True:
                check()
                code = _peek_exit(process)
                if code is not None:
                    record['returnCode'] = code
                    break
                time.sleep(.01)
            while not check(final=True):
                pass
            require(code == 0, 'Nonzero command exit')
    except BaseException as error:
        record['errors'].append(str(error) or type(error).__name__)
    finally:
        if process is not None:
            try:
                cleanup = cleanup_owned_group(process, deadline=deadline())
                record['cleanup'] = cleanup
                record.setdefault('returnCode', cleanup['returnCode'])
                require(cleanup['groupGone'], 'Owned group remains after cleanup')
            except BaseException as error:
                record['errors'].append('Cleanup: ' + (str(error) or type(error).__name__))
        for key, path in (('stdout', outpath), ('stderr', errpath)):
            if path.exists():
                try:
                    payload = bounded_bytes(path, CHILD_FILE_BYTES)
                    record[key] = {'path': str(path), 'bytes': len(payload),
                                   'sha256': hashlib.sha256(payload).hexdigest()}
                except Exception as error:
                    record['errors'].append(key + ': ' + str(error))
        if time.monotonic() > deadline():
            record['errors'].append('Shared deadline exceeded during cleanup')
        record['finished'] = time.monotonic()
        record['status'] = 'failed' if record['errors'] else 'complete'
        save(command_report, record)
    require(record['status'] == 'complete', '; '.join(record['errors']))
    return record
