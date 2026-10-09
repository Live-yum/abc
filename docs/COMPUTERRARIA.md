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

## Open and run

1. Choose the full `.wld` and select **导入完整电路**.
2. The app verifies the original WLD hash or an exact locally recorded WLD
   export, plus physical memory/ready-lamp anchors and the native monochrome
   display rectangle. Filenames do not select a profile.
3. Choose **载入 Pong 程序**, or load an RV32I flat `.bin` / whitespace-separated
   hexadecimal-byte `.txt`. The published original ROM is empty. Loading only
   the world cannot boot a program.
4. Enable **电路优化** to display Pong in this WLD, then choose **运行物理时钟**.
   OFF can execute the physical CPU, but its same-TripWire game PixelBox rule
   does not produce the Pong display. Each accepted batch contains 128 sequential
   yellow-wire pulses at `(3194,153)`, with switch interaction disabled. The UI yields between
   batches and keeps at most one operation in flight. A pulse is not necessarily
   a retired instruction. Ordinary device ticks are a separate mode.
5. Pause stops new batches; an accepted batch completes. Single-step sends one
   physical pulse. Reset reopens the original source and clears the loaded ROM
   program. Close releases the circuit handle and retained images.

Fixed controls require the pinned original WLD or an exact locally verified
export. Unknown, evicted or unregistered files remain generic circuit sessions.
A successful export records the engine-computed WLD hash, verified base layout,
known ROM image/name and pulse count only after the file is saved. Reimport
verifies the bytes and resumes saved physical state without resetting.

The version-2 local registry keeps at most eight records and 9 MiB of metadata.
It contains no whole worlds, source paths or credentials. Old paired records
cannot establish a WLD-only resume identity. Untracked low-level mutation
invalidates the known ROM baseline. Partial or cancelled saves remain dirty;
source aliases, including native symlink/hard-link aliases, remain protected.
Every export path releases its temporary output lease.

Loading a new program writes only changed physical ROM lamp bits, including
zeroing an earlier longer program's tail. Physical reset/ready/bus/store-PC
controls set the machine's start point to address zero. This is essential: the
Pong ELF entry is 8, but stack initialization occupies address 0. ELF containers
are explicitly rejected by the app; convert them to a flat image first. Program
images are limited to 768 KiB. Interrupted program loads remain visibly
incomplete and cannot run until the original world is reset/reimported.

Keyboard arrows/WASD and on-screen direction buttons use independently calibrated
physical sensors: UP `(6516,851)` mask 9; DOWN `(6517,866)` mask 5; LEFT
`(6519,858)` mask 10; RIGHT `(6520,857)` mask 5. Repeated pulses before a CPU read
retain the same direction bit; the next read clears it. Held keys therefore send
coalesced actual wire pulses between clock batches. Release stops pulsing, with
no invented release pulse. Blur/pause/close release held UI inputs. No generic
simulated key register is substituted for the physical sensors.

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
the selected rule. Both modes use the same 128-pulse batch size. The app does
not embed the complete WireHead accelerator. Final Native/Node OFF/ON checks
passed for physical CPU execution and ON's actual 3,072-pixel monochrome Pong
display. Current UI acceptance remains pending. Historical companion-format
OFF/ON pixel-equality evidence does not apply to the new rule.

## Actual displays and timing

- Monochrome: `(6485,800)`, 64 × 48, actual type-445 frame X 0/18.
- Queries read the compiler's retained pixel cells, without rescanning the
  entire WLD. The app rejects missing, duplicate, wrong-type or invalid-frame
  pixels. It never draws an expected test image or a host-side framebuffer.
- Frames are converted to nearest-neighbor RGBA images. Image decoding permits
  one pending request; replaced/disposed images cannot reappear after close.
- The unsupported mod-only color screen is absent from the interface. Its
  content cannot be recovered from the WLD, and no replacement pixels are
  synthesized.
- Physical clock Hz and display polling Hz are measured separately from Flutter
  frame timings. Polling is requested at most about 60 times/second and slows
  with execution. No fixed 5 kHz or target-device frame-rate guarantee is made.

## Source identity and bundled program

Original source: [Computerraria commit 0379d5b](https://github.com/misprit7/computerraria/tree/0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8).
The WLD is format 279, 15,200 × 7,200 tiles, SHA-256
`55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.
The original world is fetched only for authorized validation and is not bundled
in the repository or public report artifacts.

`assets/computer/pong.bin` contains the actual upstream Pong program compiled
for RV32I, 2,288 bytes, SHA-256
`d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d`.
The Pong source is unchanged. Two `cfg` attributes exclude host-only SpriteGrid
code from the RISC-V build. MIT © 2023 Xander Naumenko, complete license, source,
patch and build provenance are retained in `vendor/computerraria`.

With official Rust 1.85.1 and its `riscv32i-unknown-none-elf` standard library
already installed, rebuild using:

```sh
sh vendor/computerraria/build-pong.sh
cmp assets/computer/pong.bin vendor/computerraria/pong-build/output/pong.bin
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

`integration_test/computer_world_profile_test.dart` is a separate opt-in actual
world target for the single pinned public upstream WLD. It pointer-taps the production panel, imports the real WLD,
loads bundled Pong into physical lamps, observes changing actual monitor
frames, records physical clock rate independently of UI/raster timings,
exports the real WLD into owned temporary files, recreates the Workspace with
its actual isolated local vault, reimports without reset, compares saved
pixels/RAM/program state, then pauses/steps/resets/closes and measures memory. The
current pure-WLD acceptance must distinguish OFF physical CPU/RAM checks from
ON's changing monochrome Pong display. Historical cross-mode display equality
from the former companion format does not apply. The deterministic workload
uses 5,120 physical pulses with input at fixed clock indices, comparing physical
RAM lamp signatures and mode-appropriate actual display state. An idle
mode roundtrip must preserve the display and RAM. Framework key-down/up events for all four directions and a pointer hold on a
direction button measure input-to-physical-sensor acknowledgement and verify
release. These timings do not claim OS-device or raster presentation latency.
A separate 30–60 second steady run records throughput; its different-time endpoints are not compared for state equality. It rejects debug
timing as performance evidence. Source descriptors replace OS file chooser
interaction; chooser latency is excluded. Example on a configured Linux host:

```sh
COMPUTERRARIA_WLD=/absolute/path/computerraria.wld \
TERRAFORGE_ENGINE_LIBRARY=/absolute/path/libabc_engine.so \
TERRA_UI_PROFILE_OUTPUT=build/perf/computer-profile.json \
flutter drive --profile -d linux \
  --driver test_driver/ui_profile_driver.dart \
  --target integration_test/computer_world_profile_test.dart \
  --dart-define=COMPUTERRARIA_PROFILE_CYCLES=2 \
  --dart-define=COMPUTERRARIA_PROFILE_SECONDS=30
```

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
