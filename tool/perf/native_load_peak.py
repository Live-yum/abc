#!/usr/bin/env python3
"""Linux load-only sampler for the pinned public Computerraria WLD.

Only the directly spawned native_load_only child is inspected. No process
enumeration, cgroup reads, cache dropping, system changes, or uploads occur.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

STATUS_FIELDS = ('VmRSS', 'VmHWM', 'RssAnon', 'RssFile', 'RssShmem', 'VmSize')
ROLLUP_FIELDS = ('Rss', 'Pss', 'Pss_Anon', 'Pss_File', 'Pss_Shmem',
                 'Shared_Clean', 'Shared_Dirty', 'Private_Clean',
                 'Private_Dirty', 'Swap', 'SwapPss')
INPUTS = {
    'computerraria.wld': (405983441, '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'),
}
CAVEATS = [
    'Standalone C host and streamed native engine, not Dart/Flutter UI memory.',
    'Fresh process; OS page cache is uncontrolled and is not cleared.',
    'RSS and PSS/USS samples can miss short transients; PSS/USS peaks are lower bounds.',
    'ru_maxrss and observed VmHWM are retained separately; the larger recorded value is the conservative recorded RSS peak.',
    'Early ru_maxrss may include pre-exec launcher accounting; it is not current baseline RSS.',
    'PSS divides shared pages. USS is Private_Clean plus Private_Dirty; shared RSS is not unique ownership.',
    'Circuit allocation counters exclude host, decoder, library, allocator and mapped-page overhead; the 192 MiB circuit budget is not an RSS limit.',
    'Unavailable circuit counters before creation and after close are null, not proof of zero outstanding engine allocations.',
    'Engine phases are observed after bounded calls; a call can cross a phase boundary before it is reported.',
    'Only the physical 64x48 monochrome display is read and decoded to a C RGBA buffer; there are no Flutter textures, raster frames, CPU clock pulses, Pong or exports.',
]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def parse_kb(path, wanted):
    values = {}
    for line in path.read_text().splitlines():
        key, _, rest = line.partition(':')
        if key in wanted:
            values[key + '_bytes'] = int(rest.split()[0]) * 1024
    return values


def maximum(rows, key):
    eligible = [row for row in rows if key in row]
    return max(eligible, key=lambda row: row[key]) if eligible else None


def summarize(metadata, events, samples):
    """Pure reduction also usable to inspect retained raw evidence offline."""
    phases = [event for event in events if event.get('event') == 'phase']
    identities = [event for event in events if event.get('event') == 'identity']
    hashes = {event['name']: (event['bytes'], event['sha256'])
              for event in events if event.get('event') == 'source_hash'}
    loaded = next((phase for phase in phases if phase['phase'] == 'loaded'), None)
    closed = any(phase['phase'] == 'closed' for phase in phases)
    identity_ok = (len(identities) == 1 and
                   identities[0].get('pid') == metadata['pid'] and
                   identities[0].get('circuit_world_abi_version') == 2 and
                   identities[0].get('load_scope') == 'wld-only-mono64x48')
    displays = [event for event in events if event.get('event') == 'display']
    display_ok = displays == [{
        'event': 'display', 'name': 'mono', 'x': 6485, 'y': 800,
        'width': 64, 'height': 48, 'records': 3072, 'rgba_bytes': 12288,
    }]
    stats = loaded.get('stats', []) if loaded else []
    stats_ok = (len(stats) == 24 and stats[0] == 2 and
                stats[2:4] == [15200, 7200] and stats[14] == 15200 and
                stats[18] == 0 and stats[20] == 0)
    metadata['valid'] = bool(metadata['exit_code'] == 0 and identity_ok and
                             display_ok and stats_ok and loaded and closed and hashes == INPUTS and
                             not metadata.get('timeout_seconds'))
    for row in samples:
        preceding = [phase for phase in phases
                     if phase['monotonic_seconds'] <= row['monotonic_seconds']]
        row['phase'] = preceding[-1]['phase'] if preceding else 'startup'
    if loaded:
        rows = [row for row in samples
                if row['monotonic_seconds'] <= loaded['monotonic_seconds']]
        rss = maximum(rows, 'VmRSS_bytes')
        hwm = maximum(rows, 'VmHWM_bytes')
        if rss is None:
            metadata['valid'] = False
        metadata['loading'] = {
            'sampled_peak': rss,
            'peak_pss_sample': maximum(rows, 'Pss_bytes'),
            'peak_uss_sample': maximum(rows, 'USS_bytes'),
            'ru_maxrss_bytes': loaded['ru_maxrss_bytes'],
            'observed_vmhwm_bytes': hwm['VmHWM_bytes'] if hwm else None,
            'conservative_recorded_peak_rss_bytes': max(
                loaded['ru_maxrss_bytes'], hwm['VmHWM_bytes'] if hwm else 0),
            'engine_active_loaded_bytes': loaded['engine_active_bytes'],
            'engine_peak_bytes': loaded['engine_peak_bytes'],
            'load_seconds': loaded['elapsed_seconds'],
            'sample_count': len(rows),
            'rollup_count': sum('Pss_bytes' in row for row in rows),
            'max_sampling_gap_seconds': max(
                (b['monotonic_seconds'] - a['monotonic_seconds']
                 for a, b in zip(rows, rows[1:])), default=None),
        }
    metadata['phase_summary'] = []
    for index, phase in enumerate(phases):
        end = phases[index + 1]['monotonic_seconds'] if index + 1 < len(phases) else None
        rows = [row for row in samples if
                phase['monotonic_seconds'] <= row['monotonic_seconds'] and
                (end is None or row['monotonic_seconds'] < end)]
        peaks = {key: maximum(rows, key) for key in ('VmRSS_bytes', 'Pss_bytes', 'USS_bytes')}
        metadata['phase_summary'].append({
            **phase, 'duration_seconds': end - phase['monotonic_seconds'] if end else None,
            'sample_count': len(rows),
            'sampled_peaks_bytes': {key: row[key] if row else None for key, row in peaks.items()},
        })
    metadata['events'] = events
    metadata['caveats'] = CAVEATS
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('host', 'library', 'wld', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--rss-ms', type=float, default=10)
    parser.add_argument('--detail-ms', type=float, default=100)
    parser.add_argument('--timeout', type=float, default=180)
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Linux is required for the documented RSS and /proc units.')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', args.run_id):
        parser.error('--run-id must be a short label of letters, digits, dots, dashes or underscores.')
    if not (1 <= args.rss_ms <= 1000 and args.rss_ms <= args.detail_ms <= 10000
            and 1 <= args.timeout <= 1200):
        parser.error('Use rss-ms 1..1000, detail-ms rss-ms..10000, timeout 1..1200 seconds.')
    for name in ('host', 'library', 'wld'):
        path = getattr(args, name).resolve()
        if not path.is_file():
            parser.error(f'--{name} must identify a readable regular file.')
        setattr(args, name, path)
    if not os.access(args.host, os.X_OK):
        parser.error('--host must be executable.')
    if args.library.name != 'libabc_engine.so':
        parser.error('--library must identify libabc_engine.so.')
    if args.wld.stat().st_size != INPUTS['computerraria.wld'][0]:
        parser.error('Input size does not match the pinned complete public WLD.')
    output = args.output.resolve()
    if output.exists():
        parser.error('--output must be a new directory; existing evidence is never overwritten.')
    output.mkdir(parents=True, exist_ok=False)
    metadata = {
        'schema': 'abc.standaloneNativeLoad.v2', 'measurement_kind': 'standaloneNativeLoad',
        'load_scope': 'wld-only-mono64x48', 'circuit_world_abi_version': 2,
        'run_id': args.run_id, 'runtime': 'standalone C host / streamed Native C engine',
        'cold_process': True, 'os_page_cache_dropped': False,
        'rss_interval_seconds': args.rss_ms / 1000,
        'smaps_rollup_interval_seconds': args.detail_ms / 1000,
        'library_sha256': sha256(args.library), 'host_sha256': sha256(args.host),
        'sampler_source_sha256': sha256(Path(__file__).resolve()),
        'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'kernel': os.uname().release, 'machine': os.uname().machine,
        'inputs': {name: {'bytes': value[0], 'sha256': value[1]} for name, value in INPUTS.items()},
    }
    # Paths are launch inputs only; no command line or machine path is serialized.
    command = [str(args.host), str(args.wld),
               str(output / 'scratch.bin'), str(args.library)]
    environment = os.environ.copy()
    environment['LD_LIBRARY_PATH'] = str(args.library.parent) + (
        ':' + environment['LD_LIBRARY_PATH'] if environment.get('LD_LIBRARY_PATH') else '')
    samples, unavailable = [], set()
    with (output / 'events.jsonl').open('w') as stdout, (output / 'stderr.txt').open('w') as stderr:
        child = subprocess.Popen(command, env=environment, stdout=stdout, stderr=stderr)
        metadata['pid'] = child.pid
        proc = Path('/proc') / str(child.pid)
        started, next_rollup = time.monotonic(), 0
        try:
            while child.poll() is None:
                tick = time.monotonic()
                row = {'monotonic_seconds': tick, 'elapsed_supervisor_seconds': tick - started}
                try:
                    row.update(parse_kb(proc / 'status', STATUS_FIELDS))
                except (FileNotFoundError, ProcessLookupError):
                    break
                except PermissionError:
                    unavailable.add('status permission denied')
                    child.terminate()
                    break
                if tick >= next_rollup:
                    try:
                        row.update(parse_kb(proc / 'smaps_rollup', ROLLUP_FIELDS))
                        if 'Private_Clean_bytes' in row and 'Private_Dirty_bytes' in row:
                            row['USS_bytes'] = row['Private_Clean_bytes'] + row['Private_Dirty_bytes']
                        if 'Shared_Clean_bytes' in row and 'Shared_Dirty_bytes' in row:
                            row['Shared_bytes'] = row['Shared_Clean_bytes'] + row['Shared_Dirty_bytes']
                    except (FileNotFoundError, ProcessLookupError, PermissionError):
                        unavailable.add('smaps_rollup unavailable')
                    next_rollup = tick + args.detail_ms / 1000
                samples.append(row)
                if time.monotonic() - started > args.timeout:
                    metadata['timeout_seconds'] = args.timeout
                    child.terminate()
                    break
                time.sleep(max(0, args.rss_ms / 1000 - (time.monotonic() - tick)))
            try:
                metadata['exit_code'] = child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                metadata['timeout_seconds'] = args.timeout
                child.kill()
                metadata['exit_code'] = child.wait()
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
    metadata['unavailable'] = sorted(unavailable)
    events = []
    for line in (output / 'events.jsonl').read_text().splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            metadata['malformed_event'] = True
    report = summarize(metadata, events, samples)
    if metadata.get('malformed_event') or 'status permission denied' in unavailable:
        report['valid'] = False
    keys = sorted(set().union(*(row.keys() for row in samples)))
    with (output / 'samples.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=keys)
        writer.writeheader()
        writer.writerows(samples)
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report.get(key) for key in
                      ('measurement_kind', 'run_id', 'valid', 'exit_code', 'loading')}))
    return 0 if report['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
