#!/usr/bin/env python3
"""Build one pinned target, then drive exactly one fresh Linux/profile process.

No retry, baseline arm, additional world cycle, allocator intervention or remote
write. Call only in the reviewed dedicated CI workflow, with new output paths.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time

import memory_probe_control_run as shared
import native_retention_prepare as source_checks
from native_retention_protocol import PRODUCT_COMMIT, PRODUCT_TREE, RetentionRequestProtocol

ROOT = Path(__file__).resolve().parents[2]
TARGET = 'integration_test/computer_native_retention_test.dart'
SCHEDULE = 'tool/perf/memory_probe_control_schedule.json'
BUILD_SECONDS, RUNTIME_SECONDS, DRIVER_SECONDS = 300, 600, 900
SCHEMA = 'abc.native-retention-execution.v1'


def commands(flutter, head, version, renderer, bundle):
    defines = [f'--dart-define=PERF_COMMIT={head}',
               f'--dart-define=PERF_CHECKED_OUT_HEAD={head}',
               '--dart-define=PERF_WORKTREE_DIRTY=false',
               f'--dart-define=PERF_FLUTTER_VERSION={version}',
               f'--dart-define=PERF_RENDERER={renderer}']
    common = [flutter, '--no-version-check', '--suppress-analytics']
    compile_target = [*common, 'build', 'linux', '--no-pub', '--profile',
                      f'--target={TARGET}', *defines]
    # The pinned SDK's LinuxApp.fromPrebuiltApp takes the executable path.
    # The same integration driver/VM service behavior is retained; no new VM
    # flags, authentication changes, existing-app attach or build retry.
    drive = [*common, 'drive', '--no-pub', '--profile', '-d', 'linux',
             '--host-vmservice-port=0', '--driver=test_driver/ui_profile_driver.dart',
             f'--target={TARGET}', f'--use-application-binary={bundle / "terraforge"}',
             *defines]
    return compile_target, drive


def verify_helper(manifest_path):
    manifest_path = Path(manifest_path).resolve()
    data = shared.read_json(manifest_path)
    if (data.get('schema') != 'abc.native-retention-helper-build.v1'
            or data.get('status') != 'built'
            or data.get('outsideApplicationCheckout') is not True
            or data.get('applicationLaunched') is not False
            or data.get('downloadedDependencies') is not False):
        raise shared.InvariantError('Verified independent helper build required')
    helper = Path(data.get('helperPath', ''))
    if (not helper.is_absolute() or helper.is_symlink() or not helper.is_file()
            or helper.parent.resolve() != manifest_path.parent
            or helper.name != data.get('helperFile')
            or helper.stat().st_size != data.get('helperBytes')
            or shared.digest(helper) != data.get('helperSha256')
            or data.get('source', {}).get('path') != 'tool/perf/native_retention_probe.c'
            or data['source'].get('sha256') != shared.digest(ROOT / data['source']['path'])):
        raise shared.InvariantError('Helper binary/source bytes differ from its build provenance')
    if ROOT == helper.parent or ROOT in helper.parents:
        raise shared.InvariantError('Helper must remain outside the application checkout')
    return helper, data


def verify_artifacts(build, bundle):
    paths = {'terraforge': bundle / 'terraforge',
             'libapp.so': bundle / 'lib/libapp.so',
             'libabc_engine.so': bundle / 'lib/libabc_engine.so'}
    for name, path in paths.items():
        expected = build.get('artifacts', {}).get(name)
        if (not expected or not path.is_file() or path.is_symlink()
                or path.stat().st_size != expected['bytes']
                or shared.digest(path) != expected['sha256']):
            raise shared.InvariantError('Precompiled application artifact changed: ' + name)
    if str(build.get('cmake', {}).get('ABC_PERF_COUNTERS')).upper() not in ('OFF', 'FALSE', '0'):
        raise shared.InvariantError('Ordinary counter-disabled native library required')
    return paths


def logged_process(argv, log_path, env, deadline, *, on_start=None, monitor=None):
    """Bounded complete sanitized log; terminate only this new process group."""
    process = reader = None
    state = {}
    stopped = False
    try:
        with Path(log_path).open('x') as output:
            process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            reader = threading.Thread(target=shared.drain_log,
                                      args=(process.stdout, output, state), daemon=True)
            reader.start()
            if on_start is not None:
                on_start(process)
            while process.poll() is None:
                if monitor is not None:
                    monitor(process)
                if state.get('error'):
                    raise ValueError(state['error'])
                if time.monotonic() >= deadline:
                    raise TimeoutError('Bounded build/driver deadline exceeded')
                time.sleep(0.02)
            if monitor is not None:
                monitor(process, final=True)
            return_code = process.returncode
            shared.stop_group(process)
            stopped = True
            reader.join(timeout=10)
            if reader.is_alive() or state.get('error'):
                raise ValueError(state.get('error', 'Log reader did not finish'))
            return return_code
    finally:
        if process is not None and not stopped:
            shared.stop_group(process)
        if reader is not None:
            reader.join(timeout=10)
        if process is not None and process.stdout is not None:
            process.stdout.close()


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        raise SystemExit('Usage: native_retention_run.py NEW_OUTPUT_DIRECTORY')
    requested = Path(args[0]).absolute()
    if requested.exists() or requested.is_symlink():
        raise SystemExit('New evidence directory required; prior evidence is immutable')
    output = requested.resolve()
    output.mkdir(parents=True)
    execution = output / 'execution.json'
    record = {'schema': SCHEMA, 'status': 'preparing', 'productCommit': PRODUCT_COMMIT,
              'productTree': PRODUCT_TREE, 'plannedCycles': 8, 'warmupCycles': [0, 1, 2, 3],
              'repeatCycles': [4, 5, 6, 7], 'plannedProcessInvocations': 1,
              'processInvocations': 0, 'buildInvocations': 0,
              'buildAndHelloTimeoutSeconds': BUILD_SECONDS,
              'runtimeTimeoutSeconds': RUNTIME_SECONDS, 'totalTimeoutSeconds': DRIVER_SECONDS,
              'startedAt': shared.now(), 'acceptanceEvidence': False,
              'plateauEstablished': False, 'memoryImprovementEstablished': False,
              'logSanitization': 'complete logs except local service URLs and auth tokens redacted',
              'github': {'runId': os.environ.get('GITHUB_RUN_ID'),
                         'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT')}}
    paths = {key: output / name for key, name in {
        'raw_report': 'native-retention.raw-report.json',
        'standalone': 'native-retention.standalone.json',
        'report': 'native-retention.json', 'raw': 'native-retention.raw',
        'build': 'native-retention.build.json',
        'compiler_build': 'native-retention.compiler-build.json',
        'summary': 'native-retention.summary.json',
        'requests': 'external-requests.jsonl', 'acks': 'external-acks',
        'os': 'external-os.jsonl', 'os_manifest': 'external-os.manifest.json',
        'probes': 'native-retention-probes.jsonl',
    }.items()}
    protocol = None
    provenance = helper_manifest = build = None
    derivation_path = helper_manifest_path = helper = None
    original_sigterm = signal.getsignal(signal.SIGTERM)
    global_started = time.monotonic()

    def save():
        shared.write_json(execution, record)

    def interrupt(signum, _frame):
        raise KeyboardInterrupt(f'Interrupted by signal {signum}')

    signal.signal(signal.SIGTERM, interrupt)
    shared.write_json(execution, record, new=True)
    try:
        if os.environ.get('CI') != 'true' or sys.platform != 'linux':
            raise shared.InvariantError('Dedicated Linux CI invocation required')
        # Do not silently normalize or change allocator configuration.
        unexpected = sorted(key for key in os.environ if key in ('LD_PRELOAD', 'LD_AUDIT',
                         'GLIBC_TUNABLES') or key.startswith('MALLOC_'))
        if unexpected:
            raise shared.InvariantError('Allocator/runtime override present: ' + ', '.join(unexpected))
        derivation_path = Path(os.environ['ABC_RETENTION_DERIVATION']).resolve()
        helper_manifest_path = Path(os.environ['ABC_RETENTION_HELPER_BUILD']).resolve()
        provenance = source_checks.verify_source(ROOT, derivation_path)
        head = provenance['derivedCommit']
        if provenance['baseCommit'] != PRODUCT_COMMIT or provenance['baseTree'] != PRODUCT_TREE:
            raise shared.InvariantError('Final product commit/tree pin differs')
        record['derivedCommit'] = head
        shared.write_json(output / 'source.json', provenance, new=True)
        shutil.copyfile(derivation_path, output / 'derivation.json')
        shutil.copyfile(derivation_path.parent / 'diagnostic-overlay.patch', output / 'diagnostic-overlay.patch')
        helper, helper_manifest = verify_helper(helper_manifest_path)
        shutil.copyfile(helper_manifest_path, output / 'helper-build.json')
        # Preserve the small helper's original logs, ABI contract and binaries
        # for standalone offline hash inspection. This owned build folder has
        # no app bundle, world, runtime authentication material or user files.
        shared.evidence_files(helper_manifest_path.parent)
        shutil.copytree(helper_manifest_path.parent, output / 'helper')
        links = {'sourceSha256': shared.digest(output / 'source.json'),
                 'derivationSha256': shared.digest(output / 'derivation.json'),
                 'helperBuildSha256': shared.digest(output / 'helper-build.json')}
        flutter = os.environ.get('FLUTTER_BIN', 'flutter')
        version = json.loads(shared.capture(flutter, '--no-version-check', '--suppress-analytics',
                                            '--version', '--machine'))['frameworkVersion']
        if version != (ROOT / '.flutter-version').read_text().strip():
            raise shared.InvariantError('Pinned Flutter version mismatch')
        renderer = os.environ.get('TERRA_PERF_RENDERER', '').strip()
        if not renderer or len(renderer) > 512 or '\n' in renderer:
            raise shared.InvariantError('Observed renderer required')
        world = shared.verify_world()
        if world != (ROOT / 'build/public-computerraria/computerraria.wld').resolve():
            raise shared.InvariantError('Only the existing pinned public fixture path is allowed')
        record['input'] = {'bytes': shared.WLD_BYTES, 'sha256': shared.WLD_SHA256}
        bundle = ROOT / 'build/linux/x64/profile/bundle'
        if bundle.exists():
            raise shared.InvariantError('Fresh checkout must not already contain a profile bundle')
        build_command, drive_command = commands(flutter, head, version, renderer, bundle)
        record.update(compileCommand=build_command, driverCommand=drive_command,
                      flutterVersion=version, renderer=renderer, status='compiling')
        paths['acks'].mkdir()
        env = dict(os.environ)
        env.update(ABC_PERF_COMMIT=head, ABC_RETENTION_HELPER=str(helper),
                   ABC_RETENTION_PROBE_JOURNAL=str(paths['probes']),
                   ABC_CONTROL_SCHEDULE=str(ROOT / SCHEDULE),
                   ABC_CONTROL_REQUESTS=str(paths['requests']),
                   ABC_CONTROL_ACK_DIRECTORY=str(paths['acks']),
                   ABC_MEMORY_RAW_DIRECTORY=str(paths['raw']),
                   TERRA_UI_PROFILE_OUTPUT=str(paths['raw_report']),
                   TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(paths['standalone']),
                   COMPUTERRARIA_WLD=str(world))
        timed_started = time.monotonic()
        deadline = timed_started + DRIVER_SECONDS
        record['boundedBuildStartedAt'] = shared.now()
        record['buildInvocations'] = 1
        save()
        code = logged_process(build_command, output / 'compile.log', env,
                              timed_started + BUILD_SECONDS)
        record['buildExitCode'] = code
        if code:
            raise ValueError(f'Profile target compilation failed: {code}')
        source_checks.check_source_unchanged(ROOT, derivation_path, provenance)
        previous_commit = os.environ.get('ABC_PERF_COMMIT')
        os.environ['ABC_PERF_COMMIT'] = head
        try:
            shared.record_provenance([bundle / 'terraforge', bundle / 'lib/libapp.so',
                                      bundle / 'lib/libabc_engine.so'], paths['compiler_build'])
        finally:
            if previous_commit is None:
                os.environ.pop('ABC_PERF_COMMIT', None)
            else:
                os.environ['ABC_PERF_COMMIT'] = previous_commit
        build = shared.read_json(paths['compiler_build'])
        verify_artifacts(build, bundle)
        links.update(helperSha256=helper_manifest['helperSha256'],
                     nativeEngineSha256=build['artifacts']['libabc_engine.so']['sha256'])
        build['nativeRetentionProvenance'] = links
        shared.write_json(paths['build'], build, new=True)
        record['status'] = 'running'

        def on_start(process):
            nonlocal protocol
            record.update(processInvocations=1, driverPid=process.pid)
            protocol = RetentionRequestProtocol(paths['requests'], paths['acks'], paths['os'], process.pid)
            save()

        def monitor(_process, final=False):
            protocol.poll(final=final)
            current = time.monotonic()
            if protocol.started_at is None and current - timed_started >= BUILD_SECONDS:
                raise TimeoutError('Bounded build-and-hello deadline exceeded')
            if protocol.started_at is not None and current - protocol.started_at >= RUNTIME_SECONDS:
                raise TimeoutError('Bounded application runtime exceeded')

        code = logged_process(drive_command, output / 'drive.log', env, deadline,
                              on_start=on_start, monitor=monitor)
        record['driverExitCode'] = code
        if code:
            raise ValueError(f'Profile integration driver failed: {code}')
        source_checks.check_source_unchanged(ROOT, derivation_path, provenance)
        verify_helper(helper_manifest_path)
        verify_artifacts(build, bundle)
        record.update(sourceUnchangedAfterRun=True, helperUnchangedAfterRun=True,
                      productBinariesUnchangedAfterRun=True, status='observed')
    except (Exception, KeyboardInterrupt) as error:
        record.update(status=('interrupted' if isinstance(error, KeyboardInterrupt) else
                              'timeout' if isinstance(error, TimeoutError) else 'failed'),
                      failure=shared.safe_text(error)[:4096])
    finally:
        signal.signal(signal.SIGTERM, original_sigterm)
        record['ownedProcessGroupTerminationAttempted'] = record['processInvocations'] == 1
        if protocol is not None:
            record.update(applicationHostPid=protocol.pid,
                          externalProtocolRequests=protocol.sequence,
                          externalProtocolFinished=protocol.finished)
            try:
                protocol.close()
            except Exception as error:
                record.update(status='failed', externalSamplerFailure=shared.safe_text(error)[:4096])
            descriptor = protocol.descriptor()
            if descriptor is not None:
                shared.write_json(paths['os_manifest'], descriptor, new=True)
        try:
            launch_path = paths['raw_report'] if paths['raw_report'].exists() else paths['standalone']
            if build is not None and launch_path.exists() and protocol is not None:
                launch = shared.read_json(launch_path)
                if (launch.get('schema') != 'abc.native-retention.v1'
                        or launch.get('baseProductCommit') != PRODUCT_COMMIT
                        or launch.get('runtime', {}).get('commit') != record.get('derivedCommit')
                        or launch.get('hostPid') != protocol.pid or protocol.pid is None):
                    raise shared.InvariantError('Target report is not from the verified fresh process')
                launch['runtime'].update({
                    'buildProvenanceSha256': shared.digest(paths['build']),
                    'sourceTreeSha256': build['sourceTreeSha256'],
                    'provenanceAttachment': 'single-diagnostic-runner-after-process',
                    'nativeRetentionProvenance': build['nativeRetentionProvenance'],
                    'nativeRetentionExecution': {
                        key: record.get(key) for key in (
                            'sourceUnchangedAfterRun', 'helperUnchangedAfterRun',
                            'productBinariesUnchangedAfterRun', 'buildExitCode',
                            'driverExitCode', 'processInvocations')
                    },
                    'rawTargetReport': {'file': launch_path.name, 'sha256': shared.digest(launch_path)},
                })
                launch['externalOs'] = protocol.descriptor()
                shared.write_json(paths['report'], launch, new=True)
                validator = [sys.executable, str(ROOT / 'tool/perf/native_retention_validate.py'),
                             str(paths['report']), '--raw-directory', str(paths['raw']),
                             '--build', str(paths['build']), '--external-os', str(paths['os_manifest']),
                             '--expected-commit', record['derivedCommit'], '--output', str(paths['summary'])]
                code = logged_process(validator, output / 'validator.log', dict(os.environ),
                                      time.monotonic() + 60)
                record['validatorExitCode'] = code
                summary = shared.read_json(paths['summary'])
                record['validationStatus'] = summary.get('status')
                record['allocatorAttributionAvailable'] = summary.get('allocatorAttributionAvailable', False)
                if record['status'] == 'observed':
                    record['status'] = ('completed' if code == 0 and summary.get('evidenceValid') else 'failed')
                    if record['status'] == 'completed' and not record['allocatorAttributionAvailable']:
                        record['status'] = 'completed-inconclusive'
        except Exception as error:
            record.update(status='failed', finalizationFailure=shared.safe_text(error)[:4096])
        if not paths['summary'].exists():
            shared.write_json(paths['summary'], {
                'schema': 'abc.native-retention-validation.v1', 'status': 'incomplete',
                'evidenceValid': False, 'allocatorAttributionAvailable': False,
                'acceptanceEvidence': False, 'plateauEstablished': False,
                'memoryImprovementEstablished': False,
                'errors': [record.get('failure', record.get('finalizationFailure', record['status']))],
            }, new=True)
        record.update(completedAt=shared.now(), elapsedSeconds=time.monotonic() - global_started)
        try:
            record['files'] = shared.evidence_files(output, exclude=(execution,))
            if any(name.lower().endswith(('.wld', '.twld')) for name in record['files']):
                raise shared.InvariantError('World files must never enter evidence')
        except Exception as error:
            record.update(status='failed', inventoryFailure=shared.safe_text(error)[:4096])
        save()
    print(json.dumps({'status': record['status'], 'execution': str(execution),
                      'summary': str(paths['summary'])}))
    return 0 if record['status'] in ('completed', 'completed-inconclusive') else 1


if __name__ == '__main__':
    raise SystemExit(main())
