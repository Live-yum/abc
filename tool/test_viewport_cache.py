#!/usr/bin/env python3
"""Actual-ABI viewport cache contracts against a frozen uncached library.

Only synthetic correctness work is performed. No timings, performance workload,
download, Flutter/Dart SDK, engine-source edits, or remote writes are involved.
The imported Engine owns real native handles and services the existing ABI 2
READ/WRITE/RESULT protocol. Native-host metadata checks require separate Dart
integration on an authorized runner; the failure tests here model the host's
read-error/cancel behavior at an actual native one-byte READ event.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import tempfile

from test_sparse_lamp_queries import Engine, P, U
from test_wired_lights import write_world


SCENE = dict(x=0, y=8, width=96, height=42, stride=1)
LAMPS = [(28, 10), (63, 29), (65, 28), (70, 27), (70, 28)]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def rows(data):
    return list(struct.iter_unpack('<4I', data))


def reopened_rows(data):
    # The existing WLD reader deliberately initializes timers as disabled.
    # No other field may differ across save/reopen of this synthetic world.
    return [(x, y, cell, frame & 65535 if cell & 65535 == 144 else frame)
            for x, y, cell, frame in rows(data)]


def fixture(path, alternate=False):
    """Independent synthetic tile encoder, including all four tile headers.

    The release-139 section skeleton is reused solely as a parser fixture; all
    header flags accepted by the native tile ABI are deliberately represented,
    including wall visibility flags normally emitted by newer game versions.
    This is not a claim that Terraria release 139 produces those flags.
    """
    cells = {}
    for x in range(3, 55):
        cells[x, 10] = (0, 0, 0, 15, 0, 0)
    kinds = list(range(255, 269)) + [33, 49, 174, 372, 646, 4, 421, 422, 419, 130, 131]
    for x, kind in enumerate(kinds, 6):
        cells[x, 10] = (kind, 18 if kind == 419 and alternate else 0, 0, 15, 0, 0)
    # Preserve actuator restrictions in the same branches as ordinary toggles.
    for x, kind in enumerate((255, 262, 421, 422, 1), 33):
        cells[x, 10] = (kind, 0, 0, 15, 1, 0)
    for x, kind, height in ((50, 42, 2), (52, 93, 3)):
        for y in range(height):
            cells[x, 10+y] = (kind, 0, (height*2+y)*18, 15 if y == 0 else 0, 1, 0)
    for x in range(3, 36):
        cells[x, 20] = (0, 0, 0, 15, 0, 0)
    cells[10, 20] = (136, 0, 0, 15, 0, 0)
    for x, kind in ((20, 132), (30, 411)):
        for dx in range(2):
            for dy in range(2):
                cells[x+dx, 20+dy] = (kind, dx*18, dy*18, 15, 0, 0)
    for x in range(10, 15):
        cells[x, 24] = (144 if x == 10 else 4 if x == 14 else 0, 0, 0, 1, 0, 0)
    # Ordinary, optimized faulty/single-lamp, and RNG-sensitive general gates.
    for x in range(60, 64):
        cells[x, 29] = (419 if x == 63 else 0, 0, 0, 1, 0, 0)
    cells[63, 30] = (420, 0, 0, 2, 0, 0)
    for x in range(64, 66):
        cells[x, 27] = (419 if x == 65 else 0, 36 if x == 65 else 0, 0, 1, 0, 0)
    cells[65, 28], cells[65, 29] = (419, 18, 0, 0, 0, 0), (420, 36, 0, 2, 0, 0)
    for x in range(67, 71):
        cells[x, 26] = (419 if x == 70 else 0, 36 if x == 70 else 0, 0, 1, 0, 0)
    cells[70, 27], cells[70, 28], cells[70, 29] = (
        (419, 0, 0, 0, 0, 0), (419, 18, 0, 0, 0, 0), (420, 36, 0, 2, 0, 0))
    # Separate four-colour H/V ports plus all three junction orientations.
    cells[80, 40] = (445, 0, 0, 15, 0, 0)
    for x, y, mask in ((79, 40, 5), (81, 40, 5), (80, 39, 10), (80, 41, 10)):
        cells[x, y] = (0, 0, 0, mask, 0, 0)
    for x, frame in ((86, 0), (90, 18), (94, 36)):
        cells[x, 40] = (424, frame, 0, 15, 0, 0)
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            cells[x+dx, 40+dy] = (419, 0, 0, 15, 0, 0)
    cells[5, 45] = (500, -32768, 32767, 0, 0, 0)
    width, height = 385, 64
    write_world(path, cells, width=width, height=height)
    raw = path.read_bytes()
    starts = list(struct.unpack_from('<7i', raw, 26)) + [len(raw)]
    sections = [raw[starts[i]:starts[i+1]] for i in range(7)]
    tiles = bytearray()
    for x in range(width):
        for y in range(height):
            kind, fx, fy, wires, actuator, inactive = cells.get((x, y), (0, 0, 0, 0, 0, 0))
            wall = (1 + (x % 7)) if (x + y) % 5 == 0 else 0
            paint = (x + y) % 31 if wall else 0
            h4 = (4 if wall and x % 2 else 0) | (16 if wall and y % 2 else 0)
            h3 = bool(h4) | (2 if actuator else 0) | (4 if inactive else 0)
            h3 |= (16 if paint else 0) | (32 if wires & 8 else 0)
            h2 = bool(h3) | ((wires & 7) << 1)
            h1 = bool(h2) | (2 if kind else 0) | (4 if wall else 0) | (32 if kind > 255 else 0)
            tiles.append(h1)
            if h2: tiles.append(h2)
            if h3: tiles.append(h3)
            if h4: tiles.append(h4)
            if kind:
                tiles.append(kind & 255)
                if kind > 255: tiles.append(kind >> 8)
                tiles += struct.pack('<hh', fx, fy)
            if wall:
                tiles.append(wall)
                if paint: tiles.append(paint)
    sections[1] = tiles
    cursor, pointers = starts[0], []
    for section in sections:
        pointers.append(cursor)
        cursor += len(section)
    prefix = bytearray(raw[:starts[0]])
    struct.pack_into('<7i', prefix, 26, *pointers)
    path.write_bytes(prefix+b''.join(sections))


def snapshot(engine):
    value = engine.stats()
    return dict(topology=value[2:15], counters=value[18:24])


def drain(engine, budget=4096, hold_result=False):
    data, reads = bytearray(), []
    for _ in range(2000000):
        event, pointer = engine.step(budget)
        if event[1] == 1:
            reads.append(event[2:5])
        if event[1] == 3:
            value = C.string_at(pointer, event[4])
            address = C.cast(pointer, C.c_void_p).value
            repeated, same_pointer = engine.step(1)
            assert repeated == event, 'pending RESULT event changed before ACK'
            assert C.cast(same_pointer, C.c_void_p).value == address, 'RESULT pointer moved before ACK'
            assert C.string_at(same_pointer, repeated[4]) == value, 'RESULT bytes changed before ACK'
            assert engine.begin(1, **SCENE) == -3, 'concurrent command accepted during RESULT'
            if hold_result:
                return value, reads, event
        if event[1] == 4:
            return bytes(data), reads, event
        engine.handle(event, pointer, data)
    raise AssertionError('bounded ABI command did not complete')


class Pair:
    def __init__(self, libraries, path, streamed, mode, records):
        self.engines = [Engine(library, path, streamed) for library in libraries]
        self.streamed, self.records = streamed, records
        self.command('mode', 10, mask=mode)

    def equal(self, label, a, b):
        assert a == b, f'{label}: frozen/candidate differ: {a!r} != {b!r}'

    def command(self, label, kind, points=(), budget=4096, **fields):
        values = [e.command(kind, points=points, budget=budget, **fields) for e in self.engines]
        self.equal(label, *values)
        self.equal(label+'/state', *[snapshot(e) for e in self.engines])
        return values[0]

    def query(self, label, budget=4096, expected_probe=None, **fields):
        answers, read_events = [], []
        for engine in self.engines:
            before = snapshot(engine)
            engine.check(engine.begin(1, **fields))
            data, reads, event = drain(engine, budget)
            assert snapshot(engine) == before, label+': read changed simulation state'
            assert event[9] == 1 and event[1] == 4
            stride = fields.get('stride', 1) or 1
            expected_xy = [(x, y) for x in range(fields['x'], fields['x']+fields['width'], stride)
                           for y in range(fields['y'], fields['y']+fields['height'], stride)]
            assert [r[:2] for r in rows(data)] == expected_xy, label+': wrong sampling/order'
            answers.append(data)
            read_events.append(reads)
        self.equal(label, *answers)
        self.equal(label+'/state', *[snapshot(e) for e in self.engines])
        if expected_probe is not None and self.streamed:
            source_reads = [r for r in read_events[1] if r[0] == 1]
            if expected_probe:
                assert len(source_reads) == 1 and source_reads[0][2] == 1, (label, source_reads)
            else:
                assert source_reads and any(r[2] > 1 for r in source_reads), (label, source_reads)
        self.records.append(dict(case=label, records=len(answers[0])//16, sha256=sha(answers[0]),
                                 counters=snapshot(self.engines[0])['counters'],
                                 candidate_source_reads=[r for r in read_events[1] if r[0] == 1]))
        return answers[0]

    def save(self, label, path, budget=4096):
        values = []
        for engine in self.engines:
            engine.files[3].seek(0)
            engine.files[3].truncate()
            engine.command(6, source_id=3, budget=budget)
            engine.files[3].seek(0)
            values.append(engine.files[3].read())
        self.equal(label, *values)
        path.write_bytes(values[0])
        self.records.append(dict(case=label, bytes=len(values[0]), sha256=sha(values[0])))

    def close(self):
        for engine in self.engines:
            engine.close()


def mutation_suite(pair, prefix, budget):
    initial = pair.query(prefix+'/live/initial', budget, **SCENE)
    initial_rows = {(r[0], r[1]): r for r in rows(initial)}
    assert initial_rows[5, 45][3] == 0x7fff8000, 'signed frames not preserved'
    operations = [(f'colour-{mask}', 2, dict(x=3, y=10, width=1, height=1, mask=mask, count=1))
                  for mask in (1, 2, 4, 8, 3, 15)]
    operations += [('multi-pulse', 2, dict(x=3, y=10, width=1, height=1, mask=1, count=3)),
                   ('pixel-four-ports', 2, dict(x=79, y=39, width=3, height=3, mask=15, count=1)),
                   ('pixel-two-colours', 2, dict(x=79, y=39, width=3, height=3, mask=3, count=1))]
    for x in (86, 90, 94):
        operations.append((f'junction-{x}', 2, dict(x=x-1, y=40, width=1, height=1, mask=15, count=1)))
    for x, y in ((60, 29), (64, 27), (67, 26)):
        operations.append((f'gate-{x}', 2, dict(x=x, y=y, width=1, height=1, mask=1, count=7)))
    for x, y in ((10, 20), (20, 20), (30, 20), (10, 24)):
        operations.append((f'interact-{x}-{y}', 2, dict(x=x, y=y, width=1, height=1, mask=15, count=1, flags=1)))
    operations += [('ticks-59', 3, dict(count=59)), ('ticks-boundary', 3, dict(count=1)),
                   ('ticks-two-pulses', 3, dict(count=120))]
    changed = set()
    previous = initial
    for name, kind, fields in operations:
        pair.command(prefix+'/'+name, kind, budget=budget, **fields)
        current = pair.query(prefix+'/'+name+'/warm', budget, expected_probe=True, **SCENE)
        for old, new in zip(rows(previous), rows(current)):
            if old != new:
                changed.add(old[2] & 65535)
        previous = current
    pair.command(prefix+'/write-lamps', 5, points=[(28, 10, 1), (63, 29, 0), (70, 27, 1)], budget=budget)
    pair.query(prefix+'/write-lamps/warm', budget, expected_probe=True, **SCENE)
    pair.command(prefix+'/lamp-values', 4, points=LAMPS, budget=budget)
    pixel_data = pair.command(prefix+'/pixels', 9, x=0, y=8, width=96, height=42, budget=budget)
    assert len(pixel_data) == 16 and rows(pixel_data)[0][:2] == (80, 40)
    # All listed device/projection families must actually change, rather than
    # merely appearing unchanged in equal snapshots.
    required = set(range(255, 269)) | {4, 33, 49, 174, 372, 646, 419, 420, 421, 422,
                                     132, 136, 144, 411, 42, 93, 130, 131, 1, 445}
    assert required <= changed, (prefix, 'unexercised live branches', sorted(required-changed))
    pair.records.append(dict(case=prefix+'/live-branches', changed_tile_types=sorted(changed)))
    for enabled in (0, 1, 0, 1):
        pair.command(prefix+f'/mode-{enabled}', 10, mask=enabled)
        pair.query(prefix+f'/mode-{enabled}/first', budget, **SCENE)
        pair.query(prefix+f'/mode-{enabled}/warm', budget, expected_probe=True, **SCENE)


def cancel_mutation(pair, prefix, kind, fields, budget):
    before = pair.query(prefix+'/before', budget, **SCENE)
    for engine in pair.engines:
        baseline = engine.stats()
        engine.check(engine.begin(kind, **fields))
        for _ in range(100000):
            event, pointer = engine.step(1)
            engine.handle(event, pointer, bytearray())
            now = engine.stats()
            if now[20] > baseline[20] and (kind != 3 or now[18] > baseline[18]):
                break
            assert event[1] != 4, 'mutation completed before cancellation point'
        else:
            raise AssertionError('mutation never reached its first pulse')
        assert engine.lib.abc_world_circuit_cancel(engine.circuit) == 0
        assert engine.stats()[18:20] == baseline[18:20], 'cancel did not roll back ticks'
    after = pair.query(prefix+'/after', budget, expected_probe=False, **SCENE)
    assert after == before, 'cancel did not roll back live tiles'
    pair.equal(prefix+'/counters', *[snapshot(e) for e in pair.engines])
    pair.command(prefix+'/continuation', kind, budget=budget, **fields)
    pair.query(prefix+'/continued', budget, expected_probe=True, **SCENE)


def wait_source_read(engine):
    for _ in range(200000):
        event, pointer = engine.step(1)
        if event[1] == 1 and event[2] == 1:
            return event, pointer
        assert event[1] not in (3, 4), 'query returned a result before required source validation'
        engine.handle(event, pointer, bytearray())
    raise AssertionError('source READ not reached')


def protocol_suite(pair, prefix, saved):
    reference, candidate = pair.engines
    saved_cases = []
    pair.query(prefix+'/seed', **SCENE)
    expected = pair.query(prefix+'/warm', expected_probe=True, **SCENE)
    candidate.check(candidate.begin(1, **SCENE))
    event, pointer = wait_source_read(candidate)
    assert event[4] == 1 and not pointer, 'warm hit must issue a pointer-free one-byte READ'
    original = candidate.read(event)
    for source, offset, data, length in ((2, event[3], original, 1),
                                         (1, event[3]+1, original, 1),
                                         (1, event[3], original, 0),
                                         (1, event[3], None, 1)):
        assert candidate.lib.abc_world_circuit_supply(candidate.circuit, source, offset, data, length) == -1
        repeated, _ = candidate.step(4096)
        assert repeated == event, 'invalid supply consumed or replaced pending READ'
    assert candidate.lib.abc_world_circuit_ack(candidate.circuit) == -3
    candidate.check(candidate.lib.abc_world_circuit_supply(candidate.circuit, 1, event[3], original, 1))
    result, _, _ = drain(candidate)
    assert result == expected, 'valid retry after rejected supply changed output'
    pair.records.append(dict(case=prefix+'/mismatched-supply', rejected=['source', 'offset', 'length', 'null'], retry='passed'))
    for name in ('pending-probe', 'partial-hit', 'pending-result', 'host-read-error', 'host-short-read'):
        pair.query(prefix+'/'+name+'/seed', **SCENE)
        candidate.check(candidate.begin(1, **SCENE))
        probe, _ = wait_source_read(candidate)
        assert probe[4] == 1
        repeated, _ = candidate.step(4096)
        assert repeated == probe, 'READ was not repeatable'
        if name in ('partial-hit', 'pending-result'):
            data = candidate.read(probe)
            candidate.check(candidate.lib.abc_world_circuit_supply(candidate.circuit, 1, probe[3], data, 1))
            if name == 'partial-hit':
                partial, _ = candidate.step(1)
                assert partial[1] == 0, 'one work unit emitted a full 4032-cell hit'
            else:
                result, _, _ = drain(candidate, hold_result=True)
                assert result == expected
        elif name in ('host-read-error', 'host-short-read'):
            # Exactly where the native Dart host would detect changed
            # size/mtime/type or another read error and cancel the command.
            class FailingSource:
                def seek(self, offset):
                    assert offset == probe[3]

                def read(self, length):
                    assert length == 1
                    if name == 'host-short-read':
                        return b''
                    raise OSError('synthetic source read rejected by host')

            source = candidate.files[1]
            candidate.files[1] = FailingSource()
            try:
                try:
                    candidate.read(probe)
                except (OSError, AssertionError):
                    pass
                else:
                    raise AssertionError('host source failure was not exercised')
            finally:
                candidate.files[1] = source
        assert candidate.lib.abc_world_circuit_cancel(candidate.circuit) == 0
        assert candidate.lib.abc_world_circuit_supply(candidate.circuit, 1, probe[3], original, 1) == -1
        idle, _ = candidate.step(4096)
        assert idle[1] == 4, 'cancelled query retained a pending RESULT'
        assert pair.query(prefix+'/'+name+'/recovery', expected_probe=False, **SCENE) == expected
        target = saved.with_name(saved.stem+'-'+name+'.wld')
        pair.save(prefix+'/'+name+'/save', target)
        saved_cases.append((name, target, expected))
    # A cold partial cache build must not become usable after cancellation.
    cold = dict(x=96, y=0, width=64, height=64, stride=1)
    for engine in pair.engines:
        engine.check(engine.begin(1, **cold))
        for _ in range(100000):
            event, pointer = engine.step(1)
            assert event[1] not in (3, 4)
            engine.handle(event, pointer, bytearray())
            if event[1] == 0 and event[7] > cold['x']:
                break
        else:
            raise AssertionError('cold query never crossed first ROI column')
        assert engine.lib.abc_world_circuit_cancel(engine.circuit) == 0
    pair.query(prefix+'/cold-fill/recovery', expected_probe=False, **cold)
    pair.query(prefix+'/cold-fill/warm', expected_probe=True, **cold)
    pair.save(prefix+'/cold-fill/save', saved)
    saved_cases.append(('cold-fill', saved, expected))
    return saved_cases


def retained_cancel_suite(pair, prefix):
    for stage in ('partial', 'result'):
        pair.query(prefix+'/'+stage+'/seed', **SCENE)
        expected = pair.query(prefix+'/'+stage+'/warm', **SCENE)
        candidate = pair.engines[1]
        candidate.check(candidate.begin(1, **SCENE))
        if stage == 'partial':
            event, _ = candidate.step(1)
            assert event[1] == 0
        else:
            result, _, _ = drain(candidate, hold_result=True)
            assert result == expected
        assert candidate.lib.abc_world_circuit_cancel(candidate.circuit) == 0
        assert pair.query(prefix+'/'+stage+'/recovery', **SCENE) == expected


def rejection_suite(libraries, root, records):
    path = root/'large.wld'
    write_world(path, {}, width=257, height=257)
    pair = Pair(libraries, path, True, 0, records)
    try:
        for fields in (dict(x=0,y=0,width=257,height=257,stride=1),
                       dict(x=0,y=0,width=0,height=1,stride=1),
                       dict(x=256,y=0,width=2,height=1,stride=1),
                       dict(x=0,y=0,width=1,height=1,stride=1,flags=1)):
            values = [e.begin(1, **fields) for e in pair.engines]
            assert values == [-1, -1], values
        pair.query('oversized-raw/sampled-valid', x=0,y=0,width=257,height=257,stride=2)
        pair.query('oversized-raw/repeated', expected_probe=False, x=0,y=0,width=257,height=257,stride=2)
        pair.save('rejected-query/save-remains-valid', root/'rejected-save.wld')
    finally:
        pair.close()
    # Same-colour distinct PixelBox axes intentionally refuse optimized mode.
    path = root/'refused-mode.wld'
    write_world(path, {(10,10):(445,0,0,1,0,0), (9,10):(0,0,0,1,0,0),
                       (11,10):(0,0,0,1,0,0), (10,9):(0,0,0,1,0,0),
                       (10,11):(0,0,0,1,0,0)}, width=24,height=24)
    for streamed in (False, True):
        pair = Pair(libraries, path, streamed, 0, records)
        region = dict(x=8,y=8,width=5,height=5,stride=1)
        try:
            expected = pair.query('refused-mode/seed', **region)
            assert [e.begin(10, mask=1) for e in pair.engines] == [-7,-7]
            assert pair.query('refused-mode/warm', expected_probe=True, **region) == expected
            pair.command('refused-mode/continuation', 2,x=9,y=10,width=2,height=1,mask=1,count=1)
            pair.query('refused-mode/live', expected_probe=True, **region)
        finally:
            pair.close()


def suite(libraries):
    records, source_hashes = [], {}
    with tempfile.TemporaryDirectory(prefix='viewport-cache-contract-') as directory:
        root = Path(directory)
        path, saved = root/'original.wld', root/'saved.wld'
        fixture(path)
        source_hashes['original'] = sha(path.read_bytes())
        shapes = [dict(name='one',x=384,y=63,width=1,height=1,stride=1),
                  dict(name='3072',x=61,y=8,width=64,height=48,stride=1),
                  dict(name='4096',x=64,y=0,width=64,height=64,stride=1),
                  dict(name='4097',x=64,y=10,width=241,height=17,stride=1),
                  dict(name='4097-strided',x=64,y=10,width=241,height=17,stride=2),
                  dict(name='stride0',x=61,y=25,width=12,height=10,stride=0),
                  dict(name='stride1-normalized',x=61,y=25,width=12,height=10,stride=1),
                  dict(name='stride2',x=61,y=25,width=12,height=10,stride=2),
                  dict(name='stride-large',x=61,y=25,width=12,height=10,stride=999),
                  dict(name='gate-outside-roi',x=65,y=28,width=6,height=1,stride=1),
                  dict(name='pan',x=62,y=25,width=12,height=10,stride=1)]
        for streamed in (False, True):
            for mode in (0, 1):
                for budget in (1, 4096):
                    prefix = f'{"streamed" if streamed else "retained"}/mode{mode}/budget{budget}'
                    pair = Pair(libraries, path, streamed, mode, records)
                    try:
                        for shape in shapes:
                            region = dict(shape)
                            name = region.pop('name')
                            eligible = region['width']*region['height'] <= 4096
                            # Both flag orders exercise one key across both layers.
                            flags = (2,0,2,0) if mode else (0,2,0,2)
                            for index, flag in enumerate(flags):
                                pair.query(prefix+'/'+name+f'/layer{flag}/{index}', budget,
                                           expected_probe=eligible if index else name == 'stride1-normalized',
                                           flags=flag, **region)
                        mutation_suite(pair, prefix, budget)
                        cancel_mutation(pair, prefix+'/cancel-trigger', 2,
                                        dict(x=67,y=26,width=1,height=1,mask=1,count=9), budget)
                        cancel_mutation(pair, prefix+'/cancel-ticks', 3, dict(count=180), budget)
                        pair.save(prefix+'/save', saved, budget)
                        expected = pair.query(prefix+'/before-reopen', budget, **SCENE)
                    finally:
                        pair.close()
                    reopened = Pair(libraries, saved, streamed, 1, records)
                    try:
                        actual = reopened.query(prefix+'/reopen/cold', budget, expected_probe=False, **SCENE)
                        assert rows(actual) == reopened_rows(expected), 'reopen changed a field other than disabled timer frame_y'
                        reopened.query(prefix+'/reopen/warm', budget, expected_probe=True, **SCENE)
                        reopened.command(prefix+'/reopen/continue', 2,x=67,y=26,width=1,height=1,mask=1,count=11,budget=budget)
                        reopened.query(prefix+'/reopen/continued', budget, expected_probe=True, **SCENE)
                    finally:
                        reopened.close()
                    assert sha(path.read_bytes()) == source_hashes['original'], 'original source changed'
        for streamed in (False, True):
            pair = Pair(libraries, path, streamed, 0, records)
            saved_cases = []
            try:
                if streamed:
                    saved_cases = protocol_suite(pair, 'protocol/streamed', saved)
                else:
                    retained_cancel_suite(pair, 'protocol/retained')
            finally:
                pair.close()
            for name, saved_path, expected in saved_cases:
                reopened = Pair(libraries, saved_path, True, 0, records)
                try:
                    actual = reopened.query('protocol/'+name+'/reopen-cold', expected_probe=False, **SCENE)
                    assert rows(actual) == reopened_rows(expected)
                    reopened.query('protocol/'+name+'/reopen-warm', expected_probe=True, **SCENE)
                    reopened.command('protocol/'+name+'/reopen-continue', 2,
                                     x=67,y=26,width=1,height=1,mask=1,count=7)
                    reopened.query('protocol/'+name+'/reopen-continued', expected_probe=True, **SCENE)
                finally:
                    reopened.close()
        # Closing and reusing the same host source IDs must never reuse entries.
        other = root/'other.wld'
        fixture(other, alternate=True)
        source_hashes['alternate'] = sha(other.read_bytes())
        for current in (path, other, path):
            pair = Pair(libraries, current, True, 0, records)
            try:
                value = pair.query('close-reopen-new-source/'+current.name, expected_probe=False, **SCENE)
                frame = {(r[0],r[1]): r[3]&65535 for r in rows(value)}[28,10]
                assert frame == (18 if current == other else 0)
                pair.query('close-reopen-new-source/'+current.name+'/warm', expected_probe=True, **SCENE)
            finally:
                pair.close()
        rejection_suite(libraries, root, records)
    return dict(status='passed', abi=2, libraries=[str(Path(x).resolve()) for x in libraries],
                library_sha256=[sha(Path(x).read_bytes()) for x in libraries],
                source_sha256=source_hashes, original_source_unchanged=True,
                save_reopen_normalization='Existing WLD load resets timer (type144) frame_y to zero; every other packed field is exact',
                native_owner_cleanup='Engine.close verified zero tracked live bytes when supported',
                contract_cases=records,
                not_run=['Dart host changed-size/mtime/type integration requires an authorized runner',
                         'Flutter/Dart SDK', 'timing or performance experiment',
                         'allocator and active-VM pressure contracts are a separate C suite'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference_library')
    parser.add_argument('candidate_library')
    parser.add_argument('--output', required=True)
    arguments = parser.parse_args()
    result = suite([arguments.reference_library, arguments.candidate_library])
    Path(arguments.output).write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(status=result['status'], cases=len(result['contract_cases']), output=arguments.output)))
