"""Additive sampled-only overlay on an independently verified frozen 2b tree."""
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


def verify_source(root, proof):
    require(proof.get('schema') == 'abc.sampled-source-proof.v1'
            and proof.get('parentCommit') == PARENT and proof.get('parentTree') == PARENT_TREE
            and proof.get('baseProductCommit') == BASE, 'Sampled source proof differs')
    head = git(root, 'rev-parse', 'HEAD')
    require(head == proof['sourceCommit'] and git(root, 'rev-list', '--parents', '-n', '1', head).split() == [head, PARENT],
            'Sampled head or exact sole parent changed')
    require(git(root, 'rev-parse', PARENT + '^{tree}') == PARENT_TREE, 'Sampled parent tree differs')
    current = tree(root, head)
    require(set(current) == set(proof['sourceFiles']), 'Sampled source file set changed')
    for name, entry in current.items():
        require(identity(Path(root) / name, entry) == proof['sourceFiles'][name], 'Sampled source bytes changed: ' + name)
    require(not git(root, 'status', '--porcelain', '--untracked-files=all'), 'Sampled worktree not clean')
    manifest = read_json(Path(root) / MANIFEST)
    validate_overlay(tree(root, PARENT), current, manifest)
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
