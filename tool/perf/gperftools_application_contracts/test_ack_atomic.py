"""Bounded cross-process ACK publication tests against the actual native reader.

Only a synthetic writer and the compiled native file-I/O adapter are run. No
profiler/provider initialize/dump, application, SDK or network call is made.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import application_contract as a
from test_native_contracts import clean_environment, compile_c, seal

ROOT = Path(__file__).resolve().parent
ACK = b'ABC_HEAP_ACK_V1 0 0 OK\n'
WAITER = r'''
#include "quiet_dump_linux.c"
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    runtime.output=open(argv[1],O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
    if(runtime.output<0) return 3;
    puts("ready");fflush(stdout);
    int result=wait_ack(NULL,0,0,clock_ns(NULL)+ABC_ACK_NS);
    printf("{\"ack\":%d}\n",result);
    close(runtime.output);
    return result?1:0;
}
'''
WRITER = r'''
import os,sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import application_contract as a
out=Path(sys.argv[2]); real_write=os.write; first=True

def delayed_write(fd,data):
    global first
    if not first:
        return real_write(fd,data)
    first=False
    written=real_write(fd,data[:8])
    (out/'writer.partial').write_text('partial write reached\n')
    deadline=time.monotonic()+1.0
    while not (out/'writer.release').exists():
        if time.monotonic()>=deadline:
            raise RuntimeError('bounded synthetic writer gate timed out')
        time.sleep(0.002)
    return written
os.write=delayed_write
start=time.monotonic()
a.acknowledge(out,{'slot':0,'cycle':0},hook_started=start,receipt_seen=start,now=start)
'''


class AtomicAckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_tmp = tempfile.TemporaryDirectory()
        cls.build_root = Path(cls.build_tmp.name)
        target, library = cls.build_root / 'target', cls.build_root / 'library'
        target.write_bytes(b'offline target identity only')
        library.write_bytes(b'offline provider identity only')
        arms = {name: cls.build_root / name for name in ('probe-only', 'product-with-ownership')}
        for directory in arms.values():
            directory.mkdir()
        config = cls.build_root / 'seal.h'
        seal(config, target, library, arms)
        source = cls.build_root / 'waiter.c'
        source.write_text(WAITER)
        cls.waiter = cls.build_root / 'waiter'
        compile_c(cls.waiter, [source, ROOT / 'quiet_dump_bridge.c'], config=config, extra=('-ldl',))

    @classmethod
    def tearDownClass(cls):
        cls.build_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def ack(self):
        return a.acknowledge(self.root, {'slot': 0, 'cycle': 0},
                             hook_started=0, receipt_seen=0, now=0)

    def test_native_waiter_never_sees_partial_final_ack_during_delayed_write(self):
        waiter = subprocess.Popen([str(self.waiter), str(self.root)], env=clean_environment(),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        writer = None
        try:
            self.assertTrue(select.select([waiter.stdout], [], [], 1)[0], 'Native waiter not ready')
            self.assertEqual(waiter.stdout.readline(), 'ready\n')
            writer = subprocess.Popen([sys.executable, '-c', WRITER, str(ROOT), str(self.root)],
                                      env=clean_environment(), stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 0.75
            while not (self.root / 'writer.partial').exists():
                self.assertLess(time.monotonic(), deadline, 'Writer did not reach partial write')
                time.sleep(0.002)
            self.assertEqual((self.root / 'q0.ack.pending').read_bytes(), ACK[:8])
            self.assertFalse((self.root / 'q0.ack').exists())
            self.assertIsNone(waiter.poll(), 'Native reader must keep waiting for final ACK')
            expected = {'q0.ack', 'writer.partial', 'writer.release'}
            a.check_sidecar_caps(self.root, expected_files=expected)
            with self.assertRaisesRegex(a.ContractError, 'Unexpected/missing'):
                a.inspect_sidecar(self.root, expected_files=expected)
            (self.root / 'writer.release').write_text('continue\n')
            stdout, stderr = writer.communicate(timeout=2)
            self.assertEqual(writer.returncode, 0, (stdout, stderr))
            stdout, stderr = waiter.communicate(timeout=2)
            self.assertEqual(waiter.returncode, 0, (stdout, stderr))
            self.assertEqual(json.loads(stdout)['ack'], 0)
            self.assertEqual((self.root / 'q0.ack').read_bytes(), ACK)
            self.assertFalse((self.root / 'q0.ack.pending').exists())
            a.inspect_sidecar(self.root, expected_files=expected)
        finally:
            (self.root / 'writer.release').touch()
            for process in (writer, waiter):
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=2)

    def test_existing_ack_is_not_overwritten_and_pending_evidence_remains(self):
        path = self.root / 'q0.ack'
        path.write_bytes(b'previous ACK evidence\n')
        with self.assertRaises(FileExistsError):
            self.ack()
        self.assertEqual(path.read_bytes(), b'previous ACK evidence\n')
        self.assertEqual((self.root / 'q0.ack.pending').read_bytes(), ACK)

    def test_existing_ack_symlink_target_is_not_modified(self):
        victim = self.root / 'victim'
        victim.write_bytes(b'keep these bytes')
        (self.root / 'q0.ack').symlink_to(victim)
        with self.assertRaises(FileExistsError):
            self.ack()
        self.assertTrue((self.root / 'q0.ack').is_symlink())
        self.assertEqual(victim.read_bytes(), b'keep these bytes')
        self.assertEqual((self.root / 'q0.ack.pending').read_bytes(), ACK)

    def test_existing_pending_symlink_is_not_followed(self):
        victim = self.root / 'victim'
        victim.write_bytes(b'keep these bytes')
        (self.root / 'q0.ack.pending').symlink_to(victim)
        with self.assertRaises(FileExistsError):
            self.ack()
        self.assertEqual(victim.read_bytes(), b'keep these bytes')
        self.assertFalse((self.root / 'q0.ack').exists())

    def test_write_and_fsync_failure_preserve_pending_never_publish_final(self):
        with patch('application_contract.os.write', side_effect=OSError('synthetic write failure')):
            with self.assertRaisesRegex(OSError, 'write failure'):
                self.ack()
        self.assertTrue((self.root / 'q0.ack.pending').exists())
        self.assertFalse((self.root / 'q0.ack').exists())
        (self.root / 'q0.ack.pending').unlink()  # Test fixture reset, never runtime recovery.
        with patch('application_contract.os.fsync', side_effect=OSError('synthetic fsync failure')):
            with self.assertRaisesRegex(OSError, 'fsync failure'):
                self.ack()
        self.assertEqual((self.root / 'q0.ack.pending').read_bytes(), ACK)
        self.assertFalse((self.root / 'q0.ack').exists())

    def test_runtime_allows_only_declared_cut_pending_name(self):
        (self.root / 'q0.ack.pending').write_bytes(b'')
        a.check_sidecar_caps(self.root, expected_files={'q0.ack'})
        with self.assertRaises(a.ContractError):
            a.check_sidecar_caps(self.root, expected_files={'q7.ack'})
        with self.assertRaises(a.ContractError):
            a.inspect_sidecar(self.root, expected_files={'q0.ack'})
        (self.root / 'q0.ack.pending').rename(self.root / 'q3.ack.pending')
        with self.assertRaises(a.ContractError):
            a.check_sidecar_caps(self.root, expected_files={'q0.ack', 'q7.ack'})


if __name__ == '__main__':
    unittest.main()
