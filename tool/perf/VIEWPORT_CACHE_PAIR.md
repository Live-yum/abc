# One bounded viewport-cache diagnostic

This branch is an experiment harness, not a product acceptance or a release.
No performance invocation is authorized by this file. The parent reviews and
publishes the finalized pair before the one exact-branch workflow may run.

## Immutable identities and publication contract

Publish exactly two ordered commits in one push to
`codex/viewport-cache-pair-b3f2`:

1. **A** has parent `b3f2b22312d1369681fc9110a6957e57999a4e94` and the common
   diagnostic changes. All original 873 product files retain their exact SHA-256
   and Git executable mode. New candidate tests are common, but the private C
   pressure test compiles only against B.
2. **B** has parent A and exactly the reviewed six C source changes plus the
   four publisher-owned source/patch/build-provenance changes. Their SHA-256 and
   modes must match `viewport_cache_pair_plan.json`. No source overlay is used
   for either Native measurement arm.

The plan is identical in both commits. Its publication identity must be complete
before either commit is created. Native A and B are separate clean worktrees at
those actual commit IDs. Every source is inventoried before work. Each runtime
reports the correct arm's actual SHA and `workingTreeDirty=false`; prebuilt
binary hashes, effective C compiler flags, source hashes and the clean checkout
are rechecked after every process. The common original runner's strict result,
screenshot, input identity, lifecycle and clean-source validation is preserved.
Each arm also uploads a separate small code-only artifact with `terraforge`,
`libapp.so`, `libabc_engine.so` and its build manifest, without assets or fonts.

WASM verification uses two additional worktrees at the same A/B commits. Those
worktrees explicitly become dirty only when freshly generated engine artifacts
and runtime provenance replace the old shipped files. The workflow builds with
the pinned official Emscripten 5.0.7, records actual runtime metadata, and runs the
full authorized-source verifier without bypassing it. The actual-WASM contract
receives those freshly built paths explicitly. Before/after tracked source
inventories, deltas, generated JS/WASM and runtime provenance are retained.
Native worktrees are not modified by this step. Existing shipped B assets remain
old baseline artifacts until separately rebuilt and published by the parent;
this diagnostic is not a claim that its temporary B build is already shipping.

## Predeclared workflow and stopping condition

One ubuntu-24.04 job, contents-read only, persist-credentials false, exact branch
push guard, run attempt 1 only, no matrix, dispatch, release or deployment.
Correctness gates precede performance:

- Existing external-clock backend unit contracts and common diagnostic analysis
- Two actual Release Native engines, full 764-case synthetic differential
  semantics, private B allocation/pressure contract
- Actual Dart Native warm selected-ROI source guard: size, mtime, filesystem type,
  injected read failure and short read; original error, recovery, released host
  READ windows and source file-handle cleanup
- Actual A/B WASM synthetic byte/counter parity over shapes, layers and raw-area
  admission boundaries; live lamps, gates, wires, PixelBoxes, junctions, timers,
  source probes, byte-exact export, reopen/continuation and source-read failures
- Supplementary existing fake-ABI Web host probe, separately labeled as such

Only after those gates pass, compile two Native profile bundles with ordinary
`ABC_PERF_COUNTERS=OFF`. Execute A, B, B, A in that order as four fresh application
processes, from the same runner/session. Reuse the verified bundle for each arm;
never rebuild between paired processes. Each process retains the original
bounded diagnostic timeout. Failure stops the sequence and preserves partial
results. Never replace failed/outlying processes, trim values, retry a window,
run extra experiments after an inconclusive result, or auto-promote the candidate.

The unchanged workload uses the pinned public 405,983,441-byte WLD and 2,288-byte
Pong program. Preparation, OFF compatibility, ON 15-second dynamic observation,
100ms production scheduling with ticks6, explicit external clock128 before each
original tick, maximum 250ms visible-image probe cadence, save, reset, reopen,
continuation, cancellation and close boundaries remain the validated harness.
All input and save files stay outside artifact allowlists.

## Measurements and interpretation

Both arms have identical added test-only diagnostics. Before the initial fixed
trace in each mode, a query to a different ROI displaces the cache, then three
identical selected-ROI queries record one cache-cold and two cache-warm timings
and record hashes. These labels describe only the optional tile cache; the OS
file cache and process startup are uncontrolled. No pulses are introduced.

Retain every process, raw event, query sample, operation sample, visible-image
probe, screenshot, source hash, command error, maximum and tail. During the
15-second ON window, link each actual compound batch to its subsequent production
viewport read. Compare native record/RGBA hashes and native work counters at
identical physical-pulse/mechanical-tick ordinals. Retain unmatched ordinals when
clock cadence yields different total batch counts. Within-process save/reopen
continuation is always checked; cross-process save bytes are compared only when
the completed batch count and sampled pre-save state are equal. The original
RAM check is 8,704 passive lamps: 272 words / 1,088 bytes, not all 368 KiB RAM.
Filesystem type replacement is an actual file-to-directory change; its size and
mtime may change too, so this does not isolate the type predicate independently.

Native active and peak bytes come from the existing public engine result stats.
RSS comes from operation endpoints plus the process-lifetime high-water value.
These scopes differ and must never be added. There is no steady-window RSS peak,
memory plateau, robust device FPS, physical display presentation, NPC simulation
or observer-free claim. All original visible observers remain enabled. The two
A/B pair ratios are descriptive with only two independent processes per arm;
summary generation does not decide product acceptance or schedule more runs.

## Local verification boundary

No local Flutter/Dart SDK or Emscripten was requested or downloaded. Local checks
are Python/embedded-Python and shell syntax, Node syntax, YAML structure, exact
source manifests and offline evidence-validator unit cases. Actual Dart, Native,
WASM and profile invocations are CI-only and must not be described as passed until
the official run produces and independently verifies that evidence.
