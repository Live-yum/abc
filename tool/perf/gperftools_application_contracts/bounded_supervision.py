"""Reusable bounded supervision primitives, exercised only by offline stubs.

There is deliberately no CLI, Flutter command, WLD path, or application runner.
Every child gets a fresh process group; waitid(WNOWAIT) pins the group leader
until all signals have been sent. No numeric PGID is ever signalled after reap.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import stat
import subprocess
import time

from application_contract import ContractError, require, bounded_bytes

BUILD_HELLO_SECONDS = 300
RUNTIME_SECONDS = 600
ARM_SECONDS = 900
PAIR_SECONDS = 2000
IDENTITY_SECONDS = 60
HOOK_SECONDS = 10
ACK_SECONDS = 2
PROFILE_ANALYSIS_SECONDS = 120
TOOL_LOG_BYTES = 2 << 20
CHILD_FILE_BYTES = 64 << 20  # Safety guard, not a parser/acceptance bound.
CLEANUP_RESERVE_SECONDS = 1.5


@dataclass
class PairBudget:
    """Exact inherited deadlines; first failed arm permanently closes the pair."""
    started: float
    clock: object = time.monotonic
    arms: list = field(default_factory=list)
    failed: bool = False

    @property
    def deadline(self):
        return self.started + PAIR_SECONDS

    def start_arm(self, name):
        require(name in ('probe-only', 'product-with-ownership') and not self.failed, 'Pair stopped after failure')
        require(len(self.arms) < 2 and name == ('probe-only', 'product-with-ownership')[len(self.arms)],
                'Exactly one fresh control then product arm; no retry')
        require(not self.arms or self.arms[-1]['status'] == 'complete',
                'First arm incomplete; second arm forbidden')
        now = self.clock()
        require(now < self.deadline, 'Pair deadline expired')
        arm = {'name': name, 'started': now, 'status': 'running', 'hello': None,
               'deadline': min(now + ARM_SECONDS, self.deadline), 'errors': [], 'analyses': {}}
        self.arms.append(arm)
        return arm

    def stage_deadline(self, kind, *, began=None, hook_began=None):
        require(self.arms and self.arms[-1]['status'] == 'running' and not self.failed,
                'No active successful arm')
        arm = self.arms[-1]
        bounds = [self.deadline, arm['deadline']]
        if kind in ('build', 'hello'):
            bounds.append(arm['started'] + BUILD_HELLO_SECONDS)
        elif kind == 'runtime':
            require(arm['hello'] is not None, 'Runtime starts after original hello')
            bounds.append(arm['hello'] + RUNTIME_SECONDS)
        elif kind in ('identity', 'hook', 'ack', 'analysis'):
            require(began is not None, 'Stage start required')
            bounds.append(began + {'identity': IDENTITY_SECONDS, 'hook': HOOK_SECONDS,
                                   'ack': ACK_SECONDS, 'analysis': PROFILE_ANALYSIS_SECONDS}[kind])
            if kind in ('hook', 'ack'):
                require(arm['hello'] is not None, 'Hook before hello')
                bounds.append(arm['hello'] + RUNTIME_SECONDS)
            if kind == 'ack':
                require(hook_began is not None and hook_began <= began,
                        'ACK must retain enclosing hook deadline')
                bounds.append(hook_began + HOOK_SECONDS)
        else:
            raise ContractError('Unknown stage deadline')
        result = min(bounds)
        require(self.clock() < result, 'Shared stage deadline expired')
        return result

    def hello(self):
        arm = self.arms[-1]
        require(arm['hello'] is None and self.clock() <= self.stage_deadline('hello'),
                'Duplicate/late original hello')
        arm['hello'] = self.clock()

    def complete_arm(self, result):
        arm = self.arms[-1]
        require(not self.failed and arm['status'] == 'running' and arm['hello'] is not None
                and self.clock() < arm['deadline'],
                'Cannot complete failed/late arm')
        require(all(result.get(key) is True for key in ('workloadComplete', 'heapFilesComplete',
                                                       'stackAttributionAvailable')),
                'Arm evidence incomplete')
        arm['status'] = 'complete'
        arm['completion'] = result

    def profile_analysis_deadline(self, cut, mode):
        require(cut in ('q0', 'q7') and mode in ('inuse_space', 'inuse_objects'),
                'Only two endpoint profiles/two integer modes')
        arm = self.arms[-1]
        item = arm['analyses'].setdefault(cut, {'started': self.clock(), 'modes': []})
        require(mode not in item['modes'], 'Official analysis retry forbidden')
        deadline = self.stage_deadline('analysis', began=item['started'])
        item['modes'].append(mode)
        return deadline

    def fail(self, error):
        self.failed = True
        if self.arms:
            self.arms[-1]['status'] = 'failed'
            self.arms[-1]['errors'].append(str(error))

    def report(self):
        return {'arms': self.arms, 'failed': self.failed,
                'notStarted': ['probe-only', 'product-with-ownership'][len(self.arms):],
                'pairDeadline': self.deadline, 'automaticRetryAllowed': False}


def clean_tool_env(extra=None):
    """Offline stub/compiler/analyst allowlist; NOT a Flutter-driver interface.

    It intentionally omits CI and workload variables. Future authorized driver
    integration must use its separately audited driver environment contract.
    """
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C', 'DEBUGINFOD_URLS': ''}
    allowed = {'DISPLAY', 'XAUTHORITY', 'HOME', 'TMPDIR', 'PPROF_TMPDIR', 'XDG_RUNTIME_DIR'}
    for key, value in (extra or {}).items():
        require(key in allowed and isinstance(value, str), 'Unexpected tool environment key')
        env[key] = value
    return env


def _child_limits():
    resource.setrlimit(resource.RLIMIT_FSIZE, (CHILD_FILE_BYTES, CHILD_FILE_BYTES))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class TargetProcessIdentity:
    """Read-only target identity bound to retained /proc and executable FDs.

    This does not authorize a launch and never signals a PID. The caller must
    supply the PID from the audited original hello and a freshly owned group.
    """
    def __init__(self, pid, *, owned_pgid, expected_executable, expected_sha256):
        require(type(pid) is int and pid > 0 and type(owned_pgid) is int and owned_pgid > 0,
                'Invalid target PID/group')
        self.pid, self.expected_pgid = pid, owned_pgid
        self.proc_fd = os.open(f'/proc/{pid}', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.exe_fd = None
        try:
            self.identity = self._process_identity()
            actual_path = os.readlink('exe', dir_fd=self.proc_fd)
            require(actual_path == str(expected_executable), 'Loaded target executable path differs')
            # /proc/<pid>/exe is the intentional kernel magic link. Its opened
            # file descriptor pins executable bytes; arbitrary paths are not used.
            self.exe_fd = os.open('exe', os.O_RDONLY, dir_fd=self.proc_fd)
            info = os.fstat(self.exe_fd)
            require(stat.S_ISREG(info.st_mode) and info.st_size <= 64 << 20,
                    'Loaded target executable size/type cap')
            digest, size = hashlib.sha256(), 0
            while True:
                chunk = os.read(self.exe_fd, 1 << 20)
                if not chunk:
                    break
                size += len(chunk)
                require(size <= 64 << 20, 'Loaded target executable 64 MiB cap')
                digest.update(chunk)
            require(size == info.st_size and digest.hexdigest() == expected_sha256,
                    'Loaded target executable SHA/size differs')
            self.verify()
            self.evidence = dict(self.identity, path=actual_path, sha256=digest.hexdigest(),
                                 bytes=size, device=info.st_dev, inode=info.st_ino,
                                 procFdRetained=True, executableFdRetained=True)
        except Exception:
            self.close()
            raise

    def _read_proc(self, name):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.proc_fd)
        with os.fdopen(fd, 'rb') as stream:
            data = stream.read(65537)
        require(len(data) <= 65536, 'Target proc metadata cap')
        return data.decode('ascii')

    def _process_identity(self):
        data = self._read_proc('stat')
        fields = data[data.rfind(')') + 2:].split()
        require(len(fields) >= 20, 'Malformed target proc stat')
        uid_rows = [line.split()[1:] for line in self._read_proc('status').splitlines()
                    if line.startswith('Uid:')]
        require(len(uid_rows) == 1 and len(uid_rows[0]) == 4
                and all(int(uid) == os.getuid() for uid in uid_rows[0]), 'Target UID differs')
        require(int(fields[2]) == self.expected_pgid, 'Target is not in the owned process group')
        return {'pid': self.pid, 'pgid': int(fields[2]), 'uid': os.getuid(),
                'starttimeTicks': int(fields[19])}

    def verify(self):
        require(self._process_identity() == self.identity, 'Target UID/group/starttime identity changed')

    def close(self):
        for name in ('exe_fd', 'proc_fd'):
            descriptor = getattr(self, name, None)
            if descriptor is not None:
                os.close(descriptor)
                setattr(self, name, None)


def _peek_exit(process):
    require(process.returncode is None, 'Owned leader already reaped; refuse numeric group signal')
    try:
        info = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    except ChildProcessError as exc:
        raise ContractError('Owned leader lost/waited elsewhere; refuse numeric group signal') from exc
    if info is None:
        return None
    return info.si_status if info.si_code == os.CLD_EXITED else -info.si_status


def cleanup_owned_group(process, *, deadline):
    """TERM/KILL before wait; afterward group probes are read-only."""
    record = {'pid': process.pid, 'pgid': process.pid, 'signals': [], 'reaped': False,
              'groupGone': False}
    for sig in (signal.SIGTERM, signal.SIGKILL):
        _peek_exit(process)  # WNOWAIT even if it has already exited quickly.
        require(os.getpgid(process.pid) == process.pid, 'Owned leader process-group changed')
        try:
            os.killpg(process.pid, sig)
            record['signals'].append({'signal': sig.name, 'leaderUnreaped': True})
        except ProcessLookupError:
            pass
        if sig == signal.SIGTERM:
            time.sleep(min(0.15, max(0, deadline - time.monotonic())))
    # This is the first operation permitted to reap the leader.
    process.wait(timeout=max(0.001, min(1.0, deadline - time.monotonic())))
    record['reaped'] = True
    record['returnCode'] = process.returncode
    while True:
        try:
            os.killpg(process.pid, 0)  # Read-only; never signal after wait.
        except ProcessLookupError:
            record['groupGone'] = True
            return record
        if time.monotonic() >= deadline:
            return record
        time.sleep(min(0.02, max(0, deadline - time.monotonic())))


def _write_record(path, record):
    # Only the private command evidence path is rewritten, never partial outputs.
    data = (json.dumps(record, indent=2, sort_keys=True) + '\n').encode()
    require(len(data) <= 4 << 20, 'Command evidence JSON cap')
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
    os.replace(temporary, path)


def run_bounded(argv, output, *, deadline, watch=None, stdout_cap=TOOL_LOG_BYTES,
                env=None, poll_interval=0.01):
    """Run a caller-authorized tool/stub once, preserving every partial output.

    Only offline stubs/ordinary compiler/analyst tools use this interface. It is
    not an application/Flutter driver interface and does not preserve workload
    or SDK CI variables. The caller supplies one shared deadline with cleanup.
    module intentionally does not construct application commands or run pairs.
    `watch` performs bounded checks (receipt, RSS log, sidecar) each sweep and once
    after a fast exit. Any exception fails the command; cleanup failure is retained
    alongside the first error rather than replacing it.
    """
    require(0 < stdout_cap <= CHILD_FILE_BYTES, 'Invalid accepted stdout cap')
    require(0 < poll_interval <= 0.05, 'Unbounded polling interval')
    require(time.monotonic() + CLEANUP_RESERVE_SECONDS < deadline, 'No shared time for command and cleanup')
    output = Path(output)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    outpath, errpath, report = output / 'stdout', output / 'stderr', output / 'command.json'
    record = {'argv': [str(a) for a in argv], 'started': time.monotonic(),
              'deadline': deadline, 'status': 'running', 'errors': [],
              'cleanup': None, 'attempts': 1}
    process = None
    _write_record(report, record)

    def check():
        require(outpath.stat().st_size <= stdout_cap, 'stdout acceptance cap exceeded')
        require(errpath.stat().st_size <= TOOL_LOG_BYTES, 'stderr acceptance cap exceeded')
        if watch is not None:
            watch()

    try:
        with outpath.open('xb') as out, errpath.open('xb') as err:
            process = subprocess.Popen(record['argv'], cwd=output, stdin=subprocess.DEVNULL,
                                       stdout=out, stderr=err, env=clean_tool_env(env),
                                       start_new_session=True, preexec_fn=_child_limits)
            record['ownedProcessGroup'] = process.pid
            _write_record(report, record)
            while True:
                check()
                exit_code = _peek_exit(process)
                if exit_code is not None:
                    record['returnCode'] = exit_code
                    break
                require(time.monotonic() < deadline - CLEANUP_RESERVE_SECONDS,
                        'Command shared deadline reached (cleanup reserve)')
                time.sleep(poll_interval)
            check()  # Fast-exit output/resource/receipt failures remain failures.
            require(record['returnCode'] == 0, 'Nonzero command exit')
    except Exception as exc:
        record['errors'].append(str(exc))
    finally:
        if process is not None:
            try:
                record['cleanup'] = cleanup_owned_group(process, deadline=deadline)
                record.setdefault('returnCode', record['cleanup']['returnCode'])
                if not record['cleanup']['groupGone']:
                    record['errors'].append('Owned process group remains after cleanup')
            except Exception as exc:
                record['errors'].append('Owned cleanup failed: ' + str(exc))
        # Hash bounded logs after cleanup; output past an acceptance cap is still
        # retained up to RLIMIT_FSIZE for audit, never truncated or removed.
        for name, path in (('stdout', outpath), ('stderr', errpath)):
            if path.exists():
                try:
                    data = bounded_bytes(path, CHILD_FILE_BYTES)
                    record[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                except Exception as exc:
                    record['errors'].append(name + ' evidence: ' + str(exc))
        if time.monotonic() > deadline:
            record['errors'].append('Shared deadline exceeded during cleanup')
        record['status'] = 'failed' if record['errors'] else 'complete'
        record['finished'] = time.monotonic()
        _write_record(report, record)
    return record
