#!/usr/bin/env python3
"""Original 16x32 release-326 controller fixture; no game files or assets.

The explicit field groups follow the vendored release-326 binary reader. All
variable collections are empty. A two-by-two chest has one invented item and
an otherwise empty world leaves room for narrow placement transactions.
This is a codec/controller fixture, not evidence of game-world compatibility.
"""
import argparse
from pathlib import Path
import struct


def pack(fmt, *values):
    return struct.pack('<' + fmt, *values)


def string(value):
    data = value.encode('utf-8')
    assert len(data) < 128
    return bytes([len(data)]) + data


def world_bytes():
    name, width, height, world_id = 'ABC synthetic modern fixture', 16, 32, 42
    header = bytearray(string(name) + string('public-synthetic'))
    header += pack('Q', 0) + bytes(16)
    header += pack('7i', world_id, 0, width * 16, 0, height * 16, height, width)
    # game mode, nine seed flags, creation/last-played timestamps, moon type.
    header += bytes(4 + 9 + 16 + 1)
    # Tree/cave/background styles; spawn; surface, rock and time.
    header += bytes(17 * 4 + 2 * 4 + 3 * 8)
    header += pack('BIBBiiB', 1, 0, 0, 0, 0, 0, 0)
    # Bosses, saved NPCs/events, shadow-orb and meteor state, altar/hardmode.
    header += bytes(11 + 7 + 3 + 4 + 2)
    # Invasion, slime rain, sundial, weather, ores, backgrounds and clouds.
    header += bytes(3 * 4 + 8 + 8 + 1 + 1 + 4 + 4 + 3 * 4 + 8 + 4 + 2 + 4)
    # Empty anglers; saved NPCs/quest; invasion/cultist; empty mobs/banners.
    header += bytes(4 + 1 + 4 + 3 + 8 + 2 + 2)
    # Fast-forward/late bosses; celestial; party; sandstorm; DD2.
    header += bytes(10 + 9 + 2 + 8 + 1 + 4 + 8 + 4)
    # Backgrounds, combat book, lantern, tree tops, seasonal flags, ores.
    header += bytes(5 + 1 + 4 + 3 + 4 + 2 + 16)
    # Pets/bosses, slime/merchant spawns, books, remaining slime spawns.
    header += bytes(3 + 2 + 1 + 1 + 8 + 1 + 1 + 7)
    # Dusk/moondial; permanent seasons; vampire/infected; meteor/coin rain.
    header += bytes(2 + 2 + 1 + 1 + 8)
    # Team seed/empty spawn points, dual dungeons, lightning flags, manifest.
    header += bytes(2 + 1 + 2) + string('')
    tiles = bytearray()
    for x in range(width):
        for y in range(height):
            if 1 <= x < 3 and 2 <= y < 4:
                tiles += bytes([2, 21]) + pack('hh', (x - 1) * 18, (y - 2) * 18)
            else:
                tiles += b'\0'
    chests = pack('hii', 1, 1, 2) + string('Synthetic chest') + pack('i', 40)
    chests += pack('hiB', 1, 10, 0) + pack('h', 0) * 39
    sections = [bytes(header), bytes(tiles), chests, pack('h', 0),
                bytes(6), bytes(4), bytes(4), bytes(4), bytes(12),
                b'\0', b'\1' + string(name) + pack('i', world_id)]
    importance = bytearray(91)
    for tile in (15, 21, 395):
        importance[tile // 8] |= 1 << (tile % 8)
    size = 4 + 20 + 2 + len(sections) * 4 + 2 + len(importance)
    positions = []
    for section in sections:
        positions.append(size)
        size += len(section)
    format_bytes = (pack('i', 326) + b'relogic\2' + bytes(12)
                    + pack('h', len(sections)) + pack('11i', *positions)
                    + pack('h', 728) + importance)
    return format_bytes + b''.join(sections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    data = world_bytes()
    args.output.write_bytes(data)
    print(f'Wrote public synthetic WLD326: {len(data)} bytes')


if __name__ == '__main__':
    main()
