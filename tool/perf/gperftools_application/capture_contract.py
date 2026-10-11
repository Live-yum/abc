"""Application startup, gauge-triggered hook deadlines, and completion binding."""
from __future__ import annotations
import json
import os
from pathlib import Path
import stat
import time

from application_contract import (CUTS, MAX_LINE, MAX_SIDECAR, acknowledge,
    bounded_bytes, check_sidecar_caps, require, validate_cut)
from application_process import read_json

CLOCK = 'dart:developer.Timeline.now'


def validate_startup(hello, *, arm, pid, target, helper, allocator, output):
    value = hello.get('stackAttribution', {})
    require(value.get('schema') == 'abc.gperftools-application-startup.v1'
            and value.get('arm') == arm and value.get('hostPid') == pid,
            'Diagnostic stack startup identity absent')
    for key, expected in (('targetPath', target), ('helperPath', helper),
                          ('allocatorPath', allocator), ('outputPath', output)):
        require(value.get(key) == str(expected), 'Diagnostic startup path differs: ' + key)
    init = value.get('initialization', {})
    require(init.get('statusCode') == 0 and init.get('runningVerifiedAtInitialization') is True
            and init.get('clockDomain') == CLOCK
            and type(init.get('startUs')) is int and type(init.get('endUs')) is int
            and 0 <= init['startUs'] <= init['endUs'], 'Native provider/running initialization failed')
    native = init.get('native', {})
    expected = dict(abi=1, offline=0, initialized=1, failure=0, slotsUsed=0, dumpCount=0,
                    stopCalls=0, stopRequested=0, stopVerified=0, cleanupFailure=0,
                    observerMapsBytes=2 << 20, observerHeldFds=3, observerClosedFds=0,
                    observerFdCloseAttempts=0, observerFdCleanupFailure=0,
                    stopStartNs=0, stopEndNs=0)
    require(all(type(native.get(key)) is int and native[key] == val for key, val in expected.items())
            and type(native.get('observerPreallocatedBytes')) is int
            and native['observerPreallocatedBytes'] >= 2 << 20, 'Native startup metadata differs')
    return value


class GaugeTail:
    """Read only original flushed gauge rows; do not create an observer sample.

    An observed released-quiet gauge arms the independent supervisor's 10s hook
    timeout, including a hung native Dump before a receipt. The native hook also
    checks its exact CLOCK_MONOTONIC interval. Publication/polling latency means
    the external observed-boundary deadline is not a kernel hard timeout.
    """
    def __init__(self, path):
        self.path, self.offset, self.pending = Path(path), 0, b''
        self.identity, self.sequence, self.cuts = None, 0, {}

    def read_new(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        except FileNotFoundError:
            return
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            identity = info.st_dev, info.st_ino
            require(stat.S_ISREG(info.st_mode) and info.st_size <= 4 << 20
                    and self.identity in (None, identity) and info.st_size >= self.offset,
                    'Original gauge journal replaced/truncated/oversized')
            self.identity = identity
            stream.seek(self.offset)
            data = stream.read(1 << 20)
            self.offset += len(data)
        lines = (self.pending + data).split(b'\n')
        self.pending = lines.pop()
        require(len(self.pending) < MAX_LINE, 'Original gauge journal line cap')
        for line in lines:
            require(0 < len(line) < MAX_LINE, 'Original gauge journal line cap')
            row = json.loads(line)
            require(row.get('sequence') == self.sequence and type(row.get('sequence')) is int,
                    'Original gauge sequence differs')
            self.sequence += 1
            require(self.sequence <= 52, 'Additional ownership gauge forbidden')
            for _, cycle, cut, _ in CUTS:
                if row.get('id') == f'cycle-{cycle}.released-quiet-end':
                    require(row.get('cycle') == cycle and row.get('phase') == 'released-quiet-end'
                            and cut not in self.cuts and not row.get('partial'), 'Invalid/duplicate quiet gauge')
                    self.cuts[cut] = {'observed': time.monotonic(), 'row': row}


class CutWatcher:
    def __init__(self, directory, gauges, pid, modules):
        self.directory, self.gauges, self.pid, self.modules = Path(directory), gauges, pid, modules
        self.cuts, self.records = [], []

    def check(self):
        self.gauges.read_new()
        slot = len(self.cuts)
        if slot < 2:
            cut = CUTS[slot][2]
            gauge = self.gauges.cuts.get(cut)
            if gauge is not None:
                require(time.monotonic() - gauge['observed'] < 10, 'Observed original quiet gauge hook exceeded 10 seconds')
            path = self.directory / (cut + '.receipt')
            if path.exists():
                require(gauge is not None, 'Dump receipt before original quiet gauge publication')
                seen = time.monotonic()
                evidence = validate_cut(self.directory, slot=slot, pid=self.pid)
                self.modules.verify_cut(evidence['bracket'])
                receipt = evidence['receipt']
                # Native CLOCK_MONOTONIC is directly comparable with Python's
                # time.monotonic on this fixed Linux host; Dart timestamps are not.
                require(0 <= seen - receipt['dumpEndNs'] / 1e9 < 2,
                        'Receipt discovered after native 2-second ACK window')
                now = time.monotonic()
                require(now < receipt['dumpEndNs'] / 1e9 + 2, 'Integrity check exceeded native ACK deadline')
                acknowledge(self.directory, receipt, hook_started=gauge['observed'], receipt_seen=seen, now=now)
                ended = time.monotonic()
                require(ended < receipt['dumpEndNs'] / 1e9 + 2 and ended - gauge['observed'] < 10,
                        'ACK publication exceeded native/shared deadline')
                self.cuts.append(evidence)
                self.records.append({'cut': cut, 'gaugeObservedMonotonic': gauge['observed'],
                                     'receiptSeenMonotonic': seen, 'ackPublishedMonotonic': ended,
                                     'receipt': receipt,
                                     'mappingEvidence': {key: evidence['bracket'][key] for key in
                                         ('mappingRoles', 'mapDifferences', 'beforeSha256', 'afterSha256')}})
        for index in range(len(self.cuts) + 1, 2):
            require(not (self.directory / (CUTS[index][2] + '.receipt')).exists(), 'Out-of-order dump receipt')

    def deadline(self):
        if len(self.cuts) < 2:
            gauge = self.gauges.cuts.get(CUTS[len(self.cuts)][2])
            if gauge:
                return gauge['observed'] + 10
        return float('inf')


def validate_probe_finish(path, startup, cuts, report):
    value = read_json(path)
    require(value.get('schema') == 'abc.gperftools-dart-probe.v1' and value.get('status') == 'observed'
            and value.get('startup') == startup and value.get('stopStatusCode') == 0
            and value.get('clockDomainsComparable') is False
            and value.get('dartClockDomain') == CLOCK
            and value.get('nativeClockDomain') == 'CLOCK_MONOTONIC nanoseconds', 'Final native Stop/probe evidence failed')
    require(value.get('arm') == startup['arm'] and value.get('hostPid') == startup['hostPid'], 'Final probe identity differs')
    native = value.get('native', {})
    expected = dict(abi=1, offline=0, initialized=1, failure=0, slotsUsed=2, dumpCount=2, stopCalls=1,
                    stopRequested=1, stopVerified=1, cleanupFailure=0, observerMapsBytes=2 << 20,
                    observerHeldFds=0, observerClosedFds=3, observerFdCloseAttempts=3, observerFdCleanupFailure=0)
    require(all(type(native.get(key)) is int and native[key] == val for key, val in expected.items()),
            'Final native dump/Stop/FD-cleanup counters differ')
    require(len(cuts) == len(native.get('cuts', [])) == len(value.get('dartCuts', [])) == 2,
            'Exactly two complete quiet cuts required')
    for index, (_, cycle, _, _) in enumerate(CUTS):
        row, dart = native['cuts'][index], value['dartCuts'][index]
        receipt = cuts[index]['receipt']
        times = [row[key] for key in ('enterNs', 'dumpStartNs', 'dumpEndNs', 'ackEndNs', 'exitNs')]
        require(all(type(t) is int and t > 0 for t in times) and times == sorted(times)
                and times[-1] - times[0] <= 10_000_000_000
                and row['ackEndNs'] - row['dumpEndNs'] <= 2_000_000_000,
                'Native hook/ACK interval invalid')
        require(row['cycle'] == dart['cycle'] == cycle and row['accepted'] == 1 and dart['statusCode'] == 0
                and row['dumpStartNs'] == receipt['dumpStartNs'] and row['dumpEndNs'] == receipt['dumpEndNs']
                and row['mapsBeforeSize'] == receipt['beforeSize'] and row['mapsAfterSize'] == receipt['afterSize'],
                'Native/Dart/receipt cut identity differs')
        gauge = next(gauge for gauge in report['ownershipGauges'] if gauge['id'] == f'cycle-{cycle}.released-quiet-end')
        written = next(item for item in report['ownershipGaugeWrites'] if item['id'] == gauge['id'])
        require(written['status'] == 'written' and gauge['endUs'] <= written['endUs'] <= row['gaugeDartUs'] == dart['gaugeDartUs'] <= dart['enterUs'] <= dart['exitUs'],
                'Dump did not follow original completed quiet gauge')
    require(native['cuts'][-1]['exitNs'] <= native['stopStartNs'] <= native['stopEndNs'], 'Stop precedes endpoint completion')
    require(value['dartCuts'][-1]['exitUs'] <= value['stopStartUs'] <= value['stopEndUs'], 'Dart Stop timing differs')
    return value


def sidecar_caps(roots, *, extra_bytes=0):
    records = [check_sidecar_caps(root) for root in roots if Path(root).exists()]
    require(sum(row['retainedBytes'] for row in records) + extra_bytes <= MAX_SIDECAR,
            'All application sidecars exceed aggregate 256 MiB cap')
    require(sum(row['heapCount'] for row in records) <= 4, 'Unexpected extra application profile')
    maps = [(name, entry['bytes']) for row in records for name, entry in row['files'].items() if name.endswith('.maps')]
    startup = [(name, size) for name, size in maps if Path(name).name in ('startup.maps', 'startup-consistency.maps')]
    endpoints = [(name, size) for name, size in maps if Path(name).name not in ('startup.maps', 'startup-consistency.maps')]
    require(len(startup) <= 4 and len(endpoints) <= 8 and len(maps) <= 12
            and sum(size for _, size in maps) <= 10 << 20,
            'Four startup identity/consistency plus eight endpoint maps cap exceeded')
    return sum(row['retainedBytes'] for row in records)
