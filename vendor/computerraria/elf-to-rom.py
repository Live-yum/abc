"""Extract allocatable PROGBITS at their ELF32 PT_LOAD physical addresses.

This matches the input needed by Computerraria's ROM loader. It does not execute
the target image or use ELF e_entry as the hardware reset PC.
"""
import hashlib
import json
from pathlib import Path
import struct
import sys

source = Path(sys.argv[1])
data = source.read_bytes()
if data[:7] != b'\x7fELF\x01\x01\x01':
    raise ValueError('Expected ELF32 little-endian current-version file')
header = struct.unpack_from('<HHIIIIIHHHHHH', data, 16)
kind, machine, version, entry, phoff, shoff, flags, ehsize, phsize, phnum, shsize, shnum, shstr = header
if kind != 2 or machine != 243 or flags != 0 or phsize != 32 or shsize != 40:
    raise ValueError('Expected uncompressed integer RISC-V executable')
programs = [struct.unpack_from('<IIIIIIII', data, phoff + i * phsize) for i in range(phnum)]
sections = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * shsize) for i in range(shnum)]
strings = sections[shstr]
names = data[strings[4]:strings[4] + strings[5]]
parts = []
for section in sections:
    if section[1] != 1 or not section[2] & 2 or not section[5]:
        continue
    name = names[section[0]:].split(b'\0', 1)[0].decode('utf-8')
    matches = [p for p in programs if p[0] == 1 and section[4] >= p[1]
               and section[4] + section[5] <= p[1] + p[4]]
    if len(matches) != 1:
        raise ValueError(f'Unmapped or ambiguous section {name}')
    segment = matches[0]
    address = segment[3] + section[4] - segment[1]
    payload = data[section[4]:section[4] + section[5]]
    if len(payload) != section[5]:
        raise ValueError('Truncated section')
    parts.append((name, address, payload))
if not parts or min(p[1] for p in parts) != 0:
    raise ValueError('Computerraria image must include hardware startup at address zero')
end = max(p[1] + len(p[2]) for p in parts)
if end > 768 * 1024 or end % 4:
    raise ValueError('Image exceeds ROM or is not word-aligned')
rom = bytearray(end)
occupied = bytearray(end)
for name, address, payload in parts:
    if any(occupied[address:address + len(payload)]):
        raise ValueError(f'Overlapping section {name}')
    rom[address:address + len(payload)] = payload
    occupied[address:address + len(payload)] = b'\1' * len(payload)
source.with_suffix('.bin').write_bytes(rom)
source.with_suffix('.txt').write_text(rom.hex(' ') + '\n')
metadata = {'elf_entry': entry, 'hardware_reset_pc': 0, 'machine': machine, 'flags': flags,
    'elf_bytes': len(data), 'elf_sha256': hashlib.sha256(data).hexdigest(),
    'load_image_bytes': len(rom), 'load_image_sha256': hashlib.sha256(rom).hexdigest(),
    'sections': [{'name': n, 'physical_address': a, 'bytes': len(d)} for n, a, d in parts]}
(source.parent / 'elf-summary.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(json.dumps(metadata, indent=2))
