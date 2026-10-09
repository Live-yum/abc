#!/usr/bin/env python3
"""Run exactly one fresh Linux/profile host per control arm, preserving failures.

Usage: memory_probe_control_run.py NEW_OUTPUT_DIRECTORY
The workflow supplies ABC_CONTROL_BASE_COMMIT, ABC_CONTROL_DERIVED_COMMIT,
ABC_CONTROL_DERIVATION (an external JSON file), FLUTTER_BIN and
TERRA_PERF_RENDERER. COMPUTERRARIA_WLD is used only by product-os-only.
No downloads, retries, resumed runs or original diagnostic validation occur.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tarfile
import threading
import time

from computer_memory_run import digest, sanitize, stop_group
import computerraria_provenance
from computerraria_provenance import record as record_build


BASE_COMMIT = '51bc8eaa76b145b0d9bec3c95977779af43b676c'
ARMS = ('probe-only', 'product-os-only')
REPORT_SCHEMA = 'abc.memory-probe-control.v1'
EXECUTION_SCHEMA = 'abc.memory-probe-control-execution.v1'
ROOT = Path(__file__).resolve().parents[2]
ORIGINAL_TEST = 'integration_test/computer_memory_diagnostic_test.dart'
TARGET = 'integration_test/computer_memory_probe_control_test.dart'
SCHEDULE = 'tool/perf/memory_probe_control_schedule.json'
WLD_BYTES = 405983441
WLD_SHA256 = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
BUILD_SECONDS, RUNTIME_SECONDS, DRIVER_SECONDS = 300, 600, 900
GLOBAL_SECONDS = 2100
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_REQUEST_BYTES, MAX_LINE_BYTES, MAX_REQUESTS = 1024 * 1024, 4096, 2048
MAX_LOG_BYTES = 32 * 1024 * 1024
HEX40 = re.compile(r'^[0-9a-f]{40}$')
PHASE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_.:/-]{0,95}$')
AUTH = re.compile(r'(?i)(authorization\s*[:=]\s*(?:bearer\s+)?|(?:auth(?:entication)?[_ -]?(?:token|code)|access[_ -]?token)\s*[:=]\s*)[^\s,;"\']+')


class InvariantError(ValueError):
    """Unsafe setup/source identity: a later arm must not be launched."""


def safe_text(value):
    return AUTH.sub(r'\1[redacted]', sanitize(str(value)))


def now():
    return datetime.now(timezone.utc).isoformat()


def capture(*argv, timeout=60, binary=False):
    result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, check=False)
    if result.returncode:
        raise InvariantError(safe_text(result.stderr.decode('utf-8', 'replace'))[:4096])
    return result.stdout if binary else result.stdout.decode('utf-8').strip()


def git(*argv, **kwargs):
    return capture('git', *argv, **kwargs)


def read_json(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError(f'Missing, linked or oversized JSON evidence: {path.name}')
    result = json.loads(path.read_text())
    if not isinstance(result, dict):
        raise ValueError(f'JSON object required: {path.name}')
    return result


def write_json(path, payload, *, new=False):
    path = Path(path)
    with path.open('x' if new else 'w') as destination:
        destination.write(safe_text(json.dumps(payload, indent=2, allow_nan=False)) + '\n')


def overlay_allowed(path):
    return path in {
        ORIGINAL_TEST, TARGET,
        'integration_test/support/computer_memory_probe_telemetry.dart',
        '.github/workflows/memory-probe-control.yml',
    } or (path.startswith('tool/perf/memory_probe_control') and '/' not in path[len('tool/perf/'):])


def tree_entries(commit):
    entries = {}
    for line in git('ls-tree', '-r', '-z', '--full-tree', commit, binary=True).split(b'\0'):
        if not line:
            continue
        info, path = line.split(b'\t', 1)
        mode, kind, oid = info.decode('ascii').split()
        entries[path.decode('utf-8')] = (mode, kind, oid)
    return entries


def validate_original_change(before, after, expected_hash):
    if hashlib.sha256(before).hexdigest() != expected_hash:
        raise InvariantError('Original diagnostic test does not match the manifest base hash')
    expected = before.replace(b'_cycle(', b'runComputerMemoryDiagnosticCycle(').replace(
        b'Future<_ObservedBackend> runComputerMemoryDiagnosticCycle(',
        b'// ignore: library_private_types_in_public_api\nFuture<_ObservedBackend> runComputerMemoryDiagnosticCycle(')
    if before.count(b'_cycle(') != 2 or after != expected:
        raise InvariantError('Original diagnostic target may only expose its cycle function')


def product_hash(path, mode, expected_blob):
    """Hash actual bytes, including files hidden by assume-unchanged index flags."""
    if mode == '120000':
        data = os.readlink(path).encode()
        blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        sha256 = hashlib.sha256(data).hexdigest()
    elif mode in ('100644', '100755') and path.is_file() and not path.is_symlink():
        size = path.stat().st_size
        blob_hash = hashlib.sha1(b'blob ' + str(size).encode() + b'\0')
        content_hash = hashlib.sha256()
        with path.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                blob_hash.update(block)
                content_hash.update(block)
        blob, sha256 = blob_hash.hexdigest(), content_hash.hexdigest()
    else:
        raise InvariantError(f'Product file type differs from base: {path.name}')
    if blob != expected_blob:
        raise InvariantError(f'Product bytes differ from the fixed base: {path.name}')
    return sha256


def source_preflight(output):
    base = os.environ.get('ABC_CONTROL_BASE_COMMIT')
    head = os.environ.get('ABC_CONTROL_DERIVED_COMMIT', '')
    if base != BASE_COMMIT or not HEX40.fullmatch(head):
        raise InvariantError('Explicit fixed base and full derived commit are required')
    if git('rev-parse', '--verify', 'HEAD') != head:
        raise InvariantError('Derived commit differs from checkout HEAD')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise InvariantError('A clean committed diagnostic overlay is required')
    if git('rev-list', '--parents', '-n', '1', head).split() != [head, base]:
        raise InvariantError('Derived commit must have exactly the fixed base as its parent')
    manifest_path = Path(os.environ.get('ABC_CONTROL_MANIFEST', ROOT / 'tool/perf/memory_probe_control_manifest.json')).resolve()
    if manifest_path != ROOT / 'tool/perf/memory_probe_control_manifest.json':
        raise InvariantError('Use the committed static control manifest')
    manifest = read_json(manifest_path)
    expected = {'schema': 'abc.memory-probe-control-manifest.v1', 'baseCommit': base,
                'productChangeAllowed': False, 'arms': list(ARMS),
                'processInvocationsPerArm': 1, 'runtimeSecondsPerArm': RUNTIME_SECONDS,
                'buildSecondsPerArm': BUILD_SECONDS, 'plannedCycles': 8,
                'plannedCheckpoints': 17, 'schedule': SCHEDULE,
                'vmCallsByArm': {'probe-only': 17, 'product-os-only': 0}}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise InvariantError('Static manifest differs from the fixed experiment contract')
    schedule_path = ROOT / SCHEDULE
    schedule = read_json(schedule_path)
    schedule_hash = digest(schedule_path)
    if schedule_hash != manifest.get('scheduleSha256'):
        raise InvariantError('Schedule hash differs from the committed manifest')
    if (schedule.get('schema') != 'abc.memory-probe-control-schedule.v1'
            or schedule.get('source', {}).get('commit') != base
            or len(schedule.get('points', [])) != 17
            or schedule.get('plannedCycles') != 8 or schedule.get('plannedVmProbes') != 17):
        raise InvariantError('The original 17-probe public CI schedule is required')
    derivation_path_text = os.environ.get('ABC_CONTROL_DERIVATION')
    if not derivation_path_text:
        raise InvariantError('ABC_CONTROL_DERIVATION must identify the CI derivation manifest')
    derivation = read_json(Path(derivation_path_text).resolve())
    patch = git('diff', '--no-color', '--binary', '--full-index', base, head, binary=True)
    derivation_expected = {
        'schema': 'abc.memory-probe-control-derivation.v1', 'baseCommit': base,
        'derivedCommit': head, 'derivedTree': git('rev-parse', f'{head}^{{tree}}'),
        'patchSha256': hashlib.sha256(patch).hexdigest(), 'scheduleSha256': schedule_hash,
    }
    if any(derivation.get(key) != value for key, value in derivation_expected.items()):
        raise InvariantError('CI derivation manifest does not match the actual committed overlay')
    if not HEX40.fullmatch(derivation.get('overlaySourceCommit', '')):
        raise InvariantError('CI overlay source commit is missing')
    old, new = tree_entries(base), tree_entries(head)
    changed = sorted(path for path in old.keys() | new.keys() if old.get(path) != new.get(path))
    if not changed or any(not overlay_allowed(path) for path in changed):
        raise InvariantError('Only the explicitly allowed diagnostic overlay may differ from base')
    required = {TARGET, SCHEDULE, 'tool/perf/memory_probe_control_manifest.json',
                'tool/perf/memory_probe_control_run.py',
                'tool/perf/memory_probe_control_os.py',
                'tool/perf/memory_probe_control_validate.py',
                'integration_test/support/computer_memory_probe_telemetry.dart'}
    if not required.issubset(new):
        raise InvariantError('The committed control overlay is incomplete')
    for path, (mode, kind, _oid) in new.items():
        if overlay_allowed(path) and (kind != 'blob' or mode not in ('100644', '100755')
                                      or (ROOT / path).is_symlink()):
            raise InvariantError('Diagnostic overlays must contain ordinary committed files')
    before = git('show', f'{base}:{ORIGINAL_TEST}', binary=True)
    after = (ROOT / ORIGINAL_TEST).read_bytes()
    validate_original_change(before, after, manifest.get('originalTestBaseSha256'))
    product = {}
    for path, (mode, kind, oid) in sorted(old.items()):
        if overlay_allowed(path):
            continue
        if new.get(path) != (mode, kind, oid) or kind != 'blob':
            raise InvariantError(f'Unchanged product blob required: {path}')
        actual_hash = product_hash(ROOT / path, mode, oid)
        product[path] = {'sha256': actual_hash, 'baseGitBlob': oid,
                         'derivedGitBlob': new[path][2], 'mode': mode}
    if not product:
        raise InvariantError('No unchanged product sources found')
    provenance = {
        'schema': 'abc.memory-probe-control-source.v1',
        'baseCommit': base, 'derivedCommit': head, 'derivedTree': derivation['derivedTree'],
        'patchSha256': derivation['patchSha256'], 'changedPaths': changed,
        'productFiles': product, 'productPathsUnchanged': True,
        'verification': 'identical base/derived Git blob IDs and modes; actual working bytes match base blob; current SHA-256',
        'manifestSha256': digest(manifest_path), 'scheduleSha256': schedule_hash,
        'overlayFilesSha256': {path: digest(ROOT / path) for path in sorted(new) if overlay_allowed(path)},
    }
    if derivation.get('overlayFilesSha256') != provenance['overlayFilesSha256']:
        raise InvariantError('Derivation overlay hashes differ from actual committed files')
    write_json(output / 'source.json', provenance, new=True)
    write_json(output / 'manifest.json', manifest, new=True)
    write_json(output / 'derivation.json', derivation, new=True)
    write_json(output / 'schedule.json', schedule, new=True)
    return head, provenance


def check_source_unchanged(head, provenance):
    if (git('rev-parse', '--verify', 'HEAD') != head
            or git('status', '--porcelain', '--untracked-files=all')):
        raise InvariantError('Source changed during the paired experiment')
    for path, expected in provenance['overlayFilesSha256'].items():
        if digest(ROOT / path) != expected:
            raise InvariantError(f'Diagnostic overlay changed: {path}')
    for path, expected in provenance['productFiles'].items():
        if product_hash(ROOT / path, expected['mode'], expected['baseGitBlob']) != expected['sha256']:
            raise InvariantError(f'Product source changed: {path}')


def verify_world():
    value = os.environ.get('COMPUTERRARIA_WLD')
    if not value:
        raise InvariantError('Product arm requires explicit COMPUTERRARIA_WLD')
    source = Path(value).resolve()
    if not source.is_file() or source.stat().st_size != WLD_BYTES:
        raise InvariantError('Product arm requires the pinned full-size public WLD')
    if digest(source) != WLD_SHA256:
        raise InvariantError('Product WLD SHA-256 does not match the pinned full input')
    return source


class RequestProtocol:
    """Bounded append-only JSONL reader; OS sampler owns PID/ancestry validation."""
    def __init__(self, requests, acks, external_os, pgid, arm, sampler_factory=None):
        if sampler_factory is None:
            from memory_probe_control_os import ExternalOsSampler
            sampler_factory = ExternalOsSampler
        self.requests, self.acks = Path(requests), Path(acks)
        self.external_os, self.pgid, self.arm = Path(external_os), pgid, arm
        self.factory = sampler_factory
        self.offset = self.lines = self.sequence = 0
        self.pending = b''
        self.inode = self.pid = self.sampler = self.manifest = None
        self.started_at = None
        self.finished = False

    def acknowledge(self, sequence, payload):
        final = self.acks / f'ack-{sequence}.json'
        temporary = self.acks / f'.ack-{sequence}.tmp'
        write_json(temporary, {'sequence': sequence, **payload}, new=True)
        try:
            # link() atomically publishes without ever replacing an old ack.
            os.link(temporary, final)
        finally:
            temporary.unlink()

    def accept(self, value):
        sequence = value.get('sequence') if isinstance(value, dict) else None
        try:
            if (not isinstance(value, dict) or set(value) != {
                    'kind', 'sequence', 'hostPid', 'phase', 'cycle', 'dartTimeUs'}):
                raise ValueError('Request must contain only the six protocol fields')
            if type(sequence) is not int or sequence != self.sequence or sequence >= MAX_REQUESTS:
                raise ValueError('External request sequence is missing, duplicated or out of order')
            if self.finished:
                raise ValueError('External request received after finish')
            if type(value['hostPid']) is not int or value['hostPid'] <= 1:
                raise ValueError('Invalid requested host PID')
            if (type(value['cycle']) is not int or not -1 <= value['cycle'] <= 8
                    or type(value['dartTimeUs']) is not int or value['dartTimeUs'] < 0
                    or not isinstance(value['phase'], str) or not PHASE.fullmatch(value['phase'])):
                raise ValueError('Invalid bounded point metadata')
            kind = value['kind']
            metadata = dict(value)
            metadata['controlArm'] = self.arm
            row = None
            if kind == 'hello':
                if self.sequence != 0 or self.sampler is not None:
                    raise ValueError('Exactly one initial hello is required')
                self.pid = value['hostPid']
                self.sampler = self.factory(self.pid, self.pgid, self.external_os)
                self.sampler.start()
                self.sampler.check()
                self.started_at = time.monotonic()
                row = self.sampler.point(value['phase'], metadata)
            elif kind in ('point', 'finish'):
                if self.sampler is None or value['hostPid'] != self.pid:
                    raise ValueError('A point must identify the verified hello host')
                self.sampler.check()
                row = self.sampler.point(value['phase'], metadata)
                if kind == 'finish':
                    self.manifest = self.sampler.finish()
                    self.finished = True
            else:
                raise ValueError('Unknown external request kind')
            self.acknowledge(sequence, {'ok': True, 'row': row})
            self.sequence += 1
        except Exception as error:
            if type(sequence) is int and sequence == self.sequence and 0 <= sequence < MAX_REQUESTS:
                if not (self.acks / f'ack-{sequence}.json').exists():
                    self.acknowledge(sequence, {'ok': False, 'error': safe_text(error)[:1024]})
            raise

    def poll(self, *, final=False):
        if self.sampler is not None and not self.finished:
            self.sampler.check()
        try:
            fd = os.open(self.requests, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        except FileNotFoundError:
            if final:
                raise ValueError('No external sampler handshake was received')
            return
        with os.fdopen(fd, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError('External requests must be a regular file')
            identity = (info.st_dev, info.st_ino)
            if self.inode is not None and self.inode != identity:
                raise ValueError('External requests file was replaced')
            self.inode = identity
            if info.st_size < self.offset or info.st_size > MAX_REQUEST_BYTES:
                raise ValueError('External requests were truncated or exceeded their byte budget')
            source.seek(self.offset)
            block = source.read(65536)
            self.offset += len(block)
        self.pending += block
        while b'\n' in self.pending:
            line, self.pending = self.pending.split(b'\n', 1)
            self.lines += 1
            if not line or len(line) > MAX_LINE_BYTES or self.lines > MAX_REQUESTS:
                raise ValueError('Malformed or oversized external request line')
            self.accept(json.loads(line))
        if len(self.pending) > MAX_LINE_BYTES:
            raise ValueError('External request line exceeds its byte budget')
        if final and (self.pending or self.offset != info.st_size or not self.finished):
            raise ValueError('Incomplete external sampler request/finish protocol')

    def close(self):
        if self.sampler is not None and not self.finished:
            self.manifest = self.sampler.finish()
        return self.manifest

    def descriptor(self):
        value = self.manifest
        if value is None and self.sampler is not None:
            value = getattr(self.sampler, 'manifest', None)
        if value is None:
            return None
        return {**value, 'arm': self.arm, 'baseProductCommit': BASE_COMMIT,
                'processInvocations': 1, 'ownedProcess': bool(value.get('processIdentity')),
                'endpointRequests': self.sequence}


def drain_log(stream, output, state):
    """Bounded lines avoid unbounded readline and secret-splitting truncation."""
    total = 0
    try:
        while True:
            line = stream.readline(65537)
            if not line:
                break
            if len(line) > 65536:
                raise ValueError('Driver stdout line exceeded its bound')
            cleaned = safe_text(line.decode('utf-8', 'replace'))
            total += len(cleaned.encode('utf-8'))
            if total > MAX_LOG_BYTES:
                raise ValueError('Driver stdout exceeded its byte budget')
            output.write(cleaned)
            output.flush()
    except Exception as error:
        state['error'] = safe_text(error)
    finally:
        state['bytes'] = total


def evidence_files(directory, exclude=()):
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise InvariantError('Evidence must not contain symbolic links')
        if path.is_file() and path not in exclude:
            result[str(path.relative_to(directory))] = {
                'sha256': digest(path), 'bytes': path.stat().st_size}
    return result


def record_provenance(artifacts, output):
    # Reuse the original recorder, but bound its local Git subprocesses.
    original_git = computerraria_provenance.git
    computerraria_provenance.git = git
    try:
        record_build([str(path) for path in artifacts], output,
                     ROOT / 'build/linux/x64/profile/CMakeCache.txt',
                     ROOT / 'build/linux/x64/profile/build.ninja')
    finally:
        computerraria_provenance.git = original_git


def archive_bundle(bundle, destination):
    files = sorted(path for path in bundle.rglob('*') if path.is_file() and not path.is_symlink())
    if sum(path.stat().st_size for path in files) > 1024 * 1024 * 1024:
        raise ValueError('Optional bundle archive exceeds 1 GiB')
    with tarfile.open(destination, 'x:gz') as archive:
        for path in files:
            archive.add(path, arcname=str(path.relative_to(bundle)), recursive=False)


def run_arm(arm, output, head, provenance, flutter, version, renderer, global_deadline, world=None):
    directory = output / arm
    directory.mkdir()
    paths = {key: directory / name for key, name in {
        'report': 'control.json', 'standalone': 'control.standalone.json',
        'execution': 'control.execution.json', 'build': 'control.build.json',
        'summary': 'control.summary.json', 'raw': 'control.raw', 'log': 'control.log',
        'requests': 'external-requests.jsonl', 'acks': 'external-acks',
        'os': 'external-os.jsonl', 'os_manifest': 'external-os.manifest.json',
    }.items()}
    paths['acks'].mkdir()
    env = dict(os.environ)
    for key in ('COMPUTERRARIA_WLD', 'ABC_MEMORY_RAW_DIRECTORY', 'TERRA_UI_PROFILE_OUTPUT',
                'TERRA_UI_PROFILE_STANDALONE_OUTPUT', 'ABC_CONTROL_REQUESTS',
                'ABC_CONTROL_ACK_DIRECTORY', 'ABC_CONTROL_SCHEDULE'):
        env.pop(key, None)
    env.update(ABC_PERF_COMMIT=head, ABC_CONTROL_SCHEDULE=str(ROOT / SCHEDULE),
               ABC_CONTROL_REQUESTS=str(paths['requests']), ABC_CONTROL_ACK_DIRECTORY=str(paths['acks']),
               ABC_MEMORY_RAW_DIRECTORY=str(paths['raw']), TERRA_UI_PROFILE_OUTPUT=str(paths['report']),
               TERRA_UI_PROFILE_STANDALONE_OUTPUT=str(paths['standalone']))
    if world is not None:
        env['COMPUTERRARIA_WLD'] = str(world)
    argv = [flutter, '--no-version-check', '--suppress-analytics', 'drive', '--no-pub',
            '--profile', '-d', 'linux', '--host-vmservice-port=0',
            '--driver=test_driver/ui_profile_driver.dart', f'--target={TARGET}',
            f'--dart-define=MEMORY_CONTROL_ARM={arm}', f'--dart-define=PERF_COMMIT={head}',
            f'--dart-define=PERF_CHECKED_OUT_HEAD={head}', '--dart-define=PERF_WORKTREE_DIRTY=false',
            f'--dart-define=PERF_FLUTTER_VERSION={version}', f'--dart-define=PERF_RENDERER={renderer}']
    record = {'schema': EXECUTION_SCHEMA, 'arm': arm, 'status': 'running',
              'baseCommit': BASE_COMMIT, 'derivedCommit': head, 'sourceCommit': head,
              'processInvocations': 0, 'plannedCycles': 8, 'startedAt': now(),
              'command': argv, 'buildTimeoutSeconds': BUILD_SECONDS,
              'runtimeTimeoutSeconds': RUNTIME_SECONDS, 'timeoutSeconds': DRIVER_SECONDS,
              'scheduleSha256': provenance['scheduleSha256'],
              'sourceProvenanceSha256': digest(output / 'source.json'),
              'logSanitization': 'local-service-URLs-and-auth-tokens-redacted-before-persistence'}
    if world is not None:
        record['input'] = {'bytes': WLD_BYTES, 'sha256': WLD_SHA256, 'verification': 'full-file-sha256-once-before-product-arm'}
    process = protocol = reader = None
    started = time.monotonic()
    unsafe = False
    write_json(paths['execution'], record, new=True)
    try:
        check_source_unchanged(head, provenance)
        if time.monotonic() + DRIVER_SECONDS > global_deadline:
            raise InvariantError('Insufficient remaining paired-run budget for one full arm')
        log_state = {}
        with paths['log'].open('x') as log:
            process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            record.update(processInvocations=1, driverPid=process.pid)
            write_json(paths['execution'], record)
            protocol = RequestProtocol(paths['requests'], paths['acks'], paths['os'], process.pid, arm)
            reader = threading.Thread(target=drain_log, args=(process.stdout, log, log_state), daemon=True)
            reader.start()
            while process.poll() is None:
                protocol.poll()
                if log_state.get('error'):
                    raise ValueError(log_state['error'])
                current = time.monotonic()
                if current - started >= DRIVER_SECONDS or current >= global_deadline:
                    record['status'] = 'timeout'
                    record['timeoutStage'] = 'driver'
                    break
                if protocol.started_at is None and current - started >= BUILD_SECONDS:
                    record['status'] = 'timeout'
                    record['timeoutStage'] = 'build-and-handshake'
                    break
                if protocol.started_at is not None and current - protocol.started_at >= RUNTIME_SECONDS:
                    record['status'] = 'timeout'
                    record['timeoutStage'] = 'runtime'
                    break
                time.sleep(0.02)
            if record['status'] == 'running':
                record['exitCode'] = process.returncode
                record['status'] = 'completed' if process.returncode == 0 else 'failed'
                protocol.poll(final=True)
            stop_group(process)
            record['exitCode'] = process.returncode
            record['ownedProcessGroupTerminationAttempted'] = True
            reader.join(timeout=10)
            record['logReaderFinished'] = not reader.is_alive()
            if reader.is_alive():
                raise InvariantError('Driver log reader did not terminate')
            if log_state.get('error'):
                raise ValueError(log_state['error'])
        if protocol is not None:
            record['applicationHostPid'] = protocol.pid
            record['externalProtocolRequests'] = protocol.sequence
            record['externalProtocolFinished'] = protocol.finished
            manifest = protocol.close()
            if manifest is not None:
                write_json(paths['os_manifest'], protocol.descriptor(), new=True)
        launch_path = paths['report'] if paths['report'].exists() else paths['standalone']
        launch = read_json(launch_path)
        if (launch.get('schema') != REPORT_SCHEMA or launch.get('arm') != arm
                or launch.get('runtime', {}).get('commit') != head
                or launch.get('hostPid') != protocol.pid or protocol.pid is None):
            raise ValueError('Fresh target identity is unverified; do not associate a prior bundle')
        check_source_unchanged(head, provenance)
        bundle = ROOT / 'build/linux/x64/profile/bundle'
        artifacts = [bundle / 'terraforge', bundle / 'lib/libapp.so', bundle / 'lib/libabc_engine.so']
        previous_perf_commit = os.environ.get('ABC_PERF_COMMIT')
        os.environ['ABC_PERF_COMMIT'] = head
        try:
            record_provenance(artifacts, paths['build'])
        finally:
            if previous_perf_commit is None:
                os.environ.pop('ABC_PERF_COMMIT', None)
            else:
                os.environ['ABC_PERF_COMMIT'] = previous_perf_commit
        build = read_json(paths['build'])
        if build.get('cmake', {}).get('ABC_PERF_COUNTERS') != 'OFF':
            raise InvariantError('Only the ordinary counter-disabled native library is permitted')
        record['builtArtifacts'] = build['artifacts']
        if os.environ.get('ABC_CONTROL_ARCHIVE_BUNDLES') == '1':
            archive_bundle(bundle, directory / 'diagnostic-bundle.tar.gz')
        for path in (paths['report'], paths['standalone']):
            if path.exists():
                report = read_json(path)
                if report.get('schema') != REPORT_SCHEMA or report.get('arm') != arm:
                    raise ValueError('Report and standalone report disagree on target identity')
                report.setdefault('runtime', {}).update({
                    'buildProvenanceSha256': digest(paths['build']),
                    'sourceTreeSha256': build['sourceTreeSha256'],
                    'sourceProvenanceSha256': record['sourceProvenanceSha256'],
                    'provenanceAttachment': 'single-diagnostic-runner-after-process',
                    'controlProvenanceAttachment': 'paired-control-runner-after-owned-process',
                })
                report['externalOs'] = protocol.descriptor()
                write_json(path, report)
        validator = subprocess.run([
            sys.executable, str(ROOT / 'tool/perf/memory_probe_control_validate.py'), str(paths['report']),
            '--raw-directory', str(paths['raw']), '--build', str(paths['build']),
            '--external-os', str(paths['os_manifest']), '--expected-commit', head,
            '--output', str(paths['summary']),
        ], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, check=False)
        (directory / 'validator.log').write_text(safe_text(validator.stdout.decode('utf-8', 'replace')))
        record['validatorExitCode'] = validator.returncode
        if validator.returncode != 0:
            record['status'] = 'failed' if record['status'] == 'completed' else record['status']
    except KeyboardInterrupt as error:
        record.update(status='interrupted', failure=safe_text(error))
        unsafe = True
    except Exception as error:
        record['status'] = 'failed' if record['status'] != 'timeout' else 'timeout'
        record['failure'] = safe_text(error)[:4096]
        unsafe = isinstance(error, InvariantError)
    finally:
        if process is not None and not record.get('ownedProcessGroupTerminationAttempted'):
            stop_group(process)
            record['exitCode'] = process.returncode
            record['ownedProcessGroupTerminationAttempted'] = True
        if reader is not None:
            reader.join(timeout=10)
            record['logReaderFinished'] = not reader.is_alive()
        if protocol is not None:
            record.update(applicationHostPid=protocol.pid, externalProtocolRequests=protocol.sequence,
                          externalProtocolFinished=protocol.finished)
            if not paths['os_manifest'].exists():
                try:
                    manifest = protocol.close()
                    if manifest is not None:
                        write_json(paths['os_manifest'], protocol.descriptor(), new=True)
                except Exception as error:
                    record['externalSamplerFailure'] = safe_text(error)[:4096]
                    partial = protocol.descriptor()
                    if partial is not None:
                        write_json(paths['os_manifest'], partial, new=True)
        if process is not None and not paths['build'].exists():
            # Preserve observed bytes before the next build, while explicitly
            # refusing to attribute a leftover bundle to an unverified host.
            bundle = ROOT / 'build/linux/x64/profile/bundle'
            record['unassociatedBuildArtifacts'] = {
                name: {'sha256': digest(bundle / relative), 'bytes': (bundle / relative).stat().st_size}
                for name, relative in {'terraforge': 'terraforge', 'libapp.so': 'lib/libapp.so',
                                       'libabc_engine.so': 'lib/libabc_engine.so'}.items()
                if (bundle / relative).is_file() and not (bundle / relative).is_symlink()}
        if not paths['summary'].exists():
            write_json(paths['summary'], {'schema': 'abc.memory-probe-control-summary.v1',
                       'arm': arm, 'status': 'invalid-evidence', 'causalAttribution': 'not-evaluated',
                       'failures': [record.get('failure', record['status'])]}, new=True)
        record.update(completedAt=now(), elapsedSeconds=time.monotonic() - started,
                      unsafeToContinue=unsafe)
        try:
            record['files'] = evidence_files(directory, exclude=(paths['execution'],))
        except Exception as error:
            unsafe = True
            record.update(status='failed', unsafeToContinue=True, evidenceFailure=safe_text(error))
        write_json(paths['execution'], record)
    return record, unsafe


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        raise SystemExit('Usage: memory_probe_control_run.py NEW_OUTPUT_DIRECTORY')
    requested = Path(arguments[0]).absolute()
    if requested.exists() or requested.is_symlink():
        raise SystemExit('Use a new output directory; prior evidence is immutable')
    output = requested.resolve()
    output.mkdir(parents=True)
    record = {'schema': EXECUTION_SCHEMA, 'scope': 'paired-control', 'status': 'running',
              'baseCommit': BASE_COMMIT, 'plannedArms': list(ARMS), 'plannedProcessInvocations': 2,
              'processInvocations': 0, 'startedAt': now(), 'globalTimeoutSeconds': GLOBAL_SECONDS,
              'causalAttribution': 'unresolved', 'arms': []}
    execution = output / 'execution.json'
    write_json(execution, record, new=True)
    global_started = time.monotonic()
    global_deadline = global_started + GLOBAL_SECONDS
    previous_sigterm = signal.getsignal(signal.SIGTERM)
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f'Interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    try:
        os.chdir(ROOT)
        head, provenance = source_preflight(output)
        record['derivedCommit'] = head
        flutter = os.environ.get('FLUTTER_BIN', 'flutter')
        version = json.loads(capture(flutter, '--no-version-check', '--suppress-analytics',
                                     '--version', '--machine', timeout=60))['frameworkVersion']
        if version != (ROOT / '.flutter-version').read_text().strip():
            raise InvariantError('Pinned Flutter version mismatch')
        renderer = os.environ.get('TERRA_PERF_RENDERER', '').strip()
        if not renderer or len(renderer) > 512 or '\n' in renderer:
            raise InvariantError('Observed renderer provenance is required')
        record.update(flutterVersion=version, renderer=renderer)
        for arm in ARMS:
            check_source_unchanged(head, provenance)
            world = verify_world() if arm == 'product-os-only' else None
            arm_record, unsafe = run_arm(arm, output, head, provenance, flutter, version,
                                         renderer, global_deadline, world)
            record['arms'].append({'arm': arm, 'status': arm_record['status'],
                                   'execution': f'{arm}/control.execution.json',
                                   'summary': f'{arm}/control.summary.json'})
            record['processInvocations'] += arm_record['processInvocations']
            write_json(execution, record)
            if unsafe:
                raise InvariantError(f'{arm} reported an unsafe invariant or was interrupted')
        record['status'] = 'completed' if all(item['status'] == 'completed' for item in record['arms']) else 'failed'
    except (Exception, KeyboardInterrupt) as error:
        record.update(status='interrupted' if isinstance(error, KeyboardInterrupt) else 'failed',
                      failure=safe_text(error)[:4096])
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        finished_arms = {entry['arm'] for entry in record['arms']}
        for arm in ARMS:
            if arm not in finished_arms:
                record['arms'].append({'arm': arm, 'status': 'not-run',
                                       'reason': record.get('failure', 'unsafe setup/invariant')})
        comparison = {'schema': 'abc.memory-probe-control-comparison.v1',
                      'baseCommit': BASE_COMMIT, 'derivedCommit': record.get('derivedCommit'),
                      'status': record['status'], 'arms': record['arms'],
                      'processInvocations': record['processInvocations'],
                      'causalAttribution': 'unresolved',
                      'interpretation': 'Paired diagnostic evidence only; statuses do not establish a memory leak or its cause.'}
        write_json(output / 'comparison.json', comparison, new=True)
        record.update(completedAt=now(), elapsedSeconds=time.monotonic() - global_started)
        try:
            record['files'] = evidence_files(output, exclude=(execution,))
        except Exception as error:
            record.update(status='failed', evidenceFailure=safe_text(error))
        write_json(execution, record)
    print(json.dumps({'status': record['status'], 'execution': str(execution),
                      'comparison': str(output / 'comparison.json')}))
    return 0 if record['status'] == 'completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
