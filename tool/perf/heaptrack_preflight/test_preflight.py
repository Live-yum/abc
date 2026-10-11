"""Offline contract tests. No Heaptrack, SDK, WLD, or network is invoked."""
import copy
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest

from run_preflight import (MAX_COMPRESSED, Runner, check_official_diagnostics,
                           check_trace_caps, deb_fields, validate_policy)
from trace_contract import (ContractError, MAX_RECORD, interpreter_live_blocks,
                            official_integer_total, parse_raw, sized_string, write_prefix)


class RawFixture:
    """Hand-authored event ledger with expected snapshots independent of parser."""
    def __init__(self, directory):
        self.binary = Path(directory) / 'native contract'
        self.binary.write_bytes(b'offline ELF identity placeholder; never executed')
        self.raw = Path(directory) / 'input.raw'
        names = ['abc_fixture_malloc', 'abc_fixture_calloc', 'abc_fixture_grow',
                 'abc_fixture_realloc_failure', 'abc_fixture_realloc_zero',
                 'q0_begin', 'q0_end', 'q7_begin', 'q7_end']
        self.symbols = {name: (0x100 * (i + 1), 0x40) for i, name in enumerate(names)}
        self.fixture = {'markers': []}
        expected = [((0x2000, 101), (0x2100, 219)), ((0x2300, 409), (0x2200, 307)),
                    ((0x2300, 409), (0x2500, 601)), ((0x2700, 809), (0x2600, 749))]
        for i, (marker_id, symbol, size) in enumerate(zip(
                ('q0.begin', 'q0.end', 'q7.begin', 'q7.end'), names[5:], (13, 17, 19, 23))):
            self.fixture['markers'].append({'id': marker_id, 'symbol': symbol, 'pointer': '0x9000',
                'requestedBytes': size, 'expectedLive': [{'pointer': hex(p), 'bytes': n}
                                                       for p, n in expected[i]]})
        exe = str(self.binary.resolve()).encode()
        self.lines = [b'v 10500 3\n', b'x %x %s\n' % (len(exe), exe), b'X offline-fixture\n',
                      b'I 1000 10000\n', b'm 1 -\n', b'm 1 x 100000 0 1000\n']
        self.lines += [b't %x 0\n' % (0x100000 + address + 4) for address, _ in self.symbols.values()]
        self.lines += [b'+ 65 1 2000\n', b'+ db 2 2100\n', b'+ d 6 9000\n', b'- 9000\n',
                       b'+ 133 1 2200\n', b'- 2000\n', b'+ 199 3 2300\n', b'- 2100\n',
                       b'+ 1f7 1 2400\n', b'- 2400\n', b'+ 11 7 9000\n', b'- 9000\n',
                       b'- 2200\n', b'+ 259 1 2500\n', b'+ 13 8 9000\n', b'- 9000\n',
                       b'- 2300\n', b'+ 2ed 2 2600\n', b'- 2500\n', b'+ 329 3 2700\n',
                       b'+ 17 9 9000\n', b'- 9000\n', b'- 2700\n', b'- 2600\n', b'c 1\n', b'R 1\n']
        # Explicit allocation-call oracle, distinct from the raw event stream.
        self.fixture['operations'] = [
            self.alloc('malloc', '0x2000', 101), self.alloc('calloc', '0x2100', 219),
            self.alloc('malloc', '0x9000', 13), self.free('0x9000'),
            self.alloc('malloc', '0x2200', 307), self.realloc('0x2000', '0x2300', 409, True),
            self.free('0x2100'), self.alloc('malloc', '0x2400', 503),
            self.realloc('0x2300', None, 2**64 - 1, False), self.realloc('0x2400', None, 0, True),
            self.alloc('malloc', '0x9000', 17), self.free('0x9000'), self.free('0x2200'),
            self.alloc('malloc', '0x2500', 601), self.alloc('malloc', '0x9000', 19),
            self.free('0x9000'), self.free('0x2300'), self.alloc('calloc', '0x2600', 749),
            self.realloc('0x2500', '0x2700', 809, True), self.alloc('malloc', '0x9000', 23),
            self.free('0x9000'), self.free('0x2700'), self.free('0x2600')]

    @staticmethod
    def alloc(kind, ptr, size):
        return {'kind': kind, 'resultPointer': ptr, 'requestedBytes': size}

    @staticmethod
    def free(ptr):
        return {'kind': 'free', 'oldPointer': ptr}

    @staticmethod
    def realloc(old, result, size, freed):
        return {'kind': 'realloc', 'oldPointer': old, 'resultPointer': result,
                'requestedBytes': size, 'formerAllocationFreed': freed}

    def parse(self, lines=None):
        self.raw.write_bytes(b''.join(self.lines if lines is None else lines))
        return parse_raw(self.raw, self.fixture, self.binary, self.symbols)


class RawTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.f = RawFixture(self.temp.name)

    def test_exact_four_cuts_and_marker_lifetime(self):
        result = self.f.parse()
        self.assertTrue(result['valid'])
        self.assertEqual([r['liveBytes'] for r in result['boundaries']], [320, 716, 1010, 1558])
        self.assertEqual([r['liveBlocks'] for r in result['boundaries']], [2, 2, 2, 2])
        self.assertEqual(result['finalLiveBlocks'], 0)
        self.assertEqual(set(result['markerFrees'].values()), {1})

    def test_realloc_zero_missing_free_is_explicit_failure(self):
        result = self.f.parse([line for line in self.f.lines if line != b'- 2400\n'])
        self.assertFalse(result['valid'])
        self.assertEqual(result['boundaries'][1]['fixtureLiveBytes'], 1219)
        self.assertEqual(result['fixtureLiveAfterCleanup'], {'0x2400': 503})
        self.assertIn('fixture-live-set-mismatch', [row['kind'] for row in result['issues']])

    def test_failed_realloc_must_preserve_existing_block(self):
        lines = list(self.f.lines)
        lines.insert(lines.index(b'+ 11 7 9000\n'), b'- 2300\n')
        result = self.f.parse(lines)
        self.assertFalse(result['valid'])
        self.assertEqual(result['boundaries'][1]['fixtureLiveBytes'], 307)

    def test_missing_transient_allocation_pair_is_not_hidden_by_same_cut_totals(self):
        result = self.f.parse([line for line in self.f.lines
                               if line not in (b'+ 1f7 1 2400\n', b'- 2400\n')])
        self.assertFalse(result['valid'])
        self.assertEqual([r['liveBytes'] for r in result['boundaries']], [320, 716, 1010, 1558])
        self.assertIn('authored-event-sequence-mismatch', [row['kind'] for row in result['issues']])

    def test_marker_identity_requires_symbol_pc(self):
        lines = [b'+ d 1 9000\n' if line == b'+ d 6 9000\n' else line for line in self.f.lines]
        with self.assertRaisesRegex(ContractError, 'order|missing'):
            self.f.parse(lines)

    def test_marker_pointer_mismatch_rejected(self):
        self.f.fixture['markers'][0]['pointer'] = '0x9999'
        with self.assertRaisesRegex(ContractError, 'pointer/size'):
            self.f.parse()

    def test_duplicate_live_pointer_rejected(self):
        lines = list(self.f.lines)
        lines.insert(lines.index(b'+ d 6 9000\n'), b'+ 65 1 2000\n')
        with self.assertRaisesRegex(ContractError, 'Duplicate live pointer'):
            self.f.parse(lines)

    def test_missing_marker_free_rejected(self):
        lines = list(self.f.lines)
        index = len(lines) - 1 - lines[::-1].index(b'- 9000\n')
        del lines[index]
        with self.assertRaisesRegex(ContractError, 'lifetime'):
            self.f.parse(lines)

    def test_unknown_frees_are_counted_without_fake_allocations(self):
        lines = list(self.f.lines)
        lines.insert(-2, b'- ffff\n')
        result = self.f.parse(lines)
        self.assertTrue(result['valid'])
        self.assertEqual(result['unknownFrees'], 1)

    def test_exact_prefix_stops_before_marker_event(self):
        result = self.f.parse()
        boundary = result['boundaries'][0]
        prefix = Path(self.temp.name) / 'prefix.raw'
        identity = write_prefix(self.f.raw, boundary, prefix)
        self.assertEqual(identity['bytes'], boundary['byteOffset'])
        self.assertTrue(prefix.read_bytes().endswith(b'+ db 2 2100\n'))
        self.assertNotIn(b'+ d 6 9000\n', prefix.read_bytes())

    def test_truncated_final_record_rejected(self):
        with self.assertRaisesRegex(ContractError, 'truncated'):
            self.f.parse(self.f.lines[:-1] + [b'R 1'])

    def test_missing_shutdown_tail_rejected(self):
        with self.assertRaisesRegex(ContractError, 'shutdown tail'):
            self.f.parse(self.f.lines[:-1])

    def test_bad_version_and_unknown_mode_rejected(self):
        with self.assertRaisesRegex(ContractError, 'version/file format'):
            self.f.parse([b'v 10400 3\n'] + self.f.lines[1:])
        with self.assertRaisesRegex(ContractError, 'Unsupported raw'):
            self.f.parse(self.f.lines[:-2] + [b'A attached\n'] + self.f.lines[-2:])

    def test_cyclic_or_future_trace_rejected(self):
        lines = [b't 100104 1\n' if line == b't 100104 0\n' else line for line in self.f.lines]
        with self.assertRaisesRegex(ContractError, 'parent/IP'):
            self.f.parse(lines)

    def test_oversized_record_rejected(self):
        with self.assertRaisesRegex(ContractError, 'oversized'):
            self.f.parse(self.f.lines + [b'#' + b'x' * MAX_RECORD + b'\n'])

    def test_sized_strings_support_spaces_and_reject_truncation(self):
        self.assertEqual(sized_string(b'3 a b ff'), ('a b', b'ff'))
        with self.assertRaisesRegex(ContractError, 'Truncated'):
            sized_string(b'4 abc')


class OfficialExportTests(unittest.TestCase):
    def test_integer_export_does_not_round_or_drop_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stacks.txt'
            path.write_text('main;allocation; 1048577\n?? 503\nzero; 0\n')
            self.assertEqual(official_integer_total(path)['liveBytes'], 1049080)
            path.write_text('main;allocation; 1.05MB\n')
            with self.assertRaises(ContractError):
                official_integer_total(path)

    def test_interpreter_live_blocks_distinct_from_call_count(self):
        text = 'heaptrack stats:\n\tallocations: 99\n\tleaked allocations: 2\n\ttemporary allocations: 1\n'
        self.assertEqual(interpreter_live_blocks(text), 2)
        with self.assertRaises(ContractError):
            interpreter_live_blocks(text + text)

    def test_tool_warnings_fail_closed(self):
        with self.assertRaises(ContractError):
            check_official_diagnostics('WARNING: Detected RTLD_DEEPBIND, dropping flag')
        check_official_diagnostics('Heaptrack finished!\nheaptrack stats:\n allocations: 23\n')


class PackageTests(unittest.TestCase):
    GOOD = '''heaptrack:
  Installed: 1.5.0+dfsg1-2ubuntu3
  Candidate: 1.5.0+dfsg1-2ubuntu3
  Version table:
 *** 1.5.0+dfsg1-2ubuntu3 500
        500 http://azure.archive.ubuntu.com/ubuntu noble/universe amd64 Packages
        100 /var/lib/dpkg/status
'''

    def test_official_origin_is_required(self):
        self.assertEqual(len(validate_policy(self.GOOD)), 1)
        for bad in ('https://ppa.launchpadcontent.net/user/pkg/ubuntu', 'https://evil.invalid/ubuntu',
                    'https://archive.ubuntu.com.evil.invalid/ubuntu'):
            with self.assertRaises(ContractError):
                validate_policy(self.GOOD.replace('http://azure.archive.ubuntu.com/ubuntu', bad))

    def test_installed_only_or_wrong_suite_fails(self):
        with self.assertRaises(ContractError):
            validate_policy('\n'.join(line for line in self.GOOD.splitlines() if 'Packages' not in line))
        with self.assertRaises(ContractError):
            validate_policy(self.GOOD.replace('noble/universe', 'jammy/universe'))

    def test_ambiguous_metadata_field_rejected(self):
        self.assertEqual(deb_fields('Package: heaptrack\nVersion: 1\n')[0]['Package'], 'heaptrack')
        with self.assertRaises(ContractError):
            deb_fields('Package: heaptrack\nPackage: other\n')

    def test_fast_exit_trace_cap_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            with (Path(directory) / 'trace.gz').open('wb') as out:
                out.truncate(MAX_COMPRESSED + 1)
            with self.assertRaisesRegex(ContractError, 'Compressed trace cap'):
                check_trace_caps(directory)


class OwnedProcessTests(unittest.TestCase):
    def make_runner(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        return Runner(Path(directory.name))

    def test_successful_child_group_is_cleaned(self):
        runner = self.make_runner()
        runner.command('short-child', [sys.executable, '-c', 'print("ok")'], seconds=2)
        self.assertTrue(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])

    def test_timeout_terminates_own_group(self):
        runner = self.make_runner()
        with self.assertRaisesRegex(ContractError, 'timeout'):
            runner.command('timed-child', [sys.executable, '-c', 'import time; time.sleep(5)'], seconds=0.05)
        self.assertTrue(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])

    def test_leader_exit_does_not_skip_sigkill_for_term_ignoring_child(self):
        runner = self.make_runner()
        # The test temporarily acts as a Linux child subreaper solely so that
        # it can reap its own synthetic orphan after asserting group cleanup.
        # The production runner does not change the subreaper setting.
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        prior = ctypes.c_int()
        self.assertEqual(libc.prctl(37, ctypes.byref(prior), 0, 0, 0), 0)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        pidfile = runner.output / 'child.pid'
        child = 'import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(' + repr(str(pidfile)) + ',"w").write(str(os.getpid())); time.sleep(30)'
        leader = ('import subprocess,time; subprocess.Popen([' + repr(sys.executable) + ',"-c",' + repr(child)
                  + ']); p=' + repr(str(pidfile))
                  + '; from pathlib import Path\nwhile not Path(p).exists(): time.sleep(0.005)\n')
        try:
            # A dead adopted child remains a zombie until this test reaps it,
            # so the runner must report cleanup unverified instead of success.
            with self.assertRaisesRegex(ContractError, 'group remains'):
                runner.command('orphan-child', [sys.executable, '-c', leader], seconds=3)
            child_pid = int(pidfile.read_text())
            pid, status = os.waitpid(child_pid, 0)
            self.assertEqual(pid, child_pid)
            self.assertTrue(os.WIFSIGNALED(status))
            self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
            self.assertFalse(runner.manifest['commands'][-1]['ownedGroupCleanupVerified'])
        finally:
            self.assertEqual(libc.prctl(36, prior.value, 0, 0, 0), 0)


if __name__ == '__main__':
    unittest.main()
