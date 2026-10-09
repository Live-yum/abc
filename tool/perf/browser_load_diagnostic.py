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
                        'tool/perf/BROWSER_LOAD_DIAGNOSTIC.md')
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


def prepare():
    EVIDENCE.mkdir(parents=True, exist_ok=False)
    status = {'status': 'failed'}
    try:
        run_id = WEB_RUN
        commit = WEB_COMMIT
        repository = os.environ['GITHUB_REPOSITORY']
        if not re.fullmatch(r'[1-9][0-9]{0,19}', run_id):
            raise ValueError('Expected decimal official run ID')
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            raise ValueError('Expected exact lowercase Web source commit')
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
            raise ValueError('Invalid same-repository identity')
        run = json.loads(command(['gh', 'api', f'repos/{repository}/actions/runs/{run_id}']))
        dump(EVIDENCE / 'official-run.json', run)
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
        if artifact['id'] != WEB_ARTIFACT_ID:
            raise ValueError('Pinned official Web artifact identity changed')
        dump(EVIDENCE / 'official-artifact.json', artifact)
        download = BASE / 'download'
        download.mkdir()
        compressed = download / 'official-web.zip'
        with compressed.open('xb') as stream:
            subprocess.run(['gh', 'api',
                f'repos/{repository}/actions/artifacts/{WEB_ARTIFACT_ID}/zip'],
                stdout=stream, check=True, timeout=120)
        if describe(compressed) != WEB_ZIP:
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
        extract(archive, WEB)
        for name in ('index.html', 'main.dart.js', 'terra_world_circuit.js',
                     'terra_worker_rpc.js', 'terra_engine_worker.js', 'engine/world.wasm'):
            if not (WEB / name).is_file():
                raise ValueError(f'Incomplete Web build: {name}')
        files = {p.relative_to(WEB).as_posix(): describe(p)
                 for p in sorted(WEB.rglob('*')) if p.is_file()}
        for name, expected in WEB_HASHES.items():
            if files[name]['sha256'] != expected:
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
                    (Path(__file__), ROOT / 'tool/perf/browser_load_driver.mjs')}}
    except Exception as error:
        status['error'] = str(error)
        raise
    finally:
        dump(EVIDENCE / 'build.json', status)


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
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            errors.append(f'invalid-json-line-{number}')
    return rows, errors


class Sampler:
    def __init__(self, pid, output):
        self.pid, self.output = pid, output
        self.known, self.latest, self.previous = {}, None, {}
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
                    stream.write(json.dumps(self.latest, separators=(',', ':')) + '\n')
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


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def run():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    report_path = EVIDENCE / 'execution.json'
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
    browser = driver = sampler = server = profile_context = None
    logs = []
    dump(report_path, report)
    try:
        provenance = json.loads((EVIDENCE / 'build.json').read_text())
        if provenance.get('status') != 'verified':
            raise ValueError('Verified official Web build required')
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
        (EVIDENCE / 'meminfo-start.txt').write_text(Path('/proc/meminfo').read_text())
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
            functools.partial(QuietHandler, directory=str(WEB)))
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
        for name in ('chrome.stdout.log', 'chrome.stderr.log', 'driver.stdout.log', 'driver.stderr.log'):
            logs.append((EVIDENCE / name).open('w'))
        browser = subprocess.Popen(args, stdout=logs[0], stderr=logs[1], start_new_session=True)
        report['browserPid'] = browser.pid
        sampler = Sampler(browser.pid, EVIDENCE / 'os-memory.ndjson')
        sampler.thread.start()
        deadline = time.monotonic() + 30
        active = Path(profile) / 'DevToolsActivePort'
        while not active.is_file():
            if browser.poll() is not None:
                raise RuntimeError('Chrome exited before CDP startup; sandbox was not bypassed')
            if time.monotonic() >= deadline:
                raise TimeoutError('Chrome startup timed out; sandbox was not bypassed')
            time.sleep(0.1)
        port = int(active.read_text().splitlines()[0])
        # Evidence of default renderer seccomp and no_new_privs is required
        # before navigating to the fixture app, never fix settings to pass.
        while not sandbox_verified(sampler.latest):
            if browser.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('Could not verify sandboxed renderer; fixture was not loaded')
            time.sleep(0.1)
        report['pssAvailableBeforeLoad'] = sampler.latest['pssSumBytes'] is not None
        report['sandboxVerifiedBeforeLoad'] = True
        dump(EVIDENCE / 'sandbox-preflight.json', sampler.latest)
        dump(report_path, report)
        app_url = f'http://127.0.0.1:{server.server_port}/'
        driver = subprocess.Popen(['node', str(ROOT / 'tool/perf/browser_load_driver.mjs'),
            str(port), app_url, str(fixture), str(EVIDENCE)],
            stdout=logs[2], stderr=logs[3])
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
        result = json.loads((EVIDENCE / 'driver-result.json').read_text())
        report['driverResult'] = result
        if (result.get('status') == 'observed' and report['driverExit'] == 0
                and browser.returncode == 0 and report['terminationRequested'] is None):
            report['status'] = 'observed'
        else:
            report['status'] = 'failed'
    except Exception as error:
        report['error'] = str(error)
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
            samples, sample_errors = read_rows(sampler.output)
            stage_file = EVIDENCE / 'browser-events.ndjson'
            stages, stage_errors = read_rows(stage_file)
            report['rawReadErrors'] = {'os-memory.ndjson': sample_errors,
                                       'browser-events.ndjson': stage_errors}
            report['memory'] = summarize_memory(samples, stages)
            if report['status'] == 'observed' and (
                    sample_errors or stage_errors or report['memory']['incompleteSampleCount']
                    or not report['memory']['afterClose']):
                report['status'] = 'inconclusive'
                report['error'] = 'Complete process-tree memory evidence missing'
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
        if server:
            server.shutdown()
            server.server_close()
        for stream in logs:
            stream.close()
        if profile_context:
            try:
                profile_context.cleanup()
            except OSError as error:
                report['profileCleanupError'] = type(error).__name__
                report['status'] = 'inconclusive'
        report['finishedUtc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        report['evidenceFiles'] = {p.name: describe(p) for p in sorted(EVIDENCE.iterdir())
                                   if p.is_file() and p != report_path}
        dump(report_path, report)
    print(json.dumps({'status': report['status'], 'error': report.get('error'),
                      'browserExit': report['browserExit']}))
    return 0 if report['status'] == 'observed' else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('scope', 'prepare', 'run'))
    arguments = parser.parse_args()
    if arguments.action == 'scope':
        scope()
    elif arguments.action == 'prepare':
        prepare()
    else:
        raise SystemExit(run())
