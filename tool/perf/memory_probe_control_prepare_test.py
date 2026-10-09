import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import memory_probe_control_prepare as subject


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='memory-control-prepare-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.workflow = self.root / 'source', self.root / 'workflow'
        self.output = self.root / 'evidence'
        self.original = b'Future<_ObservedBackend> _cycle() async {}\nvoid main() { _cycle(); }\n'
        for path in (self.source, self.workflow):
            path.mkdir()
            self.git(path, 'init', '-q')
        self.write(self.source, subject.ORIGINAL, self.original)
        self.write(self.source, 'lib/product.dart', b'fixed product bytes\n')
        self.commit(self.source)
        self.base = self.git(self.source, 'rev-parse', 'HEAD').strip()
        # Workflow head may contain arbitrary unrelated product/lint changes;
        # none of those bytes may enter the fixed-product diagnostic checkout.
        self.write(self.workflow, subject.ORIGINAL, b'HEAD-only lint and product helper changes\n')
        self.write(self.workflow, 'lib/product.dart', b'new candidate product, must not copy\n')
        self.write(self.workflow, subject.DART_FILES[1], b'new diagnostic entry\n')
        self.write(self.workflow, subject.DART_FILES[2], b'new diagnostic telemetry\n')
        self.write(self.workflow, '.github/workflows/memory-probe-control.yml', b'workflow\n')
        schedule = b'{"schema":"test-only-timing"}\n'
        self.write(self.workflow, 'tool/perf/memory_probe_control_schedule.json', schedule)
        manifest = {'baseCommit': self.base, 'schedule': 'tool/perf/memory_probe_control_schedule.json',
                    'scheduleSha256': hashlib.sha256(schedule).hexdigest()}
        self.write(self.workflow, 'tool/perf/memory_probe_control_manifest.json', json.dumps(manifest).encode())
        self.commit(self.workflow)

    @staticmethod
    def write(root, name, data):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    @staticmethod
    def git(root, *args):
        return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.DEVNULL)

    def commit(self, root):
        self.git(root, 'add', '.')
        self.git(root, '-c', 'user.name=Control tests', '-c', 'user.email=tests@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'local test fixture')

    def test_pinned_body_and_product_ignore_unrelated_head_changes(self):
        with patch.object(subject, 'BASE', self.base):
            result = subject.prepare(self.workflow, self.source, self.output)
        self.assertEqual((self.source / subject.ORIGINAL).read_bytes(), subject.original_overlay(self.original))
        self.assertEqual((self.source / 'lib/product.dart').read_bytes(), b'fixed product bytes\n')
        self.assertEqual(self.git(self.source, 'rev-parse', 'HEAD^').strip(), self.base)
        patch_bytes = subprocess.check_output(['git', '-C', str(self.source), 'diff', '--no-color', '--binary', '--full-index', self.base, result['derivedCommit']])
        self.assertEqual(hashlib.sha256(patch_bytes).hexdigest(), result['patchSha256'])
        self.assertEqual(self.git(self.source, 'status', '--porcelain').strip(), '')
        with patch.object(subject, 'BASE', self.base), self.assertRaises(ValueError):
            subject.prepare(self.workflow, self.source, self.output)

    def test_changed_schedule_fails_before_source_mutation(self):
        self.write(self.workflow, 'tool/perf/memory_probe_control_schedule.json', b'changed timing\n')
        self.commit(self.workflow)
        with patch.object(subject, 'BASE', self.base), self.assertRaisesRegex(ValueError, 'digest mismatch'):
            subject.prepare(self.workflow, self.source, self.output)
        self.assertEqual(self.git(self.source, 'status', '--porcelain').strip(), '')
        self.assertFalse(self.output.exists())

    def test_symlink_diagnostic_fails_before_source_mutation(self):
        target = self.workflow / subject.DART_FILES[2]
        target.unlink()
        target.symlink_to(self.workflow / subject.DART_FILES[1])
        self.commit(self.workflow)
        with patch.object(subject, 'BASE', self.base), self.assertRaisesRegex(ValueError, 'linked diagnostic'):
            subject.prepare(self.workflow, self.source, self.output)
        self.assertEqual(self.git(self.source, 'status', '--porcelain').strip(), '')


if __name__ == '__main__':
    unittest.main()
