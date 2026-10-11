#!/usr/bin/env python3
"""Small-contract OFFLINE fault tests using a synthetic provider and identities.

No official allocator is linked, loaded, or invoked. The sample fixture has no
connection to the known allocation and cannot prove real stack/lifetime matches.
Official development headers are used only by the explicit compile-only test.
"""
from __future__ import annotations
from contextlib import contextmanager
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import unittest
import resource

ROOT=Path(__file__).resolve().parent
STUB_HEADER='''// OFFLINE ONLY. Synthetic public-API-shaped stub.
#ifndef ABC_SMALL_STUB_HEADER
#define ABC_SMALL_STUB_HEADER
#include <string>
class MallocExtension {
 public:
  virtual ~MallocExtension() = default;
  static MallocExtension *instance();
  virtual void GetHeapSample(std::string *) = 0;
  enum Ownership { kUnknownOwnership, kOwned, kNotOwned };
  virtual Ownership GetOwnership(const void *) = 0;
};
#endif
'''

def clean_environment():
    prefixes=('LD_', 'HEAP', 'TCMALLOC', 'CPUPROFILE', 'MALLOC', 'ABC_')
    env={k:v for k,v in os.environ.items() if not k.startswith(prefixes)}
    env.update(ABC_SAMPLED_DIAGNOSTIC='1', TCMALLOC_SAMPLE_PARAMETER='524288')
    return env

def run(command, env=None):
    return subprocess.run(command,check=True,text=True,capture_output=True,
                          timeout=30,env=clean_environment() if env is None else env)

class SmallSampleContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_tmp=tempfile.TemporaryDirectory(prefix='abc-small-offline-build-')
        cls.build=Path(cls.build_tmp.name)
        (cls.build/'gperftools').mkdir()
        (cls.build/'gperftools/malloc_extension.h').write_text(STUB_HEADER)
        identity=cls.build/'synthetic-provider-identity'
        identity.write_bytes(b'INERT OFFLINE IDENTITY ONLY. NOT AN ALLOCATOR OR ELF.\n')
        st=identity.stat()
        cls.config=cls.build/'identity.h'
        cls.config.write_text('static const struct abc_file_identity abc_sample_library = {'+
            f'{json.dumps(str(identity))}, UINT64_C({st.st_dev}), UINT64_C({st.st_ino}), '+
            f'UINT64_C({st.st_size}), "{hashlib.sha256(identity.read_bytes()).hexdigest()}"'+
            '};\n')
        cls.binary=cls.build/'small-offline-stub'
        cls.flags=['-std=c++17','-O2','-Wall','-Wextra','-Werror',
                   '-fno-omit-frame-pointer','-fno-optimize-sibling-calls']
        selected=os.environ.get('ABC_SAMPLE_STUB_FORTIFY_LEVEL','default')
        if selected not in ('default','2','3'):
            raise ValueError('ABC_SAMPLE_STUB_FORTIFY_LEVEL must be default, 2, or 3')
        # Select a known test level without accepting arbitrary compiler flags.
        # Default keeps the compiler's own hardening; forced levels remain on.
        fortify_flags=[] if selected=='default' else ['-U_FORTIFY_SOURCE',f'-D_FORTIFY_SOURCE={selected}']
        compiler=shutil.which('c++') or 'c++'
        cls.compiler_version=run([compiler,'--version']).stdout.splitlines()[0]
        run([compiler,*cls.flags,*fortify_flags,'-I',str(cls.build),'-I',str(ROOT),
             '-DABC_SAMPLE_OFFLINE_TESTING',f'-DABC_SAMPLE_LIBRARY_CONFIG="{cls.config}"',
             str(ROOT/'small_contract_stub_test.cc'),str(ROOT/'sample_wrapper.cc'),
             *[f'-Wl,--wrap={name}' for name in
               ('malloc','free','dlsym','dladdr','open','openat','read','__read_chk','write','close','fsync')],
             '-ldl','-o',str(cls.binary)])
        build_info=json.loads(run([str(cls.binary),'--offline-build-info']).stdout)
        assert build_info['offline'] and not build_info['officialRuntimeInvoked']
        cls.fortify_level=build_info['fortifyLevel']
        if selected!='default' and cls.fortify_level!=int(selected):
            raise AssertionError('Requested fortified test level was not compiled')
        print(f'Synthetic small contract: {cls.compiler_version}; __USE_FORTIFY_LEVEL={cls.fortify_level}')

    @classmethod
    def tearDownClass(cls):
        cls.build_tmp.cleanup()

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='abc-small-offline-case-')
        self.directory=Path(self.tmp.name)
        self.directory.chmod(0o700)

    def tearDown(self):
        self.tmp.cleanup()

    @contextmanager
    def fresh_case(self):
        # A failed subTest assertion must not leave a cut directory for the
        # next subcase. Explicit existing-cut/symlink tests keep their setup.
        previous=self.directory
        with tempfile.TemporaryDirectory(prefix='abc-small-offline-subcase-') as tmp:
            self.directory=Path(tmp)
            self.directory.chmod(0o700)
            try:
                yield
            finally:
                self.directory=previous

    def case(self,scenario='success',env_changes=None,output=None):
        env=clean_environment()
        for key,value in (env_changes or {}).items():
            if value is None: env.pop(key,None)
            else: env[key]=value
        lines=run([str(self.binary),scenario,str(output or self.directory)],env=env).stdout.splitlines()
        execution,evidence=map(json.loads,lines)
        self.assertTrue(evidence['offline'])
        self.assertFalse(evidence['officialRuntimeInvoked'])
        self.assertEqual(evidence['fortifyLevel'],self.fortify_level)
        self.assertEqual(evidence['liveFds'],0)
        self.assertEqual((evidence['knownStillLive'],evidence['probeStillLive']),(0,0))
        self.assertLessEqual(evidence['knownAllocations'],1)
        self.assertLessEqual(evidence['knownFrees'],1)
        self.assertLessEqual(evidence['sampleCalls'],3)
        self.assertEqual(execution['samplePeriodBytes'],524288)
        self.assertEqual(execution['knownBytes'],32*1024*1024)
        self.assertEqual(execution['snapshotsPlanned'],3)
        self.assertFalse(execution['fullHeapCoverage'])
        return execution,evidence

    def cut(self,name='baseline'):
        return json.loads((self.directory/name/'capture.json').read_text())

    def test_exact_three_cuts_one_known_allocation_and_free(self):
        execution,r=self.case()
        self.assertEqual((execution['status'],execution['cleanupErrno'],r['exitStatus']),(0,0,0))
        self.assertEqual((r['sampleCalls'],r['knownAllocations'],r['knownFrees']),(3,1,1))
        self.assertEqual((r['probeAllocations'],r['probeFrees']),(1,1))
        self.assertEqual(r['knownLiveAtSample'],[0,1,0])
        self.assertEqual(r['mapsOpens'],6)
        self.assertEqual(sorted(p.name for p in self.directory.iterdir()),['baseline','freed','held'])
        for name in ('baseline','held','freed'):
            report=self.cut(name)
            self.assertEqual((report['status'],report['nativeStatus'],report['apiCalls'],report['published']),(0,0,1,1))
            self.assertEqual(report['returnedBytes'],report['writtenBytes'])
            for p in (self.directory/name).iterdir():
                self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)

    def test_null_or_unowned_probe_never_samples(self):
        for scenario in ('null-provider','probe-not-owned','probe-allocation-failure'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['knownAllocations']),(7,0,0))
                self.assertEqual(list(self.directory.iterdir()),[])

    def test_all_public_provider_addresses_are_required(self):
        for scenario in ('wrong-instance-address','wrong-calloc-address','wrong-realloc-address','wrong-free-address'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['instanceCalls']),(6,0,0))

    def test_changed_instance_or_provider_rejects_after_single_sample(self):
        for scenario in ('provider-address-changed','instance-changed-after-sample'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['knownAllocations']),(25,1,0))
                self.assertEqual(self.cut()['nativeStatus'],4)
                self.assertFalse((self.directory/'baseline/q0.sample.heap').exists())

    def test_missing_or_changed_instance_after_allocation_frees_once(self):
        for scenario in ('null-provider-held','instance-changed-held','ownership-not-owned'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['knownFrees']),(9,1,1))

    def test_ownership_and_instance_exceptions_free_once(self):
        for scenario,status in (('ownership-throw-known',91),('ownership-bad-alloc-known',90),('instance-throw-held',91)):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['knownFrees']),(status,1,1))

    def test_known_allocation_failure_has_no_held_or_freed_retry(self):
        execution,r=self.case('known-allocation-failure')
        self.assertEqual((execution['status'],r['sampleCalls'],r['knownAllocations'],r['knownFrees']),(8,1,1,0))
        self.assertEqual([p.name for p in self.directory.iterdir()],['baseline'])

    def test_held_sample_exception_frees_known_and_stops(self):
        execution,r=self.case('sample-throw-held')
        self.assertEqual((execution['status'],r['sampleCalls'],r['knownFrees']),(25,2,1))
        self.assertEqual(self.cut('held')['nativeStatus'],8)
        self.assertTrue((self.directory/'held/after.maps').exists())
        self.assertFalse((self.directory/'freed').exists())

    def test_empty_and_oversized_samples_reject_without_retries(self):
        for scenario,native in (('sample-empty',10),('sample-at-limit',11)):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],self.cut()['nativeStatus']),(25,1,native))
                self.assertTrue((self.directory/'baseline/after.maps').exists())

    def test_invalid_sample_bytes_are_preserved_not_claimed_semantically_valid(self):
        execution,r=self.case('sample-nul')
        self.assertEqual((execution['status'],r['sampleCalls']),(0,3))
        self.assertTrue((self.directory/'held/q0.sample.heap').read_bytes().endswith(b'\0'))
        self.assertNotIn('accepted',execution)

    def test_fixed_environment_and_full_profiler_rejection_are_inert(self):
        for changes,native in (({'TCMALLOC_SAMPLE_PARAMETER':'1'},3),({'ABC_SAMPLED_DIAGNOSTIC':None},1),({'HEAPPROFILE':'0'},3)):
            with self.subTest(changes=changes), self.fresh_case():
                execution,r=self.case(env_changes=changes)
                self.assertEqual((execution['status'],r['sampleCalls'],self.cut()['nativeStatus']),(23,0,native))
                self.assertEqual(r['mapsOpens'],1)

    def test_maps_failure_preserves_bounded_bytes_and_after_map_once(self):
        for scenario,size in (('maps-read-error',32),('maps-read-eintr',32),('maps-empty',0),('maps-no-newline',32),('maps-over-limit',1048576)):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['mapsOpens']),(24,0,2))
                self.assertEqual((self.directory/'baseline/before.maps').stat().st_size,size)
                self.assertTrue((self.directory/'baseline/after.maps').exists())

    def test_maps_exact_limit_complete_newline_is_permitted(self):
        execution,r=self.case('maps-at-limit')
        self.assertEqual((execution['status'],r['sampleCalls']),(0,3))
        self.assertEqual((self.directory/'baseline/before.maps').stat().st_size,1048576)

    def test_maps_open_failure_still_retains_after_snapshot(self):
        execution,r=self.case('maps-open-failure')
        self.assertEqual((execution['status'],r['sampleCalls'],r['mapsOpens']),(24,0,2))
        self.assertFalse((self.directory/'baseline/before.maps').exists())
        self.assertTrue((self.directory/'baseline/after.maps').exists())

    def test_output_faults_never_retry_or_sample(self):
        for scenario in ('before-output-open-failure','before-short-write','before-write-eintr','before-sync-failure'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls'],r['mapsOpens']),(24,0,2))

    def test_close_errors_are_recorded_without_retry_or_descriptor_leak(self):
        for scenario in ('maps-close-failure','before-close-failure'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],execution['cleanupErrno'],r['sampleCalls']),(24,errno.EINTR,0))

    def test_report_failure_preserves_earlier_primary_status(self):
        for scenario,status,calls in (('report-write-failure',27,1),('primary-and-report-failure',23,0)):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],r['sampleCalls']),(status,calls))

    def test_final_descriptor_cleanup_error_rejects_successful_captures(self):
        for scenario in ('root-close-failure','library-close-failure'):
            with self.subTest(scenario=scenario), self.fresh_case():
                execution,r=self.case(scenario)
                self.assertEqual((execution['status'],execution['cleanupErrno'],r['exitStatus']),
                                 (0,errno.EINTR,92))
                self.assertEqual((r['sampleCalls'],r['knownFrees'],r['probeFrees']),(3,1,1))

    def test_existing_cut_is_not_reused_or_overwritten(self):
        baseline=self.directory/'baseline';baseline.mkdir();sentinel=baseline/'untouched';sentinel.write_bytes(b'keep')
        execution,r=self.case()
        self.assertEqual((execution['status'],r['sampleCalls']),(20,0))
        self.assertEqual(sentinel.read_bytes(),b'keep')

    def test_symlink_output_is_not_followed(self):
        sentinel=self.directory/'untouched';sentinel.write_bytes(b'keep')
        execution,r=self.case('before-symlink')
        self.assertEqual((execution['status'],r['sampleCalls']),(24,0))
        self.assertEqual(sentinel.read_bytes(),b'keep')

    def test_nonprivate_and_noncanonical_roots_are_rejected(self):
        self.directory.chmod(0o755)
        execution,r=self.case()
        self.assertEqual((execution['status'],r['sampleCalls']),(4,0))
        self.directory.chmod(0o700)
        execution,r=self.case(output=str(self.directory)+'/../'+self.directory.name)
        self.assertEqual((execution['status'],r['sampleCalls']),(2,0))

    def test_known_allocation_symbol_survives_optimized_offline_build(self):
        symbols=run(['nm','--defined-only',str(self.binary)]).stdout
        self.assertRegex(symbols,r'(?m)^\S+ T abc_sample_known_allocate$')

    def test_fortified_read_boundary_keeps_real_overflow_guard(self):
        command=[str(self.binary),'fortified-read-boundary',str(self.directory)]
        valid=json.loads(run([*command,'1']).stdout)
        self.assertTrue(valid['offline'])
        self.assertFalse(valid['officialRuntimeInvoked'])
        self.assertEqual(valid['fortifiedReadBytes'],1)
        overflow=subprocess.run([*command,'2'],check=False,text=True,capture_output=True,
            timeout=30,env=clean_environment(),
            preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_CORE,(0,0)))
        self.assertEqual(overflow.returncode,-signal.SIGABRT)
        self.assertNotIn('fortifiedReadBytes',overflow.stdout)

    def test_missing_fortified_interception_reproduces_original_empty_maps(self):
        if self.fortify_level!=3:
            self.skipTest('Original maps-dispatch regression is exercised by the level-3 suite.')
        # Explicit fault injection forwards maps to the real checked read,
        # recreating the old missing-wrap behavior on the /dev/null fixture.
        execution,r=self.case('bypass-fortified-maps')
        self.assertEqual((execution['status'],r['sampleCalls'],r['mapsOpens']),(24,0,2))
        self.assertEqual(self.cut()['nativeStatus'],0)
        self.assertEqual((self.directory/'baseline/before.maps').stat().st_size,0)
        self.assertEqual((self.directory/'baseline/after.maps').stat().st_size,0)

    def test_failed_subcase_does_not_leave_a_cut_for_next_subcase(self):
        with self.assertRaises(AssertionError):
            with self.fresh_case():
                previous=self.directory
                execution,_=self.case()
                self.assertEqual(execution['status'],0)
                self.fail('Intentional assertion to verify unconditional subcase cleanup')
        self.assertFalse(previous.exists())
        with self.fresh_case():
            self.assertNotEqual(self.directory,previous)
            execution,r=self.case()
            self.assertEqual((execution['status'],r['sampleCalls']),(0,3))

    def test_official_headers_compile_only_when_explicitly_supplied(self):
        supplied=os.environ.get('ABC_SAMPLE_OFFICIAL_HEADERS')
        if not supplied:
            self.skipTest('Set ABC_SAMPLE_OFFICIAL_HEADERS for the separate compile-only check.')
        include=Path(supplied).resolve(strict=True)
        header=include/'gperftools/malloc_extension.h'
        self.assertEqual(hashlib.sha256(header.read_bytes()).hexdigest(),
                         'cc11faffcadfd601272d154571086372641ded100604e732ca382b6217a4d583')
        run([shutil.which('c++') or 'c++',*self.flags,'-I',str(include),'-I',str(ROOT),
             f'-DABC_SAMPLE_LIBRARY_CONFIG="{self.config}"','-c',
             str(ROOT/'small_sample_contract.cc'),'-o',str(self.build/'official-header-only.o')])

if __name__=='__main__':
    unittest.main()
