#!/usr/bin/env python3
"""Fetch only the pinned public MIT Computerraria WLD for opt-in validation.

Inputs are not packaged with the application or uploaded as CI artifacts.
Existing files with unexpected bytes are never overwritten. Extraction is
streamed and accepts exactly one bounded regular WLD member.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tarfile
import tempfile
import urllib.request

REVISION = '0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8'
BASE = f'https://raw.githubusercontent.com/misprit7/computerraria/{REVISION}/'
ARCHIVE = {'name': 'computerraria.tar.gz', 'bytes': 2871121,
           'sha256': '31423b4f7ebbecceeaa54f982f02980efa5b8edccede5456456d892b0452ea1a'}
WORLD = {'name': 'computerraria.wld', 'bytes': 405983441,
         'sha256': '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'}
CHUNK = 1024 * 1024


def verified(path, spec):
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f'Refusing symbolic-link input: {path.name}')
    if not path.exists():
        return False
    if not path.is_file() or path.stat().st_size != spec['bytes']:
        raise ValueError(f'Refusing to replace unexpected existing input: {path.name}')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(CHUNK), b''):
            digest.update(block)
    if digest.hexdigest() != spec['sha256']:
        raise ValueError(f'Existing input digest mismatch: {path.name}')
    return True


def copy_verified(stream, output, spec):
    digest, total = hashlib.sha256(), 0
    while True:
        block = stream.read(min(CHUNK, spec['bytes'] - total + 1))
        if not block:
            break
        total += len(block)
        if total > spec['bytes']:
            raise ValueError(f'Input exceeds pinned length: {spec["name"]}')
        output.write(block)
        digest.update(block)
    if total != spec['bytes'] or digest.hexdigest() != spec['sha256']:
        raise ValueError(f'Pinned input length/digest mismatch: {spec["name"]}')


def install_verified(temporary, target, spec):
    # Same-directory hard-link creation is atomic and never replaces an entry.
    # The caller removes only its own temporary name after installation.
    try:
        os.link(temporary, target)
    except FileExistsError:
        if not verified(target, spec):
            raise ValueError('Input destination changed during installation')


def fetch(directory, spec, opener=urllib.request.urlopen):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / spec['name']
    if verified(target, spec):
        return target
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix='.input-', delete=False) as output:
            temporary = Path(output.name)
            with opener(BASE + spec['name'], timeout=60) as stream:
                copy_verified(stream, output, spec)
        install_verified(temporary, target, spec)
        return target
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def extract_world(archive, directory, spec=WORLD):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / spec['name']
    if verified(target, spec):
        return target
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix='.world-', delete=False) as output:
            temporary = Path(output.name)
            count = 0
            with tarfile.open(archive, mode='r|gz') as entries:
                for member in entries:
                    count += 1
                    if (count != 1 or member.name not in (spec['name'], './' + spec['name'])
                            or not member.isfile() or member.size != spec['bytes']
                            or member.sparse is not None):
                        raise ValueError('Archive must contain exactly the pinned regular WLD')
                    with entries.extractfile(member) as stream:
                        copy_verified(stream, output, spec)
            if count != 1:
                raise ValueError('Archive has no pinned WLD')
        install_verified(temporary, target, spec)
        return target
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('build/public-computerraria'))
    parser.add_argument('--local-archive', type=Path, help='Already retrieved original archive; still hash verified')
    args = parser.parse_args()
    archive = args.local_archive or fetch(args.output, ARCHIVE)
    if not verified(archive, ARCHIVE):
        raise ValueError('Local archive is missing')
    world = extract_world(archive, args.output)
    assert verified(world, WORLD)
    report = {'schema': 'abc.public-computerraria-inputs.v2', 'status': 'verified',
              'sourceRevision': REVISION, 'source': BASE, 'license': 'MIT',
              'copyright': '2023 Xander Naumenko', 'inputs': [ARCHIVE, WORLD],
              'world': {'format': 279, 'width': 15200, 'height': 7200},
              'privacy': 'Pinned public upstream fixture; no user saves. Do not upload the input files as artifacts.'}
    (args.output / 'input-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': 'verified', 'revision': REVISION,
                      'worldBytes': WORLD['bytes']}))


if __name__ == '__main__':
    main()
