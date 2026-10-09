#!/usr/bin/env python3
"""Original deterministic, hand-encoded WLD release-139 smoke fixture.

No real save, game artwork, game assembly or production encoder is used. This
small fixture covers section offsets, active tile records and a matching footer.
It supplements, and does not replace, tests against real Terraria files.
"""
import pathlib
import struct
import sys

name = b'ABC synthetic fixture'
width, height = 7, 32
# Fixed release-139 flag/header suffix after its length-prefixed world name.
flags = bytearray(271)
for offset, value in {0: 1, 8: width * 16, 16: height * 16,
                      20: height, 24: width}.items():
    struct.pack_into('<i', flags, offset, value)
flags[130] = 1  # dayTime; all event flags and progression remain false.
header = bytes([len(name)]) + name + flags
# Each tile is active, one-byte type, with no optional headers and no RLE.
tiles = bytes(v for x in range(width) for y in range(height)
              for v in (2, 1 + ((x + y) & 1)))
sections = [header, tiles, struct.pack('<hh', 0, 40), b'\0\0', b'\0',
            b'\0\0\0\0', b'\1' + bytes([len(name)]) + name + struct.pack('<i', 1)]
format_size = 57
positions, cursor = [], format_size
for section in sections:
    positions.append(cursor)
    cursor += len(section)
metadata = b'relogic\2' + bytes(12)
format_bytes = (struct.pack('<i', 139) + metadata + struct.pack('<h', 7)
                + struct.pack('<7i', *positions) + struct.pack('<hB', 3, 0))
assert len(format_bytes) == format_size
output = pathlib.Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(format_bytes + b''.join(sections))
print(f'Wrote synthetic WLD: {output} ({cursor} bytes)')
