#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# One actual profile application; the Python supervisor retains failure evidence
# and stops this invocation's process group at the fixed 20-minute deadline.
exec python3 - "${1:?A new diagnostic report .json path is required}" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

sys.path[:0] = ['tool', 'tool/perf']
from computerraria_inputs import WORLD, verified
from computerraria_provenance import record as record_build


TIMEOUT_SECONDS = 1200
SCHEMA = 'abc.computerraria-dynamic-ui.v1'
WORKLOAD_ID = 'public-derived-computerraria-external-clock-v1'
LOCAL_SERVICE = re.compile(r'(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?[^\s<>"\']*')


def sanitize(text):
    return LOCAL_SERVICE.sub('[redacted-local-service-url]', text)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def capture(*argv):
    return subprocess.check_output(argv, text=True, timeout=60).strip()


def stop_group(process):
    for sig, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 1)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            continue
        # The driver may exit before the app and its VM service.
        if sig == signal.SIGTERM:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    process.wait()


def identity(payload, head):
    runtime = payload.get('runtime', {})
    if (payload.get('schema') != SCHEMA or payload.get('workloadId') != WORKLOAD_ID or
            runtime.get('commit') != head or
            runtime.get('checkedOutHead') != head or
            runtime.get('workingTreeDirty') is not False or
            type(runtime.get('hostPid')) is not int or runtime['hostPid'] < 1):
        raise ValueError('Report does not identify this clean diagnostic target')


def validate_result(payload):
    if payload.get('status') != 'passed' or payload.get('failure') or payload.get('cleanupFailure'):
        raise ValueError('Dynamic test did not report a passed result without failure')
    if payload.get('originalSourceHashPreserved') is not True:
        raise ValueError('Original public source preservation is unverified')
    if payload.get('modes') != ['standard', 'optimized']:
        raise ValueError('The separate OFF and ON modes were not both reported')
    rows = payload.get('modeResults')
    if not isinstance(rows, list) or len(rows) != 2:
        raise ValueError('Exactly two completed mode results are required')
    if [row.get('mode') for row in rows] != ['standard', 'optimized']:
        raise ValueError('Mode results are missing, reordered, or duplicated')
    for row in rows:
        if (row.get('status') != 'passed' or row.get('actualPixelCount') != 3072 or
                any(row.get(field) is not True for field in (
                    'savedChangedDerived', 'reopenPreservedPixels', 'reopenPreservedRam',
                    'continuationMatched', 'resetRestoredPreparedPixels',
                    'reopenHadNoImplicitMutations', 'closeBoundaryPassed',
                    'closeBeganWhileClockArmed'))):
            raise ValueError(f'Incomplete visible/save/reopen evidence for {row.get("mode")}')
        fixed = row.get('fixedTrace')
        if not isinstance(fixed, list) or len(fixed) != 12:
            raise ValueError('Each mode must retain all 12 fixed electrical batches')
        validate_frames(fixed)
        if row.get('fixedDistinctFrames') != len({frame['rgbaSha256'] for frame in fixed}):
            raise ValueError('Fixed distinct-frame summary differs from the retained actual frames')
    if rows[0].get('fixedTraceExpectedDark') is not True:
        raise ValueError('Standard mode lacks the expected dark physical trace assertion')
    if any(frame['litPixels'] != 0 for frame in rows[0]['fixedTrace']):
        raise ValueError('Standard fixed trace contradicts its expected-dark assertion')
    nontrivial = {frame['rgbaSha256'] for frame in rows[1]['fixedTrace'] if 0 < frame['litPixels'] < 3072}
    if len(nontrivial) < 3:
        raise ValueError('Optimized fixed trace lacks three distinct nontrivial actual frames')
    dynamic = rows[1].get('dynamicFrames')
    if not isinstance(dynamic, list) or not dynamic:
        raise ValueError('Optimized dynamic actual-pixel frames are missing')
    validate_frames(dynamic)
    changed = rows[1].get('dynamicChangedFrames')
    if (type(changed) is not int or changed < 2 or
            changed > len({frame['rgbaSha256'] for frame in dynamic}) - 1):
        raise ValueError('Optimized mode lacks at least two actual changed dynamic frames')
    observed = rows[1]
    visible = observed.get('visibleImageSamples')
    if (observed.get('pauseStoppedClockWhileArmed') is not True or
            observed.get('dynamicWorkloadKind') != 'observed-dynamic-with-bounded-image-readback' or
            not isinstance(visible, list) or not 3 <= len(visible) <= 64 or
            observed.get('visibleProbeCount') != len(visible)):
        raise ValueError('Running actual-image observations or armed pause boundary are missing')
    for sample in visible:
        if (sample.get('status') != 'completed' or sample.get('width') != 64 or
                sample.get('height') != 48 or sample.get('monitorFullyVisible') is not True or
                sample.get('source') != 'actual-production-RawImage-clone-readback' or
                type(sample.get('readbackWallUs')) is not int or sample['readbackWallUs'] < 0):
            raise ValueError('Actual image probe is incomplete')
    matched = {sample['rgbaSha256'] for sample in visible} & {frame['rgbaSha256'] for frame in dynamic}
    if (len(matched) < 3 or observed.get('visibleDistinctMatchedNativeFrames') != len(matched) or
            changed > len(matched) - 1 or
            observed.get('visibleProbeWallUs') != sum(sample['readbackWallUs'] for sample in visible)):
        raise ValueError('Visible image changes or observation overhead are unverified')


def validate_frames(frames):
    for frame in frames:
        if (not isinstance(frame, dict) or frame.get('recordCount') != 3072 or
                not re.fullmatch(r'[0-9a-f]{64}', str(frame.get('rgbaSha256', ''))) or
                type(frame.get('litPixels')) is not int or not 0 <= frame['litPixels'] <= 3072):
            raise ValueError('An actual-pixel frame is missing or malformed')


def validate_screenshots(payload, directory):
    root = directory.resolve()
    paths = []
    for row in payload['modeResults']:
        captures = row.get('screenshots')
        if not isinstance(captures, list) or not captures:
            raise ValueError(f'Missing screenshot evidence for {row["mode"]}')
        labels = ['prepared', 'fixed-trace']
        if row['mode'] == 'optimized':
            labels.append('dynamic-paused')
        labels.append('reopened')
        if [capture.get('label') for capture in captures] != labels:
            raise ValueError('Prepared, dynamic/fixed and reopened screenshot stages are incomplete')
        for capture in captures:
            expected = f'screenshots/{row["mode"]}-{capture["label"]}.png'
            if capture.get('path') != expected:
                raise ValueError('Screenshot path is not the named mode/stage capture')
            path = root / expected
            if (path.is_symlink() or not path.is_file() or
                    not path.resolve().is_relative_to(root / 'screenshots')):
                raise ValueError(f'Screenshot is missing or outside the evidence directory: {expected}')
            with path.open('rb') as stream:
                signature = stream.read(8)
            if signature != b'\x89PNG\r\n\x1a\n' or digest(path) != capture.get('pngSha256'):
                raise ValueError(f'Screenshot PNG signature or recorded SHA-256 differs: {expected}')
            if (not re.fullmatch(r'[0-9a-f]{64}', str(capture.get('rgbaSha256', ''))) or
                    capture.get('decodedImageSha256') != capture['rgbaSha256'] or
                    capture.get('captureOutsideTimedSteadyWindow') is not True):
                raise ValueError(f'Screenshot decoded-pixel/timing evidence is incomplete: {expected}')
            paths.append(expected)
    return paths


def main():
    report = Path(sys.argv[1]).resolve()
    if report.suffix != '.json':
        raise SystemExit('Report path must end in .json')
    paths = {name: report.with_suffix(suffix) for name, suffix in (
        ('execution', '.execution.json'), ('log', '.log'),
        ('standalone', '.standalone.json'), ('build', '.build.json'),
        ('inputs', '.inputs.json'))}
    if any(path.exists() for path in [report, *paths.values()]):
        raise SystemExit('Use a fresh report path; previous evidence is immutable')
    screenshots = report.parent / 'screenshots'
    if screenshots.exists():
        raise SystemExit('Use a fresh diagnostic directory; previous screenshots are immutable')
    report.parent.mkdir(parents=True, exist_ok=True)
    record = {
        'schema': 'abc.computerraria-dynamic-execution.v1',
        'status': 'preflight', 'processInvocations': 0,
        'timeoutSeconds': TIMEOUT_SECONDS, 'plannedModes': ['standard', 'optimized'],
        'plannedFixedTracePerMode': {'batches': 12, 'pulsesPerBatch': 128},
        'plannedOptimizedDynamicSeconds': 15,
        'startedAt': datetime.now(timezone.utc).isoformat(),
        'logSanitization': 'local-service-URLs-redacted-before-persistence',
        'github': {'runId': os.getenv('GITHUB_RUN_ID'),
                   'runAttempt': os.getenv('GITHUB_RUN_ATTEMPT')},
    }
    started = time.monotonic()
    process = None
    head = None

    def save():
        paths['execution'].write_text(json.dumps(record, indent=2) + '\n')

    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f'Invocation interrupted by signal {signum}')

    signal.signal(signal.SIGTERM, interrupted)
    save()
    try:
        head = capture('git', 'rev-parse', '--verify', 'HEAD')
        record['checkedOutHead'] = head
        record['requestedCommit'] = os.environ.get('ABC_PERF_COMMIT', head)
        if head != os.environ.get('ABC_PERF_COMMIT', head):
            raise ValueError('Requested source commit differs from checkout')
        if capture('git', 'status', '--porcelain', '--untracked-files=normal'):
            raise ValueError('A clean committed product and diagnostic snapshot is required')
        record['sourceCommit'] = head
        record['diagnosticSourcesSha256'] = {
            path: digest(path) for path in (
                '.github/workflows/computerraria-dynamic-diagnostic.yml',
                '.github/actions/setup-flutter/action.yml',
                '.github/actions/setup-performance/action.yml',
                '.flutter-version',
                'integration_test/computerraria_dynamic_profile_test.dart',
                'integration_test/support/computerraria_dynamic_backend.dart',
                'test/computerraria_dynamic_backend_test.dart',
                'test_driver/ui_profile_driver.dart',
                'tool/perf/computerraria_dynamic_profile.sh',
                'tool/perf/COMPUTERRARIA_DYNAMIC_DIAGNOSTIC.md',
            )
        }
        flutter = os.environ.get('FLUTTER_BIN', 'flutter')
        version = json.loads(capture(
            flutter, '--no-version-check', '--suppress-analytics',
            '--version', '--machine'))['frameworkVersion']
        if version != Path('.flutter-version').read_text().strip() or version != '3.47.6':
            raise ValueError('Pinned Flutter 3.47.6 is required')
        source = Path(os.environ['COMPUTERRARIA_WLD'])
        if (not source.is_absolute() or
                source.resolve() != Path('build/public-computerraria/computerraria.wld').resolve() or
                not verified(source, WORLD)):
            raise ValueError('Only the verified pinned public WLD is permitted')
        pong = Path(os.environ['COMPUTERRARIA_PONG'])
        pong_provenance = json.loads(Path('vendor/computerraria/pong-provenance.json').read_text())
        pong_spec = next(row for row in pong_provenance['files']
                         if row['path'] == 'pong-build/output/pong.bin')
        if (not pong.is_absolute() or
                pong.resolve() != Path('test/fixtures/computerraria/pong.bin').resolve() or
                not verified(pong, pong_spec)):
            raise ValueError('Only the verified test/fixtures/computerraria/pong.bin is permitted')
        renderer = os.environ['TERRA_PERF_RENDERER'].strip()
        if not renderer or renderer == 'unspecified':
            raise ValueError('An observed glxinfo renderer is required')
        temporary = Path(os.environ['TMPDIR']).resolve()
        temporary.mkdir(parents=True, exist_ok=True)
        if temporary == report.parent or report.parent in temporary.parents or temporary in report.parent.parents:
            raise ValueError('Temporary WLD storage must be separate from report artifacts')
        bundle = Path('build/linux/x64/profile/bundle')
        prebuilt_path = os.environ.get('ABC_DYNAMIC_PREBUILT_MANIFEST')
        prebuilt = None
        if prebuilt_path:
            prebuilt = json.loads(Path(prebuilt_path).read_text())
            if (prebuilt.get('schema') != 'abc.computerraria.build.v1' or
                    prebuilt.get('source') != {'commit': head, 'checkedOutHead': head, 'dirty': False}):
                raise ValueError('Prebuilt manifest is not this clean committed arm')
            for name, value in prebuilt['sourceFilesSha256'].items():
                if digest(name) != value:
                    raise ValueError('Prebuilt source hash mismatch: ' + name)
            for name, relative in (('terraforge', 'terraforge'),
                                   ('libabc_engine.so', 'lib/libabc_engine.so'),
                                   ('libapp.so', 'lib/libapp.so')):
                actual = bundle / relative
                if digest(actual) != prebuilt['artifacts'][name]['sha256']:
                    raise ValueError('Prebuilt artifact mismatch: ' + name)
            record['prebuiltManifestSha256'] = digest(prebuilt_path)
            record['buildPolicy'] = 'verified-prebuilt-fresh-process-no-rebuild'
        elif bundle.exists():
            raise ValueError('A fresh profile build directory is required; no prior bundle may be attributed')
        paths['inputs'].write_text(json.dumps({
            'schema': 'abc.computerraria-dynamic-inputs.v1',
            'world': WORLD,
            'program': {'path': 'test/fixtures/computerraria/pong.bin',
                        'bytes': pong_spec['bytes'], 'sha256': pong_spec['sha256']},
            'sourceCommit': head,
            'privacy': 'Public pinned input only; WLD inputs and saved exports are excluded from artifacts.',
        }, indent=2) + '\n')
        env = dict(os.environ, TERRA_UI_PROFILE_OUTPUT=str(report),
                   TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(paths['standalone']))
        argv = [flutter, '--no-version-check', '--suppress-analytics', 'drive',
                '--no-pub', '--profile', '-d', 'linux', '--host-vmservice-port=0',
                '--driver=test_driver/ui_profile_driver.dart',
                '--target=integration_test/computerraria_dynamic_profile_test.dart',
                f'--dart-define=PERF_COMMIT={head}',
                f'--dart-define=PERF_CHECKED_OUT_HEAD={head}',
                '--dart-define=PERF_WORKTREE_DIRTY=false',
                f'--dart-define=PERF_FLUTTER_VERSION={version}',
                f'--dart-define=PERF_RENDERER={renderer}',
                f'--dart-define=PERF_RUNNER={os.getenv("TERRA_PERF_RUNNER", "local-linux-xvfb")}']
        if prebuilt is not None:
            argv.append(f'--use-application-binary={bundle.resolve() / "terraforge"}')
        record.update({'status': 'running', 'command': argv})
        save()
        with paths['log'].open('x') as output:
            process = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True,
                                       errors='replace', start_new_session=True)
            record.update({'driverPid': process.pid, 'processInvocations': 1})
            save()

            reader_errors = []

            def drain():
                try:
                    for line in process.stdout:
                        output.write(sanitize(line))
                        output.flush()
                except Exception as error:
                    reader_errors.append(sanitize(str(error)))

            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            try:
                record['exitCode'] = process.wait(timeout=TIMEOUT_SECONDS)
                record['status'] = 'completed' if process.returncode == 0 else 'failed'
            except subprocess.TimeoutExpired:
                record['status'] = 'timeout'
            except KeyboardInterrupt:
                record['status'] = 'interrupted'
            finally:
                stop_group(process)
                record.setdefault('exitCode', process.returncode)
                reader.join(timeout=10)
                record['logReaderFinished'] = not reader.is_alive()
                record['logReaderErrors'] = reader_errors
                record['ownedProcessGroupTerminationAttempted'] = True
        # Hash actual outputs even if the test or compilation failed. A partial
        # build is explicitly incomplete, never reused from another invocation.
        artifacts = [bundle / 'terraforge', bundle / 'lib/libabc_engine.so',
                     bundle / 'lib/libapp.so']
        record['availableBuildArtifacts'] = {
            str(path): {'sha256': digest(path), 'bytes': path.stat().st_size}
            for path in artifacts if path.is_file()
        }
        cache = Path('build/linux/x64/profile/CMakeCache.txt')
        ninja = Path('build/linux/x64/profile/build.ninja')
        if all(path.is_file() for path in [*artifacts, cache, ninja]):
            record_build([str(path) for path in artifacts], paths['build'], cache, ninja)
            build = json.loads(paths['build'].read_text())
            if prebuilt is not None and build != prebuilt:
                raise ValueError('Prebuilt source/artifact manifest changed while running')
            if build['cmake'].get('ABC_PERF_COUNTERS') != 'OFF':
                raise ValueError('Diagnostic requires the ordinary counter-disabled native profile build')
            record['buildProvenanceRecorded'] = True
        else:
            record['buildProvenanceRecorded'] = False
        copies = [path for path in (report, paths['standalone']) if path.is_file()]
        if not copies:
            raise ValueError('No target report; no successful dynamic evidence was produced')
        host_pid = None
        for path in copies:
            payload = json.loads(path.read_text())
            identity(payload, head)
            report_pid = payload['runtime']['hostPid']
            if host_pid is not None and report_pid != host_pid:
                raise ValueError('Driver and standalone reports identify different target processes')
            host_pid = report_pid
            record['diagnosticTargetReported'] = True
            if record['buildProvenanceRecorded']:
                payload['runtime'].update({
                    'buildProvenanceSha256': digest(paths['build']),
                    'sourceTreeSha256': build['sourceTreeSha256'],
                    'provenanceAttachment': 'single-dynamic-diagnostic-runner-after-process',
                })
            path.write_text(sanitize(json.dumps(payload, indent=2)) + '\n')
        record['applicationHostPid'] = host_pid
        if not report.is_file():
            raise ValueError('Driver report is missing; standalone evidence is partial only')
        result = json.loads(report.read_text())
        record['testStatus'] = result.get('status')
        record['testLastStage'] = result.get('lastStage')
        record['testFailure'] = result.get('failure')
        validate_result(result)
        record['verifiedScreenshots'] = validate_screenshots(result, report.parent)
        record['resultValidation'] = 'passed'
        if (not record['buildProvenanceRecorded'] or not record.get('logReaderFinished') or
                record.get('logReaderErrors')):
            raise ValueError('Build provenance or complete diagnostic log is missing')
    except (Exception, KeyboardInterrupt) as error:
        if record['status'] not in ('timeout', 'interrupted'):
            record['status'] = 'failed'
        record['failure'] = sanitize(str(error))
    finally:
        if process is not None and process.poll() is None:
            stop_group(process)
        # Error text in reports can contain a VM service URL as well.
        for path in (report, paths['standalone']):
            if path.is_file():
                path.write_text(sanitize(path.read_text(errors='replace')))
        record['completedAt'] = datetime.now(timezone.utc).isoformat()
        record['elapsedSeconds'] = time.monotonic() - started
        record['files'] = {
            path.name: {'sha256': digest(path), 'bytes': path.stat().st_size}
            for path in [report, *[value for key, value in paths.items() if key != 'execution']]
            if path.is_file()
        }
        record['screenshots'] = {
            str(path.relative_to(report.parent)): {'sha256': digest(path), 'bytes': path.stat().st_size}
            for path in sorted(screenshots.rglob('*.png')) if path.is_file()
        }
        save()
    print(json.dumps({'status': record['status'], 'report': str(report),
                      'execution': str(paths['execution']),
                      'failure': record.get('failure')}))
    return 0 if record['status'] == 'completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
PY
