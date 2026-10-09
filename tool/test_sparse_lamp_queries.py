#!/usr/bin/env python3
"""Native sparse READ_LAMPS differential and work/cancellation contract.

Run this original synthetic suite against the frozen and candidate libraries,
then compare semantic reports. The optional public-world probe uses the exact
four initialization anchors, verifies the pinned WLD and reports query timing.
No private game files or sidecar inputs are used.
"""
import argparse
import ctypes as C
import hashlib
import json
import shutil
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time

U = C.c_uint32
P = C.POINTER(C.c_uint8)
W = 1024 * 1024
ANCHORS = [(2853, 1236), (15140, 4249), (2853, 4287), (2854, 4287)]


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(W), b''):
            h.update(b)
    return h.hexdigest()


class Engine:
    def __init__(self, library, path, streamed=True):
        self.lib = C.CDLL(str(Path(library).resolve()))
        signatures = {
            'abc_alloc': ([C.c_size_t], C.c_void_p),
            'abc_free': ([C.c_void_p], None),
            'abc_world_open': ([P, U, C.POINTER(U)], C.c_int32),
            'abc_world_close': ([U], C.c_int32),
            'abc_world_stream_open_begin': ([U, U, C.POINTER(U)], C.c_int32),
            'abc_world_stream_step': ([U, U, C.POINTER(U), C.POINTER(P)], C.c_int32),
            'abc_world_stream_supply': ([U, U, U, P, U], C.c_int32),
            'abc_world_stream_adopt': ([U, U, C.POINTER(U)], C.c_int32),
            'abc_world_stream_close': ([U], C.c_int32),
            'abc_world_circuit_begin': ([U, U, U, C.POINTER(U)], C.c_int32),
            'abc_world_circuit_step': ([U, U, C.POINTER(U), C.POINTER(P)], C.c_int32),
            'abc_world_circuit_supply': ([U, U, U, P, U], C.c_int32),
            'abc_world_circuit_ack': ([U], C.c_int32),
            'abc_world_circuit_command': ([U, C.POINTER(U), C.POINTER(U)], C.c_int32),
            'abc_world_circuit_stats': ([U, C.POINTER(U)], C.c_int32),
            'abc_world_circuit_cancel': ([U], C.c_int32),
            'abc_world_circuit_close': ([U], C.c_int32),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.lib, name)
            fn.argtypes, fn.restype = args, result
        self.live_bytes = getattr(self.lib,'abc_perf_native_live_bytes',None)
        if self.live_bytes:
            self.live_bytes.argtypes, self.live_bytes.restype = [], U
        self.files = {1: open(path, 'rb'), 2: tempfile.TemporaryFile(), 3: tempfile.TemporaryFile()}
        self.world, self.circuit = U(), U()
        self.io = {'read_events': 0, 'read_bytes': 0, 'steps': 0, 'jumps': []}
        started = time.perf_counter()
        if streamed:
            task = U()
            self.check(self.lib.abc_world_stream_open_begin(1, Path(path).stat().st_size, C.byref(task)))
            while True:
                e, p = (U * 12)(), P()
                self.check(self.lib.abc_world_stream_step(task, 4096, e, C.byref(p)))
                if e[1] == 4:
                    break
                if e[1] == 1:
                    b = self.read(e)
                    self.check(self.lib.abc_world_stream_supply(task, e[2], e[3], b, e[4]))
                else:
                    assert e[1] == 0
            self.check(self.lib.abc_world_stream_adopt(task, 1, C.byref(self.world)))
            self.check(self.lib.abc_world_stream_close(task))
        else:
            raw = Path(path).read_bytes()
            p = self.lib.abc_alloc(len(raw))
            assert p
            C.memmove(p, raw, len(raw))
            self.check(self.lib.abc_world_open(C.cast(p, P), len(raw), C.byref(self.world)))
            self.lib.abc_free(p)
        self.parse_seconds = time.perf_counter() - started
        started = time.perf_counter()
        self.check(self.lib.abc_world_circuit_begin(self.world, 2, 192 * 1024 * 1024, C.byref(self.circuit)))
        self.pump()
        self.compile_seconds = time.perf_counter() - started

    @staticmethod
    def check(status):
        assert status >= 0, status
        return status

    def read(self, e):
        assert e[4] <= W
        f = self.files[e[2]]
        f.seek(e[3])
        b = f.read(e[4])
        assert len(b) == e[4]
        self.io['read_events'] += 1
        self.io['read_bytes'] += len(b)
        return (C.c_uint8 * len(b)).from_buffer_copy(b)

    def step(self, budget):
        e, p = (U * 12)(), P()
        self.check(self.lib.abc_world_circuit_step(self.circuit, budget, e, C.byref(p)))
        self.io['steps'] += 1
        return list(e), p

    def handle(self, e, p, output):
        if e[1] == 1:
            b = self.read(e)
            self.check(self.lib.abc_world_circuit_supply(self.circuit, e[2], e[3], b, e[4]))
        elif e[1] == 2:
            f = self.files[e[2]]
            f.seek(e[3])
            f.write(C.string_at(p, e[4]))
            self.check(self.lib.abc_world_circuit_ack(self.circuit))
        elif e[1] == 3:
            output.extend(C.string_at(p, e[4]))
            self.check(self.lib.abc_world_circuit_ack(self.circuit))
        else:
            assert e[1] in (0, 4)

    def pump(self, budget=4096):
        result = bytearray()
        last = 0
        for _ in range(100000000):
            e, p = self.step(budget)
            if e[1] == 0 and e[7] > last + 1:
                self.io['jumps'].append([last, e[7]])
            last = e[7]
            if e[1] == 4:
                return bytes(result)
            self.handle(e, p, result)
        raise AssertionError('pump did not complete')

    def begin(self, kind, points=(), **fields):
        words = [2, kind] + [0] * 14
        indices = dict(x=2, y=3, width=4, height=5, stride=6, mask=7, count=8, source_id=11, flags=12)
        for key, value in fields.items():
            words[indices[key]] = value
        records = [v for point in points for v in (*point, *([0] * (4-len(point))))]
        words[10] = len(points)
        return self.lib.abc_world_circuit_command(self.circuit, (U*16)(*words), (U*len(records))(*records) if records else None)

    def command(self, kind, points=(), budget=4096, **fields):
        self.check(self.begin(kind, points, **fields))
        return self.pump(budget)

    def lamps(self, points, budget=4096):
        raw = self.command(4, points, budget)
        rows = list(struct.iter_unpack('<4I', raw))
        assert len(rows) == len(points)
        assert [r[:2] for r in rows] == [tuple(p[:2]) for p in points]
        return rows

    def stats(self):
        s = (U*24)()
        self.check(self.lib.abc_world_circuit_stats(self.circuit, s))
        return list(s)

    def close(self):
        self.check(self.lib.abc_world_circuit_close(self.circuit))
        self.check(self.lib.abc_world_close(self.world))
        for f in self.files.values():
            f.close()
        if self.live_bytes:
            assert self.live_bytes() == 0, 'native owner allocation leak'


def fixture(path, rle=False):
    root = Path(__file__).resolve().parent.parent
    subprocess.run([sys.executable, str(root/'native/generate_world_fixture.py'), str(path)], check=True, stdout=subprocess.DEVNULL)
    raw = path.read_bytes()
    positions = list(struct.unpack_from('<7i', raw, 26)) + [len(raw)]
    sections = [raw[positions[i]:positions[i+1]] for i in range(7)]
    flags = bytearray(sections[0])
    at = 1 + flags[0]
    for offset, value in {8:385*16, 16:64*16, 20:64, 24:385}.items():
        struct.pack_into('<i', flags, at+offset, value)
    sections[0] = flags
    importance = bytearray(56)
    for tile in (419,420,424,445):
        importance[tile//8] |= 1 << (tile%8)
    tiles = bytearray()
    for x in range(385):
        column = []
        for y in range(64):
            tile, frame, wire = 0, 0, 0
            if y == 10:
                tile, frame, wire = 419, 18*(x%2), 2
            elif y == 11:
                tile, frame = 419, 18*(x%3 == 0)
            elif x%17 == 0 and y in (20,21,22):
                tile, frame, wire = (420 if y == 22 else 419), (18*(x%2) if y == 21 else 36), 2
            elif x%19 == 0 and y in (26,27,28):
                tile, frame, wire = (420 if y == 28 else 419), 18*(y==27), 4
            elif y == 40:
                tile, wire = (424 if x%64==0 else 445 if x%31==0 else 0), 6
                frame = 18*(x%3) if tile==424 else 0
            if tile:
                column.append(bytes((35,wire,tile&255,tile>>8)) + struct.pack('<hh',frame,0))
            elif wire:
                column.append(bytes((1,wire)))
            else:
                column.append(b'\0')
        y = 0
        while y < len(column):
            end = y + 1
            while rle and end < len(column) and column[end] == column[y]:
                end += 1
            tile = column[y]
            tiles += (bytes((tile[0] | 64,)) + tile[1:] + bytes((end-y-1,))) if end > y+1 else tile
            y = end
    sections[1] = tiles
    positions, cursor = [], 56+len(importance)
    for section in sections:
        positions.append(cursor)
        cursor += len(section)
    path.write_bytes(raw[:26] + struct.pack('<7i', *positions) + struct.pack('<h',446) + importance + b''.join(sections))


def suite(library, optimized):
    result = {}
    expected = json.loads((Path(__file__).resolve().parent.parent /
                           'native/fixtures/sparse-lamp-queries.json').read_text())
    with tempfile.TemporaryDirectory(prefix='sparse-lamps-') as directory:
        path = Path(directory)/'synthetic.wld'
        fixture(path)
        before = digest(path)
        cases = {
            'unsorted_duplicates': [(320,10),(2,10),(384,11),(64,10),(2,10),(128,11),(63,10),(320,11)],
            'same_checkpoint': [(61,11),(2,10),(63,10),(12,10)],
            'same_column': [(257,11),(257,10),(257,11),(257,40)],
            'boundaries': [(384,63),(0,0),(64,10),(63,10),(128,10),(127,10),(383,10),(0,63)],
            'gates_frontier': [(340,20),(340,21),(340,22),(323,28),(19,27),(19,28),(64,40),(31,40),(255,21)],
            'empty': [],
        }
        for streamed in (False, True):
            for name, points in cases.items():
                for budget in (1, 7, 4096):
                    engine = Engine(library, path, streamed)
                    key = f'{"stream" if streamed else "retained"}/{name}/{budget}'
                    initial = engine.stats()
                    rows = engine.lamps(points, budget)
                    assert [list(row) for row in rows] == expected[name], key
                    assert rows == engine.lamps(points, budget), 'cached repeat mismatch'
                    assert engine.stats()[18:24] == initial[18:24], 'read mutated simulation'
                    result[key] = rows
                    engine.close()
        rle_path = Path(directory)/'synthetic-rle.wld'
        fixture(rle_path, rle=True)
        for streamed in (False, True):
            engine = Engine(library,rle_path,streamed)
            for name, points in cases.items():
                rows = engine.lamps(points,1)
                assert rows == result[f'{"stream" if streamed else "retained"}/{name}/1']
            engine.close()
        result['rle_records_match'] = True
        engine = Engine(library, path)
        invalid = [[(385,10)], [(1,64)], [(1,10,0,1)]]
        result['invalid_status'] = [engine.begin(4,p) for p in invalid]
        assert result['invalid_status'] == [-1,-1,-1]
        assert engine.lib.abc_world_circuit_step(engine.circuit,0,(U*12)(),C.byref(P())) == -1
        result['after_invalid'] = engine.lamps([(3,10),(320,11)])
        points = [(384,10),(2,10),(320,10),(0,10),(2,10),(128,11)]
        result['before_write'] = engine.lamps(points)
        engine.command(5, [(320,10,1),(2,10,1),(2,10,0)])
        result['after_write'] = engine.lamps(points)
        assert [r[2] for r in result['after_write']] == [0,0,1,0,0,0]
        engine.command(2, x=3,y=10,width=1,height=1,mask=1,count=1)
        result['after_trigger'] = engine.lamps(points)
        assert [r[2] for r in result['after_trigger']] == [0,1,0,0,1,0]
        result['viewport'] = engine.command(1,x=318,y=10,width=4,height=2,stride=1).hex()
        engine.command(6,source_id=3)
        engine.files[3].seek(0)
        saved = Path(directory)/'saved.wld'
        saved.write_bytes(engine.files[3].read())
        result['saved_sha256'] = digest(saved)
        engine.close()
        engine = Engine(library,saved)
        result['reopened'] = engine.lamps(points)
        assert result['reopened'] == result['after_trigger']
        engine.close()
        for mode in ('before_jump','after_jump','pending_read','pending_result'):
            if not optimized and mode in ('after_jump','pending_read'):
                continue
            engine = Engine(library,path)
            points = [(0,10),(384,11),(0,10)]
            initial = engine.stats()[18:24]
            engine.check(engine.begin(4,points))
            engine.io['steps'] = 0
            hit = False
            for _ in range(1000000):
                e,p = engine.step(1)
                if (mode=='before_jump' and e[1]==0 and e[7]==1
                    or mode=='after_jump' and e[1]==0 and e[7]==384
                    or mode=='pending_read' and e[1]==1 and e[7]==384
                    or mode=='pending_result' and e[1]==3):
                    hit = True
                    if mode in ('after_jump','pending_read'):
                        assert engine.io['steps'] < 400, 'sparse query replayed the empty column interval'
                    if e[1] in (1,3):
                        repeated, borrowed = engine.step(1)
                        assert repeated == e, 'pending event changed without acknowledgement'
                        if e[1]==3:
                            assert C.string_at(borrowed,e[4])==C.string_at(p,e[4])
                    engine.check(engine.lib.abc_world_circuit_cancel(engine.circuit))
                    assert engine.stats()[18:24] == initial
                    assert engine.lib.abc_world_circuit_ack(engine.circuit) == -3
                    if e[1]==1:
                        b=engine.read(e)
                        assert engine.lib.abc_world_circuit_supply(engine.circuit,e[2],e[3],b,e[4]) == -1
                    break
                engine.handle(e,p,bytearray())
            assert hit, mode
            assert engine.lamps(points,1) == [(0,10,0,419),(384,11,1,419),(0,10,0,419)]
            engine.close()
        result['cancellation'] = 'all applicable checkpoints preserved state and restarted'
        # Original version-1 contiguous fixture: the unsupported-world boundary
        # must reject before any circuit query or checkpoint can be reached.
        name = b'Original legacy rejection fixture'
        legacy = (struct.pack('<iB',1,len(name)) + name + struct.pack('<7i',7,0,16,0,16,1,1)
                  + struct.pack('<ii3dBiBii',0,0,0.,0.,0.,1,0,0,0,0) + bytes(6)
                  + struct.pack('<3id',0,0,0,0.) + struct.pack('<BBhhBBB',1,3,12,34,0,0,0)
                  + bytes(2001))
        pointer = engine.lib.abc_alloc(len(legacy))
        assert pointer
        C.memmove(pointer,legacy,len(legacy))
        world, circuit = U(), U()
        engine.check(engine.lib.abc_world_open(C.cast(pointer,P),len(legacy),C.byref(world)))
        assert engine.lib.abc_world_circuit_begin(world,2,W,C.byref(circuit)) == -7 and not circuit.value
        engine.check(engine.lib.abc_world_close(world))
        engine.lib.abc_free(pointer)
        if engine.live_bytes:
            assert engine.live_bytes() == 0
        result['legacy_v1'] = 'world parses; circuit begin returns TCW_UNSUPPORTED'
        assert digest(path) == before
        result['source_sha256'] = before
    return result


def public(library, path):
    assert path.stat().st_size == 405983441
    before = digest(path)
    assert before == '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33'
    engine = Engine(library,path)
    stats = engine.stats()
    engine.io = {'read_events':0,'read_bytes':0,'steps':0,'jumps':[]}
    at = time.perf_counter()
    rows = engine.lamps(ANCHORS)
    elapsed = time.perf_counter()-at
    after = engine.stats()
    assert stats[18:24] == after[18:24]
    result = {'source_sha256':before,'library_sha256':digest(Path(library)),
              'parse_seconds':engine.parse_seconds,'compile_seconds':engine.compile_seconds,
              'query_seconds':elapsed,'records':rows,'io':engine.io,'stats':after,
              'scope':'streamed native C engine via Python; exact four initialization anchors; no UI timing'}
    engine.close()
    assert digest(path) == before
    return result


def compare_sequential(library, output, cmake):
    """Build the checked-in pre-skip driver only in an isolated test source tree."""
    root = Path(__file__).resolve().parent.parent
    output = output.resolve()
    output.parent.mkdir(parents=True,exist_ok=True)
    reference = root/'native/fixtures/sparse-lamp-sequential-query.inc'
    with tempfile.TemporaryDirectory(prefix='sparse-lamp-oracle-') as directory:
        staging = Path(directory)
        source, build = staging/'native', staging/'build'
        shutil.copytree(root/'native',source)
        query = source/'vendor/TerraWasm/src/terra_circuit_query.c'
        text = query.read_text()
        start, end = text.index('int cx_query_step('), text.index('\nint cx_command_complete(')
        assert start < end
        query.write_text(text[:start]+reference.read_text().rstrip()+text[end:])
        with output.with_suffix('.oracle-build.log').open('w') as log:
            subprocess.run([cmake,'-S',str(source),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release',
                            '-DABC_PERF_COUNTERS=ON'],check=True,stdout=log,stderr=subprocess.STDOUT)
            subprocess.run([cmake,'--build',str(build),'--parallel','2'],check=True,
                           stdout=log,stderr=subprocess.STDOUT)
        libraries = list(build.glob('*abc_engine.*'))
        oracle = next(p for p in libraries if p.suffix in ('.so','.dylib','.dll'))
        reports = []
        for label, target in (('sequential',oracle),('candidate',library.resolve())):
            report = output.with_suffix('.'+label+'.json')
            command = [sys.executable,str(Path(__file__).resolve()),'--library',str(target),'--output',str(report)]
            if label == 'candidate':
                command.append('--expect-checkpoint-jump')
            with output.with_suffix('.'+label+'.log').open('w') as log:
                subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
            reports.append(json.loads(report.read_text()))
        assert reports[0] == reports[1], 'sequential/candidate semantic differential failed'
        return {'status':'passed','semantic_entries':len(reports[0]),
                'semantic_sha256':hashlib.sha256(json.dumps(reports[0],sort_keys=True).encode()).hexdigest(),
                'oracle_source_sha256':digest(reference),
                'oracle':'checked-in v8 sequential query driver, compiled with the current surrounding engine in a temporary source tree',
                'candidate_library_sha256':digest(library)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',required=True,type=Path)
    parser.add_argument('--expect-checkpoint-jump','--optimized',dest='optimized',action='store_true',
                        help='Require the sparse query jump and its cancellation boundaries; does not enable PixelBox optimization')
    parser.add_argument('--public-world',type=Path)
    parser.add_argument('--compare-sequential',action='store_true',
                        help='Build the checked-in sequential test oracle in an isolated directory and compare complete synthetic reports')
    parser.add_argument('--cmake',default='cmake')
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    if args.compare_sequential:
        assert not args.public_world, 'The clean-checkout differential uses original synthetic fixtures only'
        result = compare_sequential(args.library,args.output,args.cmake)
    else:
        result = public(args.library,args.public_world) if args.public_world else suite(args.library,args.optimized)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print('PASS:', args.output)
