#!/usr/bin/env python3
"""Record the exact committed source and built artifacts for public-world CI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def cmake_settings(path):
    result = {}
    for line in path.read_text().splitlines():
        if line.startswith(('CMAKE_BUILD_TYPE:', 'CMAKE_C_FLAGS:', 'CMAKE_C_FLAGS_RELEASE:',
                            'CMAKE_C_FLAGS_PROFILE:', 'CMAKE_C_COMPILER:', 'CMAKE_GENERATOR:',
                            'ABC_PERF_COUNTERS:')):
            key, value = line.split('=', 1)
            result[key.split(':', 1)[0]] = value
    if not result.get('CMAKE_BUILD_TYPE'):
        raise ValueError('CMake cache does not identify the actual build configuration')
    return result


def ninja_flags(path):
    # Record actual generated target flags, not just a requested configuration.
    wanted = ('abc_world_circuit.c.o', 'terra_circuit_world.c.o', 'terra_circuit_vm.c.o')
    result, current = {}, None
    for line in path.read_text().splitlines():
        if line.startswith('build '):
            current = next((name for name in wanted if (name + ':') in line), None)
        elif current and line.startswith('  FLAGS = '):
            result[current] = line[len('  FLAGS = '):]
            current = None
    if set(result) != set(wanted):
        raise ValueError('Missing actual wiring VM compiler flags in Ninja build')
    return result


def record(artifacts, output, cmake_cache, ninja_build=None):
    head = git('rev-parse', '--verify', 'HEAD')
    expected = os.environ.get('ABC_PERF_COMMIT', head)
    dirty = bool(git('status', '--porcelain', '--untracked-files=normal'))
    if head != expected or dirty:
        raise ValueError('Acceptance build requires the requested clean committed snapshot')
    paths = git('ls-files', '--', 'native', 'lib', 'linux', 'integration_test',
                'test_driver', 'test/web', 'tool', 'assets/computer',
                'pubspec.lock', '.flutter-version').splitlines()
    source_files = {path: digest(path) for path in sorted(paths)}
    result = {
        'schema': 'abc.computerraria.build.v1',
        'source': {'commit': expected, 'checkedOutHead': head, 'dirty': dirty},
        'sourceFilesSha256': source_files,
        'sourceTreeSha256': hashlib.sha256(json.dumps(
            source_files, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
        'cmake': cmake_settings(cmake_cache),
        'artifacts': {Path(path).name: {'sha256': digest(path),
                                      'bytes': Path(path).stat().st_size}
                      for path in artifacts},
    }
    if ninja_build:
        result['effectiveCompileFlags'] = ninja_flags(ninja_build)
    if not source_files or len(result['artifacts']) != len(artifacts):
        raise ValueError('Source records must exist and artifact basenames must be unique')
    output.parent.mkdir(parents=True, exist_ok=True)
    # Independent attempts must never silently replace their provenance.
    with output.open('x') as destination:
        destination.write(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', action='append', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cmake-cache', type=Path, required=True)
    parser.add_argument('--ninja-build', type=Path)
    options = parser.parse_args()
    record(options.artifact, options.output, options.cmake_cache, options.ninja_build)
