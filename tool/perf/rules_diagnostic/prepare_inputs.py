#!/usr/bin/env python3
"""Freeze only the verified inputs needed for an auxiliary rules-only diagnosis."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
PINS = {
    'baseline': ('a5612b474fc8dc50d41b3bc6b87234d30ba97e02', '19afe39726b5ee724af413c2546c4389c5d0c205'),
    'candidate': ('cddd936f95d31b14a76503e13ffc89173110a057', 'ff5236bcfa02b8fcb3f361e9437c59c5bacc60fd'),
}
PACKAGE_FILES = ['prepare_inputs.py', 'run_diagnostic.py', 'runner.template.mjs',
                 'diagnostic_probe.mjs', 'test_probe.mjs', 'test_diagnostic.py', 'README.md']
EXPECTED = {
    'baseline': {
        'web/engine/world.js': '957c19caf1995131ac8bc462d66f0cf81df2a0be48adb1ae1070c7cdb4366e87',
        'web/engine/world.wasm': 'b3ace044d3b466eee338d25c87dd034c10cc8e73ec1c07e5f900bf42c694e7b8',
    },
    'candidate': {
        'web/engine/world.js': '50bb9a182ac1c596d5c67b84ced4d77c69a29d6bf41a4346807d46920962b47d',
        'web/engine/world.wasm': 'a9af2ce7aed0b4304c21f59e4500fd9116221588840e39af1e453459d8bf4a08',
    },
}
COMMON = {
    'web/engine/circuit_rules_web.js': '5354077e8fd4e04fb3b93557281a389a6849a1d68aeb68c36cb6dfa4c65254a5',
    'tool/perf/benchmark_wasm.mjs': 'be4c99a63cbb3e1a17c16fce297cfc8ab06d80ebe5d443bb61e454bb664472ab',
    'tool/perf/metrics.mjs': 'b1b89a3c9e83a327f16c10d0a66065a1c16a5b498851262dafc643f7a2e4b6e8',
    'tool/perf/compare.py': '91f4073d6701a84ac1a880a5a77131b36c0ad0135620a7da977c914509985be8',
    '.flutter-version': 'af7ad6b385523c1c98977a15b50c53b1fd4f35b1c5d85513600a03ba3284f6b1',
}
START = 'let rules;\nasync function rulesCycle() {'
END = '\ntry {\n  const fresh='

def digest(data):
    return hashlib.sha256(data).hexdigest()

def fragment(source):
    return source[source.index(START):source.index(END)]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--candidate-source', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--allow-file-snapshot-for-validation', action='store_true',
                        help='Local validator-only package; such a package cannot execute a benchmark')
    args = parser.parse_args()
    sources = {'baseline': args.baseline_source.resolve(), 'candidate': args.candidate_source.resolve()}
    destination = args.output_dir.resolve()
    if destination.exists():
        raise SystemExit('Refusing to overwrite existing prepared package.')
    manifest_path = destination / 'input-manifest.json'
    manifest = {'schema': 'abc.rules-only-inputs.v1', 'scope': 'Auxiliary diagnostic; never full-suite acceptance',
                'originalFailure': 'https://github.com/Live-yum/abc/actions/runs/37920825896',
                'pairedEvidence': 'https://github.com/Live-yum/abc/actions/runs/37945670244',
                'sequence': ['baseline', 'candidate', 'candidate', 'baseline', 'baseline', 'candidate'],
                'coldCycles': 1, 'warmupCycles': 5, 'measuredCycles': 25,
                'sourceGitVerified': not args.allow_file_snapshot_for_validation,
                'roles': {}, 'generated': {}}
    pending = []
    for role, (commit, tree) in PINS.items():
        source = sources[role]
        if not args.allow_file_snapshot_for_validation:
            git = lambda *words: subprocess.check_output(['git', '-C', str(source), *words], text=True, stderr=subprocess.DEVNULL).strip()
            if git('rev-parse', 'HEAD') != commit or git('rev-parse', 'HEAD^{tree}') != tree or git('status', '--porcelain', '--untracked-files=all'):
                raise SystemExit(f'Pinned Git identity or cleanliness failed: {role}')
        files = {}
        for relative, expected in {**COMMON, **EXPECTED[role]}.items():
            data = (source / relative).read_bytes()
            if digest(data) != expected:
                raise SystemExit(f'Unverified input: {role}/{relative}')
            target = destination / 'inputs' / role / relative
            if target.exists():
                raise SystemExit(f'Refusing to replace existing input: {target}')
            pending.append((target, data))
            files[relative] = {'sha256': expected, 'bytes': len(data)}
        manifest['roles'][role] = {'sourceCommit': commit, 'sourceTree': tree,
            'sourceOrigin': {'repository': 'Live-yum/abc', 'commit': commit},
            'gitVerified': not args.allow_file_snapshot_for_validation, 'files': files}
    snippets = [fragment((source / 'tool/perf/benchmark_wasm.mjs').read_text()) for source in sources.values()]
    if snippets[0] != snippets[1]:
        raise SystemExit('A/B rulesCycle differs')
    template = (ROOT / 'runner.template.mjs').read_text()
    assert template.count('/* ORIGINAL_RULES_CYCLE */') == 1
    generated = template.replace('/* ORIGINAL_RULES_CYCLE */', snippets[0]).encode()
    pending.append((destination / 'rules_runner.mjs', generated))
    manifest['rulesCycleSha256'] = digest(snippets[0].encode())
    manifest['generated']['rules_runner.mjs'] = {'sha256': digest(generated), 'bytes': len(generated)}
    for relative in PACKAGE_FILES:
        pending.append((destination / relative, (ROOT / relative).read_bytes()))
    for target, data in pending:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as output:
            output.write(data)
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    source_files = PACKAGE_FILES + ['rules_runner.mjs', 'input-manifest.json']
    source_manifest = {'schema': 'abc.rules-only-source-manifest.v1', 'scope': manifest['scope'],
        'files': {relative: {'sha256': digest((destination / relative).read_bytes()),
                            'bytes': (destination / relative).stat().st_size} for relative in source_files}}
    (destination / 'source-manifest.json').write_text(json.dumps(source_manifest, indent=2) + '\n')
    print('Prepared verified snapshots and exact rulesCycle; no benchmark executed.')

if __name__ == '__main__':
    main()
