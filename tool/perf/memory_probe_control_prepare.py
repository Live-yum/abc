#!/usr/bin/env python3
"""Overlay only explicit diagnostic files on fixed 51bc product in an owned CI checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

BASE = '51bc8eaa76b145b0d9bec3c95977779af43b676c'
ORIGINAL = 'integration_test/computer_memory_diagnostic_test.dart'
DART_FILES = (ORIGINAL, 'integration_test/computer_memory_probe_control_test.dart',
              'integration_test/support/computer_memory_probe_telemetry.dart')


def git(root, *arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments])


def original_overlay(data):
    text = data.decode('utf-8')
    if text.count('_cycle(') != 2:
        raise ValueError('Pinned private cycle source shape changed')
    return text.replace('_cycle(', 'runComputerMemoryDiagnosticCycle(').replace(
        'Future<_ObservedBackend> runComputerMemoryDiagnosticCycle(',
        '// ignore: library_private_types_in_public_api\nFuture<_ObservedBackend> runComputerMemoryDiagnosticCycle(').encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(workflow, source, output):
    workflow, source, output = (Path(p).resolve() for p in (workflow, source, output))
    if output.exists():
        raise ValueError('Use a new derivation output directory')
    if git(source, 'rev-parse', 'HEAD').decode().strip() != BASE:
        raise ValueError('Control must derive from the fixed original product')
    for root in (workflow, source):
        if git(root, 'status', '--porcelain', '--untracked-files=normal').strip():
            raise ValueError('Clean workflow and fixed-product checkouts required')
    source_manifest = json.loads((workflow / 'tool/perf/memory_probe_control_manifest.json').read_text())
    if source_manifest['baseCommit'] != BASE:
        raise ValueError('Manifest base mismatch')
    paths = sorted(set(DART_FILES) | {
        str(p.relative_to(workflow)) for p in (workflow / 'tool/perf').glob('memory_probe_control*')
        if p.is_file()
    } | {'.github/workflows/memory-probe-control.yml'})
    for name in paths:
        path = workflow / name
        if not path.is_file() or path.is_symlink():
            raise ValueError('Missing or linked diagnostic file: ' + name)
        if name != ORIGINAL and (source / name).exists():
            raise ValueError('Diagnostic addition would replace a base file: ' + name)
    original = git(source, 'show', BASE + ':' + ORIGINAL)
    # The workflow head may contain unrelated lint fixes. Reconstruct this one
    # test entry directly from the immutable base; never copy its HEAD body.
    pinned_original_overlay = original_overlay(original)
    schedule = workflow / source_manifest['schedule']
    if sha(schedule.read_bytes()) != source_manifest['scheduleSha256']:
        raise ValueError('Timing configuration digest mismatch')
    output.mkdir(parents=True)
    for name in paths:
        dest = source / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        if name == ORIGINAL:
            dest.write_bytes(pinned_original_overlay)
        else:
            shutil.copyfile(workflow / name, dest)
    git(source, 'add', '--', *paths)
    patch = git(source, 'diff', '--cached', '--no-color', '--binary', '--full-index')
    (output / 'diagnostic-overlay.patch').write_bytes(patch)
    subprocess.run(['git', '-C', str(source), '-c', 'user.name=Memory diagnostic CI',
                    '-c', 'user.email=memory-diagnostic@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-m',
                    'test: derive fixed-product memory measurement control'], check=True)
    derived = git(source, 'rev-parse', 'HEAD').decode().strip()
    if git(source, 'status', '--porcelain', '--untracked-files=normal').strip():
        raise ValueError('Derived diagnostic checkout is not clean')
    result = {
        'schema': 'abc.memory-probe-control-derivation.v1', 'baseCommit': BASE,
        'overlaySourceCommit': git(workflow, 'rev-parse', 'HEAD').decode().strip(),
        'derivedCommit': derived, 'derivedTree': git(source, 'rev-parse', 'HEAD^{tree}').decode().strip(),
        'patchSha256': sha(patch), 'patchFile': 'diagnostic-overlay.patch',
        'scheduleSha256': sha(schedule.read_bytes()),
        'overlayFilesSha256': {name: sha((source / name).read_bytes()) for name in paths},
        'productChangesAllowed': False,
        'localCommitOnly': True,
    }
    (output / 'derivation.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workflow-root', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = prepare(args.workflow_root, args.source, args.output)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
