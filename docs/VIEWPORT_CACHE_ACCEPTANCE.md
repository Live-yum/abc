# Bounded viewport source cache

This change reuses decoded source cells for repeated queries of the same viewport. Current circuit state is still applied when each result is produced. The optional cache holds at most 4,096 cells and yields to required circuit allocations; allocation refusal preserves the uncached path. A warm streamed query still performs its source-validation read. Read, short-read, range and cancellation failures remain observable.

The application controls, input semantics and clock are unchanged. This is a viewport-query optimization, not a change to the supported WLD devices or game simulation.

## Public diagnostic evidence

The fixed [GitHub Actions run 38119737165](https://github.com/Live-yum/abc/actions/runs/38119737165) used one Ubuntu 24.04 runner with software llvmpipe rendering. It compared A `abce063fad8c29a41a6a39b4434dcab9b02ce8bb` with candidate B `dc0cbba0d5b131f9d129bd8924f999a99e59a831` in exactly one predeclared ABBA sequence of four fresh application processes. A and B shared the same diagnostic source; B changed six runtime source files and their recorded provenance. Native profile worktrees stayed clean. Separate A/B WASM worktrees generated and verified their actual tested artifacts.

The input was the pinned public Computerraria world with a temporary, test-derived program state and explicit external test clock. It does not demonstrate autonomous NPC or pressure-plate activation in the original world. All four processes and all raw values were retained; no sample was deleted, repeated or replaced.

The measured command was the viewport query following each dynamic batch:

| Process | Arm | Queries | Median (ms) | p95 (ms) | Maximum (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | A | 136 | 42.5025 | 58.551 | 61.870 |
| 2 | B | 150 | 1.8645 | 13.607 | 15.387 |
| 3 | B | 150 | 1.8255 | 13.311 | 14.902 |
| 4 | A | 143 | 38.3610 | 52.119 | 62.202 |

The predeclared pairs 1→2 and 4→3 reduced this command's median by 95.61% and 95.24%. Native active allocations were 196,752 bytes (about 0.188 MiB) higher in B during these queries. This is an engine allocation measurement, not process RSS or a memory-stability result.

Different timed batch counts and unmatched pulse/tick ordinals remain in the report. Exact state equality is checked only at common ordinals; the passive RAM sample covers 272 words / 1,088 bytes, not the complete RAM. Both modes retain changed-save, reopen and continuation checks. The visible-frame observer remained enabled at its existing minimum 250 ms interval.

## Correctness and build identity

The same run passed 764 Native differential cases, five actual Dart source-guard tests in each arm, eight external-clock/lifecycle tests, the candidate allocation-pressure contract, and 180 actual rebuilt-WASM records. Both generated engines passed the complete 96-file TerraWasm, 40-module viewer and runtime-provenance verifier. The supplementary fake-host probe is distinct from those actual-WASM checks.

The adopted B world WASM is 416,015 bytes with SHA-256 `6c6590fece42d857e1d37c8b8a1f324a0bc58d1e54dfee6bc4450d140eb50bda`. Its source manifest is `8fe9e685b4e49e344ffcb12b3483bff7570db313511647f082bd471c74fb5d5a`. The original reports, generated engines and formatting copies are preserved in artifact `11695591830`, ZIP SHA-256 `8e94f133d7687b85a6a2141ad1fde3f7ef3614f5a29a8db075f51605d409b82c`.

## Limits

This is two samples per arm from one runner and one workload. The observed raster p95 values were A 45.435/39.632 ms and B 40.339/41.606 ms; they do not establish a consistent raster speedup or target-device fluency. Display calibration remained unavailable; the nominal 16.667 ms reference is not a measured display refresh budget. Every recorded frame in all four timed windows exceeded this nominal fallback (385/385, 426/426, 423/423 and 446/446); the actual display refresh rate remained unknown. Selected-ROI cold probes displace the tile cache and do not control OS page caches or cold process startup.

The original sequential RSS fields are also retained: in process 2, lifetime maxRss was 622,592 bytes below cleanup currentRss; in process 4 it was 679,936 bytes below. These are non-atomic observations without individual timestamps. Their cause is unconfirmed; neither value is corrected or removed, and the reported max is not treated as a strict upper bound.

No sustained RSS plateau, steady-window OS memory peak, global FPS improvement or hardware-device performance acceptance follows from this diagnostic. Earlier public performance comparison failures and memory-stability gaps remain open. Normal exact-head CI still has to validate the integrated source, tests and bundled runtime.
