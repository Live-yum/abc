"""Evidence joins and CI isolation must fail closed on incomplete/fake coverage."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import compare_ci
from compare_ci import load_group
from coverage_report import build_coverage


def core_report():
    return {'schema': 'abc.performance.v1', 'suite': 'test', 'status': 'passed',
            'runtime': 'test-runtime', 'buildMode': 'release', 'tier': 'ci',
            'source': {'commit': 'a' * 40, 'worktreeCommit': 'a' * 40, 'dirty': False},
            'fixtures': [{'id': 'synthetic', 'sha256': 'b' * 64}],
            'operations': [{'id': 'wld.open', 'fixture': 'synthetic', 'phase': 'warm',
                            'iterations': 3, 'warmup': 1, 'samplesMs': [1, 2, 3],
                            'medianMs': 2, 'p95Ms': 3, 'maxMs': 3}],
            'memory': [{'cycle': 0, 'phase': 'after-close', 'ownedHandles': 0,
                        'rssBytes': 100}], 'methodology': {'warmupCycles': 1, 'measuredCycles': 3}}


def write_attempt(root, number, run_id=None):
    report = root / f'test.run-{number}.json'
    report.write_text(json.dumps(core_report()))
    execution = {'schema': 'abc.performance-execution.v1', 'report': report.name,
                 'status': 'passed', 'runId': run_id or f'process-{number}',
                 'reportSha256': hashlib.sha256(report.read_bytes()).hexdigest(),
                 'source': {'commit': 'a' * 40, 'checkedOutHead': 'a' * 40, 'dirty': False},
                 'machine': {'cpuModel': 'controlled-fixture'}}
    report.with_suffix('.execution.json').write_text(json.dumps(execution))


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.inventory = {'actions': [
            {'controller': 'Workspace', 'action': 'open', 'operationIds': ['workspace.open'],
             'availability': 'available', 'reason': 'not measured'},
            {'controller': 'Workspace', 'action': 'edit', 'operationIds': ['workspace.edit-a', 'workspace.edit-b'],
             'availability': 'available', 'reason': 'only measured variants count'}]}

    def test_core_api_never_covers_ui_action(self):
        report = build_coverage(self.inventory, [('core.json', core_report())], [])
        self.assertEqual(report['actions'][0]['status'], 'gap')
        self.assertFalse(report['actions'][0]['profileDispatchMeasured'])
        self.assertEqual(report['rows'][0]['category'], 'core-api')

    def test_measured_variant_keeps_other_variant_gap(self):
        source = core_report()
        source['operations'][0]['id'] = 'workspace.edit-a'
        report = build_coverage(self.inventory, [('core.json', source)], [])
        action = report['actions'][1]
        self.assertEqual(action['measuredCoreOperations'], ['workspace.edit-a'])
        self.assertEqual(action['missingCoreOperations'], ['workspace.edit-b'])
        self.assertFalse(action['profileDispatchMeasured'])

    def test_profile_controller_does_not_invent_frames(self):
        source = core_report()
        source.update(suite='flutter-ui', runtime={'platform': 'linux', 'workingTreeDirty': False},
                      controllerOperations=[{'id': 'dispatch.open', 'action': 'open',
                                             'sampleCount': 8, 'variant': {'kind': 'world'},
                                             'samples': [{'macroScope': 'ui.wld.open'}]}])
        report = build_coverage(self.inventory, [('profile.json', source)], [])
        direct = next(row for row in report['rows'] if row['category'] == 'controller-profile')
        self.assertIsNone(direct['frames'])
        self.assertEqual(direct['frameScopes'], ['ui.wld.open'])
        self.assertTrue(report['actions'][0]['profileDispatchMeasured'])

    def test_rejected_report_remains_visible(self):
        report = build_coverage(self.inventory, [], [{'report': 'partial.json', 'reason': 'running'}])
        self.assertEqual(report['status'], 'partial')
        self.assertEqual(report['reportCount'], 0)
        self.assertEqual(len(report['rejectedReports']), 1)

    def test_explicit_dispatch_keeps_frame_and_parameter_gaps(self):
        source = core_report()
        source['suite'] = 'public-dispatch-actions'
        source['operations'][0].update(id='workspace.edit-a',
            controller='Workspace', action='edit',
            dispatchEvidence='awaited-production-dispatch',
            completion='returned-and-state-asserted')
        report = build_coverage(self.inventory, [('direct.json', source)], [])
        action = report['actions'][1]
        self.assertTrue(action['directDispatchMeasured'])
        self.assertFalse(action['profileDispatchMeasured'])
        self.assertEqual(action['missingCoreOperations'], ['workspace.edit-b'])
        row = next(row for row in report['rows'] if row['category'] == 'controller-direct')
        self.assertIsNone(row['frames'])

    def test_cloud_service_id_only_maps_audited_local_dispatch(self):
        self.inventory['actions'].append({'controller': 'Workspace',
            'action': 'cloudPrepareUpload', 'operationIds': [],
            'availability': 'available', 'reason': 'not measured'})
        source = core_report()
        source['operations'][0]['id'] = 'cloud.upload.prepare_snapshot'
        report = build_coverage(self.inventory, [('untrusted-suite.json', source)], [])
        self.assertEqual(report['actions'][-1]['status'], 'gap')
        source['suite'] = 'cloud-client-local'
        report = build_coverage(self.inventory, [('local-cloud.json', source)], [])
        self.assertTrue(report['actions'][-1]['directDispatchMeasured'])
        self.assertFalse(report['actions'][-1]['profileDispatchMeasured'])
        self.assertEqual(report['rows'][0]['category'], 'controller-local')

    def test_disabled_qa_entry_is_not_production_success(self):
        self.inventory['actions'].append({'controller': 'Workspace',
            'action': 'openSynthetic', 'operationIds': [],
            'availability': 'qa-only', 'reason': 'disabled in production'})
        report = build_coverage(self.inventory, [], [])
        self.assertEqual(report['actions'][-1]['status'], 'not-applicable')
        self.assertFalse(report['actions'][-1]['directDispatchMeasured'])

    def test_full_world_macro_never_becomes_direct_dispatch_latency(self):
        self.inventory['actions'].append({'controller': 'Workspace',
            'action': 'worldCircuitCancel', 'operationIds': [],
            'availability': 'available', 'reason': 'not measured'})
        source = core_report()
        source.update(suite='computerraria-ui', runtime={
            'platform': 'linux', 'workingTreeDirty': False})
        source['operations'][0]['id'] = 'computer.cancel-import.standard'
        report = build_coverage(self.inventory, [('whole-world.json', source)], [])
        action = report['actions'][-1]
        self.assertTrue(action['profileWorkflowMeasured'])
        self.assertFalse(action['directDispatchMeasured'])
        self.assertFalse(action['profileDispatchMeasured'])
        row = next(row for row in report['rows']
                   if row['category'] == 'controller-profile-workflow')
        self.assertEqual(row['medianMs'], source['operations'][0]['medianMs'])
        self.assertIn('whole macro', row['measurementScope'])

    def test_current_inventory_contains_early_computer_dispatches(self):
        inventory = json.loads(Path(__file__).with_name('action_gaps.json').read_text())
        names = {row['action'] for row in inventory['actions']}
        self.assertTrue({'worldCircuitCancel', 'worldCircuitChooseWorld',
            'worldCircuitImport', 'worldCircuitInput', 'worldCircuitLoadPong',
            'worldCircuitLoadProgram', 'worldCircuitOptimization',
            'worldCircuitPause', 'worldCircuitRefreshDisplay',
            'worldCircuitReleaseKeys'} <= names)


class ExecutionTests(unittest.TestCase):
    def test_new_dispatch_suite_has_three_required_ci_processes(self):
        self.assertEqual(compare_ci.SUITES['public-dispatch'], 3)

    def test_only_verified_pre_dispatch_baseline_is_uncompared(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / 'baseline'
            baseline.mkdir()
            selected = root / 'selected.json'
            selected.write_text(json.dumps({'id': 37909644872,
                'head_sha': compare_ci.PRE_DISPATCH_BASELINE,
                'status': 'completed', 'conclusion': 'success'}))
            candidate = [(root / 'candidate.json', core_report(),
                          {'source': {'commit': 'c' * 40}, 'runId': 'candidate'})]
            argv = ['compare_ci.py', '--candidate', str(root), '--baseline', str(baseline),
                    '--baseline-requested', '--baseline-run-metadata', str(selected),
                    '--output', str(root / 'summary')]
            with mock.patch.object(compare_ci, 'SUITES', {'public-dispatch': 3}), \
                 mock.patch.object(compare_ci, 'load_group', return_value=candidate) as load, \
                 mock.patch.object(sys, 'argv', argv):
                self.assertEqual(compare_ci.main(), 0)
                self.assertEqual(load.call_count, 1)
            summary = json.loads((root / 'summary/comparison.json').read_text())
            self.assertEqual(summary['status'], 'inconclusive')
            self.assertEqual(summary['suites'][0]['status'], 'new-workload-uncompared')
            # A partial attempted baseline is never treated as the historical absence.
            (baseline / 'public-dispatch.run-1.execution.json').write_text('{}')
            with mock.patch.object(compare_ci, 'SUITES', {'public-dispatch': 3}), \
                 mock.patch.object(compare_ci, 'load_group', side_effect=[candidate,
                    AssertionError('incomplete attempted baseline')]), \
                 mock.patch.object(sys, 'argv', argv):
                self.assertEqual(compare_ci.main(), 1)

    def test_three_distinct_processes_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for number in range(1, 4):
                write_attempt(root, number)
            self.assertEqual(len(load_group(root, 'test', 3)), 3)
            with self.assertRaisesRegex(AssertionError, 'expected 5'):
                load_group(root, 'test', 5)

    def test_duplicate_execution_cannot_supply_a_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for number in range(1, 4):
                write_attempt(root, number, 'same-process')
            with self.assertRaisesRegex(AssertionError, 'duplicate'):
                load_group(root, 'test', 3)

    def test_report_modification_invalidates_execution_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_attempt(root, 1)
            (root / 'test.run-1.json').write_text('{}')
            with self.assertRaisesRegex(AssertionError, 'digest mismatch'):
                load_group(root, 'test', 1)

    def test_successful_command_without_report_is_failed_and_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            completed = subprocess.run([sys.executable, str(Path(__file__).with_name('run_ci_suite.py')),
                                        '--suite', 'empty', '--runs', '1', '--timeout-seconds', '5',
                                        '--output-dir', str(root), '--', sys.executable, '-c', 'print("finished")'],
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 1)
            manifest = json.loads((root / 'empty.run-1.execution.json').read_text())
            self.assertEqual(manifest['status'], 'missing-report')
            self.assertEqual((root / 'empty.run-1.log').read_text().strip(), 'finished')

    def test_first_calibration_cannot_claim_regression_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for number in range(1, 4):
                write_attempt(root, number)
            argv = ['compare_ci.py', '--candidate', str(root), '--output', str(root / 'summary')]
            with mock.patch.object(compare_ci, 'SUITES', {'test': 3}), mock.patch.object(sys, 'argv', argv):
                self.assertEqual(compare_ci.main(), 0)
            summary = json.loads((root / 'summary/comparison.json').read_text())
            self.assertEqual(summary['status'], 'inconclusive')
            self.assertEqual(summary['suites'][0]['status'], 'inconclusive')

    def test_selected_run_commit_must_match_downloaded_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for number in range(1, 4):
                write_attempt(root, number)
            selected = root / 'selected-run.json'
            selected.write_text(json.dumps({'id': 7, 'head_sha': 'd' * 40,
                                            'status': 'completed', 'conclusion': 'success'}))
            argv = ['compare_ci.py', '--candidate', str(root), '--baseline', str(root),
                    '--baseline-requested', '--baseline-run-metadata', str(selected),
                    '--output', str(root / 'summary')]
            with mock.patch.object(compare_ci, 'SUITES', {'test': 3}), mock.patch.object(sys, 'argv', argv):
                self.assertEqual(compare_ci.main(), 1)
            summary = json.loads((root / 'summary/comparison.json').read_text())
            self.assertEqual(summary['suites'][0]['status'], 'invalid')
            self.assertIn('Downloaded baseline commit differs', summary['suites'][0]['reason'])

    def test_known_slowdown_fails_aggregate_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline, candidate = root / 'baseline', root / 'candidate'
            baseline.mkdir()
            candidate.mkdir()
            for number in range(1, 4):
                write_attempt(baseline, number, f'baseline-{number}')
                write_attempt(candidate, number, f'candidate-{number}')
                report_path = candidate / f'test.run-{number}.json'
                report = json.loads(report_path.read_text())
                report['source'].update(commit='c' * 40, worktreeCommit='c' * 40)
                report['operations'][0].update(samplesMs=[11, 12, 13], medianMs=12, p95Ms=13, maxMs=13)
                report_path.write_text(json.dumps(report))
                execution_path = report_path.with_suffix('.execution.json')
                execution = json.loads(execution_path.read_text())
                execution['source'].update(commit='c' * 40, checkedOutHead='c' * 40)
                execution['reportSha256'] = hashlib.sha256(report_path.read_bytes()).hexdigest()
                execution_path.write_text(json.dumps(execution))
            argv = ['compare_ci.py', '--candidate', str(candidate), '--baseline', str(baseline),
                    '--baseline-requested', '--output', str(root / 'summary')]
            with mock.patch.object(compare_ci, 'SUITES', {'test': 3}), mock.patch.object(sys, 'argv', argv):
                self.assertEqual(compare_ci.main(), 1)
            summary = json.loads((root / 'summary/comparison.json').read_text())
            self.assertEqual(summary['status'], 'failed')
            self.assertEqual(summary['suites'][0]['status'], 'regression')


if __name__ == '__main__':
    unittest.main()
