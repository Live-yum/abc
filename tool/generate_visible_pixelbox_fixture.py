#!/usr/bin/env python3
"""Original small WLD for visible generic-control and save/reopen acceptance.

No game assets, save, program, ROM, or application coordinate convention is
included. A two-colour wired loop reaches both axes of one real PixelBox. The
same-colour axes are joined outside the PixelBox, so both runtime modes support
the topology. A disconnected timer exercises ordinary device controls without
making the displayed PixelBox dependent on wall-clock scheduling.
"""
import argparse
import hashlib
from pathlib import Path
import tempfile

from test_wired_lights import write_world


def generate(path):
    cells = {}
    # A filled 3x3 wire grid provides H/V paths with an external bypass. The
    # PixelBox itself continues a wire straight through, as in the pinned
    # Wiring.cs HitWire traversal (929-942), followed by PixelBoxPass (668-679).
    for x in range(9, 12):
        for y in range(9, 12):
            cells[x, y] = (0, 0, 0, 3, 0, 0)
    for x in range(6, 9):
        cells[x, 10] = (0, 0, 0, 3, 0, 0)
    cells[6, 10] = (136, 0, 0, 3, 0, 0)  # Ordinary 1x1 switch.
    cells[10, 10] = (445, 0, 0, 3, 0, 0)  # Real, initially dark PixelBox.
    cells[6, 14] = (144, 0, 0, 1, 0, 0)  # Isolated, initially stopped timer.
    write_world(path, cells, width=20, height=32)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='visible-pixelbox-fixture-') as root:
        candidate = Path(root) / 'fixture.wld'
        generate(candidate)
        data = candidate.read_bytes()
        if args.check:
            assert args.output.read_bytes() == data, 'Fixture is not reproducible'
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(data)
    print(f'{args.output}: {len(data)} bytes, sha256={hashlib.sha256(data).hexdigest()}')


if __name__ == '__main__':
    main()
