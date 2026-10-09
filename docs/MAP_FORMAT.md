# Binary MAP support and verification

`.map` is a Terraria exploration save. It is not the PNG world preview and does
not contain WLD circuit, chest, entity or terrain records. The MAP panel shows
exploration light as a labelled grayscale raster; it makes no claim of game
palette fidelity. Circuit benchmarks belong to the WLD/TCW suites.

## Verified protocol sources

- Legacy Deflate/RLE layout: [Live-yum/TerraR,
  da18c18f29101af13a6b88ab9f9bfc5aea3fb8a4,
  crates/terrar-mapfile/src/lib.rs](https://github.com/Live-yum/TerraR/blob/da18c18f29101af13a6b88ab9f9bfc5aea3fb8a4/crates/terrar-mapfile/src/lib.rs),
  blob `e25dc0152677a3898ed87a6eb7241886803feea4`; public model fields are in
  `crates/terrar-model/src/mapfile.rs`, blob
  `fbc8c63095df0421a21281a5602b3bbf5c85249f` at the same commit.
- Chunked layout: vendored `native/vendor/TerraWasm/src/terra_map.c`,
  `write_map_header`, `write_map_chunk`, `fill_chunk_strip_run`; provenance is
  pinned in `native/vendor/TerraWasm/SOURCE_MANIFEST.json` and
  `THIRD_PARTY_NOTICES.md`. The writer emits raw version 33083 (`315 | 0x8000`),
  a `relogic`/file-type-1 header, then row-major 64×64 chunks. Each chunk is a
  little-endian length followed by zlib-compressed 4096 little-endian uint32
  palette-index/light/extra values.
- The independent Rust reader explicitly rejects this chunked flag. Therefore
  reusing its legacy decoder alone does not establish chunked MAP support.

`lib/domain/terraria_map.dart` is an original Dart implementation of these
verified layouts. No upstream Rust source or repository fixture is bundled.

## Supported operations and boundaries

The codec fully decodes modern legacy MAP versions 135–319 and chunked version
315. It validates signature, dimensions, option tables, chunk lengths/checksums,
decoded cell counts and RLE row boundaries. Unsupported record extensions and
other versions are rejected. It never treats a parsed header as a loaded map.

Input is limited to 128 MiB and 20,160,000 cells (the standard large world).
Region reads and atomic light/paint edits are limited to 262,144 cells per call.
Edits preserve palette indices, legacy tile kinds, metadata and extra flags.
Undo/redo history is bounded to 32 operations and 8 MiB of typed records, and
the sparse changed-cell set is limited to 1,048,576 cells. Grids are typed
arrays, not one Dart object per tile. Legacy encoding uses a contiguous output
buffer instead of allocating an object for each emitted byte.

Unchanged export is byte-identical to the input. Changed chunked export copies
untouched compressed chunks, recompresses only changed chunks, and preserves
padding cells outside world dimensions. Legacy export semantically reencodes
the full Deflate/RLE stream. Every application export fully reopens and compares
all packed cells, legacy kinds and header bytes inside the owner before it is
returned for saving. This validation can take as long as an additional open.

Closing releases owned buffers and history. On application paths, it also
terminates the owner isolate/worker. This does not promise instantaneous OS RSS
reclamation; the benchmark records resident memory separately.

## Owner boundary

`MapBackend` owns one document in a real Dart isolate on native platforms and a
dedicated Web Worker on Web. Open returns `MapSessionInfo` only. Full grids,
compressed source, history, edit, undo/redo, encoding and verification stay in
the owner. The UI receives bounded RGBA previews and explicit exported binary
files. It never runs `compute` as a Web isolation substitute.

Open snapshots caller bytes before asynchronous startup. A failed decode or
expected-world identity check leaves the current owner document intact. Tokens
reject commands for a superseded document. Close/dispose reject pending calls,
terminate the owner and discard stale replies. Timeouts and worker failure are
reported rather than silently falling back to the main thread. The panel asks
before replacing or closing a map with unexported changes.

The core's `render_lit_map` / `mark_tiles_and_chests_map` and `terra_op_get_map`
produce actual binary MAP data. `WorldMapBackend` exposes these operations on
the existing serialized C/WASM owner. Generated MAPs are fully explored output
from a WLD, not evidence of a user's original exploration progress. Generation
tests verify the WLD remains byte-identical. The output filename should still
be selected for the desired game's player/world identity before installing it.

## Fixtures and measured evidence

`tool/perf/map_fixture.dart` constructs repository-authored legacy and chunked
binary fixtures, including row RLE, all legacy kinds, variable light and
nonzero partial-chunk padding. No personal map is included.

Local verification also generated MAPs from two authorized real WLD inputs:
4200×1200 (2,171,562 MAP bytes) and 8400×2400 (8,881,710 MAP bytes). These files
and private reports remain under ignored `qa-evidence/`. They are labelled
generated, and are not uploaded with source or CI artifacts.

The reference repository's `maps/sample.map` is a 131-byte Git LFS pointer for
a 716,329-byte object. Both UTF-8 and base64 connector reads return the pointer;
the existing Git LFS flow has no credentials for that object. It is explicitly
unmaterialized, not counted as a real exploration-map test. No personal MAP was
supplied for independent compatibility validation.

## Reproduce

Build the original worker with the project's pinned Dart SDK before Flutter
Web builds:

```sh
bash tool/build_map_worker.sh
flutter test test/terraria_map_test.dart test/map_backend_test.dart test/terraria_map_panel_test.dart
TERRAFORGE_ENGINE_LIBRARY=/path/libabc_engine.so flutter test test/native_binary_map_test.dart
node tool/test_web_binary_map.mjs
TERRA_MAP_FIXTURE=/local/generated.map node tool/test_map_worker.cjs
```

Core microbenchmarks (`abc.performance.v1`) report all samples, first-use and
repeated-call median/p95/max, throughput, source preservation, owned buffer
counts and memory scopes:

```sh
dart compile exe -DABC_MAP_BUILD_MODE=aot tool/perf/map_actions.dart -o /tmp/map-perf
/tmp/map-perf --input /local/generated.map --provenance engine-generated-from-authorized-world --iterations 15 --output /local/map-aot.json
dart compile js -O2 tool/perf/map_actions_web.dart -o /tmp/map-perf.js
node tool/perf/run_map_web.cjs /tmp/map-perf.js /local/map-js.json /local/generated.map engine-generated-from-authorized-world 15
python tool/perf/generate_native_map.py --library /path/libabc_engine.so --input /local/world.wld --output /local/generated.map --report /local/map-generation.json --iterations 5
python tool/perf/prepare_map_browser.py
# Open the prepared interactive page through an authorized browser workflow.
```

The interactive browser harness is prepared for an authorized browser workflow and records
requestAnimationFrame gaps while opening/rendering/editing/undoing/redoing,
verifying exports and reopening. It also uploads real MAP-derived RGBA to a
canvas. A browser result exists only after Run completes and the user exports its report.
No browser result is implied by preparing the page. The Node worker test covers source ownership, failed replacement,
identity mismatch, stale tokens, cancellation and restart. These complement
the separate Flutter profile interaction harness; they are not substitutes for
Android/iOS/macOS device and full Flutter Web frame measurements.

`status: passed` establishes functional checks. Performance thresholds are not
invented: reports explicitly set `performanceBudgetsEvaluated: false`. OS
caches are not flushed. JavaScript timings below clock resolution may appear
as zero. Browser `performance.memory` covers the main thread, not worker heap
or process RSS. Never interpret a stable sampled heap alone as proof that all
memory is reclaimed.
