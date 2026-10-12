"""Contract/host-control tests only; never starts Flutter or a benchmark."""
import copy
import hashlib
import io
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

import circuit_painter_paired as paired


PROVENANCE = {'source_commit': 'a' * 40, 'source_manifest_sha256': 'b' * 64,
              'renderer': 'llvmpipe (test renderer)'}


def report(arm='B', width=1440, height=1000):
    viewport = paired.expected_canvas(width, height)
    pixels = {'width': math.ceil(viewport['width']), 'height': math.ceil(viewport['height']),
              'rgbaSha256': ('c' if width == 1440 else 'd') * 64}
    start, end = 10000000, 30000000
    return {
        'schema': paired.SCHEMA, 'status': 'success', 'cleanup': 'disposed',
        'referenceCommit': paired.BASE, 'sourceCommit': PROVENANCE['source_commit'],
        'sourceManifestSha256': PROVENANCE['source_manifest_sha256'],
        'renderer': PROVENANCE['renderer'], 'arm': arm,
        'scenario': 'visible-generic-circuit-painter', 'buildMode': 'profile',
        'scene': {'width': width, 'height': height, 'dpr': 1, 'columns': 48, 'rows': 32},
        'fixture': dict(paired.FIXTURE), 'warmup': {'elapsedUs': 5000000},
        'window': {'startUs': start, 'endUs': end, 'elapsedUs': end - start,
                   'invalidations': 1250, 'paints': 3},
        'invalidationPeriodUs': 16000, 'viewportBefore': dict(viewport),
        'viewportAfter': dict(viewport), 'pixelsBefore': dict(pixels),
        'pixelsAfter': dict(pixels), 'oracleRgbaSha256': pixels['rgbaSha256'],
        'droppedFrames': 0, 'droppedPaints': 0, 'windowFrameCount': 3,
        'frames': [
            {'frameNumber': i, 'vsyncStartUs': stamp, 'inWindow': start <= stamp < end,
             'buildUs': 0 if i == 0 else 100, 'rasterUs': 200, 'totalSpanUs': 300}
            for i, stamp in enumerate((start - 1, start, start + 20000, end - 1, end))
        ],
        'paints': [{'startUs': start + i * 10000, 'durationUs': i * 50} for i in range(3)],
    }


def validate(data, arm='B', width=1440, height=1000):
    return paired.validate_report(data, arm=arm, width=width, height=height, **PROVENANCE)


class ReportContractTest(unittest.TestCase):
    def reject(self, change):
        data = report()
        change(data)
        with self.assertRaises(ValueError):
            validate(data)

    def test_desktop_and_mobile_use_actual_canvas_and_raw_counts(self):
        for width, height in paired.SCENES:
            result = validate(report(width=width, height=height), width=width, height=height)
            self.assertEqual(result['windowFrameCount'], 3)
            self.assertEqual(result['recordedFrameCount'], 5)
            self.assertEqual(result['paintCount'], 3)
            self.assertEqual(result['invalidationCount'], 1250)
            self.assertEqual(result['paintUs'], {'median': 50, 'p95': 50, 'max': 100})
            self.assertFalse(any('fps' in key.lower() or 'passed' in key for key in result))
        self.assertEqual(report()['pixelsBefore']['width'], 540)
        self.assertEqual(report(width=390, height=844)['pixelsBefore']['height'], 234)

    def test_identity_fixture_and_pixel_corruption_fail(self):
        mutations = {
            'wrong schema': lambda d: d.update(schema=1),
            'wrong scenario': lambda d: d.update(scenario='full-shell'),
            'debug build': lambda d: d.update(buildMode='debug'),
            'arm mismatch': lambda d: d.update(arm='A'),
            'base mismatch': lambda d: d.update(referenceCommit='e' * 40),
            'source mismatch': lambda d: d.update(sourceCommit='e' * 40),
            'manifest mismatch': lambda d: d.update(sourceManifestSha256='e' * 64),
            'renderer mismatch': lambda d: d.update(renderer='other'),
            'scene size': lambda d: d['scene'].update(width=390),
            'scene bool DPR': lambda d: d['scene'].update(dpr=True),
            'fixture hash': lambda d: d['fixture'].update(sha256='e' * 64),
            'fixture record count': lambda d: d['fixture'].update(records=1535),
            'fixture bytes': lambda d: d['fixture'].update(bytes=24575),
            'wire mask': lambda d: d['fixture'].update(wireMask=7),
            'before pixels': lambda d: d['pixelsBefore'].update(rgbaSha256='e' * 64),
            'after pixels': lambda d: d['pixelsAfter'].update(rgbaSha256='e' * 64),
            'pixel dimensions': lambda d: d['pixelsBefore'].update(height=1000),
            'missing oracle': lambda d: d.pop('oracleRgbaSha256'),
            'malformed oracle': lambda d: d.update(oracleRgbaSha256='not-a-digest'),
        }
        for name, mutation in mutations.items():
            with self.subTest(name=name):
                self.reject(mutation)

    def test_hidden_clipped_scaled_or_moved_canvas_fails(self):
        for key, value in [('left', -1), ('left', 21), ('top', 900), ('width', 0),
                           ('width', 1440), ('height', 1000), ('dpr', 2),
                           ('surfaceWidth', 1280), ('surfaceHeight', 720),
                           ('top', float('nan')), ('dpr', True)]:
            with self.subTest(key=key, value=value):
                self.reject(lambda d: d['viewportBefore'].update({key: value}))
        self.reject(lambda d: d['viewportAfter'].update(left=20.0000001))

    def test_timing_count_and_cleanup_integrity(self):
        mutations = [
            lambda d: d.update(status='failed'),
            lambda d: d.update(cleanup='active'),
            lambda d: d.update(droppedFrames=1),
            lambda d: d.update(droppedPaints=1),
            lambda d: d.update(droppedFrames=False),
            lambda d: d.update(invalidationPeriodUs=32000),
            lambda d: d['warmup'].update(elapsedUs=4999999),
            lambda d: d['warmup'].update(elapsedUs=8000001),
            lambda d: d['window'].update(endUs=29999999),
            lambda d: d['window'].update(endUs=35000001),
            lambda d: d['window'].update(elapsedUs=20000001),
            lambda d: d['window'].update(invalidations=0),
            lambda d: d['window'].update(invalidations=20001),
            lambda d: d['window'].update(paints=2),
            lambda d: d['window'].update(paints=True),
            lambda d: d.update(windowFrameCount=2),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.reject(mutation)

    def test_missing_duplicate_outside_and_mislabelled_observations_fail(self):
        mutations = [
            lambda d: d.update(frames=[]),
            lambda d: d.update(paints=[]),
            lambda d: d.update(frames=d['frames'] * 4001),
            lambda d: d['frames'][1].update(frameNumber=0),
            lambda d: d['frames'][1].update(vsyncStartUs=9999999),
            lambda d: d['frames'][1].update(inWindow=False),
            lambda d: d['frames'][0].update(inWindow=True),
            lambda d: d['frames'][-1].update(inWindow=True),
            lambda d: d['frames'][2].update(inWindow=1),
            lambda d: d['frames'][2].update(buildUs=-1),
            lambda d: d['frames'][2].update(totalSpanUs=99),
            lambda d: d['frames'][2].update(rasterUs=float('inf')),
            lambda d: d['paints'][1].update(startUs=10000000),
            lambda d: d['paints'][0].update(startUs=9999999),
            lambda d: d['paints'][-1].update(startUs=30000000),
            lambda d: d['paints'][1].update(durationUs=-1),
            lambda d: d['paints'][-1].update(durationUs=20000000),
            lambda d: d.update(frames=[d['frames'][0], d['frames'][-1]], windowFrameCount=0),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.reject(mutation)

    def test_pair_order_scene_and_cross_process_oracle_must_match(self):
        reports = [report(a, w, h) for w, h in paired.SCENES for a in paired.ORDER]
        self.assertEqual(len(paired.validate_series(reports, PROVENANCE)), 12)
        cases = [reports[:-1], reports + [reports[0]], [reports[1], reports[0], *reports[2:]],
                 reports[6:] + reports[:6]]
        changed = copy.deepcopy(reports)
        changed[2]['oracleRgbaSha256'] = 'e' * 64
        for key in ('pixelsBefore', 'pixelsAfter'):
            changed[2][key]['rgbaSha256'] = 'e' * 64
        cases.append(changed)
        changed = copy.deepcopy(reports)
        changed[-1]['sourceManifestSha256'] = 'e' * 64
        cases.append(changed)
        for index, data in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(ValueError):
                paired.validate_series(data, PROVENANCE)


class EvidenceGuardTest(unittest.TestCase):
    def test_fixture_bytes_are_independently_reproducible(self):
        payload = bytearray()
        for i in range(48 * 32):
            flags = (1 if i % 4 == 0 else 0) | (2 if i % 17 == 0 else 0)
            payload.extend(struct.pack('<IIIhh', 40 + i % 48, 50 + i // 48,
                                       (i % 13) | flags << 16 | 15 << 24, (i % 3) * 18, 0))
        self.assertEqual(len(payload), 24576)
        self.assertEqual(hashlib.sha256(payload).hexdigest(), paired.FIXTURE_SHA256)

    def test_frozen_class_is_exact_c61_except_name(self):
        base = subprocess.check_output(['git', 'show', f'{paired.BASE}:{paired.PRODUCT}'], cwd=paired.ROOT)
        reference = (paired.ROOT / paired.REFERENCE).read_bytes()
        self.assertTrue(paired.verify_reference(base, reference)['exactClassCopy'])
        for altered in [reference.replace(b'0xff121d28', b'0xff121d29'),
                        reference + b'// An extra statement is not the frozen class.\n',
                        reference.replace(b'C61CircuitPainter', b'OtherPainter')]:
            with self.assertRaises(ValueError):
                paired.verify_reference(base, altered)
        with self.assertRaises(ValueError):
            paired.verify_reference(base + b'\n', reference)

    def test_manifests_hash_actual_bytes_and_inventory_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = [paired.PRODUCT, paired.REFERENCE, paired.TARGET, paired.DRIVER, 'other.txt']
            for name in names:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(name)
            with mock.patch.object(paired, 'capture', return_value='\0'.join(names).encode()):
                before = paired.source_manifest(root)
                (root / 'other.txt').write_text('formatted actual contents')
                self.assertNotEqual(before, paired.source_manifest(root))
            (root / 'terraforge').write_bytes(b'one binary')
            before = paired.artifact_manifest(root)
            (root / 'terraforge').write_bytes(b'changed binary')
            self.assertNotEqual(before, paired.artifact_manifest(root))

    def test_logs_are_sanitized_and_capped_without_running_flutter(self):
        output, state = io.StringIO(), {}
        paired.drain_log(io.BytesIO(b'http://127.0.0.1:1234/secret=/ws authorization: Bearer hidden\n'), output, state)
        self.assertNotIn('secret', output.getvalue())
        self.assertNotIn('hidden', output.getvalue())
        self.assertNotIn('error', state)
        for content in [b'x' * 65537, (b'x' * 1023 + b'\n') * 2049]:
            output, state = io.StringIO(), {}
            paired.drain_log(io.BytesIO(content), output, state)
            self.assertIn('error', state)
            self.assertLessEqual(len(output.getvalue().encode()), paired.MAX_LOG_BYTES)

    def test_window_deadline_precedes_any_x11_access(self):
        visible = paired.VisibleWindow(Path('/tmp/unlaunched/terraforge'), 1440, 1000, set())
        with mock.patch.object(paired, 'capture') as capture, self.assertRaises(TimeoutError):
            visible(types.SimpleNamespace(pid=100), time.monotonic() - 21)
        capture.assert_not_called()

    def test_command_timeout_reaps_only_its_owned_group(self):
        real_popen, launched = subprocess.Popen, []
        def track(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            launched.append(process)
            return process
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(paired.subprocess, 'Popen', side_effect=track):
            with self.assertRaises(TimeoutError):
                paired.command([sys.executable, '-c', 'import time; time.sleep(30)'],
                               Path(directory) / 'timeout.log', .05, os.environ.copy(),
                               time.monotonic() + 2)
        self.assertEqual(len(launched), 1)
        self.assertIsNotNone(launched[0].poll())
        self.assertNotEqual(launched[0].pid, os.getpgrp())
        with self.assertRaises(ProcessLookupError):
            os.killpg(launched[0].pid, 0)

    def test_window_requires_unique_owned_process_and_fresh_pid(self):
        executable = Path('/tmp/unlaunched/terraforge')
        def setup_capture(two=False):
            def captured(argv, **kwargs):
                if argv[1] == 'search':
                    return b'123\n124\n' if two else b'123\n'
                if argv[1] == 'getwindowpid':
                    return b'345\n'
                if argv[1] == 'getwindowgeometry':
                    return b'X=0\nY=0\nWIDTH=1440\nHEIGHT=1000\n'
                return b''
            return captured
        for group, used, multiple, fail in [(100, set(), False, False),
                                            (999, set(), False, True),
                                            (100, {345}, False, True),
                                            (100, set(), True, True)]:
            visible = paired.VisibleWindow(executable, 1440, 1000, used)
            with self.subTest(group=group, used=used, multiple=multiple), \
                    mock.patch.object(paired, 'capture', side_effect=setup_capture(multiple)), \
                    mock.patch.object(paired.os, 'getpgid', return_value=group), \
                    mock.patch.object(paired.Path, 'resolve', return_value=executable):
                if fail:
                    with self.assertRaises(ValueError):
                        visible(types.SimpleNamespace(pid=100), time.monotonic())
                else:
                    visible(types.SimpleNamespace(pid=100), time.monotonic())
                    self.assertEqual(visible.evidence['pid'], 345)
                    self.assertEqual(visible.evidence['windowId'], '123')
                    self.assertEqual(used, {345})


if __name__ == '__main__':
    unittest.main()
