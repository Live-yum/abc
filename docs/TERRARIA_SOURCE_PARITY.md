# Terraria wiring source comparison

This comparison is pinned to
[`Live-yum/TerrariaDecompiledSource@8255d34616c780af12079425ac92a0a7aed87d71`](https://github.com/Live-yum/TerrariaDecompiledSource/tree/8255d34616c780af12079425ac92a0a7aed87d71).
Its [assembly metadata](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Properties/AssemblyInfo.cs#L9-L18)
identifies Terraria 1.4.5.8 and Re-Logic copyright. The complete tree inspected
for this audit contained no README, LICENSE, COPYING, or NOTICE file. Public
availability does not establish a redistribution license. The source was used
as a behavioral reference; no decompiled implementation is copied into this
change. New tests use original synthetic WLD files.

The product remains a generic WLD wiring simulator. This document distinguishes
implemented behavior, new fixture evidence, and known limitations. It does not
claim full game, NPC/player, mod, or world-generation parity.

## Behavior matrix

| Area | Pinned source oracle | Current implementation and evidence |
| --- | --- | --- |
| Timer loading | [WorldFile.cs L2568–2576](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria.IO/WorldFile.cs#L2568-L2576) reads both frames, then resets timer frameY to zero. | Already implemented. Import does not restore a live mechanical queue or timer phase. This is separate from preserving saved light frames. |
| Timer periods and registration | [Wiring.cs L178–208](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L178-L208) maps five styles to 60/180/300/30/15 ticks. [L296–310](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L296-L310) toggles enablement; [L455–472](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L455-L472) refuses duplicate registrations and limits the shared queue to 999 entries. | These mappings, registration cap, and existing-registration phase preservation are already present by static comparison. The existing native/Web timer smoke tests cover the 60-tick boundary. This audit does not add executable coverage for all five periods. Registration order remains a known difference, described below. |
| Switch footprints and seed skipping | [Wiring.cs L259–377](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L259-L377) chooses trigger footprints and changes switch frames; [L837–860](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L837-L860) skips source tiles during each color traversal. | Existing switch/timer/detonator handling remains unchanged. The two new light families are wire outputs and are not added to the switch-input list. New tests cover full-footprint seed exclusion and a later nonseed sibling triggering the whole light. |
| Ordinary PixelBox | [Wiring.cs L664–679](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L664-L679) commits horizontal+vertical hits once per TripWire; [L929–942](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L929-L942) records traversal axes. | Default OFF retains the established per-TripWire crossing policy. Optional ON deliberately uses the documented WireHead-style same-wave cross-color pairing and is not vanilla semantics. Existing `circuit_wld_pixel_contract.c` passes after this change. Direction-sensitive world-border eligibility has not been fully validated against the source traversal. |
| Hanging lantern, tile 42, 1×2 | [Wiring.cs L1684–1686](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L1684-L1686) dispatches to [L2831–2854](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L2831-L2854). | Added: complete coherent 1×2 footprints toggle frameX 0↔18, including unwired siblings; frameY style is preserved. Same-color duplicate hits in one TripWire toggle once; distinct colors toggle independently. |
| Standing lamp, tile 93, 1×3 | [Wiring.cs L1687–1689](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L1687-L1689) dispatches to [L2949–2974](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L2949-L2974). | Added with the same contract over three cells. Two disconnected same-color networks touching different members still produce one footprint toggle in a TripWire. |
| Light actuation and malformed frames | [Wiring.cs L996–1009](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L996-L1009) performs actuation first; [L3209–3245](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L3209-L3245) distinguishes deactivation eligibility from reactivation. | Normal 42/93 lamps are non-solid: actuator presence does not deactivate them or prevent the light toggle. Incomplete/incoherent footprints, unsupported frameX/frameY, and already-inactive actuator-bearing parts return unsupported on activation and roll back the complete command. The last case depends on directional first-hit order and is intentionally outside the aggregate-net implementation. Import, inspection, and unchanged save remain available. |
| Save/reopen | [WorldFile.cs L1436–1490](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria.IO/WorldFile.cs#L1436-L1490) writes important-tile frame coordinates; [L2568–2576](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria.IO/WorldFile.cs#L2568-L2576) reads them with the timer-specific reset. | All changed 42/93 members are projected into VIEWPORT and a separate candidate WLD. READ_LAMPS reflects the same light state. Independent reopen preserves light frames and style; the original input is not modified. |

Other multi-tile light families, including chandelier 34, lamp post 92, and the
2×2 light families 95/100/126/173/564, are outside this addition. Their source
handlers are visible at
[Wiring.cs L1684–1762](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L1684-L1762).
Pumps, entity teleportation, projectile-producing devices, movement-driven
pressure plates, and mod-only mechanisms are not established by the new tests.
A readable tile or a discovered wire is not evidence that every effect of that
device is simulated.

## Known timer registration-order difference

The source visits a wire network with a FIFO queue and registers timers when
encountered. Its mechanism update then runs registrations in reverse order
([Wiring.cs L160–208](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L160-L208),
[L837–977](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L837-L977)).
The compiled adapter currently visits device ports in coordinate order instead.

An original synthetic horizontal red line at y=10 with timers at x=5 and x=7
and a source at x=8 demonstrates the difference. Both timers begin off, use the
60-tick style, and are activated by one pulse from x=8:

- Source-derived expectation: x=7 is registered before x=5; the first cycle
  fires x=5 first and switches x=7 off. x=5 remains on.
- Executed native result: x=5 is registered before x=7; the first cycle fires
  x=7 first and switches x=5 off. x=7 remains on.

The native result was reproduced through the actual ABI. The source expectation
is a trace derived from the pinned methods, not execution of a Terraria binary.
This change does not alter timer sorting: coordinate sorting cannot in general
reconstruct FIFO traversal from an arbitrary source. A future fix needs an
explicit traversal-order contract and differential cases before claiming full
vanilla timer compatibility.

Reproduce the native observation after building `build/native-release`:

```sh
python - <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, 'tool')
from test_sparse_lamp_queries import Engine
from test_wired_lights import write_world, trigger, viewport
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'timers.wld'
    cells = {(x, 10): (144 if x in (5, 7) else 0, 0, 0, 1, 0, 0)
             for x in range(5, 9)}
    write_world(path, cells)
    engine = Engine('build/native-release/libabc_engine.so', path)
    trigger(engine, x=8)
    engine.command(3, count=60)
    print([(row[0], row[3] >> 16)
           for row in viewport(engine, 5, 10, 3, 1)
           if (row[2] & 65535) == 144])
    engine.close()
PY
```

Current result: `[(5, 0), (7, 18)]`.

## Implementation and validation

The two added families reuse retained device state, per-color footprint
deduplication, command snapshots, and the existing WLD projection. During the
existing column scan, a bounded two/three-cell check retains unwired siblings
only if their footprint has a wired member. Entirely unwired light decorations
do not create mutable device records. A 16,384-cell unwired synthetic fixture
has zero additional retained circuit allocation versus an empty world with the
same dimensions. Existing actuator retention rules are unchanged.

The native fixture suite covers 16 combinations: two families, retained versus
streamed input, optimization OFF versus ON, and work budgets 1 versus 4096.
Additional checks cover every member, unwired siblings, all four wire colors,
repeated pulses, footprint seed skipping, disconnected same-color inputs,
nonzero styles, cancellation after mutation, independent save/reopen, immutable
source hashes, and malformed-footprint rollback after an earlier valid light
has already changed. These are source-behavior tests with independent input
encoding; read-back alone is not a game-compatibility certification.

```sh
cmake -S native -B build/native-release -DCMAKE_BUILD_TYPE=Release
cmake --build build/native-release --parallel 2
python tool/test_wired_lights.py build/native-release/libabc_engine.so \
  --output build/wired-lights-native.json \
  --export-fixtures build/wired-light-fixtures

cc -O2 -UNDEBUG \
  -I native/vendor/TerraWasm/include -I native/vendor/TerraWasm/src \
  native/circuit_wired_light_contract.c \
  build/native-release/terra/libterrax_world_static.a -lm -lz \
  -o build/circuit_wired_light_contract
build/circuit_wired_light_contract

# Use the newly built, authorized Web artifacts, not an earlier binary.
node test/web/world_circuit_lights_contract.cjs \
  path/to/world.js path/to/world.wasm build/wired-light-fixtures
```

The Web contract executes the same 18 original fixture files in both modes,
including save/reopen and unsupported-command rollback. Its presence or a
JavaScript syntax check does not establish that a WASM build was executed;
report the actual command result for the tested artifact. ASan/UBSan can run the
C contract against the instrumented static library using the existing native
workflow flags. This avoids mixing Python-host allocator noise into sanitizer
claims about the C contract.

Native Release fixture tests and the original device-epoch and PixelBox C
contracts passed during this audit. Flutter UI/device performance and full
game-world parity are separate acceptance work; no Flutter SDK was available
in the audit environment.
