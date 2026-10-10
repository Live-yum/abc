# Thumbnail correctness oracle: static preparation

Status: prepared and statically reviewed; **not compiled or executed**. No local Flutter/Dart/SDK command, network access, build, product edit, Git mutation, or upload was performed for this work. Execution and compiler validation remain for official GitHub CI.

## Integration contract

`oracle.dart.template` imports pure Dart libraries plus the baseline's existing `archive` and `crypto` dependencies. Replace exactly `__BASELINE_MAP_URI__`, `__CANDIDATE_MAP_URI__`, and `__FIXTURE_URI__` with valid, escaped `file:` import URIs. Use the baseline package configuration. The fixture URI must resolve to the baseline `tool/perf/map_fixture.dart`; its repository fixture formula is asserted independently in the oracle. Build and execute the resulting entry point separately with AOT and dart2js. Do not fold its execution into a timed benchmark sample.

The program writes one final stdout JSON object (`schema: map-thumbnail-correctness-v1`), whether successful or failed. A caught failure is rethrown after printing, giving a nonzero process exit. CI must require both a zero exit and JSON `status == passed`, retain each target's JSON independently, and avoid interpreting a partial file or missing JSON as success. Compiler/launcher output should be captured separately from the oracle stdout.

## Finite coverage and expected counts

For each of the two MAP encodings:

- One 256-wide light-state fixture: 54 legacy rows or 6 chunked rows. All light bytes 0–255, empty/nonempty states, paint 0/31, legacy kinds 0–8, and stored option values 0/1/65535 where that encoding has an option field. Legacy kinds without an option field always have option zero.
- One unchanged repository fixture, 130×70, retaining legacy RLE and chunked data coverage.
- Twenty-five listed boundary dimensions, each rendered at twenty listed `maxWidth` values. The custom pattern changes light along both axes and mixes empty/nonempty cells, making horizontal and vertical sampling errors visible.
- Ten explicitly specified sampling cases, one render each, with exact expected dimensions and integer-rational nearest-floor source coordinates. Cases cover integral/fractional scale, ceil output height, the 2048 height threshold, source width above the 2048 output threshold, and the 32768 source coordinate bound.

The light-state and repository fixtures also render after edit, undo, and redo. Every fixture has two additional paired renders around caller mutation of both returned buffers.

Expected totals are asserted by the program:

- 74 decoded fixture pairs.
- 1,488 full raster pair comparisons: 4 × 20 × 4 = 320 for four edited fixtures; 50 × 20 = 1,000 boundary renders; 20 exact-sampling renders; 74 × 2 = 148 buffer-independence renders.
- Every compared raster checks dimensions, byte length, every baseline/candidate RGBA byte, and each implementation's full pixels against fixture-derived grayscale/alpha. Pixel/byte totals are reported, not described as a fixed count in advance.
- 30,720 decoded source-cell checks: 2 implementations × 256 × (54 + 6). Each checks option, light, paint, and nullable legacy kind, independently of either renderer.
- 148 buffer-independence checks, 20 exact-sampling comparisons, and 888 typed exception checks: 74 × 2 implementations × (3 invalid live widths + 3 closed-session widths).
- Full original export preservation, equal edited export, exact undo/redo export restoration, unchanged retained-byte accounting across rendering, and zero retained bytes/closed state after close.

There are no timed samples, stopwatch calls, sleeps, randomness, user files, or local platform assumptions. The matrices are finite: this is not exhaustive over all source dimensions, all valid `maxWidth` values, all stored values/combinations, all possible MAP records, or real game files. The widest/tallest source fixtures contain 32,768 cells; chunk padding increases temporary encoder work, but the oracle does not create a 32,768×32,768 map.

A local Python source/arithmetic inspection verified the three placeholders occur once each, the single print call, pure-Dart import list, matrix sizes, count formulas, permitted fixture dimensions, and rational-versus-double agreement for all coordinates in the ten explicit sampling cases. That inspection predicts 36,098,480 compared RGBA bytes and at most 69,632 pixels in any one raster under the selected IEEE-754 arithmetic. These are preparation calculations, not measured Dart results or runtime pass evidence.

## Review of the previous oracle

Source reviewed: `abc-map-render-candidate-20261009/candidate/tool/render_candidate_equality.dart`, against the verified baseline `abc-publish-20261009-v17-read-close/lib/domain/terraria_map.dart` and its `tool/perf/map_fixture.dart`.

- No impossible dimension/RLE fixture was found by static review. Source dimensions stop at 32,768 and the largest old rectangle is below 20,160,000 cells. The repository fixture's widest RLE run is 32,767, which is accepted (`run > 32767` and `x + run >= width` are rejected). Chunk order, padded 64×64 chunks, chunk zlib wrapping, and legacy raw-deflate extraction match the decoder contract.
- The old light-state fixture encodes paint 31 as extra 62, or extra 126 for legacy kind 8; these do not set the decoder's rejected extra bits. Kind 8 correctly uses encoded kind 3 with extra bit 64. Its option-width bit is used only for legacy kinds 1, 2, and 7.
- Option 65535 is decoder-accepted storage stress, but exceeds the tiny synthetic header's actual palette. Neither oracle should describe such a fixture as a valid in-game palette mapping. Rendering intentionally uses only option-zero emptiness, legacy kind, and light. The new oracle makes this distinction explicit.
- The old `verifyStates` checks light and derives emptiness from the implementation's decoded cells. The new version verifies all four source fields against fixture specifications and derives expected emptiness/light independently. It checks alpha 255 for both implementations on every output pixel.
- The old broad checks compare baseline/candidate output but do not independently establish nearest-floor sampling. The new explicit rational cases establish that independently, while the general comparison sweep preserves the renderer's actual floating-point contract.
- A naive exact-rational dimension oracle can falsely reject the unchanged implementation. A static IEEE-754 arithmetic probe found, for example, `129 / (129 / 63)` can round above 63 so `.ceil()` yields 64. Other selected examples are width 257/513/1025 at `maxWidth` 63; 1023/1025 at 959; and 1025 at 960. These remain in the broad equality sweep, which reproduces the specified double scale/ceil arithmetic. Exact-dimension expectations are restricted to the ten explicit stable cases.
- The old all-valid-width sweep repeats many identical rasters for the 130-wide default fixtures. The bounded matrix removes that sweep and the large benchmark fixture. Performance fixtures belong to the separate timing harness; correctness still samples both source coordinate maxima and width/height thresholds.

## Remaining validation gaps

- AOT and dart2js compilation, dependency resolution, import-URI substitution, and runtime execution have not been verified locally. The template uses the baseline's Dart 3 record syntax and public session API, but only official CI can establish compiler compatibility.
- The archive encoder/decoder and target-specific typed-array/integer behavior have not been exercised. In particular, state bytes, chunk checksums, legacy RLE import, original/edited exports, and actual JSON counts remain unverified runtime expectations.
- Exact rational sample coordinates and dimensions were reviewed against the visible source, with a non-Dart arithmetic check for floating boundary pitfalls. That is static preparation, not a passed Dart oracle result.
- Successful runs on both CI targets would demonstrate equality for this finite matrix only. They would not establish performance, rendering equality for every accepted file/dimension, absence of unrelated decoder bugs, mobile/desktop platform packaging, or permission to release.
