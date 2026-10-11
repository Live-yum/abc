"""Offline orchestration/source/weighted-output contracts; never starts SDK."""
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from sampled_source import (validate_overlay, verify_historical_parent, PARENT, PARENT_TREE, MANIFEST,
    TARGET, BRIDGE, WORKFLOW, BRANCH, BASE, BASE_TREE, INHERITED, HISTORICAL_PARENT, HISTORICAL_PARENT_TREE,
    DIRECT_PARENT, DIRECT_PARENT_TREE, CORRECTION_PATHS, REVIEWED_FIXTURE_SHA256,
    validate_correction_parent, validate_correction_bytes, verify_correction,
    build_correction_manifest, ORIGINAL_ADDED_PATHS)
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


class FixtureCorrectionSourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='sampled-correction-source-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.head = 'f' * 40
        self.base = {name: {'mode': '100644', 'blob': 'original'} for name in
                     ('lib/product.dart', 'tool/perf/memory_ownership_schedule.json',
                      'integration_test/computer_memory_ownership_test.dart')}
        paths = set(CORRECTION_PATHS) | {TARGET, BRIDGE}
        for index in range(ORIGINAL_ADDED_PATHS - len(paths)):
            paths.add(f'tool/perf/gperftools_sampled/synthetic-{index}.py')
        self.parent = self.base | {name: {'mode': '100644', 'blob': 'frozen'} for name in paths}
        self.current = copy.deepcopy(self.parent)
        for name in CORRECTION_PATHS:
            self.current[name]['blob'] = 'corrected'
        self.workflow = (b'permissions:\n  contents: read\n'
            b'          fetch-depth: 2\n          persist-credentials: false\n'
            b'          ref: frozen-2b\n          fetch-depth: 2\n'
            b'          path: build/sampled-parent\n')
        self.changed_workflow = self.workflow.replace(b'fetch-depth: 2', b'fetch-depth: 3', 1)
        (self.root / WORKFLOW).parent.mkdir(parents=True)
        (self.root / WORKFLOW).write_bytes(self.changed_workflow)
        self.data = {name: ('synthetic frozen ' + name).encode() for name in paths - {MANIFEST}}
        self.data[WORKFLOW] = self.workflow
        self.parent_manifest = {'schema': 'abc.sampled-source-manifest.v1',
            'parentCommit': PARENT, 'parentTree': PARENT_TREE, 'branch': BRANCH,
            'addedFiles': {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                           for name, data in self.data.items()}}
        self.manifest = copy.deepcopy(self.parent_manifest)
        self.manifest.update(directParentCommit=DIRECT_PARENT, directParentTree=DIRECT_PARENT_TREE,
            correctionPaths=sorted(CORRECTION_PATHS), reviewedFixtureSha256=dict(REVIEWED_FIXTURE_SHA256))
        self.files = {name: {'sha256': digest} for name, digest in REVIEWED_FIXTURE_SHA256.items()}

    def topology(self, **changes):
        values = dict(head=self.head, parents=[self.head, DIRECT_PARENT],
            parent_tree_sha=DIRECT_PARENT_TREE, parent=self.parent, current=self.current)
        values.update(changes)
        return validate_correction_parent(**values)

    def git_value(self, root, *args, binary=False):
        if args == ('rev-list', '--parents', '-n', '1', self.head): return self.head + ' ' + DIRECT_PARENT
        if args == ('rev-list', '--parents', '-n', '1', DIRECT_PARENT): return DIRECT_PARENT + ' ' + PARENT
        if args == ('rev-parse', DIRECT_PARENT + '^{tree}'): return DIRECT_PARENT_TREE
        if args == ('rev-parse', PARENT + '^{tree}'): return PARENT_TREE
        if args == ('show', DIRECT_PARENT + ':' + MANIFEST): return json.dumps(self.parent_manifest)
        if args[0] == 'show' and args[1].startswith(DIRECT_PARENT + ':'):
            self.assertTrue(binary)
            return self.data[args[1].split(':', 1)[1]]
        raise AssertionError(args)

    def verify(self):
        with patch('sampled_source.git', side_effect=self.git_value), \
             patch('sampled_source.tree', side_effect=lambda root, ref: {PARENT: self.base, DIRECT_PARENT: self.parent}[ref]):
            return verify_correction(self.root, self.head, self.current, self.manifest, self.files)

    def test_exact_six_paths_replay_original_34_path_seal(self):
        self.assertEqual(self.verify(), sorted(CORRECTION_PATHS))
        self.assertEqual(len(self.parent_manifest['addedFiles']) + 1, 34)

    def test_wrong_parent_merge_parent_and_wrong_tree_rejected(self):
        for parents in ([self.head, PARENT], [self.head, DIRECT_PARENT, PARENT], [self.head]):
            with self.subTest(parents=parents), self.assertRaises(ValueError): self.topology(parents=parents)
        with self.assertRaises(ValueError): self.topology(parent_tree_sha='0' * 40)

    def test_added_deleted_extra_or_missing_correction_path_rejected(self):
        changes = []
        added = copy.deepcopy(self.current); added['tool/perf/gperftools_sampled/extra.py'] = {'mode': '100644', 'blob': 'new'}; changes.append(added)
        deleted = copy.deepcopy(self.current); del deleted[TARGET]; changes.append(deleted)
        missing = copy.deepcopy(self.current); missing[MANIFEST] = self.parent[MANIFEST]; changes.append(missing)
        for name in (TARGET, BRIDGE, *self.base):
            extra = copy.deepcopy(self.current); extra[name]['blob'] = 'unreviewed'; changes.append(extra)
        for current in changes:
            with self.subTest(current=current), self.assertRaises(ValueError): self.topology(current=current)

    def test_correction_modes_remain_regular_nonexecutable(self):
        for mode in ('100755', '120000'):
            current = copy.deepcopy(self.current); current[MANIFEST]['mode'] = mode
            with self.subTest(mode=mode), self.assertRaises(ValueError): self.topology(current=current)

    def test_fixed_fixture_bytes_and_only_first_checkout_change(self):
        validate_correction_bytes(self.workflow, self.changed_workflow, self.files)
        for name in REVIEWED_FIXTURE_SHA256:
            files = copy.deepcopy(self.files); files[name]['sha256'] = '0' * 64
            with self.subTest(name=name), self.assertRaises(ValueError):
                validate_correction_bytes(self.workflow, self.changed_workflow, files)
        for workflow in (self.workflow, self.changed_workflow.replace(b'contents: read', b'contents: write'),
                         self.workflow.replace(b'fetch-depth: 2', b'fetch-depth: 3'), self.changed_workflow + b'extra-trigger\n'):
            with self.subTest(workflow=workflow), self.assertRaises(ValueError):
                validate_correction_bytes(self.workflow, workflow, self.files)

    def test_original_c9_seal_is_checked_against_c9_bytes(self):
        self.data[TARGET] += b'changed'
        with self.assertRaisesRegex(ValueError, 'Original sampled c9 seal bytes'): self.verify()

    def test_original_c9_parent_and_2b_tree_are_still_pinned(self):
        original = self.git_value
        for target, replacement in (
            (('rev-list', '--parents', '-n', '1', DIRECT_PARENT), DIRECT_PARENT + ' ' + '0' * 40),
            (('rev-parse', PARENT + '^{tree}'), '0' * 40)):
            def changed(root, *args, binary=False):
                return replacement if args == target else original(root, *args, binary=binary)
            with self.subTest(target=target), patch.object(self, 'git_value', side_effect=changed), self.assertRaises(ValueError):
                self.verify()

    def test_original_product_and_workload_still_match_2b(self):
        for name in self.base:
            previous = self.parent[name]
            self.parent[name] = {'mode': '100644', 'blob': 'changed-in-c9'}
            self.current[name] = dict(self.parent[name])
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'frozen product/workload'):
                self.verify()
            self.parent[name] = previous; self.current[name] = dict(previous)

    def test_manifest_direct_pins_and_exact_scope_required(self):
        for key, value in (('directParentCommit', PARENT), ('directParentTree', PARENT_TREE),
                           ('correctionPaths', []), ('reviewedFixtureSha256', {}), ('branch', 'other')):
            previous = self.manifest[key]; self.manifest[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'seal pins or scope'): self.verify()
            self.manifest[key] = previous

    def test_seal_plan_is_deterministic_and_excludes_self_hash(self):
        for name, data in self.data.items():
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        first = build_correction_manifest(self.root, self.parent_manifest)
        self.assertNotIn(MANIFEST, first['addedFiles'])
        (self.root / MANIFEST).write_text('Different manifest bytes must not feed their own hash')
        self.assertEqual(build_correction_manifest(self.root, self.parent_manifest), first)
        self.assertEqual(first['parentCommit'], PARENT)
        self.assertEqual(first['directParentCommit'], DIRECT_PARENT)

    def test_depth_three_local_git_retains_required_history_shape(self):
        # Genuine local Git objects test shallow-history behavior separately
        # from fixed c9/2b SHA checks. These synthetic SHAs are not substitutes
        # for verification of the actual remote commits.
        origin = self.root / 'origin'; origin.mkdir()
        env = os.environ | {'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
            'GIT_AUTHOR_NAME': 'Offline Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
            'GIT_COMMITTER_NAME': 'Offline Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
        def command(path, *args, check=True):
            return subprocess.run(['git', *args], cwd=path, env=env, check=check,
                capture_output=True, text=True, timeout=20)
        command(origin, 'init', '--quiet')
        commits = []
        for value in ('older ancestor', 'original 2b shape', 'sampled c9 shape', 'fixture correction shape'):
            (origin / 'source.txt').write_text(value)
            command(origin, 'add', 'source.txt'); command(origin, 'commit', '--quiet', '-m', value)
            commits.append(command(origin, 'rev-parse', 'HEAD').stdout.strip())
        for depth in (2, 3):
            clone = self.root / ('depth-' + str(depth))
            command(self.root, 'clone', '--quiet', '--depth', str(depth), origin.as_uri(), str(clone))
            self.assertEqual(command(clone, 'rev-list', '--parents', '-n', '1', commits[3]).stdout.split(), commits[3:1:-1])
            parents = command(clone, 'rev-list', '--parents', '-n', '1', commits[2]).stdout.split()
            if depth == 3:
                self.assertEqual(parents, [commits[2], commits[1]])
                self.assertEqual(command(clone, 'show', commits[1] + ':source.txt').stdout, 'original 2b shape')
                self.assertEqual(command(clone, 'rev-parse', commits[1] + '^{tree}').returncode, 0)
                self.assertEqual(command(clone, 'show', commits[2] + ':source.txt').stdout, 'sampled c9 shape')
            else:
                self.assertEqual(parents, [commits[2]])
                self.assertNotEqual(command(clone, 'cat-file', '-e', commits[1] + '^{tree}', check=False).returncode, 0)


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
