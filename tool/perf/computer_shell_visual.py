#!/usr/bin/env python3
"""Generate four static shell observations, then compare A/B decoded pixels."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
BASE = 'cf36cd2bf1d447a887d3ea4d19611020368de22c'
CANDIDATE = 'c938c936c0c833fed4091f844ac96ac1df941e45'
SDK_REVISION = '5fc346839b5d0eef006ed8404392afb4dfae428d'
TARGET = 'test/computer_shell_visual_test.dart'
FONT = 'assets/fonts/TerraForgeCJK-Regular.otf'
FONT_SHA = '8d8f6deb9c77910cb8e24fad5b576446cac5f04faa685acaf74fcc5e4079e65b'
PRODUCT = {'lib/ui/terra_contract.dart', 'lib/ui/terra_app.dart',
           'lib/application/workspace.dart', 'lib/engine/world_circuit_session.dart'}
SIZES = {'desktop-1440x1000': (1440, 1000), 'mobile-390x844': (390, 844)}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def run(argv, cwd, log, timeout=180):
    with Path(log).open('x') as stream:
        process = subprocess.Popen(argv, cwd=cwd, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            raise
    if code:
        raise RuntimeError(f'Command exited {code}; see {Path(log).name}')


def git(*args, cwd=ROOT):
    return subprocess.check_output(['git', *args], cwd=cwd, timeout=30).decode().strip()


def inventory(stage):
    paths = git('ls-files', 'lib', 'assets', 'pubspec.yaml', 'pubspec.lock',
                '.flutter-version', 'test/support/computer_circuit_backend.dart',
                'test/workspace_test.dart', cwd=stage).splitlines()
    return {name: sha(stage / name) for name in paths}


def compare(left, right, expected_size):
    with Image.open(left) as source_a, Image.open(right) as source_b:
        if source_a.size != expected_size or source_b.size != expected_size:
            raise ValueError('Screenshot dimensions differ from the declared viewport')
        pixels_a = source_a.convert('RGBA').tobytes()
        pixels_b = source_b.convert('RGBA').tobytes()
    changed = sum(pixels_a[i:i + 4] != pixels_b[i:i + 4]
                  for i in range(0, len(pixels_a), 4))
    return {
        'width': expected_size[0], 'height': expected_size[1],
        'A': {'pngSha256': sha(left), 'rgbaSha256': hashlib.sha256(pixels_a).hexdigest()},
        'B': {'pngSha256': sha(right), 'rgbaSha256': hashlib.sha256(pixels_b).hexdigest()},
        'differentPixels': changed,
        'maximumChannelDifference': max(abs(a - b) for a, b in zip(pixels_a, pixels_b)),
        'exactPixelMatch': changed == 0,
    }


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {'schema': 1, 'status': 'preparing', 'baseCommit': BASE,
              'candidateCommit': CANDIDATE, 'diagnosticHead': git('rev-parse', 'HEAD'),
              'scenario': 'paused-full-TerraForgeApp-shared-contract-fixture',
              'harnessSha256': sha(ROOT / TARGET), 'arms': {}, 'comparisons': {},
              'method': 'Official widget golden generation followed by independent exact decoded RGBA comparison; update-goldens is not a comparison result.',
              'limitations': ['One Linux Flutter widget rasterizer at two responsive sizes, DPR 1; not native desktop/mobile/browser device screenshots.',
                              'Public synthetic contract fixture and a four-byte ROM; no large WLD read or CPU simulation.',
                              'Actual bundled CJK regular face and MaterialIcons are loaded; heavier weights use the product renderer synthesis.',
                              'The same paused monitor region is scrolled into view; each PNG captures only its viewport.']}
    stages = []
    try:
        flutter = shutil.which('flutter')
        if not flutter:
            raise RuntimeError('Official pinned Flutter setup is required')
        sdk = Path(flutter).resolve().parents[1]
        if git('rev-parse', 'HEAD', cwd=sdk) != SDK_REVISION:
            raise ValueError('Flutter SDK revision is not the reviewed official revision')
        report['sdkRevision'] = SDK_REVISION
        run([flutter, '--version', '--machine'], ROOT, output / 'toolchain.log', 60)
        temporary = Path(tempfile.mkdtemp(prefix='abc-shell-visual-',
                                         dir=os.environ.get('RUNNER_TEMP')))
        for arm, commit in [('A', BASE), ('B', CANDIDATE)]:
            stage = temporary / arm
            run(['git', 'worktree', 'add', '--detach', str(stage), commit],
                ROOT, output / f'{arm}-checkout.log', 60)
            stages.append(stage)
            sources = inventory(stage)
            if sources[FONT] != FONT_SHA:
                raise ValueError('Bundled CJK font differs from reviewed bytes')
            shutil.copyfile(ROOT / TARGET, stage / TARGET)
            if sha(stage / TARGET) != report['harnessSha256']:
                raise ValueError('A/B harness bytes differ')
            write(output / f'{arm}-sources.json', sources)
            report['arms'][arm] = {'commit': git('rev-parse', 'HEAD', cwd=stage),
                                   'sources': sources, 'cjkFontSha256': sources[FONT]}
        a, b = (report['arms'][arm]['sources'] for arm in ('A', 'B'))
        if a.keys() != b.keys() or {name for name in a if a[name] != b[name]} != PRODUCT:
            raise ValueError('Product, theme, fixture or asset inventory exceeds the four UI product changes')
        report['productDifferences'] = sorted(PRODUCT)
        write(output / 'summary.json', report)
        for arm, stage in zip(('A', 'B'), stages):
            run([flutter, 'pub', 'get', '--enforce-lockfile'], stage,
                output / f'{arm}-pub-get.log', 300)
            run([flutter, 'test', '--no-pub', '--concurrency=1',
                 '--update-goldens', TARGET], stage, output / f'{arm}-golden-generation.log')
            for name in SIZES:
                source = stage / 'test/goldens/computer-shell' / f'{name}.png'
                shutil.copyfile(source, output / f'{arm}-{name}.png')
        report['materialIconsSha256'] = sha(sdk / 'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
        for name, size in SIZES.items():
            report['comparisons'][name] = compare(output / f'A-{name}.png',
                                                  output / f'B-{name}.png', size)
        same = all(row['exactPixelMatch'] for row in report['comparisons'].values())
        report['status'] = 'static-viewport-pixels-identical' if same else 'static-viewport-pixel-differences'
        write(output / 'summary.json', report)
        return 0 if same else 1
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        write(output / 'summary.json', report)
        raise
    finally:
        for stage in reversed(stages):
            subprocess.run(['git', 'worktree', 'remove', '--force', str(stage)],
                           cwd=ROOT, timeout=30, check=False)


if __name__ == '__main__':
    sys.exit(main())
