"""Strict offline accounting for official gperftools 2.15 heapprofile output.

The semantic schedule below is independent of both fixture JSON and profiler
output. No nearest-symbol attribution, sampled-size scaling or top-N analysis.
"""
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re

MAX_RECORD = 65536
MAX_PROFILE = 1024 * 1024  # Upstream fixed buffer; exclusive file bound.
MAX_DECODED = 64 * 1024 * 1024
CUT_IDS = ('q0.begin', 'q0.end', 'q7.begin', 'q7.end', 'cleanup')
CUT_ORDINALS = (2, 8, 10, 13, 15)
OWNER_SIZES = ((101, 219, 0, 0, 0, 0), (409, 0, 307, 0, 0, 0),
               (409, 0, 0, 0, 601, 0), (0, 0, 0, 0, 809, 749), (0, 0, 0, 0, 0, 0))
# name, kind, logical owner, requested size. Calls retained from old fixture,
# with only its eight marker allocations removed and site-specific wrappers.
SCHEDULE = (
    ('abc_alloc_baseline', 'malloc', 0, 101),
    ('abc_alloc_pre_calloc', 'calloc', 1, 219),
    ('abc_alloc_q0_transient', 'malloc', 2, 307),
    ('abc_alloc_baseline_grow', 'realloc', 0, 409),
    ('free_pre_calloc_in_q0', 'free', 1, 0),
    ('abc_alloc_zero503', 'malloc', 3, 503),
    ('realloc_failure_size_max', 'realloc', 0, 2**64-1),
    ('realloc_zero_frees_source', 'realloc', 3, 0),
    ('free_q0_transient_in_gap', 'free', 2, 0),
    ('abc_alloc_gap', 'malloc', 4, 601),
    ('free_baseline_in_q7', 'free', 0, 0),
    ('abc_alloc_q7_calloc', 'calloc', 5, 749),
    ('abc_alloc_gap_grow', 'realloc', 4, 809),
    ('free_gap_after_q7', 'free', 4, 0),
    ('free_q7_calloc_after_q7', 'free', 5, 0),
)
# One allocation hook per named site, even successful in-place realloc; see
# tcmalloc.cc do_realloc. Failed nonzero realloc preserves prior hook; zero
# realloc deletes without NewHook. No runtime profile generates this oracle.
SITE_LIFETIMES = {
    'abc_alloc_baseline': (101, 0, 3),
    'abc_alloc_pre_calloc': (219, 1, 4),
    'abc_alloc_q0_transient': (307, 2, 8),
    'abc_alloc_baseline_grow': (409, 3, 10),
    'abc_alloc_zero503': (503, 5, 7),
    'abc_alloc_gap': (601, 9, 12),
    'abc_alloc_q7_calloc': (749, 11, 14),
    'abc_alloc_gap_grow': (809, 12, 13),
}


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def pointer(value):
    require(isinstance(value, str) and re.fullmatch(r'0x[0-9a-f]+', value), 'Malformed fixture pointer')
    result = int(value, 16)
    require(result < 2**64, 'Oversized fixture pointer')
    return result


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        require(name not in result, 'Duplicate JSON field')
        result[name] = value
    return result


def read_fixture(path, *, allow_offline=False):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size < MAX_PROFILE,
            'Missing/oversized fixture JSONL')
    raw = path.read_bytes()
    require(raw.endswith(b'\n'), 'Truncated fixture JSONL')
    rows = [json.loads(line, object_pairs_hook=unique_object) for line in raw.splitlines()]
    require(len(rows) == 22 and all(isinstance(row, dict) for row in rows), 'Fixture record count/type differs')
    metadata, operations, cuts, summary = rows[0], rows[1:16], rows[16:21], rows[21]
    require(metadata.get('type') == 'metadata' and metadata.get('schema') == 'abc.gperftools-contract.v1'
            and metadata.get('pointerWidthBits') == 64 and metadata.get('initialRunning') == 1
            and type(metadata.get('hostPid')) is int and metadata['hostPid'] > 0
            and (metadata.get('offline') is False or allow_offline and metadata.get('offline') is True),
            'Fixture startup/profile identity differs')
    live, cursor = {}, 0
    for index, (row, planned) in enumerate(zip(operations, SCHEDULE)):
        name, kind, owner, size = planned
        require(row.get('type') == 'operation' and row.get('ordinal') == index
                and (row.get('name'), row.get('kind'), row.get('owner'), row.get('requestedBytes')) == planned,
                'Fixture operation differs from independent schedule')
        old, result = pointer(row.get('oldPointer')), pointer(row.get('resultPointer'))
        prior = live.get(owner)
        require(old == (prior[0] if prior else 0), 'Fixture old pointer/lifetime mismatch')
        if name == 'realloc_failure_size_max':
            require(prior is not None and not result and row.get('success') == 0
                    and row.get('formerAllocationFreed') == 0 and row.get('errno') == metadata.get('enomem'),
                    'Failed-realloc preservation contract absent')
        elif kind == 'free' or name == 'realloc_zero_frees_source':
            require(prior is not None and result == 0 and row.get('success') == 1
                    and row.get('formerAllocationFreed') == 1, 'Free/realloc-zero contract absent')
            del live[owner]
        else:
            require(result > 0 and row.get('success') == 1 and row.get('formerAllocationFreed') == int(prior is not None),
                    'Successful allocation/reallocation contract absent')
            require(not any(value[0] == result for key, value in live.items() if key != owner),
                    'Duplicate live pointer across logical owners')
            live[owner] = (result, size)
        if index + 1 in CUT_ORDINALS:
            cut = cuts[cursor]
            expected = OWNER_SIZES[cursor]
            actual = tuple(live.get(i, (0, 0))[1] for i in range(6))
            require(actual == expected, 'Independent operation replay differs at cut')
            require(cut.get('type') == 'cut' and cut.get('id') == CUT_IDS[cursor]
                    and cut.get('dumpOrdinal') == cursor+1 and cut.get('operationOrdinal') == index+1
                    and cut.get('ownerSizes') == list(expected) and cut.get('liveBytes') == sum(expected)
                    and cut.get('liveBlocks') == sum(bool(n) for n in expected), 'Fixture cut oracle differs')
            cursor += 1
    require(not live and cursor == 5 and summary == {'type': 'summary', 'authoredOperations': 15,
            'dumpCount': 5, 'reallocZeroFreed': 1, 'reallocFailureEnomem': 1,
            'stopped': 1, 'semanticFailureBits': 0}, 'Fixture cleanup/semantic summary failed')
    return {'metadata': metadata, 'operations': operations, 'cuts': cuts, 'summary': summary}


def expected_sites(cut):
    ordinal = CUT_ORDINALS[CUT_IDS.index(cut)]
    return {site: [int(born < ordinal <= freed), size * int(born < ordinal <= freed),
                   int(born < ordinal), size * int(born < ordinal)]
            for site, (size, born, freed) in SITE_LIFETIMES.items()}


COUNTS = r'\s*(\d+):\s*(\d+)\s+\[\s*(\d+):\s*(\d+)\s*\]\s+@'
HEADER = re.compile(r'heap profile:' + COUNTS + r' heapprofile')
BUCKET = re.compile(COUNTS + r'((?: 0x[0-9a-f]{8,16}){1,32})')
MAPPING = re.compile(r'([0-9a-f]{8,16})-([0-9a-f]{8,16}) ([r-][w-][x-][p-]) '
                     r'([0-9a-f]+) 00:00\s+(\d+)\s*(.*)')


def counters(match):
    values = tuple(map(int, match.groups()[:4]))
    require(all(n < 2**63 for n in values) and values[0] <= values[2] and values[1] <= values[3],
            'Invalid/overflowing heap counters')
    require(values[2] > 0 or values == (0, 0, 0, 0), 'Heap bytes without allocations')
    return values


def parse_profile(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size < MAX_PROFILE,
            'Missing/oversized profile; fixed upstream 1 MiB output cap')
    data = path.read_bytes()
    require(data.endswith(b'\n') and b'\x00' not in data, 'Truncated/NUL profile')
    lines = data.decode('ascii', 'strict').splitlines()
    require(all(len(line) < MAX_RECORD for line in lines), 'Oversized profile line')
    head = HEADER.fullmatch(lines[0])
    require(head is not None, 'Malformed/unsupported heapprofile header')
    header = counters(head)
    require(lines.count('MAPPED_LIBRARIES:') == 1, 'Missing/duplicated mapping section')
    index = lines.index('MAPPED_LIBRARIES:')
    require(index >= 2 and lines[index-1] == '', 'Mapping separator missing')
    buckets, seen = [], set()
    for line in lines[1:index-1]:
        match = BUCKET.fullmatch(line)
        require(match is not None, 'Malformed/truncated bucket')
        values = counters(match)
        stack = tuple(int(pc,16) for pc in match.group(5).split())
        require(all(stack) and stack not in seen, 'Empty/duplicate stack bucket')
        seen.add(stack)
        buckets.append({'counters': values, 'stack': stack})
    sums = tuple(sum(row['counters'][i] for row in buckets) for i in range(4))
    require(sums == header, 'Incomplete profile: all four bucket sums must equal header')
    maps = []
    for line in lines[index+1:]:
        match = MAPPING.fullmatch(line)
        require(match is not None, 'Malformed/truncated mapped-library line')
        lo, hi, permissions, offset, inode, name = match.groups()
        row = {'start': int(lo,16), 'end': int(hi,16), 'permissions': permissions,
               'offset': int(offset,16), 'inode': int(inode), 'path': name}
        require(row['start'] < row['end'] < 2**64 and (not maps or row['start'] >= maps[-1]['end']),
                'Overlapping/invalid mapped-library range')
        require(not name.endswith(' (deleted)'), 'Mapped file deleted; identity unavailable')
        maps.append(row)
    require(maps and any('x' in row['permissions'] for row in maps), 'Executable maps missing')
    for row in buckets:
        for pc in row['stack']:
            require(any(m['start'] <= pc < m['end'] and 'x' in m['permissions'] for m in maps),
                    'Stack PC missing executable mapping; unknown necessary stack')
    return {'header': header, 'buckets': buckets, 'maps': maps,
            'sha256': sha256(path), 'bytes': len(data)}


def site_for_stack(stack, symbols):
    found = {name for pc in stack for name, (start, size) in symbols.items()
             if name in SITE_LIFETIMES and start <= pc < start+size}
    require(len(found) <= 1, 'Ambiguous authored allocation stack')
    return next(iter(found), None)


def validate_profile(profile, cut, binary, symbols):
    binary = str(Path(binary).resolve())
    executable_maps = [row for row in profile['maps'] if row['path'] == binary and 'x' in row['permissions']]
    require(executable_maps, 'Fixture executable mapping absent')
    for site in SITE_LIFETIMES:
        require(site in symbols, 'Required authored symbol absent')
        start, size = symbols[site]
        require(size > 0 and any(row['start'] <= start < start+size <= row['end'] for row in executable_maps),
                'Authored symbol not bound to exact executable mapping')
    actual = {name: [0,0,0,0] for name in SITE_LIFETIMES}
    for row in profile['buckets']:
        site = site_for_stack(row['stack'], symbols)
        if site:
            actual[site] = [a+b for a,b in zip(actual[site],row['counters'])]
    expected = expected_sites(cut)
    require(actual == expected, 'Authored per-site live/cumulative oracle mismatch at '+cut)
    return {'id': cut, 'allCounters': list(profile['header']), 'authoredSites': actual,
            'authoredLiveBytes': sum(row[1] for row in actual.values()),
            'authoredLiveBlocks': sum(row[0] for row in actual.values()),
            'profileSha256': profile['sha256'], 'profileBytes': profile['bytes'],
            'bucketCount': len(profile['buckets']), 'matches': True}


def validate_official(raw, profile, cut, symbols, mode):
    # Raw output has undergone upstream allocator-frame removal/PC adjustment.
    # Re-identify author wrappers by their original ELF byte extents and demand
    # the official symbol text for each required author frame agree as well.
    index = {'inuse_objects': 0, 'inuse_space': 1}[mode]
    require(raw['total'] == profile['header'][index], 'Official whole-profile integer total differs')
    actual = {name: 0 for name in SITE_LIFETIMES}
    present = set()
    for stack, count in raw['stacks'].items():
        site = site_for_stack(stack, symbols)
        if site:
            pcs = [pc for pc in stack if symbols[site][0] <= pc < sum(symbols[site])]
            require(any(re.search(r'(?<![A-Za-z0-9_])'+re.escape(site)+r'(?![A-Za-z0-9_])', raw['symbols'].get(pc, '')) for pc in pcs),
                    'Official required author frame unresolved or identity differs')
            actual[site] += count
            present.add(site)
    expected = expected_sites(cut)
    require(actual == {site: values[index] for site, values in expected.items()},
            'Official author integer counts differ')
    # Zero-inuse but historically allocated buckets must remain symbolized in
    # --raw; otherwise cumulative completeness could hide a missing zero503 site.
    require({site for site, values in expected.items() if values[2]} <= present,
            'Official historically allocated author stack missing')
    return {'mode': mode, 'total': raw['total'], 'authoredSites': actual, 'matches': True}
