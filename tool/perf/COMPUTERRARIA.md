# Complete WLD-only Computerraria acceptance

`.github/workflows/computerraria.yml` checks the complete public world. Generic
synthetic performance tests cannot substitute for this gate. The workflow has
read-only repository permissions and performs no release, deployment, signing
or credential changes.

## Input and implementation

`tool/computerraria_inputs.py` retrieves the MIT-licensed public archive from
`misprit7/computerraria@0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8`, verifies it,
and streams out exactly the complete 405,983,441-byte format-279 WLD. The world
has dimensions 15,200 × 7,200, 72,939,714 wired cells and 13,641,575 gates.
Only that WLD is opened by the application. No personal-file discovery occurs.

The generic application imports actual wires, gates, lamps, sensors and pixel
boxes. Independent test-only Native and Node drivers apply the public fixture
layout and execute unchanged upstream Pong through those circuits. Production
has no CPU/program controls or fixture coordinates. There is no runtime
instruction decoder or supplied framebuffer.
The native world-circuit ABI is 2; reports record the ABI from actual imported
circuit statistics. Optimization defaults OFF. OFF applies the original game's
per-TripWire horizontal/vertical PixelBox crossing rule. ON adds generation-based
device deduplication and WireHead-style different-colour group pairing within
one gate wave. Both retain the existing group cache and lazy lamp parity. This
pixel-rule difference is explicit; changing the switch while idle preserves the
current monitor frames, ROM/RAM, input and RNG, while later pulses may differ.

`circuitWorldWireHeadPixels: 1` advertises this rule. Non-SAVE READY bits 1/2/3
mean optimization selected / supported topology / WireHead-style rule selected.
Bit 0 remains zero. Worlds with no PixelBoxes support ON. A pixel whose same-colour
H/V axes both connect to real neighbours but have different compiled networks
requires a topology merge; enabling ON returns `TCW_UNSUPPORTED` and leaves OFF
usable. Disconnected compiler axis stubs are ignored, and duplicate H/V ports
for one group count only once. Direct pixel triggers use the same canonical group.

This is a per-pixel rule inspired by WireHead, not an unrestricted replica.
WireHead's dictionary retains only one coordinate when multiple pixels reuse the
same group pair; this implementation deliberately applies the pair rule to each
pixel rather than copying that overwrite behavior. Source references are
WireHead commit `e6009d010ca54ff43d04b44697accc7115807b9c`,
`Accelerator.cs` and `WiringWrapper.cs` (MIT), and the original rule at
`Live-yum/TerrariaDecompiledSource` commit
`8255d34616c780af12079425ac92a0a7aed87d71`, `Terraria/Wiring.cs`, SHA256
`c05fac30c1e1d13720a30be89c957b4ea5cc84be18e44e4a2c44ea532ab89832`.
No game source copy is distributed with the rule implementation.

The archive, WLD, compiler scratch and saved worlds remain in ignored temporary
or build directories. Uploaded evidence contains reports, logs, hash manifests
and the actual Flutter profile app bundle, never full input or saved worlds.

## Acceptance lanes

1. Native: three fresh processes per mode use the Release C engine with allocation
   counters. Each imports the complete WLD, writes authored ROM fixtures, checks
   48 CPU signatures and a one-bit ROM negative control, exercises physical input
   sensors, and runs unchanged upstream Pong. Display tests query the actual
   64 × 48 monitor, compare direct records with viewport records, save one WLD,
   reopen it, and execute real monochrome set/clear programs. Tracked owners must
   return to zero after close.
2. Web: three fresh processes per mode use the Emscripten 5.0.7 Release artifact.
   With `--compound-frame`, every unchanged 128-pulse batch executes the real
   compound RPC and reads the complete monochrome monitor. Returned bytes must
   equal an ordinary read at the same electrical state. Real RPC remapping and
   ArrayBuffer transfers run in a same-thread Node loopback. Node cannot clone
   immutable `fs.openAsBlob` handles, so this adapter preserves their identity
   without copying the world. This does not establish browser File transfer,
   worker threading or rendering performance. Single-WLD save/reopen and zero
   native/bridge/file owners are also required.
3. Flutter UI: three independent Linux `flutter drive --profile` processes run
   under Xvfb using schema `abc.generic-world-profile.v1`, workload
   `generic-wld-controls-v1`. Two cycles per mode retain import, real wire-mask
   direct trigger, one tick, a 30-second generic run/pause, explicitly selected
   sparse PixelBox ROI, save, original-source reset and export reopen/close.
   One cancelled import and all 13 load/reset/reimport OS windows are retained.
   The ROI and trigger come from actual viewport records, without CPU coordinates
   or a 64 by 48 assumption. FrameTiming, VM heap and OS observations remain
   separate. Unknown display calibration cannot establish smoothness. No ROM,
   fixture keyboard or Pong action is dispatched through the application.

Each process is bounded at 20 minutes and each lane at 90 minutes. Timeouts,
failed or incomplete display behavior remain failures, never passing partial
reports. Reruns use new output directories. The driver report, standalone app
report, stdout/stderr and profile bundle are retained.

## Correctness and provenance

The gate requires all 15 process reports, exact source HEAD, a clean checkout,
source/build artifact hashes, pinned WLD identity, observed ABI 2 and explicit
`inputFormat: wld-only`. Native/Node fixture reports retain schema 2; the current
Flutter UI has its own generic schema and workload identity. Historical CPU UI
reports cannot satisfy current generic action coverage or direct comparisons. Linux Profile builds must prove actual generated `-O3 -DNDEBUG`
flags for the world bridge and circuit VM.

The 48 arithmetic/control-flow/memory results come from the authored physical
ROM fixture's instruction semantics. The mutation must change only the first
result to `0x7fffffff`. `display` and `clear` in
`native/fixtures/computerraria/programs.json` are authored monochrome-only ROM
programs; they are distinct from the unmodified 2,288-byte upstream Pong asset.

CPU, input and fixed-clock traces are compared across OFF/ON. Pixel projections
are validated against each mode's declared rule, then compared exactly within
that mode across repetitions and runtimes. For the bounded authored display program and 1,536-clock Pong fixture, the
original WLD's monitor was observed dark under the per-TripWire rule. This is an
explicit display compatibility limitation, never successful Pong-display
acceptance, and is not a claim about all programs or longer input trajectories. ON must
produce the intended physical set/clear pixels and moving upstream Pong states.
New WLD-only frame hashes require fresh execution; older evidence is not a new
golden. Two equally halted executions cannot pass continuation liveness.

The initial pure-WLD OFF diagnostic correctly failed the former all-modes-display
assertion after its CPU tests passed. The new rule's fresh Native ON proof passes
those unchanged display/Pong checks. The mode-specific validator requires fresh 12-point passive ready/RAM/stack
traces before cross-mode CPU equality can be claimed. The complete multi-process
CI gate remains separate from individual local process results.

A saved world's immediate monitor records must exactly equal pre-save records.
Resetting and replacing a paused Pong ROM may affect other buffered words;
post-program full-record hashes are compared across identical traces within each
mode instead of asserting that unrelated buffered words never change.

## Timing and input interpretation

Web `node-bridge-clock-stage-v1` timing covers only the physical clock command.
Selected-display reads and compound loopback roundtrip milliseconds have their
own table. The externally awaited separate-command scope remains distinct.
No Node measure is browser rendering FPS. Physical clock Hz, display-read Hz,
changed monitor states and actual Flutter frames are separate measurements.

Flutter's fixed physical trace is compared separately from its wall-timed run:
faster modes can execute different pulse counts in the same 30-second window.
The display frame budget derives from observed refresh metadata. Raw timing
arrays are required in each steady window; declared counts cannot replace them.
Quick successful actions may have no engine frame in their short sample window,
and that absence remains visible.

First sensor acknowledgement is measured for all four directions and touch.
In ON mode, UP/DOWN/touch-DOWN remain held until the first valid changed decoded
paddle state, then release in `finally` and verify that sensor pulses stop.
OFF retains real sensor acknowledgement/release checks and reports paddle
observation as not applicable because its display compatibility is unsupported;
its physical CPU/RAM liveness and observed monitor records remain mandatory. Their separate
`pressToPaddleStateMs` is labeled
`decoded-physical-monitor-state-not-raster-presentation`. The shared deadline is
5,000 ms from press: `0 <= sensor latency <= paddle-state latency <= 5000`.
LEFT/RIGHT are sensor-only because upstream Pong does not move its paddle for
those directions. Neither latency includes the physical OS input path or raster
presentation.

## Memory during actual loading

`loadingOsMemory` uses schema `abc.profile-loading-os-memory.v1`. A sampler isolate
reads only its own Flutter application PID while loading is active. Its memory
and bounded bookkeeping are included; compiler, driver, Xvfb and other processes
are excluded. There are nine chronological windows: one cancelled attempt and
eight ready loads, plus eight independent close samples. Every ready load must
have real periodic status samples as well as baseline/terminal samples. Readiness
requires the verified complete WLD and actual initialized 12,288-byte monochrome
RGBA plane.

RSS, smaps RSS, PSS and USS sampled maxima are retained independently with their
observation times. VmHWM is a separate cumulative process measurement at each
boundary; it is never called a per-load maximum. Status and smaps reads are
sequential and may disagree. PSS/USS may be explicitly unavailable or partial,
with the read failure reason retained; absent values are never replaced by zero.
Target intervals are 10 ms for status and 100 ms for smaps. Actual counts,
min/mean/max gaps and non-overlapping interval histograms are validated and
reported. Sampling may miss peaks between observations.

The first complete load follows cancellation in the same host. Later loads are
labeled repeats; filesystem cache state is uncontrolled throughout. These data
establish observed baseline, sampled peak, terminal and close memory, without an
invented absolute memory budget or leak threshold.

## Run and compare

After building the exact native and Web artifacts:

```sh
python3 tool/computerraria_inputs.py
mkdir -p build/computerraria/tmp
export TMPDIR="$PWD/build/computerraria/tmp"
ABC_COMPUTERRARIA_SAVE=1 dart run native/computerraria_acceptance.dart \
  build/native-wld-only/libabc_engine.so \
  build/public-computerraria/computerraria.wld - test/fixtures/computerraria/pong.bin \
  build/computerraria/native-standard.json
node test/web/computerraria_file_acceptance.cjs \
  web/engine/world.js web/engine/world.wasm \
  build/public-computerraria/computerraria.wld \
  build/computerraria/web-standard.json \
  --pong test/fixtures/computerraria/pong.bin --input - --save --compound-frame
```

For ON, set `ABC_COMPUTERRARIA_OPTIMIZED=1` for Native or add `--optimized` for
Web, and use separate report files. The existing bounded CI runs cover both.
Download the three `computerraria-raw-*` artifacts and run:

```sh
python3 tool/perf/computerraria_compare.py \
  --reports build/computerraria/candidate \
  --output build/computerraria/summary \
  --expected-commit FULL_40_CHARACTER_SOURCE_COMMIT
python3 -m unittest discover -s tool/perf -p 'computerraria_checks_test.py'
```

Helper tests use synthetic report objects and do not execute the actual world.

## Optional bounded continuation and ownership probes

The same-program diagnostic explicitly selects ON before both live and reopened
runs. It saves after the 5,120-pulse input trace, continues
live for 4,096 pulses, then reopens the saved WLD and repeats the exact trace.
No reset, ROM write, bus-zero pulse or boundary advance occurs after reopening.
Every 128-pulse checkpoint compares full monitor records, the ready lamp, stated
CPU/input-area lamp probes and the first 64 plus last 1,024 bytes of physical RAM.
Those lamp probes do not claim a complete architectural register/latch map.
Liveness requires changing CPU/RAM/monitor state and held-UP paddle motion.

```sh
node test/web/computerraria_continuation_probe.cjs \
  web/engine/world.js web/engine/world.wasm \
  build/public-computerraria/computerraria.wld test/fixtures/computerraria/pong.bin \
  build/computerraria/continuation.json
```

The repeated owner probe requires fresh successful ABI-2 Native acceptance
reports for both modes from the same library and WLD. It uses the same fixed
1,536 Pong clocks and each mode's complete monochrome hash, retaining exact
same-mode cycle equality while preserving different pixel rules:

```sh
dart run native/computerraria_soak.dart \
  build/native-wld-only/libabc_engine.so \
  build/public-computerraria/computerraria.wld \
  build/computerraria/native-standard.json \
  build/computerraria/native-optimized.json 50 build/computerraria/soak.jsonl
```

These optional probes add no CI jobs. No historical result is asserted to pass
the new contract before fresh execution.
