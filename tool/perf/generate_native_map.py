#!/usr/bin/env python3
"""Generate actual MAP fixtures through the shipped C facade; keep saves local."""
import argparse
import ctypes as C
import hashlib
import json
import math
from pathlib import Path
import resource
import os
import platform
import subprocess
import statistics
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', required=True)
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--iterations', type=int, default=3)
    parser.add_argument('--fixture-id', default='private-world-1')
    parser.add_argument('--provenance', default='authorized-local-input')
    args = parser.parse_args()
    if args.iterations < 2 or args.iterations > 100:
        parser.error('iterations must be 2–100')
    def command(*words):
        result = subprocess.run(words, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    commit = command('git', 'rev-parse', 'HEAD')
    dirty = command('git', 'status', '--porcelain', '--untracked-files=normal')
    revision = dict(commit=os.getenv('ABC_PERF_COMMIT') or os.getenv('GITHUB_SHA') or commit or 'unknown',
        worktreeCommit=commit or 'unknown', dirty='unknown' if dirty is None else bool(dirty),
        commitSource='ABC_PERF_COMMIT' if os.getenv('ABC_PERF_COMMIT') else 'GITHUB_SHA' if os.getenv('GITHUB_SHA') else 'git' if commit else 'unknown')
    source_path = Path(args.input)
    source = source_path.read_bytes()
    source_hash = hashlib.sha256(source).digest()
    lib = C.CDLL(args.library)
    u, p, up = C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32)
    lib.abc_world_open.argtypes = [p, u, up]
    lib.abc_world_close.argtypes = [u]
    lib.abc_world_operation.argtypes = [u, C.c_char_p, C.c_char_p, p, u, up]
    lib.abc_world_map.argtypes = [u, p, u, up, up, up]
    lib.abc_world_save.argtypes = [u, p, u, up]
    lib.abc_error.argtypes = [p, u, up]

    def check(status):
        if status:
            out, required = C.create_string_buffer(8192), u()
            lib.abc_error(out, len(out), C.byref(required))
            raise RuntimeError(f'Native MAP status {status}: {out.value.decode(errors="replace")}')

    def read(function, *prefix):
        required = u()
        check(function(*prefix, None, 0, C.byref(required)))
        if not 0 < required.value <= 128 * 1024 * 1024:
            raise RuntimeError('Native MAP output exceeds contract')
        result = C.create_string_buffer(required.value)
        check(function(*prefix, result, len(result), C.byref(required)))
        return result.raw[:required.value]

    def generate(handle, marked):
        op = b'mark_tiles_and_chests_map' if marked else b'render_lit_map'
        request = b'{"tile_markers":[{"tile_type":1,"color":"#ff00ff","radius":2}]}' if marked else b'{}'
        read(lib.abc_world_operation, handle, op, request)
        size, width, height = u(), u(), u()
        check(lib.abc_world_map(handle, None, 0, C.byref(size), C.byref(width), C.byref(height)))
        if not 4 < size.value <= 128 * 1024 * 1024:
            raise RuntimeError('MAP result has invalid size')
        out = C.create_string_buffer(size.value)
        check(lib.abc_world_map(handle, out, len(out), C.byref(size), C.byref(width), C.byref(height)))
        data = out.raw[:size.value]
        if int.from_bytes(data[:4], 'little') != 33083 or data[4:12] != b'relogic\x01':
            raise RuntimeError('Engine result is not binary MAP')
        return data

    samples = {key: [] for key in ['map.generate_lit', 'map.generate_marked']}
    memory = []
    output = None
    for cycle in range(args.iterations):
        handle = u()
        check(lib.abc_world_open(source, len(source), C.byref(handle)))
        try:
            for key, marked in [('map.generate_lit', False), ('map.generate_marked', True)]:
                start = time.perf_counter_ns()
                result = generate(handle.value, marked)
                samples[key].append((time.perf_counter_ns() - start) / 1e6)
                if not marked:
                    output = result
            if read(lib.abc_world_save, handle.value) != source:
                raise RuntimeError('MAP generation changed WLD bytes')
        finally:
            check(lib.abc_world_close(handle.value))
        # Linux current RSS; maxrss is a peak and must not be presented as live.
        rss = int(Path('/proc/self/statm').read_text().split()[1]) * resource.getpagesize()
        memory.append(dict(cycle=cycle, phase='after-close', rssBytes=rss,
                           heapUsedBytes=None, heapCapacityBytes=None,
                           wasmCapacityBytes=None, ownedHandles=0))
    if hashlib.sha256(source_path.read_bytes()).digest() != source_hash:
        raise RuntimeError('Input file changed')
    destination = Path(args.output)
    if destination.resolve() == source_path.resolve():
        raise RuntimeError('Output must differ from source')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(output)
    operations = []
    for key, values in samples.items():
        for phase, phase_values in [('cold', values[:1]), ('warm', values[1:])]:
            sorted_values = sorted(phase_values)
            operations.append(dict(id=key, fixture=args.fixture_id, phase=phase,
                iterations=len(phase_values), warmup=0, unit='ms', samplesMs=phase_values,
                medianMs=statistics.median(phase_values), p95Ms=sorted_values[math.ceil(len(sorted_values)*.95)-1],
                maxMs=max(phase_values), throughputPerSecond=1000/statistics.median(phase_values),
                bytesPerOperation=len(source)))
    report = dict(schema='abc.performance.v1', suite='native-map-generation',
        runtime='linux-native-c', buildMode='release', tier=os.getenv('ABC_PERF_TIER', 'local'), workload='generated-from-authorized-world', source=revision,
        methodology=dict(cold='First invocation; OS caches are not flushed.', warmupCycles=0, measuredCycles=args.iterations-1, totalCycles=args.iterations),
        toolchain=dict(python=platform.python_version(), nativeLibrarySha256=hashlib.sha256(Path(args.library).read_bytes()).hexdigest()),
        fixtures=[dict(id=args.fixture_id, kind='wld', provenance=args.provenance, bytes=len(source), sha256=source_hash.hex()),
                  dict(id='generated-map-1', kind='map', provenance='engine-generated-from-authorized-world', bytes=len(output), sha256=hashlib.sha256(output).hexdigest())],
        operations=operations, memory=memory,
        sourcePreserved=True, status='passed',
        gaps=['Generated fully explored MAP is not a personal exploration MAP.',
              'Current process RSS includes Python retained input/output and allocator state.',
              'No Android/iOS/macOS device or UI frame timing measured here.'])
    Path(args.report).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': 'passed', 'mapBytes': len(output), 'operations': len(operations), 'sourcePreserved': True}))


if __name__ == '__main__':
    main()
