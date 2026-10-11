#!/usr/bin/env python3
"""Strict, bounded Heaptrack 1.5.0 raw-v3 contract accounting.

This is not a symbolizer. Marker PCs are verified against nm/readelf identities;
the unmodified distribution interpreter provides symbolization and an independent
integer-byte export. Unknown frees are counted, never invented as allocations.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import re

MAX_RECORD = 65536
MAX_DECODED = 64 * 1024 * 1024
MAX_RECORDS = 1_000_000
VERSION = (0x10500, 3)
MARKER_IDS = ('q0.begin', 'q0.end', 'q7.begin', 'q7.end')
HEX = re.compile(rb'[0-9a-f]+\Z')


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


def hexes(data, count=None):
    tokens = data.split(b' ')
    require(all(HEX.fullmatch(token) for token in tokens), 'Malformed hexadecimal field')
    require(count is None or len(tokens) == count, 'Wrong hexadecimal field count')
    values = [int(token, 16) for token in tokens]
    require(all(value < 2**64 for value in values), 'Hexadecimal field exceeds uint64')
    return values


def sized_string(data):
    size_token, sep, rest = data.partition(b' ')
    require(bool(sep), 'Missing sized-string delimiter')
    size = hexes(size_token, 1)[0]
    require(size <= len(rest), 'Truncated sized string')
    value = rest[:size].decode('utf-8', 'strict')
    tail = rest[size:]
    require(not tail or tail.startswith(b' '), 'Missing sized-string tail delimiter')
    return value, tail[1:] if tail else b''


def pointer(value):
    require(isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]+', value),
            'Invalid fixture pointer')
    number = int(value, 16)
    require(0 <= number < 2**64, 'Fixture pointer exceeds uint64')
    return number


def read_fixture(path):
    raw = Path(path).read_bytes()
    require(len(raw) <= 1024 * 1024 and raw.endswith(b'\n'), 'Fixture JSONL incomplete or oversized')
    rows = [json.loads(line) for line in raw.splitlines()]
    require(all(isinstance(row, dict) for row in rows), 'Fixture record is not an object')
    metadata = [row for row in rows if row.get('type') == 'metadata']
    operations = [row for row in rows if row.get('type') == 'operation']
    markers = [row for row in rows if row.get('type') == 'marker']
    summaries = [row for row in rows if row.get('type') == 'summary']
    require(len(metadata) == len(summaries) == 1, 'Fixture header/summary multiplicity')
    require(metadata[0].get('schema') == 'abc.heaptrack-contract.v1', 'Fixture schema differs')
    require(metadata[0].get('maxAuthoredOperations') == 32, 'Fixture authored budget differs')
    require(0 < len(operations) <= 32, 'Fixture authored operation budget exceeded')
    require([row.get('ordinal') for row in operations] == list(range(len(operations))),
            'Fixture operation ordinal missing or duplicated')
    require([row.get('id') for row in markers] == list(MARKER_IDS), 'Fixture cut order differs')
    require(len({row.get('symbol') for row in markers}) == 4, 'Marker symbols not distinct')
    summary = summaries[0]
    require(summary.get('completed') is True and summary.get('authoredOperations') == len(operations)
            and summary.get('markerCount') == 4 and summary.get('fixtureLiveBytes') == 0
            and summary.get('fixtureLiveBlocks') == 0 and summary.get('reallocZeroFreed') is True,
            'Native fixture semantic summary failed')
    require(len(rows) == len(operations) + 6, 'Unexpected fixture record type')
    kinds = {row.get('kind') for row in operations}
    require({'malloc', 'calloc', 'realloc', 'free'} <= kinds, 'Required operation kind absent')
    names = {row.get('name'): row for row in operations}
    require(len(names) == len(operations), 'Authored operation names duplicated')
    failed = names.get('realloc_failure_size_max', {})
    zero = names.get('realloc_zero_frees_source', {})
    require(failed.get('kind') == 'realloc' and failed.get('requestedBytes') == 2**64 - 1
            and failed.get('resultPointer') is None and failed.get('success') is False
            and failed.get('formerAllocationFreed') is False
            and failed.get('errno') == metadata[0].get('enomem')
            and pointer(failed.get('oldPointer')) > 0, 'Failed-realloc preservation contract absent')
    require(zero.get('kind') == 'realloc' and zero.get('requestedBytes') == 0
            and zero.get('resultPointer') is None and zero.get('success') is True
            and zero.get('formerAllocationFreed') is True
            and pointer(zero.get('oldPointer')) > 0, 'Realloc-zero free contract absent')
    for marker in markers:
        ordinal = marker.get('operationOrdinal')
        require(type(ordinal) is int and 0 <= ordinal < len(operations), 'Marker operation missing')
        op = operations[ordinal]
        require(op.get('kind') == 'malloc' and op.get('name') == marker['symbol']
                and op.get('requestedBytes') == marker.get('requestedBytes')
                and pointer(op.get('resultPointer')) == pointer(marker.get('pointer')),
                'Marker does not bind to its actual authored allocation')
        expected = marker.get('expectedLive')
        require(isinstance(expected, list), 'Expected live set absent')
        points = [pointer(row.get('pointer')) for row in expected]
        require(all(points) and len(set(points)) == len(points), 'Expected live pointers invalid')
        require(all(type(row.get('bytes')) is int and row['bytes'] > 0 for row in expected),
                'Expected live sizes invalid')
        require(sum(row['bytes'] for row in expected) == marker.get('expectedLiveBytes')
                and len(expected) == marker.get('expectedLiveBlocks'), 'Expected live totals disagree')
    return {'metadata': metadata[0], 'operations': operations, 'markers': markers, 'summary': summary}


@dataclass
class Allocation:
    size: int
    trace: int
    fixture: bool
    marker: str | None


def parse_raw(path, fixture, executable, symbols):
    """Return integrity issues and exact live accounting at marker event prefixes.

    `symbols` is an externally verified name -> (ELF virtual address, byte size)
    map. All raw trace IDs are positional, as in the upstream recorder.
    """
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Raw trace is not an ordinary file')
    require(path.stat().st_size <= MAX_DECODED, 'Decoded raw byte limit exceeded')
    executable = str(Path(executable).resolve())
    markers = fixture['markers']
    by_symbol = {row['symbol']: row for row in markers}
    require(all(name in symbols for name in by_symbol), 'Marker ELF symbol absent')
    owned_names = {name for name in symbols if name.startswith('abc_fixture_')}
    require(bool(owned_names), 'Fixture allocation wrapper symbols absent')
    traces = [None]
    modules = []
    live = {}
    observed = {}
    marker_frees = defaultdict(int)
    issues = []
    unknown_frees = 0
    record_count = 0
    allocation_events = 0
    free_events = 0
    total_bytes = 0
    exe = None
    version_seen = False
    seen_clock = False
    last_clock = -1
    last_mode = None
    trace_symbols = {}
    authored_events = []

    def names_for_trace(trace_id):
        if trace_id in trace_symbols:
            return trace_symbols[trace_id]
        found = set()
        seen = set()
        cursor = trace_id
        while cursor:
            require(cursor < len(traces) and cursor not in seen, 'Trace reference invalid/cyclic')
            seen.add(cursor)
            ip, parent, bound_modules = traces[cursor]
            for name, base, spans in bound_modules:
                if name == executable and any(lo <= ip < hi for lo, hi in spans):
                    for symbol, (start, length) in symbols.items():
                        if base + start <= ip < base + start + length:
                            found.add(symbol)
            cursor = parent
        trace_symbols[trace_id] = found
        return found

    with path.open('rb') as stream:
        while True:
            offset = stream.tell()
            line = stream.readline(MAX_RECORD + 1)
            if not line:
                break
            record_count += 1
            total_bytes += len(line)
            require(record_count <= MAX_RECORDS, 'Raw record count exceeded')
            require(total_bytes <= MAX_DECODED, 'Decoded raw byte limit exceeded')
            require(len(line) <= MAX_RECORD and line.endswith(b'\n'), 'Raw record oversized or truncated')
            require(b'\x00' not in line, 'NUL in raw record')
            data = line[:-1]
            if not data or data.startswith(b'#'):
                continue
            require(len(data) >= 2 and data[1:2] == b' ', 'Malformed raw record prefix')
            mode, payload = data[:1], data[2:]
            require(version_seen or mode == b'v', 'Raw header not first')
            if mode == b'v':
                require(not version_seen and tuple(hexes(payload, 2)) == VERSION,
                        'Heaptrack version/file format differs or duplicated')
                version_seen = True
            elif mode == b'x':
                require(exe is None, 'Duplicate raw executable')
                exe, tail = sized_string(payload)
                require(not tail and str(Path(exe).resolve()) == executable, 'Unexpected profiled executable')
            elif mode == b'm':
                name, tail = sized_string(payload)
                if name == '-':
                    require(not tail, 'Malformed module reset')
                    modules = []
                else:
                    require(exe is not None, 'Module before executable')
                    if name == 'x':
                        name = exe
                    parts = hexes(tail)
                    require(len(parts) >= 3 and len(parts) % 2 == 1, 'Malformed module mapping')
                    base = parts[0]
                    spans = [(base + lo, base + lo + length)
                             for lo, length in zip(parts[1::2], parts[2::2])]
                    require(all(lo < hi <= 2**64 for lo, hi in spans), 'Invalid module segment')
                    modules.append((str(Path(name).resolve()) if name.startswith('/') else name, base, spans))
            elif mode == b't':
                ip, parent = hexes(payload, 2)
                require(ip > 0 and parent < len(traces), 'Trace parent/IP invalid')
                traces.append((ip, parent, tuple(modules)))
            elif mode == b'+':
                size, trace, ptr = hexes(payload, 3)
                require(ptr > 0 and trace < len(traces), 'Allocation pointer/trace invalid')
                require(ptr not in live, 'Duplicate live pointer: a deallocation record may be missing')
                names = names_for_trace(trace)
                marker_names = names & set(by_symbol)
                require(len(marker_names) <= 1, 'Ambiguous marker trace')
                marker_name = next(iter(marker_names), None)
                if marker_name:
                    marker = by_symbol[marker_name]
                    marker_id = marker['id']
                    require(marker_id not in observed, 'Duplicate marker allocation')
                    require(marker_id == MARKER_IDS[len(observed)], 'Marker event order differs')
                    require(ptr == pointer(marker['pointer']) and size == marker['requestedBytes'],
                            'Marker pointer/size does not bind fixture metadata')
                    actual = {p: value.size for p, value in live.items() if value.fixture and not value.marker}
                    expected = {pointer(row['pointer']): row['bytes'] for row in marker['expectedLive']}
                    if actual != expected:
                        issues.append({'kind': 'fixture-live-set-mismatch', 'marker': marker_id,
                                       'expected': {hex(p): n for p, n in expected.items()},
                                       'actual': {hex(p): n for p, n in actual.items()}})
                    observed[marker_id] = {
                        'id': marker_id, 'symbol': marker_name, 'recordOrdinal': record_count,
                        'byteOffset': offset, 'allocationEventOrdinal': allocation_events,
                        'liveBytes': sum(value.size for value in live.values()), 'liveBlocks': len(live),
                        'fixtureLiveBytes': sum(actual.values()), 'fixtureLiveBlocks': len(actual),
                        'unknownFrees': unknown_frees,
                        'byTrace': dict(sorted(_by_trace(live).items())),
                    }
                live[ptr] = Allocation(size, trace, bool(names & owned_names), marker_name)
                if names & owned_names or marker_name:
                    authored_events.append(('+', ptr, size))
                allocation_events += 1
            elif mode == b'-':
                ptr = hexes(payload, 1)[0]
                require(ptr > 0, 'Null free record')
                value = live.pop(ptr, None)
                if value is None:
                    unknown_frees += 1
                elif value.marker:
                    marker_frees[value.marker] += 1
                if value is not None and (value.fixture or value.marker):
                    authored_events.append(('-', ptr))
                free_events += 1
            elif mode == b'c':
                stamp = hexes(payload, 1)[0]
                require(stamp >= last_clock, 'Raw clock moved backward')
                last_clock, seen_clock = stamp, True
            elif mode == b'R':
                hexes(payload, 1)
            elif mode == b'I':
                values = hexes(payload, 2)
                require(all(values), 'Invalid system-information record')
            elif mode in (b'X', b'S'):
                payload.decode('utf-8', 'strict')
            else:
                raise ContractError('Unsupported raw record: ' + repr(mode))
            last_mode = mode
    require(version_seen and exe is not None and len(traces) > 1 and seen_clock,
            'Raw stream misses required provenance or final time')
    require(last_mode == b'R', 'Raw shutdown tail missing')
    require(tuple(observed) == MARKER_IDS, 'Required marker missing')
    require(all(marker_frees[name] == 1 for name in by_symbol), 'Marker lifetime did not close')
    fixture_live = {hex(ptr): item.size for ptr, item in live.items() if item.fixture}
    if fixture_live:
        issues.append({'kind': 'fixture-live-after-cleanup', 'actual': fixture_live})
    expected_events = authored_expected_events(fixture['operations'])
    if authored_events != expected_events:
        mismatch = next((i for i, pair in enumerate(zip(expected_events, authored_events))
                         if pair[0] != pair[1]), min(len(expected_events), len(authored_events)))
        issues.append({'kind': 'authored-event-sequence-mismatch', 'firstMismatch': mismatch,
                       'expectedCount': len(expected_events), 'actualCount': len(authored_events),
                       'expectedEvent': expected_events[mismatch] if mismatch < len(expected_events) else None,
                       'actualEvent': authored_events[mismatch] if mismatch < len(authored_events) else None})
    return {'schema': 'abc.heaptrack-raw-contract.v1', 'valid': not issues,
            'issues': issues, 'rawSha256': sha256(path), 'rawBytes': total_bytes,
            'records': record_count, 'allocationEvents': allocation_events, 'freeEvents': free_events,
            'unknownFrees': unknown_frees, 'boundaries': list(observed.values()),
            'markerFrees': dict(marker_frees), 'finalLiveBytes': sum(v.size for v in live.values()),
            'finalLiveBlocks': len(live), 'fixtureLiveAfterCleanup': fixture_live,
            'authoredEvents': authored_events, 'expectedAuthoredEvents': expected_events,
            'boundaryAtomic': False, 'mmapCovered': False, 'profilerInternalAllocationsCovered': False}


def authored_expected_events(operations):
    expected = []
    for operation in operations:
        kind = operation['kind']
        result = operation.get('resultPointer')
        old = operation.get('oldPointer')
        if kind in ('malloc', 'calloc') and result is not None:
            expected.append(('+', pointer(result), operation['requestedBytes']))
        elif kind == 'free' and old is not None:
            expected.append(('-', pointer(old)))
        elif kind == 'realloc':
            if result is not None:
                if old is not None:
                    expected.append(('-', pointer(old)))
                expected.append(('+', pointer(result), operation['requestedBytes']))
            elif operation.get('formerAllocationFreed'):
                expected.append(('-', pointer(old)))
    return expected


def _by_trace(live):
    totals = defaultdict(int)
    for value in live.values():
        totals[str(value.trace)] += value.size
    return totals


def write_prefix(raw_path, boundary, output_path):
    remaining = boundary['byteOffset']
    require(remaining > 0, 'Empty prefix')
    with Path(raw_path).open('rb') as source, Path(output_path).open('xb') as output:
        while remaining:
            data = source.read(min(remaining, 1024 * 1024))
            require(bool(data), 'Raw prefix truncated')
            output.write(data)
            remaining -= len(data)
    return {'sha256': sha256(output_path), 'bytes': Path(output_path).stat().st_size}


def official_integer_total(path):
    """Sum all integer rows, including unresolved/zero stacks; no top-N report."""
    total, rows = 0, 0
    with Path(path).open('rb') as stream:
        for line in stream:
            require(len(line) <= MAX_RECORD and line.endswith(b'\n'), 'Official stack export truncated')
            text = line[:-1].decode('utf-8', 'strict')
            stack, separator, number = text.rpartition(' ')
            require(bool(stack) and bool(separator) and re.fullmatch(r'[0-9]+', number),
                    'Official stack export lacks exact unsigned integer')
            total += int(number)
            rows += 1
    require(rows > 0, 'Official integer stack export empty')
    return {'liveBytes': total, 'stackRows': rows, 'sha256': sha256(path)}


def interpreter_live_blocks(stderr):
    matches = re.findall(r'^\s*leaked allocations:\s*([0-9]+)\s*$', stderr, re.M)
    require(len(matches) == 1, 'Official interpreter remaining-block count absent/duplicated')
    return int(matches[0])
