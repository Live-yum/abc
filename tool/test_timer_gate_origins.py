#!/usr/bin/env python3
"""Original gate-output timer fixtures with explicit source-derived frames.

These are two narrow known gate behaviors, not a second general game model.
The real gate output originates at (8,10), independently of the external red
source at (5,7). Its blue FIFO encounters x7 before x5; reverse UpdateMech
therefore leaves x5 enabled at tick60. Ordinary AND and the existing optimized
faulty/single-lamp gate representation must preserve the same physical origin.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile

from test_sparse_lamp_queries import Engine
from test_wired_lights import viewport, write_world


def fixtures():
    for standard in (False, True):
        cells = {(x, 10): (144 if x in (5, 7) else 0, 0, 0, 2, 0, 0)
                 for x in range(5, 9)}
        cells[8, 10] = (420, 36 if standard else 0, 0, 2, 0, 0)
        for x in range(5, 9):
            cells[x, 7] = (0, 0, 0, 1, 0, 0)
        if standard:
            cells[8, 8] = (419, 36, 0, 1, 0, 0)
            cells[8, 9] = (419, 18, 0, 0, 0, 0)
        else:
            cells[8, 8] = (0, 0, 0, 1, 0, 0)
            cells[8, 9] = (419, 0, 0, 1, 0, 0)
        yield ('standard-faulty-gate-origin' if standard else 'ordinary-and-gate-origin'), cells


def timer_frames(engine, budget=4096):
    return [[r[0], r[1], r[3] >> 16] for r in viewport(engine, 5, 10, 3, 1, budget)
            if (r[2] & 65535) == 144]


def pulse(engine, budget):
    return engine.command(2, x=5, y=7, width=1, height=1, mask=1, count=1, budget=budget)


def suite(library):
    passed = []
    with tempfile.TemporaryDirectory(prefix='gate-timer-origin-') as temp:
        path = Path(temp) / 'original.wld'
        for name, cells in fixtures():
            write_world(path, cells)
            before = hashlib.sha256(path.read_bytes()).hexdigest()
            for streamed in (False, True):
                for mode in (0, 1):
                    for budget in (1, 4096):
                        engine = Engine(library, path, streamed)
                        try:
                            engine.command(10, mask=mode)
                            pulse(engine, budget)
                            assert timer_frames(engine, budget) == [[5, 10, 18], [7, 10, 18]], name
                            engine.command(3, count=60, budget=budget)
                            assert timer_frames(engine, budget) == [[5, 10, 18], [7, 10, 0]], name
                            passed.append(dict(case=name, streamed=streamed, optimized=mode, budget=budget))
                        finally:
                            engine.close()
            assert hashlib.sha256(path.read_bytes()).hexdigest() == before
    return dict(status='passed', matrix=passed, input_sha256_unchanged=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('library')
    parser.add_argument('--output')
    args = parser.parse_args()
    report = json.dumps(suite(args.library), indent=2) + '\n'
    if args.output:
        Path(args.output).write_text(report)
    print(report)
