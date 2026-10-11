#!/usr/bin/env python3
"""Layered source gate for the separate, first-attempt application diagnostic.

The original ownership source gate is retained unchanged. This gate accepts one
new reviewed overlay, verifies full independent 9d4 and 5a trees, then checks
actual worktree bytes for every committed path, including the manifest itself.
The manifest excludes its own recursive hash; its Git blob and separately
recorded SHA bind it in the independently enumerated remote checkout tree.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

BASE = '9d4cd5a0f9db03042a3986689fea374ba92d78b8'
BASE_TREE = '68de875853d92b0352077865cf862ffaceaaec92'
INHERITED = '5a161bf1215361e56358ed6476dbf97a69e53803'
PACKAGE_GATE = 'ac4596fef78b8705cce595075aa0c92d9e70faa4'
BRANCH = 'refs/heads/codex/memory-allocation-application-9d4'
MANIFEST = 'tool/perf/gperftools_application/source-manifest.json'
TARGET = 'integration_test/computer_memory_ownership_test.dart'
OLD_WORKFLOW = '.github/workflows/memory-ownership.yml'
NEW_WORKFLOW = '.github/workflows/gperftools-application.yml'
ROOT = Path(__file__).resolve().parents[3]
DIRECT_PARENT = '96c096e5ada603f1e6db517a76101dd9fe4e09d5'
DIRECT_PARENT_TREE = '7b6223f3b1c5703e8fadca6d3921b7597f9ced56'
INPLACE_TEST = 'tool/perf/gperftools_application/test_inplace_elf_contracts.py'
REVIEWED_IMPLEMENTATION_BLOBS = {'tool/perf/gperftools_application/attribution_coverage.py': '9329db360c1df47ed92640dffae5d64c99ff2455', 'tool/perf/gperftools_application/elf_identity.py': 'ad747cf2a9172da1c1ce22cc3e8a2424b5542910', 'tool/perf/gperftools_application/run_pair.py': 'a85f81ee214ea0bdbce5b50ef213394818a5a9df', 'tool/perf/gperftools_application/test_attribution_coverage.py': '012cf61a0acab8b6977e536c8eaec4603bb924d3', 'tool/perf/gperftools_application/test_deferred_identity_contracts.py': 'b1e3bc5cfa7a9aa5bd1f3ecc4f050fa1de5ab9d8', 'tool/perf/gperftools_application/test_runner_contracts.py': '4057b720385312788ed4e3434a1aab5411dad299'}
NEW_FILES = frozenset(['tool/perf/gperftools_application/attribution_coverage.py', 'tool/perf/gperftools_application/test_attribution_coverage.py', 'tool/perf/gperftools_application/test_deferred_identity_contracts.py'])
CORRECTION_PATHS = frozenset(REVIEWED_IMPLEMENTATION_BLOBS) | frozenset({
    'tool/perf/gperftools_application/application_source.py',
    MANIFEST,
})


def require(value, text):
    if not value:
        raise ValueError(text)


def git(root, *argv, binary=False):
    output = subprocess.check_output(['git', *argv], cwd=root, timeout=30)
    return output if binary else output.decode().strip()


def identity(path, expected):
    if expected['mode'] == '120000':
        require(path.is_symlink(), 'Expected committed symlink')
        data = os.readlink(path).encode()
    else:
        require(not path.is_symlink() and path.is_file(), 'Expected committed regular file')
        mode = '100755' if path.stat().st_mode & stat.S_IXUSR else '100644'
        require(mode == expected['mode'], 'Committed mode differs')
        data = path.read_bytes()
    blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
    require(blob == expected['blob'], 'Worktree bytes differ from independently listed Git blob')
    return {**expected, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def tree(root, commit):
    output = {}
    for line in git(root, 'ls-tree', '-rz', commit, binary=True).split(b'\0'):
        if not line:
            continue
        fields, name = line.split(b'\t', 1)
        mode, kind, blob = fields.decode().split()
        name = name.decode()
        path = Path(name)
        require(kind == 'blob' and mode in ('100644', '100755', '120000')
                and not path.is_absolute() and '..' not in path.parts
                and str(path) == name and '\\' not in name, 'Unsupported source tree entry')
        output[name] = dict(mode=mode, blob=blob)
    return output


def allowed_addition(name):
    return name.startswith(('tool/perf/gperftools_application/',
                            'tool/perf/gperftools_application_contracts/',
                            'tool/perf/gperftools_preflight/')) or name in (
        NEW_WORKFLOW, 'integration_test/support/memory_allocation_stack_probe.dart')


def verify_layers(manifest, base, inherited, current):
    require(manifest.get('schema') == 'abc.gperftools-application-source-manifest.v1'
            and manifest.get('baseCommit') == BASE and manifest.get('baseTree') == BASE_TREE
            and manifest.get('inheritedCommit') == INHERITED
            and manifest.get('packageGateCommit') == PACKAGE_GATE
            and manifest.get('branch') == BRANCH
            and manifest.get('directParentCommit') == DIRECT_PARENT
            and manifest.get('directParentTree') == DIRECT_PARENT_TREE, 'Source layer pins differ')
    require(len(base) == 886, 'Full fixed shipping tree differs')
    declared = manifest['files']
    require(set(declared) == set(current) - {MANIFEST}, 'Manifest final tree inventory differs')
    for name, row in declared.items():
        require({k: row[k] for k in ('mode', 'blob')} == current[name], 'Final committed source identity differs')
    historical = manifest['inheritedFiles']
    require(set(historical) == set(inherited), 'Inherited full tree inventory differs')
    for name, row in historical.items():
        require({k: row[k] for k in ('mode', 'blob')} == inherited[name], 'Historical source identity differs')
    require(set(inherited) - set(current) <= {OLD_WORKFLOW}, 'Unreviewed inherited file deletion')
    changed = {name for name in inherited.keys() & current.keys() if inherited[name] != current[name]}
    require(changed == {TARGET}, 'Only original integration harness may change in inherited tree')
    require(all(allowed_addition(name) for name in current.keys() - inherited.keys()),
            'Added path outside diagnostic-only overlay')
    require(NEW_WORKFLOW in current and MANIFEST in current, 'Actual-pair workflow/source manifest absent')
    # Existing product/diagnostic native/Dart owner hooks, schedule, inputs/ROI,
    # original validators and original cycle function remain inherited bytes.
    for name in base:
        if name not in inherited:
            raise ValueError('Inherited source unexpectedly removed a shipping file')
    return True


def verify_correction_parent(head, parents, parent_tree_sha, parent, current):
    """Only the eight reviewed correction paths may differ from the pinned parent.

    The independent 9d4/5a checks still run in verify_layers. This additional gate
    prevents a follow-up commit from modifying any already-reviewed application,
    workload, workflow, package contract, budget, or provenance dependency.
    """
    require(parents == [head, DIRECT_PARENT],
            'Deferred-symbol correction must have exactly the fixed diagnostic parent')
    require(parent_tree_sha == DIRECT_PARENT_TREE, 'Fixed diagnostic parent tree differs')
    require(set(parent) - set(current) == set(), 'Deferred-symbol correction cannot delete parent files')
    require(set(current) - set(parent) == NEW_FILES,
            'Only the three reviewed deferred-symbol files may be added to the fixed parent')
    changed = {name for name in parent.keys() | current.keys() if parent.get(name) != current.get(name)}
    require(changed == CORRECTION_PATHS, 'Deferred-symbol correction differs outside the exact eight-path delta')
    for name in CORRECTION_PATHS:
        require(current[name]['mode'] == '100644'
                and (name in NEW_FILES or parent[name]['mode'] == '100644'),
                'Deferred-symbol correction paths must remain regular non-executable sources')
    for name, blob in REVIEWED_IMPLEMENTATION_BLOBS.items():
        require(current[name]['blob'] == blob, 'Reviewed deferred-symbol implementation bytes differ: ' + name)
    return sorted(changed)


def source_gate(root, base_root, inherited_root, output):
    root, base_root, inherited_root = map(Path, (root, base_root, inherited_root))
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REF') == BRANCH
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Only fixed branch first GitHub attempt allowed')
    head = git(root, 'rev-parse', 'HEAD')
    require(head == os.environ.get('GITHUB_SHA'), 'Checkout head differs from this exact CI event')
    parents = git(root, 'rev-list', '--parents', '-n', '1', head).split()
    require(parents == [head, DIRECT_PARENT],
            'Deferred-symbol correction must have exactly the fixed diagnostic parent')
    parent_tree_sha = git(root, 'rev-parse', DIRECT_PARENT + '^{tree}')
    require(parent_tree_sha == DIRECT_PARENT_TREE, 'Fixed diagnostic parent tree differs')
    require(not git(root, 'status', '--porcelain', '--untracked-files=all'), 'Clean committed source required')
    require(git(base_root, 'rev-parse', 'HEAD') == BASE and git(base_root, 'rev-parse', 'HEAD^{tree}') == BASE_TREE,
            'Independent shipping checkout differs')
    require(git(inherited_root, 'rev-parse', 'HEAD') == INHERITED, 'Independent inherited checkout differs')
    base, inherited, current = tree(base_root, BASE), tree(inherited_root, INHERITED), tree(root, head)
    correction_paths = verify_correction_parent(
        head, parents, parent_tree_sha, tree(root, DIRECT_PARENT), current)
    payload = (root / MANIFEST).read_bytes()
    require(len(payload) <= 4 << 20, 'Source manifest cap')
    manifest = json.loads(payload)
    verify_layers(manifest, base, inherited, current)
    for name, expected in base.items():
        identity(base_root / name, expected)
    for name, expected in inherited.items():
        require(identity(inherited_root / name, expected) == manifest['inheritedFiles'][name], 'Inherited actual bytes differ')
    files = {name: identity(root / name, expected) for name, expected in sorted(current.items())}
    require(all(files[name] == row for name, row in manifest['files'].items()), 'Final SHA/size differs')
    import dependencies
    from run_preflight import validate_source_manifest
    package_manifest_sha = validate_source_manifest()
    proof = {'schema': 'abc.memory-ownership-source.v1', 'sourceCommit': head,
             'baseProductCommit': BASE, 'baseProductTree': BASE_TREE,
             'directParentCommit': DIRECT_PARENT, 'directParentTree': DIRECT_PARENT_TREE,
             'correctionPaths': correction_paths,
             'inheritedDiagnosticCommit': INHERITED, 'officialPackageGateCommit': PACKAGE_GATE,
             'officialPackageSourceManifestSha256': package_manifest_sha,
             'sourceTree': git(root, 'rev-parse', 'HEAD^{tree}'), 'baseFiles': 886,
             'sourceFiles': files, 'manifestSha256': hashlib.sha256(payload).hexdigest(),
             'selfHashPolicy': 'manifest excludes itself; independent Git tree and this proof bind its bytes',
             'diagnosticOverlay': True, 'shippingRuntimeUsed': False,
             'scheduleSha256': files['tool/perf/memory_ownership_schedule.json']['sha256'],
             'patchBaseCommit': DIRECT_PARENT,
             'patchScope': 'exact-eight-path-deferred-symbol-correction',
             'patchSha256': hashlib.sha256(git(root, 'diff', '--binary', '--full-index', DIRECT_PARENT, head, binary=True)).hexdigest()}
    with Path(output).open('x') as stream:
        json.dump(proof, stream, indent=2, sort_keys=True); stream.write('\n')
    return proof


def verify_source_proof(root, proof):
    require(proof.get('schema') == 'abc.memory-ownership-source.v1'
            and proof.get('baseProductCommit') == BASE
            and proof.get('inheritedDiagnosticCommit') == INHERITED
            and proof.get('officialPackageGateCommit') == PACKAGE_GATE
            and proof.get('directParentCommit') == DIRECT_PARENT
            and proof.get('directParentTree') == DIRECT_PARENT_TREE
            and proof.get('patchBaseCommit') == DIRECT_PARENT, 'Layered source proof missing')
    require(git(root, 'rev-parse', 'HEAD') == proof['sourceCommit']
            and not git(root, 'status', '--porcelain', '--untracked-files=all'), 'Source checkout changed')
    current = tree(root, proof['sourceCommit'])
    correction_paths = verify_correction_parent(
        proof['sourceCommit'], git(root, 'rev-list', '--parents', '-n', '1', proof['sourceCommit']).split(),
        git(root, 'rev-parse', DIRECT_PARENT + '^{tree}'), tree(root, DIRECT_PARENT), current)
    require(proof.get('correctionPaths') == correction_paths, 'Correction proof paths differ')
    require(set(current) == set(proof['sourceFiles']), 'Source proof tree differs')
    for name, expected in current.items():
        require(identity(Path(root) / name, expected) == proof['sourceFiles'][name], 'Source bytes changed after gate')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-root', required=True, type=Path)
    parser.add_argument('--inherited-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    source_gate(ROOT, args.base_root, args.inherited_root, args.output)
