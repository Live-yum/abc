#!/usr/bin/env python3
"""One fresh Chrome process, public File fixture, unmodified official Web build.

No Flutter build, browser installation, security changes, external browser or
user profile. Only the browser process launched here and its descendants are
sampled. Missing process evidence is null/inconclusive, never an invented zero.
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import signal
import shlex
import subprocess
import tarfile
import tempfile
import threading
import time
import zipfile


ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'build/browser-load-diagnostic'
EVIDENCE = BASE / 'evidence'
WEB = BASE / 'web'
CYCLE_BASE = ROOT / 'build/browser-cycle-diagnostic'
CYCLE_COUNT = 3
CYCLE_GLOBAL_SECONDS = 3300
CYCLE_CLEANUP_RESERVE_SECONDS = 30
CYCLE_DRIVER_SOFT_SECONDS = 3240
CYCLE_POLL_SECONDS = 0.5
CYCLE_MAX_RSS_BYTES = 6 * 1024 ** 3
CYCLE_MAX_EVIDENCE_BYTES = 512 * 1024 ** 2
CYCLE_SAMPLE_BYTES = 256 * 1024 ** 2
CYCLE_LOG_BYTES = 16 * 1024 ** 2
CYCLE_AFTER_CLOSE_MS = 20000
CYCLE_STAGES = (
    'baseline-start', 'load-start', 'ready', 'optimization-start', 'program-start',
    'boot-start', 'pong-ready', 'input-start', 'input-complete', 'live-start',
    'pause-start', 'paused', 'pause-verified', 'reset-start', 'reset-ready',
    'close-start', 'close-complete', 'release-complete',
)
WORLD_SIZE = 405983441
WORLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
CHROME = Path('/opt/google/chrome/chrome')
WEB_RUN = '37920825904'
WEB_COMMIT = 'cddd936f95d31b14a76503e13ffc89173110a057'
WEB_ARTIFACT_ID = 11611983230
WEB_ZIP = {'bytes': 22366110,
           'sha256': 'fa7e9e4575109f388cae6533193bd96bf6b15d42bd767130d5de03c811ba8a92'}
WEB_HASHES = {
    'main.dart.js': '35ca45df21710b3463cb51866b0ede28ef9eea449fb0310c82889de26625277e',
    'engine/world.wasm': 'a9af2ce7aed0b4304c21f59e4500fd9116221588840e39af1e453459d8bf4a08',
    'engine/world.js': '50bb9a182ac1c596d5c67b84ced4d77c69a29d6bf41a4346807d46920962b47d',
}


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def describe(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return {'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}


def command(args):
    return subprocess.check_output(args, text=True, timeout=120).strip()


def diagnostic_changed(paths):
    return any(path in ('.github/workflows/browser-load-diagnostic.yml',
                        'tool/perf/BROWSER_LOAD_DIAGNOSTIC.md',
                        'tool/perf/BROWSER_CYCLE_DIAGNOSTIC.md')
               or (path.startswith('tool/perf/browser_load_') and path.count('/') == 2)
               for path in paths)


def scope_for_event(name, event, dispatch_head, check_commit, changed_paths):
    def commit(value):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value):
            raise ValueError('Event scope requires exact 40-character lowercase commit SHAs')
        if not check_commit(value):
            raise ValueError(f'Event scope commit is unavailable: {value}')
        return value

    if name == 'workflow_dispatch':
        return {'run': True, 'reason': 'explicit-dispatch-one-attempt',
                'head': commit(dispatch_head), 'before': None}
    if name == 'push':
        if (event.get('ref') != 'refs/heads/codex/diagnostic-browser-cycles'
                or event.get('deleted') is True):
            raise ValueError('Only a non-deleted exact diagnostic-cycle branch push is authorized')
        head = commit(event.get('after'))
        if dispatch_head is not None and commit(dispatch_head) != head:
            raise ValueError('Push event head does not match the execution commit')
        if event.get('before') == '0' * 40:
            return {'run': True, 'reason': 'diagnostic-cycle-branch-created-one-attempt',
                    'head': head, 'before': None}
        before = commit(event.get('before'))
        enabled = diagnostic_changed(changed_paths(before, head))
        return {'run': enabled, 'reason': 'diagnostic-files-changed' if enabled
                else 'unrelated-event-diff-no-measurement', 'before': before, 'head': head}
    if name != 'pull_request' or event.get('action') not in ('opened', 'synchronize'):
        raise ValueError('Unsupported event: no browser measurement authorized by this workflow')
    request = event.get('pull_request', {})
    head = commit(request.get('head', {}).get('sha'))
    before = commit(event.get('before') if event['action'] == 'synchronize'
                    else request.get('base', {}).get('sha'))
    changed = changed_paths(before, head)
    enabled = diagnostic_changed(changed)
    return {'run': enabled, 'reason': 'diagnostic-files-changed' if enabled
            else 'unrelated-event-diff-no-measurement', 'before': before, 'head': head}


def scope():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())

    def exists(sha):
        return command(['git', '-C', str(ROOT), 'rev-parse', '--verify', sha + '^{commit}']) == sha

    def changed(before, head):
        return subprocess.check_output(['git', '-C', str(ROOT), 'diff', '--name-only', '--no-renames',
            '-z', before, head, '--'], timeout=120).decode('utf-8').split('\0')

    decision = scope_for_event(os.environ['GITHUB_EVENT_NAME'], event,
                               os.environ.get('GITHUB_SHA'), exists, changed)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as stream:
        stream.write('run=' + str(decision['run']).lower() + '\n')
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as stream:
        stream.write(('One browser measurement is selected; measurement outcome is pending.'
                      if decision['run'] else
                      'Skipped: this event changes no diagnostic files. No Chrome measurement ran '
                      'and no measurement artifact or passing measurement is claimed.') + '\n')
    print(json.dumps(decision))


def extract(archive, destination):
    """Reject traversal, links, special files and oversized build artifacts."""
    with tarfile.open(archive, 'r:gz') as source:
        members = source.getmembers()
        if sum(m.size for m in members) > 1024 * 1024 * 1024:
            raise ValueError('Web artifact unpacked size exceeds 1 GiB')
        seen = set()
        for member in members:
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe Web artifact path')
            if not (member.isfile() or member.isdir()):
                raise ValueError('Web artifact must contain only regular files/directories')
            if member.isfile() and str(relative) in seen:
                raise ValueError('Duplicate Web artifact file')
            seen.add(str(relative))
        source.extractall(destination, members=members, filter='data')


def validate_product_pin(pin):
    """An explicit immutable product selection; never resolve a moving branch."""
    fields = {'schema', 'label', 'commit', 'runId', 'artifactId', 'artifactZip', 'archive', 'webFiles'}
    if not isinstance(pin, dict) or set(pin) != fields or pin['schema'] != 'abc.browser-product-pin.v1':
        raise ValueError('Invalid exact product pin schema')
    if not isinstance(pin['label'], str) or not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', pin['label']):
        raise ValueError('Invalid product pin label')
    if not isinstance(pin['commit'], str) or not re.fullmatch(r'[0-9a-f]{40}', pin['commit']):
        raise ValueError('Product pin requires an exact lowercase commit SHA')
    if not isinstance(pin['runId'], str) or not re.fullmatch(r'[1-9][0-9]{0,19}', pin['runId']):
        raise ValueError('Product pin requires an exact official run ID')
    if type(pin['artifactId']) is not int or not 0 < pin['artifactId'] < 10 ** 20:
        raise ValueError('Product pin requires an exact artifact ID')
    def descriptor(row, bound):
        if (not isinstance(row, dict) or set(row) != {'bytes', 'sha256'}
                or type(row['bytes']) is not int or not 0 < row['bytes'] <= bound
                or not isinstance(row['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', row['sha256'])):
            raise ValueError('Product pin requires bounded byte counts and exact SHA-256 hashes')
    descriptor(pin['artifactZip'], 128 * 1024 * 1024)
    descriptor(pin['archive'], 128 * 1024 * 1024)
    if not isinstance(pin['webFiles'], dict) or set(pin['webFiles']) != set(WEB_HASHES):
        raise ValueError('Product pin must identify main.dart.js, engine/world.wasm and engine/world.js')
    for row in pin['webFiles'].values():
        descriptor(row, 128 * 1024 * 1024)
    return pin


def load_product_pin(path):
    path = Path(path)
    if path.stat().st_size > 65536:
        raise ValueError('Product pin manifest exceeds 64 KiB')
    return validate_product_pin(json.loads(path.read_text()))


def prepare(product_pin=None):
    cycles = product_pin is not None
    pin = validate_product_pin(product_pin) if cycles else None
    base = CYCLE_BASE if cycles else BASE
    evidence, web = base / 'evidence', base / 'web'
    artifact_id = pin['artifactId'] if pin else WEB_ARTIFACT_ID
    expected_zip = pin['artifactZip'] if pin else WEB_ZIP
    evidence.mkdir(parents=True, exist_ok=False)
    status = {'status': 'failed'}
    try:
        run_id = pin['runId'] if pin else WEB_RUN
        commit = pin['commit'] if pin else WEB_COMMIT
        repository = os.environ['GITHUB_REPOSITORY']
        if not re.fullmatch(r'[1-9][0-9]{0,19}', run_id):
            raise ValueError('Expected decimal official run ID')
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError('Expected exact lowercase Web source commit')
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
            raise ValueError('Invalid same-repository identity')
        run = json.loads(command(['gh', 'api', f'repos/{repository}/actions/runs/{run_id}']))
        dump(evidence / 'official-run.json', run)
        if (run.get('head_sha') != commit or run.get('status') != 'completed'
                or run.get('conclusion') != 'success'
                or run.get('path') != '.github/workflows/ci.yml'
                or run.get('repository', {}).get('full_name') != repository):
            raise ValueError('Artifact must come from successful official Flutter CI at the requested SHA')
        artifact_name = f'terraforge-web-{commit}'
        artifacts = json.loads(command(['gh', 'api',
            f'repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100']))
        selected = [a for a in artifacts['artifacts'] if a['name'] == artifact_name]
        if len(selected) != 1 or selected[0]['expired']:
            raise ValueError('Exactly one unexpired official Web artifact is required')
        artifact = selected[0]
        if artifact['id'] != artifact_id:
            raise ValueError('Pinned official Web artifact identity changed')
        dump(evidence / 'official-artifact.json', artifact)
        download = base / 'download'
        download.mkdir()
        compressed = download / 'official-web.zip'
        with compressed.open('xb') as stream:
            subprocess.run(['gh', 'api',
                f'repos/{repository}/actions/artifacts/{artifact_id}/zip'],
                stdout=stream, check=True, timeout=120)
        if describe(compressed) != expected_zip:
            raise ValueError('Pinned official artifact ZIP hash/length mismatch')
        with zipfile.ZipFile(compressed) as bundle:
            if bundle.namelist() != ['terraforge-web.tar.gz']:
                raise ValueError('Unexpected official artifact ZIP entries')
            if bundle.getinfo('terraforge-web.tar.gz').file_size > 128 * 1024 * 1024:
                raise ValueError('Official Web tarball exceeds bounded size')
            bundle.extract('terraforge-web.tar.gz', download)
        archive = download / 'terraforge-web.tar.gz'
        if not archive.is_file():
            raise ValueError('Missing official Web tarball')
        if pin and describe(archive) != pin['archive']:
            raise ValueError('Pinned official tarball hash/length mismatch')
        extract(archive, web)
        for name in ('index.html', 'main.dart.js', 'terra_world_circuit.js',
                     'terra_worker_rpc.js', 'terra_engine_worker.js', 'engine/world.wasm'):
            if not (web / name).is_file():
                raise ValueError(f'Incomplete Web build: {name}')
        files = {p.relative_to(web).as_posix(): describe(p)
                 for p in sorted(web.rglob('*')) if p.is_file()}
        for name, expected in (pin['webFiles'].items() if pin else WEB_HASHES.items()):
            if (files[name] != expected if pin else files[name]['sha256'] != expected):
                raise ValueError(f'Pinned official product bytes changed: {name}')
        source_head = command(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'])
        source_dirty = bool(command(['git', '-C', str(ROOT), 'status', '--porcelain',
                                     '--untracked-files=normal']))
        if source_dirty:
            raise ValueError('Diagnostic checkout must be clean and committed')
        status = {'status': 'verified', 'repository': repository,
                  'artifactSourceCommit': commit, 'artifactRunId': run_id,
                  'artifactRunUrl': run['html_url'], 'artifactId': artifact['id'],
                  'githubArtifactDigest': artifact.get('digest'),
                  'artifactZip': describe(compressed), 'archive': describe(archive),
                  'diagnosticSourceCommit': source_head,
                  'diagnosticDirty': source_dirty, 'webFiles': files,
                  'diagnosticFiles': {p.name: describe(p) for p in
                    (Path(__file__), ROOT / 'tool/perf/browser_load_driver.mjs',
                     ROOT / 'tool/perf/browser_load_cycles.mjs')}}
        if pin:
            status['productPin'] = pin
    except Exception as error:
        status['error'] = str(error)
        raise
    finally:
        dump(evidence / 'build.json', status)


def parse_kib(text):
    return {match[1]: int(match[2]) * 1024 for line in text.splitlines()
            if (match := re.fullmatch(r'([A-Za-z_]+):\s+(\d+) kB', line.strip()))}


def proc_stat(text):
    fields = text[text.rfind(')') + 2:].split()
    return {'state': fields[0], 'ppid': int(fields[1]), 'startTicks': int(fields[19])}



def chrome_process_kind(args):
    # Chromium may rewrite its process title into one argv entry. Ordinary
    # argv elements remain intact; quoted title arguments are parsed separately.
    tokens = [arg for arg in args if arg]
    if len(tokens) == 1:
        try:
            tokens = shlex.split(tokens[0])
        except ValueError:
            return 'unknown'
    kinds = [match.group(1) for arg in tokens
             if (match := re.fullmatch(r'--type=([A-Za-z0-9_-]+)', arg))]
    if len(kinds) > 1:
        return 'unknown'
    return kinds[0] if kinds else 'browser'


def snapshot_process(pid, expected_start=None):
    folder = Path('/proc') / str(pid)
    begin = time.monotonic_ns()
    try:
        stat = proc_stat((folder / 'stat').read_text())
        if expected_start is not None and stat['startTicks'] != expected_start:
            return None  # PID reuse is not part of this owned browser.
        raw_status = (folder / 'status').read_text()
        status = parse_kib(raw_status)
        args = (folder / 'cmdline').read_bytes().decode(errors='replace').split('\0')
        kind = chrome_process_kind(args)
        row = {'pid': pid, **stat, 'kind': kind, 'readStartMonoNs': begin,
               'rssBytes': status.get('VmRSS'), 'processHwmBytes': status.get('VmHWM'),
               'pssBytes': None, 'smapsRssBytes': None, 'smapsError': None,
               'sandbox': {key: next((line.split(':', 1)[1].strip()
                   for line in raw_status.splitlines() if line.startswith(key + ':')), None)
                   for key in ('NoNewPrivs', 'Seccomp', 'Seccomp_filters')},
               'args': args}
        try:
            smaps = parse_kib((folder / 'smaps_rollup').read_text())
            row.update(pssBytes=smaps.get('Pss'), smapsRssBytes=smaps.get('Rss'))
        except (OSError, ValueError) as error:
            row['smapsError'] = type(error).__name__
        # Recheck identity after non-atomic /proc reads.
        if proc_stat((folder / 'stat').read_text())['startTicks'] != stat['startTicks']:
            return None
        row['readEndMonoNs'] = time.monotonic_ns()
        return row
    except (OSError, ValueError, IndexError):
        return None


def aggregate(rows):
    live = [p for p in rows if p['state'] != 'Z']
    def total(key):
        values = [p[key] for p in live]
        return sum(values) if values and all(v is not None for v in values) else None
    return {'processCount': len(live), 'rssSumBytes': total('rssBytes'),
            'pssSumBytes': total('pssBytes')}


def read_rows(path):
    rows, errors = [], []
    if not path.is_file():
        return rows, ['missing-file']
    with path.open('rb') as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except (json.JSONDecodeError, UnicodeDecodeError):
                errors.append(f'invalid-json-line-{number}')
    return rows, errors


class Sampler:
    def __init__(self, pid, output, max_output_bytes=None):
        self.pid, self.output = pid, output
        self.known, self.latest, self.previous = {}, None, {}
        self.max_output_bytes, self.output_bytes = max_output_bytes, 0
        self.max_owned_rss_bytes = None
        self.stop = threading.Event()
        self.failure = None
        self.thread = threading.Thread(target=self.loop, daemon=True)

    def sample(self):
        sample_start = time.monotonic_ns()
        pending = [self.pid, *self.known]
        seen, rows = set(), []
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            row = snapshot_process(pid, self.known.get(pid))
            if not row:
                continue
            self.known[pid] = row['startTicks']
            rows.append(row)
            try:
                # Threads can spawn Chrome children; follow only this owned tree.
                for task in (Path('/proc') / str(pid) / 'task').iterdir():
                    pending.extend(int(p) for p in (task / 'children').read_text().split())
            except OSError:
                pass
        current = {row['pid']: row['startTicks'] for row in rows}
        disappeared = [{'pid': pid, 'startTicks': start, 'exitStatus': None}
                       for pid, start in self.previous.items() if current.get(pid) != start]
        self.previous = current
        return {'monoNs': time.monotonic_ns(), 'sampleStartMonoNs': sample_start,
                'processes': rows, 'disappearedSincePrevious': disappeared, **aggregate(rows)}

    def loop(self):
        try:
            with self.output.open('x') as stream:
                while not self.stop.is_set():
                    begin = time.monotonic()
                    self.latest = self.sample()
                    known_rss = [row['rssBytes'] for row in self.latest['processes']
                                 if row['state'] != 'Z' and row['rssBytes'] is not None]
                    if known_rss:
                        # Even an incomplete tree can establish the limit was
                        # exceeded. This lower bound never fills raw RSS/PSS.
                        self.max_owned_rss_bytes = max(self.max_owned_rss_bytes or 0, sum(known_rss))
                    line = json.dumps(self.latest, separators=(',', ':')) + '\n'
                    size = len(line.encode('utf-8'))
                    if self.max_output_bytes is not None and self.output_bytes + size > self.max_output_bytes:
                        raise RuntimeError('OS sample evidence size limit reached')
                    stream.write(line)
                    self.output_bytes += size
                    stream.flush()
                    self.stop.wait(max(0, 0.25 - (time.monotonic() - begin)))
        except Exception as error:
            self.failure = str(error)


def sandbox_verified(row):
    renderers = [p for p in (row or {}).get('processes', []) if p['kind'] == 'renderer']
    return bool(renderers) and all(p['sandbox']['NoNewPrivs'] == '1'
                                  and p['sandbox']['Seccomp'] == '2' for p in renderers)


def summarize_memory(samples, stages):
    names = {s['name']: s['hostMonoNs'] for s in stages if s.get('type') == 'stage'}
    gaps = [b['monoNs'] - a['monoNs'] for a, b in zip(samples, samples[1:])]
    result = {'sampleCount': len(samples), 'maxSampleGapNs': max(gaps, default=None),
              'baseline': None, 'loadingPeak': None, 'readyIdlePeak': None,
              'lifecyclePeak': None, 'afterClose': None,
              'loadingPeakMinusBaseline': None, 'lifecyclePeakMinusBaseline': None,
              'releaseFromLifecyclePeak': None}
    # Only complete-tree observations are comparable; do not fill missing PSS.
    window = [s for s in samples if names.get('baseline-start', float('inf')) <= s['monoNs']
              <= names.get('release-complete', names.get('driver-failed', float('inf')))]
    baseline = [s for s in window if names.get('baseline-start', float('inf')) <= s['monoNs']
                < names.get('load-start', -1)]
    loading = [s for s in window if names.get('load-start', float('inf')) <= s['monoNs']
               < names.get('ready', names.get('driver-failed', float('inf')))]
    idle = [s for s in window if names.get('ready', float('inf')) <= s['monoNs']
            < names.get('close-start', names.get('driver-failed', float('inf')))]
    lifecycle = [s for s in window if names.get('load-start', float('inf')) <= s['monoNs']]
    closed = [s for s in window if names.get('close-complete', float('inf')) <= s['monoNs']
              <= names.get('release-complete', -1)]
    def point(rows, pick):
        if not rows:
            return None
        return {key: pick(values) if (values := [s[key] for s in rows if s[key] is not None])
                else None for key in ('rssSumBytes', 'pssSumBytes')}
    result.update(baseline=point(baseline, lambda a: a[-1]), loadingPeak=point(loading, max),
                  readyIdlePeak=point(idle, max), lifecyclePeak=point(lifecycle, max),
                  afterClose=point(closed, lambda a: a[-1]),
                  phaseSampleCounts={'baseline': len(baseline), 'loading': len(loading),
                                     'readyIdle': len(idle), 'lifecycle': len(lifecycle),
                                     'afterClose': len(closed)},
                  measurementWindowSampleCount=len(window),
                  incompleteSampleCount=sum(s['rssSumBytes'] is None or s['pssSumBytes'] is None
                                            for s in window))
    def delta(high, low):
        if not result[high] or not result[low]:
            return None
        return {key: result[high][key] - result[low][key]
                if result[high][key] is not None and result[low][key] is not None else None
                for key in result[high]}
    result['loadingPeakMinusBaseline'] = delta('loadingPeak', 'baseline')
    result['lifecyclePeakMinusBaseline'] = delta('lifecyclePeak', 'baseline')
    result['releaseFromLifecyclePeak'] = delta('lifecyclePeak', 'afterClose')
    return result


def summarize_cycle_memory(samples, stages):
    """Strict per-cycle windows. Invalid marker streams never yield comparisons.

    A missing suffix keeps earlier sampled peaks, clamped before the following
    cycle. A duplicate, skipped or backwards marker makes that cycle invalid.
    The comparable release statistic uses an identical 20 s post-close window,
    not whichever sample happened to be last when the next cycle started.
    """
    keys = ('rssSumBytes', 'pssSumBytes')
    grouped = {cycle: [] for cycle in range(1, CYCLE_COUNT + 1)}
    issues = []
    previous_time, previous_cycle = None, 0
    invalid_cycles = set()
    for number, row in enumerate(stages, 1):
        if not isinstance(row, dict):
            issues.append(f'event-{number}: not an object')
            continue
        if row.get('type') != 'stage' or row.get('name') not in (*CYCLE_STAGES, 'driver-failed'):
            continue
        cycle, stamp = row.get('cycle'), row.get('hostMonoNs')
        if type(cycle) is not int or cycle not in grouped:
            issues.append(f'event-{number}: invalid cycle')
            invalid_cycles.update(grouped)
            continue
        if type(stamp) is not int or stamp < 0:
            issues.append(f'cycle-{cycle}: invalid monotonic timestamp')
            invalid_cycles.add(cycle)
            continue
        if previous_time is not None and (stamp <= previous_time or cycle < previous_cycle):
            issues.append(f'cycle-{cycle}: out-of-order marker')
            invalid_cycles.update((cycle, previous_cycle))
        previous_time, previous_cycle = stamp, cycle
        grouped[cycle].append(row)

    valid_samples = []
    previous_sample_time = None
    for number, row in enumerate(samples, 1):
        stamp = row.get('monoNs') if isinstance(row, dict) else None
        start = row.get('sampleStartMonoNs', stamp) if isinstance(row, dict) else None
        if (type(stamp) is not int or type(start) is not int or not 0 <= start <= stamp
                or (previous_sample_time is not None and stamp <= previous_sample_time)
                or any(row.get(key) is not None and (type(row[key]) is not int or row[key] < 0)
                       for key in keys)):
            issues.append(f'sample-{number}: invalid or out-of-order sample')
            continue
        previous_sample_time = stamp
        valid_samples.append(row)

    def point(rows, mode):
        if not rows:
            return None
        if mode == 'last':
            return {key: rows[-1].get(key) for key in keys}
        if mode == 'mean':
            return {key: sum(values) / len(values) if all(v is not None for v in values) else None
                    for key in keys for values in [[row.get(key) for row in rows]]}
        return {key: max(values, default=None) for key in keys
                for values in [[row[key] for row in rows if row.get(key) is not None]]}

    def difference(high, low):
        if high is None or low is None:
            return None
        return {key: high[key] - low[key] if high[key] is not None and low[key] is not None
                else None for key in keys}

    cycles = []
    for cycle, markers in grouped.items():
        errors, expected, names, failed = [], 0, {}, False
        for row in markers:
            name = row['name']
            if failed:
                errors.append('marker after driver-failed')
            if name == 'driver-failed':
                if failed:
                    errors.append('duplicate driver-failed')
                failed = True
                names[name] = row['hostMonoNs']
            elif expected >= len(CYCLE_STAGES) or name != CYCLE_STAGES[expected]:
                errors.append(f'unexpected marker: {name}')
            else:
                names[name] = row['hostMonoNs']
                expected += 1
        if cycle in invalid_cycles:
            errors.append('invalid marker ordering or attribution')
        complete = expected == len(CYCLE_STAGES) and not failed and not errors
        status = 'invalid' if errors else 'complete' if complete else 'failed' if failed else 'incomplete'
        if not markers:
            status = 'missing'
        entry = {'cycle': cycle, 'stageStatus': status, 'stageErrors': errors,
                 'stages': names, 'missingStages': list(CYCLE_STAGES[expected:]),
                 'memory': None}
        cycles.append(entry)
        if errors or 'baseline-start' not in names:
            continue
        following = [row['hostMonoNs'] for later in range(cycle + 1, CYCLE_COUNT + 1)
                     for row in grouped[later]]
        # All windows are half-open; non-atomic samples crossing a boundary are
        # excluded. A truncated cycle cannot consume the following cycle's data.
        end = min(names.get('release-complete', float('inf')),
                  names.get('driver-failed', float('inf')),
                  min(following, default=float('inf')))
        if end == float('inf'):
            end = (valid_samples[-1]['monoNs'] + 1) if valid_samples else names['baseline-start']
        begin = names['baseline-start']
        def window(start, stop):
            if start is None:
                return []
            stop = min(end, stop if stop is not None else end)
            return [row for row in valid_samples if start <= row.get('sampleStartMonoNs', row['monoNs'])
                    and row['monoNs'] < stop]
        all_rows = window(begin, end)
        phase_rows = {start: window(names.get(start), names.get(stop))
                      for start, stop in zip(CYCLE_STAGES, CYCLE_STAGES[1:])}
        baseline = phase_rows['baseline-start']
        lifecycle = window(names.get('load-start'), end)
        closed_at = names.get('close-complete')
        closed_end = None if closed_at is None else closed_at + CYCLE_AFTER_CLOSE_MS * 1000000
        elapsed_close = closed_end is not None and names.get('release-complete', -1) >= closed_end
        closed = window(closed_at, closed_end) if elapsed_close and end >= closed_end else []
        memory = {'measurementWindow': {'startMonoNs': begin, 'endMonoNsExclusive': end},
                  'measurementWindowSampleCount': len(all_rows),
                  'incompleteSampleCount': sum(any(row.get(key) is None for key in keys)
                                               for row in all_rows),
                  'maxSampleGapNs': max((b['monoNs'] - a['monoNs']
                                        for a, b in zip(all_rows, all_rows[1:])), default=None),
                  'baseline': point(baseline, 'last'),
                  'loadingPeak': point(phase_rows['load-start'], 'peak'),
                  'lifecyclePeak': point(lifecycle, 'peak'),
                  'afterClose': point(closed, 'mean'),
                  'phasePeaks': {name: point(rows, 'peak') for name, rows in phase_rows.items()},
                  'phaseSampleCounts': {name: len(rows) for name, rows in phase_rows.items()},
                  'afterCloseWindow': {'startMonoNs': closed_at, 'endMonoNsExclusive': closed_end,
                      'durationMs': CYCLE_AFTER_CLOSE_MS, 'completeElapsedWindow': elapsed_close,
                      'statistic': 'arithmetic-mean-of-samples', 'sampleCount': len(closed),
                      'incompleteSampleCount': sum(any(row.get(key) is None for key in keys)
                                                   for row in closed)}}
        memory['loadingPeakMinusBaseline'] = difference(memory['loadingPeak'], memory['baseline'])
        memory['lifecyclePeakMinusBaseline'] = difference(memory['lifecyclePeak'], memory['baseline'])
        memory['releaseFromLifecyclePeak'] = difference(memory['lifecyclePeak'], memory['afterClose'])
        entry['memory'] = memory

    deltas = []
    for earlier, later in zip(cycles, cycles[1:]):
        eligible = (earlier['stageStatus'] == later['stageStatus'] == 'complete'
                    and not issues)
        first = earlier['memory']['afterClose'] if eligible else None
        second = later['memory']['afterClose'] if eligible else None
        delta = difference(second, first)
        deltas.append({'fromCycle': earlier['cycle'], 'toCycle': later['cycle'],
                       'windowDurationMs': CYCLE_AFTER_CLOSE_MS,
                       'statistic': 'arithmetic-mean-of-samples', 'deltaBytes': delta,
                       'status': 'observed' if delta and all(v is not None for v in delta.values())
                       else 'inconclusive'})
    adequate = not issues and all(entry['stageStatus'] == 'complete' and entry['memory']
        and entry['memory']['incompleteSampleCount'] == 0
        and entry['memory']['baseline'] and entry['memory']['loadingPeak']
        and entry['memory']['afterClose'] for entry in cycles)
    return {'expectedCycles': CYCLE_COUNT, 'cycles': cycles, 'streamErrors': issues,
            'status': 'observed' if adequate else 'inconclusive',
            'successiveAfterCloseDeltas': deltas,
            'interpretation': 'Descriptive same-window observations only; no leak or stability threshold verdict.'}


class BoundedLog:
    """Drain a child's pipe while bounding retained logs, including failures."""
    def __init__(self, source, path, max_bytes=CYCLE_LOG_BYTES):
        self.source, self.path, self.max_bytes = source, path, max_bytes
        self.bytes_written, self.limit_reached, self.failure = 0, False, None
        self.thread = threading.Thread(target=self.copy, daemon=True)
        self.thread.start()

    def copy(self):
        try:
            with self.path.open('xb') as output:
                while data := self.source.read(65536):
                    keep = data[:max(0, self.max_bytes - self.bytes_written)]
                    output.write(keep)
                    output.flush()
                    self.bytes_written += len(keep)
                    if len(keep) != len(data):
                        self.limit_reached = True
        except Exception as error:
            self.failure = str(error)
        finally:
            self.source.close()

    def close(self):
        self.thread.join(timeout=2)


class CycleGuard:
    def __init__(self, evidence, started=None):
        self.evidence = evidence
        self.started = time.monotonic() if started is None else started
        self.max_evidence_bytes = 0

    def reason(self, sampler=None, logs=(), now=None):
        now = time.monotonic() if now is None else now
        if now - self.started >= CYCLE_GLOBAL_SECONDS - CYCLE_CLEANUP_RESERVE_SECONDS:
            return 'cycle-global-deadline-cleanup-reserve'
        if sampler and sampler.failure:
            return 'cycle-sampler-failure: ' + sampler.failure
        if sampler and (sampler.max_owned_rss_bytes or 0) >= CYCLE_MAX_RSS_BYTES:
            return 'cycle-owned-rss-limit-6-gib'
        for stream in logs:
            if stream.failure or stream.limit_reached:
                return 'cycle-log-evidence-limit-or-read-failure'
        size = sum(path.stat().st_size for path in self.evidence.rglob('*') if path.is_file())
        self.max_evidence_bytes = max(self.max_evidence_bytes, size)
        if size >= CYCLE_MAX_EVIDENCE_BYTES:
            return 'cycle-total-evidence-limit-512-mib'
        return None


def wait_cycle_driver(driver, guard, sampler, logs, wait=time.sleep):
    """Poll rather than block for minutes, preserving evidence on each limit."""
    while True:
        reason = guard.reason(sampler, logs)
        if reason:
            return None, reason
        code = driver.poll()
        if code is not None:
            return code, None
        wait(CYCLE_POLL_SECONDS)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def run(cycles=False):
    evidence = CYCLE_BASE / 'evidence' if cycles else EVIDENCE
    web = CYCLE_BASE / 'web' if cycles else WEB
    guard = CycleGuard(evidence) if cycles else None
    evidence.mkdir(parents=True, exist_ok=True)
    report_path = evidence / 'execution.json'
    if report_path.exists():
        raise ValueError('One attempt only; execution evidence already exists')
    report = {'schema': 'abc.browser-load-diagnostic.v1', 'status': 'inconclusive',
              'startedUtc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'sampleIntervalMs': 250, 'browserExit': None, 'driverExit': None,
              'terminationRequested': None, 'sandboxVerifiedBeforeLoad': False,
              'limits': [
                  'One headless Chrome lifecycle with accessibility enabled; no screen FPS claim.',
                  'Fresh browser process, not cold OS file cache: fixture verification reads it before launch; picker and pre-verification are outside loading.',
                  'This independent CI result cannot explain another cloud browser Error 9.',
                  'RSS sums can double count shared pages; PSS is a separate proportional view.',
                  'PSS sums are proportional shared-memory estimates, not exclusive process ownership.',
                  'Per-process VmHWM is a process-lifetime high-water mark, not a resettable phase peak or additive tree peak.',
                  '250 ms samples can miss shorter peaks; /proc fields are non-atomic.',
                  'The process set is the browser plus observed descendants; very short-lived or double-forked children may escape enumeration.',
                  'WASM heap capacity and engine native-active counters overlap OS measurements.',
                  'Only the direct Chrome wait status is an OS return code; CDP crash status/code and process disappearance are separate evidence.',
                  'No forced GC; after-close delta includes elapsed time, worker retirement and allocator behavior.',
              ]}
    if cycles:
        report.update(schema='abc.browser-cycle-diagnostic.v1', requestedCycles=CYCLE_COUNT,
            control={'label': 'exact-explicit-product-control',
                     'preparedBuildEvidence': str(evidence / 'build.json')},
            budgets={'globalSeconds': CYCLE_GLOBAL_SECONDS,
                     'cleanupReserveSeconds': CYCLE_CLEANUP_RESERVE_SECONDS,
                     'driverSoftSeconds': CYCLE_DRIVER_SOFT_SECONDS,
                     'driverPollMs': int(CYCLE_POLL_SECONDS * 1000),
                     'maxOwnedRssBytes': CYCLE_MAX_RSS_BYTES,
                     'maxEvidenceBytes': CYCLE_MAX_EVIDENCE_BYTES,
                     'maxOsMemoryBytes': CYCLE_SAMPLE_BYTES, 'maxBytesPerLog': CYCLE_LOG_BYTES},
            afterCloseWindowMs=CYCLE_AFTER_CLOSE_MS)
        report['limits'][0] = 'Three interaction cycles in one headless Chrome/process-sampling stream; no screen FPS claim.'
        report['limits'].append('Same-window after-close means and deltas are descriptive; no leak or stability pass threshold.')
    browser = driver = sampler = server = profile_context = None
    logs = []
    bounded_logs = []
    dump(report_path, report)
    try:
        provenance = json.loads((evidence / 'build.json').read_text())
        if provenance.get('status') != 'verified':
            raise ValueError('Verified official Web build required')
        if cycles:
            pin = validate_product_pin(provenance.get('productPin'))
            if (provenance.get('artifactSourceCommit') != pin['commit']
                    or provenance.get('artifactRunId') != pin['runId']
                    or provenance.get('artifactId') != pin['artifactId']
                    or provenance.get('artifactZip') != pin['artifactZip']
                    or provenance.get('archive') != pin['archive']):
                raise ValueError('Prepared provenance differs from exact product selection')
            report['control']['label'] = pin['label']
            files = {p.relative_to(web).as_posix(): describe(p)
                     for p in sorted(web.rglob('*')) if p.is_file()}
            if (not files or files != provenance.get('webFiles')
                    or any(files.get(name) != meta for name, meta in pin['webFiles'].items())):
                raise ValueError('Prepared immutable official Web files changed')
            report['control']['artifactSourceCommit'] = provenance['artifactSourceCommit']
        if os.getuid() == 0 or platform.system() != 'Linux':
            raise ValueError('Non-root Linux with existing Chrome sandbox is required')
        if not CHROME.is_file() or not os.access(CHROME, os.X_OK):
            raise ValueError('Preinstalled official /opt/google/chrome/chrome is required')
        fixture = ROOT / 'build/public-computerraria/computerraria.wld'
        fixture_meta = describe(fixture)
        if fixture_meta != {'bytes': WORLD_SIZE, 'sha256': WORLD_SHA}:
            raise ValueError('Complete pinned public WLD length/hash mismatch')
        report.update(fixture=fixture_meta, browserBinary=describe(CHROME),
                      chromeVersion=command([str(CHROME), '--version']),
                      chromePackage=command(['dpkg-query', '-W', '-f=${Package} ${Version}',
                                             'google-chrome-stable']),
                      kernel=platform.platform(), nodeVersion=command(['node', '--version']),
                      pythonVersion=platform.python_version(), uid=os.getuid(),
                      runnerImage={k: os.environ.get(k) for k in ('ImageOS', 'ImageVersion')},
                      build={'artifactSourceCommit': provenance['artifactSourceCommit'],
                             'diagnosticSourceCommit': provenance['diagnosticSourceCommit']})
        if cycles:
            report['cycleDiagnosticFiles'] = {p.name: describe(p) for p in
                (Path(__file__), ROOT / 'tool/perf/browser_load_driver.mjs',
                 ROOT / 'tool/perf/browser_load_cycles.mjs')}
            if reason := guard.reason():
                report['terminationRequested'] = reason
                raise RuntimeError(reason)
        (evidence / 'meminfo-start.txt').write_text(Path('/proc/meminfo').read_text())
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
            functools.partial(QuietHandler, directory=str(web)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        # No profile, cookies, credentials, or browser from another task is used.
        profile_context = tempfile.TemporaryDirectory(prefix='abc-browser-load-')
        profile = profile_context.name
        args = [str(CHROME), '--headless=new', '--remote-debugging-address=127.0.0.1',
                '--remote-debugging-port=0', f'--user-data-dir={profile}',
                '--no-first-run', '--no-default-browser-check', '--window-size=1440,1100',
                'about:blank']
        report['browserArguments'] = [a if not a.startswith('--user-data-dir=')
                                     else '--user-data-dir=<new-temporary-profile>' for a in args]
        if not cycles:
            for name in ('chrome.stdout.log', 'chrome.stderr.log', 'driver.stdout.log', 'driver.stderr.log'):
                logs.append((evidence / name).open('w'))
        browser = subprocess.Popen(args, stdout=subprocess.PIPE if cycles else logs[0],
            stderr=subprocess.PIPE if cycles else logs[1], start_new_session=True)
        if cycles:
            bounded_logs.extend((BoundedLog(browser.stdout, evidence / 'chrome.stdout.log'),
                                 BoundedLog(browser.stderr, evidence / 'chrome.stderr.log')))
        report['browserPid'] = browser.pid
        sampler = Sampler(browser.pid, evidence / 'os-memory.ndjson',
                          max_output_bytes=CYCLE_SAMPLE_BYTES if cycles else None)
        sampler.thread.start()
        deadline = time.monotonic() + 30
        active = Path(profile) / 'DevToolsActivePort'
        while not active.is_file():
            if cycles and (reason := guard.reason(sampler, bounded_logs)):
                report['terminationRequested'] = reason
                raise RuntimeError(reason)
            if browser.poll() is not None:
                raise RuntimeError('Chrome exited before CDP startup; sandbox was not bypassed')
            if time.monotonic() >= deadline:
                raise TimeoutError('Chrome startup timed out; sandbox was not bypassed')
            time.sleep(0.1)
        port = int(active.read_text().splitlines()[0])
        # Evidence of default renderer seccomp and no_new_privs is required
        # before navigating to the fixture app, never fix settings to pass.
        while not sandbox_verified(sampler.latest):
            if cycles and (reason := guard.reason(sampler, bounded_logs)):
                report['terminationRequested'] = reason
                raise RuntimeError(reason)
            if browser.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Could not verify sandboxed renderer; fixture was not loaded')
            time.sleep(0.1)
        report['pssAvailableBeforeLoad'] = sampler.latest['pssSumBytes'] is not None
        report['sandboxVerifiedBeforeLoad'] = True
        dump(evidence / 'sandbox-preflight.json', sampler.latest)
        dump(report_path, report)
        app_url = f'http://127.0.0.1:{server.server_port}/'
        driver = subprocess.Popen(['node', str(ROOT / 'tool/perf/browser_load_driver.mjs'),
            str(port), app_url, str(fixture), str(evidence)] + (['--cycles=3'] if cycles else []),
            stdout=subprocess.PIPE if cycles else logs[2], stderr=subprocess.PIPE if cycles else logs[3])
        if cycles:
            bounded_logs.extend((BoundedLog(driver.stdout, evidence / 'driver.stdout.log'),
                                 BoundedLog(driver.stderr, evidence / 'driver.stderr.log')))
            report['driverExit'], reason = wait_cycle_driver(driver, guard, sampler, bounded_logs)
            if reason:
                report['terminationRequested'] = reason
                report['status'] = 'failed'
                raise RuntimeError(reason)
        else:
            try:
                report['driverExit'] = driver.wait(timeout=780)
            except subprocess.TimeoutExpired:
                report['terminationRequested'] = 'driver-hard-deadline-780-seconds'
                driver.terminate()
                try:
                    driver.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    driver.kill()
                    driver.wait()
                report['driverExit'] = driver.returncode
        # The driver requests Browser.close after its bounded release tail.
        try:
            browser.wait(timeout=15)
        except subprocess.TimeoutExpired:
            report['terminationRequested'] = report['terminationRequested'] or 'browser-did-not-close'
            browser.terminate()
            try:
                browser.wait(timeout=5)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait()
        report['browserExit'] = {'returncode': browser.returncode,
            'signal': -browser.returncode if browser.returncode < 0 else None}
        result = json.loads((evidence / 'driver-result.json').read_text())
        report['driverResult'] = result
        if cycles and (result.get('schema') != 'abc.browser-cycle-driver.v1'
                       or result.get('requestedCycles') != CYCLE_COUNT
                       or result.get('afterCloseMs') != CYCLE_AFTER_CLOSE_MS):
            raise ValueError('Cycle driver schema/count/release-window mismatch')
        if (result.get('status') == 'observed' and report['driverExit'] == 0
                and browser.returncode == 0 and report['terminationRequested'] is None):
            report['status'] = 'observed'
        else:
            report['status'] = 'failed'
    except Exception as error:
        report['error'] = str(error)
        if cycles:
            report['status'] = 'failed'
    finally:
        if driver and driver.poll() is None:
            driver.terminate()
            try:
                driver.wait(timeout=5)
            except subprocess.TimeoutExpired:
                driver.kill()
                driver.wait()
            report['driverExit'] = driver.returncode
        if browser:
            if browser.poll() is None:
                report['terminationRequested'] = report['terminationRequested'] or 'finalize-owned-browser'
                browser.terminate()
                try:
                    browser.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    browser.kill()
                    browser.wait()
            report['browserExit'] = {'returncode': browser.returncode,
                'signal': -browser.returncode if browser.returncode < 0 else None}
        if sampler:
            sampler.stop.set()
            sampler.thread.join(timeout=5)
            if sampler.failure or sampler.thread.is_alive():
                report['status'] = 'failed'
                report['samplerError'] = sampler.failure or 'Sampler did not stop'
            # Only verified descendants of this launch, with unchanged Linux
            # start ticks, can be cleaned up after a browser crash/deadline.
            survivors = [row for pid, start in list(sampler.known.items())
                         if pid != sampler.pid and (row := snapshot_process(pid, start))
                         and row['state'] != 'Z']
            report['ownedDescendantsAfterBrowserExit'] = [
                {'pid': row['pid'], 'startTicks': row['startTicks'], 'kind': row['kind']}
                for row in survivors]
            if survivors:
                report['status'] = 'inconclusive'
                report['terminationRequested'] = report['terminationRequested'] or 'owned-descendants-remained'
                for row in survivors:
                    try:
                        os.kill(row['pid'], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                time.sleep(1)
                for row in survivors:
                    still_owned = snapshot_process(row['pid'], row['startTicks'])
                    if still_owned and still_owned['state'] != 'Z':
                        try:
                            os.kill(row['pid'], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
            samples, sample_errors = read_rows(sampler.output)
            stage_file = evidence / 'browser-events.ndjson'
            stages, stage_errors = read_rows(stage_file)
            report['rawReadErrors'] = {'os-memory.ndjson': sample_errors,
                                       'browser-events.ndjson': stage_errors}
            report['memory'] = (summarize_cycle_memory(samples, stages) if cycles
                                else summarize_memory(samples, stages))
            missing_memory = (report['memory']['status'] != 'observed' if cycles else
                              report['memory']['incompleteSampleCount'] or not report['memory']['afterClose'])
            if report['status'] == 'observed' and (sample_errors or stage_errors or missing_memory):
                report['status'] = 'inconclusive'
                report['error'] = 'Complete process-tree memory evidence missing'
        if server:
            server.shutdown()
            server.server_close()
        for stream in logs:
            stream.close()
        for stream in bounded_logs:
            stream.close()
        if cycles:
            if 'driverResult' not in report:
                try:
                    report['driverResult'] = json.loads((evidence / 'driver-result.json').read_text())
                except (OSError, ValueError) as error:
                    report['driverResultReadError'] = str(error)
            report['boundedLogs'] = {stream.path.name: {
                'bytesRetained': stream.bytes_written, 'limitReached': stream.limit_reached,
                'error': stream.failure, 'drainComplete': not stream.thread.is_alive()}
                for stream in bounded_logs}
            reason = guard.reason(sampler, bounded_logs)
            if reason:
                report['status'] = 'failed'
                report['terminationRequested'] = report['terminationRequested'] or reason
            report['maxObservedEvidenceBytes'] = guard.max_evidence_bytes
            report['maxObservedOwnedRssBytes'] = sampler.max_owned_rss_bytes if sampler else None
            if any(stream.thread.is_alive() for stream in bounded_logs):
                report['status'] = 'inconclusive'
        if profile_context:
            try:
                profile_context.cleanup()
            except OSError as error:
                report['profileCleanupError'] = type(error).__name__
                report['status'] = 'inconclusive'
        report['finishedUtc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        report['evidenceFiles'] = {p.name: describe(p) for p in sorted(evidence.iterdir())
                                   if p.is_file() and p != report_path}
        dump(report_path, report)
    print(json.dumps({'status': report['status'], 'error': report.get('error'),
                      'browserExit': report['browserExit']}))
    return 0 if report['status'] == 'observed' else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('scope', 'prepare', 'prepare-cycles', 'run', 'run-cycles'))
    parser.add_argument('--product-manifest', type=Path)
    arguments = parser.parse_args()
    if (arguments.action == 'prepare-cycles') != (arguments.product_manifest is not None):
        parser.error('--product-manifest is required only with prepare-cycles')
    if arguments.action == 'scope':
        scope()
    elif arguments.action == 'prepare':
        prepare()
    elif arguments.action == 'prepare-cycles':
        prepare(load_product_pin(arguments.product_manifest))
    else:
        raise SystemExit(run(cycles=arguments.action == 'run-cycles'))
