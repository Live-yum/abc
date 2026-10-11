"""Fixed sampled-fixture correction retaining the original frozen 2b audit."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'gperftools_application'))
import dependencies
from application_source import (git, tree, identity, require, BASE, BASE_TREE, INHERITED,
    DIRECT_PARENT as HISTORICAL_PARENT, DIRECT_PARENT_TREE as HISTORICAL_PARENT_TREE,
    MANIFEST as HISTORICAL_MANIFEST, verify_layers, verify_correction_parent)
from application_process import read_json, save

PARENT = '2b6397da3279926d91280d9a32f4b19d3488f349'
PARENT_TREE = '01b1dadab0cde210d61c560c4137b4a942a09f1d'
BRANCH = 'refs/heads/codex/sampled-q0-feasibility-9d4'
TARGET = 'integration_test/computer_memory_sampled_q0_test.dart'
BRIDGE = 'integration_test/support/memory_sampled_q0_probe.dart'
WORKFLOW = '.github/workflows/gperftools-sampled-q0.yml'
MANIFEST = 'tool/perf/gperftools_sampled/source-manifest.json'
ROOT = Path(__file__).resolve().parents[3]
DIRECT_PARENT = 'c9cbca50f9796c104e023a83aa085583ec4346cc'
DIRECT_PARENT_TREE = '206051c0bc836bb41ff46f285495af770ae3017e'
SOURCE = 'tool/perf/gperftools_sampled/sampled_source.py'
SOURCE_TEST = 'tool/perf/gperftools_sampled/test_sampled_runner.py'
REVIEWED_FIXTURE_SHA256 = {
    'tool/perf/gperftools_sampled/small_contract_stub_test.cc':
        'e1f5d28f545c25523c616b1799b55a9496f690e2800230e2501bbc111e4fc935',
    'tool/perf/gperftools_sampled/test_small_sample_contract.py':
        '9fd49312dc5320fe0b6c9304709bc019b49c13c5919db3ab25827ada331957e0',
}
CORRECTION_PATHS = frozenset(REVIEWED_FIXTURE_SHA256) | {SOURCE, SOURCE_TEST, MANIFEST, WORKFLOW}
ORIGINAL_ADDED_PATHS = 34


def validate_overlay(parent, current, manifest):
    require(manifest.get('schema') == 'abc.sampled-source-manifest.v1'
            and manifest.get('parentCommit') == PARENT and manifest.get('parentTree') == PARENT_TREE,
            'Sampled source seal parent differs')
    require(all(current.get(name) == entry for name, entry in parent.items()),
            'Sampled diagnostic changed or removed frozen product/workload/full-profiler files')
    added = set(current) - set(parent)
    require(added == set(manifest['addedFiles']) | {MANIFEST}, 'Sampled added paths differ from exact seal')
    require({TARGET, BRIDGE, WORKFLOW} <= added, 'Sampled independent entry/bridge/workflow missing')
    require(all(name in (TARGET, BRIDGE, WORKFLOW) or name.startswith('tool/perf/gperftools_sampled/')
                for name in added), 'Sampled path outside reviewed additive scope')
    require(all(current[name]['mode'] == '100644' for name in added), 'Sampled executable/symlink addition forbidden')
    return sorted(added)


def validate_correction_parent(head, parents, parent_tree_sha, parent, current):
    require(parents == [head, DIRECT_PARENT], 'Fixture correction requires the exact sole c9 parent')
    require(parent_tree_sha == DIRECT_PARENT_TREE, 'Fixed sampled c9 parent tree differs')
    require(set(parent) == set(current), 'Fixture correction cannot add or remove paths')
    changed = {name for name in current if parent[name] != current[name]}
    require(changed == CORRECTION_PATHS, 'Fixture correction differs outside the exact six paths')
    require(all(parent[name]['mode'] == current[name]['mode'] == '100644' for name in changed),
            'Fixture correction sources must remain regular non-executable files')
    return sorted(changed)


def validate_correction_bytes(parent_workflow, current_workflow, files):
    needle = b'          fetch-depth: 2\n          persist-credentials: false\n'
    require(parent_workflow.count(needle) == 1 and current_workflow == parent_workflow.replace(
        needle, needle.replace(b': 2', b': 3'), 1),
        'Workflow correction must change only the first checkout depth from 2 to 3')
    for name, digest in REVIEWED_FIXTURE_SHA256.items():
        require(files.get(name, {}).get('sha256') == digest, 'Reviewed fixture bytes differ: ' + name)


def build_correction_manifest(root, original_manifest):
    """Prepare a deterministic seal; caller reviews the plan before writing it.

    Self is excluded exactly as before. Its actual Git blob and independently
    enumerated sourceFiles bind it, avoiding a recursive manifest/source hash.
    """
    require(original_manifest.get('schema') == 'abc.sampled-source-manifest.v1'
            and original_manifest.get('parentCommit') == PARENT
            and original_manifest.get('parentTree') == PARENT_TREE,
            'Original additive seal pins differ')
    paths = set(original_manifest['addedFiles'])
    require(len(paths) + 1 == ORIGINAL_ADDED_PATHS and MANIFEST not in paths
            and {TARGET, BRIDGE, WORKFLOW, SOURCE, SOURCE_TEST} <= paths,
            'Original 34-path additive seal inventory differs')
    files = {}
    for name in sorted(paths):
        path = Path(root) / name
        require(path.is_file() and not path.is_symlink() and not path.stat().st_mode & 0o111,
                'Correction seal requires non-executable regular files')
        data = path.read_bytes()
        files[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    return {**original_manifest, 'addedFiles': files,
        'directParentCommit': DIRECT_PARENT, 'directParentTree': DIRECT_PARENT_TREE,
        'correctionPaths': sorted(CORRECTION_PATHS),
        'reviewedFixtureSha256': dict(REVIEWED_FIXTURE_SHA256),
        'selfHashPolicy': 'Self omitted from addedFiles; Git blob and independently enumerated current tree bind manifest bytes.'}


def verify_correction(root, head, current, manifest, files):
    require(manifest.get('directParentCommit') == DIRECT_PARENT
            and manifest.get('directParentTree') == DIRECT_PARENT_TREE
            and manifest.get('branch') == BRANCH
            and manifest.get('correctionPaths') == sorted(CORRECTION_PATHS)
            and manifest.get('reviewedFixtureSha256') == REVIEWED_FIXTURE_SHA256,
            'Fixture correction seal pins or scope differ')
    parent = tree(root, DIRECT_PARENT)
    changed = validate_correction_parent(head,
        git(root, 'rev-list', '--parents', '-n', '1', head).split(),
        git(root, 'rev-parse', DIRECT_PARENT + '^{tree}'), parent, current)
    require(git(root, 'rev-list', '--parents', '-n', '1', DIRECT_PARENT).split() == [DIRECT_PARENT, PARENT],
            'Original sampled c9 parent is not the frozen 2b commit')
    require(git(root, 'rev-parse', PARENT + '^{tree}') == PARENT_TREE, 'Original frozen 2b tree differs')
    original = tree(root, PARENT)
    parent_manifest = json.loads(git(root, 'show', DIRECT_PARENT + ':' + MANIFEST))
    added = validate_overlay(original, parent, parent_manifest)
    require(len(added) == ORIGINAL_ADDED_PATHS, 'Original sampled c9 additive inventory differs')
    # Replay the ORIGINAL seal against c9 Git objects, not corrected worktree
    # files. All original product/workload comparisons remain against 2b.
    for name, expected in parent_manifest['addedFiles'].items():
        data = git(root, 'show', DIRECT_PARENT + ':' + name, binary=True)
        require({'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()} == expected,
                'Original sampled c9 seal bytes differ: ' + name)
    require(validate_overlay(original, current, manifest) == added,
            'Corrected additive inventory differs from original sampled c9')
    validate_correction_bytes(git(root, 'show', DIRECT_PARENT + ':' + WORKFLOW, binary=True),
                              (Path(root) / WORKFLOW).read_bytes(), files)
    return changed


def verify_source(root, proof):
    require(proof.get('schema') == 'abc.sampled-source-proof.v1'
            and proof.get('parentCommit') == PARENT and proof.get('parentTree') == PARENT_TREE
            and proof.get('directParentCommit') == DIRECT_PARENT
            and proof.get('directParentTree') == DIRECT_PARENT_TREE
            and proof.get('correctionPaths') == sorted(CORRECTION_PATHS)
            and proof.get('baseProductCommit') == BASE, 'Sampled source proof differs')
    head = git(root, 'rev-parse', 'HEAD')
    require(head == proof['sourceCommit'] and git(root, 'rev-list', '--parents', '-n', '1', head).split() == [head, DIRECT_PARENT],
            'Sampled head or exact sole parent changed')
    require(git(root, 'rev-parse', PARENT + '^{tree}') == PARENT_TREE, 'Sampled parent tree differs')
    current = tree(root, head)
    require(set(current) == set(proof['sourceFiles']), 'Sampled source file set changed')
    for name, entry in current.items():
        require(identity(Path(root) / name, entry) == proof['sourceFiles'][name], 'Sampled source bytes changed: ' + name)
    require(not git(root, 'status', '--porcelain', '--untracked-files=all'), 'Sampled worktree not clean')
    manifest = read_json(Path(root) / MANIFEST)
    verify_correction(root, head, current, manifest, proof['sourceFiles'])
    for name, expected in manifest['addedFiles'].items():
        observed = proof['sourceFiles'][name]
        require({key: observed[key] for key in ('sha256', 'bytes')} == expected, 'Sampled seal bytes differ: ' + name)


def verify_historical_parent(parent_root, base_root, inherited_root):
    """Replay immutable tree contracts without pretending this is the old CI event."""
    require(git(parent_root, 'rev-parse', 'HEAD') == PARENT
            and git(parent_root, 'rev-parse', 'HEAD^{tree}') == PARENT_TREE,
            'Independent parent checkout identity differs')
    require(not git(parent_root, 'status', '--porcelain', '--untracked-files=all'), 'Historical parent checkout dirty')
    require(git(base_root, 'rev-parse', 'HEAD') == BASE and git(base_root, 'rev-parse', 'HEAD^{tree}') == BASE_TREE,
            'Independent shipping tree differs')
    require(git(inherited_root, 'rev-parse', 'HEAD') == INHERITED, 'Independent original workload tree differs')
    base, inherited, historical = tree(base_root, BASE), tree(inherited_root, INHERITED), tree(parent_root, PARENT)
    historical_parents = git(parent_root, 'rev-list', '--parents', '-n', '1', PARENT).split()
    correction = verify_correction_parent(PARENT, historical_parents,
        git(parent_root, 'rev-parse', HISTORICAL_PARENT + '^{tree}'), tree(parent_root, HISTORICAL_PARENT), historical)
    manifest = read_json(Path(parent_root) / HISTORICAL_MANIFEST)
    verify_layers(manifest, base, inherited, historical)
    for name, entry in base.items():
        identity(Path(base_root) / name, entry)
    for name, entry in inherited.items():
        require(identity(Path(inherited_root) / name, entry) == manifest['inheritedFiles'][name],
                'Original workload actual bytes differ')
    files = {name: identity(Path(parent_root) / name, entry) for name, entry in historical.items()}
    require(all(files[name] == entry for name, entry in manifest['files'].items()), 'Historical source SHA/size differs')
    return {'schema': 'abc.sampled-historical-parent.v1', 'sourceCommit': PARENT,
        'sourceTree': PARENT_TREE, 'baseProductCommit': BASE, 'inheritedDiagnosticCommit': INHERITED,
        'historicalCorrectionPaths': correction, 'sourceFiles': files,
        'historicalEventWasNotExecutedOrImpersonated': True}


def source_gate(root, parent_root, base_root, inherited_root, output):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REF') == BRANCH
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Only real sampled first-attempt event allowed')
    previous = verify_historical_parent(parent_root, base_root, inherited_root)
    inherited = tree(parent_root, PARENT)
    head = git(root, 'rev-parse', 'HEAD')
    require(head == os.environ.get('GITHUB_SHA'), 'Sampled head differs from actual CI event')
    current = tree(root, head)
    manifest = read_json(Path(root) / MANIFEST)
    added = validate_overlay(inherited, current, manifest)
    files = {name: identity(Path(root) / name, entry) for name, entry in current.items()}
    proof = {'schema': 'abc.sampled-source-proof.v1', 'sourceCommit': head,
        'parentCommit': PARENT, 'parentTree': PARENT_TREE, 'baseProductCommit': BASE,
        'directParentCommit': DIRECT_PARENT, 'directParentTree': DIRECT_PARENT_TREE,
        'correctionPaths': sorted(CORRECTION_PATHS),
        'sourceFiles': files, 'addedPaths': added,
        'parentProofSha256': hashlib.sha256(json.dumps(previous, sort_keys=True).encode()).hexdigest(),
        'scheduleSha256': files['tool/perf/memory_ownership_schedule.json']['sha256'],
        'sampledTargetSha256': files[TARGET]['sha256'], 'mode': 'sampled-q0-only',
        'originalEightCycleWorkloadCompleted': False}
    verify_source(root, proof)
    save(Path(output).with_name('parent-source-proof.json'), previous, new=True)
    save(output, proof, new=True)
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent-root', type=Path, required=True)
    parser.add_argument('--base-root', type=Path, required=True)
    parser.add_argument('--inherited-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source_gate(ROOT, args.parent_root, args.base_root, args.inherited_root, args.output)
