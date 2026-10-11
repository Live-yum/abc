#!/usr/bin/env python3
"""One explicit integration build, one control then one product, no retries.

This is an actual GitHub-CI entrypoint, never an offline test substitute. New
stack evidence is separate from the original reports and acceptance result.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time

import dependencies
from dependencies import ROOT, HERE, CONTRACTS
from application_contract import (CUTS, MAX_RAW, OsJournalTail, arm_completion,
    bounded_bytes, check_sidecar_caps, inspect_sidecar, require, validate_official_raw)
from bounded_supervision import PairBudget, TargetProcessIdentity
from prebuilt_contract import (ARMS, SDK_COMMIT, SDK_VERSION, TARGET, bind_runtime_entry,
                               bind_source_target, commands, verify_commands)
from application_process import clean_environment, read_json, run_command, save
from application_source import BASE, BRANCH, verify_source_proof
from capture_contract import (CLOCK, CutWatcher, GaugeTail, sidecar_caps,
                              validate_probe_finish, validate_startup)
from elf_identity import BoundModules, endpoint_delta, file_identity
from helper_config import write_config
from memory_ownership_run import publish_ready, validate_target
from memory_ownership_validate import validate_arm, validate_group
from memory_probe_control_os import _OwnedProcess
from run_preflight import check_official_diagnostics

SCHEDULE = ROOT / 'tool/perf/memory_ownership_schedule.json'
WLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
KNOWN_IMAGE_FAILURE = 'ownership: product image callback observation never fired'


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1 << 20), b''):
            result.update(data)
    return result.hexdigest()


def actual_ci_guard(environment):
    require(environment.get('GITHUB_ACTIONS') == 'true' and environment.get('CI') == 'true'
            and environment.get('GITHUB_REF') == BRANCH and environment.get('GITHUB_RUN_ATTEMPT') == '1',
            'Actual application pair is fixed-branch first-attempt GitHub CI only')
    require(sys.platform == 'linux'
            and time.get_clock_info('monotonic').implementation == 'clock_gettime(CLOCK_MONOTONIC)',
            'Verified shared Linux native/Python monotonic clock required; Dart clock stays separate')


def check_package(proof):
    require(proof.get('status') == 'official-package-identity-only'
            and proof.get('packageIdentityPassed') is True
            and proof.get('applicationInvocations') == proof.get('profiledFixtureInvocations') == 0,
            'Official unchanged package-only identity gate absent')
    paths = proof['toolPaths']
    require(paths['preload'] == '/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16'
            and paths['pprof'] == '/usr/bin/google-pprof', 'Official tool paths differ')
    for role, package in (('preload', 'libgoogle-perftools4t64'), ('pprof', 'google-perftools')):
        observed = file_identity(Path(paths[role]))
        expected = proof['packageIdentity'][package]['installedFiles'][paths[role]]
        require({key: observed[key] for key in ('sha256', 'bytes')} == expected,
                'Official installed file changed after package gate')
    return paths


def runtime_environment(source, arm, folder, helper, stack_helper):
    env = clean_environment(source)
    env.update(MEMORY_OWNER_ARM=arm, ABC_STACK_ARM=arm,
               ABC_OWNER_SCHEDULE=str(SCHEDULE), ABC_OWNER_LIBC_HELPER=str(helper),
               ABC_STACK_HELPER=str(stack_helper), ABC_OWNER_HELLO=str(folder / 'hello.json'),
               ABC_OWNER_READY=str(folder / 'ready.json'), ABC_MEMORY_RAW_DIRECTORY=str(folder / 'raw'),
               TERRA_UI_PROFILE_OUTPUT=str(folder / 'report.json'),
               TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(folder / 'standalone.json'))
    if arm == ARMS[0]:
        env.pop('COMPUTERRARIA_WLD', None)
    return env


def exact_profile_files(directory, *, final=False):
    directory = Path(directory)
    allowed = {'launch.once', 'dart-probe.json', 'q0.ack', 'q7.ack',
               'q0.receipt', 'q7.receipt', 'q0.before.maps', 'q0.after.maps',
               'q7.before.maps', 'q7.after.maps', 'heap.0001.heap', 'heap.0002.heap'}
    if not final:
        allowed |= {name + '.pending' for name in ('q0.ack', 'q7.ack', 'q0.receipt', 'q7.receipt')}
        allowed |= {'dart-probe.json.pending'}
    actual = {path.name for path in directory.iterdir()}
    require(actual <= allowed and (not final or actual == allowed), 'Unexpected/missing application sidecar including extra exit dump')
    check_sidecar_caps(directory, max_heaps=2)
    return allowed


class PairRunner:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.shared = self.output / 'stack-attribution'
        self.shared.mkdir(mode=0o700)
        self.folders, self.dirs = {}, {}
        for arm in ARMS:
            folder = self.output / arm
            folder.mkdir(mode=0o700)
            self.folders[arm] = folder
            sidecar = folder / 'stack-attribution'
            sidecar.mkdir(mode=0o700)
            self.dirs[arm] = sidecar
        self.sidecars = [self.shared, *self.dirs.values()]
        self.budget = PairBudget(time.monotonic())
        self.source = read_json(args.source_proof)
        self.source_sha = sha(args.source_proof)
        self.head = self.source['sourceCommit']
        self.package = read_json(args.package_proof)
        self.paths = check_package(self.package)
        self.environment = clean_environment(dict(os.environ, ABC_PERF_COMMIT=self.head))
        self.native = None
        self.results, self.executions, self.sidecar_results = [], [], []
        self.group = {'schema': 'abc.memory-ownership-group.v1', 'status': 'running',
                      'sourceCommit': self.head, 'baseProductCommit': BASE,
                      'sourceProvenanceSha256': self.source_sha, 'scheduleSha256': sha(SCHEDULE),
                      'armOrder': list(ARMS), 'executions': self.executions}
        self.application = {'schema': 'abc.gperftools-application-pair.v1', 'status': 'running',
                            'sourceCommit': self.head, 'buildInvocations': 0,
                            'actualArmOrder': [], 'arms': self.sidecar_results,
                            'originalAcceptanceOverridden': False, 'automaticRetryAllowed': False,
                            'crossArmSubtraction': False, 'knownHistoricalImageFailurePreserved': True,
                            'hookWatchdog': {'source': 'original flushed ownership-gauges.jsonl',
                                'secondsFromObservedGauge': 10, 'pollIntervalSeconds': .01,
                                'pollingLatencyPossible': True, 'kernelHardTimeout': False,
                                'nativeElapsedCheckSeconds': 10},
                            'observedTargetRssStopBytes': 2 << 30, 'kernelHardRssLimit': False,
                            'mapBudget': {'startupIdentityMaps': 2, 'endpointBracketMaps': 8,
                                'totalMaps': 10, 'eachBytesMaximum': 1 << 20, 'aggregateBytesMaximum': 10 << 20,
                                'startupConsistencyReadsNotRetained': 2, 'totalProcMapsReads': 12},
                            'ackPolicy': 'supervisor conservatively requires ACK within 2s of dumpEnd; native starts its 2s wait after receipt publication'}
        self.persist()

    def persist(self):
        self.application['budget'] = self.budget.report()
        save(self.output / 'group.json', self.group)
        save(self.output / 'application-pair.json', self.application)

    def caps(self, *, extra_bytes=0):
        return sidecar_caps(self.sidecars, extra_bytes=extra_bytes)

    def stage(self, label, argv, *, deadline, stdout=None, stdout_cap=None, application=False):
        return run_command(argv, self.shared / 'commands' / label, cwd=ROOT,
                           environment=self.environment, deadline=lambda: deadline,
                           watch=lambda _: self.caps(), stdout=stdout, stdout_cap=stdout_cap, application=application,
                           log_cap=8 << 20 if application else 2 << 20)

    def build_once(self, arm):
        deadline = min(arm['started'] + 300, arm['deadline'], self.budget.deadline)
        self.flutter = Path(shutil.which(os.environ.get('FLUTTER_BIN', 'flutter')) or '').resolve()
        require(self.flutter.is_file(), 'Pinned Flutter executable unavailable')
        require((ROOT / '.flutter-version').read_text().strip() == SDK_VERSION, 'Checkout Flutter pin differs')
        sdk = self.flutter.parent.parent
        sdk_info = self.stage('sdk-commit', ['git', '-C', str(sdk), 'rev-parse', 'HEAD'], deadline=deadline)
        require(Path(sdk_info['stdout']['path']).read_text().strip() == SDK_COMMIT, 'Actual Flutter revision differs')
        version = self.stage('sdk-version', [str(self.flutter), '--no-version-check', '--suppress-analytics', '--version', '--machine'], deadline=deadline)
        require(json.loads(Path(version['stdout']['path']).read_text())['frameworkVersion'] == SDK_VERSION,
                'Actual Flutter version differs')
        verify_source_proof(ROOT, self.source)
        self.launcher, self.stack_helper = self.shared / 'sealed-launcher', self.shared / 'libabc_quiet_dump.so'
        self.argv = commands(str(self.flutter), str(self.launcher), self.head, os.environ['TERRA_PERF_RENDERER'])
        verify_commands(self.argv, commands(str(self.flutter), str(self.launcher), self.head, os.environ['TERRA_PERF_RENDERER']), SDK_COMMIT, SDK_VERSION)
        self.source_binding = bind_source_target((ROOT / TARGET).read_bytes(), self.source['sourceFiles'][TARGET]['sha256'])
        cache = ROOT / 'build/linux/x64/profile/CMakeCache.txt'
        require(not cache.exists() and not (cache.parent / 'bundle').exists(),
                'Existing application build/cache forbidden before unique integration build')
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text('ABC_OWNER_DIAGNOSTICS:BOOL=ON\nABC_PERF_COUNTERS:BOOL=ON\n')
        self.application['buildInvocations'] = 1
        self.persist()
        self.stage('integration-build', self.argv['build'], deadline=deadline, application=True)
        verify_source_proof(ROOT, self.source)
        self.bundle = ROOT / 'build/linux/x64/profile/bundle'
        self.target = self.bundle / 'terraforge'
        self.native_path = self.shared / 'native-preflight.json'
        self.stage('actual-native-abi', [sys.executable, str(ROOT / 'tool/perf/memory_ownership_preflight.py'), 'native',
                   '--bundle', str(self.bundle), '--helper', str(self.args.helper.resolve()),
                   '--helper-build', str(self.args.helper_build.resolve()), '--output', str(self.native_path)], deadline=deadline)
        self.native = read_json(self.native_path)
        require(self.native.get('sourceCommit') == self.head and self.native.get('symbols') ==
                {'perfAbi': 1, 'ownerAbi': 1, 'requiredSymbolsVerified': True}, 'Built native ABI proof differs')
        self.stage('scalar-build-provenance', [sys.executable, str(HERE / 'capture_build.py'),
                   '--folder', str(self.folders[ARMS[0]]), '--head', self.head, '--source-sha', self.source_sha,
                   '--helper', str(self.args.helper.resolve()), '--native-proof', str(self.native_path)], deadline=deadline)
        self.build = read_json(self.folders[ARMS[0]] / 'build.json')
        self.build_sha = sha(self.folders[ARMS[0]] / 'build.json')
        self.binaries = read_json(self.folders[ARMS[0]] / 'code/manifest.json')['binaries']
        config = self.shared / 'sealed-config.h'
        self.seal = write_config(config, self.target, Path(self.paths['preload']), self.dirs)
        common = ['cc', '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-I', str(CONTRACTS),
                  '-DABC_SEALED_CONFIG=' + json.dumps(str(config))]
        self.stage('compile-launcher', common + [str(CONTRACTS / 'target_launcher.c'), '-o', str(self.launcher)], deadline=deadline)
        self.stage('compile-quiet-helper', common + ['-fPIC', '-shared', str(CONTRACTS / 'quiet_dump_bridge.c'),
                   str(CONTRACTS / 'quiet_dump_linux.c'), '-ldl', '-Wl,-z,defs', '-o', str(self.stack_helper)], deadline=deadline)
        self.required = {row['path']: row for row in [file_identity(path) for path in (
            self.target, self.bundle / 'lib/libapp.so',
            self.bundle / 'lib/libflutter_linux_gtk.so', self.args.helper.resolve(), self.stack_helper,
            Path(self.paths['preload']))]}
        engine = file_identity(self.bundle / 'lib/libabc_engine.so')
        self.presealed = {engine['path']: engine}
        self.launcher_identity = file_identity(self.launcher)
        save(self.shared / 'prebuilt.json', {'commands': self.argv, 'sdkCommit': SDK_COMMIT, 'sdkVersion': SDK_VERSION,
            'sourceBinding': self.source_binding, 'sealedConfig': self.seal,
            'requiredLoadedFiles': self.required, 'presealedLazyEngine': self.presealed,
            'launcher': self.launcher_identity,
            'originalBuildSha256': self.build_sha, 'singleBuildInvocation': True}, new=True)
        self.caps()
        require(time.monotonic() < deadline, 'First-arm build/hello budget exhausted before drive')

    def drive_arm(self, arm):
        name = arm['name']
        folder, sidecar = self.folders[name], self.dirs[name]
        if name == ARMS[1]:
            shutil.copytree(self.folders[ARMS[0]] / 'code', folder / 'code')
            shutil.copyfile(self.folders[ARMS[0]] / 'build.json', folder / 'build.json')
        execution = {'schema': 'abc.memory-ownership-execution.v1', 'arm': name, 'status': 'running',
            'sourceCommit': self.head, 'baseProductCommit': BASE, 'processInvocations': 1,
            'sourceProvenanceSha256': self.source_sha, 'scheduleSha256': sha(SCHEDULE),
            'nativeEngineSha256': self.native['nativeEngineSha256'],
            'allocatorHelperSha256': self.native['allocatorHelperSha256'],
            'allocatorBuildSha256': self.native['allocatorBuildSha256'], 'symbols': self.native['symbols'],
            'ownedProcess': False, 'identityGatePassed': False, 'measurementReleased': False,
            'timeoutSeconds': 900, 'runtimeTimeoutSeconds': 600, 'buildHelloTimeoutSeconds': 300,
            'command': self.argv['drive'], 'launchedMonotonicNs': time.monotonic_ns()}
        self.executions.append(execution)
        self.application['actualArmOrder'].append(name)
        identity = original_identity = modules = watcher = startup = None
        rss = OsJournalTail(folder / 'raw')
        gauges = GaugeTail(folder / 'raw/ownership-gauges.jsonl')
        hello_seen = None
        command_result = None

        def deadline():
            result = min(self.budget.deadline, arm['deadline'],
                         arm['started'] + 300 if hello_seen is None else hello_seen + 600)
            # Native cuts are additionally watched from original gauge publication.
            return min(result, watcher.deadline()) if watcher else result

        def watch(process):
            nonlocal identity, original_identity, modules, watcher, startup, hello_seen
            self.caps()
            exact_profile_files(sidecar)
            if hello_seen is None and (folder / 'hello.json').exists():
                hello = read_json(folder / 'hello.json')
                self.budget.hello()
                hello_seen = arm['hello']
                execution['helloMonotonicNs'] = time.monotonic_ns()
                gate_deadline = min(deadline(), hello_seen + 60)
                original_identity = _OwnedProcess(hello['hostPid'], process.pid)
                identity = TargetProcessIdentity(hello['hostPid'], owned_pgid=process.pid,
                    expected_executable=self.target, expected_sha256=self.seal['target']['sha256'])
                startup = validate_startup(hello, arm=name, pid=identity.pid, target=self.target,
                    helper=self.stack_helper, allocator=self.paths['preload'], output=sidecar)
                expected = self.binaries['terraforge']
                runtime_entry = bind_runtime_entry(hello, arm=name, head=self.head, owned_pid=identity.pid,
                    loaded_executable={key: identity.evidence[key] for key in ('bytes', 'sha256')},
                    built_executable=expected, source_binding=self.source_binding)
                token = bounded_bytes(sidecar / 'launch.once', 128)
                require(token == f'ABC_LAUNCH_ONCE_V1 {identity.pid} {name}\n'.encode(), 'Once-token is not bound to actual hello PID')
                require(file_identity(self.launcher) == self.launcher_identity, 'Launcher changed between arms')
                modules = BoundModules(identity, self.required, self.shared / 'modules',
                    self.shared / ('loaded-' + name), deadline=gate_deadline, cap_check=self.caps, presealed=self.presealed)
                execution.update(processIdentity=original_identity.identity, ownedProcess=True,
                    buildSha256=self.build_sha, binarySha256=expected['sha256'], binaries=self.binaries,
                    loadedExecutableSha256=expected['sha256'], loadedExecutableBytes=expected['bytes'])
                require(time.monotonic() < gate_deadline, 'Startup identity gate exceeded 60 seconds/shared budget')
                save(self.shared / ('entry-' + name + '.json'), {'runtimeEntry': runtime_entry,
                    'targetProcess': identity.evidence, 'startup': startup,
                    'providerIdentity': 'sealed helper verifies all seven providers before initialized=1',
                    'actualLoadedModulesVerified': True, 'moduleCount': len(modules.records),
                    'presealedButNotYetLoaded': sorted(modules.deferred)}, new=True)
                watcher = CutWatcher(sidecar, gauges, identity.pid, modules)
                execution['identityGatePassed'] = True
                execution['identityGatePassedMonotonicNs'] = time.monotonic_ns()
                publish_ready(folder / 'ready.json', {'schema': 'abc.memory-ownership-ready.v1', 'arm': name,
                    'hostPid': identity.pid, 'sourceCommit': self.head, 'baseProductCommit': BASE, 'buildSha256': self.build_sha})
                execution['measurementReleased'] = True
                save(folder / 'execution.json', execution)
            if watcher:
                watcher.check()
                rss.read_new()
            self.caps()

        save(folder / 'execution.json', execution, new=True)
        self.persist()
        error = None
        workload_complete = heap_files_complete = False
        try:
            verify_source_proof(ROOT, self.source)
            for path, row in {**self.required, **self.presealed}.items():
                require(file_identity(Path(path)) == row, 'Built artifact changed before next arm')
            command_result = run_command(self.argv['drive'], folder / 'driver-command', cwd=ROOT,
                environment=runtime_environment(self.environment, name, folder, self.args.helper.resolve(), self.stack_helper),
                deadline=deadline, watch=watch, log_cap=8 << 20, application=True)
            execution.update(status='completed', exitCode=command_result['returnCode'], logReaderFinished=True)
            require(watcher is not None and len(watcher.cuts) == 2, 'Original integration/quiet endpoints incomplete')
            execution['exitedMonotonicNs'] = time.monotonic_ns()
            exact_profile_files(sidecar, final=True)
            report = read_json(folder / 'report.json')
            validate_target(report, name, self.head, identity.pid)
            validate_probe_finish(sidecar / 'dart-probe.json', startup, watcher.cuts, report)
            heap_files_complete = True
            # Same original post-process provenance attachment; no scalar schema additions.
            for path in (folder / 'report.json', folder / 'standalone.json'):
                if path.exists():
                    value = read_json(path)
                    validate_target(value, name, self.head, identity.pid)
                    value['runtime'].update(buildProvenanceSha256=self.build_sha,
                        sourceTreeSha256=self.build['sourceTreeSha256'],
                        provenanceAttachment='single-diagnostic-runner-after-process')
                    save(path, value)
            execution['reportSha256'] = sha(folder / 'report.json')
            save(folder / 'execution.json', execution)
            report = read_json(folder / 'report.json')
            summary = validate_arm(report, folder / 'raw', self.build, self.head, self.build_sha, execution,
                                   read_json(SCHEDULE), sha(SCHEDULE), execution['reportSha256'])
            save(folder / 'summary.json', summary, new=True)
            self.results.append(summary)
            require(summary.get('evidenceValid') is True or name == ARMS[1] and summary.get('errors') == [KNOWN_IMAGE_FAILURE],
                    'Original workload/identity validator failed beyond preserved image coverage: ' + repr(summary.get('errors')))
            workload_complete = True
            modules.rehash(min(self.budget.deadline, arm['deadline']))
            expected_os = sorted((path.name for path in (folder / 'raw').glob('os-*.jsonl')), key=lambda n: int(n[3:-6]))
            while rss.tail.offset < rss.tail.path.stat().st_size or len(rss.closed_files) + 1 < len(expected_os):
                require(time.monotonic() < arm['deadline'], 'OS journal final drain shared timeout')
                rss.read_new()
            save(self.shared / ('rss-' + name + '.json'), rss.finish(expected_os), new=True)
            analysis = []
            for index, (_, _, cut, heap_name) in enumerate(CUTS):
                for mode in ('inuse_space', 'inuse_objects'):
                    analysis_deadline = self.budget.profile_analysis_deadline(cut, mode)
                    check_package(self.package)
                    raw = self.shared / f'{name}-{cut}.{mode}.raw'
                    result = self.stage(f'pprof-{name}-{cut}-{mode}',
                        [self.paths['pprof'], '--raw', '--' + mode, str(self.target), str(sidecar / heap_name)],
                        deadline=analysis_deadline, stdout=raw, stdout_cap=MAX_RAW)
                    check_official_diagnostics(Path(result['stderr']['path']).read_text())
                    validated = validate_official_raw(raw, self.target, watcher.cuts[index]['profile'], mode)
                    analysis.append({'cut': cut, 'mode': mode, 'total': validated['total'],
                                     'rawSha256': sha(raw), 'rawBytes': raw.stat().st_size,
                                     'wholeIntegerStacksMatched': True})
            save(self.shared / ('analysis-' + name + '.json'), analysis, new=True)
            save(self.shared / ('endpoints-' + name + '.json'), endpoint_delta(
                watcher.cuts[0]['profile'], watcher.cuts[1]['profile'], modules.records), new=True)
            save(self.shared / ('receipts-' + name + '.json'), watcher.records, new=True)
            save(self.shared / ('lazy-module-bindings-' + name + '.json'), modules.transitions, new=True)
            verify_source_proof(ROOT, self.source)
            self.caps()
            result = arm_completion(workload_complete=True, heap_files_complete=True,
                attribution_available=True, original_report=folder / 'summary.json')
            result['arm'] = name
            self.budget.complete_arm(result)
            self.sidecar_results.append(result)
            save(folder / 'stack-summary.json', result, new=True)
        except BaseException as caught:
            error = str(caught) or type(caught).__name__
            self.budget.fail(error)
            # Original execution completion is a fact independent of a later
            # pprof/sidecar failure. Do not rewrite the original saved result.
            if not (folder / 'summary.json').exists():
                execution.update(status='failed', error=error)
            execution.setdefault('exitCode', command_result['returnCode'] if command_result else None)
            execution.setdefault('exitedMonotonicNs', time.monotonic_ns())
            if not (folder / 'summary.json').exists():
                summary = {'schema': 'abc.memory-ownership-validation.v1', 'arm': name,
                           'status': 'failed', 'evidenceValid': False, 'errors': [error]}
                save(folder / 'summary.json', summary, new=True)
                self.results.append(summary)
            result = arm_completion(workload_complete=workload_complete, heap_files_complete=heap_files_complete,
                attribution_available=False, original_report=folder / 'summary.json', error=error)
            result['arm'] = name
            self.sidecar_results.append(result)
            save(folder / 'stack-summary.json', result, new=True)
        finally:
            if modules:
                modules.close()
            if identity:
                identity.close()
            if original_identity:
                original_identity.close()
            save(folder / 'execution.json', execution)
            self.persist()
        return error is None

    def run(self):
        try:
            first = self.budget.start_arm(ARMS[0])
            self.build_once(first)
            if self.drive_arm(first):
                self.drive_arm(self.budget.start_arm(ARMS[1]))
        except BaseException as error:
            self.budget.fail(str(error) or type(error).__name__)
            self.application['error'] = str(error) or type(error).__name__
        self.group['status'] = 'completed' if len(self.results) == 2 and all(row.get('evidenceValid') for row in self.results) else 'failed'
        original = validate_group(self.group, self.results)
        save(self.output / 'group-summary.json', original, new=True)
        self.application['status'] = 'capture-complete' if len(self.sidecar_results) == 2 and all(
            row['stackAttributionAvailable'] for row in self.sidecar_results) else 'failed'
        self.application['originalGroupEvidenceValid'] = original.get('evidenceValid', False)
        self.application['originalGroupSummarySha256'] = sha(self.output / 'group-summary.json')
        try:
            self.caps()
            inventories = {str(path.relative_to(self.output)): inspect_sidecar(path) for path in self.sidecars}
            save(self.output / 'sidecar-inventory.json', inventories, new=True)
        except BaseException as error:
            self.budget.fail('Final sidecar seal: ' + str(error))
            self.application['status'] = 'failed'
            self.application['finalSealError'] = str(error)
        self.persist()
        # Preserve original acceptance failure as a failing workflow even if the
        # separate capture facts are complete. Never overwrite historical reports.
        return 0 if self.application['status'] == 'capture-complete' and original.get('evidenceValid') else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--source-proof', required=True, type=Path)
    parser.add_argument('--package-proof', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--helper-build', required=True, type=Path)
    args = parser.parse_args()
    actual_ci_guard(os.environ)
    proof = read_json(args.source_proof)
    verify_source_proof(ROOT, proof)
    world = Path(os.environ['COMPUTERRARIA_WLD'])
    require(not world.is_symlink() and world.stat().st_size == 405983441 and sha(world) == WLD_SHA, 'Fixed public WLD differs')
    def interrupted(signum, _):
        raise KeyboardInterrupt(f'Signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    return PairRunner(args).run()


if __name__ == '__main__':
    raise SystemExit(main())
