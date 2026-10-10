# Complete-world circuit execution

The additional source API accepts an immutable native file or browser File/Blob,
using circuit ABI 2. The small byte-array API remains
available. Native reads and browser Blob slices are at most 1 MiB. Neither API
materializes the complete large WLD in Dart/JavaScript. Native scratch and saved
outputs use files; large browser sources require worker-owned OPFS storage.
Small browser byte inputs may use a shared bounded 64 MiB paged fallback.

The native session budget is 192 MiB, reported separately from retained/peak
native bytes, Dart/JS buffers, Wasm heap and process RSS. The Web heap ceiling is
256 MiB. These are allocation limits, not a claim that the whole application uses
only that much memory. The 406 MB public world is streamed without companion files.

`WorldCircuitSourceBackend` adds ranged open, progress, cancellation and explicit
saved-output release. Completed streamed saves return source descriptors rather
than full byte arrays. Their files survive circuit close/reset until released.
Original picker files are never deleted or overwritten by output cleanup.
Input WLD identities and completed output identities are computed from the
actual ranged bytes; a caller-supplied source digest is never trusted. Native
save completion moves its temporary files into independent leases instead of
duplicating a whole-world buffer or temporary file.

## Two simulation settings

The “电路优化” switch defaults OFF. OFF retains per-TripWire device-mask clearing
and game PixelBox crossings. ON adds generation-stamped device deduplication
and the referenced WireHead ordinary-PixelBox different-color group-pair parity
within each gate wave. Existing compiled connectivity, gate scheduling and lazy
lamp representation remain shared. Future pixel behavior can differ; OFF is
not replaced with an artificially slower backend.

Command `TCW_OPTIMIZATION=10` accepts mask 0/1 only while idle. A topology whose
same-color PixelBox axes would require merging distinct networks rejects ON.
The application pauses and drains accepted work first; switching does not alter
ROM, RAM, inputs or existing pixels. Non-save READY bit 1 reports ON, bit 2
reports topology eligibility, and bit 3 reports the selected WireHead-style
pixel policy. Bit 0 remains zero. Bit 3 indicates policy, not the presence of a
screen. SAVE reserved remains zero. The host requires
`circuitWorldWireHeadPixels: 1` before enabling the new policy.

## Actual displays and physical I/O

`TCW_PIXELS=9` reads a rectangle of at most 65,536 cells from the retained physical
pixel state, without rescanning world columns. It returns sparse x-then-y records
in the existing 16-byte coordinate/type/flags/frame format; non-pixel cells are
absent. Existing `TCW_VIEWPORT` behavior is unchanged. Circuit logic and program
stores, never a host framebuffer emulator, determine every returned state.

Production uses one generic tick runner and explicit device/line-pulse
controls. It does not select CPU layouts or inject programs from source hashes.
Pixel regions are user-selected bounded rectangles, with transparent gaps.
Timers require explicit activation; automatic NPC motion is not simulated.

Computerraria ROM maps and clock controls exist only in explicit test harnesses,
which exercise generic physical lamp and wire operations. They never provide
runtime pixels or hidden application behavior. See [fixture scope](COMPUTERRARIA.md).

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
image is `test/fixtures/computerraria/pong.bin` with its adjacent MIT license/provenance.

```sh
ABC_COMPUTERRARIA_SAVE=1 \
  dart native/computerraria_acceptance.dart /path/libabc_engine.so \
  /path/computerraria.wld \
  - test/fixtures/computerraria/pong.bin /path/report-standard.json
ABC_COMPUTERRARIA_OPTIMIZED=1 ABC_COMPUTERRARIA_SAVE=1 \
  dart native/computerraria_acceptance.dart /path/libabc_engine.so \
  /path/computerraria.wld \
  - test/fixtures/computerraria/pong.bin /path/report-optimized.json
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
  /path/computerraria.wld 50 /path/soak.jsonl /path/verified-wld-acceptance.json
```

Rebuild Web artifacts with `tool/build_web_engine.sh`, stage its four engine
files and `manifest.json`, then run `node tool/record_web_engine.mjs` to capture
capabilities from the actual instantiated artifact. The explicit reviewed patch,
base/current hashes and diff are recorded under `native/patches/`; source and
artifact verification includes that local-patch layer.

## Streaming digest host

Native and Web hosts use the existing C incremental SHA-256 implementation when
all four lifecycle functions are available. The Web path reuses one 1 MiB input
allocation and preserves bounded reads, yielding, cancellation and full-source
verification. Older engines with none of these functions retain the original
host fallback; a partial API is rejected. Outputs are published only after a
complete verified digest, and hash contexts are released on success and error.
An isolated Node measurement is not a browser end-to-end loading result.

The identified local host-hashing build passed one full original-WLD run per
backend and mode. Native OFF/ON imports measured 12.695 / 12.983 seconds,
versus the earlier 16.645 / 15.653 seconds; Node WASM measured 17.907 / 17.449
seconds, versus 22.718 / 22.577 seconds. All four old/new correctness
projections, same-mode cross-backend display/save state, and cross-mode physical
CPU/RAM/input projections match exactly. Full save/reopen passed and owners
returned to zero. These are single local observations, not statistical speedup
claims or browser loading measurements. Whole-process peaks include save and
reopen, so they must not be compared with the older Native report's pre-save
peak. See the [artifact-bound evidence](evidence/host-wld-regression-2026-10-09.json).
