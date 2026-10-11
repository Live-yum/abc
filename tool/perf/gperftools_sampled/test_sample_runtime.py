#!/usr/bin/env python3
"""Offline runtime/launcher tests: inert ELF and synthetic provider only.
No official allocator, SDK, application, GitHub, network or CI is invoked.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from sampled_seal_config import file_identity, output_identity, render_header
ROOT = Path(__file__).resolve().parent
STUB_HEADER = '''#include <string>
class MallocExtension {
 public:
 enum Ownership { kUnknownOwnership = 0, kOwned, kNotOwned };
 virtual ~MallocExtension() = default;
 static MallocExtension *instance();
 virtual Ownership GetOwnership(const void *) = 0;
 virtual void GetHeapSample(std::string *) = 0;
};
'''
def clean_environment():
    return {k:v for k,v in os.environ.items() if not k.startswith(("LD_", "HEAP", "TCMALLOC", "CPUPROFILE", "MALLOC", "ABC_"))}
def run(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=20, env=clean_environment())
    if result.returncode:
        raise AssertionError(f"compile failed: {result.stderr}")
    return result
class SampleRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_tmp = tempfile.TemporaryDirectory(prefix="abc-sampled-runtime-offline-")
        cls.build = Path(cls.build_tmp.name)
        (cls.build / "gperftools").mkdir()
        (cls.build / "gperftools/malloc_extension.h").write_text(STUB_HEADER)
        cls.library = cls.build / "synthetic-provider.so"
        cls.target = cls.build / "inert-target"
        cls.cxx = shutil.which("c++") or "c++"
        cls.cc = shutil.which("cc") or "cc"
        cls.flags = ["-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function"]
        run([cls.cxx,*cls.flags,"-fPIC","-shared","-I",str(cls.build),str(ROOT/"native_runtime_stub_provider.cc"),"-o",str(cls.library)])
        run([cls.cxx,*cls.flags,"-I",str(ROOT),str(ROOT/"native_runtime_stub_target.cc"),"-ldl","-o",str(cls.target)])
    @classmethod
    def tearDownClass(cls):
        cls.build_tmp.cleanup()
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="abc-sampled-runtime-case-")
        self.case_dir = Path(self.tmp.name)
        self.output = self.case_dir / "output"
        self.output.mkdir(mode=0o700)
        self.helper = self.case_dir / "runtime.so"
        self.launcher = self.case_dir / "sampled-launcher"
        self.config = self.case_dir / "runtime-seal.h"
        self.launch_config = self.case_dir / "launcher-seal.h"
        self.target_id = file_identity(self.target, executable=True)
        self.library_id = file_identity(self.library)
        self.output_id = output_identity(self.output)
        self.config.write_text(render_header(self.target_id,self.library_id,self.output_id,str(self.helper)))
        run([self.cxx,*self.flags,"-DABC_SAMPLE_OFFLINE_TESTING","-fPIC","-shared",f'-DABC_SAMPLE_SEALED_CONFIG="{self.config}"',"-I",str(self.build),"-I",str(ROOT),str(ROOT/"sample_runtime.cc"),str(ROOT/"sample_wrapper.cc"),str(ROOT/"native_runtime_stub_faults.cc"),"-Wl,--wrap=close",str(self.library),"-Wl,-z,defs","-ldl","-o",str(self.helper)])
        self.launch_config.write_text(render_header(self.target_id,self.library_id,self.output_id,str(self.helper),helper=file_identity(self.helper)))
        run([self.cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-DABC_SAMPLE_OFFLINE_TESTING",f'-DABC_SAMPLE_SEALED_CONFIG="{self.launch_config}"',"-I",str(ROOT),str(ROOT/"sampled_target_launcher.c"),"-o",str(self.launcher)])
    def tearDown(self):
        self.output.chmod(0o700)
        self.tmp.cleanup()
    def case(self, action="success", *, ack="success", env_changes=None):
        env = clean_environment(); env.update(env_changes or {})
        process = subprocess.Popen([str(self.launcher),action],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        sent = False; deadline = time.monotonic()+8
        while process.poll() is None and time.monotonic()<deadline:
            if (self.output/"q0.sample.receipt").exists() and ack!="missing" and not sent:
                pending = self.output/"q0.sample.ack.pending"
                payload = b"ABC_SAMPLED_ACK_V1 0 0 OK\n" if ack=="success" else b"ABC_HEAP_ACK_V1 0 0 OK\n"
                fd=os.open(pending,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                try: os.write(fd,payload); os.fsync(fd)
                finally: os.close(fd)
                pending.rename(self.output/"q0.sample.ack");sent=True
            time.sleep(.005)
        if process.poll() is None: process.kill()
        stdout,stderr=process.communicate(timeout=2)
        self.assertEqual(process.returncode,0,stderr)
        records=[json.loads(line) for line in stdout.splitlines()]
        self.assertTrue(records[-1]["offline"]);self.assertFalse(records[-1]["officialRuntimeInvoked"])
        for record in records:
            if "schema" in record:
                self.assertLess(len(json.dumps(record)),16384)
                self.assertEqual(record["schema"],"abc.gperftools-sampled-runtime.v1")
                self.assertFalse(record["mapsAccepted"]);self.assertFalse(record["fullRunCompleted"])
        return records
    def test_success_provider_identity_receipt_cleanup_and_fixture(self):
        startup,closed,status=self.case()
        self.assertEqual((status["initStatus"],status["cutStatus"]),(0,0))
        self.assertEqual((startup["observer"]["heldFds"],startup["observer"]["fdOpened"],startup["observer"]["fdClosed"]),(3,4,1))
        self.assertTrue(startup["provider"]["publicInstanceAddressChecked"])
        self.assertTrue(startup["provider"]["allocationOwnershipChecked"])
        self.assertEqual(closed["provider"]["sha256"],self.library_id["sha256"])
        self.assertEqual(closed["target"]["sha256"],self.target_id["sha256"])
        self.assertEqual(closed["pid"],startup["pid"])
        self.assertEqual((closed["q0Calls"],closed["sample"]["api_calls"],closed["closeCalls"]),(1,1,1))
        self.assertTrue(closed["q0TransportAccepted"]);self.assertTrue(closed["cut"]["receiptPublished"]);self.assertTrue(closed["cut"]["ackAccepted"])
        o=closed["observer"]
        self.assertEqual(o["fdOpened"],o["fdCloseAttempts"]);self.assertEqual(o["fdOpened"],o["fdClosed"])
        self.assertEqual((o["heldFds"],o["cleanupErrno"]),(0,0));self.assertEqual(o["preallocatedMapsBytes"],2097152)
        for name in ("q0.sample.before.maps","q0.sample.after.maps"):
            p=self.output/name
            self.assertTrue(p.read_bytes().endswith(b"\n"));self.assertLessEqual(p.stat().st_size,1048576)
            self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)
        parts=(self.output/"q0.sample.receipt").read_text().split()
        self.assertEqual(parts[:3],["ABC_SAMPLED_RECEIPT_V1","0","0"]);self.assertEqual(int(parts[3]),closed["pid"])
        self.assertEqual(parts[-1],"q0.sample.heap")
        def shape(v): return {k:shape(x) if isinstance(x,dict) else type(x).__name__ for k,x in v.items()}
        fixture=json.loads((ROOT/"sample_runtime_metadata.example.json").read_text())
        self.assertEqual(shape(closed),shape(fixture))
    def test_second_launch_rejected(self):
        self.case()
        r=subprocess.run([str(self.launcher)],env=clean_environment(),capture_output=True,text=True)
        self.assertEqual(r.returncode,78);self.assertIn("once-token",r.stderr);self.assertEqual(r.stdout,"")
    def test_no_retry_idempotent_cleanup(self):
        _,first,repeated,second,_=self.case("repeat")
        self.assertEqual(repeated,{"repeat":108,"reinitialize":108,"reclose":0})
        self.assertEqual(first["observer"],second["observer"]);self.assertEqual(second["sample"]["api_calls"],1)
    def test_wrong_ack_preserves_artifacts(self):
        _,closed,status=self.case(ack="wrong")
        self.assertEqual(status["cutStatus"],105);self.assertFalse(closed["q0TransportAccepted"])
        for name in ("q0.sample.heap","q0.sample.before.maps","q0.sample.after.maps","q0.sample.receipt"):
            self.assertTrue((self.output/name).exists())
        self.assertEqual(closed["observer"]["heldFds"],0)
    def test_missing_ack_original_two_seconds(self):
        started=time.monotonic();_,closed,status=self.case(ack="missing")
        self.assertEqual(status["cutStatus"],105);self.assertLess(time.monotonic()-started,4)
        self.assertFalse(closed["cut"]["ackAccepted"])
    def test_current_ownership_rechecked(self):
        _,closed,status=self.case("unowned-after-init")
        self.assertEqual(status["cutStatus"],102);self.assertEqual(closed["sample"]["api_calls"],0)
    def test_current_environment_rechecked(self):
        _,closed,status=self.case("dirty-after-init")
        self.assertEqual(status["cutStatus"],102);self.assertEqual(closed["sample"]["api_calls"],0)
    def test_output_identity_rechecked(self):
        _,closed,status=self.case("output-mode-after-init")
        self.assertEqual(status["cutStatus"],102);self.assertEqual(closed["sample"]["api_calls"],0)
    def test_retained_library_sha_and_size_rechecked(self):
        original=self.library.read_bytes()
        try:
            _,closed,status=self.case("library-change-after-init")
            self.assertEqual(status["cutStatus"],102)
            self.assertEqual(closed["sample"]["api_calls"],0)
            self.assertEqual(closed["observer"]["heldFds"],0)
        finally:
            self.library.write_bytes(original)
    def test_sample_exception_retains_maps(self):
        _,closed,status=self.case(env_changes={"ABC_STUB_SCENARIO":"sample-throw"})
        self.assertEqual(status["cutStatus"],8);self.assertEqual(closed["sample"]["api_calls"],1)
        self.assertTrue((self.output/"q0.sample.before.maps").exists());self.assertTrue((self.output/"q0.sample.after.maps").exists())
        self.assertFalse((self.output/"q0.sample.receipt").exists())
    def test_wrong_ownership_init_cleanup(self):
        startup,closed,status=self.case(env_changes={"ABC_STUB_SCENARIO":"unowned"})
        self.assertEqual(status["initStatus"],102);self.assertFalse(startup["initialized"])
        self.assertEqual(closed["observer"]["heldFds"],0);self.assertEqual(closed["sample"]["api_calls"],0)
    def test_close_eintr_is_recorded_and_never_retried(self):
        startup,closed,status=self.case(env_changes={"ABC_STUB_SCENARIO":"close-eintr"})
        self.assertEqual(status["initStatus"],101)
        self.assertEqual(closed["observer"]["cleanupErrno"],4)
        self.assertEqual(closed["observer"]["fdOpened"],4)
        self.assertEqual(closed["observer"]["fdCloseAttempts"],4)
        self.assertEqual(closed["observer"]["fdClosed"],3)
        self.assertEqual(closed["observer"]["heldFds"],0)
        self.assertEqual(closed["sample"]["api_calls"],0)
    def test_dirty_launcher_rejected(self):
        env=clean_environment();env["HEAPPROFILE"]="never-start"
        r=subprocess.run([str(self.launcher)],env=env,capture_output=True,text=True)
        self.assertEqual(r.returncode,78);self.assertIn("launcher-not-clean",r.stderr)
        self.assertFalse((self.output/"launch.once").exists())
    def test_helper_actual_hash_verified(self):
        with self.helper.open("ab") as f: f.write(b"changed")
        r=subprocess.run([str(self.launcher)],env=clean_environment(),capture_output=True,text=True)
        self.assertEqual(r.returncode,78);self.assertIn("helper-identity",r.stderr)
        self.assertFalse((self.output/"launch.once").exists())
    def test_preexisting_ack_cannot_satisfy_fresh_cut(self):
        path=self.output/"q0.sample.ack"
        path.write_bytes(b"ABC_SAMPLED_ACK_V1 0 0 OK\n");path.chmod(0o600)
        startup,closed,status=self.case(ack="missing")
        self.assertEqual(status["initStatus"],101)
        self.assertEqual(closed["sample"]["api_calls"],0)
        self.assertEqual(closed["observer"]["heldFds"],0)
        self.assertFalse((self.output/"q0.sample.heap").exists())
    def test_oversize_return_not_truncated_or_published(self):
        _,closed,status=self.case(env_changes={"ABC_STUB_SCENARIO":"sample-oversize"})
        self.assertEqual(status["cutStatus"],11)
        self.assertEqual(closed["sample"]["returned_bytes"],1048576)
        self.assertEqual(closed["sample"]["written_bytes"],0)
        self.assertFalse((self.output/"q0.sample.heap").exists())
        self.assertTrue((self.output/"q0.sample.before.maps").exists())
        self.assertTrue((self.output/"q0.sample.after.maps").exists())
if __name__=="__main__": unittest.main()
