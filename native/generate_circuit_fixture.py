#!/usr/bin/env python3
"""Synthetic release-139 red-wire timer and torch; no proprietary fixture."""
import pathlib, struct, subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / 'plain.wld'
    subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('generate_world_fixture.py')), str(source)], check=True)
    raw = source.read_bytes()
positions = list(struct.unpack_from('<7i', raw, 26)) + [len(raw)]
sections = [raw[positions[i]:positions[i+1]] for i in range(7)]
importance = bytearray(19)
for tile in (4, 144):
    importance[tile//8] |= 1 << (tile%8)
tiles = bytearray()
for x in range(7):
    for y in range(32):
        if y == 10 and x in (2, 3):
            tiles += bytes((3, 2, 144 if x == 2 else 4)) + struct.pack('<hh', 0, 0)
        else:
            tiles += bytes((2, 1))
sections[1] = tiles
cursor = 56 + len(importance)
positions=[]
for section in sections:
    positions.append(cursor)
    cursor += len(section)
header=raw[:26]+struct.pack('<7i',*positions)+struct.pack('<h',145)+importance
pathlib.Path(sys.argv[1]).write_bytes(header+b''.join(sections))
