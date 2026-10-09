#!/usr/bin/env python3
"""Original tiny wired chest/sign/entity fixture; never a real save or game asset."""
import pathlib
import struct
import sys

pack = lambda fmt, *values: struct.pack('<' + fmt, *values)
def text(value):
    encoded = value.encode('utf-8')
    assert len(encoded) < 128
    return bytes([len(encoded)]) + encoded

name = 'ABC wired objects'
width = height = 32
flags = bytearray(271)
for offset, value in {0: 1, 8: width * 16, 16: height * 16, 20: height, 24: width}.items():
    struct.pack_into('<i', flags, offset, value)
flags[130] = 1
objects = [(21, 1, 2, 2, 2), (55, 5, 2, 2, 2), (378, 9, 2, 2, 3)]
tiles = bytearray()
for x in range(width):
    for y in range(height):
        obj = next((o for o in objects if o[1] <= x < o[1]+o[3] and o[2] <= y < o[2]+o[4]), None)
        red = y == 2 and 1 <= x <= 10
        blue = y == 2 and 20 <= x <= 21
        support = any(o[1] <= x < o[1]+o[3] and y == o[2]+o[4] for o in objects)
        type_id = obj[0] if obj else 1 if support else None
        first = (1 if red or blue else 0) | (2 if type_id is not None else 0) | (32 if type_id is not None and type_id > 255 else 0)
        tiles.append(first)
        if red or blue: tiles.append(2 if red else 4)
        if type_id is not None:
            tiles += pack('H', type_id) if type_id > 255 else bytes([type_id])
            if obj: tiles += pack('hh', (x-obj[1])*18, (y-obj[2])*18)
chests = pack('hhii', 1, 40, 1, 2) + text('Keep\0inventory') + pack('hiB', 9, 8, 3) + pack('h', 0)*39
signs = pack('h', 1) + text('Original\0sign text') + pack('ii', 5, 2)
entities = pack('iBiHHh', 1, 0, 7, 9, 2, -1)
sections = [text(name)+flags, tiles, chests, signs, b'\0', entities, b'\1'+text(name)+pack('i', 1)]
important = bytearray(48)
for type_id, *_ in objects: important[type_id//8] |= 1 << (type_id % 8)
positions = []
cursor = 56 + len(important)
for section in sections:
    positions.append(cursor)
    cursor += len(section)
header = pack('i', 139)+b'relogic\2'+bytes(12)+pack('h', 7)+pack('7i', *positions)+pack('h', 384)+important
path = pathlib.Path(sys.argv[1])
path.write_bytes(header+b''.join(sections))
print(f'Wrote original wired-object WLD: {path} ({cursor} bytes)')
