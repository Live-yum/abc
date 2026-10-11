#!/usr/bin/env python3
"""Verify the immutable product and the separately identified diagnostic overlay.

This module never launches a measurement arm. Only --native loads the actual
Profile library, in a separate bounded preflight process.
"""
import argparse
import ctypes
import difflib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile

BASE = '9d4cd5a0f9db03042a3986689fea374ba92d78b8'
BASE_TREE = '68de875853d92b0352077865cf862ffaceaaec92'
BRANCH = 'refs/heads/codex/memory-ownership-protocol-format-9d4'
MANIFEST = 'tool/perf/memory_ownership_manifest.json'
ROOT = Path(__file__).resolve().parents[2]
PRODUCER_FIXTURE_LIMIT = 16 * 1024


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def command(*args, root=ROOT, binary=False):
    result = subprocess.run(args, cwd=root, capture_output=True, check=True, timeout=120)
    return result.stdout if binary else result.stdout.decode().strip()


def write(path, value):
    with Path(path).open('x') as output:
        output.write(json.dumps(value, indent=2, allow_nan=False) + '\n')


def safe_path(value):
    path = PurePosixPath(value)
    if (not value or str(path) != value or path.is_absolute() or
            any(part in ('', '.', '..') for part in path.parts) or '\\' in value):
        raise ValueError('Unsafe source path')
    return path


def tree(commit, root=ROOT):
    result = {}
    for line in command('git', 'ls-tree', '-r', '-z', commit, root=root, binary=True).split(b'\0'):
        if line:
            head, path = line.split(b'\t', 1)
            mode, kind, blob = head.decode().split()
            name = path.decode()
            safe_path(name)
            if kind != 'blob' or mode not in ('100644', '100755', '120000'):
                raise ValueError('Unsupported source tree entry')
            result[name] = {'mode': mode, 'blob': blob}
    return result


def file_identity(path, expected):
    if expected['mode'] == '120000':
        if not path.is_symlink():
            raise ValueError('Expected source symlink')
        content = os.readlink(path).encode()
    else:
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing regular source')
        actual = '100755' if path.stat().st_mode & stat.S_IXUSR else '100644'
        if actual != expected['mode']:
            raise ValueError('Source executable mode differs')
        content = path.read_bytes()
    blob = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
    if blob != expected['blob']:
        raise ValueError('Actual source bytes differ from Git tree')
    return {'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest(), **expected}


def validate_delta(old, new, manifest):
    rows = manifest['files']
    paths = [r['path'] for r in rows]
    for path in paths:
        safe_path(path)
    if len(paths) != len(set(paths)) or MANIFEST in paths:
        raise ValueError('Duplicate/self-recursive manifest entry')
    changed = {p for p in old.keys() | new.keys() if old.get(p) != new.get(p)}
    if changed != set(paths) | {MANIFEST} or MANIFEST in old:
        raise ValueError('Derived tree differs outside the exact overlay')
    for row in rows:
        path = row['path']
        if new.get(path) != {k: row['after'][k] for k in ('mode', 'blob')}:
            raise ValueError('Derived blob/mode differs from manifest')
        before = row.get('before')
        if old.get(path) != (None if before is None else {k: before[k] for k in ('mode', 'blob')}):
            raise ValueError('Base blob/mode differs from manifest')
    # The shipping runtime is deliberately unused and remains byte-identical.
    if any(p.startswith('web/engine/') for p in changed):
        raise ValueError('This diagnostic must not replace shipping Web artifacts')


def source_preflight(output, base_root):
    head = command('git', 'rev-parse', 'HEAD')
    if os.environ.get('GITHUB_REF') != BRANCH or os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
        raise ValueError('Only the first exact-branch diagnostic run is permitted')
    if command('git', 'rev-list', '--parents', '-n', '1', head).split() != [head, BASE]:
        raise ValueError('Diagnostic must be one child commit of the fixed product')
    if command('git', 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Committed clean diagnostic checkout required')
    if command('git', 'rev-parse', f'{BASE}^{{tree}}') != BASE_TREE:
        raise ValueError('Base tree identity differs')
    if command('git', 'rev-parse', 'HEAD', root=base_root) != BASE:
        raise ValueError('Independent pristine product checkout differs')
    old, new = tree(BASE), tree(head)
    if len(old) != 886 or tree('HEAD', base_root) != old:
        raise ValueError('Full original product tree differs')
    for path, entry in old.items():
        file_identity(base_root / path, entry)
    manifest = json.loads((ROOT / MANIFEST).read_text())
    if (manifest.get('schema') != 'abc.memory-ownership-manifest.v1' or
            manifest.get('baseCommit') != BASE or manifest.get('baseTree') != BASE_TREE or
            manifest.get('arms') != ['probe-only', 'product-with-ownership'] or
            manifest.get('processInvocationsPerArm') != 1 or manifest.get('vmProbeSlotsPerArm') != 17 or
            manifest.get('gaugesPerArm') != 52):
        raise ValueError('Diagnostic manifest protocol differs')
    validate_delta(old, new, manifest)
    sources = {p: file_identity(ROOT / p, entry) for p, entry in sorted(new.items())}
    for row in manifest['files']:
        if sources[row['path']] != row['after']:
            raise ValueError('Overlay source SHA/size differs')
    schedule = ROOT / 'tool/perf/memory_ownership_schedule.json'
    if digest(schedule) != manifest['scheduleSha256']:
        raise ValueError('Pinned original timing schedule differs')
    result = {'schema': 'abc.memory-ownership-source.v1', 'baseProductCommit': BASE,
              'baseProductTree': BASE_TREE, 'sourceCommit': head,
              'sourceTree': command('git', 'rev-parse', 'HEAD^{tree}'),
              'diagnosticOverlay': True, 'shippingRuntimeUsed': False,
              'manifestSha256': digest(ROOT / MANIFEST), 'scheduleSha256': digest(schedule),
              'baseFiles': len(old), 'sourceFiles': sources,
              'patchSha256': hashlib.sha256(command('git', 'diff', '--binary', '--full-index', BASE, head, binary=True)).hexdigest()}
    write(output, result)
    return result


def format_archive(destination):
    destination.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((ROOT / MANIFEST).read_text())
    paths = [r['path'] for r in manifest['files'] if r['path'].endswith('.dart')]
    if not paths:
        raise ValueError('No diagnostic Dart sources')
    copies = destination / 'formatted'
    for name in paths:
        target = copies / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    # Only evidence copies are formatted. Later --output=none checks originals.
    result = subprocess.run(['dart', 'format', *[str(copies / p) for p in paths]],
                            capture_output=True, text=True, timeout=120, check=False)
    (destination / 'format.log').write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError('Official formatter failed')
    patch, rows = [], []
    for name in paths:
        before, after = ROOT / name, copies / name
        patch.extend(difflib.unified_diff(before.read_text().splitlines(True), after.read_text().splitlines(True),
                                         fromfile='a/' + name, tofile='b/' + name))
        rows.append({'path': name, 'beforeSha256': digest(before), 'formattedSha256': digest(after)})
    (destination / 'format.patch').write_text(''.join(patch))
    write(destination / 'format-manifest.json', {'schema': 'abc.memory-ownership-format.v1', 'files': rows})
    with tarfile.open(destination / 'formatted-sources.tar.gz', 'w:gz') as archive:
        for name in paths:
            archive.add(copies / name, arcname=name, recursive=False)
    shutil.rmtree(copies)
    subprocess.run(['dart', 'format', '--output=none', '--set-exit-if-changed', *paths], cwd=ROOT, check=True, timeout=120)


def native_settings(cache, ninja):
    settings = {}
    for line in cache.read_text().splitlines():
        if '=' in line and ':' in line and not line.startswith(('#', '//')):
            key, value = line.split('=', 1)
            settings[key.split(':', 1)[0]] = value
    if any(settings.get(key) != value for key, value in {
            'CMAKE_BUILD_TYPE': 'Profile', 'ABC_OWNER_DIAGNOSTICS': 'ON', 'ABC_PERF_COUNTERS': 'ON'}.items()):
        raise ValueError('Actual CMake options differ from explicit owner/counter Profile build')
    wanted = {'abc_owner_diagnostics.c.o', 'abc_perf.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o'}
    targets, current = {}, None
    for line in ninja.read_text().splitlines():
        if line.startswith('build '):
            current = next((name for name in wanted if name + ':' in line), None)
            if current:
                targets[current] = {}
        elif current and line.startswith(('  DEFINES = ', '  FLAGS = ')):
            key, value = line.strip().split(' = ', 1)
            targets[current][key] = value
    if set(targets) != wanted:
        raise ValueError('Actual owner/perf/circuit compilation targets missing')
    for name, row in targets.items():
        tokens = row.get('DEFINES', '').split()
        if name != 'terra_circuit_vm.c.o' and '-DABC_OWNER_DIAGNOSTICS=1' not in tokens:
            raise ValueError('Owner macro missing on actual native target')
        flags = row.get('FLAGS', '').split()
        if '-O3' not in flags or '-DNDEBUG' not in flags:
            raise ValueError('Original Profile compiler optimization flags changed')
    return settings, targets


def native_preflight(bundle, helper, helper_build_path, output):
    settings, targets = native_settings(bundle.parent / 'CMakeCache.txt', bundle.parent / 'build.ninja')
    engine = bundle / 'lib/libabc_engine.so'
    library = ctypes.CDLL(str(engine.resolve()))
    for name in ('abc_perf_abi_version', 'abc_owner_diagnostics_abi_version'):
        method = getattr(library, name)
        method.argtypes, method.restype = [], ctypes.c_uint32
        if method() != 1:
            raise ValueError('Actual native ABI version mismatch')
    required_perf = ('abc_perf_total_live_bytes', 'abc_perf_native_live_bytes',
                     'abc_perf_bridge_live_bytes', 'abc_perf_peak_bytes',
                     'abc_perf_world_open_count', 'abc_perf_world_circuit_count',
                     'abc_perf_compiler')
    for name in required_perf:
        getattr(library, name)
    snapshot = library.abc_owner_diagnostics_snapshot_v1
    snapshot.argtypes = [ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t]
    snapshot.restype = ctypes.c_int32
    words = (ctypes.c_uint64 * 16)()
    if snapshot(words, 16) != 0 or list(words)[:2] != [1, 16] or any(words[12:]):
        raise ValueError('Actual native owner snapshot ABI mismatch')
    if snapshot(words, 15) != -1:
        raise ValueError('Actual native owner ABI did not reject wrong buffer size')
    libc = ctypes.CDLL(str(helper.resolve()))
    initialize = libc.abc_retention_initialize_v1
    initialize.argtypes, initialize.restype = [], ctypes.c_int
    status = initialize()
    probe = libc.abc_retention_snapshot_v1
    probe.argtypes, probe.restype = [ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t], ctypes.c_int
    if status not in range(5) or probe(words, 16) != status or words[0] != 1 or words[1] != status:
        raise ValueError('Actual libc helper ABI mismatch')
    if probe(words, 15) != -1:
        raise ValueError('Actual libc helper did not reject wrong buffer size')
    helper_build = json.loads(helper_build_path.read_text())
    if (helper_build.get('status') != 'built' or
            helper_build.get('helperSha256') != digest(helper) or
            helper_build.get('source', {}).get('sha256') !=
            'cdedeb679d128bee9c513f2cd0ad92f2941ab74a705d67f9d99b9dc4b8906c03' or
            helper_build.get('outsideApplicationCheckout') is not True):
        raise ValueError('Actual helper/header/runtime build provenance differs')
    result = {'schema': 'abc.memory-ownership-native-preflight.v1',
              'sourceCommit': command('git', 'rev-parse', 'HEAD'),
              'symbols': {'perfAbi': 1, 'ownerAbi': 1, 'requiredSymbolsVerified': True},
              'requiredPerfSymbols': list(required_perf),
              'nativeEngineSha256': digest(engine), 'allocatorHelperSha256': digest(helper),
              'helperAvailabilityStatus': status,
              'allocatorBuild': helper_build,
              'allocatorBuildSha256': digest(helper_build_path),
              'cmake': {k: settings[k] for k in ('CMAKE_BUILD_TYPE', 'ABC_OWNER_DIAGNOSTICS', 'ABC_PERF_COUNTERS')},
              'actualCompilationTargets': targets}
    write(output, result)
    return result


def read_producer_fixture(path):
    """Read one bounded regular export without following a final symlink."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= PRODUCER_FIXTURE_LIMIT:
            raise ValueError('Producer fixture must be a nonempty regular file at most 16 KiB')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            content = stream.read(PRODUCER_FIXTURE_LIMIT + 1)
        after = os.fstat(descriptor)
        if (len(content) != before.st_size or len(content) > PRODUCER_FIXTURE_LIMIT or
                (before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise ValueError('Producer fixture changed during bounded read')
        return content, (before.st_dev, before.st_ino)
    finally:
        os.close(descriptor)


def validate_producer_fixture(content):
    # Reuse the real strict consumer. This minimal context only validates cycle
    # protocol rows; it neither fabricates nor validates a memory/raw report.
    from memory_ownership_validate import OwnershipValidator, exact_keys, integer, require, strict_json

    fixture = strict_json(content.decode('utf-8'))
    exact_keys(fixture, {'schema', 'arm', 'completed', 'interrupted'}, 'producer fixture')
    require(fixture['schema'] == 'abc.memory-ownership-producer-contract.v1'
            and fixture['arm'] == 'probe-only', 'producer fixture schema/arm differs')
    consumer = OwnershipValidator.__new__(OwnershipValidator)
    consumer.arm = fixture['arm']
    for name, count in (('completed', 8), ('interrupted', 7)):
        section = fixture[name]
        exact_keys(section, {'plannedCycles', 'completedCycles', 'cycles'}, f'producer {name}')
        require(integer(section['plannedCycles'], 'plannedCycles') == 8
                and integer(section['completedCycles'], 'completedCycles') == count,
                f'producer {name} cycle counts differ')
        rows = section['cycles']
        require(isinstance(rows, list) and len(rows) == 8, 'producer must export eight ordered cycle rows')
        for index, row in enumerate(rows):
            exact_keys(row, {'cycle', 'mode', 'scenario', 'status', 'productOperations'}, 'producer cycle')
            if name == 'completed' or index < 7:
                consumer.validate_cycle(row, index)
    completed, interrupted = fixture['completed']['cycles'], fixture['interrupted']['cycles']
    # Check types before dictionary equality can equate Boolean/float to integer.
    integer(interrupted[7]['cycle'], 'interrupted cycle index')
    integer(interrupted[7]['productOperations'], 'interrupted product operations')
    require(interrupted[:7] == completed[:7]
            and interrupted[7] == {**completed[7], 'status': 'running'},
            'interrupted producer must retain seven completed rows and the final running row')
    try:
        consumer.validate_cycle(interrupted[7], 7)
    except ValueError:
        pass
    else:
        raise ValueError('Strict consumer unexpectedly accepted the interrupted running cycle')


def producer_preflight(fixture_path, opt_in_fixture_path, output):
    first, first_identity = read_producer_fixture(fixture_path)
    second, second_identity = read_producer_fixture(opt_in_fixture_path)
    if first_identity == second_identity:
        raise ValueError('Default and opt-in exports must be independent files')
    validate_producer_fixture(first)
    validate_producer_fixture(second)
    if first != second:
        raise ValueError('Default and opt-in producer exports differ')
    head = command('git', 'rev-parse', 'HEAD')
    if re.fullmatch(r'[0-9a-f]{40}', head) is None:
        raise ValueError('Producer proof requires the actual Git HEAD')
    result = {'schema': 'abc.memory-ownership-producer-preflight.v1',
              'sourceCommit': head, 'fixtureSha256': hashlib.sha256(first).hexdigest(),
              'optInFixtureSha256': hashlib.sha256(second).hexdigest(),
              'contractPassed': True, 'completedAccepted': True, 'interruptedRejected': True,
              'exportsIdentical': True, 'proofScope': 'producer-cycle-protocol-only'}
    write(output, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    source = sub.add_parser('source')
    source.add_argument('--base-root', type=Path, required=True)
    source.add_argument('--output', type=Path, required=True)
    formatting = sub.add_parser('format')
    formatting.add_argument('--output', type=Path, required=True)
    native = sub.add_parser('native')
    native.add_argument('--bundle', type=Path, required=True)
    native.add_argument('--helper', type=Path, required=True)
    native.add_argument('--helper-build', type=Path, required=True)
    native.add_argument('--output', type=Path, required=True)
    producer = sub.add_parser('producer')
    producer.add_argument('--fixture', type=Path, required=True)
    producer.add_argument('--opt-in-fixture', type=Path, required=True)
    producer.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.mode == 'source':
        source_preflight(args.output, args.base_root.resolve())
    elif args.mode == 'format':
        format_archive(args.output)
    elif args.mode == 'producer':
        producer_preflight(args.fixture, args.opt_in_fixture, args.output)
    else:
        native_preflight(args.bundle.resolve(), args.helper.resolve(), args.helper_build.resolve(), args.output)


if __name__ == '__main__':
    main()
