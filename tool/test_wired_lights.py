#!/usr/bin/env python3
"""Original WLD fixtures for the two source-audited multi-tile light families.

The expected frames below come from the behavior of Wiring.cs at
8255d34616c780af12079425ac92a0a7aed87d71, not the candidate encoder. Exercise
the actual native ABI with retained and streamed files and independent reopen.
"""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import tempfile

from test_sparse_lamp_queries import Engine, P, U


def write_world(path, cells, width=20, height=32):
    """Encode a small original release-139 world with no production encoder."""
    name = b'Wired light contract'
    flags = bytearray(271)
    for offset, value in {0: 1, 8: width*16, 16: height*16,
                          20: height, 24: width}.items():
        struct.pack_into('<i', flags, offset, value)
    flags[130] = 1
    types = {value[0] for value in cells.values() if value[0]}
    count = max(types | {144}) + 1
    importance = bytearray((count+7)//8)
    for tile in types:
        importance[tile//8] |= 1 << (tile % 8)
    tiles = bytearray()
    for x in range(width):
        for y in range(height):
            tile, fx, fy, wires, actuator, inactive = cells.get((x,y),(0,0,0,0,0,0))
            h3 = (2 if actuator else 0) | (4 if inactive else 0) | (32 if wires & 8 else 0)
            h2 = ((wires & 7) << 1) | bool(h3)
            h1 = (2 if tile else 0) | bool(h2) | (32 if tile > 255 else 0)
            tiles.append(h1)
            if h2: tiles.append(h2)
            if h3: tiles.append(h3)
            if tile:
                tiles.append(tile & 255)
                if tile > 255: tiles.append(tile >> 8)
                tiles += struct.pack('<hh', fx, fy)
    sections = [bytes([len(name)]) + name + flags, tiles,
                struct.pack('<hh',0,40), b'\0\0', b'\0', b'\0'*4,
                b'\1' + bytes([len(name)]) + name + struct.pack('<i',1)]
    cursor = 56+len(importance)
    positions = []
    for section in sections:
        positions.append(cursor)
        cursor += len(section)
    metadata = b'relogic\2' + bytes(12)
    header = struct.pack('<i',139)+metadata+struct.pack('<h',7)
    header += struct.pack('<7i',*positions)+struct.pack('<h',count)+importance
    path.write_bytes(header+b''.join(sections))


def fixture(path, tile=42, frame=0, style=2, rows=None, actuator=False,
            malformed=None, second_light=False, wires=15):
    height = 2 if tile == 42 else 3
    if rows is None: rows = list(range(height))
    cells = {}
    for row in range(height):
        cells[6,10+row] = (tile,frame,(style*height+row)*18,
                          wires if row in rows else 0,int(actuator),0)
    for row in rows:
        for x in range(3,6): cells[x,10+row] = (0,0,0,wires,0,0)
    if malformed == 'missing': del cells[6,10+height-1]
    if malformed == 'style':
        entry = list(cells[6,10+height-1]);entry[2] += height*18
        cells[6,10+height-1] = tuple(entry)
    if malformed == 'state':
        entry = list(cells[6,10+height-1]);entry[1] = 18-frame
        cells[6,10+height-1] = tuple(entry)
    if malformed == 'inactive':
        entry = list(cells[6,10+height-1]);entry[4] = entry[5] = 1
        cells[6,10+height-1] = tuple(entry)
    if second_light:
        # The valid earlier fixture mutates before the invalid later fixture.
        for row in range(height):
            cells[9,10+row] = (tile,frame,(style*height+row)*18,wires,0,0)
        for x in range(7,9): cells[x,10] = (0,0,0,wires,0,0)
        del cells[9,10+height-1]
    write_world(path,cells)
    return height


def viewport(engine, x, y, width, height, budget=4096):
    return list(struct.iter_unpack('<4I',engine.command(
        1,x=x,y=y,width=width,height=height,stride=1,budget=budget)))


def frames(engine, height, expected, style=2, actuator=False):
    rows = viewport(engine,6,10,1,height)
    assert [r[3] & 65535 for r in rows] == [expected]*height, rows
    assert [r[3] >> 16 for r in rows] == [(style*height+r)*18 for r in range(height)], rows
    assert all((r[2] >> 17) & 1 == actuator for r in rows), rows
    assert not any((r[2] >> 18) & 1 for r in rows), rows
    # READ_LAMPS must agree with the frame shown by VIEWPORT and later SAVE.
    assert [r[2] for r in engine.lamps([(6,10+i) for i in range(height)])] == [int(expected==0)]*height
    return rows


def trigger(engine, mask=1, count=1, **kwargs):
    fields = dict(x=3,y=10,width=1,height=1,mask=mask,count=count)
    fields.update(kwargs)
    return engine.command(2,**fields)


def suite(library):
    checked = []
    with tempfile.TemporaryDirectory(prefix='wired-light-contract-') as directory:
        root = Path(directory)
        for tile in (42,93):
            height = 2 if tile == 42 else 3
            for streamed in (False,True):
                for optimized in (0,1):
                    for budget in (1,4096):
                        path = root/'light.wld'
                        fixture(path,tile,actuator=True)
                        original = hashlib.sha256(path.read_bytes()).hexdigest()
                        engine = Engine(library,path,streamed)
                        engine.command(10,mask=optimized)
                        frames(engine,height,0,actuator=True)
                        trigger(engine,budget=budget)
                        frames(engine,height,18,actuator=True)
                        trigger(engine,mask=3,budget=budget)
                        frames(engine,height,18,actuator=True)  # Red and blue toggle twice.
                        trigger(engine,mask=4,budget=budget)
                        frames(engine,height,0,actuator=True)
                        trigger(engine,mask=8,budget=budget)
                        frames(engine,height,18,actuator=True)
                        trigger(engine,mask=15,budget=budget)
                        frames(engine,height,18,actuator=True)  # All four colours toggle four times.
                        trigger(engine,count=2,budget=budget)
                        frames(engine,height,18,actuator=True)  # Two distinct TripWire calls.
                        trigger(engine,x=6,height=height,budget=budget)
                        frames(engine,height,18,actuator=True)  # Entire footprint is seed-skipped.
                        trigger(engine,x=6,budget=budget)
                        frames(engine,height,0,actuator=True)  # A later nonseed part still toggles.
                        trigger(engine,budget=budget)
                        expected = frames(engine,height,18,actuator=True)
                        engine.command(6,source_id=3,budget=budget)
                        engine.files[3].seek(0)
                        saved = root/'saved.wld';saved.write_bytes(engine.files[3].read())
                        engine.close()
                        reopened = Engine(library,saved,streamed)
                        assert frames(reopened,height,18,actuator=True) == expected
                        trigger(reopened,budget=budget)
                        frames(reopened,height,0,actuator=True)
                        reopened.close()
                        assert hashlib.sha256(path.read_bytes()).hexdigest() == original
                        checked.append(dict(tile=tile,streamed=streamed,optimized=optimized,budget=budget))
            for hit_row in range(height):
                fixture(root/'part.wld',tile,frame=18,style=5,rows=[hit_row])
                engine = Engine(library,root/'part.wld')
                trigger(engine,y=10+hit_row)
                frames(engine,height,0,style=5)
                engine.close()
            if tile == 93:
                fixture(root/'separate.wld',tile,rows=[0,2])
                engine = Engine(library,root/'separate.wld')
                trigger(engine,height=3)
                frames(engine,height,18)  # Two disconnected red nets, same footprint.
                engine.close()
            for malformed in ('missing','style','state','inactive','later_missing'):
                fixture(root/'bad.wld',tile,malformed=malformed,
                        second_light=malformed=='later_missing')
                engine = Engine(library,root/'bad.wld')
                before = viewport(engine,3,10,7,height)
                assert engine.begin(2,x=3,y=10,width=1,height=1,mask=1,count=1) >= 0
                try:
                    engine.pump(1)
                    raise AssertionError('malformed footprint was accepted')
                except AssertionError as error:
                    assert error.args == (-7,), error
                assert viewport(engine,3,10,7,height) == before
                # A supported follow-up and SAVE remain usable after failure.
                engine.command(3,count=1)
                engine.command(6,source_id=3)
                engine.close()
            fixture(root/'cancel.wld',tile)
            engine = Engine(library,root/'cancel.wld')
            before = frames(engine,height,0)
            pulse_before = engine.stats()[20]
            assert engine.begin(2,x=3,y=10,width=1,height=1,mask=1,count=2) >= 0
            for _ in range(10000):
                event,pointer = engine.step(1)
                engine.handle(event,pointer,bytearray())
                if engine.stats()[20] > pulse_before: break
            else: raise AssertionError('first pulse was not reached')
            assert engine.lib.abc_world_circuit_cancel(engine.circuit) == 0
            assert frames(engine,height,0) == before
            trigger(engine)
            frames(engine,height,18)
            engine.close()
        # Decorative worlds must not retain thousands of mutable light cells.
        plain = root/'empty.wld';dense = root/'unwired.wld'
        write_world(plain,{},width=128,height=128)
        cells = {(x,y):(42,0,(y%2)*18,0,0,0)
                 for x in range(128) for y in range(128)}
        write_world(dense,cells,width=128,height=128)
        engine = Engine(library,plain);empty_bytes = engine.stats()[16];engine.close()
        engine = Engine(library,dense);unwired_bytes = engine.stats()[16]
        assert unwired_bytes == empty_bytes,(empty_bytes,unwired_bytes)
        assert viewport(engine,6,10,1,2)[0][3] == 0
        engine.close()
    return dict(status='passed',matrix=checked,
                unwired_16384_cells_retained_growth=unwired_bytes-empty_bytes,
                additional=['every footprint member','unwired sibling','style preservation',
                            'disconnected same-colour nets','five malformed rollback cases per family',
                            'cancel after mutation and restart','save/reopen','source hash unchanged'])


def export_fixtures(directory):
    directory = Path(directory);directory.mkdir(parents=True,exist_ok=True)
    cases = []
    for tile,height in ((42,2),(93,3)):
        name = f'light-{tile}.wld';fixture(directory/name,tile,actuator=True)
        cases.append(dict(file=name,tile=tile,height=height,scenario='ordinary',style=2,actuator=True))
        for row in range(height):
            name=f'light-{tile}-part-{row}.wld'
            fixture(directory/name,tile,frame=18,style=5,rows=[row])
            cases.append(dict(file=name,tile=tile,height=height,scenario='part',row=row,style=5))
        for malformed in ('missing','style','state','inactive','later_missing'):
            name=f'light-{tile}-{malformed}.wld'
            fixture(directory/name,tile,malformed=malformed,second_light=malformed=='later_missing')
            cases.append(dict(file=name,tile=tile,height=height,scenario='malformed'))
    name='light-93-disconnected.wld';fixture(directory/name,93,rows=[0,2])
    cases.append(dict(file=name,tile=93,height=3,scenario='disconnected',style=2))
    (directory/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    return len(cases)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('library',nargs='?')
    parser.add_argument('--output')
    parser.add_argument('--export-fixtures')
    args = parser.parse_args()
    if args.export_fixtures:
        print(f'Exported {export_fixtures(args.export_fixtures)} original WLD cases')
    if not args.library:
        if not args.export_fixtures: parser.error('library or --export-fixtures is required')
        raise SystemExit(0)
    result = suite(args.library)
    report = json.dumps(result,indent=2)+'\n'
    if args.output: Path(args.output).write_text(report)
    print(report)
