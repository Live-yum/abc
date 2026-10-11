"""Offline orchestration/source/weighted-output contracts; never starts SDK."""
import copy
import json
import math
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from sampled_source import (validate_overlay, verify_historical_parent, PARENT, PARENT_TREE, MANIFEST,
    TARGET, BRIDGE, WORKFLOW, BRANCH, BASE, BASE_TREE, INHERITED, HISTORICAL_PARENT, HISTORICAL_PARENT_TREE)
from sampled_contract import PERIOD
from sampled_pprof import validate_weighted_raw, check_sampled_diagnostics
from run_sampled_q0 import (SampledRunner, ci_guard, sampled_commands, sample_environment, BUDGETS,
                           close_retained, SampledBoundModules, verify_development_header, HEADER, HEADER_BYTES, HEADER_SHA)
from small_target_exec import open_sealed, close_once_all
from sampled_seal_config import file_identity


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.parent = {'lib/product.dart': {'mode': '100644', 'blob': 'a'},
                       'tool/perf/memory_ownership_schedule.json': {'mode': '100644', 'blob': 'b'}}
        self.new = {name: {'mode': '100644', 'blob': 'c'} for name in (TARGET, BRIDGE, WORKFLOW, MANIFEST)}
        self.current = self.parent | self.new
        self.manifest = dict(schema='abc.sampled-source-manifest.v1', parentCommit=PARENT,
                             parentTree=PARENT_TREE, addedFiles={name: {} for name in self.new if name != MANIFEST})

    def test_additive_exact(self):
        self.assertEqual(validate_overlay(self.parent, self.current, self.manifest), sorted(self.new))

    def test_wrong_parent(self):
        self.manifest['parentCommit'] = '0' * 40
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_wrong_parent_tree(self):
        self.manifest['parentTree'] = '0' * 40
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_product_mutation(self):
        self.current['lib/product.dart'] = {'mode': '100644', 'blob': 'x'}
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_workload_mutation(self):
        del self.current['tool/perf/memory_ownership_schedule.json']
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_extra_path(self):
        self.current['lib/extra.dart'] = {'mode': '100644', 'blob': 'x'}
        self.manifest['addedFiles']['lib/extra.dart'] = {}
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_unsealed_path(self):
        self.current['tool/perf/gperftools_sampled/unknown.py'] = {'mode': '100644', 'blob': 'x'}
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_symlink(self):
        self.current[TARGET]['mode'] = '120000'
        with self.assertRaises(ValueError): validate_overlay(self.parent, self.current, self.manifest)

    def test_historical_parent_replays_pure_contracts_not_event_cli(self):
        row = {'mode': '100644', 'blob': 'a'}
        actual = dict(row, bytes=1, sha256='0' * 64)
        manifest = {'inheritedFiles': {'file': actual}, 'files': {'file': actual}}
        def git_value(root, *args):
            root = str(root)
            if args[:2] == ('status', '--porcelain'): return ''
            if args[:2] == ('rev-list', '--parents'): return PARENT + ' ' + HISTORICAL_PARENT
            if args == ('rev-parse', HISTORICAL_PARENT + '^{tree}'): return HISTORICAL_PARENT_TREE
            if args == ('rev-parse', 'HEAD'): return {'/parent': PARENT, '/base': BASE, '/original': INHERITED}[root]
            if args == ('rev-parse', 'HEAD^{tree}'): return {'/parent': PARENT_TREE, '/base': BASE_TREE}[root]
            raise AssertionError(args)
        with patch('sampled_source.git', side_effect=git_value), patch('sampled_source.tree', return_value={'file': row}), \
             patch('sampled_source.read_json', return_value=manifest), patch('sampled_source.identity', return_value=actual), \
             patch('sampled_source.verify_layers') as layers, patch('sampled_source.verify_correction_parent', return_value=['reviewed']) as correction, \
             patch.dict(os.environ, {'GITHUB_REF': BRANCH, 'GITHUB_SHA': 'f' * 40}):
            result = verify_historical_parent(Path('/parent'), Path('/base'), Path('/original'))
            self.assertTrue(result['historicalEventWasNotExecutedOrImpersonated'])
            self.assertEqual(os.environ['GITHUB_REF'], BRANCH)
            self.assertEqual(os.environ['GITHUB_SHA'], 'f' * 40)
            layers.assert_called_once(); correction.assert_called_once()
            self.assertEqual(correction.call_args.args[:3], (PARENT, [PARENT, HISTORICAL_PARENT], HISTORICAL_PARENT_TREE))

    def test_historical_wrong_parent_stops_before_content(self):
        with patch('sampled_source.git', return_value='0' * 40), patch('sampled_source.tree') as tree:
            with self.assertRaises(ValueError): verify_historical_parent(Path('/parent'), Path('/base'), Path('/original'))
            tree.assert_not_called()


class OrchestrationTests(unittest.TestCase):
    def test_independent_workflow_no_old_pair_or_map(self):
        path = Path(__file__).resolve().parents[3] / WORKFLOW
        text = path.read_text()
        self.assertIn('branches: [codex/sampled-q0-feasibility-9d4]', text)
        self.assertNotIn('run_pair.py', text)
        self.assertNotIn('python3 build/sampled-parent/tool/perf/gperftools_application/application_source.py', text)
        self.assertNotIn('computerraria_inputs.py', text)
        self.assertNotIn('COMPUTERRARIA_WLD=', text)
        self.assertIn('cancel-in-progress: false', text)
        self.assertIn('contents: read', text)
        self.assertNotIn('contents: write', text)
        self.assertEqual(text.count('python3 tool/perf/gperftools_sampled/run_sampled_q0.py'), 1)

    def test_ci_guard(self):
        env = dict(CI='true', GITHUB_ACTIONS='true', GITHUB_REF=BRANCH, GITHUB_RUN_ATTEMPT='1')
        ci_guard(env)
        for key, value in [('CI', 'false'), ('GITHUB_REF', 'refs/heads/codex/memory-allocation-application-9d4'),
                           ('GITHUB_RUN_ATTEMPT', '2'), ('COMPUTERRARIA_WLD', '/x/world.wld')]:
            with self.subTest(key=key), self.assertRaises(ValueError): ci_guard(env | {key: value})

    def test_only_independent_entry(self):
        result = sampled_commands('/sdk/flutter', '/sealed/launcher', 'f' * 40, 'llvmpipe')
        for kind, argv in result.items():
            self.assertIn('--target=' + TARGET, argv)
            self.assertIn('--dart-define=ABC_SAMPLED_DIAGNOSTIC=true', argv)
            self.assertFalse(any('computer_memory_ownership_test.dart' in value for value in argv))
            self.assertEqual(argv.count('--target=' + TARGET), 1)
        self.assertIn('--use-application-binary=/sealed/launcher', result['drive'])

    def test_target_only_environment(self):
        env = sample_environment(dict(LD_PRELOAD='evil', HEAPPROFILE='evil', TCMALLOC_SAMPLE_PARAMETER='4',
            ABC_STACK_HELPER='evil', ABC_SAMPLED_DIAGNOSTIC='1', COMPUTERRARIA_WLD='/world', CI='true'),
            Path('/output'), Path('/owner.so'), Path('/sample.so'))
        for key in ('LD_PRELOAD', 'HEAPPROFILE', 'TCMALLOC_SAMPLE_PARAMETER', 'ABC_STACK_HELPER', 'ABC_SAMPLED_DIAGNOSTIC', 'COMPUTERRARIA_WLD'):
            self.assertNotIn(key, env)
        self.assertEqual(env['MEMORY_OWNER_ARM'], 'probe-only')
        self.assertEqual(env['ABC_SAMPLED_HELLO'], '/output/sampled-hello.json')

    def test_original_budgets(self):
        for key, value in dict(totalSeconds=2000, armSeconds=900, buildHelloSeconds=300,
            runtimeSeconds=600, identitySeconds=60, hookSeconds=10, ackSeconds=2, analysisSeconds=120,
            rawEachExclusiveBytes=1 << 20, sidecarTotalBytes=256 << 20, mapsTotalBytes=10 << 20).items():
            self.assertEqual(BUDGETS[key], value)

    def test_small_failure_blocks_build(self):
        instance = object.__new__(SampledRunner)
        instance.result = {'status': 'running'}
        with patch.object(instance, 'small_contract', side_effect=ValueError('small failed')), \
             patch.object(instance, 'build') as build, patch.object(instance, 'drive') as drive, \
             patch.object(instance, 'persist'):
            with self.assertRaisesRegex(ValueError, 'small failed'): instance.run()
            build.assert_not_called(); drive.assert_not_called()
            self.assertEqual(instance.result['status'], 'failed')

    def test_inconclusive_not_retried(self):
        instance = object.__new__(SampledRunner)
        instance.result = {'status': 'inconclusive-known-allocation-not-sampled'}
        with patch.object(instance, 'small_contract', side_effect=ValueError('not sampled')) as small, \
             patch.object(instance, 'build') as build, patch.object(instance, 'persist'):
            with self.assertRaises(ValueError): instance.run()
            self.assertEqual(small.call_count, 1); build.assert_not_called()
            self.assertEqual(instance.result['status'], 'inconclusive-known-allocation-not-sampled')

    def test_build_requires_real_small_result(self):
        instance = object.__new__(SampledRunner); instance.result = {}
        with self.assertRaisesRegex(ValueError, 'Small contract'): instance.build()

    def test_retained_small_fd_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'synthetic'; path.write_bytes(b'synthetic bytes only')
            identity = file_identity(path)
            fd = open_sealed(identity)
            try: self.assertEqual(os.fstat(fd).st_ino, identity['inode'])
            finally: os.close(fd)
            path.write_bytes(b'changed bytes')
            with self.assertRaises(ValueError): open_sealed(identity)

    def test_cleanup_attempts_all_descriptors_without_retry(self):
        class Target: pass
        target = Target(); target.exe_fd = 8; target.proc_fd = 9
        owner = Target(); owner.fd = 10
        with patch('run_sampled_q0.os.close', side_effect=[OSError(4, 'interrupted'), None, None]) as close:
            errors = close_retained([('target', target, ('exe_fd', 'proc_fd')), ('owner', owner, ('fd',))])
        self.assertEqual([call.args[0] for call in close.call_args_list], [8, 9, 10])
        self.assertEqual(len(errors), 1); self.assertFalse(errors[0]['retried'])
        self.assertIsNone(target.exe_fd); self.assertIsNone(target.proc_fd); self.assertIsNone(owner.fd)

    def test_module_close_failure_keeps_closing(self):
        modules = object.__new__(SampledBoundModules)
        modules.held = {'first': (11, None), 'second': (12, None)}
        with patch('run_sampled_q0.os.close', side_effect=[OSError(4, 'interrupted'), None]) as close:
            modules.close(); modules.close()
        self.assertEqual(close.call_count, 2)
        self.assertEqual(modules.held, {})
        self.assertEqual(len(modules.sampled_close_errors), 1)

    def test_small_close_preserves_first_failure_and_attempts_all(self):
        original = ValueError('original exec failure')
        with patch('small_target_exec.os.close', side_effect=[OSError(4, 'interrupted'), None]) as close:
            close_once_all((19, 20), original)
        self.assertEqual(close.call_count, 2)
        self.assertEqual(str(original), 'original exec failure')
        self.assertTrue(original.__notes__)

    def test_official_header_identity(self):
        proof = {'packageIdentity': {'libgoogle-perftools-dev': {'installedFiles': {
            HEADER: {'bytes': HEADER_BYTES, 'sha256': HEADER_SHA}}}}}
        with patch('run_sampled_q0.file_identity', return_value={'path': HEADER, 'bytes': HEADER_BYTES, 'sha256': HEADER_SHA}):
            self.assertEqual(verify_development_header(proof, 100)['sha256'], HEADER_SHA)
        with patch('run_sampled_q0.file_identity', return_value={'path': HEADER, 'bytes': HEADER_BYTES, 'sha256': '0' * 64}):
            with self.assertRaises(ValueError): verify_development_header(proof, 100)


class WeightedOutputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / 'weighted.raw'
        self.sample = {'schema': 'abc.tcmalloc-live-sample.v1', 'mode': 'sampled', 'samplePeriodBytes': PERIOD,
            'rawSha256': '0' * 64, 'sampleRecords': [
            {'rawSampleCounts': (1, 1024, 1, 1024), 'stack': (0x100, 0x201)},
            {'rawSampleCounts': (1, 2048, 1, 2048), 'stack': (0x100, 0x201)}]}

    def tearDown(self): self.directory.cleanup()

    def write(self, value, stack=(0x100, 0x200), symbols=b''):
        self.path.write_bytes(b'--- symbol\nbinary=/synthetic\n' + symbols + b'---\n--- profile\n' +
            struct.pack('<5Q', 0, 3, 0, 1, 0) + struct.pack('<2Q', value, len(stack)) + struct.pack('<' + 'Q' * len(stack), *stack))

    def expected(self, index):
        return int(sum(row['rawSampleCounts'][index] / (1 - math.exp(-row['rawSampleCounts'][1] / PERIOD)) for row in self.sample['sampleRecords']))

    def test_weighted_bytes(self):
        self.write(self.expected(1))
        value = validate_weighted_raw(self.path, '/synthetic', self.sample, 'inuse_space')
        self.assertTrue(value['estimateNotExact']); self.assertFalse(value['fullHeapCoverage'])

    def test_weighted_objects(self):
        self.write(self.expected(0))
        self.assertEqual(validate_weighted_raw(self.path, '/synthetic', self.sample, 'inuse_objects')['serializedEstimatedTotal'], self.expected(0))

    def test_unweighted_fails(self):
        self.write(3072)
        with self.assertRaises(ValueError): validate_weighted_raw(self.path, '/synthetic', self.sample, 'inuse_space')

    def test_missing_record_fails(self):
        self.write(self.expected(1) - 1)
        with self.assertRaises(ValueError): validate_weighted_raw(self.path, '/synthetic', self.sample, 'inuse_space')

    def test_exact_official_allocator_filter(self):
        self.write(self.expected(1), stack=(0x200,), symbols=b'0x100 malloc\n')
        result = validate_weighted_raw(self.path, '/synthetic', self.sample, 'inuse_space')
        self.assertEqual(result['allocatorFramePcsRemovedByOfficialTool'], [0x100])

    def test_unknown_stack_retained(self):
        self.write(self.expected(1), stack=(0x999,))
        with self.assertRaises(ValueError): validate_weighted_raw(self.path, '/synthetic', self.sample, 'inuse_space')

    def test_notices_required(self):
        data = b'Using local file /synthetic.\nAdjusting heap profiles for 1-in-524288 sampling rate\nHeap version 2\n'
        check_sampled_diagnostics(data)
        result = check_sampled_diagnostics(data + b'WARNING missing external debug\n')
        self.assertEqual(result['additionalDiagnostics'], ['WARNING missing external debug'])
        self.assertFalse(result['symbolizationCompletenessProven'])
        with self.assertRaises(ValueError): check_sampled_diagnostics(b'')


if __name__ == '__main__': unittest.main()
