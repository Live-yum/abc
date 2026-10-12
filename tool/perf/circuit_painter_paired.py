#!/usr/bin/env python3
"""One Linux/profile binary, twelve fresh visible hosts, BAABBA per canvas.

Usage: circuit_painter_paired.py NEW_OUTPUT_DIRECTORY
Run in the official Flutter CI environment under Xvfb, with RUNNER_TEMP and
TERRA_PERF_RENDERER set. This is a synthetic painter diagnostic, not an FPS or
product-performance acceptance test. It performs no memory or VM sampling.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[2]
BASE = 'c61d7a1d8c5155515808611fdf2c3b5992b666f3'
BASE_SOURCE_SHA256 = 'd04fd5574aed152a6bf9cc654950471197020f56ef9db5efc5d19bef82eb439a'
BASE_CLASS_SHA256 = 'e586a4cc0fd99b80ce0be03745ef19c9afff369b624722eb32b3207809849f27'
PRODUCT = 'lib/ui/world_circuit_panel.dart'
REFERENCE = 'test/support/circuit_painter_c61_reference.dart'
TARGET = 'integration_test/circuit_painter_profile_test.dart'
DRIVER = 'test_driver/circuit_painter_profile_driver.dart'
SCHEMA = 'abc.circuit-painter-profile.v1'
ORDER = ('B', 'A', 'A', 'B', 'B', 'A')
SCENES = ((1440, 1000), (390, 844))
FIXTURE_SHA256 = 'fb159a71b949453a6da80642737c77c48b4b3fa8bba43a0fc00cbb97358f6e9c'
FIXTURE = {'sha256': FIXTURE_SHA256, 'bytes': 24576, 'records': 1536, 'wireMask': 15}
BUILD_SECONDS, RUN_SECONDS, GLOBAL_SECONDS = 600, 150, 1500
MAX_LOG_BYTES, MAX_REPORT_BYTES, MAX_OBSERVATIONS = 2 * 1024 * 1024, 16 * 1024 * 1024, 20000
HEX40, HEX64 = re.compile(r'^[0-9a-f]{40}$'), re.compile(r'^[0-9a-f]{64}$')
LOCAL_URL = re.compile(r'(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?[^\s<>"\']*')
AUTH = re.compile(r'(?i)(authorization\s*[:=]\s*(?:bearer\s+)?|(?:auth(?:entication)?[_ -]?(?:token|code)|access[_ -]?token)\s*[:=]\s*)[^\s,;"\']+')


def safe_text(value):
    return AUTH.sub(r'\1[redacted]', LOCAL_URL.sub('[redacted-local-service-url]', str(value)))


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def capture(argv, *, cwd=ROOT, env=None, timeout=20, allowed=(0,)):
    result = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode not in allowed:
        raise ValueError(f'Command failed ({result.returncode}): {safe_text(result.stderr.decode("utf-8", "replace"))[:1024]}')
    if len(result.stdout) > MAX_REPORT_BYTES:
        raise ValueError('Captured command output exceeded its bound')
    return result.stdout


def verify_reference(base_source, reference):
    """The frozen class must be c61 bytes, allowing only its public-name rename."""
    if hashlib.sha256(base_source).hexdigest() != BASE_SOURCE_SHA256:
        raise ValueError('Fixed c61 source hash differs')
    marker = b'class _CircuitPainter extends CustomPainter {'
    renamed = b'class C61CircuitPainter extends CustomPainter {'
    if base_source.count(marker) != 1 or reference.count(renamed) != 1:
        raise ValueError('Missing or duplicate baseline painter class')
    original = base_source[base_source.index(marker):].strip() + b'\n'
    copied = reference[reference.index(renamed):].strip().replace(b'C61CircuitPainter', b'_CircuitPainter') + b'\n'
    if original != copied or hashlib.sha256(original).hexdigest() != BASE_CLASS_SHA256:
        raise ValueError('Frozen painter differs from c61 beyond its class name')
    return {'commit': BASE, 'sourcePath': PRODUCT, 'sourceSha256': BASE_SOURCE_SHA256,
            'classSha256': BASE_CLASS_SHA256, 'referencePath': REFERENCE,
            'referenceSha256': hashlib.sha256(reference).hexdigest(), 'exactClassCopy': True}


def source_manifest(root):
    names = sorted(filter(None, capture(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')))
    if not {PRODUCT, REFERENCE, TARGET, DRIVER}.issubset(names):
        raise ValueError('Product, frozen oracle, integration target and driver must all be tracked')
    rows = []
    for name in names:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Tracked source must be a regular file: {name}')
        rows.append({'path': name, 'bytes': path.stat().st_size, 'sha256': sha(path)})
    return rows


def artifact_manifest(bundle):
    rows = []
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink():
            # Copying the bundle dereferences links. Reject subsequent link swaps.
            raise ValueError('Built bundle contains an unexpected symbolic link')
        if path.is_file():
            rows.append({'path': str(path.relative_to(bundle)), 'bytes': path.stat().st_size,
                         'sha256': sha(path), 'mode': path.stat().st_mode & 0o777})
    if not rows or not (bundle / 'terraforge').is_file():
        raise ValueError('Missing built Linux application bundle')
    return rows


def stop_group(process):
    """Signal only the new process group created by this runner invocation."""
    for sig, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 1)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            continue
    process.wait(timeout=5)


def drain_log(stream, output, state):
    total = written = 0
    try:
        while True:
            line = stream.readline(65537)
            if not line:
                break
            total += len(line)
            if len(line) > 65536 or total > MAX_LOG_BYTES:
                raise ValueError('Command log exceeded its line or 2 MiB byte bound')
            cleaned = safe_text(line.decode('utf-8', 'replace'))
            written += len(cleaned.encode('utf-8'))
            if written > MAX_LOG_BYTES:
                raise ValueError('Sanitized command log exceeded its 2 MiB byte bound')
            output.write(cleaned)
            output.flush()
    except Exception as error:
        state['error'] = safe_text(error)
    finally:
        state['bytes'] = total


def command(argv, output, timeout, env, global_deadline, on_poll=None):
    """Keep bounded logs, apply both deadlines, and reap this owned group."""
    if time.monotonic() >= global_deadline:
        raise TimeoutError('Global 1500-second deadline expired')
    state = {}
    with Path(output).open('x') as log:
        process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        reader = threading.Thread(target=drain_log, args=(process.stdout, log, state), daemon=True)
        reader.start()
        started = time.monotonic()
        deadline = min(started + timeout, global_deadline)
        try:
            while process.poll() is None:
                if state.get('error'):
                    raise ValueError(state['error'])
                if time.monotonic() >= deadline:
                    raise TimeoutError('Bounded command or global deadline expired')
                if on_poll:
                    on_poll(process, started)
                time.sleep(.1)
            code = process.returncode
        finally:
            try:
                stop_group(process)
            finally:
                reader.join(timeout=5)
                process.stdout.close()
        if reader.is_alive() or state.get('error'):
            raise ValueError(state.get('error', 'Command log reader did not finish'))
    if code:
        raise ValueError(f'Command exited {code}: {argv[:4]}')


class VisibleWindow:
    """Select the owned GTK X11 window; resizing never changes Flutter test metrics."""
    def __init__(self, executable, width, height, used_pids):
        self.executable = executable.resolve()
        self.width, self.height, self.used_pids = width, height, used_pids
        self.evidence = None

    def __call__(self, process, started):
        if self.evidence:
            return
        if time.monotonic() - started >= 20:
            raise TimeoutError('No unique owned, resized visible GTK window within 20 seconds')
        windows = capture(['xdotool', 'search', '--onlyvisible', '--name', '^terraforge$'],
                          timeout=2, allowed=(0, 1)).decode().split()
        owned = []
        for window in windows:
            if not window.isdecimal():
                raise ValueError('Invalid X11 window identity')
            try:
                pid = int(capture(['xdotool', 'getwindowpid', window], timeout=2).strip())
                if Path(f'/proc/{pid}/exe').resolve(strict=True) != self.executable:
                    continue
                if os.getpgid(pid) != process.pid:
                    raise ValueError('Matching application belongs to an unowned process group')
                owned.append((window, pid))
            except (FileNotFoundError, ProcessLookupError):
                continue
        if len(owned) > 1:
            raise ValueError('Multiple owned visible GTK windows')
        if not owned:
            return
        window, pid = owned[0]
        if pid in self.used_pids:
            raise ValueError('Application PID repeated across fresh-process runs')
        capture(['xdotool', 'windowmove', window, '0', '0'], timeout=2)
        capture(['xdotool', 'windowsize', '--sync', window, str(self.width), str(self.height)], timeout=2)
        geometry = dict(line.split('=', 1) for line in capture(
            ['xdotool', 'getwindowgeometry', '--shell', window], timeout=2).decode().splitlines() if '=' in line)
        if any(geometry.get(key) != str(value) for key, value in
               {'X': 0, 'Y': 0, 'WIDTH': self.width, 'HEIGHT': self.height}.items()):
            raise ValueError('Actual X11 window geometry differs from requested visible canvas')
        if time.monotonic() - started >= 20:
            raise TimeoutError('Owned GTK window was not resized within 20 seconds')
        self.used_pids.add(pid)
        self.evidence = {'pid': pid, 'windowId': window, 'executable': str(self.executable),
                         'processGroup': process.pid, 'x': 0, 'y': 0,
                         'width': self.width, 'height': self.height}


def integer(value, label, minimum=0, maximum=None):
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f'Invalid {label}')
    return value


def object_at(data, key):
    value = data.get(key)
    if not isinstance(value, dict):
        raise ValueError(f'Missing object: {key}')
    return value


def observations(data, key, minimum=1):
    values = data.get(key)
    if not isinstance(values, list) or not minimum <= len(values) <= MAX_OBSERVATIONS:
        raise ValueError(f'Missing or unbounded {key}')
    if any(not isinstance(value, dict) for value in values):
        raise ValueError(f'Invalid {key} records')
    return values


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[int((len(ordered) - 1) * fraction)]


def distribution(values):
    return {'median': percentile(values, .5), 'p95': percentile(values, .95), 'max': max(values)}


def expected_canvas(width, height):
    # WorldCircuitPanel's responsive viewport, remounted with shared-theme padding.
    scale = min((width - 40) / 48, 360 / 32)
    return {'surfaceWidth': width, 'surfaceHeight': height, 'dpr': 1,
            'left': 20, 'top': 20, 'width': 48 * scale, 'height': 32 * scale}


def validate_report(data, *, arm, width, height, source_commit, source_manifest_sha256, renderer):
    if not isinstance(data, dict):
        raise ValueError('Report must be an object')
    expected = {'schema': SCHEMA, 'status': 'success', 'cleanup': 'disposed',
                'referenceCommit': BASE, 'sourceCommit': source_commit,
                'sourceManifestSha256': source_manifest_sha256, 'renderer': renderer,
                'arm': arm, 'scenario': 'visible-generic-circuit-painter', 'buildMode': 'profile'}
    if any(data.get(key) != value for key, value in expected.items()):
        raise ValueError('Wrong target identity, profile mode, provenance or cleanup')
    if not HEX40.fullmatch(source_commit) or not HEX64.fullmatch(source_manifest_sha256) or not renderer:
        raise ValueError('Incomplete expected build provenance')
    scene = {'width': width, 'height': height, 'dpr': 1, 'columns': 48, 'rows': 32}
    if (data.get('scene') != scene or data.get('fixture') != FIXTURE or
            any(type(v) not in (int, float) for v in data['scene'].values())):
        raise ValueError('Scene or fixed fixture identity differs')
    for name in ('bytes', 'records', 'wireMask'):
        integer(data['fixture'][name], f'fixture {name}', FIXTURE[name], FIXTURE[name])
    expected_viewport = expected_canvas(width, height)
    for name in ('viewportBefore', 'viewportAfter'):
        viewport = object_at(data, name)
        if (viewport.keys() != expected_viewport.keys() or
                any(type(viewport[k]) not in (int, float) or not math.isfinite(viewport[k]) or
                    abs(viewport[k] - expected_viewport[k]) > 1e-6 for k in expected_viewport)):
            raise ValueError('Painter must occupy the exact stable responsive visible viewport')
    if data['viewportBefore'] != data['viewportAfter']:
        raise ValueError('Visible canvas bounds changed during measurement')
    oracle = data.get('oracleRgbaSha256')
    if not isinstance(oracle, str) or not HEX64.fullmatch(oracle):
        raise ValueError('Missing independent c61 pixel oracle')
    for name in ('pixelsBefore', 'pixelsAfter'):
        if data.get(name) != {'width': math.ceil(expected_viewport['width']),
                              'height': math.ceil(expected_viewport['height']), 'rgbaSha256': oracle}:
            raise ValueError('Visible painter pixels differ from the frozen oracle or target size')
    for name in ('droppedFrames', 'droppedPaints'):
        integer(data.get(name), name, maximum=0)
    integer(data.get('invalidationPeriodUs'), 'invalidation period', 16000, 16000)
    warmup = integer(object_at(data, 'warmup').get('elapsedUs'), 'warmup duration', 5000000, 8000000)
    window = object_at(data, 'window')
    start = integer(window.get('startUs'), 'window start')
    end = integer(window.get('endUs'), 'window end', start + 20000000, start + 25000000)
    elapsed = integer(window.get('elapsedUs'), 'window elapsed', end - start, end - start)
    invalidations = integer(window.get('invalidations'), 'invalidation count', 1, MAX_OBSERVATIONS)
    paint_count = integer(window.get('paints'), 'paint count', 1, MAX_OBSERVATIONS)
    frames, paints = observations(data, 'frames'), observations(data, 'paints')
    if len(paints) != paint_count:
        raise ValueError('Actual paint count differs from recorded observations')
    numbers, last_vsync, actual_frames = set(), -1, []
    for frame in frames:
        number = integer(frame.get('frameNumber'), 'frame number')
        stamp = integer(frame.get('vsyncStartUs'), 'vsync timestamp')
        if stamp <= last_vsync or number in numbers:
            raise ValueError('Duplicate or non-increasing actual frame observations')
        numbers.add(number)
        last_vsync = stamp
        membership = start <= stamp < end
        if type(frame.get('inWindow')) is not bool or frame['inWindow'] != membership:
            raise ValueError('Frame membership disagrees with its actual vsync timestamp')
        for name in ('buildUs', 'rasterUs', 'totalSpanUs'):
            integer(frame.get(name), name, maximum=RUN_SECONDS * 1000000)
        if frame['totalSpanUs'] < max(frame['buildUs'], frame['rasterUs']):
            raise ValueError('Frame span cannot be shorter than its component durations')
        if membership:
            actual_frames.append(frame)
    integer(data.get('windowFrameCount'), 'window frame count', len(actual_frames), len(actual_frames))
    if not actual_frames:
        raise ValueError('No actual Flutter frame in the recording window')
    last_paint = -1
    for paint in paints:
        stamp = integer(paint.get('startUs'), 'paint timestamp', start, end - 1)
        if stamp <= last_paint:
            raise ValueError('Duplicate or non-increasing actual paint observations')
        last_paint = stamp
        duration = integer(paint.get('durationUs'), 'paint duration', maximum=RUN_SECONDS * 1000000)
        if stamp + duration > end:
            raise ValueError('Synchronous paint observation extends beyond its recording window')
    return {'warmupElapsedUs': warmup, 'windowElapsedUs': elapsed,
            'invalidationCount': invalidations, 'paintCount': paint_count,
            'windowFrameCount': len(actual_frames), 'recordedFrameCount': len(frames),
            'paintUs': distribution([p['durationUs'] for p in paints]),
            **{name: distribution([f[name] for f in actual_frames])
               for name in ('buildUs', 'rasterUs', 'totalSpanUs')}}


def validate_series(reports, provenance):
    if len(reports) != len(SCENES) * len(ORDER):
        raise ValueError('Expected exactly twelve fresh-process reports')
    metrics, pixel_by_scene = [], {}
    for data, (width, height, arm) in zip(reports, [(w, h, a) for w, h in SCENES for a in ORDER]):
        metrics.append(validate_report(data, arm=arm, width=width, height=height, **provenance))
        key = (width, height)
        if key in pixel_by_scene and pixel_by_scene[key] != data['oracleRgbaSha256']:
            raise ValueError('Same visible scene produced different pixels across A/B processes')
        pixel_by_scene[key] = data['oracleRgbaSha256']
    return metrics


def read_report(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_REPORT_BYTES:
        raise ValueError('Missing, linked or oversized raw report')
    def reject_constant(value):
        raise ValueError(f'Non-finite JSON number: {value}')
    return json.loads(path.read_text(), parse_constant=reject_constant)


def interrupted(signum, frame):
    raise InterruptedError(f'Runner interrupted by signal {signum}')


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: circuit_painter_paired.py NEW_OUTPUT_DIRECTORY')
    deadline = time.monotonic() + GLOBAL_SECONDS
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    summary = {'schema': 'abc.circuit-painter-paired.v1', 'status': 'preparing',
               'referenceCommit': BASE, 'orderPerScene': list(ORDER),
               'scenes': [{'width': w, 'height': h} for w, h in SCENES], 'runs': [],
               'acceptedAsOptimization': False, 'buildCount': 1,
               'boundsSeconds': {'build': BUILD_SECONDS, 'run': RUN_SECONDS, 'global': GLOBAL_SECONDS},
               'method': 'One profile binary; frozen c61 A and production B; BAABBA fresh processes per visible canvas. No memory sampling. Counts and durations are not callback-derived FPS or an acceptance verdict.'}
    temporary = None
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        env = os.environ.copy()
        if sys.platform != 'linux' or not env.get('RUNNER_TEMP') or not env.get('DISPLAY'):
            raise ValueError('Official Linux CI, RUNNER_TEMP and a visible X11 display are required')
        renderer = env.get('TERRA_PERF_RENDERER', '')
        if not renderer or len(renderer) > 160:
            raise ValueError('Explicit TERRA_PERF_RENDERER identity required')
        flutter = shutil.which('flutter')
        if not flutter or not shutil.which('xdotool'):
            raise ValueError('Official pinned Flutter setup and xdotool must already be installed')
        env.update(CI='true', GDK_BACKEND='x11', GDK_SCALE='1', GDK_DPI_SCALE='1')
        head = capture(['git', 'rev-parse', '--verify', 'HEAD']).decode().strip()
        if not HEX40.fullmatch(head):
            raise ValueError('Full checkout source commit required')
        version = json.loads(capture([flutter, '--no-version-check', '--suppress-analytics', '--version', '--machine'], env=env))
        if version.get('frameworkVersion') != (ROOT / '.flutter-version').read_text().strip():
            raise ValueError('Flutter version differs from the repository pin')
        summary['baseline'] = verify_reference(capture(['git', 'show', f'{BASE}:{PRODUCT}']), (ROOT / REFERENCE).read_bytes())
        fixture = b''.join(struct.pack('<IIIhh', 40 + i % 48, 50 + i // 48,
                                      i % 13 | ((int(i % 4 == 0) | (2 if i % 17 == 0 else 0)) << 16) | 15 << 24,
                                      (i % 3) * 18, 0) for i in range(1536))
        if hashlib.sha256(fixture).hexdigest() != FIXTURE_SHA256:
            raise ValueError('Pinned fixture generator changed')
        sources = source_manifest(ROOT)
        write(output / 'source-manifest.json', {'sourceCommit': head, 'files': sources})
        manifest_hash = sha(output / 'source-manifest.json')
        provenance = {'source_commit': head, 'source_manifest_sha256': manifest_hash, 'renderer': renderer}
        summary.update(sourceCommit=head, sourceManifestSha256=manifest_hash,
                       fixture=FIXTURE, renderer=renderer,
                       environment={'os': platform.platform(), 'architecture': platform.machine(),
                                    'cpuCount': os.cpu_count(), 'flutter': version,
                                    'githubRunId': env.get('GITHUB_RUN_ID'),
                                    'githubRunAttempt': env.get('GITHUB_RUN_ATTEMPT'),
                                    'display': env['DISPLAY'], 'libglAlwaysSoftware': env.get('LIBGL_ALWAYS_SOFTWARE')})
        common = [f'--target={TARGET}', f'--dart-define=PAINTER_SOURCE_COMMIT={head}',
                  f'--dart-define=PAINTER_SOURCE_MANIFEST_SHA256={manifest_hash}',
                  f'--dart-define=PAINTER_RENDERER={renderer}']
        write(output / 'summary.json', summary)
        command([flutter, '--no-version-check', '--suppress-analytics', 'build', 'linux',
                 '--no-pub', '--profile', *common], output / 'build.log', BUILD_SECONDS, env, deadline)
        if sources != source_manifest(ROOT):
            raise ValueError('Tracked source bytes changed during the single profile build')
        temporary = Path(tempfile.mkdtemp(prefix='abc-circuit-painter-', dir=env['RUNNER_TEMP']))
        bundle = temporary / 'bundle'
        shutil.copytree(ROOT / 'build/linux/x64/profile/bundle', bundle)
        artifacts = artifact_manifest(bundle)
        write(output / 'artifact-manifest.json', artifacts)
        summary['artifactManifestSha256'] = sha(output / 'artifact-manifest.json')
        summary['status'] = 'measuring'
        reports, used_pids = [], set()
        for width, height in SCENES:
            for local_index, arm in enumerate(ORDER, 1):
                prefix = f'{width}x{height}-{local_index:02}-{arm}'
                report_path = output / f'{prefix}.json'
                if artifact_manifest(bundle) != artifacts:
                    raise ValueError('Single built bundle changed before a run')
                run_env = env | {'ABC_PAINTER_OUTPUT': str(report_path), 'ABC_PAINTER_ARM': arm,
                                 'ABC_PAINTER_WIDTH': str(width), 'ABC_PAINTER_HEIGHT': str(height)}
                visible = VisibleWindow(bundle / 'terraforge', width, height, used_pids)
                summary['activeRun'] = {'index': len(reports) + 1, 'arm': arm,
                                        'width': width, 'height': height, 'report': report_path.name}
                write(output / 'summary.json', summary)
                try:
                    command([flutter, '--no-version-check', '--suppress-analytics', 'drive',
                             '--no-pub', '--profile', '-d', 'linux', '--host-vmservice-port=0',
                             f'--driver={DRIVER}', f'--use-application-binary={bundle / "terraforge"}',
                             *common], output / f'{prefix}.log', RUN_SECONDS, run_env, deadline, visible)
                finally:
                    summary['activeRun']['window'] = visible.evidence
                    write(output / 'summary.json', summary)
                if not visible.evidence:
                    raise ValueError('Driver exited without a verified owned visible window')
                if artifact_manifest(bundle) != artifacts:
                    raise ValueError('Single built bundle changed during a run')
                report = read_report(report_path)
                metrics = validate_report(report, arm=arm, width=width, height=height, **provenance)
                reports.append(report)
                summary['runs'].append({'index': len(reports), 'sceneIndex': local_index,
                                        'arm': arm, 'width': width, 'height': height,
                                        'report': report_path.name, 'reportSha256': sha(report_path),
                                        'window': visible.evidence, 'metrics': metrics})
                summary.pop('activeRun')
                write(output / 'summary.json', summary)
        validate_series(reports, provenance)
        if len(used_pids) != 12 or sources != source_manifest(ROOT):
            raise ValueError('Fresh host identity or source provenance changed across runs')
        if time.monotonic() >= deadline:
            raise TimeoutError('Global 1500-second deadline expired')
        summary['status'] = 'complete-measurements-not-performance-acceptance'
    except BaseException as error:
        summary['status'] = 'failed-or-incomplete'
        summary['failure'] = safe_text(error)[:4096]
        raise
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        write(output / 'summary.json', summary)
        if temporary:
            shutil.rmtree(temporary)


if __name__ == '__main__':
    main()
