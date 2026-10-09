#!/usr/bin/env python3
"""Lightweight validators and observer checks; never starts the rules workload."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_diagnostic as diagnostic


class DiagnosticContract(unittest.TestCase):
    def test_verified_exact_inputs_and_sequence(self):
        manifest = diagnostic.validate_inputs()
        self.assertEqual(manifest['sequence'], ['baseline', 'candidate', 'candidate', 'baseline', 'baseline', 'candidate'])

    def test_generated_javascript_syntax(self):
        for name in ['rules_runner.mjs', 'diagnostic_probe.mjs', 'test_probe.mjs']:
            subprocess.run(['node', '--check', str(diagnostic.ROOT / name)], check=True)

    def test_tampered_wasm_fails_before_workload(self):
        with tempfile.TemporaryDirectory(prefix='abc-rules-input-test-') as tmp:
            root = Path(tmp) / 'package'
            shutil.copytree(diagnostic.ROOT, root, ignore=shutil.ignore_patterns('__pycache__'))
            wasm = root / 'inputs/candidate/web/engine/world.wasm'
            wasm.write_bytes(wasm.read_bytes() + b'bad')
            with patch.object(diagnostic, 'ROOT', root), self.assertRaisesRegex(AssertionError, 'Input changed'):
                diagnostic.validate_inputs()

    def test_rule_extraction_tamper_fails(self):
        with tempfile.TemporaryDirectory(prefix='abc-rules-extraction-test-') as tmp:
            root = Path(tmp) / 'package'
            shutil.copytree(diagnostic.ROOT, root, ignore=shutil.ignore_patterns('__pycache__'))
            runner = root / 'rules_runner.mjs'
            runner.write_text(runner.read_text().replace("await invoke('close','editor.close')", "await invoke('close','editor.snapshot')"))
            with patch.object(diagnostic, 'ROOT', root), self.assertRaisesRegex(AssertionError, 'extraction/template changed'):
                diagnostic.validate_inputs()

    def test_original_statistical_decision_unchanged(self):
        comparator = diagnostic.comparison_module()
        self.assertEqual(comparator.compare_values([1, 2, 3], [4, 5, 6])['status'], 'regression')
        self.assertEqual(comparator.compare_values([4, 5, 6], [1, 2, 3])['status'], 'improvement')
        self.assertEqual(comparator.compare_values([1, 2, 3], [2, 3, 4])['status'], 'within-observed-noise')

    def test_no_private_absolute_paths_in_manifests(self):
        for name in ['input-manifest.json', 'source-manifest.json']:
            data = json.loads((diagnostic.ROOT / name).read_text())
            def inspect(value):
                if isinstance(value, str):
                    self.assertFalse(value.startswith('/'), 'Manifest must not embed executor absolute paths')
                elif isinstance(value, dict):
                    for key, child in value.items():
                        inspect(key)
                        inspect(child)
                elif isinstance(value, list):
                    for child in value:
                        inspect(child)
            inspect(data)

    def test_observer_boundaries_and_gc(self):
        subprocess.run(['node', '--expose-gc', str(diagnostic.ROOT / 'test_probe.mjs')], check=True)

    def test_default_is_validation_only(self):
        result = subprocess.run([sys.executable, str(diagnostic.ROOT / 'run_diagnostic.py')], text=True, capture_output=True, check=True)
        self.assertIn('no benchmark executed', result.stdout)

    def test_wrong_toolchain_stops_before_output_or_process(self):
        with tempfile.TemporaryDirectory(prefix='abc-rules-preflight-test-') as tmp:
            output = Path(tmp) / 'must-not-exist'
            manifest = diagnostic.validate_inputs()
            manifest['sourceGitVerified'] = True
            with patch.object(diagnostic, 'validate_inputs', return_value=manifest), \
                 patch.object(diagnostic, 'host', return_value={'node': 'v0.0.0', 'v8': 'wrong'}), \
                 patch('sys.argv', ['run_diagnostic.py', '--execute', '--output-dir', str(output)]), \
                 patch.object(diagnostic.subprocess, 'Popen') as popen, \
                 self.assertRaisesRegex(SystemExit, 'no processes started'):
                diagnostic.main()
            popen.assert_not_called()
            self.assertFalse(output.exists())

    def test_validator_snapshot_cannot_execute(self):
        manifest = diagnostic.validate_inputs()
        manifest['sourceGitVerified'] = False
        with patch.object(diagnostic, 'validate_inputs', return_value=manifest), \
             patch('sys.argv', ['run_diagnostic.py', '--execute', '--output-dir', 'must-not-exist']), \
             patch.object(diagnostic.subprocess, 'Popen') as popen, \
             self.assertRaisesRegex(SystemExit, 'Validator-only snapshots cannot execute'):
            diagnostic.main()
        popen.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
