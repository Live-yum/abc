#!/usr/bin/env python3
"""Stream Linux memory samples from one verified runner-owned application.

The caller must launch a fresh process group and get its application's PID
through a private handshake. Only that PID's status/smaps_rollup is read;
ancestor stat files are used solely to prove ownership. No PID discovery or
process-wide memory enumeration is performed. Call finish() before terminating
the application, and treat any SamplerError as a failed diagnostic.

Python timestamps are monotonic_ns(), not Dart Timeline.now(). A point's small
metadata map can carry Dart's sequence/cycle/dartTimeUs for correlation, but the
two clocks must not be subtracted or assumed to share an epoch.
"""

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import threading
import time


CLOCK_DOMAIN = 'python.time.monotonic_ns'
STATUS_INTERVAL_NS = 10_000_000
SMAPS_INTERVAL_NS = 100_000_000
MAX_PROC_BYTES = 65_536
MAX_ANCESTORS = 256


class SamplerError(RuntimeError):
    """The evidence is incomplete or the selected process is unverified."""


class ProcessOwnershipError(SamplerError):
    """The requested PID cannot be proven to belong to this runner."""


@dataclass(frozen=True)
class _Stat:
    pid: int
    state: str
    ppid: int
    pgid: int
    starttime: int


def _parse_stat(text, expected_pid):
    # comm may contain spaces and parentheses, including a closing parenthesis.
    try:
        left, right = text.index('('), text.rindex(')')
        pid = int(text[:left].strip())
        fields = text[right + 1:].split()
        result = _Stat(pid, fields[0], int(fields[1]), int(fields[2]),
                       int(fields[19]))
    except (ValueError, IndexError) as error:
        raise ProcessOwnershipError('Malformed process stat identity') from error
    if result.pid != expected_pid or result.starttime < 0:
        raise ProcessOwnershipError('Process stat identity does not match PID')
    return result


def _read_fd_text(directory_fd, name):
    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                 dir_fd=directory_fd)
    with os.fdopen(fd, 'rb') as source:
        data = source.read(MAX_PROC_BYTES + 1)
    if len(data) > MAX_PROC_BYTES:
        raise SamplerError('Unexpectedly large proc record')
    return data.decode('utf-8', errors='strict')


def _read_ancestor_stat(pid):
    # The only file ever read for another process is stat. Do not read that
    # process's status or smaps, even when determining its UID or ancestry.
    with open(f'/proc/{pid}/stat', 'rb') as source:
        data = source.read(MAX_PROC_BYTES + 1)
    if len(data) > MAX_PROC_BYTES:
        raise ProcessOwnershipError('Unexpectedly large ancestor stat')
    return _parse_stat(data.decode('utf-8', errors='strict'), pid)


class _OwnedProcess:
    def __init__(self, pid, expected_pgid):
        if any(type(value) is not int or value <= 0
               for value in (pid, expected_pgid)):
            raise ProcessOwnershipError('PID and process group must be positive integers')
        if pid == os.getpid() or expected_pgid in (os.getpid(), os.getpgrp()):
            raise ProcessOwnershipError('A distinct runner-launched process group is required')
        self.pid = pid
        self.pgid = expected_pgid
        self.runner_pid = os.getpid()
        self.uid = os.getuid()
        self.fd = None
        self.identity = None
        try:
            if os.geteuid() != self.uid:
                raise ProcessOwnershipError('Runner real and effective UID must match')
            # A retained proc directory fd binds reads to this task. A recycled
            # numeric PID cannot redirect openat() to a different task.
            self.fd = os.open(f'/proc/{pid}',
                              os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
            self.identity = self._verify()
        except BaseException:
            self.close()
            raise

    def _verify(self):
        try:
            if os.fstat(self.fd).st_uid != self.uid:
                raise ProcessOwnershipError('Application UID differs from runner UID')
            target = _parse_stat(_read_fd_text(self.fd, 'stat'), self.pid)
            if target.state in ('Z', 'X', 'x') or target.pgid != self.pgid:
                raise ProcessOwnershipError('Application exited or changed process group')
            cursor, seen, leader = target, set(), None
            for _ in range(MAX_ANCESTORS):
                if cursor.pid in seen:
                    raise ProcessOwnershipError('Invalid process ancestry cycle')
                seen.add(cursor.pid)
                if cursor.pid == self.pgid:
                    if cursor.pgid != self.pgid:
                        raise ProcessOwnershipError('Expected process group leader changed group')
                    leader = cursor
                if cursor.pid == self.runner_pid:
                    break
                if cursor.ppid <= 0:
                    raise ProcessOwnershipError('Application is not a descendant of this runner')
                cursor = _read_ancestor_stat(cursor.ppid)
            else:
                raise ProcessOwnershipError('Process ancestry exceeds verification bound')
            if leader is None:
                raise ProcessOwnershipError('Application is not descended from the launched group leader')
            identity = {
                'pid': self.pid, 'uid': self.uid, 'processGroupId': self.pgid,
                'starttimeTicks': target.starttime,
                'groupLeaderStarttimeTicks': leader.starttime,
                'runnerPid': self.runner_pid, 'runnerStarttimeTicks': cursor.starttime,
            }
            if self.identity is not None and identity != self.identity:
                raise ProcessOwnershipError('Pinned process identity changed (possible PID reuse)')
            return identity
        except (OSError, UnicodeError) as error:
            raise ProcessOwnershipError('Cannot verify owned application process') from error

    def verify(self):
        return dict(self._verify())

    def read(self, name):
        if name not in ('status', 'smaps_rollup'):
            raise ValueError('Only the selected process memory files may be sampled')
        self.verify()
        started = time.monotonic_ns()
        text = _read_fd_text(self.fd, name)
        ended = time.monotonic_ns()
        self.verify()
        return text, started, ended

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def process_identity(pid, expected_pgid):
    """Verify a handshake PID; return bounded identity data, or raise."""
    process = _OwnedProcess(pid, expected_pgid)
    try:
        return process.verify()
    finally:
        process.close()


def _memory_fields(text, required, optional=()):
    found = {}
    wanted = set(required) | set(optional)
    for line in text.splitlines():
        key, separator, value = line.partition(':')
        if separator and key in wanted:
            parts = value.split()
            if (key in found or len(parts) != 2 or parts[1] != 'kB'
                    or not parts[0].isdigit()):
                raise SamplerError(f'Malformed proc memory field: {key}')
            found[key] = int(parts[0]) * 1024
    missing = set(required) - found.keys()
    if missing:
        raise SamplerError('Missing proc memory fields: ' + ', '.join(sorted(missing)))
    return found


def _status_values(text, uid):
    uid_lines = [line for line in text.splitlines() if line.startswith('Uid:')]
    if len(uid_lines) != 1 or uid_lines[0].split()[1:] != [str(uid)] * 4:
        raise ProcessOwnershipError('Application status UID differs from runner UID')
    values = _memory_fields(text, ('VmRSS', 'VmHWM'))
    return {'rssBytes': values['VmRSS'], 'processVmHwmBytes': values['VmHWM']}


def _smaps_values(text):
    values = _memory_fields(text, ('Rss', 'Pss', 'Private_Clean', 'Private_Dirty'),
                            ('Private_Hugetlb',))
    # Private hugetlb mappings are excluded from the kernel's Rss/Pss fields.
    # Include them in USS and expose the component; absent older-kernel fields
    # are left null and the inclusion status is explicit, never invented as 0.
    huge = values.get('Private_Hugetlb')
    uss = values['Private_Clean'] + values['Private_Dirty']
    if huge is not None:
        uss += huge
    return {
        'smapsRssBytes': values['Rss'], 'pssBytes': values['Pss'], 'ussBytes': uss,
        'privateCleanBytes': values['Private_Clean'],
        'privateDirtyBytes': values['Private_Dirty'], 'privateHugetlbBytes': huge,
        'ussIncludesPrivateHugetlb': huge is not None,
    }


def _point_metadata(phase, metadata):
    if (not isinstance(phase, str) or not phase or len(phase) > 128
            or any(ord(character) < 32 or ord(character) == 127 for character in phase)):
        raise ValueError('Phase must be 1–128 characters without control characters')
    if metadata is None:
        return {}
    if not isinstance(metadata, dict) or len(metadata) > 16:
        raise ValueError('Point metadata must contain at most 16 scalar fields')
    result = {}
    for key, value in metadata.items():
        if not isinstance(key, str) or not key or len(key) > 64:
            raise ValueError('Point metadata keys must be 1–64 characters')
        if value is None or type(value) is bool:
            pass
        elif type(value) is int and -(2 ** 63) <= value < 2 ** 63:
            pass
        elif type(value) is float and math.isfinite(value):
            pass
        elif isinstance(value, str) and len(value) <= 256:
            pass
        else:
            raise ValueError('Point metadata values must be bounded JSON scalars')
        result[key] = value
    return result


class ExternalOsSampler:
    """10 ms status / 100 ms rollup target cadence, plus synchronous points.

    start() returns self. point(phase, metadata) returns the flushed OS row;
    acknowledge the corresponding application request only after it returns.
    check() polls background failure without a sample. finish() stops sampling,
    closes files and returns a manifest, or raises on any sampling failure.
    The manifest property remains available after failure; raw JSONL is never
    deleted, rewritten, or replaced. No list of samples is retained in memory.
    """

    def __init__(self, pid, expected_pgid, output_file):
        self.pid, self.expected_pgid = pid, expected_pgid
        self.output_file = Path(output_file)
        self._process = self._output = self._thread = None
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._failure = None
        self._state = 'new'
        self._sha256 = hashlib.sha256()
        self._bytes = self._rows = self._smaps_rows = self._points = 0
        self._missed_status_ticks = 0
        self._first_ns = self._last_ns = self._last_smaps_ns = None
        self._max_status_gap_ns = 0
        self._identity = None

    def start(self):
        with self._lock:
            if self._state != 'new':
                raise SamplerError('Sampler may only be started once')
            try:
                self._process = _OwnedProcess(self.pid, self.expected_pgid)
                self._identity = self._process.verify()
                try:
                    self._output = self.output_file.open('x', encoding='utf-8', newline='\n')
                except OSError as error:
                    raise SamplerError('Raw output must be a new writable file') from error
                self._state = 'running'
                self._sample('sampler-start', {}, True, False)
                self._thread = threading.Thread(target=self._run,
                                                name='external-os-sampler', daemon=True)
                self._thread.start()
            except Exception as error:
                self._fail(error)
                self._close()
                self.check()
        return self

    def _fail(self, error):
        if self._failure is None:
            self._failure = error
        self._state = 'failed'
        self._stop.set()

    def check(self):
        with self._lock:
            if self._failure is not None:
                raise SamplerError(f'External OS sampler failed: {self._failure}') from self._failure

    def _sample(self, phase, metadata, include_smaps, point):
        status, started, ended = self._process.read('status')
        row = {
            'schema': 'abc.memory-probe-control-os.v1', 'type': 'os',
            'sequence': self._rows, 'phase': phase, 'pid': self.pid,
            'starttimeTicks': self._identity['starttimeTicks'],
            'clockDomain': CLOCK_DOMAIN, 'timeUnit': 'nanoseconds',
            'timeNs': started, 'statusEndNs': ended, 'atomic': False,
            **_status_values(status, self._identity['uid']),
        }
        if metadata:
            row['metadata'] = metadata
            if 'dartTimeUs' in metadata:
                row['metadataClockDomains'] = {'dartTimeUs': 'dart:developer.Timeline.now'}
        if include_smaps:
            smaps, smaps_started, smaps_ended = self._process.read('smaps_rollup')
            row.update({'smapsTimeNs': smaps_started, 'smapsEndNs': smaps_ended,
                        **_smaps_values(smaps)})
        encoded = json.dumps(row, separators=(',', ':'), ensure_ascii=True,
                             allow_nan=False) + '\n'
        self._output.write(encoded)
        self._output.flush()
        self._sha256.update(encoded.encode('ascii'))
        self._bytes += len(encoded)
        self._rows += 1
        self._points += int(point)
        self._smaps_rows += int(include_smaps)
        if self._first_ns is None:
            self._first_ns = started
        if self._last_ns is not None:
            self._max_status_gap_ns = max(self._max_status_gap_ns, started - self._last_ns)
        self._last_ns = started
        if include_smaps:
            self._last_smaps_ns = smaps_started
        return row

    def _run(self):
        deadline = self._first_ns + STATUS_INTERVAL_NS
        try:
            while not self._stop.wait(max(0, deadline - time.monotonic_ns()) / 1e9):
                with self._lock:
                    if self._stop.is_set():
                        break
                    self._sample('periodic', {},
                                 time.monotonic_ns() - self._last_smaps_ns >= SMAPS_INTERVAL_NS,
                                 False)
                    # Preserve actual timing and skipped ticks. Never emit fake
                    # catch-up samples when proc reads or endpoints take longer.
                    elapsed_ticks = max(1, (time.monotonic_ns() - deadline)
                                        // STATUS_INTERVAL_NS + 1)
                    self._missed_status_ticks += elapsed_ticks - 1
                    deadline += elapsed_ticks * STATUS_INTERVAL_NS
        except Exception as error:
            with self._lock:
                self._fail(error)

    def point(self, phase, metadata=None):
        bounded = _point_metadata(phase, metadata)
        with self._lock:
            self.check()
            if self._state != 'running':
                raise SamplerError('Sampler is not running')
            try:
                return self._sample(phase, bounded, True, True)
            except Exception as error:
                self._fail(error)
                self.check()

    def _close(self):
        try:
            if self._output is not None:
                self._output.close()
                self._output = None
        finally:
            if self._process is not None:
                self._process.close()
                self._process = None

    @property
    def manifest(self):
        with self._lock:
            return {
                'schema': 'abc.memory-probe-control-os-manifest.v1',
                'status': self._state, 'file': self.output_file.name,
                'sha256': self._sha256.hexdigest(), 'bytes': self._bytes,
                'integrityScope': 'successfully-flushed-rows',
                'complete': self._state == 'completed',
                'processIdentity': dict(self._identity) if self._identity else None,
                'clockDomain': CLOCK_DOMAIN, 'timeUnit': 'nanoseconds',
                'crossClockSubtractionAllowed': False,
                'targetStatusIntervalNs': STATUS_INTERVAL_NS,
                'targetSmapsIntervalNs': SMAPS_INTERVAL_NS,
                'statusSamples': self._rows, 'smapsSamples': self._smaps_rows,
                'namedPointSamples': self._points,
                'firstTimeNs': self._first_ns, 'lastTimeNs': self._last_ns,
                'maximumObservedStatusGapNs': self._max_status_gap_ns,
                'missedPeriodicStatusTicks': self._missed_status_ticks,
                'failure': (str(self._failure).replace(str(self.output_file),
                                                     self.output_file.name)[:512]
                            if self._failure else None),
            }

    def finish(self):
        self._stop.set()
        if self._thread is not None and self._thread.ident is not None:
            self._thread.join(timeout=5)
            if self._thread.is_alive():
                # Do not close descriptors out from under an active proc read.
                error = SamplerError('OS sampling thread did not stop; raw evidence is incomplete')
                self._fail(error)
                raise error
        with self._lock:
            if self._state == 'new':
                raise SamplerError('Sampler was never started')
            try:
                self._close()
            except Exception as error:
                self._fail(error)
            self.check()
            self._state = 'completed'
            return self.manifest
