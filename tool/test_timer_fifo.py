#!/usr/bin/env python3
"""Original WLD/actual-ABI timer encounter-order contracts.

The independent oracle below models the ordinary-wire behavior audited in
Wiring.cs at 8255d34616c780af12079425ac92a0a7aed87d71: x/y seed order,
red/blue/green/yellow passes, a FIFO with down/up/right/left expansion, and
reverse mechanical-list updates. It neither imports nor translates engine C.
Special routing tiles and gate waves are deliberately outside this oracle.
"""
import argparse
from collections import deque
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile

from test_sparse_lamp_queries import Engine
from test_wired_lights import viewport, write_world

REFERENCE = '8255d34616c780af12079425ac92a0a7aed87d71'
PERIODS = (60, 180, 300, 30, 15)
NEIGHBORS = ((0, 1), (0, -1), (1, 0), (-1, 0))


class Reference:
    """Small behavioral model, using coordinates and Python FIFO/list state."""
    def __init__(self, cells, width, height):
        self.cells = {point: list(cell) for point, cell in cells.items()}
        self.width, self.height, self.ticks = width, height, 0
        self.mechanisms = []
        self.cooldown = {}
        self.encounters = []
        for cell in self.cells.values():
            if cell[0] == 144:
                cell[2] = 0  # World loading never restores a timer queue.

    def register(self, point, duration):
        if point not in self.cooldown and len(self.mechanisms) < 999:
            self.mechanisms.append(point)
            self.cooldown[point] = duration

    def toggle_timer(self, point):
        cell = self.cells[point]
        if cell[2] == 0:
            cell[2] = 18
            self.register(point, 18000)
        else:
            cell[2] = 0

    def pulse(self, x, y, width=1, height=1, mask=15):
        for color in (1, 2, 4, 8):
            if not mask & color:
                continue
            seeds = [(a, b) for a in range(x, x + width)
                     for b in range(y, y + height)
                     if self.cells.get((a, b), (0, 0, 0, 0))[3] & color]
            skipped, visited = set(seeds), set(seeds)
            queue = deque(seeds)
            while queue:
                point = queue.popleft()
                cell = self.cells[point]
                if point not in skipped:
                    if cell[0] == 144:
                        self.encounters.append([color, *point])
                        self.toggle_timer(point)
                    elif cell[0] == 419:
                        cell[1] = 18 - cell[1]
                for dx, dy in NEIGHBORS:
                    neighbor = point[0] + dx, point[1] + dy
                    a, b = neighbor
                    if (2 <= a < self.width - 2 and
                            2 <= b < self.height - 2 and
                            neighbor not in visited and
                            self.cells.get(neighbor, (0, 0, 0, 0))[3] & color):
                        visited.add(neighbor)
                        queue.append(neighbor)

    def interact(self, x, y):
        point = x, y
        cell = self.cells[point]
        if cell[0] == 144:
            self.toggle_timer(point)
        elif cell[0] == 411:
            self.register(point, 60)
            shift = -36 if cell[1] >= 36 else 36
            for a in range(x, x + 2):
                for b in range(y, y + 2):
                    self.cells[a, b][1] += shift
            self.pulse(x, y, 2, 2)
        else:
            raise AssertionError('Reference interaction requires a timer/button')

    def advance(self, count):
        for _ in range(count):
            self.ticks += 1
            # New registrations produced during a pulse wait until next tick.
            index = len(self.mechanisms) - 1
            while index >= 0:
                point = self.mechanisms[index]
                cell = self.cells[point]
                self.cooldown[point] -= 1
                if cell[0] == 144:
                    if cell[2] == 0:
                        self.cooldown[point] = 0
                    elif self.cooldown[point] % PERIODS[cell[1] // 18] == 0:
                        self.cooldown[point] = 18000
                        self.pulse(*point)
                if self.cooldown[point] <= 0:
                    if cell[0] == 144:
                        cell[2] = 0
                    elif cell[0] == 411:
                        shift = -36 if cell[1] >= 36 else 36
                        for a in range(point[0], point[0] + 2):
                            for b in range(point[1], point[1] + 2):
                                self.cells[a, b][1] += shift
                    del self.cooldown[point]
                    del self.mechanisms[index]
                index -= 1

    def apply(self, command):
        fields = command['fields']
        if command['kind'] == 3:
            self.advance(fields['count'])
        else:
            for _ in range(fields.get('count', 1) or 1):
                if fields.get('flags', 0) & 1:
                    self.interact(fields['x'], fields['y'])
                else:
                    self.pulse(fields['x'], fields['y'],
                               fields.get('width', 1), fields.get('height', 1),
                               fields.get('mask', 15))

    def snapshot(self):
        return [[x, y, cell[0], cell[1], cell[2]]
                for (x, y), cell in sorted(self.cells.items())
                if cell[0] in (144, 419, 411)]


def trigger(x, y, width=1, height=1, mask=1, count=1, flags=0):
    return dict(kind=2, fields=dict(x=x, y=y, width=width, height=height,
                                   mask=mask, count=count, flags=flags))


def ticks(count):
    return dict(kind=3, fields=dict(count=count))


def wire(cells, points, mask=1):
    for point in points:
        old = cells.get(point, (0, 0, 0, 0, 0, 0))
        cells[point] = (*old[:3], old[3] | mask, *old[4:])


def timer(cells, point, style=0, mask=None, initial=0):
    old = cells.get(point, (0, 0, 0, 0, 0, 0))
    cells[point] = (144, style * 18, initial,
                    old[3] if mask is None else mask, 0, 0)


def case(name, cells, commands, width=32, height=32):
    return dict(name=name, cells=cells, commands=commands, width=width, height=height)


def cases():
    result = []
    # The first fixture is the minimal demonstrated pre-fix failure.
    for direction in ('right', 'left', 'below', 'above'):
        cells = {}
        if direction in ('right', 'left'):
            wire(cells, [(x, 10) for x in range(4, 9)])
            for point in ((5, 10), (7, 10)):
                timer(cells, point)
            source = (8, 10) if direction == 'right' else (4, 10)
        else:
            wire(cells, [(10, y) for y in range(4, 9)])
            for point in ((10, 5), (10, 7)):
                timer(cells, point)
            source = (10, 8) if direction == 'below' else (10, 4)
        result.append(case('source-' + direction, cells,
                           [trigger(*source), ticks(59), ticks(1), ticks(120)]))

    for direction in ('left', 'right', 'above', 'below'):
        cells = {}
        horizontal = direction in ('left', 'right')
        low = direction in ('left', 'above')
        coordinates = range(0, 9) if low else range(12, 20)
        point = lambda at: (at, 10) if horizontal else (10, at)
        wire(cells, [point(at) for at in coordinates])
        for at in ((0, 2, 4) if low else (15, 17, 19)):
            timer(cells, point(at))
        result.append(case('border-source-' + direction, cells,
                           [trigger(*point(1 if low else 18)), ticks(60), ticks(60)],
                           width=20, height=20))

    cells = {}
    wire(cells, [(10, y) for y in range(8, 13)] +
                [(x, 10) for x in range(8, 13)])
    for point in ((10, 12), (10, 8), (12, 10), (8, 10)):
        timer(cells, point)
    result.append(case('equal-distance-down-up-right-left', cells,
                       [trigger(10, 10), ticks(60), ticks(60)]))

    cells = {}
    wire(cells, [(x, y) for x in range(5, 12) for y in range(6, 13)
                 if x in (5, 11) or y in (6, 12)])
    for point in ((5, 6), (5, 9), (5, 12), (8, 6), (8, 12)):
        timer(cells, point)
    result.append(case('loop-no-repeat', cells,
                       [trigger(11, 9), ticks(60), trigger(5, 9), ticks(120)]))

    cells = {}
    wire(cells, [(x, y) for x in range(7, 11) for y in range(9, 13)])
    for point in ((8, 9), (8, 12), (9, 9), (9, 12),
                  (7, 10), (7, 11), (10, 10), (10, 11)):
        timer(cells, point)
    # Include a seed timer: it must be skipped through every path in the loop.
    timer(cells, (8, 10))
    result.append(case('rectangle-x-then-y-seed-order', cells,
                       [trigger(8, 10, 2, 2), ticks(60), ticks(60)]))

    cells = {}
    wire(cells, [(x, 10) for x in range(4, 9)] +
                [(x, 14) for x in range(4, 8)])
    points = ((6, 10), (8, 10), (5, 14), (7, 14))
    for x, y in points:
        wire(cells, [(x, b) for b in range(y, 19)], 2)
        timer(cells, (x, y))
    wire(cells, [(x, 18) for x in range(5, 9)], 2)
    result.append(case('disconnected-red-frontiers-interleave', cells,
                       [trigger(4, 10, 1, 5), ticks(60), ticks(60), ticks(60)]))

    cells = {}
    for color, point, points in (
            (1, (12, 10), [(x, 10) for x in range(10, 14)]),
            (2, (10, 8), [(10, y) for y in range(7, 11)]),
            (4, (8, 10), [(x, 10) for x in range(7, 11)]),
            (8, (10, 12), [(10, y) for y in range(10, 14)])):
        wire(cells, points, color)
        timer(cells, point)
        output = points[-1] if color in (1, 8) else points[0]
        cells[output] = (419, 0, 0, color, 0, 0)
    result.append(case('four-colors-red-blue-green-yellow', cells,
                       [trigger(10, 10, mask=15), ticks(60),
                        trigger(10, 10, mask=15, count=2), ticks(60)]))

    cells = {}
    wire(cells, [(x, 10) for x in range(5, 9)])
    for x in (5, 7, 8):
        timer(cells, (x, 10))
    result.append(case('timer-output-registers-in-fifo-order', cells,
                       [trigger(8, 10, flags=1), ticks(59), ticks(1),
                        ticks(59), ticks(1), ticks(180)]))

    cells = {}
    wire(cells, [(x, 10) for x in range(5, 9)], 3)
    for x in (5, 7):
        timer(cells, (x, 10))
    result.append(case('multiple-pulses-and-colors', cells,
                       [trigger(8, 10, count=2), trigger(8, 10, count=3),
                        ticks(23), trigger(8, 10, mask=3), ticks(37),
                        trigger(8, 10, count=5), ticks(120)]))

    cells = {}
    commands = []
    for style in range(5):
        x = 4 + style * 4
        wire(cells, [(x, 10), (x, 11)])
        timer(cells, (x, 10), style, initial=18)
        cells[x, 11] = (419, 0, 0, 1, 0, 0)
        commands.append(trigger(x, 10, flags=1))
    commands += [ticks(n) for n in (14, 1, 14, 1, 29, 1, 119, 1, 119, 1)]
    result.append(case('all-five-periods-and-import-reset', cells, commands))

    cells = {(5, 10): (144, 0, 18, 1, 0, 0), (6, 10): (419, 0, 0, 1, 0, 0)}
    operate = trigger(5, 10, flags=1)
    result.append(case('existing-registration-keeps-phase', cells,
                       [operate, ticks(23), operate, operate, ticks(36), ticks(1),
                        operate, ticks(1), operate, ticks(59), ticks(1)]))
    return result


def cap_case(shared_button):
    # 1,000 separate wire islands. Coordinate order puts yellow, green and
    # blue first, but color passes register all 997 red timers before blue,
    # green and yellow. The cap therefore makes color order observable.
    cells = {}
    for index in range(1000):
        x = 3 + 3 * index
        color = (8, 4, 2, 1)[index] if index < 4 else 1
        wire(cells, [(x, y) for y in range(10, 14)], color)
        timer(cells, (x, 12))
        cells[x, 13] = (419, 0, 0, color, 0, 0)
    commands = []
    for button in range(int(shared_button)):
        left = 3 + button * 3
        for dx in range(2):
            for dy in range(2):
                cells[left + dx, 20 + dy] = (411, dx * 18, dy * 18, 0, 0, 0)
        commands.append(trigger(left, 20, flags=1))
    commands += [trigger(3, 10, 2998, 1, mask=15), ticks(59), ticks(1)]
    # The button case now has a free slot; the timer-only case remains full.
    # Operating the rejected yellow timer distinguishes these two outcomes.
    commands += [trigger(3, 12, flags=1), trigger(3, 12, flags=1), ticks(60)]
    suffix = 'two-buttons' if shared_button == 2 else 'button' if shared_button else 'timers'
    return case('999-shared-cap-' + suffix,
                cells, commands, width=3008)


def actual_snapshot(engine, expected, budget):
    by_row = {}
    for x, y, *_ in expected:
        by_row.setdefault(y, []).append(x)
    values = {}
    for y, xs in by_row.items():
        left, right = min(xs), max(xs)
        rows = viewport(engine, left, y, right - left + 1, 1, budget)
        for x in xs:
            row = rows[x - left]
            values[x, y] = [x, y, row[2] & 65535, row[3] & 65535, row[3] >> 16]
    return [values[tuple(row[:2])] for row in expected]


def check_state(engine, reference, budget, context):
    expected = reference.snapshot()
    # Large-cap fixtures vary the simulation command budget. Their unrelated
    # inspection scans use 4096 to avoid repeating millions of Python ABI calls.
    query_budget = 4096 if len(expected) > 128 else budget
    actual = actual_snapshot(engine, expected, query_budget)
    if actual != expected:
        mismatches = [(want, got) for want, got in zip(expected, actual) if want != got]
        raise AssertionError(f'{context}: expected/actual {mismatches[:8]}')
    assert engine.stats()[18:20] == [reference.ticks, 0], context
    lamps = [row[:2] for row in expected if row[2] == 419]
    if lamps:
        assert [row[2] for row in engine.lamps(lamps, query_budget)] == [
            int(reference.cells[tuple(point)][1] == 18) for point in lamps], context
    return actual


def materialize(spec, path):
    write_world(path, spec['cells'], spec['width'], spec['height'])
    return Reference(spec['cells'], spec['width'], spec['height'])


def run_case(library, path, spec, streamed, optimized, budget):
    reference = materialize(spec, path)
    source_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    context = f"{spec['name']}/stream={streamed}/mode={optimized}/budget={budget}"
    engine = Engine(library, path, streamed)
    try:
        engine.command(10, mask=optimized, budget=budget)
        check_state(engine, reference, budget, context + '/initial')
        for index, command in enumerate(spec['commands']):
            engine.command(command['kind'], budget=budget, **command['fields'])
            reference.apply(command)
            check_state(engine, reference, budget, context + f'/step={index}')
        engine.command(6, source_id=3, budget=budget)
        engine.files[3].seek(0)
        saved = path.with_name('saved.wld')
        saved.write_bytes(engine.files[3].read())
    finally:
        engine.close()
    reopened = Engine(library, saved, streamed)
    try:
        reopened.command(10, mask=optimized, budget=budget)
        reset = Reference(reference.cells, spec['width'], spec['height'])
        check_state(reopened, reset, budget, context + '/reopen')
        reopened.command(3, count=300, budget=budget)
        reset.advance(300)
        check_state(reopened, reset, budget, context + '/reopen-no-live-queue')
        # Operate one saved timer to prove a fresh scheduler remains usable.
        point = next(point for point, cell in reset.cells.items() if cell[0] == 144)
        command = trigger(*point, flags=1)
        reopened.command(command['kind'], budget=budget, **command['fields'])
        reset.apply(command)
        reopened.command(3, count=60, budget=budget)
        reset.advance(60)
        check_state(reopened, reset, budget, context + '/reopen-new-activation')
    finally:
        reopened.close()
    assert hashlib.sha256(path.read_bytes()).hexdigest() == source_hash, context
    return dict(case=spec['name'], streamed=streamed, optimized=optimized, budget=budget)


def cancellation_case(library, path, streamed, optimized, cancel_kind):
    spec = cases()[0]
    reference = materialize(spec, path)
    engine = Engine(library, path, streamed)
    context = f'cancel-{cancel_kind}/stream={streamed}/mode={optimized}'
    try:
        engine.command(10, mask=optimized)
        for command in (trigger(8, 10), ticks(23)):
            engine.command(command['kind'], budget=1, **command['fields'])
            reference.apply(command)
        before = check_state(engine, reference, 1, context + '/before')
        old_stats = engine.stats()[18:24]
        command = ticks(120) if cancel_kind == 3 else trigger(8, 10, count=3)
        Engine.check(engine.begin(command['kind'], **command['fields']))
        for _ in range(100000):
            event, pointer = engine.step(1)
            engine.handle(event, pointer, bytearray())
            # Each pulse uses one red net. Entry to the second pulse proves
            # the first trip, including deferred FIFO replay, already mutated
            # timer frames and registrations. The command is still pending.
            if engine.stats()[20] >= old_stats[2] + 2:
                break
            assert event[1] != 4, 'Command finished before cancellation target'
        else:
            raise AssertionError('No wire mutation reached for cancellation')
        Engine.check(engine.lib.abc_world_circuit_cancel(engine.circuit))
        assert check_state(engine, reference, 1, context + '/rollback') == before
        # Work/pulse diagnostics count attempted work; only simulation ticks
        # are transactional. Frames, queue ordering and phase are checked too.
        assert engine.stats()[18:20] == old_stats[:2], context + '/ticks-rollback'
        engine.command(command['kind'], budget=1, **command['fields'])
        reference.apply(command)
        check_state(engine, reference, 1, context + '/retry')
        # Retry must restore queue order and elapsed phase, not only frames.
        engine.command(3, count=120, budget=1)
        reference.advance(120)
        check_state(engine, reference, 1, context + '/later-boundaries')
    finally:
        engine.close()


def cancellation_sweep(library, path, streamed, optimized, cached):
    """Cancel at every work-unit boundary, including inside FIFO/cache replay."""
    spec = cases()[0]
    command = trigger(8, 10, count=2)
    cancelled = 0
    for cutoff in range(1, 256):
        reference = materialize(spec, path)
        engine = Engine(library, path, streamed)
        context = f'cancel-sweep/stream={streamed}/mode={optimized}/cached={cached}/step={cutoff}'
        try:
            engine.command(10, mask=optimized)
            # Bind the input without pulsing it. The sweep then isolates the
            # simulation and cold/hot FIFO trace, rather than source decoding.
            engine.lamps([(8, 10)])
            for setup in (trigger(8 if cached else 4, 10), ticks(23)):
                engine.command(setup['kind'], budget=1, **setup['fields'])
                reference.apply(setup)
            old_stats = engine.stats()[18:24]
            Engine.check(engine.begin(command['kind'], **command['fields']))
            finished = False
            for _ in range(cutoff):
                event, pointer = engine.step(1)
                engine.handle(event, pointer, bytearray())
                if event[1] == 4:
                    finished = True
                    break
            if finished:
                return cancelled
            Engine.check(engine.lib.abc_world_circuit_cancel(engine.circuit))
            check_state(engine, reference, 1, context + '/rollback')
            assert engine.stats()[18:20] == old_stats[:2], context + '/ticks-rollback'
            engine.command(command['kind'], budget=1, **command['fields'])
            reference.apply(command)
            check_state(engine, reference, 1, context + '/retry')
            engine.command(3, count=37, budget=1)
            reference.advance(37)
            check_state(engine, reference, 1, context + '/preserved-phase-and-order')
            cancelled += 1
        finally:
            engine.close()
    raise AssertionError('Tiny cancellation sweep did not reach command completion')


def unsupported_case(library, path, streamed, optimized, budget, routing):
    if routing == 'over-65536':
        cells = {(x, y): (0, 0, 0, 1, 0, 0)
                 for x in range(3, 260) for y in range(3, 259)}
        width, height = 270, 264
        isolated_source, isolated_timer, isolated_lamp = (267, 260), (264, 260), (265, 260)
        wire(cells, [(x, 260) for x in range(263, 268)])
    else:
        cells = {}
        width = height = 32
        wire(cells, [(x, 10) for x in range(4, 11)])
        cells[6, 10] = (int(routing), 0, 0, 1, 0, 0)
        isolated_source, isolated_timer, isolated_lamp = (10, 20), (5, 20), (9, 20)
        wire(cells, [(x, 20) for x in range(4, 11)])
        # A second special route containing only one hit timer remains valid.
        cells[6, 20] = (int(routing), 0, 0, 1, 0, 0)
    for point in ((5, 10), (7, 10), isolated_timer):
        timer(cells, point)
    cells[9, 10] = (419, 0, 0, 1, 0, 0)
    cells[isolated_lamp] = (419, 0, 0, 1, 0, 0)
    spec = case('unsupported-' + str(routing), cells, [], width, height)
    reference = materialize(spec, path)
    source_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    engine = Engine(library, path, streamed)
    context = f"{spec['name']}/stream={streamed}/mode={optimized}/budget={budget}"
    try:
        engine.command(10, mask=optimized)
        before = viewport(engine, 4, 10, 7, 1)
        old_stats = engine.stats()[18:24]
        for _ in range(2):
            try:
                engine.command(2, x=10, y=10, width=1, height=1,
                               mask=1, count=1, budget=budget)
            except AssertionError as error:
                assert error.args == (-7,), (context, error)
            else:
                raise AssertionError(context + ': ambiguous multi-timer command was accepted')
            assert viewport(engine, 4, 10, 7, 1) == before, context + '/full-cell-rollback'
            check_state(engine, reference, budget, context + '/rollback')
            assert engine.stats()[18:20] == old_stats[:2], context + '/ticks-rollback'
        command = trigger(*isolated_source)
        engine.command(command['kind'], budget=budget, **command['fields'])
        reference.apply(command)
        check_state(engine, reference, budget, context + '/single-timer-fallback')
        engine.command(3, count=60, budget=budget)
        reference.advance(60)
        check_state(engine, reference, budget, context + '/single-timer-emits')
        engine.command(6, source_id=3, budget=budget)
    finally:
        engine.close()
    assert hashlib.sha256(path.read_bytes()).hexdigest() == source_hash, context


def suite(library, only=None):
    # Zero/one/two occupied slots put the cap after green/blue/red respectively,
    # making every adjacent color-pass ordering observable through lamp output.
    specs = cases() + [cap_case(False), cap_case(True), cap_case(2)]
    if only:
        specs = [spec for spec in specs if only in spec['name']]
        assert specs, f'No matching case: {only}'
    checked = []
    cancelled = 0
    swept = 0
    unsupported = 0
    with tempfile.TemporaryDirectory(prefix='timer-fifo-contract-') as directory:
        path = Path(directory) / 'timer.wld'
        for spec in specs:
            for streamed in (False, True):
                for optimized in (0, 1):
                    for budget in (1, 4096):
                        checked.append(run_case(library, path, spec, streamed, optimized, budget))
            print(f"PASS: {spec['name']} (8 native configurations)", file=sys.stderr, flush=True)
        if not only:
            for streamed in (False, True):
                for optimized in (0, 1):
                    for kind in (2, 3):
                        cancellation_case(library, path, streamed, optimized, kind)
                        cancelled += 1
                    for cached in (False, True):
                        swept += cancellation_sweep(library, path, streamed, optimized, cached)
                    for budget in (1, 4096):
                        for routing in (424, 445, 'over-65536'):
                            unsupported_case(library, path, streamed, optimized, budget, routing)
                            unsupported += 1
            print(f'PASS: {cancelled} cancellation cases, {swept} cancellation boundaries, {unsupported} unsupported/fallback cases', file=sys.stderr, flush=True)
    return dict(status='passed', reference=REFERENCE, matrix=checked,
                cancellation_cases=cancelled, cancellation_boundaries=swept,
                unsupported_fallback_cases=unsupported,
                input_sha256_unchanged=True, save_reopen_resets_timer_queue=True)


def baseline_proof(library):
    spec = cases()[0]
    observed = []
    with tempfile.TemporaryDirectory(prefix='timer-fifo-baseline-') as directory:
        path = Path(directory) / 'baseline.wld'
        reference = materialize(spec, path)
        reference.apply(trigger(8, 10))
        reference.advance(60)
        expected = reference.snapshot()
        assert [row[4] for row in expected] == [18, 0]
        for streamed in (False, True):
            for optimized in (0, 1):
                for budget in (1, 4096):
                    engine = Engine(library, path, streamed)
                    try:
                        engine.command(10, mask=optimized)
                        engine.command(2, x=8, y=10, width=1, height=1,
                                       mask=1, count=1, budget=budget)
                        engine.command(3, count=60, budget=budget)
                        actual = actual_snapshot(engine, expected, budget)
                        assert [row[4] for row in actual] == [0, 18], actual
                        observed.append(dict(streamed=streamed, optimized=optimized,
                                             budget=budget, frames_y=[row[4] for row in actual]))
                    finally:
                        engine.close()
    return dict(status='baseline-defect-reproduced', reference=REFERENCE,
                expected_frames_y=[18, 0], matrix=observed)


def export_fixtures(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    exported = []
    for spec in cases():
        filename = spec['name'] + '.wld'
        reference = materialize(spec, directory / filename)
        entry = dict(name=spec['name'], file=filename, initial=reference.snapshot(), steps=[])
        for command in spec['commands']:
            reference.apply(command)
            entry['steps'].append(dict(**copy.deepcopy(command),
                                       expected=reference.snapshot(), ticks=reference.ticks))
        reset = Reference(reference.cells, spec['width'], spec['height'])
        entry['reopened'] = reset.snapshot()
        exported.append(entry)
    # These two narrow gate origins have hand-audited expected timer frames;
    # keep them separate from the ordinary-wire oracle's supported behavior.
    from test_timer_gate_origins import fixtures as gate_fixtures
    for name, cells in gate_fixtures():
        filename = name + '.wld'
        write_world(directory / filename, cells)
        initial = [[x, y, cell[0], cell[1], cell[2]]
                   for (x, y), cell in sorted(cells.items()) if cell[0] in (144, 419)]
        pulsed = copy.deepcopy(initial)
        for row in pulsed:
            if row[2] == 144:
                row[4] = 18
            elif name == 'ordinary-and-gate-origin':
                row[3] = 18
        advanced = copy.deepcopy(pulsed)
        for row in advanced:
            if row[:2] == [7, 10]:
                row[4] = 0
        reopened = copy.deepcopy(advanced)
        for row in reopened:
            if row[2] == 144:
                row[4] = 0
        exported.append(dict(name=name, file=filename, initial=initial, steps=[
            dict(**trigger(5, 7), expected=pulsed, ticks=0),
            dict(**ticks(60), expected=advanced, ticks=60)], reopened=reopened))
    (directory / 'cases.json').write_text(json.dumps(dict(reference=REFERENCE, cases=exported), indent=2) + '\n')
    return len(exported)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('library', nargs='?')
    parser.add_argument('--output')
    parser.add_argument('--only', help='Run cases with this name substring')
    parser.add_argument('--baseline-proof', action='store_true')
    parser.add_argument('--export-fixtures')
    args = parser.parse_args()
    if args.export_fixtures:
        print(f'Exported {export_fixtures(args.export_fixtures)} original timer WLD cases')
    if not args.library:
        if not args.export_fixtures:
            parser.error('library or --export-fixtures is required')
        raise SystemExit(0)
    result = baseline_proof(args.library) if args.baseline_proof else suite(args.library, args.only)
    report = json.dumps(result, indent=2) + '\n'
    if args.output:
        Path(args.output).write_text(report)
    print(report)
