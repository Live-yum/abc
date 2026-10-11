#!/usr/bin/env python3
"""One official small contract, then at most one original control prefix to q0.

This is an independent sampled feasibility runner. It cannot dispatch the old
full pair, a WLD workload, q7, or an automatic retry. All process execution is CI
guarded; importing this module only exposes offline-testable command builders.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

from sampled_contract import PERIOD, parse_sample, validate_sampled_bracket, estimate_samples
from sampled_source import ROOT, BRANCH, TARGET, BASE, verify_source
from sampled_pprof import validate_weighted_raw, check_sampled_diagnostics
from sampled_seal_config import (render_header, output_identity,
                                file_identity as seal_file)
from application_contract import require, bounded_bytes, OsJournalTail, parse_maps
from application_process import run_command, save, read_json, clean_environment
from bounded_supervision import TargetProcessIdentity
from prebuilt_contract import SDK_COMMIT, SDK_VERSION, TARGET as OLD_TARGET, commands
from capture_contract import GaugeTail, sidecar_caps
from elf_identity import BoundModules, file_identity
from run_pair import check_package, verified_analysis
from memory_probe_control_os import _OwnedProcess
from sampled_supervision import (bind_sampled_source, validate_sampled_hello,
    publish_sampled_ready, SampledCutWatcher, validate_sampled_finish, read_sampled_json)

HERE = Path(__file__).resolve().parent
SCHEDULE = ROOT / 'tool/perf/memory_ownership_schedule.json'
BUDGETS = dict(totalSeconds=2000, smallSeconds=120, armSeconds=900,
               buildHelloSeconds=300, runtimeSeconds=600, identitySeconds=60,
               hookSeconds=10, ackSeconds=2, analysisSeconds=120,
               rawEachExclusiveBytes=1 << 20, mapsEachBytes=1 << 20,
               mapsTotalBytes=10 << 20, mapsMaximumFiles=12,
               jsonEachBytes=4 << 20, officialRawEachBytes=16 << 20,
               sidecarTotalBytes=256 << 20, targetObservedRssStopBytes=2 << 30)
HEADER = '/usr/include/gperftools/malloc_extension.h'
HEADER_BYTES = 19705
HEADER_SHA = 'cc11faffcadfd601272d154571086372641ded100604e732ca382b6217a4d583'


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def ci_guard(env):
    require(env.get('GITHUB_ACTIONS') == env.get('CI') == 'true'
            and env.get('GITHUB_REF') == BRANCH and env.get('GITHUB_RUN_ATTEMPT') == '1',
            'Sampled feasibility is fixed-branch, first-attempt CI only')
    require(sys.platform == 'linux' and time.get_clock_info('monotonic').implementation == 'clock_gettime(CLOCK_MONOTONIC)',
            'Shared Linux CLOCK_MONOTONIC required')
    require(not env.get('COMPUTERRARIA_WLD'), 'No WLD input permitted in sampled q0 feasibility')


def verify_development_header(package, deadline):
    expected = package['packageIdentity']['libgoogle-perftools-dev']['installedFiles'][HEADER]
    require(expected == {'bytes': HEADER_BYTES, 'sha256': HEADER_SHA}, 'Official fixed development header package proof differs')
    actual = file_identity(Path(HEADER), deadline=deadline)
    require({key: actual[key] for key in ('bytes', 'sha256')} == expected, 'Installed official development header differs')
    require(not (HERE / 'gperftools').exists(), 'Local public-header shadow forbidden')
    return actual


def sampled_commands(flutter, launcher, head, renderer):
    original = commands(flutter, launcher, head, renderer)
    return {kind: [f'--target={TARGET}' if arg == f'--target={OLD_TARGET}' else arg
                   for arg in argv] + ['--dart-define=ABC_SAMPLED_DIAGNOSTIC=true']
            for kind, argv in original.items()}


def sample_environment(original, folder, helper, runtime):
    result = clean_environment(original)
    for name in list(result):
        if name.startswith(('ABC_STACK_', 'ABC_SAMPLED_')) or name == 'COMPUTERRARIA_WLD':
            result.pop(name)
    result.update(MEMORY_OWNER_ARM='probe-only', ABC_OWNER_SCHEDULE=str(SCHEDULE),
        ABC_OWNER_LIBC_HELPER=str(helper), ABC_SAMPLED_HELPER=str(runtime),
        ABC_SAMPLED_OUTPUT=str(folder), ABC_SAMPLED_HELLO=str(folder / 'sampled-hello.json'),
        ABC_SAMPLED_READY=str(folder / 'sampled-ready.json'),
        ABC_MEMORY_RAW_DIRECTORY=str(folder / 'raw'),
        TERRA_UI_PROFILE_OUTPUT=str(folder / 'report.json'),
        TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(folder / 'standalone.json'))
    # Only the native launcher supplies allocator/diagnostic enable to target.
    return result


class SampledBoundModules(BoundModules):
    """Attempt every owned close once; retain errors without masking first fault."""
    def close(self):
        if not hasattr(self, 'sampled_close_errors'):
            self.sampled_close_errors = []
        for name in list(getattr(self, 'held', {})):
            fd, _ = self.held.pop(name)
            try:
                os.close(fd)
            except OSError as error:
                self.sampled_close_errors.append({'path': name, 'errno': error.errno, 'retried': False})


def close_retained(objects):
    errors = []
    for label, obj, attributes in objects:
        if obj is None:
            continue
        for attribute in attributes:
            fd = getattr(obj, attribute, None)
            if fd is not None:
                setattr(obj, attribute, None)
                try:
                    os.close(fd)
                except OSError as error:
                    errors.append({'owner': label, 'field': attribute, 'errno': error.errno, 'retried': False})
    return errors


class SampledTargetIdentity(TargetProcessIdentity):
    def close(self):
        if not hasattr(self, 'sampled_close_errors'):
            self.sampled_close_errors = []
        self.sampled_close_errors.extend(close_retained([('target', self, ('exe_fd', 'proc_fd'))]))


class SampledOwnedProcess(_OwnedProcess):
    def close(self):
        if not hasattr(self, 'sampled_close_errors'):
            self.sampled_close_errors = []
        self.sampled_close_errors.extend(close_retained([('ancestry', self, ('fd',))]))


class SampledRunner:
    def __init__(self, args):
        ci_guard(os.environ)
        self.args = args
        self.started = time.monotonic()
        self.deadline = self.started + BUDGETS['totalSeconds']
        self.output = args.output.resolve()
        self.output.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.shared = self.output / 'evidence'
        self.shared.mkdir(mode=0o700)
        self.folder = self.output / 'probe-only'
        self.folder.mkdir(mode=0o700)
        self.small = self.output / 'small-captures'
        self.result = {'schema': 'abc.sampled-q0-feasibility.v1', 'status': 'running',
            'sourceCommit': None, 'baseProductCommit': BASE, 'mode': 'sampled',
            'smallContractInvocations': 0, 'applicationInvocations': 0, 'buildInvocations': 0,
            'originalEightCycleWorkloadCompleted': False, 'completedCycles': 0,
            'productArmStarted': False, 'wldLoaded': False, 'mappingAcceptanceEstablished': False,
            'memoryAcceptanceEstablished': False, 'fullHeapCoverage': False,
            'automaticRetryAllowed': False, 'budgets': BUDGETS,
            'targetObservedRssIsNotHardLimit': True,
            'dynamicSampleApiInternalPeakNotHardBounded': True,
            'originalImageAndPerformanceFailuresPreserved': True,
            'pathVerificationIsNotAtomicBinding': True,
            'binutilsExternalReadsNotExhaustivelyTraced': True,
            'offlineResymbolizationRequiresSameShaElfs': True}
        self.persist()
        try:
            self.source = read_json(args.source_proof)
            verify_source(ROOT, self.source)
            self.head = self.source['sourceCommit']
            self.source_sha = sha(args.source_proof)
            self.package = read_json(args.package_proof)
            self.paths = check_package(self.package, deadline=self.deadline)
            self.header_identity = verify_development_header(self.package, self.deadline)
            self.header_root = self.shared / 'official-headers'
            (self.header_root / 'gperftools').mkdir(mode=0o700, parents=True)
            self.header_copy = self.header_root / 'gperftools/malloc_extension.h'
            with self.header_copy.open('xb') as destination:
                destination.write(bounded_bytes(HEADER, HEADER_BYTES))
            require(sha(self.header_copy) == HEADER_SHA, 'Copied official header identity differs')
            self.environment = clean_environment(dict(os.environ, ABC_PERF_COMMIT=self.head))
            for variable in ('CPATH', 'CPLUS_INCLUDE_PATH', 'C_INCLUDE_PATH', 'OBJC_INCLUDE_PATH',
                             'LIBRARY_PATH', 'COMPILER_PATH', 'GCC_EXEC_PREFIX'):
                self.environment.pop(variable, None)
            self.result['sourceCommit'] = self.head
            self.result['initializationPassed'] = True
            self.persist()
        except BaseException as error:
            self.result.update(status='failed', initializationPassed=False,
                               firstError=str(error) or type(error).__name__)
            self.persist()
            raise

    def persist(self):
        self.result['elapsedSeconds'] = time.monotonic() - self.started
        save(self.output / 'sampled-feasibility.json', self.result)

    def caps(self):
        return sidecar_caps([self.output])

    def stage(self, name, argv, deadline, *, stdout=None, stdout_cap=None, application=False):
        return run_command(argv, self.shared / 'commands' / name, cwd=ROOT,
            environment=self.environment, deadline=lambda: min(deadline, self.deadline),
            watch=lambda _: self.caps(), stdout=stdout, stdout_cap=stdout_cap,
            application=application, log_cap=8 << 20 if application else 2 << 20)

    def setup_tools(self, deadline):
        self.tools = {}
        for name in ('addr2line', 'objdump', 'nm', 'c++filt'):
            path = (Path('/usr/bin') / name).resolve()
            row = file_identity(path, deadline=deadline)
            version = self.stage('symbol-tool-' + name, [str(path), '--version'], deadline)
            self.tools[name] = {'identity': row, 'version': Path(version['stdout']['path']).read_text()}
        self.pprof_tools = '--tools=' + ','.join(name + ':' + row['identity']['path'] for name, row in self.tools.items())
        save(self.shared / 'symbol-tools.json', self.tools, new=True)

    def analyze(self, label, sample_path, binary, sample, deadline, verify):
        results = {}
        for mode in ('inuse_space', 'inuse_objects'):
            output = self.shared / (label + '-' + mode + '.raw')
            def command():
                return self.stage(label + '-' + mode,
                    [self.paths['pprof'], self.pprof_tools, '--raw', '--' + mode, str(binary), str(sample_path)],
                    deadline, stdout=output, stdout_cap=16 << 20)
            execution, checks = verified_analysis(command, verify,
                self.shared / (label + '-' + mode + '-verification.json'))
            diagnostics = check_sampled_diagnostics(bounded_bytes(execution['stderr']['path'], 2 << 20))
            result = validate_weighted_raw(output, str(binary), sample, mode)
            result['officialDiagnostics'] = diagnostics
            save(self.shared / (label + '-' + mode + '.json'), result, new=True)
            results[mode] = {'serializedEstimatedTotal': result['serializedEstimatedTotal'],
                            'rawSha256': sha(output), 'estimateNotExact': True}
        return results

    def small_contract(self):
        deadline = min(self.deadline, time.monotonic() + BUDGETS['smallSeconds'])
        self.setup_tools(deadline)
        require(verify_development_header(self.package, deadline) == self.header_identity, 'Development header changed before compile')
        require(sha(self.header_copy) == HEADER_SHA, 'Selected compile header changed')
        library = seal_file(self.paths['preload'])
        config = self.shared / 'small-library-config.h'
        config.write_text('static const struct abc_file_identity abc_sample_library = {' +
            json.dumps(library['path']) + f', UINT64_C({library["device"]}), UINT64_C({library["inode"]}), ' +
            f'UINT64_C({library["size"]}), ' + json.dumps(library['sha256']) + '};\n')
        binary = self.shared / 'official-small-contract'
        self.stage('compile-small', ['c++', '-std=c++17', '-O1', '-g', '-fPIC', '-fno-omit-frame-pointer',
            '-fno-optimize-sibling-calls', '-no-pie', '-Wall', '-Wextra', '-Werror',
            '-I', str(self.header_root), '-I', str(HERE), '-DABC_SAMPLE_LIBRARY_CONFIG=' + json.dumps(str(config)),
            str(HERE / 'small_sample_contract.cc'), str(HERE / 'sample_wrapper.cc'),
            self.paths['preload'], '-ldl', '-o', str(binary)], deadline)
        require(verify_development_header(self.package, deadline) == self.header_identity, 'Development header changed after compile')
        require(sha(self.header_copy) == HEADER_SHA, 'Selected compile header changed after compile')
        target = seal_file(binary, executable=True)
        seal = self.shared / 'small-seal.json'
        save(seal, {'target': target, 'library': library}, new=True)
        self.result['smallContractInvocations'] = 1
        self.persist()
        execution = self.stage('official-small-execute', [sys.executable, str(HERE / 'small_target_exec.py'), str(seal), str(self.small)], deadline)
        observed = json.loads(Path(execution['stdout']['path']).read_text())
        require(observed.get('schema') == 'abc.official-sampled-small-execution.v1'
            and observed.get('status') == observed.get('cleanupErrno') == 0
            and observed.get('knownBytes') == 32 << 20 and observed.get('samplePeriodBytes') == PERIOD,
            'Official small execution/cleanup failed')
        nm = self.stage('small-known-symbol', [self.tools['nm']['identity']['path'], '-S', '--defined-only', str(binary)], deadline)
        found = re.findall(r'^([0-9a-f]+) ([0-9a-f]+) [Tt] abc_sample_known_allocate$', Path(nm['stdout']['path']).read_text(), re.M)
        require(len(found) == 1 and int(found[0][1], 16) > 0, 'Known small allocation exact ELF symbol absent')
        start, size = map(lambda value: int(value, 16), found[0])
        samples, known = {}, {}
        def verify():
            require(seal_file(binary, executable=True) == target and seal_file(self.paths['preload']) == library,
                    'Official small target/provider changed')
            check_package(self.package, deadline=deadline)
        verify()
        for name in ('baseline', 'held', 'freed'):
            folder = self.small / name
            metadata = read_json(folder / 'capture.json')
            require(metadata.get('status') == metadata.get('nativeStatus') == metadata.get('cleanupErrno') == 0
                    and metadata.get('apiCalls') == metadata.get('transportAccepted') == metadata.get('published') == 1,
                    'Small sample transport incomplete')
            require(bounded_bytes(self.small / 'launch.once', 128) ==
                    f'ABC_SAMPLED_SMALL_ONCE_V1 {metadata["pid"]}\n'.encode(), 'Small sample PID differs from one exec')
            sample = parse_sample(folder / 'q0.sample.heap')
            bracket = validate_sampled_bracket(sample, folder / 'before.maps', folder / 'after.maps')
            observed_maps = parse_maps(bounded_bytes(folder / 'before.maps', 1 << 20))
            for sealed in (target, library):
                mapped = [row for row in observed_maps if row['path'] == sealed['path'] and 'x' in row['permissions']]
                require(mapped and all(row['inode'] == sealed['inode'] and row['device'] ==
                    (os.major(sealed['device']), os.minor(sealed['device'])) for row in mapped),
                    'Small target/provider mapping differs from sealed file identity')
            require(any(row['path'] == target['path'] and 'x' in row['permissions'] and
                        row['start'] <= start < start + size <= row['end'] for row in observed_maps),
                    'Known symbol is not inside actual sealed non-PIE target executable mapping')
            known[name] = [row for row in sample['sampleRecords']
                          if any(start <= pc - (index > 0) < start + size for index, pc in enumerate(row['stack']))]
            save(self.shared / ('small-' + name + '-integrity.json'), {'sample': sample, 'mapping': bracket,
                'knownAllocationElfRange': [start, start + size], 'knownSampleRecords': len(known[name])}, new=True)
            samples[name] = self.analyze('small-' + name, folder / 'q0.sample.heap', binary, sample, deadline, verify)
        require(not known['baseline'] and not known['freed'], 'Known allocation persists outside held interval')
        if not known['held']:
            self.result['status'] = 'inconclusive-known-allocation-not-sampled'
            self.persist()
            raise ValueError('Known allocation not sampled; q0 forbidden; no probabilistic retry')
        require(len(known['held']) == 1 and known['held'][0]['rawSampleCounts'][:2] == (1, 32 << 20),
                'Known sampled allocation size/count differs')
        self.result['smallContract'] = {'status': 'passed', 'snapshots': samples, 'knownAllocationSampledAndFreed': True,
                                      'estimateNotExact': True, 'fullHeapCoverage': False}
        self.persist()

    def build(self):
        require(self.result.get('smallContract', {}).get('status') == 'passed', 'Small contract must pass before Flutter')
        self.arm_started = time.monotonic()
        self.arm_deadline = min(self.deadline, self.arm_started + 900)
        deadline = min(self.arm_deadline, self.arm_started + 300)
        flutter = Path(shutil.which(os.environ.get('FLUTTER_BIN', 'flutter')) or '').resolve()
        require(flutter.is_file() and (ROOT / '.flutter-version').read_text().strip() == SDK_VERSION, 'Flutter pin unavailable')
        revision = self.stage('sdk-commit', ['git', '-C', str(flutter.parent.parent), 'rev-parse', 'HEAD'], deadline)
        require(Path(revision['stdout']['path']).read_text().strip() == SDK_COMMIT, 'Actual SDK commit differs')
        version = self.stage('sdk-version', [str(flutter), '--no-version-check', '--suppress-analytics', '--version', '--machine'], deadline)
        require(json.loads(Path(version['stdout']['path']).read_text())['frameworkVersion'] == SDK_VERSION, 'SDK version differs')
        self.launcher = self.shared / 'sampled-target-launcher'
        self.runtime = self.shared / 'libabc_sample_runtime.so'
        self.argv = sampled_commands(str(flutter), str(self.launcher), self.head, os.environ['TERRA_PERF_RENDERER'])
        self.source_binding = bind_sampled_source((ROOT / TARGET).read_bytes(), self.source['sourceFiles'][TARGET]['sha256'])
        verify_source(ROOT, self.source)
        cache = ROOT / 'build/linux/x64/profile/CMakeCache.txt'
        require(not cache.exists() and not (cache.parent / 'bundle').exists(), 'Existing application build forbidden')
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text('ABC_OWNER_DIAGNOSTICS:BOOL=ON\nABC_PERF_COUNTERS:BOOL=ON\n')
        self.result['buildInvocations'] = 1
        self.persist()
        self.stage('integration-build', self.argv['build'], deadline, application=True)
        verify_source(ROOT, self.source)
        self.bundle = ROOT / 'build/linux/x64/profile/bundle'
        self.target = self.bundle / 'terraforge'
        native_path = self.shared / 'native-preflight.json'
        self.stage('actual-native-abi', [sys.executable, str(ROOT / 'tool/perf/memory_ownership_preflight.py'), 'native',
            '--bundle', str(self.bundle), '--helper', str(self.args.helper.resolve()), '--helper-build', str(self.args.helper_build.resolve()),
            '--output', str(native_path)], deadline)
        native = read_json(native_path)
        require(native.get('sourceCommit') == self.head and native.get('symbols') == {'perfAbi': 1, 'ownerAbi': 1, 'requiredSymbolsVerified': True},
                'Native ABI proof differs')
        self.stage('scalar-build-provenance', [sys.executable, str(HERE.parent / 'gperftools_application/capture_build.py'),
            '--folder', str(self.folder), '--head', self.head, '--source-sha', self.source_sha,
            '--helper', str(self.args.helper.resolve()), '--native-proof', str(native_path)], deadline)
        self.build_sha = sha(self.folder / 'build.json')
        self.binaries = read_json(self.folder / 'code/manifest.json')['binaries']
        self.target_seal, library, output = seal_file(self.target, executable=True), seal_file(self.paths['preload']), output_identity(self.folder)
        config = self.shared / 'runtime-config.h'
        config.write_text(render_header(self.target_seal, library, output, str(self.runtime)))
        require(verify_development_header(self.package, deadline) == self.header_identity, 'Development header changed before runtime compile')
        require(sha(self.header_copy) == HEADER_SHA, 'Selected runtime header changed')
        self.stage('compile-runtime', ['c++', '-std=c++17', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-fPIC', '-shared',
            '-DABC_SAMPLE_SEALED_CONFIG=' + json.dumps(str(config)), '-I', str(self.header_root), '-I', str(HERE), str(HERE / 'sample_runtime.cc'),
            str(HERE / 'sample_wrapper.cc'), self.paths['preload'], '-ldl', '-Wl,-z,defs', '-o', str(self.runtime)], deadline)
        require(verify_development_header(self.package, deadline) == self.header_identity, 'Development header changed after runtime compile')
        require(sha(self.header_copy) == HEADER_SHA, 'Selected runtime header changed after compile')
        launcher_config = self.shared / 'launcher-config.h'
        launcher_config.write_text(render_header(self.target_seal, library, output, str(self.runtime), helper=seal_file(self.runtime)))
        self.stage('compile-launcher', ['cc', '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
            '-DABC_SAMPLE_SEALED_CONFIG=' + json.dumps(str(launcher_config)), '-I', str(HERE),
            str(HERE / 'sampled_target_launcher.c'), '-o', str(self.launcher)], deadline)
        self.required = {row['path']: row for row in [file_identity(path) for path in (self.target,
            self.bundle / 'lib/libapp.so', self.bundle / 'lib/libflutter_linux_gtk.so', self.runtime,
            self.args.helper.resolve(), Path(self.paths['preload']))]}
        engine = file_identity(self.bundle / 'lib/libabc_engine.so')
        self.presealed = {engine['path']: engine}
        self.launcher_identity = file_identity(self.launcher)
        save(self.shared / 'prebuilt.json', {'commands': self.argv, 'sourceBinding': self.source_binding,
            'requiredLoadedFiles': self.required, 'presealedLazyEngine': self.presealed,
            'launcher': self.launcher_identity, 'buildSha256': self.build_sha}, new=True)

    def drive(self):
        identity = owned = modules = watcher = gate = None
        hello_seen = None
        gauges = GaugeTail(self.folder / 'raw/ownership-gauges.jsonl')
        rss = OsJournalTail(self.folder / 'raw')
        execution = {'schema': 'abc.sampled-q0-execution.v1', 'status': 'running', 'sourceCommit': self.head,
            'identityGatePassed': False, 'measurementReleased': False, 'applicationInvocations': 1}
        self.result['applicationInvocations'] = 1
        self.persist()
        def deadline():
            end = min(self.arm_deadline, self.arm_started + 300 if hello_seen is None else hello_seen + 600)
            return min(end, watcher.deadline()) if watcher else end
        def watch(process):
            nonlocal identity, owned, modules, watcher, gate, hello_seen
            self.caps()
            if hello_seen is None and (self.folder / 'sampled-hello.json').exists():
                hello_seen = time.monotonic()
                hello = read_sampled_json(self.folder / 'sampled-hello.json')
                owned = SampledOwnedProcess.__new__(SampledOwnedProcess)
                owned.__init__(hello['hostPid'], process.pid)
                identity = SampledTargetIdentity.__new__(SampledTargetIdentity)
                identity.__init__(hello['hostPid'], owned_pgid=process.pid,
                    expected_executable=self.target, expected_sha256=self.target_seal['sha256'])
                gate = validate_sampled_hello(hello, identity, head=self.head,
                    built_executable=self.binaries['terraforge'], source_binding=self.source_binding,
                    helper=self.runtime, allocator=self.required[self.paths['preload']], output=self.folder)
                require(bounded_bytes(self.folder / 'launch.once', 128) == f'ABC_SAMPLED_LAUNCH_ONCE_V1 {identity.pid} sampled-q0\n'.encode(),
                        'Sampled launcher token PID differs')
                require(file_identity(self.launcher) == self.launcher_identity, 'Sampled launcher changed')
                modules = SampledBoundModules.__new__(SampledBoundModules)
                modules.__init__(identity, self.required, self.shared / 'modules', self.shared / 'loaded-probe',
                    deadline=min(deadline(), hello_seen + 60), cap_check=self.caps, presealed=self.presealed)
                watcher = SampledCutWatcher(self.folder, gauges, identity, modules)
                execution.update(identityGatePassed=True, targetPid=identity.pid, ownedProcess=owned.identity)
                save(self.shared / 'entry-proof.json', gate, new=True)
                require(time.monotonic() < min(deadline(), hello_seen + 60), 'Sampled startup gate deadline expired')
                publish_sampled_ready(self.folder, gate, self.build_sha)
                execution['measurementReleased'] = True
                save(self.folder / 'execution.json', execution)
            if watcher:
                watcher.check()
                rss.read_new()
            self.caps()
        save(self.folder / 'execution.json', execution, new=True)
        primary = None
        try:
            verify_source(ROOT, self.source)
            run = run_command(self.argv['drive'], self.folder / 'driver-command', cwd=ROOT,
                environment=sample_environment(self.environment, self.folder, self.args.helper.resolve(), self.runtime),
                deadline=deadline, watch=watch, application=True, log_cap=8 << 20)
            require(watcher is not None and len(watcher.cuts) == 1, 'Sampled q0 not captured')
            report, probe = read_sampled_json(self.folder / 'report.json'), read_sampled_json(self.folder / 'dart-sampled-q0.json')
            completion = validate_sampled_finish(report, probe, gate['startup'], watcher.cuts,
                expected_head=self.head, schedule_sha256=self.source['scheduleSha256'], raw_directory=self.folder / 'raw')
            execution.update(status='sampled-q0-captured', completion=completion, command=run)
            save(self.folder / 'execution.json', execution)
            expected_os = sorted((path.name for path in (self.folder / 'raw').glob('os-*.jsonl')), key=lambda name: int(name[3:-6]))
            require(expected_os, 'Original OS journal missing')
            while rss.tail.offset < rss.tail.path.stat().st_size or len(rss.closed_files) + 1 < len(expected_os):
                require(time.monotonic() < self.arm_deadline, 'Original OS journal drain timeout')
                rss.read_new()
            save(self.shared / 'q0-original-os-summary.json', rss.finish(expected_os), new=True)
            save(self.shared / 'q0-receipts.json', watcher.records, new=True)
            sample = parse_sample(self.folder / 'q0.sample.heap')
            analysis_deadline = min(self.arm_deadline, time.monotonic() + 120)
            # Only actual sampled PCs enter post-exit symbol capability work.
            profile_view = {'maps': sample['maps'], 'buckets': [{'stack': row['stack']} for row in sample['sampleRecords']]}
            modules.prepare_symbols([profile_view], analysis_deadline)
            estimates = self.analyze('q0', self.folder / 'q0.sample.heap', self.target, sample, analysis_deadline,
                                    lambda: modules.rehash(analysis_deadline))
            save(self.shared / 'q0-reference-estimates.json', estimate_samples(sample), new=True)
            self.result.update(status='sampled-q0-feasible', q0Estimates=estimates,
                q0RawSha256=sample['rawSha256'], q0RawBytes=sample['rawBytes'], transportCompletion=completion)
        except BaseException as error:
            primary = error
            execution.update(status='failed', firstError=str(error) or type(error).__name__)
            save(self.folder / 'execution.json', execution)
            raise
        finally:
            if modules is not None:
                modules.close()
            cleanup_errors = list(getattr(modules, 'sampled_close_errors', []))
            for resource in (identity, owned):
                if resource is not None:
                    resource.close()
                    cleanup_errors.extend(getattr(resource, 'sampled_close_errors', []))
            save(self.shared / 'retained-fd-cleanup.json', {'errors': cleanup_errors, 'retries': 0,
                 'allCloseAttemptsSuccessful': not cleanup_errors}, new=True)
            if cleanup_errors:
                if primary is not None:
                    primary.add_note('Independent retained-FD cleanup errors: ' + repr(cleanup_errors))
                else:
                    raise ValueError('Retained-FD cleanup errors: ' + repr(cleanup_errors))

    def run(self):
        try:
            self.small_contract()
            self.build()
            self.drive()
        except BaseException as error:
            if not self.result['status'].startswith('inconclusive-'):
                self.result['status'] = 'failed'
            self.result['firstError'] = str(error) or type(error).__name__
            raise
        finally:
            self.persist()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    for name in ('source-proof', 'package-proof', 'helper', 'helper-build'):
        parser.add_argument('--' + name, required=True, type=Path)
    SampledRunner(parser.parse_args()).run()
