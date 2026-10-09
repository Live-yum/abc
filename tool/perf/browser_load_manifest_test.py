"""Exact product selection contracts. No network, browser or benchmark execution."""
import copy
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import browser_load_diagnostic as diagnostic


class ProductManifestChecks(unittest.TestCase):
    def pin(self):
        return diagnostic.load_product_pin(Path(__file__).with_name('browser_load_product_1dac431.json'))

    def test_candidate_is_explicit_and_baseline_control_is_unchanged(self):
        pin = self.pin()
        self.assertEqual(pin['commit'], '1dac431c45f82bcc298ea4bbce6abebb126dfc33')
        self.assertEqual(pin['runId'], '37963125990')
        self.assertEqual(pin['artifactId'], 11632794168)
        self.assertEqual(diagnostic.WEB_COMMIT, 'cddd936f95d31b14a76503e13ffc89173110a057')
        self.assertEqual(diagnostic.WEB_RUN, '37920825904')
        self.assertEqual(diagnostic.WEB_ARTIFACT_ID, 11611983230)

    def test_manifest_rejects_moving_refs_unbounded_sizes_bad_hashes_and_missing_required_files(self):
        changes = [lambda p: p.update(commit='main'), lambda p: p.update(commit='A' * 40),
                   lambda p: p.update(runId='latest'), lambda p: p.update(artifactId=True),
                   lambda p: p.update(label='bad label'), lambda p: p.update(extra='unexpected'),
                   lambda p: p['artifactZip'].update(bytes=128 * 1024 * 1024 + 1),
                   lambda p: p['archive'].update(sha256='bad'),
                   lambda p: p['webFiles'].pop('engine/world.js'),
                   lambda p: p['webFiles']['main.dart.js'].update(bytes=False)]
        for mutate in changes:
            pin = self.pin(); mutate(pin)
            with self.subTest(pin=pin), self.assertRaises(ValueError):
                diagnostic.validate_product_pin(pin)

    def test_oversized_manifest_is_rejected_before_parsing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'pin.json'; path.write_text(' ' * 65537)
            with self.assertRaisesRegex(ValueError, '64 KiB'):
                diagnostic.load_product_pin(path)

    def test_prepare_rejects_wrong_official_head_without_downloading_or_falling_back(self):
        pin = self.pin()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / 'cycle'
            run = {'head_sha': '0' * 40, 'status': 'completed', 'conclusion': 'success',
                   'path': '.github/workflows/ci.yml', 'repository': {'full_name': 'owner/repo'}}
            with patch.object(diagnostic, 'CYCLE_BASE', base), \
                    patch.dict(diagnostic.os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}), \
                    patch.object(diagnostic, 'command', return_value=json.dumps(run)) as read, \
                    patch.object(diagnostic.subprocess, 'run') as download:
                with self.assertRaisesRegex(ValueError, 'requested SHA'):
                    diagnostic.prepare(pin)
            read.assert_called_once(); download.assert_not_called()
            status = json.loads((base / 'evidence/build.json').read_text())
            self.assertEqual(status['status'], 'failed')
            self.assertFalse((base / 'web').exists())

    def test_prepare_verifies_exact_zip_tar_files_and_uses_only_separate_cycle_paths(self):
        pin = self.pin()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); cycle = root / 'cycle'; baseline = root / 'baseline'
            (root / 'tool/perf').mkdir(parents=True)
            for name in ['browser_load_driver.mjs', 'browser_load_cycles.mjs']:
                (root / 'tool/perf' / name).write_text('// synthetic test source')
            files = {name: ('test:' + name).encode() for name in ['index.html', 'main.dart.js',
                'terra_world_circuit.js', 'terra_worker_rpc.js', 'terra_engine_worker.js',
                'engine/world.wasm', 'engine/world.js']}
            archive = root / 'fixture.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                for name, data in files.items():
                    member = tarfile.TarInfo(name); member.size = len(data); tar.addfile(member, io.BytesIO(data))
            zipped = root / 'fixture.zip'
            with zipfile.ZipFile(zipped, 'w') as output:
                output.write(archive, 'terraforge-web.tar.gz')
            pin['artifactZip'] = diagnostic.describe(zipped); pin['archive'] = diagnostic.describe(archive)
            for name in pin['webFiles']:
                pin['webFiles'][name] = {'bytes': len(files[name]),
                    'sha256': diagnostic.hashlib.sha256(files[name]).hexdigest()}
            run = {'head_sha': pin['commit'], 'status': 'completed', 'conclusion': 'success',
                   'path': '.github/workflows/ci.yml', 'repository': {'full_name': 'owner/repo'},
                   'html_url': 'https://github.com/owner/repo/actions/runs/' + pin['runId']}
            artifact = {'name': 'terraforge-web-' + pin['commit'], 'id': pin['artifactId'], 'expired': False}
            def read(args):
                if args[0] == 'gh':
                    return json.dumps({'artifacts': [artifact]} if 'artifacts?' in args[-1] else run)
                return '' if 'status' in args else 'a' * 40
            def download(_args, *, stdout, **_kwargs):
                stdout.write(zipped.read_bytes())
            with patch.object(diagnostic, 'ROOT', root), patch.object(diagnostic, 'CYCLE_BASE', cycle), \
                    patch.object(diagnostic, 'BASE', baseline), \
                    patch.dict(diagnostic.os.environ, {'GITHUB_REPOSITORY': 'owner/repo'}), \
                    patch.object(diagnostic, 'command', side_effect=read), \
                    patch.object(diagnostic.subprocess, 'run', side_effect=download):
                diagnostic.prepare(copy.deepcopy(pin))
            status = json.loads((cycle / 'evidence/build.json').read_text())
            self.assertEqual(status['status'], 'verified')
            self.assertEqual(status['productPin'], pin)
            self.assertEqual(status['artifactSourceCommit'], pin['commit'])
            self.assertEqual(status['archive'], pin['archive'])
            self.assertEqual(status['webFiles']['main.dart.js'], pin['webFiles']['main.dart.js'])
            self.assertFalse(baseline.exists())
            self.assertEqual((cycle / 'web/index.html').read_bytes(), files['index.html'])


if __name__ == '__main__':
    unittest.main()
