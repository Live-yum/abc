#!/usr/bin/env python3
"""Add diagnostics to the fixed product in an owned checkout; never publish it.

All existing blobs, executable bits and symlink bytes are verified directly,
regardless of Git's ignored, assume-unchanged or skip-worktree hints. Generated
ignored build outputs may exist at verification time; they never exempt tracked
files from verification. Preparation requires an empty untracked working tree.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess

BASE = '661f9f17531e87f0b3f9f7028d70a94814c21234'
BASE_TREE = '9ff4ca286afa3e545901c498de167ee0c5dfc61d'
SCHEDULE = 'tool/perf/memory_probe_control_schedule.json'
SCHEDULE_SHA256 = 'bedae8b1416f4124160c4e75323436e3b04df4fc1b709c89a04a34070087657a'
TARGET = 'integration_test/computer_native_retention_test.dart'
SUPPORT = 'integration_test/support/native_retention_probe.dart'
WORKFLOW = '.github/workflows/native-retention.yml'
REQUIRED = {TARGET, SUPPORT, WORKFLOW, 'tool/perf/native_retention_probe.c',
            'tool/perf/native_retention_prepare.py', 'tool/perf/native_retention_build.py',
            'tool/perf/native_retention_protocol.py', 'tool/perf/native_retention_run.py',
            'tool/perf/native_retention_validate.py', 'tool/perf/native_retention_manifest.json',
            'tool/perf/native_retention_probe_contract.dart'}
HEX40 = re.compile(r'^[0-9a-f]{40}$')


class InvariantError(ValueError):
    """Source or evidence no longer matches the fixed experiment."""


def git(root, *arguments):
    return subprocess.check_output([
        'git', '--no-replace-objects', '-C', str(root), '-c', 'core.hooksPath=/dev/null',
        '-c', 'core.fsmonitor=false', *arguments], stderr=subprocess.PIPE)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def overlay_allowed(name):
    return name in {TARGET, SUPPORT, WORKFLOW} or (
        name.startswith('tool/perf/native_retention')
        and '/' not in name[len('tool/perf/'):])


def safe_path(root, name):
    parts = PurePosixPath(name).parts
    if (not parts or PurePosixPath(name).is_absolute() or '..' in parts
            or '.' in parts or '.git' in parts or '\\' in name):
        raise InvariantError('Unsafe source path: ' + name)
    parent = root
    for part in parts[:-1]:
        parent = parent / part
        if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
            raise InvariantError('Linked or non-directory source parent: ' + name)
    return root.joinpath(*parts)


def tree_entries(root, commit):
    result = {}
    for row in git(root, 'ls-tree', '-r', '-z', '--full-tree', commit).split(b'\0'):
        if row:
            info, name = row.split(b'\t', 1)
            mode, kind, oid = info.decode('ascii').split()
            name = name.decode('utf-8')
            safe_path(root, name)
            result[name] = (mode, kind, oid)
    return result


def file_manifest(root, name, entry, *, diagnostic=False):
    mode, kind, oid = entry
    path = safe_path(root, name)
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise InvariantError('Missing tracked source: ' + name) from error
    if kind != 'blob':
        raise InvariantError('Only auditable Git blobs are supported: ' + name)
    if mode == '120000' and stat.S_ISLNK(metadata.st_mode) and not diagnostic:
        data = os.fsencode(os.readlink(path))
    elif mode in ('100644', '100755') and stat.S_ISREG(metadata.st_mode):
        actual_mode = '100755' if metadata.st_mode & 0o111 else '100644'
        if actual_mode != mode:
            raise InvariantError('Tracked source mode differs: ' + name)
        data = path.read_bytes()
    else:
        raise InvariantError('Linked or changed tracked source type: ' + name)
    blob = hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()
    if blob != oid:
        raise InvariantError('Tracked source bytes differ: ' + name)
    return {'mode': mode, 'gitBlob': oid, 'sha256': sha(data), 'bytes': len(data)}


def audit_checkout(root, entries, *, no_ignored=False):
    # Inspect the index itself as well as working bytes: status can conceal
    # changed files through assume-unchanged, skip-worktree or core.filemode.
    indexed = {}
    for row in git(root, 'ls-files', '--stage', '-z').split(b'\0'):
        if row:
            info, name = row.split(b'\t', 1)
            mode, oid, stage = info.decode('ascii').split()
            if stage != '0':
                raise InvariantError('Unmerged source index')
            indexed[name.decode('utf-8')] = (mode, 'blob', oid)
    if indexed != entries:
        raise InvariantError('Source index differs from its committed tree')
    if git(root, 'ls-files', '--others', '--exclude-standard', '-z'):
        raise InvariantError('Unexpected untracked source files')
    if no_ignored and git(root, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z'):
        raise InvariantError('Initial product checkout contains ignored untracked files')
    return {name: file_manifest(root, name, entry)
            for name, entry in sorted(entries.items())}


def read_json(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 32 * 1024 * 1024:
        raise InvariantError('Missing, linked or oversized derivation evidence')
    result = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(result, dict):
        raise InvariantError('Derivation must be a JSON object')
    return result


def patch_bytes(root, head):
    return git(root, 'diff', '--no-ext-diff', '--no-textconv', '--no-renames',
               '--no-color', '--binary', '--full-index', '--src-prefix=a/',
               '--dst-prefix=b/', '--no-relative', BASE, head, '--')


def write_json(path, value):
    with Path(path).open('x', encoding='utf-8') as target:
        target.write(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def verify_source(source, derivation_path):
    """Return exact identity and per-file evidence; safe before and after a run."""
    source = Path(source).resolve()
    derivation_path = Path(derivation_path)
    derivation = read_json(derivation_path)
    head = git(source, 'rev-parse', '--verify', 'HEAD').decode().strip()
    base_tree = git(source, 'rev-parse', BASE + '^{tree}').decode().strip()
    tree = git(source, 'rev-parse', 'HEAD^{tree}').decode().strip()
    if base_tree != BASE_TREE:
        raise InvariantError('Fixed product tree mismatch')
    if git(source, 'rev-list', '--parents', '-n', '1', head).decode().split() != [head, BASE]:
        raise InvariantError('Derived commit must have exactly the fixed product parent')
    old, new = tree_entries(source, BASE), tree_entries(source, head)
    if any(new.get(name) != entry for name, entry in old.items()):
        raise InvariantError('An existing product file was replaced, changed or deleted')
    additions = sorted(new.keys() - old.keys())
    if not additions or any(not overlay_allowed(name) for name in additions):
        raise InvariantError('Unexpected tracked addition outside diagnostic whitelist')
    if not REQUIRED.issubset(additions):
        raise InvariantError('Required new diagnostic additions are missing')
    all_files = audit_checkout(source, new)
    overlay = {name: file_manifest(source, name, new[name], diagnostic=True) for name in additions}
    product = {name: all_files[name] for name in sorted(old)}
    schedule_hash = sha(safe_path(source, SCHEDULE).read_bytes())
    if schedule_hash != SCHEDULE_SHA256:
        raise InvariantError('Frozen timing schedule digest mismatch')
    patch = patch_bytes(source, head)
    patch_file = derivation_path.parent / 'diagnostic-overlay.patch'
    if patch_file.is_symlink() or not patch_file.is_file() or patch_file.read_bytes() != patch:
        raise InvariantError('Preserved exact patch differs from committed additions')
    expected = {
        'schema': 'abc.native-retention-derivation.v1',
        'baseCommit': BASE, 'baseTree': BASE_TREE, 'derivedCommit': head,
        'derivedTree': tree, 'patchFile': 'diagnostic-overlay.patch',
        'patchSha256': sha(patch), 'schedule': SCHEDULE,
        'scheduleSha256': schedule_hash, 'changedPaths': additions,
        'overlayFiles': overlay,
        'overlayFilesSha256': {name: item['sha256'] for name, item in overlay.items()},
        'productChangesAllowed': False, 'localCommitOnly': True,
    }
    if any(derivation.get(key) != value for key, value in expected.items()):
        raise InvariantError('Derivation identity or file manifest differs')
    if not HEX40.fullmatch(derivation.get('overlaySourceCommit', '')):
        raise InvariantError('Missing overlay source commit')
    return {
        **expected, 'schema': 'abc.native-retention-source.v1',
        'overlaySourceCommit': derivation['overlaySourceCommit'],
        'productFiles': product, 'productPathsUnchanged': True,
        'derivationSha256': sha(derivation_path.read_bytes()),
        'verification': 'All base/derived blob IDs and modes match; every tracked working file is checked directly, including hidden and ignored files.',
    }


def check_source_unchanged(source, derivation_path, provenance):
    current = verify_source(source, derivation_path)
    if current != provenance:
        raise InvariantError('Source or derivation changed during the experiment')
    return current


def prepare(workflow, source, output):
    if Path(output).is_symlink():
        raise InvariantError('Use a new ordinary derivation output directory')
    workflow, source, output = (Path(p).resolve() for p in (workflow, source, output))
    if (source == workflow or source in workflow.parents or workflow in source.parents
            or output == source or source in output.parents
            or output == workflow or workflow in output.parents):
        raise InvariantError('Use distinct checkouts and external evidence output')
    if output.exists():
        raise InvariantError('Use a new derivation output directory')
    if git(source, 'rev-parse', 'HEAD').decode().strip() != BASE:
        raise InvariantError('Source must be the fixed final product checkout')
    if git(source, 'rev-parse', 'HEAD^{tree}').decode().strip() != BASE_TREE:
        raise InvariantError('Fixed product tree mismatch')
    old = tree_entries(source, BASE)
    audit_checkout(source, old, no_ignored=True)
    workflow_head = git(workflow, 'rev-parse', 'HEAD').decode().strip()
    workflow_entries = tree_entries(workflow, workflow_head)
    audit_checkout(workflow, workflow_entries)
    names = sorted(name for name in workflow_entries if overlay_allowed(name))
    if not REQUIRED.issubset(names):
        raise InvariantError('Required new diagnostic additions are missing')
    prepared = {}
    overlay = {}
    for name in names:
        if name in old or os.path.lexists(safe_path(source, name)):
            raise InvariantError('Diagnostic addition would replace a base file: ' + name)
        overlay[name] = file_manifest(workflow, name, workflow_entries[name], diagnostic=True)
        prepared[name] = safe_path(workflow, name).read_bytes()
    if (SCHEDULE not in old
            or sha(safe_path(source, SCHEDULE).read_bytes()) != SCHEDULE_SHA256):
        raise InvariantError('Frozen timing schedule digest mismatch')
    # All validation above is read-only. Never copy another workflow's product,
    # schedule, existing tests, prior workflow files or original cycle function.
    output.mkdir(parents=True)
    for name, data in prepared.items():
        dest = safe_path(source, name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        with dest.open('xb') as target:
            target.write(data)
        dest.chmod(0o755 if overlay[name]['mode'] == '100755' else 0o644)
    git(source, 'add', '--', *names)
    staged = git(source, 'write-tree').decode().strip()
    expected_entries = {**old, **{name: workflow_entries[name] for name in names}}
    if tree_entries(source, staged) != expected_entries:
        raise InvariantError('Staging transformed source bytes or modes')
    audit_checkout(source, expected_entries)
    git(source, '-c', 'user.name=Native retention diagnostic CI',
        '-c', 'user.email=native-retention@example.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '-m',
        'test: derive fixed-product native retention observation')
    head = git(source, 'rev-parse', 'HEAD').decode().strip()
    patch = patch_bytes(source, head)
    (output / 'diagnostic-overlay.patch').write_bytes(patch)
    result = {
        'schema': 'abc.native-retention-derivation.v1',
        'baseCommit': BASE, 'baseTree': BASE_TREE,
        'overlaySourceCommit': workflow_head, 'derivedCommit': head,
        'derivedTree': git(source, 'rev-parse', 'HEAD^{tree}').decode().strip(),
        'patchSha256': sha(patch), 'patchFile': 'diagnostic-overlay.patch',
        'schedule': SCHEDULE, 'scheduleSha256': SCHEDULE_SHA256,
        'changedPaths': names, 'overlayFiles': overlay,
        'overlayFilesSha256': {name: item['sha256'] for name, item in overlay.items()},
        'productChangesAllowed': False, 'localCommitOnly': True,
    }
    write_json(output / 'derivation.json', result)
    verify_source(source, output / 'derivation.json')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workflow-root', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.workflow_root, args.source, args.output), indent=2))


if __name__ == '__main__':
    main()
