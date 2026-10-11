#!/usr/bin/env python3
"""CI-only official-package and single synthetic Heaptrack capture gate.

Never installs packages, downloads inputs, starts Flutter/Dart, opens a WLD, or
starts a product sample. A successful result authorizes no later experiment.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time
from urllib.parse import urlparse

from trace_contract import (ContractError, MAX_DECODED, MAX_RECORD, hexes,
                            interpreter_live_blocks, official_integer_total,
                            parse_raw, read_fixture, require, sha256, write_prefix)

PACKAGE_VERSION = '1.5.0+dfsg1-2ubuntu3'
PACKAGES = ('heaptrack', 'libheaptrack')
ROOT = Path(__file__).resolve().parent
MAX_COMPRESSED = 16 * 1024 * 1024
MAX_COMMAND_LOG = 2 * 1024 * 1024
MAX_ANALYSIS_FILE = 64 * 1024 * 1024
RUN_SECONDS = 10
PREFIX_SECONDS = 120
TOTAL_SECONDS = 650
COMMON_FLAGS = ['-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                '-fno-builtin-malloc', '-fno-builtin-free',
                '-fno-optimize-sibling-calls', '-rdynamic']


def save(path, value):
    path = Path(path)
    data = json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n'
    temporary = path.with_name(path.name + '.pending')
    with temporary.open('x') as stream:
        stream.write(data)
    os.replace(temporary, path)


def deb_fields(text):
    stanzas = []
    for chunk in re.split(r'\n\s*\n', text.strip()):
        fields = {}
        previous = None
        for line in chunk.splitlines():
            if line.startswith((' ', '\t')):
                require(previous is not None, 'Malformed package continuation')
                fields[previous] += '\n' + line
                continue
            key, separator, value = line.partition(':')
            require(bool(separator) and key not in fields, 'Malformed/duplicate package field')
            previous = key
            fields[key] = value.strip()
        if fields:
            stanzas.append(fields)
    return stanzas


def validate_policy(policy, version=PACKAGE_VERSION):
    """Bind the installed version to Ubuntu archive URLs and signed apt indexes.

    Apt's normal authentication is performed by the caller's apt-get update;
    this gate refuses an installed-only status or a third-party same-version
    source. The downloaded .deb is separately bound to apt's SHA256 record.
    """
    require(re.search(r'^\s*Installed:\s*' + re.escape(version) + r'\s*$', policy, re.M),
            'Installed version not the fixed official package')
    active = False
    origins = []
    for line in policy.splitlines():
        match = re.match(r'^\s*(?:\*\*\*\s+)?(\S+)\s+(\d+)\s*$', line)
        if match:
            active = match.group(1) == version
            continue
        if not active:
            continue
        match = re.match(r'^\s*\d+\s+(https?://\S+)\s+(\S+)\s+(\S+)\s+Packages\s*$', line)
        if not match:
            continue
        url, suite, architecture = match.groups()
        parsed = urlparse(url)
        hostname = parsed.hostname or ''
        trusted = (hostname in ('archive.ubuntu.com', 'security.ubuntu.com')
                   or hostname.endswith('.archive.ubuntu.com'))
        require(trusted and parsed.scheme in ('http', 'https')
                and parsed.path.rstrip('/') == '/ubuntu' and not parsed.username
                and not parsed.password and not parsed.query and not parsed.fragment,
                'Fixed package has a non-official Ubuntu archive origin')
        require(suite.split('/')[0] == 'noble' and architecture == 'amd64',
                'Package origin suite/architecture differs')
        origins.append({'url': url, 'suite': suite, 'architecture': architecture})
    require(bool(origins), 'No official Ubuntu noble package index binds installed version')
    return origins


def bounded_child():
    # Child-local execution/file limits, not persistent OS/security settings.
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_ANALYSIS_FILE, MAX_ANALYSIS_FILE))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def leader_exit_without_reaping(pid):
    """Keep the owned group leader waitable so its numeric PID cannot be reused."""
    info = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if info is None:
        return None
    return info.si_status if info.si_code == os.CLD_EXITED else -info.si_status


def cleanup_owned_group(process):
    """Signal only while our unreaped leader pins this freshly created group.

    Do not use Popen.poll before this: it reaps the leader, which can leave a
    detached descendant and can permit numeric PID reuse. After reaping, probes
    are read-only and no further signals are sent to a numeric group ID.
    """
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        if sig == signal.SIGTERM:
            time.sleep(0.15)
    process.wait(timeout=1)
    deadline = time.monotonic() + 1
    while True:
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)


def check_trace_caps(watch):
    if watch:
        for path in Path(watch).iterdir():
            require(not path.is_symlink(), 'Unexpected trace symlink')
            if path.is_file():
                require(path.stat().st_size <= MAX_COMPRESSED, 'Compressed trace cap')


class Runner:
    def __init__(self, output):
        self.output = output
        self.started = time.monotonic()
        self.manifest = {
            'schema': 'abc.heaptrack-preflight.v1', 'status': 'running',
            'startedAt': datetime.now(timezone.utc).isoformat(),
            'fixedPackageVersion': PACKAGE_VERSION, 'upstreamVersion': '1.5.0',
            'rawFormatVersion': 3, 'commands': [], 'profiledFixtureInvocations': 0,
            'applicationInvocations': 0, 'flutterInvocations': 0, 'wldOpened': False,
            'packageInstallationPerformed': False, 'networkDownloadsPerformed': False,
            'realSamplingAllowedByThisResult': False,
            'limits': {'profiledFixtureSeconds': RUN_SECONDS, 'authoredAllocatorOperations': 32,
                       'compressedTraceBytes': MAX_COMPRESSED, 'decodedTraceBytes': MAX_DECODED,
                       'recordBytes': MAX_RECORD, 'perPrefixAnalysisSeconds': PREFIX_SECONDS,
                       'wholePreflightSeconds': TOTAL_SECONDS, 'commandLogBytes': MAX_COMMAND_LOG},
            'sourceFiles': {p.name: {'sha256': sha256(p), 'bytes': p.stat().st_size}
                            for p in sorted(ROOT.iterdir()) if p.is_file() and p.suffix in ('.py', '.c', '.md', '.json')},
            'knownLimits': ['malloc-family events only', 'not an atomic whole-heap snapshot',
                            'profiler-internal recursion-guard allocations not censused',
                            'no direct mmap/private-pool/GPU coverage',
                            'native allocation provenance is not a retaining-owner graph'],
        }
        self.env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C',
                    'TMPDIR': str(output / 'tmp'), 'DEBUGINFOD_URLS': '',
                    'HEAPTRACK_ENABLE_DEBUGINFOD': '0'}
        (output / 'tmp').mkdir()
        (output / 'logs').mkdir()
        self.persist()

    def persist(self):
        save(self.output / 'manifest.json', self.manifest)

    def command(self, name, argv, seconds=30, stdin=None, stdout=None, watch=None):
        require(time.monotonic() - self.started < TOTAL_SECONDS, 'Whole preflight budget expired')
        seconds = min(seconds, TOTAL_SECONDS - (time.monotonic() - self.started))
        outpath = Path(stdout) if stdout else self.output / 'logs' / (name + '.stdout.txt')
        errpath = self.output / 'logs' / (name + '.stderr.txt')
        record = {'name': name, 'argv': [str(value) for value in argv],
                  'timeoutSeconds': seconds, 'stdout': str(outpath.relative_to(self.output)),
                  'stderr': str(errpath.relative_to(self.output))}
        self.manifest['commands'].append(record)
        self.persist()
        start = time.monotonic()
        process = None
        try:
            with outpath.open('xb') as out, errpath.open('xb') as err:
                source = Path(stdin).open('rb') if stdin else subprocess.DEVNULL
                try:
                    process = subprocess.Popen(record['argv'], cwd=self.output, env=self.env,
                                               stdin=source, stdout=out, stderr=err,
                                               start_new_session=True, preexec_fn=bounded_child)
                    record['ownedProcessGroup'] = process.pid
                    terminal_code = None
                    while terminal_code is None:
                        terminal_code = leader_exit_without_reaping(process.pid)
                        if terminal_code is not None:
                            break
                        require(time.monotonic() - start <= seconds, name + ': timeout')
                        require(errpath.stat().st_size <= MAX_COMMAND_LOG, name + ': stderr cap')
                        require(outpath.stat().st_size <= (MAX_ANALYSIS_FILE if stdout else MAX_COMMAND_LOG),
                                name + ': stdout cap')
                        check_trace_caps(watch)
                        time.sleep(0.02)
                    record['returnCode'] = terminal_code
                    require(record['returnCode'] == 0, name + ': nonzero exit')
                finally:
                    if stdin:
                        source.close()
        except Exception as error:
            record['error'] = str(error)
            raise
        finally:
            if process is not None:
                try:
                    record['ownedGroupCleanupVerified'] = cleanup_owned_group(process)
                except Exception as cleanup_error:
                    record['ownedGroupCleanupVerified'] = False
                    record['cleanupError'] = str(cleanup_error)
            record['elapsedSeconds'] = time.monotonic() - start
            for key, path in [('stdout', outpath), ('stderr', errpath)]:
                if path.is_file():
                    record[key + 'Sha256'] = sha256(path)
                    record[key + 'Bytes'] = path.stat().st_size
            self.persist()
        require(record.get('ownedGroupCleanupVerified') is True, name + ': owned process group remains')
        # A fast child can exit before a polling iteration checked its output.
        require(errpath.stat().st_size <= MAX_COMMAND_LOG and
                outpath.stat().st_size <= (MAX_ANALYSIS_FILE if stdout else MAX_COMMAND_LOG),
                name + ': final output cap')
        check_trace_caps(watch)
        return outpath, errpath

    def text(self, name, argv, seconds=30):
        out, err = self.command(name, argv, seconds)
        return out.read_text(errors='strict'), err.read_text(errors='strict')


def package_gate(runner, deb_dir):
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line)
    require(release.get('ID', '').strip('"') == 'ubuntu'
            and release.get('VERSION_ID', '').strip('"') == '24.04', 'Requires Ubuntu 24.04 CI')
    arch, _ = runner.text('architecture', ['/usr/bin/dpkg', '--print-architecture'])
    require(arch.strip() == 'amd64', 'Requires Ubuntu amd64 CI')
    trusted, paths = {}, {}
    candidates = list(deb_dir.glob('*.deb'))
    require(len(candidates) == 2 and all(p.is_file() and not p.is_symlink() for p in candidates),
            'Exactly two ordinary fixed-package .deb archives required')
    extracted_root = runner.output / 'package-bytes'
    extracted_root.mkdir()
    for package in PACKAGES:
        installed, _ = runner.text(package + '-installed', ['/usr/bin/dpkg-query', '-W',
                '-f=${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\t${Status}\n', package])
        fields = installed.strip().split('\t')
        require(fields == [package, PACKAGE_VERSION, 'amd64', 'heaptrack', PACKAGE_VERSION, 'install ok installed'],
                package + ': installed binary/source identity differs')
        policy, _ = runner.text(package + '-policy', ['/usr/bin/apt-cache', 'policy', package])
        origins = validate_policy(policy)
        shown, _ = runner.text(package + '-apt-metadata',
                              ['/usr/bin/apt-cache', 'show', package + '=' + PACKAGE_VERSION])
        metadata = [r for r in deb_fields(shown) if r.get('Package') == package
                    and r.get('Version') == PACKAGE_VERSION and r.get('Architecture') == 'amd64']
        require(bool(metadata), package + ': apt package metadata absent')
        digests = {row.get('SHA256') for row in metadata}
        require(len(digests) == 1 and re.fullmatch(r'[0-9a-f]{64}', next(iter(digests)) or ''),
                package + ': apt SHA256 missing or ambiguous')
        expected_hash = next(iter(digests))
        archives = [p for p in candidates if sha256(p) == expected_hash]
        require(len(archives) == 1, package + ': archive not bound to apt SHA256')
        archive = archives[0]
        control, _ = runner.text(package + '-archive-control', ['/usr/bin/dpkg-deb', '-f', str(archive)])
        control = deb_fields(control)
        require(len(control) == 1 and control[0].get('Package') == package
                and control[0].get('Version') == PACKAGE_VERSION and control[0].get('Architecture') == 'amd64',
                package + ': archive identity differs')
        destination = extracted_root / package
        runner.command(package + '-extract-verified', ['/usr/bin/dpkg-deb', '-x', str(archive), str(destination)])
        listing, _ = runner.text(package + '-installed-files', ['/usr/bin/dpkg-query', '-L', package])
        matched_files = {}
        for name in listing.splitlines():
            installed_path = Path(name)
            if not name.startswith('/usr/'):
                continue
            extracted = destination / name.lstrip('/')
            if not extracted.is_file():
                continue
            require(installed_path.is_file() and sha256(installed_path) == sha256(extracted),
                    package + ': installed file differs from authenticated .deb: ' + name)
            matched_files[name] = {'sha256': sha256(installed_path), 'bytes': installed_path.stat().st_size}
            if installed_path.name in ('heaptrack', 'heaptrack_print', 'heaptrack_interpret', 'heaptrack_env'):
                require(installed_path.name not in paths, 'Ambiguous official tool path')
                paths[installed_path.name] = str(installed_path)
            if installed_path.name.startswith('libheaptrack_preload.so') and not installed_path.is_symlink():
                require('preload' not in paths, 'Ambiguous preload library')
                paths['preload'] = str(installed_path)
        require(bool(matched_files), package + ': no verified installed files')
        trusted[package] = {'version': PACKAGE_VERSION, 'architecture': 'amd64', 'origins': origins,
                            'archiveName': archive.name, 'archiveSha256': expected_hash,
                            'sourcePackage': control[0].get('Source', package),
                            'installedFiles': matched_files}
    require({'heaptrack', 'heaptrack_print', 'heaptrack_interpret', 'heaptrack_env', 'preload'} <= set(paths),
            'Complete official recorder/interpreter/print/preload tools unavailable')
    version, _ = runner.text('heaptrack-version', [paths['heaptrack'], '--version'])
    require(version.strip() == 'heaptrack 1.5.0', 'Heaptrack executable version differs')
    pversion, _ = runner.text('heaptrack-print-version', [paths['heaptrack_print'], '--version'])
    require(pversion.strip() == 'heaptrack_print 1.5.0', 'Heaptrack printer version differs')
    help_text, _ = runner.text('heaptrack-help', [paths['heaptrack'], '--help'])
    require('--raw' in help_text and '--record-only' in help_text, 'Required raw recorder CLI absent')
    help_text, _ = runner.text('heaptrack-print-help', [paths['heaptrack_print'], '--help'])
    require(all(flag in help_text for flag in ('flamegraph-cost-type', 'disable-builtin-suppressions',
                                              'disable-embedded-suppressions', 'merge-backtraces')),
            'Required official analysis CLI absent')
    runner.manifest['packageIdentity'] = trusted
    runner.manifest['toolPaths'] = paths
    runner.manifest['packageIdentityPassed'] = True
    runner.persist()
    return paths


def symbol_inventory(runner, binary):
    output, _ = runner.text('contract-dynamic-symbols', ['/usr/bin/nm', '-D', '-S', '--defined-only', str(binary)])
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4 and (fields[3].startswith('abc_fixture_') or fields[3] in
                                ('q0_begin', 'q0_end', 'q7_begin', 'q7_end')):
            require(fields[2] in ('T', 't'), 'Fixture symbol is not executable text')
            start, size = int(fields[0], 16), int(fields[1], 16)
            require(size > 0, 'Fixture symbol has no address extent')
            symbols[fields[3]] = (start, size)
    required = {'q0_begin', 'q0_end', 'q7_begin', 'q7_end', 'abc_fixture_malloc', 'abc_fixture_calloc',
                'abc_fixture_grow', 'abc_fixture_realloc_failure', 'abc_fixture_realloc_zero'}
    require(required <= set(symbols), 'Fixture required exported symbols absent')
    header, _ = runner.text('contract-elf-header', ['/usr/bin/readelf', '-h', str(binary)])
    require('Advanced Micro Devices X86-64' in header and ('DYN (' in header or 'EXEC (' in header),
            'Contract is not a supported x86-64 ELF executable')
    runner.text('contract-elf-notes', ['/usr/bin/readelf', '-n', str(binary)])
    runner.text('contract-elf-sections', ['/usr/bin/readelf', '-SW', str(binary)])
    save(runner.output / 'symbols.json', {name: {'virtualAddress': values[0], 'size': values[1]}
                                          for name, values in sorted(symbols.items())})
    return symbols


def decode_raw(runner, compressed, decoded):
    require(compressed.stat().st_size <= MAX_COMPRESSED, 'Compressed trace cap exceeded')
    if compressed.name.endswith('.gz'):
        with gzip.open(compressed, 'rb') as source, decoded.open('xb') as out:
            size = 0
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                size += len(block)
                require(size <= MAX_DECODED, 'Decoded trace cap exceeded')
                out.write(block)
    elif compressed.name.endswith('.zst'):
        require(Path('/usr/bin/zstd').is_file(), 'zstd recorded trace without distribution decoder')
        runner.command('decode-raw', ['/usr/bin/zstd', '-d', '--stdout', str(compressed)],
                       seconds=30, stdout=decoded)
    else:
        raise ContractError('Unexpected raw compression suffix')
    require(0 < decoded.stat().st_size <= MAX_DECODED, 'Decoded trace absent or oversized')


def check_official_diagnostics(text):
    require(not re.search(r'(?i)(warning|error|failed to|damaged|corrupt|RTLD_DEEPBIND|unexpected)', text),
            'Official profiler/interpreter warning or error; target semantics/coverage not accepted')


def run(runner, deb_dir):
    tools = package_gate(runner, deb_dir)
    binary = runner.output / 'native_contract'
    runner.command('compile-contract', ['/usr/bin/cc', *COMMON_FLAGS, str(ROOT / 'native_contract.c'),
                                       '-o', str(binary)], seconds=60)
    symbols = symbol_inventory(runner, binary)
    runner.manifest['fixtureBinary'] = {'sha256': sha256(binary), 'bytes': binary.stat().st_size}
    raw_dir = runner.output / 'raw'
    raw_dir.mkdir()
    runner.manifest['profiledFixtureInvocations'] = 1
    runner.persist()
    stdout, stderr = runner.command('profile-contract', [tools['heaptrack'], '--raw', '--record-only',
                                    '-o', str(raw_dir / 'contract'), str(binary)],
                                   seconds=RUN_SECONDS, watch=raw_dir)
    check_official_diagnostics(stderr.read_text())
    output_lines = stdout.read_text().splitlines()
    fixture_lines = [line for line in output_lines if line.startswith('{')]
    check_official_diagnostics('\n'.join(line for line in output_lines if not line.startswith('{')))
    require(bool(fixture_lines), 'Native fixture JSONL missing')
    fixture_path = runner.output / 'fixture.jsonl'
    with fixture_path.open('x') as out:
        out.write('\n'.join(fixture_lines) + '\n')
    fixture = read_fixture(fixture_path)
    require(type(fixture['metadata'].get('hostPid')) is int and fixture['metadata']['hostPid'] > 0,
            'Fixture PID identity missing')
    compressed = list(raw_dir.glob('contract.raw.*'))
    require(len(compressed) == 1 and compressed[0].is_file() and not compressed[0].is_symlink(),
            'Exactly one complete raw capture required')
    decoded = raw_dir / 'contract.raw'
    decode_raw(runner, compressed[0], decoded)
    runner.manifest['rawCapture'] = {'file': compressed[0].name, 'sha256': sha256(compressed[0]),
                                   'bytes': compressed[0].stat().st_size}
    accounting = parse_raw(decoded, fixture, binary, symbols)
    save(runner.output / 'raw-accounting.json', accounting)
    runner.manifest['rawAccounting'] = {'valid': accounting['valid'], 'issues': accounting['issues']}
    runner.persist()
    analysis = runner.output / 'prefixes'
    analysis.mkdir()
    comparisons = []
    # Even when observed realloc semantics mismatch, retain the four official
    # prefix analyses as failure evidence. No second profiled process is started.
    for boundary in accounting['boundaries']:
        start = time.monotonic()
        folder = analysis / boundary['id']
        folder.mkdir()
        prefix = folder / 'input.raw'
        prefix_identity = write_prefix(decoded, boundary, prefix)
        interpreted = folder / 'interpreted.txt'
        _, err = runner.command('interpret-' + boundary['id'], [tools['heaptrack_interpret']],
                                seconds=PREFIX_SECONDS, stdin=prefix, stdout=interpreted)
        diagnostic = err.read_text()
        check_official_diagnostics(diagnostic)
        blocks = interpreter_live_blocks(diagnostic)
        integer_path = folder / 'live-by-stack.txt'
        remaining = PREFIX_SECONDS - (time.monotonic() - start)
        require(remaining > 0, 'Per-prefix analysis budget expired')
        _, err = runner.command('print-' + boundary['id'], [tools['heaptrack_print'],
                '--disable-builtin-suppressions', '--disable-embedded-suppressions',
                '--merge-backtraces=false', '--print-peaks=false', '--print-allocators=false',
                '--print-temporary=false', '--print-leaks=false', '--flamegraph-cost-type=leaked',
                '--print-flamegraph=' + str(integer_path), str(interpreted)], seconds=remaining)
        check_official_diagnostics(err.read_text())
        require(integer_path.is_file() and integer_path.stat().st_size <= MAX_ANALYSIS_FILE,
                'Official integer export missing/oversized')
        integer = official_integer_total(integer_path)
        comparison = {'id': boundary['id'], 'inputPrefix': prefix_identity,
                      'recordOrdinal': boundary['recordOrdinal'], 'byteOffset': boundary['byteOffset'],
                      'accountedLiveBytes': boundary['liveBytes'], 'officialLiveBytes': integer['liveBytes'],
                      'accountedLiveBlocks': boundary['liveBlocks'], 'officialLiveBlocks': blocks,
                      'officialIntegerExport': integer,
                      'matches': integer['liveBytes'] == boundary['liveBytes'] and blocks == boundary['liveBlocks']}
        comparisons.append(comparison)
        save(runner.output / 'official-comparisons.json', comparisons)
    require(len(comparisons) == 4 and all(row['matches'] for row in comparisons),
            'Official/accountant exact totals or required four-cut count differ')
    require(accounting['valid'], 'Profiler failed native semantic oracle; real sampling remains stopped')
    runner.manifest['contractPassed'] = True
    runner.manifest['status'] = 'passed-synthetic-only'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--deb-dir', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    require(not args.output.is_symlink() and not output.exists(), 'Output must be a new isolated directory')
    require(args.deb_dir.is_dir() and not args.deb_dir.is_symlink(), 'Verified package directory unavailable')
    output.mkdir(parents=True)
    runner = Runner(output)
    result = 1
    try:
        run(runner, args.deb_dir.resolve())
        result = 0
    except Exception as error:
        runner.manifest['status'] = 'failed-closed'
        runner.manifest['failure'] = {'type': type(error).__name__, 'message': str(error)}
        runner.manifest['contractPassed'] = False
    finally:
        runner.manifest['finishedAt'] = datetime.now(timezone.utc).isoformat()
        runner.manifest['elapsedSeconds'] = time.monotonic() - runner.started
        runner.manifest['evidence'] = {
            str(path.relative_to(output)): {'sha256': sha256(path), 'bytes': path.stat().st_size}
            for path in sorted(output.rglob('*')) if path.is_file() and not path.is_symlink()
            and path.name not in ('manifest.json', 'manifest.json.pending')}
        runner.persist()
    print(json.dumps({'status': runner.manifest['status'], 'profiledFixtureInvocations':
                      runner.manifest['profiledFixtureInvocations'], 'applicationInvocations': 0,
                      'contractPassed': runner.manifest.get('contractPassed', False),
                      'failure': runner.manifest.get('failure')}))
    return result


if __name__ == '__main__':
    raise SystemExit(main())
