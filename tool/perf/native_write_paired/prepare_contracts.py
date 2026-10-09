#!/usr/bin/env python3
"""Prepare a separate full candidate checkout and prove Flutter resolves it."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urljoin, urlparse

import paired

HERE = Path(__file__).resolve().parent
TESTS = ['native_world_circuit_write_fixture.c', 'native_world_circuit_write_test.dart',
         'native_world_circuit_write_owner_test.dart']


def materialize(baseline, output):
    baseline, output = Path(baseline).resolve(), Path(output).resolve()
    paired.verify_fixed_product_sources(baseline)
    if output.exists():
        raise ValueError('Contract candidate directory must be new')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(baseline), *args]).decode().strip()
    if git('rev-parse', 'HEAD') != paired.BASE_COMMIT or git('rev-parse', 'HEAD^{tree}') != paired.BASE_TREE:
        raise ValueError('Contract source commit/tree mismatch')
    paths = subprocess.check_output(['git', '-C', str(baseline), 'ls-files', '-z']).decode().rstrip('\0').split('\0')
    if len(paths) != 828:
        raise ValueError('Fixed product tracked file count mismatch')
    before = {}
    for name in paths:
        source = baseline / name
        if source.is_symlink() or not source.resolve().is_relative_to(baseline):
            raise ValueError('Contract source contains unexpected link/path')
        before[name] = paired.digest(source)
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    manifest = paired.load_json(HERE / 'source-manifest.json')
    if before[paired.BINDING] != paired.BASE_SHA:
        raise ValueError('Contract baseline binding mismatch')
    shutil.copyfile(HERE / 'candidate_binding.dart.txt', output / paired.BINDING)
    for name in TESTS:
        source = HERE / 'contracts' / (name + '.txt')
        if paired.digest(source) != manifest['contractFixtureSha256'][name]:
            raise ValueError('Contract fixture hash mismatch')
        shutil.copyfile(source, output / 'test' / name)
    if paired.digest(output / paired.BINDING) != paired.CANDIDATE_SHA:
        raise ValueError('Contract candidate binding mismatch')
    for name in paths:
        if paired.digest(baseline / name) != before[name]:
            raise ValueError('Read-only product checkout was modified')
        if name != paired.BINDING and paired.digest(output / name) != before[name]:
            raise ValueError('Unexpected copied product difference')
    record = {'status': 'prepared', 'sourceCommit': paired.BASE_COMMIT, 'sourceTree': paired.BASE_TREE,
              'productFiles': 828, 'baselineFilesSha256': before,
              'candidateBindingSha256': paired.CANDIDATE_SHA,
              'contractFilesSha256': manifest['contractFixtureSha256'],
              'materialization': 'tracked source only; no baseline .dart_tool or package_config copied'}
    paired.write_json(output.parent / 'contracts-provenance.json', record)
    return record


def verify_package(output):
    output = Path(output).resolve()
    config_path = output / '.dart_tool/package_config.json'
    packages = paired.load_json(config_path)['packages']
    own = [p for p in packages if p['name'] == 'terraforge']
    if len(own) != 1:
        raise ValueError('One terraforge package required')
    uri = urljoin(config_path.as_uri(), own[0]['rootUri'])
    if urlparse(uri).scheme != 'file':
        raise ValueError('Candidate package root must be local')
    resolved = Path(unquote(urlparse(uri).path)).resolve()
    if resolved != output or own[0].get('packageUri') != 'lib/':
        raise ValueError('terraforge resolves outside the candidate root')
    if paired.digest(resolved / paired.BINDING) != paired.CANDIDATE_SHA:
        raise ValueError('Resolved binding is not the reviewed WRITE candidate')
    fixture_manifest = paired.load_json(HERE / 'source-manifest.json')['contractFixtureSha256']
    for name in TESTS:
        if paired.digest(output / 'test' / name) != fixture_manifest[name]:
            raise ValueError('Materialized contract source changed')
    record_path = output.parent / 'contracts-provenance.json'
    record = paired.load_json(record_path)
    record.update(status='package-resolution-verified', packageRoot=str(resolved),
                  packageConfig=paired.pin(config_path), resolvedBinding=paired.pin(resolved / paired.BINDING))
    paired.write_json(record_path, record)
    return record


def verify_results(path):
    events = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    done = [e for e in events if e.get('type') == 'done']
    completed = [e for e in events if e.get('type') == 'testDone' and not e.get('hidden', False)]
    if len(done) != 1 or done[0].get('success') is not True:
        raise ValueError('Contract suite did not finish successfully')
    if len(completed) != 20 or any(e.get('result') != 'success' or e.get('skipped') for e in completed):
        raise ValueError('Exactly 20 successful, unskipped new contracts required')
    return {'status': 'passed', 'successfulTests': len(completed), 'rawLog': paired.pin(path)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['materialize', 'verify-package', 'verify-results'])
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'materialize':
        if args.baseline is None:
            parser.error('materialize needs --baseline')
        result = materialize(args.baseline, args.output)
    elif args.action == 'verify-package':
        result = verify_package(args.output)
    else:
        result = verify_results(args.output)
    print(json.dumps({'status': result['status']}))
