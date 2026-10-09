# Complete public Computerraria acceptance

`.github/workflows/computerraria.yml` is a separate acceptance gate for the
complete public upstream world. Passing the generic synthetic performance
workflow does not satisfy this gate. This workflow has read-only repository
permissions and performs no release, deployment, signing or credential changes.

## Inputs and implementation under test

`tool/computerraria_inputs.py` downloads only the MIT-licensed public pair at
`misprit7/computerraria@0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8`. The input
manifest verifies the compressed archive, complete 405,983,441-byte format-279
WLD (15,200 × 7,200), and 427,712-byte compressed TWLD. The companion is streamed
through the real importer. The large world is not replaced with a crop or a
synthetic fixture. No personal world, player or resource-pack discovery occurs.

The application reads the original wires, gates, ROM/RAM lamps, sensors and
physical pixel controllers. The upstream Pong program executes through those
circuits. Neither tModLoader/WireHead nor a CPU emulator is a runtime dependency.
The default OFF mode preserves the existing circuit strategy. ON enables the new
generation-based deduplication path. Both modes share the preexisting group cache
and lazy parity machinery; the comparison does not attribute those shared
optimizations to the new switch.

All inputs and save outputs remain under ignored build/temporary directories.
Artifacts contain reports, logs, hash manifests and the actual Flutter profile
application bundle. Original WLD/TWLD files, the download archive and generated
save outputs are never uploaded. The app bundle contains only the repository's
authorized assets, not the full input world.

## Acceptance lanes

1. Native: three fresh processes per mode build and use the actual Release C
   engine with read-only allocation counters. Every process imports the complete
   pair, checks 48 CPU signatures and a real one-bit ROM negative control, tests
   sticky/read-clear input sensors, runs upstream Pong, verifies real mono/color
   display records, saves the complete pair and reopens it. A real display program
   sets and clears target words after reopening. Owner allocations must return
   to zero after close.
2. Web engine: three fresh processes per mode use the Emscripten 5.0.7 Release
   WASM artifact, built from the same recorded sources. The actual Web file-owner
   bridge runs the complete pair and physical program with `--compound-frame`.
   Each unchanged 128-pulse batch uses the production compound RPC and alternates
   monochrome/color selection. Every returned selected frame is checked byte for
   byte against an ordinary read at the same electrical state. The real RPC
   client/host, remapping and ArrayBuffer transfers run in a same-thread Node
   loopback. Node cannot clone `fs.openAsBlob` handles, so this adapter preserves
   immutable file-backed Blob identity without copying the world. This is not
   browser File-transfer, worker-threading or rendering evidence. The same six
   processes also verify paired save/reopen, full record hashes and zero
   native/bridge/file owners after close; no additional heavy jobs are added.
3. Flutter UI: three independent Linux `flutter drive --profile` processes run
   under Xvfb. Each process retains two complete import/run/reset/close cycles in
   each mode, including the first cycle. Import cancellation is also exercised.
   Each cycle uses the same 5,120 physical pulses and calibrated UP/DOWN inputs,
   with actual mono/color and physical RAM hashes every 512 pulses. A separate
   input phase sends keyboard down/up events on the production monitor and touch
   hold/release on the production direction button. A separate 30-second steady
   Pong window records actual Flutter engine UI/raster frame timings, physical
   pulse count, display polls and observed changed frames. RSS and VM-service heap
   samples cover the baseline, paused state and every close.

Each process is bounded at 20 minutes and each lane at 90 minutes. Timeouts remain
failures; they cannot become a passing partial report. The driver and app-side
standalone report, process stdout/stderr, failed attempts and profile bundle are
retained. Reruns use a new output directory and do not overwrite earlier attempts.

## Exact comparison and interpretation

`computerraria_compare.py` requires all 15 process reports and successful jobs.
It verifies the process exit status, report SHA-256, unique process run ID, exact
requested commit, clean source state, source file hashes, built artifact hashes,
public input identity and correct mode. Absent, dirty, failed, truncated or
debug-only reports cannot pass.

Build manifests retain the actual CMake configuration. The Linux profile
manifest also records generated Ninja compiler flags for the ABC world bridge,
physical circuit world and circuit VM. The gate requires Release-equivalent
`-O3 -DNDEBUG` C flags inside the Flutter Profile application, so the UI
calibration cannot silently run an unoptimized native engine.

Within each backend, all three OFF and all three ON runs must have identical
deterministic CPU/input results, Pong pulse checkpoints and full display hashes.
The complete saved WLD/TWLD byte counts and hashes must match, as must the full
mono/color records before save, after reopen, and after post-reopen set/clear.
Resetting/replacing a paused Pong ROM can change other buffered display words;
the gate compares the observed full records instead of assuming that all other
pixels are unchanged.

The CI Web lane requires compound coverage for every measured batch, correct
alternating monitor sizes and both selections during Pong. Missing compound
evidence, a browser/FPS transport label, or mixed clock/roundtrip measurements
fail the gate. Historical standalone reports can still be validated explicitly
as separate-command evidence; they do not satisfy this compound CI requirement.

Web `node-bridge-clock-stage-v1` throughput uses only the bridge's physical clock
command duration. It excludes the subsequent pixel read and RPC roundtrip. The
compound clock-plus-selected-display roundtrip has a separate millisecond table.
Legacy `node-awaited-clock-command-v1` measurements include the externally
awaited dispatch; the summary keeps these scopes in separate rows instead of
pooling their rates. Neither measure is browser threading, rendering or FPS.

The Flutter fixed trace is compared across modes and processes separately from
the wall-timed run. Faster modes can execute different pulse counts in the same
30-second window, so wall-time end states are not compared for equality. The
reported keyboard/touch latency ends at completion of the actual native sensor
command. It excludes the physical keyboard/OS path and does not claim
input-to-presented-pixel latency.

Actual raw `FrameTiming` arrays are required in every steady cycle; declared
counts are checked against those arrays. The refresh budget is computed from
the observed Flutter display refresh rate. Quick successful operations may have
no engine frame within their short window; the report retains that absence.
Observed frame counts, p95 UI/raster durations, over-budget frames, input latency
and first/repeat heap/RSS observations are reported quantitatively. Physical
clock Hz, poll Hz and displayed changes are distinct measurements.

The first accepted run is calibration. There is no fabricated historical
baseline, arbitrary pass/fail FPS target, memory-leak threshold, or claim that
software-rendered Xvfb represents a particular phone or desktop. All first and
repeat cycles are retained with no excluded warmup; OS/filesystem cache state is
uncontrolled. Raw artifacts make later controlled comparisons possible.

## Reproduce the report gate

Download this workflow's three `computerraria-raw-*` artifacts into directories
with those names, then run:

```sh
python3 tool/perf/computerraria_compare.py \
  --reports build/computerraria/candidate \
  --output build/computerraria/summary \
  --expected-commit FULL_40_CHARACTER_SOURCE_COMMIT
```

`comparison.json` contains the validation result, accepted evidence, individual
measurements and correctness digests. `comparison.md` is the human-readable job
summary. Helper tests use small synthetic report objects and do not claim to
execute the actual world:

```sh
python3 -m unittest discover -s tool/perf -p 'computerraria_checks_test.py'
```
