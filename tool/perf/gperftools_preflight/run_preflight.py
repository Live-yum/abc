#!/usr/bin/env python3
"""CI-only official-package and single synthetic gperftools capture gate.

Never installs packages, downloads inputs, starts Flutter/Dart, opens a WLD, or
starts a product sample. A successful result authorizes no later experiment.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import signal
import stat
import subprocess
import time
from urllib.parse import urlparse

from profile_contract import (ContractError, MAX_RECORD, MAX_PROFILE, MAX_DECODED,
                              require, sha256)

PACKAGE_VERSION = '2.15-3build1'
PACKAGES = ('libgoogle-perftools4t64', 'libgoogle-perftools-dev', 'google-perftools')
PACKAGE_ARCH = {'libgoogle-perftools4t64': 'amd64', 'libgoogle-perftools-dev': 'amd64', 'google-perftools': 'all'}
PACKAGE_COMPONENT = {'libgoogle-perftools4t64': 'main', 'libgoogle-perftools-dev': 'main', 'google-perftools': 'universe'}
REQUIRED_PATHS = {
    'preload': ('libgoogle-perftools4t64', '/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16'),
    'header': ('libgoogle-perftools-dev', '/usr/include/gperftools/heap-profiler.h'),
    'pprof': ('google-perftools', '/usr/bin/google-pprof'),
}
ROOT = Path(__file__).resolve().parent
MAX_COMPRESSED = 16 * 1024 * 1024
MAX_COMMAND_LOG = 2 * 1024 * 1024
MAX_ANALYSIS_FILE = 64 * 1024 * 1024
RUN_SECONDS = 10
PREFIX_SECONDS = 120
TOTAL_SECONDS = 650
COMMON_FLAGS = ['-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                '-fno-builtin-malloc', '-fno-builtin-free', '-fno-builtin-calloc', '-fno-builtin-realloc',
                '-fno-pie', '-no-pie',
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


MIRROR_URI = 'mirror+file:/etc/apt/apt-mirrors.txt'
MIRROR_PATH = '/etc/apt/apt-mirrors.txt'
SOURCE_PATH = '/etc/apt/sources.list.d/ubuntu.sources'
KEYRING_PATH = '/usr/share/keyrings/ubuntu-archive-keyring.gpg'
MAX_APT_TEXT = 4096


def official_archive_url(url):
    parsed = urlparse(url)
    hostname = parsed.hostname or ''
    trusted = (hostname in ('archive.ubuntu.com', 'security.ubuntu.com')
               or hostname.endswith('.archive.ubuntu.com'))
    require(trusted and parsed.scheme in ('http', 'https')
            and parsed.path.rstrip('/') == '/ubuntu' and not parsed.username
            and not parsed.password and not parsed.query and not parsed.fragment
            and not parsed.params and parsed.port is None and not any(c.isspace() for c in url),
            'Fixed package has a non-official Ubuntu archive origin')
    return url.rstrip('/')


def observed_identity(info, directory=False):
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            'APT source path is not an ordinary directory/file')
    return {'device': info.st_dev, 'inode': info.st_ino, 'uid': info.st_uid,
            'gid': info.st_gid, 'mode': oct(stat.S_IMODE(info.st_mode)), 'bytes': info.st_size,
            'type': 'directory' if directory else 'regular-file', 'symlink': False,
            'groupOrWorldWritable': bool(info.st_mode & 0o022)}


def protected_identity(info, directory=False):
    require(info.st_uid == 0 and not info.st_mode & 0o022,
            'APT source path is not root-owned and protected from non-root writes')
    return observed_identity(info, directory)


def fixed_path_identity(path, info, directory=False):
    require(path in (MIRROR_PATH, SOURCE_PATH, KEYRING_PATH), 'Unexpected APT source path')
    return (observed_identity if path == KEYRING_PATH else protected_identity)(info, directory)


def read_protected_apt_file(path, limit=MAX_APT_TEXT):
    # Only caller-selected fixed source/keyring paths; never open a URI-supplied path.
    require(path in (MIRROR_PATH, SOURCE_PATH, KEYRING_PATH), 'Unexpected APT source path')
    # The immutable mirror/source rule does not apply to the official image's
    # keyring tree: its documented bootstrap makes /usr/share writable.
    def identity_check(info, directory=False):
        return fixed_path_identity(path, info, directory)
    descriptors, identities = [], []
    try:
        descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(descriptor)
        identities.append({'path': '/', **identity_check(os.fstat(descriptor), directory=True)})
        components = Path(path).parts[1:]
        for index, component in enumerate(components):
            is_directory = index < len(components) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW | (os.O_DIRECTORY if is_directory else 0)
            descriptor = os.open(component, flags, dir_fd=descriptor)
            descriptors.append(descriptor)
            identities.append({'path': '/' + '/'.join(components[:index + 1]),
                               **identity_check(os.fstat(descriptor), directory=is_directory)})
        before = os.fstat(descriptor)
        require(before.st_size <= limit, 'APT source file exceeds byte cap')
        data = os.read(descriptor, limit + 1)
        require(len(data) <= limit and not os.read(descriptor, 1), 'APT source file exceeds byte cap')
        after = os.fstat(descriptor)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                'APT source file changed while reading')
        require(str(Path(path).resolve(strict=True)) == path
                and (os.stat(path).st_dev, os.stat(path).st_ino) == (after.st_dev, after.st_ino),
                'APT source path identity changed')
        return data, {'path': path, 'sha256': hashlib.sha256(data).hexdigest(),
                      'bytes': len(data), 'pathIdentities': identities}
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def validate_keyring_package(owner, installed, checksums, data):
    require(owner.strip() == 'ubuntu-keyring: ' + KEYRING_PATH,
            'Fixed keyring is not owned by the ubuntu-keyring package')
    fields = installed.strip().split('\t')
    require(len(fields) == 4 and fields[0] == 'ubuntu-keyring' and bool(fields[1])
            and fields[2] == 'all' and fields[3] == 'install ok installed',
            'Ubuntu keyring package identity differs')
    wanted = KEYRING_PATH.lstrip('/')
    rows = []
    for line in checksums.splitlines():
        values = line.split()
        if len(values) == 2 and values[1] == wanted:
            rows.append(values[0])
    require(len(rows) == 1 and re.fullmatch(r'[0-9a-f]{32}', rows[0]) is not None,
            'Fixed keyring package checksum absent or ambiguous')
    # dpkg's installed md5sums is a consistency check under the official runner
    # bootstrap premise. It is not independent signature/authenticity evidence.
    require(hashlib.md5(data, usedforsecurity=False).hexdigest() == rows[0],
            'Fixed keyring bytes differ from ubuntu-keyring installed checksum')
    return {'package': fields[0], 'version': fields[1], 'architecture': fields[2],
            'installedMd5': rows[0], 'sha256': hashlib.sha256(data).hexdigest(),
            'bytes': len(data), 'installedBytesMatch': True,
            'trustBasis': 'official runner bootstrap and previously reviewed workflow only; dpkg MD5 is a consistency check, not independent signature verification'}


def verify_bootstrap_keyring(runner):
    data, identity = read_protected_apt_file(KEYRING_PATH, 1024 * 1024)
    runner.manifest['aptSourceFiles']['keyring'] = identity
    runner.persist()
    owner, _ = runner.text('keyring-package-owner', ['/usr/bin/dpkg-query', '-S', KEYRING_PATH])
    installed, _ = runner.text('keyring-package-installed', ['/usr/bin/dpkg-query', '-W',
            '-f=${Package}\t${Version}\t${Architecture}\t${Status}\n', 'ubuntu-keyring'])
    checksums, _ = runner.text('keyring-package-checksums', ['/usr/bin/dpkg-query',
                              '--control-show', 'ubuntu-keyring', 'md5sums'])
    identity['packageConsistency'] = validate_keyring_package(owner, installed, checksums, data)
    runner.persist()
    return identity


def parse_mirror_list(data):
    require(len(data) <= MAX_APT_TEXT, 'Mirror list exceeds byte cap')
    lines = data.decode('ascii').splitlines()
    require(0 < len(lines) <= 64, 'Mirror list exceeds line cap')
    mirrors = []
    for line in lines:
        if not line or line.startswith('#'):
            continue
        # Exact runner form only: one literal TAB and priority:1, :2 or :3.
        match = re.fullmatch(r'(https?://[^\s]+)\tpriority:([123])', line)
        require(match is not None, 'Unsupported mirror list entry/metadata')
        url, priority = match.groups()
        mirrors.append({'url': official_archive_url(url), 'priority': int(priority)})
    require(len(mirrors) == 3 and {r['priority'] for r in mirrors} == {1, 2, 3}
            and len({r['url'] for r in mirrors}) == 3, 'Expected three distinct runner mirrors/priorities')
    return mirrors


def validate_source_stanza(text):
    matching = []
    text = '\n'.join(line for line in text.splitlines() if not line.startswith('#'))
    # APT 2.8 Sourcesentry suffix is the 1-based Deb822 stanza, not a line number.
    for index, stanza in enumerate(deb_fields(text), 1):
        if MIRROR_URI not in stanza.get('URIs', '').split() or 'noble' not in stanza.get('Suites', '').split():
            continue
        require(stanza.get('Types') == 'deb' and stanza.get('URIs') == MIRROR_URI
                and set(PACKAGE_COMPONENT.values()) <= set(stanza.get('Components', '').split())
                and stanza.get('Signed-By') == KEYRING_PATH
                and stanza.get('Architectures', 'amd64') == 'amd64'
                and stanza.get('Enabled', 'yes') == 'yes', 'Fixed Ubuntu source stanza identity differs')
        forbidden = {'trusted', 'allow-insecure', 'allow-weak', 'allow-downgrade-to-insecure',
                     'check-valid-until', 'check-date', 'signed-by-add', 'signed-by-remove'}
        require(not any(key.lower() in forbidden for key in stanza), 'Ubuntu source has a trust override')
        matching.append({'sourcesEntry': SOURCE_PATH + ':' + str(index), 'stanza': stanza})
    require(len(matching) == 1, 'Unique fixed Ubuntu noble source stanza absent')
    return matching[0]


def validate_policy(policy, version=PACKAGE_VERSION, mirrors=None, component="main"):
    require(re.search(r'^\s*Installed:\s*' + re.escape(version) + r'\s*$', policy, re.M),
            'Installed version not the fixed official package')
    active, origins = False, []
    for line in policy.splitlines():
        match = re.match(r'^\s*(?:\*\*\*\s+)?(\S+)\s+(\d+)\s*$', line)
        if match:
            active = match.group(1) == version
            continue
        if not active:
            continue
        match = re.match(r'^\s*\d+\s+(\S+)\s+(\S+)\s+(\S+)\s+Packages\s*$', line)
        if not match:
            continue
        url, suite, architecture = match.groups()
        if url == MIRROR_URI:
            require(bool(mirrors), 'Fixed mirror source lacks verified list evidence')
        else:
            official_archive_url(url)
        require(suite == 'noble/' + component and architecture == 'amd64',
                'Package origin suite/architecture differs')
        origins.append({'url': url, 'suite': suite, 'architecture': architecture})
    require(bool(origins), 'No official Ubuntu noble package index binds installed version')
    return origins


def validate_download_log(text, mirrors):
    require(len(text.encode()) <= 65536, 'APT download log exceeds byte cap')
    rows = {}
    for line in text.splitlines():
        if not any(re.search(r'\b' + re.escape(package) + r'\s+(?:amd64|all)\s', line) for package in PACKAGES):
            continue
        match = re.fullmatch(r'Get:\d+ (https?://\S+) (\S+) (\S+) (\S+) (\S+) (\S+) \[[^\]\r\n]+\]', line)
        require(match is not None, 'Malformed package download evidence')
        url, suite, index_arch, package, architecture, version = match.groups()
        url = official_archive_url(url)
        require(package in PACKAGES and url in {r['url'] for r in mirrors}
                and suite == 'noble/' + PACKAGE_COMPONENT[package] and index_arch == 'amd64'
                and architecture == PACKAGE_ARCH[package] and version == PACKAGE_VERSION,
                'Package download does not match verified mirrors/fixed identity')
        require(package not in rows, 'Duplicate package download evidence')
        rows[package] = {'url': url, 'suite': suite, 'architecture': architecture, 'version': version}
    require(set(rows) == set(PACKAGES), 'All fixed package download records required')
    return rows


def validate_index_targets(text, source, component):
    require(component in set(PACKAGE_COMPONENT.values()), 'Unexpected fixed package component')
    # Runner images have unrelated repositories sharing suite/component names.
    # First select the exact already-verified Ubuntu source tuple, then require
    # a unique component candidate. No third-party Origin/Label claim can select
    # a row; every original identity/trust/format check still applies afterward.
    matches = [row for row in deb_fields(text)
               if row.get('Repo-URI', '').rstrip('/') == MIRROR_URI
               and row.get('Sourcesentry') == source['sourcesEntry']
               and row.get('Component') == component]
    require(len(matches) == 1, 'Unique fixed Ubuntu source/component index absent or duplicated')
    row = matches[0]
    require(row.get('Release') == 'noble' and row.get('Suite') == 'noble'
            and row.get('Component') == component and row.get('Architecture') == 'amd64'
            and row.get('Identifier') == 'Packages' and row.get('Target-Of') == 'deb'
            and row.get('Trusted') == 'yes' and row.get('Origin') == 'Ubuntu'
            and row.get('Label') == 'Ubuntu' and row.get('Codename') == 'noble',
            'Package index is not the authenticated fixed Ubuntu source')
    filename = Path(row.get('Filename', ''))
    require(filename.is_absolute() and filename.parent == Path('/var/lib/apt/lists')
            and row.get('MetaKey') == component + '/binary-amd64/Packages', 'Unexpected package index path')
    return row


def bind_archive(candidates, metadata, package):
    digests = {row.get('SHA256') for row in metadata}
    require(len(digests) == 1 and re.fullmatch(r'[0-9a-f]{64}', next(iter(digests)) or ''),
            package + ': apt SHA256 missing or ambiguous')
    expected_hash = next(iter(digests))
    archives = [p for p in candidates if sha256(p) == expected_hash]
    require(len(archives) == 1, package + ': archive not bound to apt SHA256')
    return archives[0], expected_hash


def validate_redirect_overrides(text):
    for line in text.splitlines():
        require(re.fullmatch(r"APT_REDIRECT_[0-9]+='(?:false|no|0)'", line) is not None,
                'APT redirect configuration may override command-local prohibition')


def verified_mirror_evidence(runner, download_log):
    data, identity = read_protected_apt_file(MIRROR_PATH)
    (runner.output / 'apt-mirrors.txt').write_bytes(data)
    runner.manifest['aptSourceFiles'] = {'mirrorList': identity}
    runner.persist()
    mirrors = parse_mirror_list(data)
    source_data, source_identity = read_protected_apt_file(SOURCE_PATH)
    (runner.output / 'ubuntu.sources').write_bytes(source_data)
    runner.manifest['aptSourceFiles']['sourceFile'] = source_identity
    runner.persist()
    source = validate_source_stanza(source_data.decode('utf-8'))
    keyring_identity = verify_bootstrap_keyring(runner)
    require(download_log.is_file() and not download_log.is_symlink()
            and download_log.stat().st_size <= 65536, 'APT download evidence missing/oversized')
    download_data = download_log.read_bytes()
    downloads = validate_download_log(download_data.decode('utf-8'), mirrors)
    (runner.output / 'apt-download.log').write_bytes(download_data)
    # Query only nonsensitive flags; never dump all configuration or proxy credentials.
    keys = set()
    for scheme in ('http', 'https'):
        for host in {urlparse(row['url']).hostname for row in mirrors}:
            keys.add(f'Acquire::{scheme}::{host}::AllowRedirect')
            for binary in ('http', 'https'):
                keys.add(f'Binary::{binary}::Acquire::{scheme}::{host}::AllowRedirect')
        for binary in ('http', 'https'):
            keys.add(f'Binary::{binary}::Acquire::{scheme}::AllowRedirect')
    arguments = [item for index, key in enumerate(sorted(keys)) for item in (f'APT_REDIRECT_{index}', key)]
    configured, _ = runner.text('apt-redirect-overrides', ['/usr/bin/apt-config', 'shell', *arguments])
    validate_redirect_overrides(configured)
    indexes, _ = runner.text('apt-index-targets', ['/usr/bin/apt-get', '-o', 'Dir::Cache::pkgcache=',
            '-o', 'Dir::Cache::srcpkgcache=', 'indextargets', 'Identifier: Packages',
            'Release: noble', 'Architecture: amd64'])
    index = {component: validate_index_targets(indexes, source, component)
             for component in sorted(set(PACKAGE_COMPONENT.values()))}
    evidence = {'mirrorList': identity, 'mirrors': mirrors, 'sourceFile': source_identity,
                'source': source, 'keyring': keyring_identity, 'downloads': downloads, 'index': index,
                'authentication': 'ordinary workflow apt-get update; Trusted is cached state, not independent verification',
                'redirects': 'workflow command-local HTTP/HTTPS prohibition; no enabling host/binary override'}
    runner.manifest['aptMirrorEvidence'] = evidence
    runner.persist()
    return evidence


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
        size = 0
        entries = list(Path(watch).iterdir())
        require(len(entries) <= 5, 'Unexpected extra profile file')
        for path in entries:
            require(path.is_file() and not path.is_symlink(), 'Unexpected profile file type')
            require(path.stat().st_size < MAX_PROFILE, 'Actual profiler 1 MiB buffer cap')
            size += path.stat().st_size
        require(size <= MAX_COMPRESSED, 'Aggregate profile byte cap')


class Runner:
    def __init__(self, output):
        self.output = output
        self.started = time.monotonic()
        self.manifest = {
            'schema': 'abc.gperftools-preflight.v1', 'status': 'running',
            'startedAt': datetime.now(timezone.utc).isoformat(),
            'fixedPackageVersion': PACKAGE_VERSION, 'upstreamVersion': '2.15',
            'profileFormat': 'heapprofile', 'commands': [], 'profiledFixtureInvocations': 0,
            'applicationInvocations': 0, 'flutterInvocations': 0, 'wldOpened': False,
            'packageInstallationPerformed': False, 'networkDownloadsPerformed': False,
            'realSamplingAllowedByThisResult': False,
            'limits': {'profiledFixtureSeconds': RUN_SECONDS, 'authoredAllocatorOperations': 32,
                       'aggregateProfileBytes': MAX_COMPRESSED, 'singleProfileBytesExclusive': MAX_PROFILE, 'decodedTraceBytes': MAX_DECODED,
                       'recordBytes': MAX_RECORD, 'perProfileAnalysisSeconds': PREFIX_SECONDS,
                       'wholePreflightSeconds': TOTAL_SECONDS, 'commandLogBytes': MAX_COMMAND_LOG},
            'sourceFiles': {p.name: {'sha256': sha256(p), 'bytes': p.stat().st_size}
                            for p in sorted(ROOT.iterdir()) if p.is_file() and p.suffix in ('.py', '.c', '.md', '.json', '.txt')},
            'knownLimits': ['malloc-family events only', 'allocator-replacing tcmalloc provenance; cannot reconcile original glibc +72.729 MiB', 'synchronous hooks snapshot of single-thread fixture only',
                            'profiler-internal recursion-guard allocations not censused',
                            'no direct mmap/private-pool/GPU coverage',
                            'native allocation provenance is not a retaining-owner graph'],
        }
        self.env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'LANG': 'C',
                    'TMPDIR': str(output / 'tmp'), 'DEBUGINFOD_URLS': '',
                    'PPROF_TMPDIR': str(output / 'tmp')}
        (output / 'tmp').mkdir()
        (output / 'logs').mkdir()
        self.persist()

    def persist(self):
        save(self.output / 'manifest.json', self.manifest)

    def command(self, name, argv, seconds=30, stdin=None, stdout=None, watch=None, target_env=None):
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
                    process = subprocess.Popen(record['argv'], cwd=self.output, env=(self.env if target_env is None else target_env),
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


def package_gate(runner, deb_dir, download_log):
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines()
                   if '=' in line)
    require(release.get('ID', '').strip('"') == 'ubuntu'
            and release.get('VERSION_ID', '').strip('"') == '24.04', 'Requires Ubuntu 24.04 CI')
    arch, _ = runner.text('architecture', ['/usr/bin/dpkg', '--print-architecture'])
    require(arch.strip() == 'amd64', 'Requires Ubuntu amd64 CI')
    mirror_evidence = verified_mirror_evidence(runner, download_log)
    trusted, paths = {}, {}
    candidates = list(deb_dir.glob('*.deb'))
    require(len(candidates) == len(PACKAGES) and all(p.is_file() and not p.is_symlink() for p in candidates),
            'Exactly three ordinary fixed-package .deb archives required')
    extracted_root = runner.output / 'package-bytes'
    extracted_root.mkdir()
    for package in PACKAGES:
        installed, _ = runner.text(package + '-installed', ['/usr/bin/dpkg-query', '-W',
                '-f=${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\t${Status}\n', package])
        fields = installed.strip().split('\t')
        require(fields == [package, PACKAGE_VERSION, PACKAGE_ARCH[package], 'google-perftools', PACKAGE_VERSION, 'install ok installed'],
                package + ': installed binary/source identity differs')
        policy, _ = runner.text(package + '-policy', ['/usr/bin/apt-cache', 'policy', package])
        origins = validate_policy(policy, mirrors=mirror_evidence['mirrors'], component=PACKAGE_COMPONENT[package])
        require(all(row['url'] == MIRROR_URI for row in origins), 'Unexpected non-mirror policy source in this fixed runner contract')
        shown, _ = runner.text(package + '-apt-metadata',
                              ['/usr/bin/apt-cache', 'show', package + '=' + PACKAGE_VERSION])
        metadata = [r for r in deb_fields(shown) if r.get('Package') == package
                    and r.get('Version') == PACKAGE_VERSION and r.get('Architecture') == PACKAGE_ARCH[package]]
        require(bool(metadata), package + ': apt package metadata absent')
        archive, expected_hash = bind_archive(candidates, metadata, package)
        control, _ = runner.text(package + '-archive-control', ['/usr/bin/dpkg-deb', '-f', str(archive)])
        control = deb_fields(control)
        require(len(control) == 1 and control[0].get('Package') == package
                and control[0].get('Version') == PACKAGE_VERSION and control[0].get('Architecture') == PACKAGE_ARCH[package],
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
            for role, (wanted_package, wanted_path) in REQUIRED_PATHS.items():
                if package == wanted_package and name == wanted_path:
                    require(role not in paths and not installed_path.is_symlink(), 'Ambiguous/symlink official tool path')
                    paths[role] = name
        require(bool(matched_files), package + ': no verified installed files')
        trusted[package] = {'version': PACKAGE_VERSION, 'architecture': PACKAGE_ARCH[package], 'origins': origins,
                            'archiveName': archive.name, 'archiveSha256': expected_hash,
                            'download': mirror_evidence['downloads'][package],
                            'indexSourcesEntry': mirror_evidence['index'][PACKAGE_COMPONENT[package]]['Sourcesentry'],
                            'sourcePackage': control[0].get('Source', package),
                            'installedFiles': matched_files}
    require(set(paths) == set(REQUIRED_PATHS), 'Complete official full-tcmalloc/header/pprof paths unavailable')
    # Distribution package/source identity binds this analyst; upstream pprof
    # deliberately reports its script version (2.0), not gperftools 2.15.
    version, _ = runner.text('google-pprof-version', [paths['pprof'], '--version'])
    require('pprof' in version.lower(), 'Official pprof version output missing')
    help_text, _ = runner.text('google-pprof-help', [paths['pprof'], '--help'])
    require(all(flag in help_text for flag in ('--raw', '--inuse_space', '--inuse_objects')),
            'Required official raw integer analysis CLI absent')
    runner.manifest['packageIdentity'] = trusted
    runner.manifest['toolPaths'] = paths
    runner.manifest['packageIdentityPassed'] = True
    runner.persist()
    return paths


def symbol_inventory(runner, binary):
    from profile_contract import SITE_LIFETIMES
    output, _ = runner.text('contract-dynamic-symbols', ['/usr/bin/nm', '-D', '-S', '--defined-only', str(binary)])
    symbols = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[3] in SITE_LIFETIMES:
            require(fields[2] in ('T', 't') and fields[3] not in symbols, 'Invalid/duplicate authored text symbol')
            start, size = int(fields[0],16), int(fields[1],16)
            require(size > 0, 'Authored symbol extent absent')
            symbols[fields[3]] = (start, size)
    require(set(symbols) == set(SITE_LIFETIMES), 'Required authored symbol absent')
    header, _ = runner.text('contract-elf-header', ['/usr/bin/readelf', '-h', str(binary)])
    require('Advanced Micro Devices X86-64' in header and 'EXEC (' in header,
            'Contract must be non-PIE x86-64 ELF for absolute symbol extent identity')
    runner.text('contract-elf-notes', ['/usr/bin/readelf', '-n', str(binary)])
    runner.text('contract-elf-sections', ['/usr/bin/readelf', '-SW', str(binary)])
    runner.text('contract-elf-dynamic', ['/usr/bin/readelf', '-d', str(binary)])
    save(runner.output / 'symbols.json', {name: {'virtualAddress': start, 'size': size}
                                        for name, (start,size) in symbols.items()})
    return symbols


def target_environment(runner, preload, prefix):
    require(Path(preload).is_absolute() and str(Path(preload).resolve()) == preload,
            'Preload must be exact verified regular library realpath')
    env = dict(runner.env)
    env.update({'LD_PRELOAD': preload, 'HEAPPROFILE': str(prefix),
                'HEAP_PROFILE_ALLOCATION_INTERVAL': '0', 'HEAP_PROFILE_DEALLOCATION_INTERVAL': '0',
                'HEAP_PROFILE_INUSE_INTERVAL': '0', 'HEAP_PROFILE_TIME_INTERVAL': '0',
                'HEAP_PROFILE_CLEANUP': '0', 'HEAP_PROFILE_MMAP': '0',
                'HEAP_PROFILE_ONLY_MMAP': '0', 'HEAP_PROFILE_MMAP_LOG': '0'})
    require('HEAPPROFILESIGNAL' not in env, 'Asynchronous profile signal forbidden')
    return env


def check_official_diagnostics(text):
    require(not re.search(r'(?i)(warning|error|failed to|corrupt|truncat|unknown|cannot|could not|no symbols|invalid)', text),
            'Official tool diagnostic invalidates identity/completeness')


def preserve_modules(runner, profiles, binary, preload):
    """Freeze every file-backed executable mapping and its build identity.

    gperftools intentionally writes device=00:00; validate its retained inode,
    path and all executable bytes rather than pretending device is authentic.
    """
    import shutil
    folder = runner.output / 'modules'
    folder.mkdir()
    modules = {}
    for profile in profiles:
        for mapping in profile['maps']:
            if 'x' not in mapping['permissions']:
                continue
            name = mapping['path']
            if name in ('[vdso]', '[vsyscall]'):
                continue  # Kernel pseudo mappings retained verbatim in each dump.
            require(name.startswith('/'), 'Unidentified executable mapping')
            path = Path(name)
            require(path.is_file() and not path.is_symlink(), 'Mapped executable identity missing/symlink')
            info = path.stat()
            require(info.st_ino == mapping['inode'] and info.st_size <= MAX_ANALYSIS_FILE,
                    'Mapped executable inode/byte bound differs')
            digest = sha256(path)
            if name in modules:
                require(modules[name]['sha256'] == digest, 'Mapped executable changed across profiles')
                continue
            copy = folder / (digest + '-' + path.name)
            shutil.copyfile(path, copy)
            require(sha256(copy) == digest and sha256(path) == digest, 'Mapped executable changed while retaining bytes')
            notes, _ = runner.text('module-notes-' + str(len(modules)), ['/usr/bin/readelf', '-n', str(copy)])
            require(re.search(r'Build ID: [0-9a-f]+', notes), 'Mapped ELF build identity missing')
            modules[name] = {'sha256': digest, 'bytes': info.st_size, 'inode': info.st_ino,
                             'retained': str(copy.relative_to(runner.output)),
                             'buildIds': re.findall(r'Build ID: ([0-9a-f]+)', notes)}
    require(str(binary) in modules and preload in modules, 'Fixture/full allocator mapped identities missing')
    runner.manifest['mappedModuleIdentities'] = modules
    runner.persist()
    return modules


def validate_source_manifest():
    manifest = json.loads((ROOT / 'source-manifest.json').read_text())
    files = manifest.get('files', {})
    require(set(files) == {p.name for p in ROOT.iterdir() if p.is_file() and p.name != 'source-manifest.json'
                           and p.suffix in ('.py','.c','.md','.json','.txt')}, 'Frozen source inventory differs')
    for name, identity in files.items():
        path = ROOT / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == identity['bytes']
                and sha256(path) == identity['sha256'], 'Frozen source bytes differ: '+name)
    return sha256(ROOT / 'source-manifest.json')


def run(runner, deb_dir, download_log):
    from profile_contract import (CUT_IDS, read_fixture, parse_profile, validate_profile, validate_official)
    from pprof_raw import parse_pprof_raw
    runner.manifest['sourceManifestSha256'] = validate_source_manifest()
    runner.persist()
    paths = package_gate(runner, deb_dir, download_log)
    binary = runner.output / 'native_contract'
    runner.command('compile-contract', ['/usr/bin/cc', *COMMON_FLAGS, str(ROOT / 'native_contract.c'),
                   paths['preload'], '-ldl', '-o', str(binary)], seconds=60)
    symbols = symbol_inventory(runner, binary)
    runner.manifest['fixtureBinary'] = {'sha256': sha256(binary), 'bytes': binary.stat().st_size}
    profiles_dir = runner.output / 'profiles'
    profiles_dir.mkdir()
    prefix = profiles_dir / 'contract'
    env = target_environment(runner, paths['preload'], prefix)
    runner.manifest['targetOnlyEnvironment'] = {key: value for key,value in env.items() if key not in runner.env}
    runner.manifest['profiledFixtureInvocations'] = 1
    runner.persist()
    stdout, stderr = runner.command('profile-contract', [str(binary)], seconds=RUN_SECONDS,
                                   watch=profiles_dir, target_env=env)
    diagnostic = stderr.read_text()
    check_official_diagnostics(diagnostic)
    expected_files = [Path(str(prefix)+f'.{i:04}.heap') for i in range(1,6)]
    require(set(profiles_dir.iterdir()) == set(expected_files), 'Exactly five synchronous profile files required')
    announcements = re.findall(r'^Dumping heap profile to (.+) \((.+)\)$', diagnostic, re.M)
    require(announcements == [(str(path),cut) for path,cut in zip(expected_files,CUT_IDS)],
            'Profile dump order/reason differs from synchronous cuts')
    fixture_path = runner.output / 'fixture.jsonl'
    fixture_path.write_bytes(stdout.read_bytes())
    fixture = read_fixture(fixture_path)
    require(fixture['metadata']['mallocProvider'] == paths['preload']
            and fixture['metadata']['dumpProvider'] == paths['preload'], 'Actual allocator/API provider differs')
    profiles = [parse_profile(path) for path in expected_files]
    accounting = []
    # Persist complete parsed counters before semantic comparisons so even a
    # rejected first cut leaves a reviewable profile/header evidence summary.
    save(runner.output / 'profiles-summary.json', [
        {'id': cut, 'header': profile['header'], 'bucketCount': len(profile['buckets']),
         'sha256': profile['sha256'], 'bytes': profile['bytes'], 'maps': profile['maps']}
        for cut,profile in zip(CUT_IDS,profiles)])
    preserve_modules(runner, profiles, binary, paths['preload'])
    for cut,profile in zip(CUT_IDS,profiles):
        accounting.append(validate_profile(profile, cut, binary, symbols))
        save(runner.output / 'profile-accounting.json', accounting)
    analysis_dir = runner.output / 'official'
    analysis_dir.mkdir()
    comparisons = []
    for cut,path,profile in zip(CUT_IDS,expected_files,profiles):
        start = time.monotonic()
        row = {'id': cut, 'results': []}
        for mode in ('inuse_space', 'inuse_objects'):
            remaining = PREFIX_SECONDS - (time.monotonic() - start)
            require(remaining > 0, 'Per-profile analysis budget expired')
            exported = analysis_dir / (cut+'.'+mode+'.raw')
            _, err = runner.command('pprof-'+cut+'-'+mode,
                [paths['pprof'], '--raw', '--'+mode, str(binary), str(path)],
                seconds=remaining, stdout=exported)
            check_official_diagnostics(err.read_text())
            raw = parse_pprof_raw(exported, binary)
            check = validate_official(raw, profile, cut, symbols, mode)
            check.update({'sha256': sha256(exported), 'bytes': exported.stat().st_size})
            row['results'].append(check)
        comparisons.append(row)
        save(runner.output / 'official-comparisons.json', comparisons)
    # Confirm captured and analyzed library/source bytes stayed fixed.
    for name, module in runner.manifest['mappedModuleIdentities'].items():
        require(sha256(name) == module['sha256'], 'Mapped ELF bytes changed during analysis')
    require(validate_source_manifest() == runner.manifest['sourceManifestSha256'], 'Frozen source changed')
    runner.manifest['contractPassed'] = True
    runner.manifest['status'] = 'passed-synthetic-only'
    runner.manifest['conclusion'] = ('Fixed full tcmalloc synthetic contract only; allocator replacement '
        'cannot reconcile historical glibc +72.729 MiB. No leak or no-leak verdict, no real-sampling promotion.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--deb-dir', required=True, type=Path)
    parser.add_argument('--apt-download-log', required=True, type=Path)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'Actual profiler entrypoint is GitHub CI only')
    output = args.output.resolve()
    require(not args.output.is_symlink() and not output.exists(), 'Output must be a new isolated directory')
    require(args.deb_dir.is_dir() and not args.deb_dir.is_symlink(), 'Verified package directory unavailable')
    output.mkdir(parents=True)
    runner = Runner(output)
    result = 1
    try:
        run(runner, args.deb_dir.resolve(), args.apt_download_log)
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
