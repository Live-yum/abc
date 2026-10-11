#!/usr/bin/env python3
"""Bounded CMake/OFF-identity/ABI gates, never a full-world workload."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from memory_ownership_preflight import ROOT, digest, write
from memory_ownership_helper_build import build as build_helper


def run(argv, output, name, expected=0):
    result = subprocess.run([str(x) for x in argv], cwd=ROOT, capture_output=True, timeout=240)
    (output / (name + '.log')).write_bytes(result.stdout + result.stderr)
    if (result.returncode == 0) != (expected == 0):
        raise ValueError('Native gate failed: ' + name)
    return result


def exports(library):
    result = subprocess.check_output(['nm', '-D', '--defined-only', str(library)], text=True, timeout=30)
    return sorted(line.split()[-1] for line in result.splitlines() if line.split())


def prepare(base, output):
    output.mkdir(parents=True, exist_ok=False)
    rows = {}
    for arm, source in (('base', base), ('derived', ROOT)):
        build = ROOT / 'build' / ('memory-owner-off-' + arm)
        run(['cmake', '-S', source / 'native', '-B', build, '-DCMAKE_BUILD_TYPE=Release',
             '-DABC_PERF_COUNTERS=OFF', '-DABC_OWNER_DIAGNOSTICS=OFF'], output, arm + '-configure')
        run(['cmake', '--build', build, '--parallel', '2'], output, arm + '-build')
        library = build / 'libabc_engine.so'
        symbols = exports(library)
        if any(name.startswith(('abc_owner_', 'abc_perf_')) for name in symbols):
            raise ValueError('Diagnostic exports leaked into OFF build')
        objects = list(build.rglob('terra_circuit_world.c.o'))
        if len(objects) != 1:
            raise ValueError('Ambiguous OFF circuit object')
        text = output / (arm + '-circuit-text.bin')
        run(['objcopy', '--dump-section', '.text=' + str(text), objects[0]], output, arm + '-text')
        rows[arm] = {'symbols': symbols, 'circuitTextSha256': digest(text), 'librarySha256': digest(library)}
    if rows['base']['symbols'] != rows['derived']['symbols'] or rows['base']['circuitTextSha256'] != rows['derived']['circuitTextSha256']:
        raise ValueError('OFF exports or guarded circuit machine code differ')
    invalid = run(['cmake', '-S', 'native', '-B', 'build/memory-owner-invalid',
                   '-DABC_PERF_COUNTERS=OFF', '-DABC_OWNER_DIAGNOSTICS=ON'], output, 'invalid-flags', expected=1)
    if b'ABC_OWNER_DIAGNOSTICS requires explicit ABC_PERF_COUNTERS=ON' not in invalid.stdout + invalid.stderr:
        raise ValueError('Invalid CMake flags failed for an unrelated reason')
    helper_directory = Path(os.environ['RUNNER_TEMP']).resolve() / 'memory-owner-helper'
    helper_evidence = output / 'helper-build'
    helper_evidence.mkdir()
    try:
        helper_build = build_helper(ROOT, helper_directory)
    finally:
        if helper_directory.is_dir():
            for item in helper_directory.iterdir():
                if item.suffix in ('.json', '.txt', '.c', '.d'):
                    shutil.copyfile(item, helper_evidence / item.name)
    helper = helper_directory / 'libabc_native_owner_libc.so'
    cc = ['cc', '-std=c17', '-O2', '-Wall', '-Wextra', '-Werror']
    variants = {
        'stub': ['-DABC_OWNER_DIAGNOSTICS=1', '-DABC_OWNER_STUB_CONTRACT=1', '-Inative',
                 'native/owner_diagnostic_contract.c', 'native/abc_owner_diagnostics.c'],
        'libc': ['-DABC_OWNER_LIBC_CONTRACT=1', 'native/owner_diagnostic_contract.c', helper],
        'unsupported': ['-DABC_OWNER_LIBC_CONTRACT=1', '-DABC_RETENTION_DISABLE_MALLINFO2=1',
                        'native/owner_diagnostic_contract.c', 'tool/perf/native_owner_libc_probe.c', '-ldl', '-pthread'],
    }
    for name, args in variants.items():
        binary = output / ('owner-' + name + '-contract')
        run([*cc, *args, '-o', binary], output, name + '-compile')
        run([binary], output, name + '-contract')
    write(output / 'native-contracts.json', {'schema': 'abc.memory-ownership-native-contracts.v1',
          'offBuilds': rows, 'ownerWithoutCountersRejected': True,
          'contracts': ['stub', 'libc', 'unsupported'], 'helperSha256': digest(helper),
          'helperBuildSha256': digest(helper_directory / 'helper-build.json'),
          'helperBuild': helper_build,
          'largeWorldMeasured': False, 'sanitizersExecuted': False})


def profile(bundle, output):
    library = bundle / 'lib'
    binary = output / 'owner-real-contract'
    run(['cc', '-std=c17', '-O2', '-Wall', '-Wextra', '-Werror', '-Inative',
         'native/owner_diagnostic_contract.c', '-L' + str(library), '-labc_engine',
         '-Wl,-rpath,' + str(library), '-o', binary], output, 'profile-contract-compile')
    run([binary, 'assets/qa/synthetic-circuit.wld'], output, 'profile-contract')
    symbols = exports(library / 'libabc_engine.so')
    if ('cx_owner_diagnostics_counts' in symbols or
            sorted(s for s in symbols if s.startswith('abc_owner_')) !=
            ['abc_owner_diagnostics_abi_version', 'abc_owner_diagnostics_snapshot_v1']):
        raise ValueError('Owner diagnostic exports are not the exact intended pair')
    write(output / 'profile-native-contract.json', {'status': 'passed', 'fixtureBytes': 864,
          'librarySha256': digest(library / 'libabc_engine.so'), 'symbols': symbols})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('prepare', 'profile'))
    parser.add_argument('--base-root', type=Path)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.mode == 'prepare':
        prepare(args.base_root.resolve(), args.output.resolve())
    else:
        profile(args.bundle.resolve(), args.output.resolve())


if __name__ == '__main__':
    main()
