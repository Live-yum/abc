# Complete-world circuit execution

The additional source API accepts an immutable native file or browser File/Blob,
plus an optional original `.twld` companion. The old small byte-array API remains
available. Native reads and browser Blob slices are at most 1 MiB. Neither API
materializes the complete large WLD in Dart/JavaScript. Native scratch and saved
outputs use files; large browser sources require worker-owned OPFS storage.
Small browser byte inputs may use a shared bounded 64 MiB paged fallback.

The native session budget is 192 MiB, reported separately from retained/peak
native bytes, Dart/JS buffers, Wasm heap and process RSS. The Web heap ceiling is
256 MiB. These are allocation limits, not a claim that the whole application uses
only that much memory. The 406 MB public world is streamed; its approximately
438 MB expanded TWLD is decoded natively in bounded windows.

`WorldCircuitSourceBackend` adds ranged open, progress, cancellation and explicit
saved-output release. Completed streamed saves return source descriptors rather
than full byte arrays. Their files survive circuit close/reset until released.
Original picker files are never deleted or overwritten by output cleanup.
Input WLD/TWLD identities and completed output identities are computed from the
actual ranged bytes; a caller-supplied source digest is never trusted. Native
save completion moves its temporary files into independent leases instead of
duplicating a whole-world buffer or temporary file.

## Two simulation settings

The “电路优化” switch defaults OFF. OFF preserves the existing per-TripWire
device-mask clearing implementation. ON uses a verified independent generation
counter to deduplicate device hits without clearing unrelated devices on every
gate output. Generation wrap resets the transient stamps. Existing compiled
connectivity, gate waves and lazy lamp representation are shared by both modes;
OFF is not a new wire-by-wire backend, and ON is not the complete WireHead mod.

The source ABI command `TCW_OPTIMIZATION=10` uses `mask=0/1`, no data records and
no flags. The engine accepts it only at an idle boundary. The application pauses
and drains the accepted physical clock batch before switching. ROM, RAM, RNG,
pending input, gate/pixel state and electrical counters do not change.
Non-save READY bit 1 reports this setting.

TWLD compatibility is independent of the speed switch. Native decoding identifies
`WireHead/ColorPixelBox` by its saved module/type name and restores the custom
pixel data; non-save READY bit 0 reports this profile. It supplies the published
world's display topology and gate-wave pairing semantics without installing or
executing tModLoader or WireHead. A WLD without the matching sidecar retains its
original pixel rules in either speed setting.

## Actual displays and physical I/O

`TCW_PIXELS=9` reads a rectangle of at most 65,536 cells from the retained physical
pixel state, without rescanning world columns. It returns sparse x-then-y records
in the existing 16-byte coordinate/type/flags/frame format; non-pixel cells are
absent. Existing `TCW_VIEWPORT` behavior is unchanged. Circuit logic and program
stores, never a host framebuffer emulator, determine every returned state.

Computerraria clock controls pulse the real yellow wire at `(3194,153)`, with
`hitSwitch:false`. A batched trigger waits for each complete activation before
starting the next. One pulse is not necessarily one instruction. Automatic
training-dummy NPC motion is not simulated.

The verified ROM maps and program loader operate on ordinary physical logic
lamps. The application does not decode RISC-V instructions. The standalone
acceptance images and expected RAM words are test fixtures, not runtime output
providers. The matching complete published WLD is initially empty of program
data; the actual upstream Pong image boots at address zero.

## Reproduction and evidence

Run the small ownership/pixel/strategy contract against a freshly built native
library with `ABC_PERF_COUNTERS=ON`:

```sh
python3 native/generate_circuit_pixel_fixture.py /tmp/abc-pixels.wld
dart native/world_circuit_source_smoke.dart /path/libabc_engine.so /tmp/abc-pixels.wld
```

The complete public-world runner requires external input paths and records the
exact binary hashes. It never substitutes a cropped world or software CPU:
The input-probe path may be `-` to use the reviewable 40-byte image in
`native/fixtures/computerraria/programs.json`; the distributed upstream Pong
image is `assets/computer/pong.bin` with its adjacent MIT license/provenance.

```sh
ABC_COMPUTERRARIA_SAVE=1 \
  dart native/computerraria_acceptance.dart /path/libabc_engine.so \
  /path/computerraria.wld /path/computerraria.twld \
  - assets/computer/pong.bin /path/report-standard.json
ABC_COMPUTERRARIA_OPTIMIZED=1 ABC_COMPUTERRARIA_SAVE=1 \
  dart native/computerraria_acceptance.dart /path/libabc_engine.so \
  /path/computerraria.wld /path/computerraria.twld \
  - assets/computer/pong.bin /path/report-optimized.json
```

`test/web/computerraria_file_acceptance.cjs` runs the exact Web Wasm artifact in
Node with File/Blob sources and random-access temporary files. Its options include
`--optimized`, `--pong`, `--input`, and `--save`. This establishes the Web module
and source bridge behavior; it is not real-browser OPFS or Flutter frame-rate
validation. Browser/device profile measurements remain distinct.

`native/computerraria_soak.dart` repeats complete-world import, 48 physical CPU
signatures, actual upstream Pong and close, alternating settings. Each flushed
JSONL row records source identity, complete display digest, tracked native/bridge
allocations, world handles, Linux descriptor count and RSS. It retains only
bounded counters between cycles and performs no forced garbage collection or
allocator trimming. Use a temporary directory with room for the working files:

```sh
TMPDIR=/path/roomy-temporary-directory \
  dart native/computerraria_soak.dart /path/libabc_engine.so \
  /path/computerraria.wld /path/computerraria.twld 50 /path/soak.jsonl
```

Rebuild Web artifacts with `tool/build_web_engine.sh`, stage its four engine
files and `manifest.json`, then run `node tool/record_web_engine.mjs` to capture
capabilities from the actual instantiated artifact. The explicit reviewed patch,
base/current hashes and diff are recorded under `native/patches/`; source and
artifact verification includes that local-patch layer.
