"""Synthetic checkout audits only; no real repository edits or app execution."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_retention_prepare as subject

ROOT = Path(__file__).resolve().parents[2]


class PreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='native-retention-source-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source, self.workflow = self.root / 'source', self.root / 'workflow'
        self.output = self.root / 'derivation'
        for root in (self.source, self.workflow):
            root.mkdir()
            self.git(root, 'init', '-q')
        self.write(self.source, 'lib/product.dart', b'fixed final product\n')
        self.write(self.source, '.hidden/config', b'hidden tracked product\n')
        self.write(self.source, 'bin/program', b'#!/bin/sh\nexit 0\n', executable=True)
        self.write(self.source, '.gitignore', b'ignored/\nbuild/\n')
        self.write(self.source, '.github/workflows/prior.yml', b'prior workflow\n')
        self.write(self.source, subject.SCHEDULE, (ROOT / subject.SCHEDULE).read_bytes())
        (self.source / 'lib/product-link').symlink_to('product.dart')
        self.commit(self.source)
        self.update_pin()
        self.write(self.workflow, '.gitignore', b'ignored/\n')
        self.write(self.workflow, 'lib/product.dart', b'unrelated workflow candidate\n')
        self.write(self.workflow, '.github/workflows/prior.yml', b'not copied\n')
        self.write(self.workflow, subject.SCHEDULE, b'not copied; use fixed base schedule\n')
        for name in subject.REQUIRED:
            self.write(self.workflow, name, ('diagnostic: ' + name + '\n').encode())
        self.write(self.workflow, 'tool/perf/native_retention_fixture.py', b'diagnostic fixture\n', executable=True)
        self.commit(self.workflow)
        self.base_patch = patch.object(subject, 'BASE', self.base)
        self.tree_patch = patch.object(subject, 'BASE_TREE', self.base_tree)
        self.base_patch.start()
        self.tree_patch.start()
        self.addCleanup(self.base_patch.stop)
        self.addCleanup(self.tree_patch.stop)

    @staticmethod
    def git(root, *args):
        return subprocess.check_output(['git', '-C', str(root), '-c', 'core.hooksPath=/dev/null', *args],
                                       text=True, stderr=subprocess.DEVNULL).strip()

    @staticmethod
    def write(root, name, data, executable=False):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if executable else 0o644)

    def commit(self, root):
        self.git(root, 'add', '-A')
        self.git(root, '-c', 'user.name=Source contract tests', '-c', 'user.email=tests@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'synthetic fixture')

    def update_pin(self):
        self.base = self.git(self.source, 'rev-parse', 'HEAD')
        self.base_tree = self.git(self.source, 'rev-parse', 'HEAD^{tree}')

    def prepare(self):
        return subject.prepare(self.workflow, self.source, self.output)

    def verify(self):
        return subject.verify_source(self.source, self.output / 'derivation.json')

    def test_only_new_diagnostics_leave_every_existing_product_file_unchanged(self):
        result = self.prepare()
        verified = self.verify()
        self.assertEqual(result['baseCommit'], self.base)
        self.assertEqual(result['baseTree'], self.base_tree)
        self.assertEqual(self.git(self.source, 'rev-parse', 'HEAD^'), self.base)
        self.assertEqual((self.source / 'lib/product.dart').read_bytes(), b'fixed final product\n')
        self.assertEqual((self.source / '.github/workflows/prior.yml').read_bytes(), b'prior workflow\n')
        self.assertEqual(verified['productFiles']['.hidden/config']['mode'], '100644')
        self.assertEqual(verified['productFiles']['lib/product-link']['mode'], '120000')
        self.assertEqual(verified['overlayFiles']['tool/perf/native_retention_fixture.py']['mode'], '100755')
        self.assertTrue(verified['productPathsUnchanged'])
        self.assertEqual(subject.check_source_unchanged(self.source, self.output / 'derivation.json', verified), verified)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_existing_ignored_tracked_bytes_are_audited(self):
        self.prepare()
        self.git(self.source, 'update-index', '--assume-unchanged', '.hidden/config')
        self.write(self.source, '.hidden/config', b'concealed edit\n')
        self.assertEqual(self.git(self.source, 'status', '--porcelain'), '')
        with self.assertRaisesRegex(ValueError, 'Tracked source bytes differ'):
            self.verify()

    def test_ignored_tracked_file_cannot_escape(self):
        self.write(self.source, 'ignored/product', b'base bytes\n')
        self.git(self.source, 'add', '-f', 'ignored/product')
        self.commit(self.source)
        self.update_pin()
        with patch.object(subject, 'BASE', self.base), patch.object(subject, 'BASE_TREE', self.base_tree):
            self.prepare()
            self.git(self.source, 'update-index', '--skip-worktree', 'ignored/product')
            self.write(self.source, 'ignored/product', b'different\n')
            with self.assertRaisesRegex(ValueError, 'Tracked source bytes differ'):
                self.verify()

    def test_initial_ignored_untracked_file_rejected_before_mutation(self):
        self.write(self.source, 'ignored/hide.py', b'hidden untracked addition\n')
        with self.assertRaisesRegex(ValueError, 'ignored untracked'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_base_tree_pin_enforced(self):
        with patch.object(subject, 'BASE_TREE', '0' * 40), self.assertRaisesRegex(ValueError, 'tree mismatch'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_source_hidden_edit_rejected_before_mutation(self):
        self.git(self.source, 'update-index', '--assume-unchanged', '.hidden/config')
        self.write(self.source, '.hidden/config', b'tampered before preparation\n')
        with self.assertRaisesRegex(ValueError, 'Tracked source bytes differ'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_existing_diagnostic_cannot_be_replaced(self):
        self.write(self.source, 'tool/perf/native_retention_fixture.py', b'existing base file\n')
        self.commit(self.source)
        self.update_pin()
        with patch.object(subject, 'BASE', self.base), patch.object(subject, 'BASE_TREE', self.base_tree):
            with self.assertRaisesRegex(ValueError, 'replace a base file'):
                self.prepare()
        self.assertFalse(self.output.exists())

    def test_frozen_schedule_rejected_before_mutation(self):
        with patch.object(subject, 'SCHEDULE_SHA256', '0' * 64):
            with self.assertRaisesRegex(ValueError, 'schedule digest mismatch'):
                self.prepare()
        self.assertFalse(self.output.exists())

    def test_symlink_diagnostic_rejected_before_mutation(self):
        path = self.workflow / subject.SUPPORT
        path.unlink()
        path.symlink_to('../computer_native_retention_test.dart')
        self.commit(self.workflow)
        with self.assertRaisesRegex(ValueError, 'Linked or changed'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_hidden_workflow_edit_cannot_be_copied(self):
        self.git(self.workflow, 'update-index', '--assume-unchanged', subject.TARGET)
        self.write(self.workflow, subject.TARGET, b'hidden uncommitted diagnostic\n')
        with self.assertRaisesRegex(ValueError, 'Tracked source bytes differ'):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_mode_edits_detected_even_with_filemode_disabled(self):
        self.prepare()
        self.git(self.source, 'config', 'core.filemode', 'false')
        (self.source / 'bin/program').chmod(0o644)
        self.assertEqual(self.git(self.source, 'status', '--porcelain'), '')
        with self.assertRaisesRegex(ValueError, 'mode differs'):
            self.verify()

    def test_staged_ignored_addition_rejected(self):
        self.prepare()
        self.write(self.source, 'ignored/injected', b'new tracked input\n')
        self.git(self.source, 'add', '-f', 'ignored/injected')
        with self.assertRaisesRegex(ValueError, 'index differs'):
            self.verify()

    def test_unexpected_committed_addition_rejected(self):
        self.prepare()
        self.write(self.source, 'lib/unexpected.dart', b'addition outside diagnostic namespace\n')
        self.git(self.source, 'add', 'lib/unexpected.dart')
        self.git(self.source, '-c', 'user.name=Tests', '-c', 'user.email=tests@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '--amend', '--no-edit', '-q')
        with self.assertRaisesRegex(ValueError, 'outside diagnostic whitelist'):
            self.verify()

    def test_unchanged_parent_does_not_allow_committed_base_edit(self):
        self.prepare()
        self.write(self.source, '.github/workflows/prior.yml', b'modified prior workflow\n')
        self.git(self.source, 'add', '.github/workflows/prior.yml')
        self.git(self.source, '-c', 'user.name=Tests', '-c', 'user.email=tests@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '--amend', '--no-edit', '-q')
        with self.assertRaisesRegex(ValueError, 'existing product file'):
            self.verify()

    def test_deleted_source_and_replaced_parent_directory_rejected(self):
        self.prepare()
        (self.source / 'lib/product.dart').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing tracked'):
            self.verify()
        self.write(self.source, 'lib/product.dart', b'fixed final product\n')
        (self.source / '.hidden/config').unlink()
        (self.source / '.hidden').rmdir()
        linked = self.root / 'alternate'
        linked.mkdir()
        self.write(linked, 'config', b'hidden tracked product\n')
        (self.source / '.hidden').symlink_to(linked)
        with self.assertRaisesRegex(ValueError, 'source parent'):
            self.verify()

    def test_overlay_actual_bytes_verified_after_preflight(self):
        self.prepare()
        before = self.verify()
        self.git(self.source, 'update-index', '--assume-unchanged', subject.TARGET)
        self.write(self.source, subject.TARGET, b'changed after preflight\n')
        with self.assertRaisesRegex(ValueError, 'Tracked source bytes differ'):
            subject.check_source_unchanged(self.source, self.output / 'derivation.json', before)

    def test_exact_patch_and_manifest_tampering_rejected(self):
        result = self.prepare()
        patch_file = self.output / 'diagnostic-overlay.patch'
        original = patch_file.read_bytes()
        patch_file.write_bytes(original + b'\n')
        with self.assertRaisesRegex(ValueError, 'exact patch differs'):
            self.verify()
        patch_file.write_bytes(original)
        changed = copy.deepcopy(result)
        changed['overlayFiles'][subject.TARGET]['sha256'] = '0' * 64
        (self.output / 'derivation.json').write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, 'file manifest differs'):
            self.verify()

    def test_ignored_generated_build_outputs_do_not_hide_tracked_inputs(self):
        self.prepare()
        before = self.verify()
        self.write(self.source, 'build/generated', b'normal untracked build output\n')
        self.assertEqual(subject.check_source_unchanged(self.source, self.output / 'derivation.json', before), before)

    def test_output_inside_application_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'external evidence'):
            subject.prepare(self.workflow, self.source, self.source / 'build/derivation')


if __name__ == '__main__':
    unittest.main()
