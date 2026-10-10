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
| Timer periods and registration | [Wiring.cs L178–208](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L178-L208) maps five styles to 60/180/300/30/15 ticks. [L296–310](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L296-L310) toggles enablement; [L455–472](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L455-L472) refuses duplicate registrations and limits the shared queue to 999 entries. | The timer FIFO contract now compares all five periods, existing-registration phase, the shared 999-position limit, and timer-driven output order against an independent ordinary-wire model. The bounded ordering subset and explicit unsupported cases are described below. |
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

The generic circuit viewport still colors ordinary tiles by type. The new
42/93 state and saved-frame contracts do not add game-style light emission or
a dedicated lit/unlit lamp appearance to that overview. PixelBox rendering
and dedicated game-light rendering are separate features.

## Bounded timer encounter order

The fixed source visits each color with a FIFO. It seeds the complete trigger
rectangle with x as the outer loop and y as the inner loop, skips device effects
on those seeds, then expands down, up, right, left. All same-color seed
components share that queue. Colors run red, blue, green, yellow. A neighbor is
eligible only at coordinates `[2, width-2)` and `[2, height-2)`; an outside seed
can still enter the eligible interior. See
[TripWire L525–646](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L525-L646)
and [HitWire L837–979](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L837-L979).
The mechanism update visits registrations in reverse order
([L160–208](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L160-L208)).

An original horizontal red line at y=10, timers at x=5 and x=7, and a source at
x=8 exposed the old coordinate-order bug. At the 60-tick boundary the old native
ABI produced `[(5, 0), (7, 18)]`. The ordinary-wire FIFO registers x=7 before
x=5, so x=5 fires first and disables x=7. The candidate now produces the
source-derived `[(5, 18), (7, 0)]`. The expectation is derived from the pinned
source; this is not execution of a Terraria binary.

The new optional index retains only timer-bearing ordinary wire networks when
the world has at least two wire-connected timers. It is built during the
existing column replay, with no additional world scan and no width×height
array. Replaying a trigger uses its real rectangle or physical gate origin and
one FIFO per color, including disconnected components. Ordinary-wire cycles
use mark-on-enqueue visitation; source routing tiles are handled as the explicit
limitation below rather than approximated by this rule.

First-use traversal yields after each seed or wire cell. The one fixed visited
buffer clear is at most 64 KiB. Timer application also yields one hit at a time.
Sixteen LRU entries cache source rectangle, color mask and encounter list;
repeated triggers replay the timer list without traversing the wire graph.
Each cache entry stores at most 4,096 hits (256 KiB total). Longer valid traces
still execute completely but are not cached. Cached traces are immutable
geometric facts; a cancelled incomplete trace is never marked valid. Mode
changes clear the cache, and closing/reopening creates a new index.

The index has a hard limit of 65,536 wire-color cells. Its cells use at most
1 MiB; the conservative FIFO including border seeds uses at most 1.25 MiB plus
16 bytes, and visitation uses at most 64 KiB. Network metadata and gate origins
are separately capped at 65,536 entries (512 KiB and 1 MiB). All allocations are
charged to the existing circuit memory budget. When the VM is inactive and no command transaction is in progress, a required
allocation can discard the optional index and retry. This also protects later
inspection/save queries and the next command snapshot. Runtime
workspace/cache allocations immediately reduce the VM's remaining allocation
ceiling, so the owner and VM cannot spend the same bytes twice.

If a TripWire reaches more than one timer and its index is unavailable, or any
affected timer network contains a junction (424) or PixelBox (445), the command
returns unsupported and rolls back the complete command. A routing tile used
as an outside-border seed is likewise rejected for such a multi-timer command.
A missing/incomplete geometric trace also fails explicitly; it never falls back
to coordinate sorting. Loading, inspection, unchanged saving and unambiguous
single-timer operation remain available. This replaces an incorrect outcome
with an explicit limit for these cases; full direction-sensitive timer parity
is not claimed. The optimization switch still defaults OFF, and its separate
ON PixelBox rule is unchanged.

Timer effects are applied at the end of their TripWire, before gate evaluation.
This is safe for the currently supported handlers: a wire-hit timer changes
only its own frame and mechanical registration
([L296–310](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L296-L310),
[L1012–1016](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L1012-L1016)).
The wire-hit 411 button changes its footprint frames without registering a new
mechanism ([L1115–1137](https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs#L1115-L1137));
manual button interaction registers before the traversal. The supported light,
actuator and gate handlers do not inspect timer frames during that traversal.
Gate evaluation remains after the completed trip. Extending support to other
mechanical handlers requires revisiting this ordering argument.

The independent Python oracle encodes original synthetic WLD fixtures and
models FIFO traversal plus reverse mechanical updates. It tests the actual
native C ABI, both retained and streamed input, OFF/ON, budgets 1/4096, all five
periods, branches, loops, multiple seeds/colors/pulses, phase preservation, the
shared cap, cancellation/retry, immutable inputs and candidate save/reopen.
Separate gate-origin fixtures cover ordinary AND and the existing compiled
faulty/single-lamp gate representation, so timer traversal cannot accidentally
reuse the external trigger point for a gate output. The native C contract
checks traces longer than 4,096 hits, LRU eviction, partial replay restart,
shared VM/owner memory ceilings and eviction under idle/query allocation
pressure.
The Web runner uses the same exported expected traces against rebuilt WASM;
its presence alone does not establish that it ran.

```sh
python tool/test_timer_fifo.py build/native-release/libabc_engine.so \
  --output build/native-timers.json
python tool/test_timer_gate_origins.py build/native-release/libabc_engine.so \
  --output build/native-timer-gates.json
python tool/test_timer_fifo.py --export-fixtures build/timer-fixtures
node test/web/world_circuit_timer_contract.cjs \
  path/to/world.js path/to/world.wasm build/timer-fixtures
```

The fixed 405,983,441-byte public Computerraria world contains one wired timer
at `(3202,159)`. A candidate native streamed-load inspection found no optional
index allocation, then completed clock/reset smoke commands in OFF and ON.
The input SHA-256 remained
`55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.
This rules out this new multi-timer restriction on that fixture's timer path;
it is not the complete physical-CPU/Pong, Flutter UI, or performance acceptance.

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
has already changed. Eight additional timer-driven exception/cancellation cases
cover both families in both modes and verify rollback of light state, timer
progress, and cooldown before a successful retry. These are source-behavior tests with independent input
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
contracts passed during this audit. The first official diagnostic run
[38057554463](https://github.com/Live-yum/abc/actions/runs/38057554463), pinned to
`11f669da12788e556e3057b6bd9b3ca6db1c1947`, also passed the three
ASan/UBSan C contracts and the rebuilt Web artifact’s 36 fixture/mode cases.
The eight timer-driven rollback cases were added after that run. The Native
job in [full CI run 38060354468](https://github.com/Live-yum/abc/actions/runs/38060354468),
pinned to `ca7ee6ba74556a69432a09d1f8729a51bffd04d6`, subsequently passed
those eight cases, the 16 fixture combinations, and the sanitizer contracts.
That run’s separate Web job failed before its tests because a shallow checkout
lacked the fixed c61 source object required by the provenance test; Native
success does not imply that the entire run passed.
Flutter UI/device performance and full game-world parity remain separate
acceptance work. SDK-dependent checks run in official CI.
