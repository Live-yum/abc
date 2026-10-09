#!/usr/bin/env python3
"""Small original synthetic world with independent pixel axes and empty cells."""
import pathlib
import struct
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / 'plain.wld'
    subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('generate_world_fixture.py')), str(source)], check=True)
    raw = source.read_bytes()
positions = list(struct.unpack_from('<7i', raw, 26)) + [len(raw)]
sections = [raw[positions[i]:positions[i+1]] for i in range(7)]
importance = bytearray(56)
for tile in (411, 419, 445):
    importance[tile // 8] |= 1 << (tile % 8)
tiles = bytearray()
for x in range(7):
    for y in range(32):
        if x in (2, 3) and y in (20, 21):
            tiles += bytes((35, 6, 155, 1)) + struct.pack('<hh', (x - 2) * 18, (y - 20) * 18)
        elif (x, y) == (5, 20):
            tiles += bytes((35, 6, 163, 1)) + struct.pack('<hh', 0, 0)
        elif (x, y) == (4, 20):
            tiles += bytes((1, 6))
        elif (x, y) == (3, 10):
            tiles += bytes((35, 6, 189, 1)) + struct.pack('<hh', 0, 0)
        elif y == 10 and x in (2, 4):
            tiles += bytes((1, 2))
        elif x == 3 and y in (9, 11):
            tiles += bytes((1, 4))
        else:
            tiles += bytes((2, 1))
sections[1] = tiles
cursor = 56 + len(importance)
positions = []
for section in sections:
    positions.append(cursor)
    cursor += len(section)
header = raw[:26] + struct.pack('<7i', *positions) + struct.pack('<h', 446) + importance
pathlib.Path(sys.argv[1]).write_bytes(header + b''.join(sections))
