# Full-world physical computer workflow

The World Circuit panel accepts the complete original Computerraria WLD and its
paired TWLD through ranged sources. The desktop/mobile picker passes a path;
the browser picker passes the original selected File/Blob. Neither path loads the 405,983,441-byte
world into a Dart `Uint8List`. The TWLD remains compressed until the owning
native/Web engine incrementally parses it. No tModLoader, WireHead process,
Terraria executable, or host RISC-V emulator is required.

## Open and run

1. In World Circuit, choose the full `.wld`, then its matching `.twld`, and select
   **导入完整电路**. Choosing a different WLD clears the previous pairing.
2. The app verifies the original WLD/TWLD hash pair, or an exact pair previously
   exported by this app and recorded locally, plus actual memory/ready-lamp
   anchors, both display rectangles, and the decoded TWLD compatibility flag.
   Filenames do not select a profile.
3. Choose **载入 Pong 程序**, or load an RV32I flat `.bin` / whitespace-separated
   hexadecimal-byte `.txt`. The published original ROM is empty. Loading only
   the world cannot boot a program.
4. Choose **运行物理时钟**. Each accepted batch contains 128 sequential yellow-wire
   pulses at `(3194,153)`, with switch interaction disabled. The UI yields between
   batches and keeps at most one operation in flight. A pulse is not necessarily
   a retired instruction. Ordinary device ticks are a separate mode.
5. Pause stops new batches; an accepted batch completes. Single-step sends one
   physical pulse. Reset reopens the original source and clears the loaded ROM
   program. Close releases the circuit handle and retained images.

Fixed controls are enabled for the pinned original pair or an exact app-issued
pair present in the bounded local provenance registry. Unknown, mismatched,
evicted or unregistered pairs remain generic circuit sessions. A WLD without
TWLD uses original circuit rules and does not claim a compatible monitor.

A successful paired export records both engine-computed output hashes, the
verified base profile, the known ROM image/name and program pulse count. Only
after **both** files are saved is the entry committed through the existing local
vault and read back. Reimport verifies actual source hashes and restores actual
saved ROM/CPU/pixels without resetting; changing the program later uses the
retained previous ROM image to clear its full tail. Partial saves remain dirty
and are not registered. Native destinations cannot alias either in-use original,
including symlink/hard-link aliases. Engine output leases are released on every
export path.

The local registry retains the eight most recently registered exact pairs in at
most 9 MiB of JSON; normally one snapshot is retained, temporarily at most two
through an interrupted update. Malformed latest metadata fails closed. The
registry stores no full worlds, source paths, credentials or cloud data. It is
local to this installation. Untracked low-level mutation invalidates the known
ROM baseline; reset the imported source before replacement or a registered
resumable export. Ordinary tracked program, clock, input and optimization flows
retain provenance. Reset restores the imported snapshot, which may already
contain a program when it is an app-issued export.

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

The switch defaults **off** for each newly opened world. Both modes use the
existing compiled connectivity, grouped networks and lazy circuit state. Off
retains the previous per-trip device-mask clearing; on uses generation-stamped
device signal deduplication to avoid clearing unrelated devices on every pulse.
It is a bounded optimization inspired by the same class of wiring-accelerator
techniques, not a claim that the app embeds the full WireHead accelerator or
that off reimplements vanilla Terraria breadth-first traversal.

Changing modes pauses the runner, drains an accepted atomic batch, and changes
only transient deduplication metadata. ROM, RAM, physical input latches, pixels
and RNG state stay intact. The loaded program remains available for resume.
The exact same 128-pulse batches are used in both modes. The required TWLD
compatibility semantics describe the world's devices and are independent of
this performance switch.

## Actual displays and timing

- Monochrome: `(6485,800)`, 64 × 48, actual type-445 frame X 0/18.
- Color: `(7371,1002)`, 176 × 96, actual compatible pixel state
  `frameX / 18 + 4 * (frameY / 18)`, all 16 states retained.
- Queries read the compiler's retained pixel cells, without rescanning the
  entire WLD. The app rejects missing, duplicate, wrong-type or invalid-frame
  pixels. It never draws an expected test image or a host-side framebuffer.
- Frames are converted to nearest-neighbor RGBA images. Image decoding permits
  one pending request; replaced/disposed images cannot reappear after close.
- Color cells use the rounded whole-sprite mean RGB for each upstream state.
  This is an explicitly approximate flat appearance, not Terraria's textured
  tile rendering or an additive RGB interpretation of wire colors. Source
  palette measurements are recorded under `vendor/computerraria`.
- Physical clock Hz and display polling Hz are measured separately from Flutter
  frame timings. Polling is requested at most about 60 times/second and slows
  with execution. No fixed 5 kHz or target-device frame-rate guarantee is made.

## Source identity and bundled program

Original source: [Computerraria commit 0379d5b](https://github.com/misprit7/computerraria/tree/0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8).
The WLD is format 279, 15,200 × 7,200 tiles, SHA-256
`55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.
Its compressed TWLD is 427,712 bytes and contains 16,896 custom color pixels;
its large expanded arrays must not be inflated on Flutter's UI isolate.
World/companion files are not distributed in this repository.

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

## Verification and profiling

Focused tests cover content/profile gating, large-file descriptor selection,
ROM banks/endian/tail clearing, program limits, all 16 color states, cancelled
import and reload, cancelled partial program loading, physical clock batching,
pause/close ordering, and actual image widgets. Fake-backend tests validate host
contracts, not physical CPU execution.

`integration_test/computer_world_profile_test.dart` is a separate opt-in actual
world target for the single pinned public upstream pair. It pointer-taps the production panel, imports the real pair,
loads bundled Pong into physical lamps, observes changing actual monitor
frames, records physical clock rate independently of UI/raster timings,
exports the real pair into owned temporary files, recreates the Workspace with
its actual isolated local vault, reimports without reset, compares saved
pixels/RAM/program state, then pauses/steps/resets/closes and measures memory. Each mode first executes
the same 5,120 physical pulses with input at fixed clock indices, comparing
actual monochrome/color frame hashes and physical RAM lamp signatures. An idle
mode roundtrip must preserve both. Framework key-down/up events for all four directions and a pointer hold on a
direction button measure input-to-physical-sensor acknowledgement and verify
release. These timings do not claim OS-device or raster presentation latency.
A separate 30–60 second steady run records throughput; its different-time endpoints are not compared for state equality. It rejects debug
timing as performance evidence. Source descriptors replace OS file chooser
interaction; chooser latency is excluded. Example on a configured Linux host:

```sh
COMPUTERRARIA_WLD=/absolute/path/computerraria.wld \
COMPUTERRARIA_TWLD=/absolute/path/computerraria.twld \
TERRAFORGE_ENGINE_LIBRARY=/absolute/path/libabc_engine.so \
TERRA_UI_PROFILE_OUTPUT=build/perf/computer-profile.json \
flutter drive --profile -d linux \
  --driver test_driver/ui_profile_driver.dart \
  --target integration_test/computer_world_profile_test.dart \
  --dart-define=COMPUTERRARIA_PROFILE_CYCLES=2 \
  --dart-define=COMPUTERRARIA_PROFILE_SECONDS=30
```

Browser inputs must use explicit loopback fixture URLs through
`COMPUTERRARIA_WLD_URL` / `COMPUTERRARIA_TWLD_URL`; they become Blobs, not Dart
world buffers. Do not expose fixture servers publicly or include world files in
the repository or report artifacts. The dedicated Linux CI job may download
only this pinned public upstream pair and verify its exact hashes; personal
world/player inputs remain excluded from public CI. Serialize full-world runs with other large compiles/tests to keep
memory results interpretable. Merely adding this target is not a completed
profile run or a claim of smooth performance on mobile devices.
