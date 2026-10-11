"""Independent sampled-q0 binding and supervision; no CLI or process launcher.

The orchestrator owns launch, the original 10ms polling loop, overall budgets,
retained process/module identities, and failure cleanup. These helpers never
run an SDK, application, profiler, symbolizer, or retry a failed/inconclusive cut.
"""
from __future__ import annotations

import ctypes
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
APPLICATION = ROOT / 'tool/perf/gperftools_application'
if not APPLICATION.is_dir():
    APPLICATION = (ROOT.parent / 'gperftools-maps-role-publication-review/snapshot'
                   / 'tool/perf/gperftools_application')
if not APPLICATION.is_dir():
    raise RuntimeError('Reviewed application dependency layout absent')
sys.path.insert(0, str(APPLICATION))
import dependencies  # noqa: E402; frozen shared contract hashes are checked here
from application_contract import (ContractError, MAX_HEAP, MAX_MAPS, MAX_RECEIPT, MAX_SIDECAR,
                                  bounded_bytes, check_sidecar_caps, require)
from bounded_supervision import TargetProcessIdentity
from capture_contract import CLOCK, GaugeTail
from prebuilt_contract import BASE, SDK_COMMIT, SDK_VERSION, absolute_path, sha
import memory_ownership_validate as owners
from sampled_contract import parse_sample_bytes, validate_sampled_bracket

TARGET = 'integration_test/computer_memory_sampled_q0_test.dart'
POLL_SECONDS = .01  # The owning run_command loop already uses this interval.
GAUGE_IDS = owners.gauge_plan()[:7]
SAMPLE_FILES = ('q0.sample.receipt', 'q0.sample.heap',
                'q0.sample.before.maps', 'q0.sample.after.maps')
WIRE_ACK = b'ABC_SAMPLED_ACK_V1 0 0 OK\n'


def integer(value, label, minimum=0):
    require(type(value) is int and minimum <= value < 2**63,
            label + ': missing/invalid integer')
    return value


def _equals(value, expected, label):
    require(isinstance(value, dict), label + ': expected object')
    require(all(key in value and type(value[key]) is type(item) and value[key] == item
                for key, item in expected.items()), label + ': fields differ')


def _span(row, start, end):
    values = [integer(row.get(key), key) for key in (start, end)]
    require(values[0] <= values[1], 'Reversed ' + start + '/' + end)
    return values


def read_sampled_json(path, cap=4 << 20):
    return owners.strict_json(bounded_bytes(path, cap))


def bind_sampled_source(source_bytes, expected_sha256):
    sha(expected_sha256, 64)
    require(type(source_bytes) is bytes and source_bytes and
            hashlib.sha256(source_bytes).hexdigest() == expected_sha256,
            'Sampled integration source differs from sealed bytes')
    require(b'abc.gperftools-sampled-hello.v1' in source_bytes and
            b'abc.gperftools-sampled-q0-control.v1' in source_bytes,
            'Independent sampled integration handshake absent')
    return {'target': TARGET, 'sha256': expected_sha256,
            'bytes': len(source_bytes), 'runtimeEntryExecuted': False}


def _native_common(native, pid):
    _equals(native, dict(schema='abc.gperftools-sampled-runtime.v1', abi=1,
                        mode='sampled', pid=pid, initialized=True,
                        initializationStatus=0, failure=0,
                        estimationOnly=True, transportOnly=True,
                        mapsAccepted=False, fullRunCompleted=False), 'Sampled native metadata')


def validate_sampled_hello(hello, identity, *, head, built_executable,
                           source_binding, helper, allocator, output):
    """Bind the actual sampled hello to retained process/ELF and sealed inputs.

    allocator is the verified provider identity mapping (path/sha256/device/
    inode); helper/output are canonical paths. The original binder hard-codes
    the old target/schema, so only its pure digest/path primitives are reused.
    No converted/fabricated old-schema hello is ever passed to it.
    """
    require(isinstance(identity, TargetProcessIdentity), 'Retained target identity required')
    identity.verify()
    sha(head, 40)
    _equals(hello, dict(schema='abc.gperftools-sampled-hello.v1', arm='probe-only',
                       hostPid=identity.pid, sourceCommit=head, baseProductCommit=BASE),
            'Sampled integration hello identity')
    require(set(hello) == {'schema', 'arm', 'hostPid', 'sourceCommit',
                          'baseProductCommit', 'startedUs', 'sampledStartup'},
            'Unexpected sampled hello fields')
    integer(hello.get('startedUs'), 'hello startedUs')
    _equals(source_binding, dict(target=TARGET, runtimeEntryExecuted=False), 'Sampled source binding')
    integer(source_binding.get('bytes'), 'source bytes', 1)
    sha(source_binding.get('sha256'), 64)
    require(set(built_executable) == {'sha256', 'bytes'}, 'Built target evidence shape')
    sha(built_executable['sha256'], 64)
    integer(built_executable['bytes'], 'built target bytes', 1)
    require({key: identity.evidence[key] for key in ('sha256', 'bytes')} == built_executable,
            'Loaded target differs from built sampled integration ELF')
    require(identity.evidence.get('procFdRetained') is True and
            identity.evidence.get('executableFdRetained') is True,
            'Target identity is not backed by retained descriptors')
    value = hello.get('sampledStartup')
    _equals(value, dict(schema='abc.gperftools-sampled-startup.v1', mode='sampled',
                       arm='probe-only', hostPid=identity.pid), 'Sampled Dart startup')
    for name, path in (('helperPath', helper), ('outputPath', output),
                       ('targetPath', identity.evidence['path']),
                       ('allocatorPath', allocator['path'])):
        require(value.get(name) == absolute_path(str(path)), 'Sampled startup path differs: ' + name)
    init = value.get('initialization')
    _equals(init, dict(statusCode=0, clockDomain=CLOCK,
                      identityVerifiedAtInitialization=True), 'Sampled initializer')
    _span(init, 'startUs', 'endUs')
    require(init['endUs'] <= hello['startedUs'], 'Hello precedes initialization')
    native = init.get('native')
    _native_common(native, identity.pid)
    _equals(native, dict(q0Calls=0, closeCalls=0, closed=False,
                        q0TransportAccepted=False), 'Sampled startup lifetime')
    _equals(native.get('observer'), dict(fdOpened=4, fdCloseAttempts=1,
        fdClosed=1, heldFds=3, cleanupErrno=0, ioErrno=0,
        preallocatedMapsBytes=2 << 20), 'Sampled startup descriptor budget')
    _equals(native.get('sample'), dict(api_calls=0, accepted=0, published=0), 'Sample before release')
    for name, expected in (('target', identity.evidence), ('provider', allocator)):
        _equals(native.get(name), {key: expected[key] for key in ('path', 'sha256', 'device', 'inode')},
                'Native sealed ' + name)
    _equals(native['provider'], dict(publicInstanceAddressChecked=True,
                                    allocationOwnershipChecked=True), 'Provider public identity')
    info = Path(output).lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.geteuid() and
            stat.S_IMODE(info.st_mode) == 0o700 and str(Path(output).resolve()) == str(output),
            'Sampled output must be canonical owned private directory')
    _equals(native.get('output'), dict(path=str(output), device=info.st_dev, inode=info.st_ino),
            'Native sealed output')
    require(bounded_bytes(Path(output) / 'launch.once', 128) ==
            f'ABC_SAMPLED_LAUNCH_ONCE_V1 {identity.pid} sampled-q0\n'.encode(),
            'Sampled launch token is not bound to actual hello PID')
    identity.verify()
    return {'runtimeEntry': {'integrationHandshakeBound': True, 'arm': 'probe-only',
            'hostPid': identity.pid, 'sourceCommit': head, 'target': TARGET,
            'targetSourceSha256': source_binding['sha256'], 'executable': dict(built_executable),
            'originalEightCycleWorkloadCompleted': False}, 'startup': value}


def _rename_noreplace(directory_fd, pending, final):
    # Public libc ABI, Linux-only by the surrounding diagnostic contract.
    library = ctypes.CDLL(None, use_errno=True)
    operation = library.renameat2
    operation.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                          ctypes.c_uint)
    operation.restype = ctypes.c_int
    if operation(directory_fd, os.fsencode(pending), directory_fd, os.fsencode(final), 1):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def _publish_new(directory, name, data):
    """Exclusive pending -> atomic no-replace final, with nlink always one.

    Each owned descriptor closes in finally. Failed pending files remain raw
    evidence. No overwrite, truncation, publication retry or fallback occurs.
    """
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(directory_fd)
        require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
                'Publication directory owner/mode differs')
        pending = name + '.pending'
        fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                     os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory_fd)
        try:
            view = memoryview(data)
            while view:
                count = os.write(fd, view)
                require(count > 0, 'Incomplete sampled publication write')
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        _rename_noreplace(directory_fd, pending, name)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return Path(directory) / name


def publish_sampled_ready(directory, gate, build_sha256):
    sha(build_sha256, 64)
    entry = gate['runtimeEntry']
    _equals(entry, dict(integrationHandshakeBound=True, target=TARGET, arm='probe-only',
                        originalEightCycleWorkloadCompleted=False), 'Sampled ready gate')
    require(str(directory) == gate['startup']['outputPath'], 'READY destination differs from startup')
    value = dict(schema='abc.gperftools-sampled-ready.v1', arm='probe-only',
                 hostPid=entry['hostPid'], sourceCommit=entry['sourceCommit'],
                 baseProductCommit=BASE, buildSha256=build_sha256)
    _publish_new(directory, 'sampled-ready.json',
                 (json.dumps(value, separators=(',', ':')) + '\n').encode())
    return value


def sampled_sidecar_caps(directory):
    result = check_sidecar_caps(directory, max_heaps=2)
    allowed = {name for name in SAMPLE_FILES} | {'q0.sample.ack'}
    allowed |= {name + '.pending' for name in allowed}
    for relative in result['files']:
        name = Path(relative).name
        if ('.heap' in name or '.receipt' in name or '.ack' in name or
                name.startswith(('q0', 'q7'))):
            require(relative == name and name in allowed, 'Extra/old sampled cut artifact')
            size = result['files'][relative]['bytes']
            if '.heap' in name:
                require(size < MAX_HEAP, 'Sampled pending/final heap exceeds original exclusive 1 MiB cap')
            if '.receipt' in name or '.ack' in name:
                require(size <= MAX_RECEIPT, 'Sampled pending/final receipt/ACK exceeds 512 bytes')
        if name.endswith('.maps'):
            require(name in {'startup.maps', 'startup-consistency.maps',
                             'q0.sample.before.maps', 'q0.sample.after.maps'},
                    'Unexpected sampled mapping snapshot')
    require(result['heapCount'] <= 1, 'Only one sampled heap allowed')
    return result


def parse_sampled_receipt(data, pid):
    require(isinstance(data, bytes) and 0 < len(data) <= MAX_RECEIPT,
            'Sampled receipt byte bound')
    match = re.fullmatch(rb'ABC_SAMPLED_RECEIPT_V1 0 0 ([1-9][0-9]*) '
        rb'([0-9]+) ([0-9]+) ([1-9][0-9]*) ([1-9][0-9]*) q0\.sample\.heap\n', data)
    require(match is not None, 'Malformed/extra sampled receipt')
    actual_pid, start, end, before, after = map(int, match.groups())
    require(type(pid) is int and actual_pid == pid, 'Sampled receipt PID differs')
    require(0 < start <= end < 2**63 and end - start < 10_000_000_000 and
            0 < before <= MAX_MAPS and 0 < after <= MAX_MAPS, 'Sampled receipt timing/size bounds')
    return dict(slot=0, cycle=0, pid=pid, apiStartNs=start, apiEndNs=end,
                beforeSize=before, afterSize=after, heap='q0.sample.heap')


def validate_sampled_cut(directory, pid):
    directory = Path(directory)
    sampled_sidecar_caps(directory)
    # Native publishes receipt only after complete raw heap and both maps were
    # flushed. Read complete retained files before parsing; never overwrite them.
    payloads = {name: bounded_bytes(directory / name,
                MAX_RECEIPT if name.endswith('.receipt') else MAX_HEAP if name.endswith('.heap')
                else MAX_MAPS, exclusive=name.endswith('.heap')) for name in SAMPLE_FILES}
    receipt = parse_sampled_receipt(payloads[SAMPLE_FILES[0]], pid)
    require(len(payloads[SAMPLE_FILES[2]]) == receipt['beforeSize'] and
            len(payloads[SAMPLE_FILES[3]]) == receipt['afterSize'], 'Sampled receipt/maps length mismatch')
    sample = parse_sample_bytes(payloads[SAMPLE_FILES[1]])
    mapping = validate_sampled_bracket(sample, directory / SAMPLE_FILES[2],
                                       directory / SAMPLE_FILES[3])
    require(mapping['bracket']['beforeSha256'] == hashlib.sha256(payloads[SAMPLE_FILES[2]]).hexdigest()
            and mapping['bracket']['afterSha256'] == hashlib.sha256(payloads[SAMPLE_FILES[3]]).hexdigest(),
            'Retained raw maps changed during parsing')
    return {'receipt': receipt, 'sample': sample, 'bracket': mapping['bracket'],
            'rawRetainedBeforeParse': True, 'directory': str(directory),
            'raw': {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                    for name, data in payloads.items()}}


class SampledCutWatcher:
    """Call check from existing 10ms loop; no background reader or new sample."""
    def __init__(self, directory, gauges, identity, modules):
        require(isinstance(gauges, GaugeTail), 'Original flushed-gauge tail required')
        require(isinstance(identity, TargetProcessIdentity), 'Retained target identity required')
        self.directory, self.gauges = Path(directory), gauges
        self.identity, self.modules = identity, modules
        self.cuts, self.records = [], []
        self.attempted, self.failed = False, False

    def deadline(self):
        gauge = self.gauges.cuts.get('q0')
        return gauge['observed'] + 10 if gauge is not None and not self.cuts else float('inf')

    def check(self):
        require(not self.failed, 'Failed sampled cut is consumed; no retry')
        try:
            sampled_sidecar_caps(self.directory)
            self.gauges.read_new()
            require(self.gauges.sequence <= 7 and set(self.gauges.cuts) <= {'q0'},
                    'Additional gauge/cut beyond sampled q0')
            gauge = self.gauges.cuts.get('q0')
            if gauge is not None:
                require(gauge['row']['sequence'] == 6 and self.gauges.sequence == 7,
                        'q0 is not the seventh original gauge')
            if self.cuts:
                return
            if gauge is not None:
                require(time.monotonic() < gauge['observed'] + 10,
                        'Observed original q0 hook exceeded 10 seconds')
            path = self.directory / 'q0.sample.receipt'
            if path.exists():
                require(gauge is not None and not self.attempted,
                        'Sampled receipt before gauge or duplicate attempt')
                self.attempted = True
                seen = time.monotonic()
                self.identity.verify()
                cut = validate_sampled_cut(self.directory, self.identity.pid)
                receipt = cut['receipt']
                require(0 <= seen - receipt['apiEndNs'] / 1e9 < 2,
                        'Sample receipt outside original Python ACK deadline')
                # Existing metadata/PC binding only. No full symbolization,
                # module hashing, copies, extra maps read or allocations in target.
                self.modules.verify_cut(cut['bracket'])
                now = time.monotonic()
                require(gauge['observed'] <= seen <= now < receipt['apiEndNs'] / 1e9 + 2
                        and now < gauge['observed'] + 10, 'Sample ACK verification deadline')
                _publish_new(self.directory, 'q0.sample.ack', WIRE_ACK)
                ended = time.monotonic()
                require(ended < receipt['apiEndNs'] / 1e9 + 2 and ended < gauge['observed'] + 10,
                        'Sample ACK publication exceeded deadline')
                self.cuts.append(cut)
                self.records.append({'cut': 'q0', 'gaugeObservedMonotonic': gauge['observed'],
                    'receiptSeenMonotonic': seen, 'ackPublishedMonotonic': ended,
                    'receipt': receipt, 'mappingEvidence': {key: cut['bracket'][key] for key in
                        ('mappingRoles', 'mapDifferences', 'beforeSha256', 'afterSha256')}})
        except BaseException:
            self.failed = True
            raise


def _raw_rows(root, descriptor, expected_file, count):
    _equals(descriptor, dict(file=expected_file, sampleCount=count), 'Raw descriptor')
    data = bounded_bytes(Path(root) / expected_file, 4 << 20)
    require(data.endswith(b'\n') and descriptor.get('bytes') == len(data) and
            descriptor.get('sha256') == hashlib.sha256(data).hexdigest(), 'Raw descriptor digest/size mismatch')
    raw = data.splitlines(keepends=True)
    require(len(raw) == count and all(len(line) < 65536 for line in raw), 'Raw row count/line cap')
    return [owners.strict_json(line) for line in raw], raw


def validate_sampled_finish(report, probe, startup, cuts, *, expected_head,
                            schedule_sha256, raw_directory):
    """Validate a truncated sampled control without invoking full-arm acceptance."""
    sha(expected_head, 40)
    require(schedule_sha256 == owners.SCHEDULE_SHA256, 'Original fixed schedule SHA differs')
    _equals(report, dict(schema='abc.gperftools-sampled-q0-control.v1',
        workloadId='abc.original-probe-only-to-q0', status='sampled-q0-captured',
        arm='probe-only', hostPid=startup['hostPid'], baseProductCommit=BASE,
        buildMode='profile', inputFormat='none', mode='sampled-q0-feasibility',
        stopBoundary='cycle-0.released-quiet-end', plannedCycles=0, completedCycles=0,
        originalEightCycleWorkloadCompleted=False, mappingAcceptanceEstablished=False,
        fullHeapCoverage=False, productOperations=0, ticksPerCycle=0,
        excludedWarmupCycles=0, plannedCheckpoints=2, vmProbeCalls=2,
        plannedOwnershipGauges=7, expectedNativeWorkers=0,
        inProcessOsSamplerRetained=True, externalOsSamplerEnabled=False,
        fixture=None, failure=None, failureStack=None, scheduleSha256=schedule_sha256),
        'Sampled q0 report scope/completion')
    _equals(report.get('runtime'), dict(commit=expected_head, checkedOutHead=expected_head,
        workingTreeDirty=False, flutterVersion=SDK_VERSION, flutterRevisionPin=SDK_COMMIT),
        'Sampled runtime/source identity')
    _equals(probe, dict(schema='abc.gperftools-sampled-dart-q0.v1', mode='sampled',
        arm='probe-only', hostPid=startup['hostPid'], status='sampled-q0-captured',
        closeStatusCode=0, dartClockDomain=CLOCK, nativeClockDomain='CLOCK_MONOTONIC nanoseconds',
        clockDomainsComparable=False, q0Attempted=True, originalEightCycleWorkloadCompleted=False,
        mappingAcceptanceEstablished=False, fullHeapCoverage=False, transportOnly=True), 'Sampled Dart finish')
    require(probe.get('startup') == startup and report.get('sampledProbe') == probe,
            'Startup/Dart/main report binding differs')
    native = probe.get('native')
    _native_common(native, startup['hostPid'])
    _equals(native, dict(q0Calls=1, closeCalls=1, closed=True, q0TransportAccepted=True), 'Sampled final lifetime')
    for name in ('provider', 'target', 'output'):
        for key in ('path', 'sha256', 'device', 'inode') if name != 'output' else ('path', 'device', 'inode'):
            require(native[name][key] == startup['initialization']['native'][name][key],
                    'Final native identity changed: ' + name)
    _equals(native['provider'], dict(publicInstanceAddressChecked=True,
                                    allocationOwnershipChecked=True), 'Final provider identity checks')
    observer = native.get('observer')
    _equals(observer, dict(heldFds=0, cleanupErrno=0, ioErrno=0,
                           preallocatedMapsBytes=2 << 20), 'Sampled final cleanup')
    opened = integer(observer.get('fdOpened'), 'observer opened', 4)
    require(integer(observer.get('fdCloseAttempts'), 'observer closes') == opened ==
            integer(observer.get('fdClosed'), 'observer closed'), 'Sampled owned descriptor cleanup incomplete')
    sample = native.get('sample')
    _equals(sample, dict(abi=1, status=0, accepted=1, api_calls=1, provider_checks=2,
        output_opened=1, output_close_attempts=1, output_closed=1, cleanup_errno=0,
        io_errno=0, published=1, api_returned=1), 'Sampled transport completion')
    require(len(cuts) == 1 and cuts[0].get('rawRetainedBeforeParse') is True,
            'Exactly one independently verified retained q0 required')
    evidence, cut, dart = cuts[0], native.get('cut'), probe.get('dartCut')
    receipt = evidence['receipt']
    for name, descriptor in evidence['raw'].items():
        data = bounded_bytes(Path(evidence['directory']) / name,
            MAX_RECEIPT if name.endswith('.receipt') else MAX_HEAP if name.endswith('.heap') else MAX_MAPS,
            exclusive=name.endswith('.heap'))
        require(len(data) == descriptor['bytes'] and hashlib.sha256(data).hexdigest() == descriptor['sha256'],
                'Raw sampled evidence changed after ACK')
    require(bounded_bytes(Path(evidence['directory']) / 'q0.sample.ack', MAX_RECEIPT) == WIRE_ACK,
            'Sampled ACK missing/changed')
    _equals(cut, dict(beforeComplete=True, afterComplete=True, receiptPublished=True,
                     ackAccepted=True), 'Native map/ACK completion')
    _equals(dart, dict(cycle=0, statusCode=0), 'Dart q0 cut')
    native_times = [integer(cut.get('enterNs'), 'native enter', 1)]
    native_times += [integer(sample.get(k), k, 1) for k in
                     ('hook_start_ns', 'api_start_ns', 'api_end_ns', 'hook_end_ns')]
    native_times += [integer(cut.get(k), k, 1) for k in ('ackEndNs', 'exitNs')]
    require(native_times == sorted(native_times) and native_times[-1] - native_times[0] < 10_000_000_000
            and cut['ackEndNs'] - sample['api_end_ns'] < 2_000_000_000,
            'Sampled native hook/ACK duration invalid')
    require(sample['api_start_ns'] == receipt['apiStartNs'] and sample['api_end_ns'] == receipt['apiEndNs']
            and sample['api_elapsed_ns'] == sample['api_end_ns'] - sample['api_start_ns']
            and cut['beforeBytes'] == receipt['beforeSize'] and cut['afterBytes'] == receipt['afterSize'],
            'Sampled native/receipt timing or maps differ')
    size = evidence['raw']['q0.sample.heap']['bytes']
    require(sample['returned_bytes'] == sample['written_bytes'] == size and
            integer(sample.get('returned_capacity_bytes'), 'sample string capacity') >= size,
            'Sampled returned/written raw sizes differ')
    _span(dart, 'enterUs', 'exitUs')
    _span(probe, 'closeStartUs', 'closeEndUs')
    require(dart['exitUs'] <= probe['closeStartUs'], 'Dart close preceded q0 return')
    gauges, encoded = _raw_rows(raw_directory, report['raw']['ownershipGauges'], 'ownership-gauges.jsonl', 7)
    require(gauges == report.get('ownershipGauges') and
            [(row['id'], row['cycle'], row['phase']) for row in gauges] == GAUGE_IDS,
            'Sampled report/raw original gauge prefix differs')
    ready = read_sampled_json(Path(startup['outputPath']) / 'sampled-ready.json', 4096)
    _equals(ready, dict(schema='abc.gperftools-sampled-ready.v1', arm='probe-only',
                        hostPid=startup['hostPid'], sourceCommit=expected_head,
                        baseProductCommit=BASE), 'Published sampled READY')
    require(set(ready) == {'schema', 'arm', 'hostPid', 'sourceCommit', 'baseProductCommit', 'buildSha256'},
            'Published READY shape differs')
    sha(ready.get('buildSha256'), 64)
    ready_gate = report.get('startupIdentityGate')
    require(isinstance(ready_gate, dict) and set(ready_gate) == set(ready) | {'readyReceivedUs'} and
            {key: ready_gate[key] for key in ready} == ready, 'Dart READY differs from published identity gate')
    require(startup['initialization']['endUs'] <= integer(ready_gate.get('readyReceivedUs'), 'READY received')
            <= gauges[0]['startUs'], 'Measurement preceded verified READY')
    writes = report.get('ownershipGaugeWrites')
    require(isinstance(writes, list) and len(writes) == 7, 'Seven gauge write receipts required')
    previous_images, previous_end = None, -1
    for index, (row, written, raw) in enumerate(zip(gauges, writes, encoded)):
        owners.exact_keys(row, {'id', 'sequence', 'cycle', 'phase', 'startUs', 'mainStartUs', 'mainEndUs',
            'endUs', 'captureEndUs', 'serializedAfterUs', 'images', 'imageCache', 'wrapper',
            'worker', 'fd', 'allocator', 'atomic'}, 'Sampled original gauge')
        _equals(row, dict(sequence=index, atomic=False), 'Gauge sequence/atomicity')
        require(not row.get('partial') and not row.get('abortedBeforeVm'), 'Partial gauge cannot pass')
        start, end = _span(row, 'startUs', 'endUs')
        main_start, main_end = _span(row, 'mainStartUs', 'mainEndUs')
        capture = integer(row.get('captureEndUs'), 'capture end')
        require(previous_end <= start <= main_start <= main_end <= capture <=
                integer(row.get('serializedAfterUs'), 'serialization') <= end, 'Gauge ordering differs')
        previous_end = capture
        owners.validate_images(row['images'], previous_images)
        previous_images = row['images']
        owners.exact_keys(row['imageCache'], {'currentSize', 'currentSizeBytes', 'liveImageCount',
                                           'pendingImageCount'}, 'Sampled image cache')
        for name, value in row['imageCache'].items():
            integer(value, 'image cache ' + name)
        owners.validate_wrapper(row['wrapper'])
        require(row['wrapper']['present'] is False, 'Sampled control retained product wrapper')
        require(owners.validate_fd(row['fd'], startup['hostPid']) is False, 'FD observation unavailable')
        owners.validate_allocator(row['allocator'], index)  # Unsupported stays explicit, never replaced with zero.
        worker = row.get('worker')
        owners.exact_keys(worker, {'status', 'workerGeneration', 'requestUs', 'ackUs',
                                  'productionPendingBefore', 'productionPendingAfter', 'owner'},
                          'Sampled original worker')
        _equals(worker, dict(status='worker-not-started', workerGeneration=None, owner=None,
                              productionPendingBefore=0, productionPendingAfter=0), 'Sampled worker topology')
        _span(worker, 'requestUs', 'ackUs')
        require(start <= worker['requestUs'] <= worker['ackUs'] <= main_start <= main_end <=
                row['fd']['startUs'] <= row['fd']['endUs'] <= capture, 'Worker/main/FD order differs')
        _equals(written, dict(id=row['id'], sequence=index, bytes=len(raw), status='written'), 'Gauge write receipt')
        _span(written, 'startUs', 'endUs')
        require(end <= written['startUs'], 'Gauge write preceded serialization')
    require(gauges[-1]['endUs'] <= writes[-1]['endUs'] <=
            integer(cut.get('gaugeDartUs'), 'native gauge stamp') == integer(dart.get('gaugeDartUs'), 'Dart gauge stamp')
            <= dart['enterUs'], 'Sample was not after original completed q0 gauge')
    _validate_original_prefix(report, gauges, raw_directory)
    return {'schema': 'abc.gperftools-sampled-q0-validation.v1', 'status': 'sampled-q0-validated',
            'sampledQ0ControlComplete': True, 'originalEightCycleWorkloadCompleted': False,
            'mappingAcceptanceEstablished': False, 'fullHeapCoverage': False,
            'vmProbeCalls': 2, 'ownershipGaugeCount': 7, 'completedCycles': 0,
            'automaticRetryAllowed': False}


def _validate_original_prefix(report, gauges, raw_directory):
    points = report.get('memoryPoints')
    require(isinstance(points, list) and len(points) == 2 and
            [(row['cycle'], row['phase']) for row in points] == [(-1, 'baseline'), (0, 'after-close-retained')],
            'Exactly original two VM points before q0 required')
    for point, indexes in zip(points, ((1, 2), (4, 5))):
        before, after = (gauges[i] for i in indexes)
        require(point.get('gaugeBeforeId') == before['id'] and point.get('gaugeAfterId') == after['id']
                and point.get('wrapperLatestRetained') is False and point.get('atomic') is False,
                'VM point gauge/lifecycle binding differs')
        _span(point, 'vmStartUs', 'vmEndUs')
        require(before['allocator']['endUs'] <= point['vmStartUs'] <= point['vmEndUs'] <= after['startUs'],
                'Original VM slot/allocator bracket differs')
        vm = point.get('vm')
        _equals(vm, dict(gc='requested-all-isolate-groups',
                         heapMeasurementMethod=owners.original.HEAP_METHOD), 'Original VM observation')
        require(vm.get('heapUnavailable') is None, 'Original VM observation unavailable')
        for field in owners.original.VM_FIELDS:
            integer(vm.get(field), field, 1 if field in ('rssBytes', 'maxRssBytes', 'heapUsedBytes',
                'heapCapacityBytes', 'sampledIsolates', 'sampledIsolateGroups') else 0)
        owners.validate_telemetry(point)
    require(report.get('cycles') == [dict(cycle=0, mode='standard', scenario='no-world-no-edit',
        status='stopped-at-q0', productOperations=0)], 'Original cycle must remain incomplete at q0')
    schedule = owners.load_json(Path(owners.__file__).with_name('memory_ownership_schedule.json'))
    require(hashlib.sha256(Path(owners.__file__).with_name('memory_ownership_schedule.json').read_bytes()).hexdigest()
            == owners.SCHEDULE_SHA256, 'Installed original schedule bytes changed')
    phase_point = lambda cycle, phase: next(row for row in schedule['points']
                                            if row['cycle'] == cycle and row['phase'] == phase)
    quiet = lambda phase: next(row for row in schedule['quietWindows']
                               if row['cycle'] == 0 and row['phase'] == phase)
    cycle = schedule['cycles'][0]
    expected = [(-1, 'baseline', phase_point(-1, 'baseline')['offsetUs']),
                (0, 'cycle-start', cycle['startOffsetUs']),
                (0, 'idle-workload-slot-end', cycle['workloadEndOffsetUs']),
                (0, 'retained-quiet-start', quiet('retained')['startOffsetUs']),
                (0, 'after-close-retained', phase_point(0, 'after-close-retained')['offsetUs']),
                (0, 'released-quiet-start', quiet('released')['startOffsetUs'])]
    waits = report.get('scheduleObservations')
    require(isinstance(waits, list) and len(waits) == 6 and
            [(row['cycle'], row['phase'], row['plannedOffsetUs']) for row in waits] == expected,
            'Original six scheduled waits before q0 differ')
    previous = -1
    for row in waits:
        actual = integer(row.get('actualOffsetUs'), 'actual schedule offset')
        require(actual >= previous and row.get('lateUs') == max(0, actual - row['plannedOffsetUs']),
                'Schedule lateness/order differs')
        previous = actual
    origin = integer(report.get('scheduleOriginUs'), 'schedule origin')
    require(gauges[0]['endUs'] <= origin, 'Initialization not separated from baseline')
    boundaries = report['raw'].get('boundaries')
    phases = ['cycle-start', 'cycle-disposed', 'drain-start', 'drain-end',
              'retained-point', 'released-prefix', 'drain-start', 'drain-end']
    require(isinstance(boundaries, list) and [(row['cycle'], row['phase']) for row in boundaries] ==
            [(0, phase) for phase in phases], 'Original q0 boundary prefix differs')
    previous = -1
    for boundary in boundaries:
        current = integer(boundary.get('timeUs'), 'boundary time')
        require(current >= previous, 'Boundary time reversed')
        previous = current
    for begin, end, gauge in ((2, 3, gauges[3]), (6, 7, gauges[6])):
        require(boundaries[end]['timeUs'] - boundaries[begin]['timeUs'] >= 1200000 and
                boundaries[end]['timeUs'] <= gauge['startUs'], 'Original quiet drain shortened/moved')
    require(integer(report['raw'].get('recordingStoppedUs'), 'recording stopped') >= gauges[-1]['endUs'] >= previous,
            'Original recorder stopped before q0 boundary')
    summary = report.get('imageObserverSummary')
    _equals(summary, dict(restorationComplete=True, priorCallbackFailures=0,
                          callbacksIntact=True, everReplaced=False), 'Image observer cleanup')
    rows, _ = _raw_rows(raw_directory, report['raw']['allocatorCaptures'], 'allocator-captures.jsonl', 7)
    for index, (raw, gauge) in enumerate(zip(rows, gauges)):
        _equals(raw, dict(sequence=index, rawWordEncoding='unsigned-decimal-string'), 'Allocator raw identity')
        require(raw.get('startUs') == gauge['allocator']['startUs'] and
                raw.get('endUs') == gauge['allocator']['endUs'], 'Allocator raw timing differs')
        words = raw.get('rawWords')
        require(isinstance(words, list) and len(words) == 16 and all(isinstance(word, str)
            and re.fullmatch(r'0|[1-9][0-9]{0,19}', word) and int(word) < 2**64 for word in words),
            'Allocator raw unsigned word shape differs')
        values = list(map(int, words))
        require(type(raw.get('statusCode')) is int and raw['statusCode'] in range(5) and
                values[:2] == [1, raw['statusCode']], 'Allocator raw status/ABI differs')
        allocator = gauge['allocator']
        require(values[2] == allocator['sizeTBytes'] and
                values[3] == (allocator['mallinfo2StructBytes'] or 0), 'Allocator raw ABI layout differs')
        expected_reason = [None, 'unsupported-build-headers', 'runtime-mallinfo2-unavailable',
                           'allocator-symbols-interposed', 'libc-symbol-identity-unverified'][raw['statusCode']]
        require(allocator['reason'] == expected_reason, 'Allocator raw unavailability reason differs')
        if raw['statusCode'] == 0:
            require(gauge['allocator']['status'] == 'available' and
                    values[6:] == [gauge['allocator']['fields'][key] for key in owners.MALLINFO_FIELDS],
                    'Allocator raw fields differ from gauge')
        else:
            require(gauge['allocator']['status'] == 'unsupported' and values[6:] == [2**64 - 1] * 10,
                    'Unsupported allocator values fabricated')
    _validate_original_os_prefix(report, raw_directory)


def _validate_original_os_prefix(report, raw_directory):
    """Stream the one unchanged OS journal through its existing row validator."""
    os_report = report['raw'].get('os')
    _equals(os_report, dict(hostPid=report['hostPid'], error=None), 'Original OS journal completion')
    files = os_report.get('files')
    require(isinstance(files, list) and len(files) == 1, 'Sampled q0 must stop before any OS rotation')
    descriptor = files[0]
    require(descriptor.get('file') == 'os-0.jsonl', 'Original OS journal filename differs')
    count = integer(descriptor.get('sampleCount'), 'OS raw row count', 1)
    state = SimpleNamespace(report=report, os_count=0, last_os_time=-1, os_smaps=0,
        os_phases=Counter(), os_periodic=0, os_maxima={}, os_selected={},
        referenced_os={point[key]['sequence'] for point in report['memoryPoints'] for key in ('osBefore', 'osAfter')})
    path = Path(raw_directory) / 'os-0.jsonl'
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    hasher, total = hashlib.sha256(), 0
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= MAX_SIDECAR,
                'Original OS raw file type/aggregate cap')
        while True:
            line = stream.readline(65537)
            if not line:
                break
            require(len(line) < 65536 and line.endswith(b'\n'), 'Original OS raw line cap/truncation')
            total += len(line)
            require(total <= MAX_SIDECAR, 'Original OS raw aggregate cap exceeded')
            hasher.update(line)
            row = owners.strict_json(line)
            owners.original.Validator.validate_os_row(state, row)
        after = os.fstat(stream.fileno())
    identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    require(identity(before) == identity(after) and total == after.st_size == descriptor.get('bytes')
            and hasher.hexdigest() == descriptor.get('sha256'), 'Original OS raw identity/digest changed')
    expected = Counter({'baseline.before-gc': 1, 'baseline.after-gc': 1,
                        'after-close-retained.before-gc': 1, 'after-close-retained.after-gc': 1,
                        'recording-stopped': 1})
    require(state.os_count == count == os_report.get('sampleCount') and state.os_periodic > 0 and
            state.os_smaps >= 5 and Counter({key: val for key, val in state.os_phases.items()
                                           if key != 'periodic'}) == expected,
            'Original OS q0 prefix contains missing/extra observations')
    for point in report['memoryPoints']:
        for key, suffix in (('osBefore', 'before-gc'), ('osAfter', 'after-gc')):
            row = point[key]
            require(state.os_selected.get(row['sequence']) == row and row['phase'] == point['phase'] + '.' + suffix,
                    'Original point OS observation differs from retained raw journal')
