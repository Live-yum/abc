"""Offline Python/C/stub regression only. No Flutter, WLD or profiler execution."""
import copy
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import dependencies
from application_contract import ContractError, MAX_SIDECAR, map_key
from bounded_supervision import PairBudget, TargetProcessIdentity, cleanup_owned_group
from application_process import clean_environment, read_json, run_command
from application_source import (BASE, BASE_TREE, INHERITED, PACKAGE_GATE, BRANCH,
    MANIFEST, TARGET, NEW_WORKFLOW, DIRECT_PARENT, DIRECT_PARENT_TREE, PREFIX_TEST,
    CORRECTION_PATHS, verify_correction_parent, verify_layers)
from capture_contract import CLOCK, CutWatcher, GaugeTail, validate_startup, sidecar_caps
from elf_identity import BoundModules, elf_metadata, endpoint_delta, file_identity, load_bias
from run_pair import (KNOWN_IMAGE_FAILURE, actual_ci_guard, exact_profile_files,
                      runtime_environment)


class ProcessContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='abc-application-runner-test-')
        self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()
    def command(self, code, name='command', **extra):
        deadline = time.monotonic() + 5
        return run_command([sys.executable, '-c', code], self.root / name,
            cwd=self.root, environment=dict(os.environ, CI='true', GITHUB_ACTIONS='true'),
            deadline=lambda: deadline, **extra)

    def test_driver_retains_ci_workload_engine_switches_cleans_profiler(self):
        source = dict(CI='true', GITHUB_ACTIONS='true', MEMORY_OWNER_ARM='probe-only',
                      FLUTTER_ENGINE_SWITCH_1='--abc', COMPUTERRARIA_WLD='/original',
                      LD_PRELOAD='bad', LD_AUDIT='bad', TCMALLOC_SAMPLE_PARAMETER='9',
                      HEAPPROFILE='bad', HEAPPROFILESIGNAL='9', HEAP_PROFILE_INUSE_INTERVAL='1',
                      CPUPROFILE='bad', MALLOC_CONF='bad', ABC_STACK_OUTPUT='bad')
        env = clean_environment(source)
        for key in ('CI', 'GITHUB_ACTIONS', 'MEMORY_OWNER_ARM', 'FLUTTER_ENGINE_SWITCH_1', 'COMPUTERRARIA_WLD'):
            self.assertEqual(env[key], source[key])
        self.assertFalse(any(key.startswith(('LD_', 'HEAP', 'TCMALLOC', 'CPUPROFILE', 'MALLOC')) for key in env))
        self.assertNotIn('ABC_STACK_OUTPUT', env)

    def test_real_child_driver_has_original_file_limit_auxiliary_has_64MiB(self):
        code = 'import json,resource; print(json.dumps(resource.getrlimit(resource.RLIMIT_FSIZE)))'
        original = resource.getrlimit(resource.RLIMIT_FSIZE)
        application = self.command(code, 'application', application=True)
        auxiliary = self.command(code, 'auxiliary')
        self.assertEqual(json.loads(Path(application['stdout']['path']).read_text()), list(original))
        self.assertEqual(json.loads(Path(auxiliary['stdout']['path']).read_text()), [64 << 20] * 2)
        self.assertTrue(application['cleanup']['groupGone'])
        self.assertTrue(auxiliary['cleanup']['groupGone'])
        self.assertTrue(all(row['leaderUnreaped'] for row in application['cleanup']['signals']))

    def test_fast_exit_is_checked_and_partial_output_retained(self):
        with self.assertRaises(ContractError):
            self.command("print('x' * 1000)", log_cap=128)
        evidence = read_json(self.root / 'command/command.json')
        self.assertEqual(evidence['status'], 'failed')
        self.assertGreater((self.root / 'command/stdout.log').stat().st_size, 128)
        self.assertTrue(evidence['cleanup']['groupGone'])

    def test_target_gauge_then_hung_dump_is_killed_and_second_arm_never_starts(self):
        sidecar = self.root / 'sidecar'; sidecar.mkdir()
        gauge = self.root / 'ownership-gauges.jsonl'
        code = ("import json,time,signal; from pathlib import Path; "
                "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                f"Path({str(gauge)!r}).write_text(json.dumps(dict(sequence=0,id='cycle-0.released-quiet-end',cycle=0,phase='released-quiet-end',endUs=1))+'\\n'); "
                "time.sleep(30)")
        budget = PairBudget(time.monotonic())
        budget.start_arm('probe-only'); budget.hello()
        watcher = CutWatcher(sidecar, GaugeTail(gauge), 1, None)
        fixed = time.monotonic() + 14
        def watch(_):
            watcher.check()
        def deadline():
            return min(fixed, watcher.deadline())
        started = time.monotonic()
        with self.assertRaises(ContractError) as failed:
            run_command([sys.executable, '-c', code], self.root / 'hung-dump',
                cwd=self.root, environment=os.environ, deadline=deadline, watch=watch, application=True)
        budget.fail(failed.exception)
        with self.assertRaises(ContractError):
            budget.start_arm('product-with-ownership')
        self.assertLess(time.monotonic() - started, 12)
        record = read_json(self.root / 'hung-dump/command.json')
        self.assertTrue(record['cleanup']['groupGone'])
        self.assertEqual(budget.report()['notStarted'], ['product-with-ownership'])
        self.assertEqual(watcher.cuts, [])

    def test_existing_command_directory_cannot_be_reused(self):
        self.command('print(1)')
        with self.assertRaises(FileExistsError):
            self.command('print(2)')


class CaptureContracts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()

    def startup(self):
        return {'stackAttribution': {'schema': 'abc.gperftools-application-startup.v1',
            'arm': 'probe-only', 'hostPid': 123, 'targetPath': '/target', 'helperPath': '/helper',
            'allocatorPath': '/allocator', 'outputPath': '/output', 'initialization': {
                'statusCode': 0, 'runningVerifiedAtInitialization': True, 'clockDomain': CLOCK,
                'startUs': 1, 'endUs': 2, 'native': dict(abi=1,offline=0,initialized=1,failure=0,
                    slotsUsed=0,dumpCount=0,stopCalls=0,stopRequested=0,stopVerified=0,cleanupFailure=0,
                    observerPreallocatedBytes=2099000,observerMapsBytes=2097152,observerHeldFds=3,
                    observerClosedFds=0,observerFdCloseAttempts=0,observerFdCleanupFailure=0,
                    stopStartNs=0,stopEndNs=0)}}}

    def validate(self, hello):
        return validate_startup(hello,arm='probe-only',pid=123,target='/target',helper='/helper',allocator='/allocator',output='/output')

    def test_provider_offline_wrong_path_or_uninitialized_hello_rejected(self):
        self.validate(self.startup())
        for key, value in [('offline', 1), ('initialized', 0), ('failure', 2), ('dumpCount', 1)]:
            hello = self.startup(); hello['stackAttribution']['initialization']['native'][key] = value
            with self.subTest(key=key), self.assertRaises(ContractError):
                self.validate(hello)
        hello = self.startup(); hello['stackAttribution']['helperPath'] = '/wrong'
        with self.assertRaises(ContractError): self.validate(hello)

    def test_probe_environment_cannot_open_world_and_keeps_actual_ci(self):
        source = {'CI':'true','GITHUB_ACTIONS':'true','COMPUTERRARIA_WLD':'/original'}
        probe = runtime_environment(source, 'probe-only', self.root, Path('/old-helper'), Path('/new-helper'))
        product = runtime_environment(source, 'product-with-ownership', self.root, Path('/old-helper'), Path('/new-helper'))
        self.assertNotIn('COMPUTERRARIA_WLD', probe)
        self.assertEqual(product['COMPUTERRARIA_WLD'], '/original')
        self.assertEqual(probe['GITHUB_ACTIONS'], 'true')
        self.assertNotIn('LD_PRELOAD', product)
        self.assertNotIn('ABC_STACK_OUTPUT', product)

    def test_actual_entry_refuses_local_offline_or_retry(self):
        for env in ({}, {'CI':'true','GITHUB_ACTIONS':'true','GITHUB_REF':BRANCH,'GITHUB_RUN_ATTEMPT':'2'}):
            with self.assertRaises(ContractError): actual_ci_guard(env)

    def test_extra_exit_dump_and_receipt_before_gauge_fail(self):
        (self.root / 'heap.0003.heap').write_bytes(b'partial')
        with self.assertRaises(ContractError): exact_profile_files(self.root)
        (self.root / 'heap.0003.heap').unlink()
        (self.root / 'q0.receipt').write_bytes(b'partial')
        watcher = CutWatcher(self.root, GaugeTail(self.root / 'absent'), 1, None)
        with self.assertRaisesRegex(ContractError, 'before original quiet gauge'): watcher.check()

    def test_aggregate_sidecar_cap_counts_across_arm_directories(self):
        arms = [self.root / 'control', self.root / 'product']
        for root in arms:
            root.mkdir()
            with (root / 'retained.bin').open('wb') as stream:
                stream.truncate((MAX_SIDECAR // 2) + 1)
        with self.assertRaisesRegex(ContractError, 'aggregate'): sidecar_caps(arms)

    def test_original_image_failure_keeps_exact_original_guard_prefix(self):
        from memory_ownership_validate import OwnershipValidator
        from computer_memory_validate import require
        validator = object.__new__(OwnershipValidator)
        validator.errors = []
        validator.guard('ownership', lambda: require(False, 'product image callback observation never fired'))
        self.assertEqual(validator.errors, [KNOWN_IMAGE_FAILURE])

    def test_gauge_tail_handles_partial_lines_rejects_duplicate_or_truncation(self):
        path = self.root / 'gauges'
        data = json.dumps(dict(sequence=0,id='cycle-0.released-quiet-end',cycle=0,phase='released-quiet-end',endUs=1)).encode()+b'\n'
        path.write_bytes(data[:20]); tail=GaugeTail(path); tail.read_new(); self.assertFalse(tail.cuts)
        with path.open('ab') as stream: stream.write(data[20:])
        tail.read_new(); self.assertIn('q0',tail.cuts)
        path.write_bytes(b'')
        with self.assertRaises(ContractError): tail.read_new()


class ElfContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='abc-elf-identity-stub-')
        cls.root=Path(cls.tmp.name); cls.binary=cls.root/'inert-elf'
        source=cls.root/'inert.c'; source.write_text('#include <unistd.h>\nint main(void){sleep(30);return 0;}\n')
        subprocess.run(['cc','-g','-O0','-Wl,--build-id','-o',str(cls.binary),str(source)],check=True,timeout=20,
                       env=clean_environment(os.environ),capture_output=True)
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def test_actual_elf_metadata_bind_id_segments_and_exact_symbol_ranges(self):
        result=elf_metadata(self.binary.read_bytes())
        self.assertTrue(result['buildId']); self.assertTrue(result['ptLoad'])
        self.assertTrue(any(s['name']=='main' and s['size']>0 for s in result['symtab']))
        for mutation in (b'not ELF', self.binary.read_bytes()[:80]):
            with self.assertRaises(ContractError): elf_metadata(mutation)

    def test_endpoint_buckets_keep_integer_changes_and_unknown_functions(self):
        meta=elf_metadata(self.binary.read_bytes())
        main=next(row for row in meta['symtab'] if row['name']=='main')
        segment=next(row for row in meta['ptLoad'] if row['flags']&1 and row['vaddr']<=main['address']<row['vaddr']+row['memorySize'])
        bias=0x700000000000
        mapping=dict(path=str(self.binary),start=bias+(segment['vaddr']&~4095),
            end=bias+((segment['vaddr']+segment['memorySize']+4095)&~4095),permissions='r-xp')
        module=dict(meta,path=str(self.binary),loadBias=bias)
        pc=bias+main['address']
        first={'maps':[mapping],'buckets':[{'stack':(pc,), 'counters':(1,10,2,20)}]}
        last={'maps':[mapping],'buckets':[{'stack':(pc,), 'counters':(3,40,7,80)}]}
        result=endpoint_delta(first,last,{str(self.binary):module})
        self.assertEqual(result['allStackBuckets'][0]['delta'],[2,30,5,60])
        self.assertFalse(result['allStackBuckets'][0]['unknown'])
        module['dynsym']=[];module['symtab']=[]
        unknown=endpoint_delta(first,last,{str(self.binary):module})
        self.assertEqual(unknown['unknownBucketCount'],1)
        self.assertEqual(unknown['allStackBuckets'][0]['frames'][0]['exactRangeSymbolCandidates'],[])
        self.assertFalse(unknown['crossArmSubtraction'])

    def test_real_inert_process_maps_bind_modules_and_detect_new_maps(self):
        process=subprocess.Popen([str(self.binary)],start_new_session=True,env=clean_environment(os.environ))
        identity=modules=None
        try:
            expected=file_identity(self.binary)
            identity=TargetProcessIdentity(process.pid,owned_pgid=process.pid,expected_executable=self.binary,expected_sha256=expected['sha256'])
            with tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary)
                modules=BoundModules(identity,{str(self.binary):expected},root/'modules',root/'evidence',
                    deadline=time.monotonic()+10,cap_check=lambda **kw: None)
                modules.verify_cut({'fileExecutableMaps':list(modules.executable_keys)})
                with self.assertRaises(ContractError): modules.verify_cut({'fileExecutableMaps':[]})
                modules.rehash(time.monotonic()+10)
                self.assertIn(str(self.binary),modules.records)
        finally:
            if modules:modules.close()
            if identity:identity.close()
            self.assertTrue(cleanup_owned_group(process,deadline=time.monotonic()+2)['groupGone'])


    def test_presealed_lazy_module_binds_without_preloading_and_rejects_changed_or_unknown(self):
        binary = self.binary
        source = self.root / 'lazy.c'
        source.write_text('int delayed_function(int value){return value+1;}\n')
        lazy = self.root / 'lazy.so'
        subprocess.run(['cc','-g','-shared','-fPIC','-Wl,--build-id','-o',str(lazy),str(source)],
                       check=True,timeout=20,capture_output=True,env=clean_environment(os.environ))
        process = subprocess.Popen([str(binary)],start_new_session=True,env=clean_environment(os.environ))
        identity = modules = None
        try:
            expected, delayed = file_identity(binary), file_identity(lazy)
            identity = TargetProcessIdentity(process.pid,owned_pgid=process.pid,
                expected_executable=binary,expected_sha256=expected['sha256'])
            with tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary)
                modules=BoundModules(identity,{str(binary):expected},root/'modules',root/'evidence',
                    deadline=time.monotonic()+10,cap_check=lambda **kw: None,presealed={str(lazy):delayed})
                self.assertIn(str(lazy),modules.deferred)
                self.assertNotIn(str(lazy),modules.records)
                self.assertFalse(modules.deferred[str(lazy)]['loadedAtStartup'])
                segment = next(row for row in modules.deferred[str(lazy)]['ptLoad'] if row['flags'] & 1)
                bias = 0x700000000000
                row=dict(start=bias+(segment['vaddr']&~4095),
                    end=bias+((segment['vaddr']+segment['memorySize']+4095)&~4095),
                    permissions='r-xp',offset=segment['offset']&~4095,
                    inode=delayed['inode'],device=(os.major(delayed['device']),os.minor(delayed['device'])),path=str(lazy))
                bracket={'fileExecutableMaps':[*modules.executable_keys,map_key(row)],'before':[row]}
                bad=copy.deepcopy(bracket);bad['before'][0]['inode']+=1
                with self.assertRaisesRegex(ContractError,'device/inode'):modules.verify_cut(bad)
                unknown=copy.deepcopy(bracket);unknown['fileExecutableMaps'][-1]=tuple(list(map_key(row))[:-1]+['/unsealed.so'])
                with self.assertRaisesRegex(ContractError,'not presealed'):modules.verify_cut(unknown)
                modules.verify_cut(bracket)
                self.assertNotIn(str(lazy),modules.deferred)
                self.assertTrue(modules.records[str(lazy)]['loadedIdentityProven'])
                self.assertFalse(modules.records[str(lazy)]['loadedAtStartup'])
                self.assertEqual(len(modules.transitions),1)
                # Mutating the retained inode invalidates later receipt validation.
                with lazy.open('ab') as stream:stream.write(b'x')
                with self.assertRaisesRegex(ContractError,'metadata changed'):modules.verify_cut(bracket)
        finally:
            if modules:modules.close()
            if identity:identity.close()
            self.assertTrue(cleanup_owned_group(process,deadline=time.monotonic()+2)['groupGone'])


class SourceContracts(unittest.TestCase):
    def fixture(self):
        row={'mode':'100644','blob':'a'*40}
        base={f'base/{i}':dict(row) for i in range(886)}
        inherited={**base,TARGET:dict(row)}
        current={**inherited,TARGET:{**row,'blob':'b'*40},MANIFEST:dict(row),NEW_WORKFLOW:dict(row)}
        manifest=dict(schema='abc.gperftools-application-source-manifest.v1',baseCommit=BASE,baseTree=BASE_TREE,
            inheritedCommit=INHERITED,packageGateCommit=PACKAGE_GATE,branch=BRANCH,
            directParentCommit=DIRECT_PARENT,directParentTree=DIRECT_PARENT_TREE,
            files={k:dict(v) for k,v in current.items() if k!=MANIFEST},inheritedFiles=copy.deepcopy(inherited))
        return manifest,base,inherited,current
    def test_whole_tree_protects_original_product_and_diagnostic(self):
        values=self.fixture(); self.assertTrue(verify_layers(*values))
        values=self.fixture(); values[3]['base/1']['blob']='c'*40
        with self.assertRaises(ValueError): verify_layers(*values)
    def test_unknown_added_path_or_missing_inherited_inventory_fails(self):
        values=self.fixture(); values[3]['lib/new_feature.dart']={'mode':'100644','blob':'d'*40}
        values[0]['files']['lib/new_feature.dart']=values[3]['lib/new_feature.dart']
        with self.assertRaises(ValueError): verify_layers(*values)
        values=self.fixture(); del values[0]['inheritedFiles']['base/0']
        with self.assertRaises(ValueError): verify_layers(*values)


class CorrectionSourceContracts(unittest.TestCase):
    def fixture(self):
        head='e'*40
        old={'mode':'100644','blob':'a'*40}
        new={'mode':'100644','blob':'b'*40}
        parent={name:dict(old) for name in CORRECTION_PATHS if name != PREFIX_TEST}
        parent.update({name:dict(old) for name in (
            'lib/main.dart', 'native/abc_owner_diagnostics.c',
            'integration_test/computer_memory_ownership_test.dart',
            'integration_test/computer_memory_diagnostic_test.dart',
            'integration_test/support/generic_circuit_profile.dart',
            'tool/perf/memory_ownership_schedule.json', NEW_WORKFLOW,
            'tool/perf/gperftools_application/run_pair.py')})
        current=copy.deepcopy(parent)
        current.update({name:dict(new) for name in CORRECTION_PATHS})
        return head,[head,DIRECT_PARENT],DIRECT_PARENT_TREE,parent,current

    def test_accepts_only_exact_correction_on_fixed_parent_and_tree(self):
        self.assertEqual(verify_correction_parent(*self.fixture()),sorted(CORRECTION_PATHS))

    def test_wrong_parent_old_base_merge_or_tree_rejected(self):
        for parents in (['e'*40,BASE],['e'*40,'f'*40],['e'*40,DIRECT_PARENT,BASE],['e'*40]):
            values=list(self.fixture());values[1]=parents
            with self.subTest(parents=parents),self.assertRaisesRegex(ValueError,'fixed diagnostic parent'):
                verify_correction_parent(*values)
        values=list(self.fixture());values[2]='f'*40
        with self.assertRaisesRegex(ValueError,'parent tree differs'):
            verify_correction_parent(*values)

    def test_extra_added_deleted_or_missing_correction_path_rejected(self):
        values=self.fixture();values[4]['tool/perf/gperftools_application/extra.py']={'mode':'100644','blob':'c'*40}
        with self.assertRaises(ValueError):verify_correction_parent(*values)
        values=self.fixture();del values[4]['lib/main.dart']
        with self.assertRaises(ValueError):verify_correction_parent(*values)
        values=self.fixture();values[4][MANIFEST]=dict(values[3][MANIFEST])
        with self.assertRaises(ValueError):verify_correction_parent(*values)

    def test_product_workload_schedule_roi_workflow_and_budget_changes_rejected(self):
        for name in ('lib/main.dart','native/abc_owner_diagnostics.c',TARGET,
                     'integration_test/computer_memory_diagnostic_test.dart',
                     'integration_test/support/generic_circuit_profile.dart',
                     'tool/perf/memory_ownership_schedule.json',NEW_WORKFLOW,
                     'tool/perf/gperftools_application/run_pair.py'):
            values=self.fixture();values[4][name]['blob']='d'*40
            with self.subTest(name=name),self.assertRaisesRegex(ValueError,'exact five-path'):
                verify_correction_parent(*values)

    def test_correction_mode_or_symlink_changes_rejected(self):
        for mode in ('100755','120000'):
            for name in CORRECTION_PATHS:
                values=self.fixture();values[4][name]['mode']=mode
                with self.subTest(name=name,mode=mode),self.assertRaisesRegex(ValueError,'regular non-executable'):
                    verify_correction_parent(*values)
        values=self.fixture();values[3][MANIFEST]['mode']='100755'
        with self.assertRaisesRegex(ValueError,'regular non-executable'):
            verify_correction_parent(*values)

    def test_layer_manifest_wrong_or_missing_parent_pins_rejected(self):
        for field in ('directParentCommit','directParentTree'):
            for missing in (False,True):
                values=SourceContracts().fixture()
                if missing:del values[0][field]
                else:values[0][field]='f'*40
                with self.subTest(field=field,missing=missing),self.assertRaisesRegex(ValueError,'Source layer pins'):
                    verify_layers(*values)


if __name__ == '__main__':
    unittest.main(verbosity=2)
