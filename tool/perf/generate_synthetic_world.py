#!/usr/bin/env python3
"""Original deterministic v139 WLD for scalable public performance checks.

Hand-encoded from the same format contract as native/generate_world_fixture.py.
No personal save, game artwork, preset or extracted dataset is embedded. Empty
objects/bestiary make its limitations explicit; synthetic-circuit/objects add
those operation cases, and authorized local real saves add realistic workloads.
"""
import argparse
import pathlib
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output')
parser.add_argument('--width', type=int, default=512)
parser.add_argument('--height', type=int, default=256)
args = parser.parse_args()
if not (7 <= args.width <= 8400 and 32 <= args.height <= 2400):
    parser.error('Dimensions must fit 7..8400 by 32..2400')
width, height = args.width, args.height
name = b'ABC benchmark synthetic'
flags = bytearray(271)
for offset, value in {0: 1, 8: width * 16, 16: height * 16, 20: height, 24: width}.items():
    struct.pack_into('<i', flags, offset, value)
flags[130] = 1
header = bytes([len(name)]) + name + flags
tiles = bytes(v for x in range(width) for y in range(height) for v in (2, 1 + ((x + y) & 1)))
sections = [header, tiles, struct.pack('<hh', 0, 40), b'\0\0', b'\0', b'\0\0\0\0', b'\1' + bytes([len(name)]) + name + struct.pack('<i', 1)]
positions, cursor = [], 57
for section in sections:
    positions.append(cursor)
    cursor += len(section)
metadata = b'relogic\2' + bytes(12)
prefix = struct.pack('<i', 139) + metadata + struct.pack('<h', 7) + struct.pack('<7i', *positions) + struct.pack('<hB', 3, 0)
assert len(prefix) == 57
destination = pathlib.Path(args.output)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(prefix + b''.join(sections))
print(f'Generated original synthetic v139 {width}x{height}, {cursor} bytes')
