# Full-world physical computer workflow

The World Circuit panel accepts one complete `.wld` through ranged sources.
The native picker passes a path and the browser passes the selected File/Blob;
the 405,983,441-byte reference world is not copied into a Dart `Uint8List`.
Only WLD data is parsed, simulated and exported. No mod runtime, companion file
or host RISC-V emulator supplies missing devices or display state.

The pure-WLD migration uses circuit ABI 2. Final Native/Node OFF/ON acceptance
passed in one fresh process per backend/mode: OFF runs the physical CPU, while
ON drives actual monochrome Pong. Node ON saved continuation also passed.
Current Flutter UI, final pure-WLD long soak and repeated clean-CI acceptance
remain pending. The isolated loading results below do not measure those final
artifacts; prior companion-format results are historical evidence only.

## Test fixture, not an application mode

Production has no ROM loader, Pong button, RV32I control, preset screen or
sample direction-key mapping. File hashes never activate hidden behavior.
This WLD follows the ordinary generic wiring path. Its empty ROM and missing
NPC motion are not replaced by implicit test data or clock pulses.

Explicit native/Node acceptance and
`test/support/computerraria/fixture_driver.dart` contain the pinned layout.
That driver issues physical lamp/trigger/pixel commands through an injected
serialized executor. It does not interpret RISC-V instructions or produce an
expected framebuffer. Program bytes are in `test/fixtures/computerraria/`,
not the Flutter asset bundle. Provenance is fixture-only; production no longer
records known program identities for exported WLDs.

The following CPU/UI timing evidence describes earlier explicitly named
workloads. Former application buttons and keyboard measurements do not validate
the new generic interface. Revised app profiles have separate workload/schema
identities; physical engine fixture checks retain their explicit hashes.

## 电路优化 switch

The switch defaults **off**. Both modes retain compiled connectivity and grouped
lamp state. OFF uses the game rule: within each TripWire, horizontal and vertical
hits together toggle an ordinary PixelBox; accumulated hits clear afterward.

ON adds generation-stamped device deduplication and WireHead-style ordinary
PixelBox semantics: different-color network-hit parity pairs are accumulated
within one logic-gate wave and toggle the actual pixel. Hits do not carry into
the next wave. This is a behavior difference for future pulses, not just a speed
setting. The complete original WLD's 3,072 monochrome PixelBoxes have verified
single-axis connections for each color, so its existing topology can be reused.
Worlds whose same-color axes require merging distinct networks reject ON;
standard mode remains available. No missing device data is synthesized.

Changing modes pauses the runner and drains the accepted batch. The change
itself preserves ROM, RAM, inputs and existing pixels; subsequent pulses follow
the selected rule. Fixture tests declare their own pulse batch size. The app does
not embed the complete WireHead accelerator. Final Native/Node OFF/ON checks
passed for physical CPU execution and ON's actual 3,072-pixel monochrome Pong
display. Current UI acceptance remains pending. Historical companion-format
OFF/ON pixel-equality evidence does not apply to the new rule.

## Fixture displays and historical timing

- Monochrome: `(6485,800)`, 64 × 48, actual type-445 frame X 0/18.
- Queries read the compiler's retained pixel cells, without rescanning the
  entire WLD. The fixture requires its known dense screen. Generic production regions
  accept sparse gaps and reject duplicate, wrong-type or invalid-frame pixels. It never draws an expected test image or a host-side framebuffer.
- Frames are converted to nearest-neighbor RGBA images. Image decoding permits
  one pending request; replaced/disposed images cannot reappear after close.
- The unsupported mod-only color screen is absent from the interface. Its
  content cannot be recovered from the WLD, and no replacement pixels are
  synthesized.
- Physical clock Hz and display polling Hz are measured separately from Flutter
  frame timings. Polling is requested at most about 60 times/second and slows
  with execution. No fixed 5 kHz or target-device frame-rate guarantee is made.

## Source identity and test program

Original source: [Computerraria commit 0379d5b](https://github.com/misprit7/computerraria/tree/0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8).
The WLD is format 279, 15,200 × 7,200 tiles, SHA-256
`55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.
The original world is fetched only for authorized validation and is not bundled
in the repository or public report artifacts.

`test/fixtures/computerraria/pong.bin` contains the actual upstream Pong program compiled
for RV32I, 2,288 bytes, SHA-256
`d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d`.
The Pong source is unchanged. Two `cfg` attributes exclude host-only SpriteGrid
code from the RISC-V build. MIT © 2023 Xander Naumenko, complete license, source,
patch and build provenance are retained in `vendor/computerraria`.

With official Rust 1.85.1 and its `riscv32i-unknown-none-elf` standard library
already installed, rebuild using:

```sh
sh vendor/computerraria/build-pong.sh
cmp test/fixtures/computerraria/pong.bin vendor/computerraria/pong-build/output/pong.bin
```

The script uses the existing `rustc`/rustup shim on PATH, or
`COMPUTERRARIA_RUSTC`. It does not download a compiler or execute upstream host
build scripts. The extractor maps allocatable ELF data by physical load address;
it does not execute the program.

## Bounded loading evidence

Three fresh standalone C processes per variant loaded the public reference WLD
and compiled its circuit. Median loading fell from **17.654 to 9.664 seconds
(45.26%)**, with optimized maximum observed process RSS **143.871 MiB**. The
compiled structures matched; peak RSS was effectively unchanged. The optimization
uses sparse compiler indexes and checked inline decoding, with no persistent
compiled cache. These measurements identify isolated Native library
`08fd47547cb2ba13401a525c01b0b5ea9f9390f1ade232c1d39c538e98944d1f`;
the final merged Native/WASM artifacts differ and need fresh measurement.
A separate single Dart owner import took **14.874 seconds**. Neither result is
an actual Flutter UI import measurement.

On a private real v326 WLD (8,400 × 2,400; 11,956,596 bytes), three runs per
variant reduced standalone TCW open/full compilation median from **1.9931 to
0.5539 seconds (72.21%)**. Compiled structures matched and tracked owners were
zero after close. This excludes ordinary preview/rendering and input hashing.
Only sanitized size/version/dimension and timing evidence is included publicly;
the private source, name, path and hash remain excluded.

Both comparisons used uncontrolled OS page cache, so fresh processes do not
establish cold-storage performance. They do not measure browser/Flutter memory,
program execution or export, and do not establish complete resident-memory
return. The [historical pure-WLD baseline report](evidence/standalone-native-load-2026-10-09.json)
is preserved unchanged. See the
[sanitized comparison](evidence/standalone-native-load-optimization-2026-10-09.json)
and [standalone measurement protocol](../tool/perf/NATIVE_LOAD_PEAK.md).

## Verification and profiling

Final Native `d033ffd6…bf9d7` and Node WASM `b3ace044…e7b8` passed both modes
and strict report validation, one fresh process per backend/mode. The 48 CPU
signatures, one-bit ROM negative control, 23 input probes, 12 ready/RAM/stack
checkpoints and saved RAM match across modes. Same-mode Native/Node complete
display and saved-WLD hashes match. ON produces actual moving monochrome Pong;
both modes pass single-WLD save/reopen, and the public original is unchanged.
Twelve 128-pulse Pong batches measured OFF/ON clock-command rates of Native
**1,012 / 6,014 pulses/s** and Node **979 / 5,848 pulses/s**. Node median compound
round trips were **131 / 22 ms**. Native awaited-command and Node bridge-stage
measurements have different boundaries; neither is browser FPS or Flutter frame
timing.

The separate ON continuation probe saved at 5,120 pulses, reopened without reset
or ROM rewrite and matched 32 subsequent 128-pulse checkpoints across live and
reopened sessions. It compares all 3,072 monochrome pixels, 654 CPU-area lamps,
45 input-area lamps and 272 RAM words (a 64-byte prefix plus the 1,024-byte Pong
stack region). It observed 21 display states and 33 states in each other probe
set; held UP moved the paddle center from 24.5 to 23.5. Brief UP/DOWN did not move
the paddle in these traces. Native/bridge/file owners returned to zero. This
bounded check does not cover all architectural registers/RAM, arbitrary
programs, complete game behavior or actual UI latency. See the
[sanitized backend acceptance report](evidence/pure-wld-backend-acceptance-2026-10-09.json).
Current UI, final pure-WLD long soak and repeated clean-CI acceptance remain pending.

Focused tests cover content/profile gating, large-file descriptor selection,
ROM banks/endian/tail clearing, program limits, native monochrome states, cancelled
import and reload, cancelled partial program loading, physical clock batching,
pause/close ordering, and actual image widgets. Fake-backend tests validate host
contracts, not physical CPU execution.

The former `computer_world_profile_test.dart` loaded a program through CPU
buttons and injected direction keys. These features were removed. Retained
reports are historical and cannot be compared as the same generic workload.

Revised opt-in app profiles exercise WLD import, explicit generic controls,
selected viewport/PixelBoxes, ticks, run/pause, save/reopen, reset and close.
Source adapters exclude OS file-chooser latency. Framework events do not prove
OS input-to-presentation latency. Report validity alone does not establish
calibrated refresh performance, target-device fluency or stable memory.

Browser inputs must use explicit loopback fixture URLs through
`COMPUTERRARIA_WLD_URL`; it becomes a Blob, not a Dart
world buffers. Do not expose fixture servers publicly or include world files in
the repository or report artifacts. The dedicated Linux CI job may download
only this pinned public upstream WLD and verify its exact hash; personal
world/player inputs remain excluded from public CI. Serialize full-world runs with other large compiles/tests to keep
memory results interpretable. Merely adding this target is not a completed
profile run or a claim of smooth performance on mobile devices.

### Host display cadence and bounded diagnostics

The browser runtime batches the existing physical clock command (128 pulses by
default) and the monochrome monitor's pixel query into one serialized worker RPC.
The worker still invokes the retained wiring engine twice, in that order; no
instruction execution moves to the host. Input sensor commands complete before
this batch. Worker cooperation remains at 128 core steps or 16 ms, and the UI's
16.667 ms publication gate remains. The Web backend explicitly guarantees each
batch response arrives from a dedicated worker message event, so it can begin
one next batch without adding a host Timer. Native and unknown/test backends
retain the 1 ms timer yield. A generation token and single active pump prevent
pause/restart, cancellation, or closure from duplicating a continuation; a busy
serialized owner is awaited before accepting the next batch. Each runtime batch reads
the monochrome monitor; manual stepping, verification, explicit refresh, mode
changes, UI pause after drain, and export retain a fresh read of that monitor.

The response retains the successfully committed clock result if its subsequent
pixel read fails. The session then preserves the accepted pulse count and dirty
state, pauses with the error, and never retries that clock. Returned pixel
chunks still copy borrowed WASM memory before acknowledgement. A single owned
chunk can be transferred directly; only multi-chunk results need concatenation.

Image presentation permits one decode in flight. A completed image for the same
monitor is published even when a newer frame is pending, then only the newest
pending frame is decoded. Monitor/dimension changes and session/reset identity
changes reject obsolete callbacks; disposal never resurrects an image.

Performance details are collapsed by default. Pause and expand them to inspect
bounded recent-128-call host duration samples in milliseconds. Machine profile
observations store microseconds, counts, host identity, and overlapping-stage
metadata. Existing per-command worker core/yield/copy/wall stages remain directly
comparable. The combined request has separate `runtime.batch` and RPC stages;
its wall time must not be interpreted as the former clock-only RPC. Runtime loop
wall and actual fallback timer wait are also measured. The Web continuation
gap has its own `runtime.ownerContinuationGap` stage; an absent timer-wait row
means that path did not schedule per-batch host timers. Stopwatch/callback timings are
not Flutter FrameTiming, display FPS, or presentation/input latency.

### Actual pure-WLD browser baseline (2026-10-09)

The exact a5612b4 CI Web build loaded the 405,983,441-byte public WLD in three
fresh cloud Chrome processes. Source hashing through final monochrome display
initialization took 41.050 / 41.944 / 38.646 seconds. This boundary excludes the
file chooser and is not the first presented frame. Hashing alone took
17.221 / 16.547 / 15.671 seconds. OS caches were not flushed.

The owned Chrome process-tree PSS peaks were 680.816 / 689.459 / 690.667 MiB,
with a maximum 268.285 MiB increase from the corresponding baseline. Renderer
RSS peaks were 441.633 / 450.773 / 448.328 MiB; these overlap the tree metrics.
WASM capacity was 159.313 MiB and engine allocation peak was 138.950 MiB.
After close, active engine bytes and scratch storage reached zero, but the old
worker retained its WASM high-water capacity. One separate reset after Pong
crashed Chrome with Error 9; OOM has not been established as the cause.
See the machine-readable [baseline](evidence/browser-pure-wld-baseline-2026-10-09.json).

Fresh ON before loading Pong produced a paused 25,728-pulse screenshot whose
3,072 binary pixels all match an independent physical native replay (22 lit
pixels). OFF-to-ON switching after execution preserves existing pixels and
does not reconstruct earlier display history. For a fresh ON result, reset to
the original WLD, enable optimization, then load the program. The approximately
21.9 display reads per second observed during that session are not raster FPS.

On headless Linux, the platform may report a raw display refresh rate of zero.
The profile collector retains its explicit nominal 60 Hz fallback for scheduling;
the report validator marks refresh calibration and derived frame-budget
acceptance unavailable. Correctness, physical input traces and memory checks
remain required. Unknown calibration must not be presented as smoothness on a
60 Hz device.
