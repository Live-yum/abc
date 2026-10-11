"""Offline application heap evidence contracts; no app/profiler/SDK entry point.

The imported small-contract modules are immutable, hash-bound dependencies.
Maps completeness requires independently captured pre/post snapshots; bundled
reconstructed maps only exercise the offline parser and are not runtime proof.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys

ROOT = Path(__file__).resolve().parent
# Explicit authoring layout and normal repository layout only. Never search an
# arbitrary environment/PYTHONPATH for a conveniently named dependency.
SMALL_LAYOUTS = (ROOT.parent / 'gperftools-preflight-index',
                 ROOT.parent / 'gperftools_preflight')
SMALL = next((path for path in SMALL_LAYOUTS if path.is_dir()), SMALL_LAYOUTS[0])
DEPENDENCIES = {
    'profile_contract': '07cee15d0c0c3f6d3be56b60f2339fd419def81d3fcaea4236660468a9f25d79',
    'pprof_raw': '3bc28fc584db560c865f7f7aa8e3acc72debfe6e40257e8b861367e320093646',
}


def _load(name):
    path = SMALL / (name + '.py')
    if hashlib.sha256(path.read_bytes()).hexdigest() != DEPENDENCIES[name]:
        raise RuntimeError('Frozen small-contract dependency differs: ' + name)
    spec = importlib.util.spec_from_file_location('_abc_frozen_' + name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


small = _load('profile_contract')
raw_parser = _load('pprof_raw')
ContractError = small.ContractError
require = small.require
MAX_HEAP = 1 << 20  # exclusive, the upstream fixed buffer
MAX_MAPS = 1 << 20  # inclusive, each of eight raw snapshots
MAX_RAW = 16 << 20  # inclusive; NEVER the child's 64 MiB RLIMIT_FSIZE
MAX_SIDECAR = 256 << 20
MAX_MODULE = 64 << 20
MAX_LINE = 1 << 16
MAX_RECEIPT = 512
RSS_STOP = 2 << 30  # observed stop line, not a kernel RSS limit
CUTS = ((0, 0, 'q0', 'heap.0001.heap'), (1, 7, 'q7', 'heap.0002.heap'))


def bounded_bytes(path, cap, *, exclusive=False):
    """Refuse symlinks/FIFOs and changing or oversized evidence before parsing."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode), 'Evidence must be a regular file')
            require(before.st_size < cap if exclusive else before.st_size <= cap,
                    'Evidence byte cap exceeded')
            data = stream.read(cap + 1)
            after = os.fstat(stream.fileno())
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(identity(before) == identity(after) and len(data) == after.st_size,
                'Evidence changed during bounded read')
        require(len(data) < cap if exclusive else len(data) <= cap, 'Evidence byte cap exceeded')
        return data
    except OSError as exc:
        raise ContractError('Cannot read evidence: ' + str(exc)) from exc


def ascii_lines(data):
    require(data and data.endswith(b'\n') and b'\x00' not in data, 'Truncated/NUL evidence')
    require(all(c == 10 or 32 <= c < 127 for c in data), 'Non-ASCII/control evidence')
    lines = data.decode('ascii').split('\n')[:-1]
    require(all(len(line) < MAX_LINE for line in lines), 'Evidence line cap exceeded')
    return lines


PROC_MAP = re.compile(r'([0-9a-f]{8,16})-([0-9a-f]{8,16}) ([r-][w-][x-][ps]) '
                      r'([0-9a-f]+) ([0-9a-f]+):([0-9a-f]+)\s+(\d+)\s*(.*)')


def parse_maps(data, *, heap_format=False):
    rows = []
    for line in ascii_lines(data):
        match = (small.MAPPING if heap_format else PROC_MAP).fullmatch(line)
        require(match is not None, 'Malformed/truncated maps line')
        if heap_format:
            lo, hi, perms, offset, inode, name = match.groups()
            device = None  # gperftools deliberately prints 00:00, not real st_dev.
        else:
            lo, hi, perms, offset, major, minor, inode, name = match.groups()
            device = (int(major, 16), int(minor, 16))
        row = dict(start=int(lo, 16), end=int(hi, 16), permissions=perms,
                   offset=int(offset, 16), inode=int(inode), path=name, device=device)
        require(row['start'] < row['end'] < 2**64 and row['inode'] < 2**64
                and row['offset'] < 2**64 and (not rows or rows[-1]['end'] <= row['start']),
                'Overlapping/invalid maps range')
        require(not name.endswith(' (deleted)'), 'Deleted mapping cannot establish file identity')
        require(not name or name.startswith('/') or re.fullmatch(
            r'\[(?:heap|stack(?::\d+)?|vdso|vvar|vvar_vclock|vsyscall|anon:[^\[\]]+|anon_shmem:[^\[\]]+)\]', name),
            'Unknown or unresolved mapping path')
        if name.startswith('/'):
            require('\\' not in name and '/./' not in name and '/../' not in name
                    and row['inode'] > 0, 'Unresolved mapped file path or inode')
        rows.append(row)
    require(rows and any('x' in r['permissions'] for r in rows), 'Executable maps missing')
    return rows


def parse_heap(path):
    data = bounded_bytes(path, MAX_HEAP, exclusive=True)
    lines = ascii_lines(data)
    head = small.HEADER.fullmatch(lines[0])
    require(head is not None, 'Malformed/unsupported heapprofile header')
    header = small.counters(head)
    require(lines.count('MAPPED_LIBRARIES:') == 1, 'Missing/duplicated mapping section')
    index = lines.index('MAPPED_LIBRARIES:')
    require(index >= 2 and lines[index - 1] == '', 'Missing map separator')
    buckets, seen = [], set()
    for line in lines[1:index - 1]:
        match = small.BUCKET.fullmatch(line)
        require(match is not None, 'Malformed/truncated heap bucket')
        counts = small.counters(match)
        stack = tuple(int(pc, 16) for pc in match.group(5).split())
        require(all(stack) and stack not in seen, 'Zero/duplicate stack')
        seen.add(stack)
        buckets.append({'counters': counts, 'stack': stack})
    require(tuple(sum(b['counters'][i] for b in buckets) for i in range(4)) == header,
            'Incomplete heap: all four bucket sums must equal header')
    maps = parse_maps(('\n'.join(lines[index + 1:]) + '\n').encode(), heap_format=True)
    for bucket in buckets:
        for pc in bucket['stack']:
            require(any(m['start'] <= pc < m['end'] and 'x' in m['permissions'] for m in maps),
                    'Necessary PC missing executable mapping')
    return dict(header=header, buckets=buckets, maps=maps, bytes=len(data),
                sha256=hashlib.sha256(data).hexdigest())


def map_key(row, *, device=False):
    keys = ('start', 'end', 'permissions', 'offset', 'inode', 'path')
    return tuple(row[k] for k in keys) + ((row['device'],) if device else ())


def validate_map_bracket(profile, before_path, after_path, *, necessary_pcs=()):
    before_bytes = bounded_bytes(before_path, MAX_MAPS)
    after_bytes = bounded_bytes(after_path, MAX_MAPS)
    before, after = parse_maps(before_bytes), parse_maps(after_bytes)
    executable_files = lambda rows: {map_key(r) for r in rows
                                    if 'x' in r['permissions'] and r['path'].startswith('/')}
    expected = executable_files(before)
    require(expected and expected == executable_files(after) == executable_files(profile['maps']),
            'Incomplete/unstable file-backed executable map set')
    before_all, after_all, dumped = ({map_key(r) for r in rows}
                                    for rows in (before, after, profile['maps']))
    require(before_all & after_all <= dumped <= before_all | after_all,
            'Incomplete/unknown full maps snapshot (including stable anonymous tail)')
    # Device is absent from the profiler's text, so independently retain/compare
    # it between /proc snapshots; inode/path/range/offset must also be stable.
    require({map_key(r, device=True) for r in before if map_key(r) in expected}
            == {map_key(r, device=True) for r in after if map_key(r) in expected},
            'Mapped-file device identity changed')
    pcs = set(necessary_pcs) | {pc for b in profile['buckets'] for pc in b['stack']}
    non_elf = []
    for pc in sorted(pcs):
        candidates = [[r for r in rows if r['start'] <= pc < r['end']
                       and 'x' in r['permissions']] for rows in (before, profile['maps'], after)]
        require(all(len(group) == 1 for group in candidates)
                and len({map_key(group[0]) for group in candidates}) == 1,
                'Necessary PC mapping absent/changed within dump bracket')
        row = candidates[0][0]
        if not row['path'].startswith('/'):
            non_elf.append({'pc': pc, 'mapping': row})
    # Requiring all map rows would reject ordinary allocator growth during dump;
    # required executable mappings and PCs are exact, anonymous rows preserved.
    return {'before': before, 'after': after, 'nonElfFrames': non_elf,
            'fileExecutableMaps': sorted(expected), 'complete': True,
            'beforeSha256': hashlib.sha256(before_bytes).hexdigest(),
            'afterSha256': hashlib.sha256(after_bytes).hexdigest(),
            'atomicObjectSnapshot': False}


def validate_module_records(bracket, records):
    """Validate already-audited ELF metadata; never infer nearest symbols.

    Callers must bind these records to actual retained module bytes before use.
    Offline metadata alone is NOT loaded-target identity proof.
    """
    required = {key[-1] for key in bracket['fileExecutableMaps']}
    require(set(records) == required, 'Missing/extra executable module identity')
    for path, row in records.items():
        require(row.get('path') == path and type(row.get('bytes')) is int
                and 0 < row['bytes'] <= MAX_MODULE, 'Necessary ELF byte cap/identity missing')
        require(re.fullmatch('[0-9a-f]{64}', row.get('sha256', '')) is not None
                and re.fullmatch('[0-9a-f]{8,128}', row.get('buildId', '')) is not None,
                'ELF SHA/build ID missing')
        require(type(row.get('loadBias')) is int and row['loadBias'] >= 0
                and isinstance(row.get('ptLoad'), list) and row['ptLoad'],
                'ELF PT_LOAD/load-bias missing')
        for segment in row['ptLoad']:
            fields = ('offset', 'vaddr', 'fileSize', 'memorySize', 'flags', 'align')
            require(isinstance(segment, dict)
                    and all(type(segment.get(k)) is int and 0 <= segment[k] < 2**64 for k in fields),
                    'Malformed ELF PT_LOAD fields')
            require(segment['fileSize'] <= segment['memorySize']
                    and segment['offset'] + segment['fileSize'] <= row['bytes']
                    and segment['align'] >= 4096 and segment['align'] & (segment['align'] - 1) == 0,
                    'Invalid ELF PT_LOAD extent/alignment')
        for start, end, permissions, offset, inode, mapped_path in bracket['fileExecutableMaps']:
            if mapped_path != path:
                continue
            require(any(seg['flags'] & 1
                        and start - offset == row['loadBias'] + seg['vaddr'] - seg['offset']
                        and row['loadBias'] + (seg['vaddr'] & ~4095) <= start < end
                        <= row['loadBias'] + ((seg['vaddr'] + seg['memorySize'] + 4095) & ~4095)
                        for seg in row['ptLoad']), 'Executable mapping not bound to ELF PT_LOAD/load bias')
        for key in ('dynsym', 'symtab'):
            require(isinstance(row.get(key), list), 'ELF symbol-range inventory missing')
            for symbol in row[key]:
                require(isinstance(symbol, dict) and isinstance(symbol.get('name'), str)
                        and type(symbol.get('address')) is int and type(symbol.get('size')) is int
                        and 0 <= symbol['address'] < 2**64 and 0 <= symbol['size']
                        and symbol['address'] + symbol['size'] < 2**64,
                        'Malformed exact ELF symbol extent')
        require('debugInfo' in row, 'Matching-debug availability must be explicit')
        if row['debugInfo'] is not None:
            debug = row['debugInfo']
            require(isinstance(debug, dict) and debug.get('buildId') == row['buildId']
                    and re.fullmatch('[0-9a-f]{64}', debug.get('sha256', '')) is not None,
                    'Debug information does not match ELF build ID')
    return {'moduleCount': len(records), 'loadedIdentityProven': False,
            'requiresBoundModuleBytes': True}


def normalized_file_pc(pc, mapping, module):
    """ASLR-neutral ELF virtual offset only; no nearest-symbol attribution."""
    require(mapping['path'] == module['path'] and mapping['path'].startswith('/')
            and mapping['start'] <= pc < mapping['end'] and 'x' in mapping['permissions'],
            'PC lacks exact executable module mapping')
    relative = pc - module['loadBias']
    require(relative >= 0 and any(segment['flags'] & 1
            and segment['vaddr'] <= relative < segment['vaddr'] + segment['memorySize']
            for segment in module['ptLoad']), 'PC outside exact executable PT_LOAD extent')
    return (module['buildId'], relative)


def parse_receipt(path, *, expected_slot, expected_pid):
    data = bounded_bytes(path, MAX_RECEIPT)
    require(len(ascii_lines(data)) == 1, 'Receipt must be one bounded line')
    match = re.fullmatch(rb'ABC_HEAP_RECEIPT_V1 (0|1) (0|7) ([1-9][0-9]*) '
                         rb'([0-9]+) ([0-9]+) ([1-9][0-9]*) ([1-9][0-9]*) '
                         rb'(heap\.000[12]\.heap)\n', data)
    require(match is not None, 'Malformed receipt')
    slot, cycle, pid, start, end, before_size, after_size = map(int, match.groups()[:7])
    require(0 <= expected_slot < 2 and (slot, cycle, match[8].decode()) ==
            (CUTS[expected_slot][0], CUTS[expected_slot][1], CUTS[expected_slot][3])
            and pid == expected_pid, 'Receipt identity/cut mismatch')
    require(0 < start <= end < 2**63 and end - start <= 10_000_000_000
            and 0 < before_size <= MAX_MAPS and 0 < after_size <= MAX_MAPS,
            'Receipt timing/maps bounds')
    return dict(slot=slot, cycle=cycle, pid=pid, dumpStartNs=start, dumpEndNs=end,
                beforeSize=before_size, afterSize=after_size, heap=match[8].decode())


def acknowledge(directory, receipt, *, hook_started, receipt_seen, now):
    """Publish only a fully written ACK; pending failures remain as evidence."""
    require(now - receipt_seen <= 2 and now - hook_started <= 10
            and hook_started <= receipt_seen <= now, 'ACK/hook deadline exceeded')
    directory = Path(directory)
    name = CUTS[receipt['slot']][2] + '.ack'
    pending = name + '.pending'
    path = directory / name
    data = f"ABC_HEAP_ACK_V1 {receipt['slot']} {receipt['cycle']} OK\n".encode()
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory_fd)
        try:
            remaining = memoryview(data)
            while remaining:
                written = os.write(fd, remaining)
                require(written > 0, 'Incomplete ACK pending write')
                remaining = remaining[written:]
            # Unbuffered writes above need no Python stream flush. Sync before
            # publication so a reader can never observe empty/partial final ACK.
            os.fsync(fd)
        finally:
            os.close(fd)
        # linkat is atomic and refuses an existing destination, including a
        # symlink. Keep pending on every failure; never overwrite an old ACK.
        os.link(pending, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
                follow_symlinks=False)
        os.fsync(directory_fd)
        os.unlink(pending, dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return path


def validate_cut(directory, *, slot, pid):
    directory = Path(directory)
    receipt = parse_receipt(directory / (CUTS[slot][2] + '.receipt'),
                            expected_slot=slot, expected_pid=pid)
    before = directory / (CUTS[slot][2] + '.before.maps')
    after = directory / (CUTS[slot][2] + '.after.maps')
    require(len(bounded_bytes(before, MAX_MAPS)) == receipt['beforeSize']
            and len(bounded_bytes(after, MAX_MAPS)) == receipt['afterSize'],
            'Receipt/maps size mismatch')
    profile = parse_heap(directory / receipt['heap'])
    bracket = validate_map_bracket(profile, before, after)
    return {'receipt': receipt, 'profile': profile, 'bracket': bracket}


_SKIP = set('calloc cfree malloc free memalign posix_memalign pvalloc valloc realloc '
            'tc_calloc tc_cfree tc_malloc tc_free tc_memalign tc_posix_memalign tc_pvalloc '
            'tc_valloc tc_realloc tc_new tc_delete tc_newarray tc_deletearray tc_new_nothrow '
            'tc_newarray_nothrow do_malloc ::do_malloc ::do_malloc_or_cpp_alloc '
            'DoSampledAllocation simple_alloc::allocate __malloc_alloc_template::allocate '
            '__builtin_delete __builtin_new __builtin_vec_delete __builtin_vec_new '
            'malloc_zone_malloc malloc_zone_calloc malloc_zone_valloc malloc_zone_realloc '
            'malloc_zone_memalign malloc_zone_free __start_google_malloc __stop_google_malloc '
            '__start_malloc_hook __stop_malloc_hook'.split()) | {'operator new', 'operator new[]'}
_SKIP |= {'_' + name for name in _SKIP.copy()}


def _short_name(symbol):
    # Pinned pprof ShortFunctionName with default template stripping; the first
    # inline name is its symbols[pc][0]. This reproduces tool behavior only.
    symbol = symbol.split('--')[0]
    for pattern in (r'\([^()]*\)(\s*const)?', r'<[0-9a-f]*>$', r'<[^<>]*>'):
        while True:
            reduced = re.sub(pattern, '', symbol)
            if reduced == symbol:
                break
            symbol = reduced
    return re.sub(r'^.*\s+(\w+::)', r'\1', symbol)


def validate_official_raw(path, binary, profile, mode):
    require(mode in ('inuse_space', 'inuse_objects'), 'Unsupported raw integer mode')
    raw = raw_parser.parse_pprof_raw(path, binary)
    index = {'inuse_objects': 0, 'inuse_space': 1}[mode]
    expected, removed = defaultdict(int), set()
    for bucket in profile['buckets']:
        adjusted = [pc if i == 0 else pc - 1 for i, pc in enumerate(bucket['stack'])]
        keep = []
        for pc in adjusted:
            name = _short_name(raw['symbols'].get(pc, ''))
            if name in _SKIP or 'TCMalloc' in name or name.startswith('tcmalloc::'):
                removed.add(pc)
            else:
                keep.append(pc)
        require(keep, 'Official allocator removal erased a whole source stack')
        expected[tuple(keep)] += bucket['counters'][index]
    require(raw['total'] == profile['header'][index], 'Official whole-profile integer sum differs')
    require(raw['stacks'] == dict(expected),
            'Official full stack accounting differs, including historical zero-live buckets')
    return {'mode': mode, 'total': raw['total'], 'stacks': raw['stacks'],
            'allocatorFramePcsRemovedByOfficialTool': sorted(removed),
            'functionAttributionProvenByRawSymbols': False}


def check_sidecar_caps(directory, *, expected_files=None, max_heaps=4):
    """Runtime metadata-only upper bounds; incomplete writes may be zero bytes.

    Never read/hash payloads in a supervision polling loop. Completeness and
    lower bounds belong to receipt-time parsing and the final seal below.
    """
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), 'Invalid sidecar directory')
    total, entries, heap_count, heap_bytes, maps_count, maps_bytes = 0, {}, 0, 0, 0, 0
    directory_count = 0
    for base, dirs, files in os.walk(directory, followlinks=False):
        directory_count += 1
        require(directory_count <= 256, 'Sidecar directory count cap')
        for name in dirs:
            require(not (Path(base) / name).is_symlink(), 'Sidecar directory symlink')
        for name in files:
            path = Path(base) / name
            rel = str(path.relative_to(directory))
            require(len(entries) < 4096, 'Sidecar entry cap exceeded')
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode), 'Unexpected sidecar file type')
            size = info.st_size
            total += size
            require(total <= MAX_SIDECAR, 'Sidecar cumulative 256 MiB cap exceeded')
            if path.suffix == '.heap':
                require(size < MAX_HEAP, 'Heap 1 MiB cap')
                heap_count += 1
                heap_bytes += size
            if path.suffix == '.maps':
                require(size <= MAX_MAPS, 'Maps 1 MiB cap')
                maps_count += 1
                maps_bytes += size
            if path.suffix == '.raw':
                require(size <= MAX_RAW, 'Official raw 16 MiB cap')
            entries[rel] = {'bytes': size}
    require(max_heaps in (2, 4) and heap_count <= max_heaps and heap_bytes < max_heaps * MAX_HEAP
            and maps_count <= 8 and maps_bytes <= 8 * MAX_MAPS, 'Pair heap/maps total cap')
    if expected_files is not None:
        runtime_expected = set(expected_files)
        # These two fixed in-progress names exist only during atomic ACK
        # publication. A final seal still requires the exact completed list.
        runtime_expected |= {name + '.pending' for name in runtime_expected
                             if Path(name).name in ('q0.ack', 'q7.ack')}
        require(set(entries) <= runtime_expected,
                'Unexpected/missing sidecar file (including extra dump)')
    return {'retainedBytes': total, 'files': entries, 'heapCount': heap_count}


def inspect_sidecar(directory, *, expected_files=None, complete_heaps=None,
                    max_heaps=4, allow_missing=False):
    """One final seal: hash complete retained evidence and preserve SHA references."""
    directory = Path(directory)
    inventory = check_sidecar_caps(directory, expected_files=expected_files, max_heaps=max_heaps)
    entries, hashes = inventory['files'], {}
    if expected_files is not None and not allow_missing:
        require(set(entries) == set(expected_files), 'Unexpected/missing sidecar file (including extra dump)')
    for rel, record in entries.items():
        path = directory / rel
        data = bounded_bytes(path, MAX_SIDECAR)
        require(len(data) == record['bytes'], 'Sidecar changed during final seal')
        if path.suffix in ('.heap', '.maps'):
            require(data, 'Incomplete empty heap/maps at final seal')
        digest = hashlib.sha256(data).hexdigest()
        record['sha256'] = digest
        hashes.setdefault(digest, []).append(rel)
    if complete_heaps is not None:
        require(inventory['heapCount'] == complete_heaps, 'Incomplete heap count')
    return {'retainedBytes': inventory['retainedBytes'], 'uniqueShaBytes': sum(entries[names[0]]['bytes'] for names in hashes.values()),
            'shaReferences': hashes, 'files': entries}


class OsLogTail:
    """Incremental original os-*.jsonl reader; never takes a new RSS sample."""
    def __init__(self, path, *, previous_sequence=-1):
        self.path, self.offset, self.pending = Path(path), 0, b''
        self.identity, self.last_sequence, self.max_rss = None, previous_sequence, 0

    def read_new(self, *, final=False):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        except FileNotFoundError:
            require(not final, 'Original OS log missing')
            return 0
        count = 0
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode), 'Original OS log is not a regular file')
            require(info.st_size <= 4 << 20, 'Original OS JSON 4 MiB file cap')
            identity = (info.st_dev, info.st_ino)
            require(self.identity in (None, identity) and info.st_size >= self.offset,
                    'Original OS log replaced/truncated')
            self.identity = identity
            stream.seek(self.offset)
            # 1 MiB per sweep, so the supervising loop retains deadline control.
            data = stream.read(1 << 20)
            self.offset += len(data)
        parts = (self.pending + data).split(b'\n')
        self.pending = parts.pop()
        require(len(self.pending) < MAX_LINE, 'Original OS log line cap')
        for line in parts:
            require(0 < len(line) < MAX_LINE, 'Original OS log line cap')
            try:
                row = json.loads(line, object_pairs_hook=small.unique_object)
            except (ValueError, UnicodeError) as exc:
                raise ContractError('Invalid original OS log JSON') from exc
            require(isinstance(row, dict) and row.get('type') == 'os'
                    and type(row.get('sequence')) is int and row['sequence'] == self.last_sequence + 1
                    and type(row.get('rssBytes')) is int and row['rssBytes'] >= 0,
                    'Original OS log sequence/RSS contract')
            self.last_sequence = row['sequence']
            self.max_rss = max(self.max_rss, row['rssBytes'])
            require(row['rssBytes'] <= RSS_STOP, 'Observed target RSS exceeds 2 GiB stop line')
            count += 1
        if final:
            require(not self.pending and self.offset == info.st_size, 'Incomplete/unread original OS log')
        return count


class OsJournalTail:
    """Consume original sequential rotated chunks, at most 1 MiB per sweep."""
    def __init__(self, directory):
        self.directory = Path(directory)
        self.index = 0
        self.tail = OsLogTail(self.directory / 'os-0.jsonl')
        self.max_rss = 0
        self.closed_files = []

    def read_new(self):
        count = self.tail.read_new()
        self.max_rss = max(self.max_rss, self.tail.max_rss)
        next_path = self.directory / f'os-{self.index + 1}.jsonl'
        if os.path.lexists(next_path):
            info = self.tail.path.lstat()
            if self.tail.offset == info.st_size:
                require(not self.tail.pending, 'Incomplete previous rotated OS chunk')
                self.closed_files.append(self.tail.path.name)
                self.index += 1
                self.tail = OsLogTail(next_path, previous_sequence=self.tail.last_sequence)
        return count

    def finish(self, expected_files):
        # Caller drains read_new on its existing deadline before finalization;
        # do not introduce an unbounded final read or reset sequence at rotation.
        self.tail.read_new(final=True)
        require(self.closed_files + [self.tail.path.name] == list(expected_files),
                'Original OS chunks missing/out of order/unread')
        self.max_rss = max(self.max_rss, self.tail.max_rss)
        return {'sampleCount': self.tail.last_sequence + 1,
                'observedMaxRssBytes': self.max_rss, 'newSamplingPerformed': False}


def arm_completion(*, workload_complete, heap_files_complete, attribution_available,
                   original_report, error=None):
    require(all(type(x) is bool for x in (workload_complete, heap_files_complete, attribution_available)),
            'Completion fields must be explicit booleans')
    require(not attribution_available or workload_complete and heap_files_complete,
            'Attribution cannot precede workload/heap completion')
    # Preserve the whole original validator outcome and byte hash verbatim;
    # zero-image coverage is still failure, even when this sidecar succeeds.
    original = bounded_bytes(original_report, 4 << 20)
    try:
        legacy = json.loads(original, object_pairs_hook=small.unique_object)
    except (ValueError, UnicodeError) as exc:
        raise ContractError('Invalid original validator report') from exc
    return {'schema': 'abc.gperftools-application-arm.v1',
            'workloadComplete': workload_complete, 'heapFilesComplete': heap_files_complete,
            'stackAttributionAvailable': attribution_available, 'error': error,
            'originalValidatorReport': legacy,
            'originalValidatorReportSha256': hashlib.sha256(original).hexdigest(),
            'originalValidatorOutcomeOverridden': False,
            'claimsObjectIdentity': False, 'claimsProductNetLeak': False,
            'claimsOriginalGlibcReconciliation': False}
