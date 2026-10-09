"""Bounded native helper build contracts. Never opens a world or starts Flutter."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import native_retention_build as subject

ROOT = Path(__file__).resolve().parents[2]


class HelperBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('cc'):
            raise unittest.SkipTest('Installed system compiler unavailable')
        temporary = tempfile.TemporaryDirectory(prefix='native-retention-build-test-')
        cls.addClassCleanup(temporary.cleanup)
        cls.output = Path(temporary.name) / 'build'
        cls.result = subject.build(ROOT, cls.output)

    def test_helper_and_all_recorded_command_outputs_are_hashed(self):
        result = self.result
        self.assertEqual(result['status'], 'built')
        self.assertEqual(subject.digest(Path(result['helperPath'])), result['helperSha256'])
        self.assertEqual(Path(result['helperPath']).parent, self.output)
        self.assertEqual(json.loads((self.output / 'helper-build.json').read_text()), result)
        self.assertTrue(result['outsideApplicationCheckout'])
        self.assertFalse(result['applicationLaunched'])
        self.assertFalse(result['downloadedDependencies'])
        for command in result['commands']:
            for stream in ('stdout', 'stderr'):
                self.assertEqual(subject.digest(self.output / command[stream + 'File']), command[stream + 'Sha256'])
        self.assertFalse(any('flutter' in str(arg) for cmd in result['commands'] for arg in cmd['argv']))

    def test_actual_official_header_and_fresh_c_runtime_identity_recorded(self):
        result = self.result
        header = result['mallocHeader']
        self.assertEqual(Path(header['path']).name, 'malloc.h')
        self.assertEqual(subject.digest(header['path']), header['sha256'])
        runtime = result['runtime']
        self.assertEqual(runtime['scope'], 'fresh-native-build-contract-process-only')
        self.assertIn(runtime['sizeTBytes'], (4, 8))
        self.assertEqual(runtime['mallinfo2StructBytes'], 10 * runtime['sizeTBytes'])
        self.assertEqual(runtime['helperStatus'], 0)
        self.assertTrue(runtime['abiContractMatched'])
        self.assertEqual(subject.digest(runtime['libcPath']), runtime['libcSha256'])
        self.assertEqual(runtime['sourceReviewRequired'], runtime['runtimeLibcVersion'] not in ('2.39', '2.41'))
        self.assertIn(runtime['package']['status'], ('available', 'unavailable'))
        self.assertIn('version', result['compiler'])

    def test_refuses_reusing_evidence_or_building_inside_app(self):
        with self.assertRaisesRegex(ValueError, 'new helper build directory'):
            subject.build(ROOT, self.output)
        with self.assertRaisesRegex(ValueError, 'outside the entire application'):
            subject.build(ROOT, ROOT / 'build/diagnostic-helper')

    def test_refuses_arbitrary_compiler(self):
        compiler = self.output / 'fake-cc'
        compiler.write_text('#!/bin/sh\nexit 99\n')
        compiler.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'distribution compiler'):
            subject.build(ROOT, self.output.parent / 'second', compiler)
        self.assertFalse((self.output.parent / 'second').exists())

    def test_failed_compile_retains_commands_and_failure_evidence(self):
        source = self.output.parent / 'broken-source'
        probe = source / subject.HELPER_SOURCE
        probe.parent.mkdir(parents=True)
        probe.write_text('this deliberately is not valid C;\n')
        output = self.output.parent / 'failed-build'
        with self.assertRaisesRegex(ValueError, 'compile-helper'):
            subject.build(source, output)
        record = json.loads((output / 'helper-build.json').read_text())
        self.assertEqual(record['status'], 'failed')
        self.assertEqual(record['failureType'], 'ValueError')
        command = record['commands'][-1]
        self.assertEqual(command['name'], 'compile-helper')
        self.assertNotEqual(command['returnCode'], 0)
        self.assertEqual(subject.digest(output / command['stderrFile']), command['stderrSha256'])


if __name__ == '__main__':
    unittest.main()
