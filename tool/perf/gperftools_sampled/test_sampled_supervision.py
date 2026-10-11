"""Offline synthetic contracts only; no target, SDK, allocator or CI is run."""
from __future__ import annotations

import copy
import errno
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import sampled_supervision as supervision
from sampled_supervision import ContractError, GaugeTail, TargetProcessIdentity
import memory_ownership_validate_test as original_fixture
from test_sampled_contract import fixture as sample_fixture, PROC

HERE = Path(__file__).resolve().parent
HEAD = 'a' * 40
PID = 123


def native_fixture(startup=False):
    name = 'sample_runtime_metadata' + ('.startup' if startup else '') + '.example.json'
    result = json.loads((HERE / name).read_bytes())
    result['pid'] = PID
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, separators=(',', ':')) + '\n')


class OfflineSampledSupervision(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='sampled-supervision-offline-')
        self.root = Path(self.tmp.name)
        self.sidecar = self.root / 'sampled'
        self.sidecar.mkdir(mode=0o700)
        self.raw = self.root / 'raw'
        self.clock = 3.005
        self.native = native_fixture(startup=True)
        output_info = self.sidecar.stat()
        self.native['output'] = dict(path=str(self.sidecar), device=output_info.st_dev, inode=output_info.st_ino)
        self.identity = mock.Mock(spec=TargetProcessIdentity)
        self.identity.pid = PID
        self.identity.evidence = dict(self.native['target'], bytes=100,
                                      procFdRetained=True, executableFdRetained=True)
        self.helper = '/offline/sample-runtime.so'
        self.allocator = self.native['provider']
        self.startup = dict(schema='abc.gperftools-sampled-startup.v1', mode='sampled',
            arm='probe-only', hostPid=PID, helperPath=self.helper,
            targetPath=self.native['target']['path'], allocatorPath=self.allocator['path'],
            outputPath=str(self.sidecar), initialization=dict(statusCode=0, startUs=1, endUs=2,
                clockDomain=supervision.CLOCK, identityVerifiedAtInitialization=True, native=self.native))
        self.hello = dict(schema='abc.gperftools-sampled-hello.v1', arm='probe-only', hostPid=PID,
            sourceCommit=HEAD, baseProductCommit=supervision.BASE, startedUs=3, sampledStartup=self.startup)
        (self.sidecar / 'launch.once').write_text(f'ABC_SAMPLED_LAUNCH_ONCE_V1 {PID} sampled-q0\n')
        source = (supervision.ROOT / supervision.TARGET).read_bytes()
        self.binding = supervision.bind_sampled_source(source, hashlib.sha256(source).hexdigest())
        self.built = dict(sha256=self.native['target']['sha256'], bytes=100)

    def tearDown(self):
        self.tmp.cleanup()

    def hello_gate(self):
        return supervision.validate_sampled_hello(self.hello, self.identity, head=HEAD,
            built_executable=self.built, source_binding=self.binding, helper=self.helper,
            allocator=self.allocator, output=self.sidecar)

    def sample_files(self, raw=None):
        data = sample_fixture() if raw is None else raw
        (self.sidecar / 'q0.sample.heap').write_bytes(data)
        (self.sidecar / 'q0.sample.before.maps').write_bytes(PROC)
        (self.sidecar / 'q0.sample.after.maps').write_bytes(PROC)
        (self.sidecar / 'q0.sample.receipt').write_bytes(
            f'ABC_SAMPLED_RECEIPT_V1 0 0 {PID} 3002000000 3003000000 '
            f'{len(PROC)} {len(PROC)} q0.sample.heap\n'.encode())

    def make_watcher(self, rows=None):
        self.raw.mkdir(exist_ok=True)
        gauge_path = self.raw / 'ownership-gauges.jsonl'
        if rows is None:
            rows = [dict(id=name, sequence=i, cycle=cycle, phase=phase)
                    for i, (name, cycle, phase) in enumerate(supervision.GAUGE_IDS)]
        gauge_path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.modules = mock.Mock()
        return supervision.SampledCutWatcher(self.sidecar, GaugeTail(gauge_path), self.identity, self.modules)

    def tick(self, watcher):
        with mock.patch.object(supervision.time, 'monotonic', side_effect=lambda: self.clock):
            watcher.check()

    def test_actual_entrypoint_hello_and_native_startup_fixture_bind(self):
        gate = self.hello_gate()
        self.assertEqual(gate['runtimeEntry']['target'], supervision.TARGET)
        self.assertFalse(gate['runtimeEntry']['originalEightCycleWorkloadCompleted'])
        self.assertEqual(self.identity.verify.call_count, 2)
        entry = (supervision.ROOT / supervision.TARGET).read_text()
        for key in self.hello:
            self.assertIn("'" + key + "'", entry)
        value = supervision.publish_sampled_ready(self.sidecar, gate, 'b' * 64)
        self.assertEqual(len(value), 6)
        self.assertEqual(supervision.read_sampled_json(self.sidecar / 'sampled-ready.json'), value)
        self.assertEqual((self.sidecar / 'sampled-ready.json').stat().st_nlink, 1)

    def test_wrong_schema_pid_source_target_build_and_native_identity_fail(self):
        cases = [lambda: self.hello.update(schema='abc.memory-ownership-hello.v1'),
                 lambda: self.hello.update(hostPid=PID + 1),
                 lambda: self.hello.update(sourceCommit='b' * 40),
                 lambda: self.binding.update(target='lib/main.dart'),
                 lambda: self.built.update(sha256='c' * 64),
                 lambda: self.native['target'].update(inode=999),
                 lambda: self.native.update(q0Calls=1),
                 lambda: self.native['provider'].update(allocationOwnershipChecked=False),
                 lambda: self.native['observer'].update(heldFds=4)]
        for mutate in cases:
            with self.subTest(mutation=mutate):
                old = copy.deepcopy((self.hello, self.binding, self.built))
                mutate()
                with self.assertRaises((ContractError, ValueError)):
                    self.hello_gate()
                self.hello, self.binding, self.built = old
                self.startup = self.hello['sampledStartup']
                self.native = self.startup['initialization']['native']
                self.allocator = self.native['provider']

    def test_launch_token_must_be_sampled_and_match_actual_pid(self):
        for token in (f'ABC_SAMPLED_LAUNCH_ONCE_V1 {PID} probe-only\n',
                      f'ABC_SAMPLED_LAUNCH_ONCE_V1 {PID + 1} sampled-q0\n'):
            (self.sidecar / 'launch.once').write_text(token)
            with self.assertRaises(ContractError):
                self.hello_gate()

    def test_json_rejects_duplicate_keys_and_nonfinite_values(self):
        path = self.root / 'bad.json'
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}'):
            path.write_bytes(raw)
            with self.assertRaises(ValueError):
                supervision.read_sampled_json(path)

    def test_one_q0_validates_retained_maps_pc_and_publishes_exact_ack(self):
        self.sample_files()
        watcher = self.make_watcher()
        self.tick(watcher)
        self.assertEqual(len(watcher.cuts), 1)
        self.assertEqual((self.sidecar / 'q0.sample.ack').read_bytes(), supervision.WIRE_ACK)
        self.assertEqual((self.sidecar / 'q0.sample.ack').stat().st_nlink, 1)
        self.assertFalse((self.sidecar / 'q0.sample.ack.pending').exists())
        self.modules.verify_cut.assert_called_once()
        self.assertTrue(watcher.cuts[0]['rawRetainedBeforeParse'])
        self.tick(watcher)
        self.assertEqual(len(watcher.cuts), 1)
        self.modules.verify_cut.assert_called_once()

    def test_bad_raw_is_preserved_and_cannot_ack_or_retry(self):
        data = sample_fixture() + b'\0'
        self.sample_files(data)
        watcher = self.make_watcher()
        with self.assertRaises(ContractError):
            self.tick(watcher)
        self.assertEqual((self.sidecar / 'q0.sample.heap').read_bytes(), data)
        self.assertTrue(all((self.sidecar / name).exists() for name in supervision.SAMPLE_FILES))
        self.assertFalse((self.sidecar / 'q0.sample.ack').exists())
        (self.sidecar / 'q0.sample.heap').write_bytes(sample_fixture())
        with self.assertRaisesRegex(ContractError, 'no retry'):
            self.tick(watcher)

    def test_wrong_pc_map_bracket_refuses_ack_without_altering_raw(self):
        self.sample_files()
        after = self.sidecar / 'q0.sample.after.maps'
        after.write_bytes(PROC.replace(b'08:01', b'08:02'))
        watcher = self.make_watcher()
        with self.assertRaises(ContractError):
            self.tick(watcher)
        self.assertEqual(after.read_bytes(), PROC.replace(b'08:01', b'08:02'))
        self.assertFalse((self.sidecar / 'q0.sample.ack').exists())

    def test_receipt_before_original_q0_gauge_fails(self):
        self.sample_files()
        watcher = self.make_watcher(rows=[])
        with self.assertRaisesRegex(ContractError, 'before gauge'):
            self.tick(watcher)

    def test_extra_q7_old_full_profile_or_eighth_gauge_fails(self):
        self.sample_files()
        for name in ('q7.sample.receipt', 'heap.0001.heap', 'q0.receipt'):
            extra = self.sidecar / name
            extra.write_text('extra')
            with self.subTest(name=name), self.assertRaises(ContractError):
                self.tick(self.make_watcher())
            extra.unlink()
        rows = [dict(id=name, sequence=i, cycle=cycle, phase=phase)
                for i, (name, cycle, phase) in enumerate(supervision.GAUGE_IDS)]
        rows.append(dict(id='cycle-0.after-close-released.before-gc', sequence=7,
                         cycle=0, phase='after-close-released.before-gc'))
        with self.assertRaisesRegex(ContractError, 'Additional gauge'):
            self.tick(self.make_watcher(rows))

    def test_receipt_pid_cycle_extra_line_size_and_time_rejected(self):
        data = f'ABC_SAMPLED_RECEIPT_V1 0 0 {PID} 3002000000 3003000000 10 10 q0.sample.heap\n'.encode()
        for raw in (data.replace(f' {PID} '.encode(), b' 999 '), data.replace(b' 0 0 ', b' 1 7 '),
                    data + b'\n', data.replace(b' 10 10 ', b' 1048577 10 '),
                    data.replace(b'3003000000', b'3001000000'), data.replace(b'sample.heap', b'heap.0001.heap')):
            with self.subTest(raw=raw), self.assertRaises(ContractError):
                supervision.parse_sampled_receipt(raw, PID)

    def test_observed_gauge_arms_ten_second_timeout_without_receipt(self):
        watcher = self.make_watcher()
        self.tick(watcher)
        self.assertEqual(watcher.deadline(), self.clock + 10)
        self.clock += 10
        with self.assertRaisesRegex(ContractError, '10 seconds'):
            self.tick(watcher)
        self.modules.verify_cut.assert_not_called()

    def test_api_end_two_second_deadline_includes_integrity_and_publication(self):
        self.sample_files()
        watcher = self.make_watcher()
        self.clock = 5.003
        with self.assertRaisesRegex(ContractError, 'ACK deadline'):
            self.tick(watcher)
        self.assertFalse((self.sidecar / 'q0.sample.ack').exists())
        watcher = self.make_watcher()
        self.clock = 3.005
        self.modules.verify_cut.side_effect = lambda _: setattr(self, 'clock', 5.003)
        with self.assertRaisesRegex(ContractError, 'verification deadline'):
            self.tick(watcher)
        self.assertFalse((self.sidecar / 'q0.sample.ack').exists())

    def test_ack_publication_never_overwrites_existing_final(self):
        path = self.sidecar / 'q0.sample.ack'
        path.write_bytes(b'prior\n')
        with self.assertRaises(OSError):
            supervision._publish_new(self.sidecar, path.name, supervision.WIRE_ACK)
        self.assertEqual(path.read_bytes(), b'prior\n')
        self.assertEqual((self.sidecar / 'q0.sample.ack.pending').read_bytes(), supervision.WIRE_ACK)

    def test_pending_artifacts_keep_original_size_caps(self):
        for name, count in (('q0.sample.heap.pending', 1 << 20),
                            ('q0.sample.receipt.pending', 513), ('q0.sample.ack.pending', 513)):
            path = self.sidecar / name
            path.write_bytes(b'x' * count)
            with self.subTest(name=name), self.assertRaises(ContractError):
                supervision.sampled_sidecar_caps(self.sidecar)
            self.assertEqual(path.stat().st_size, count)
            path.unlink()

    def test_module_binding_failure_never_acknowledges_or_retries(self):
        self.sample_files()
        watcher = self.make_watcher()
        self.modules.verify_cut.side_effect = ContractError('synthetic sealed module mismatch')
        with self.assertRaisesRegex(ContractError, 'module mismatch'):
            self.tick(watcher)
        self.assertFalse((self.sidecar / 'q0.sample.ack').exists())
        self.assertTrue(watcher.failed)
        self.modules.verify_cut.side_effect = None
        with self.assertRaisesRegex(ContractError, 'no retry'):
            self.tick(watcher)

    def test_ack_publication_time_is_checked_after_atomic_publish(self):
        self.sample_files()
        watcher = self.make_watcher()
        publish = supervision._publish_new
        def slow_publish(*args):
            result = publish(*args)
            self.clock = 5.003
            return result
        with mock.patch.object(supervision, '_publish_new', side_effect=slow_publish):
            with self.assertRaisesRegex(ContractError, 'publication exceeded'):
                self.tick(watcher)
        self.assertTrue(watcher.failed)
        self.assertEqual(watcher.cuts, [])
        self.assertEqual((self.sidecar / 'q0.sample.ack').read_bytes(), supervision.WIRE_ACK)

    def test_publication_closes_every_owned_fd_on_success_and_failures(self):
        for fault in ('none', 'open', 'write', 'sync', 'rename', 'close'):
            directory = self.root / fault
            directory.mkdir(mode=0o700)
            opened, closed = [], []
            real_open, real_close, real_write, real_sync = os.open, os.close, os.write, os.fsync
            def opening(*args, **kwargs):
                if fault == 'open' and len(opened) == 1:
                    raise OSError(errno.EIO, 'synthetic open failure')
                fd = real_open(*args, **kwargs)
                opened.append(fd)
                return fd
            def closing(fd):
                closed.append(fd)
                result = real_close(fd)
                if fault == 'close' and len(closed) == 1:
                    raise OSError(errno.EINTR, 'synthetic uncertain close result')
                return result
            def writing(*args):
                if fault == 'write':
                    return 0
                return real_write(*args)
            def syncing(fd):
                if fault == 'sync':
                    raise OSError(errno.EIO, 'synthetic sync failure')
                return real_sync(fd)
            original_rename = supervision._rename_noreplace
            def renaming(*args):
                if fault == 'rename':
                    raise OSError(errno.EIO, 'synthetic rename failure')
                return original_rename(*args)
            with self.subTest(fault=fault), mock.patch.object(supervision.os, 'open', side_effect=opening), \
                    mock.patch.object(supervision.os, 'close', side_effect=closing), \
                    mock.patch.object(supervision.os, 'write', side_effect=writing), \
                    mock.patch.object(supervision.os, 'fsync', side_effect=syncing), \
                    mock.patch.object(supervision, '_rename_noreplace', side_effect=renaming):
                if fault == 'none':
                    supervision._publish_new(directory, 'q0.sample.ack', supervision.WIRE_ACK)
                else:
                    with self.assertRaises((ContractError, OSError)):
                        supervision._publish_new(directory, 'q0.sample.ack', supervision.WIRE_ACK)
                self.assertCountEqual(opened, closed)
                self.assertEqual(len(closed), len(set(closed)))

    def finish_fixture(self):
        report, _, _, _ = original_fixture.fixture(self.raw, arm='probe-only')
        report.update(schema='abc.gperftools-sampled-q0-control.v1', workloadId='abc.original-probe-only-to-q0',
            status='sampled-q0-captured', mode='sampled-q0-feasibility',
            stopBoundary='cycle-0.released-quiet-end', plannedCycles=0, completedCycles=0,
            originalEightCycleWorkloadCompleted=False, mappingAcceptanceEstablished=False,
            fullHeapCoverage=False, productOperations=0, plannedCheckpoints=2,
            vmProbeCalls=2, plannedOwnershipGauges=7, failure=None, failureStack=None)
        report['runtime'].update(commit=HEAD, checkedOutHead=HEAD, workingTreeDirty=False,
            flutterVersion=supervision.SDK_VERSION, flutterRevisionPin=supervision.SDK_COMMIT)
        ready = supervision.publish_sampled_ready(self.sidecar, self.hello_gate(), 'b' * 64)
        report['startupIdentityGate'] = {**ready, 'readyReceivedUs': 100}
        report['ownershipGauges'] = report['ownershipGauges'][:7]
        report['ownershipGaugeWrites'] = report['ownershipGaugeWrites'][:7]
        report['memoryPoints'] = report['memoryPoints'][:2]
        report['cycles'] = [dict(cycle=0, mode='standard', scenario='no-world-no-edit',
                                status='stopped-at-q0', productOperations=0)]
        report['scheduleObservations'] = report['scheduleObservations'][:6]
        for wait in report['scheduleObservations']:
            wait['lateUs'] = max(0, wait['lateUs'])
        report['raw']['boundaries'] = report['raw']['boundaries'][:8]
        cutoff = report['ownershipGauges'][-1]['endUs']
        os_rows = [json.loads(line) for line in (self.raw / 'os-0.jsonl').read_bytes().splitlines()]
        os_rows = [row for row in os_rows if row['timeUs'] <= cutoff]
        last_os = next(json.loads(line) for line in (self.raw / 'os-8.jsonl').read_bytes().splitlines()
                       if json.loads(line)['phase'] == 'recording-stopped')
        for index, key in enumerate(('timeUs', 'statusEndUs', 'smapsTimeUs', 'smapsEndUs')):
            last_os[key] = cutoff + 100 + index
        last_os['sequence'] = len(os_rows)
        os_rows.append(last_os)
        report['raw']['os']['files'] = [dict(file='os-0.jsonl', sampleCount=len(os_rows))]
        report['raw']['os']['sampleCount'] = len(os_rows)
        original_fixture.fixture_source.write_rows(self.raw, report['raw']['os']['files'][0], os_rows)
        report['raw']['ownershipGauges']['sampleCount'] = 7
        original_fixture.fixture_source.write_rows(self.raw, report['raw']['ownershipGauges'], report['ownershipGauges'])
        original_fixture.write_allocator_captures(self.raw, report)
        self.sample_files()
        watcher = self.make_watcher(report['ownershipGauges'])
        # make_watcher wrote equivalent pretty JSON; restore original bytes and
        # descriptor equality for the final raw-report integrity contract.
        original_fixture.fixture_source.write_rows(self.raw, report['raw']['ownershipGauges'], report['ownershipGauges'])
        self.tick(watcher)
        native = native_fixture()
        for name in ('provider', 'target', 'output'):
            native[name] = copy.deepcopy(self.native[name])
        native['cut'].update(beforeBytes=len(PROC), afterBytes=len(PROC),
            gaugeDartUs=report['ownershipGaugeWrites'][-1]['endUs'] + 1)
        native['sample'].update(returned_bytes=len(sample_fixture()), written_bytes=len(sample_fixture()),
                                returned_capacity_bytes=len(sample_fixture()))
        dart_enter = native['cut']['gaugeDartUs'] + 1
        probe = dict(schema='abc.gperftools-sampled-dart-q0.v1', mode='sampled', arm='probe-only',
            hostPid=PID, status='sampled-q0-captured', startup=self.startup, closeStatusCode=0,
            closeStartUs=dart_enter + 10, closeEndUs=dart_enter + 11,
            dartClockDomain=supervision.CLOCK, nativeClockDomain='CLOCK_MONOTONIC nanoseconds',
            clockDomainsComparable=False, native=native, q0Attempted=True,
            dartCut=dict(cycle=0, gaugeDartUs=native['cut']['gaugeDartUs'],
                         enterUs=dart_enter, exitUs=dart_enter + 9, statusCode=0),
            originalEightCycleWorkloadCompleted=False, mappingAcceptanceEstablished=False,
            fullHeapCoverage=False, transportOnly=True)
        report['sampledProbe'] = probe
        return report, probe, watcher.cuts

    def finish(self, report, probe, cuts):
        return supervision.validate_sampled_finish(report, probe, self.startup, cuts,
            expected_head=HEAD, schedule_sha256=supervision.owners.SCHEDULE_SHA256, raw_directory=self.raw)

    def test_dart_report_binds_two_vm_seven_gauges_and_zero_completed_cycles(self):
        report, probe, cuts = self.finish_fixture()
        result = self.finish(report, probe, cuts)
        self.assertEqual(result['status'], 'sampled-q0-validated')
        self.assertFalse(result['originalEightCycleWorkloadCompleted'])
        self.assertFalse(result['mappingAcceptanceEstablished'])
        self.assertFalse(result['automaticRetryAllowed'])

    def test_full_workload_claim_wrong_counts_failed_cleanup_or_extra_cut_rejected(self):
        report, probe, cuts = self.finish_fixture()
        mutations = [lambda r, p, c: r.update(originalEightCycleWorkloadCompleted=True),
            lambda r, p, c: r.update(completedCycles=1), lambda r, p, c: r.update(vmProbeCalls=3),
            lambda r, p, c: r['memoryPoints'].append(copy.deepcopy(r['memoryPoints'][-1])),
            lambda r, p, c: p['native']['observer'].update(heldFds=1),
            lambda r, p, c: p['native']['observer'].update(cleanupErrno=5),
            lambda r, p, c: p['native']['sample'].update(cleanup_errno=5),
            lambda r, p, c: p['native'].update(q0Calls=2),
            lambda r, p, c: r['raw']['os']['files'].append(copy.deepcopy(r['raw']['os']['files'][0])),
            lambda r, p, c: r['startupIdentityGate'].update(buildSha256='c' * 64),
            lambda r, p, c: r['startupIdentityGate'].update(readyReceivedUs=10**15),
            lambda r, p, c: c.append(copy.deepcopy(c[0])),
            lambda r, p, c: p['dartCut'].update(cycle=7)]
        for mutation in mutations:
            r, p, c = copy.deepcopy((report, probe, cuts))
            mutation(r, p, c)
            with self.subTest(mutation=mutation), self.assertRaises((ContractError, ValueError)):
                self.finish(r, p, c)

    def test_raw_change_after_ack_is_rejected(self):
        report, probe, cuts = self.finish_fixture()
        raw = self.sidecar / 'q0.sample.heap'
        raw.write_bytes(raw.read_bytes().replace(b'64', b'65'))
        with self.assertRaisesRegex(ContractError, 'changed after ACK'):
            self.finish(report, probe, cuts)


if __name__ == '__main__':
    unittest.main()
