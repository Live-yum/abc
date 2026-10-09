# Reproducible core and action performance

These workloads execute the actual native library, WASM bridge, Workspace
transactions, retained source circuit rules and native vault. Every timed
operation is awaited. Independent readback, byte preservation, deterministic
timer outcomes, explicit failure recovery and owner closure are checked. They
load their source fixtures before timing, so OS picker interaction and original
source disk reads are excluded. Native vault disk I/O is timed separately. They
are not Flutter frame-rate measurements. The separate profile-app suite owns
UI/raster frame timing, responsiveness and gestures.

`report.schema.json` defines `abc.performance.v1`. `action_catalog.json` lists
explicit action/parameter variants. `action_gaps.json` inventories the actual
Workspace and CircuitRulesWorkspace dispatchers, including early lifecycle
actions. Regenerate it with `python3 tool/perf/update_action_gaps.py`. A declared
workload counts as measured only when its operation ID appears in a passed
runtime report; a core API timing never automatically covers a UI action.

## Public CI workload

Public runs use original synthetic saves, a generated v326 player, generated
resource/achievement fixtures, and the attributed circuit source demos. The
register case has 26,688 wire cells and 10,304 devices/tiles in its source
document. Synthetic WLD v139 has no writable bestiary section; local modern
fixtures cover that feature. No private save or resource pack is a CI input.

```sh
python3 tool/perf/generate_synthetic_world.py build/performance/synthetic-medium.wld
export ABC_PERF_SYNTHETIC_WORLD="$PWD/build/performance/synthetic-medium.wld"
export TERRAFORGE_ENGINE_LIBRARY="$PWD/build/native-release/libabc_engine.so"
export LIBQUICKJSC_TEST_PATH="$PUB_CACHE/hosted/pub.dev/flutter_js-0.8.7/linux/shared/libquickjs_c_bridge_plugin.so"
ABC_PERF_REPORT=build/performance/native-actions.json \
  flutter test --no-pub --concurrency=1 test/performance/native_actions_test.dart
ABC_PERF_REPORT=build/performance/wasm-actions.json \
  node --expose-gc tool/perf/benchmark_wasm.mjs
```

The verified JS runtimes default to `web/engine/world.js` and `player.js`;
`TERRA_WORLD_RUNTIME` and `TERRA_PLAYER_RUNTIME` can select other verified builds.
Run the native and WASM processes sequentially. The default CI tier performs
one first-use cycle, five excluded warmup cycles, then 25 measured cycles.
`ABC_PERF_CYCLES` and `ABC_PERF_WARMUP` are explicit overrides (minimum 3 and 1).
Within a cycle documents alternate order, are edited, exported, independently
reopened and closed. Circuits are loaded, edited, routed, triggered, ticked,
reset and reopened; all 15 source demos are exercised. This is not an open-only
loop. Throughput is awaited operations/second, not ticks/second or frames/second.

Online resource and cloud protocol/storage suites use local synthetic
transports and have separate report destinations. Their results do not claim
live HTTP latency. MAP codec/generation and profile UI have separate suites.

## Private local and soak workload

Use `ABC_PERF_TIER=local` (10 measured cycles) or `soak` (50), and optional
`ABC_PERF_WORLD`, `ABC_PERF_WORLD2`, `ABC_PERF_PLAYER`, `ABC_PRIVATE_PACK`. These
are local filesystem paths supplied by the user. Private fixture variables are
rejected in the CI tier. Fixture labels, dimensions, format versions and byte
counts are recorded; names, chest contents, file paths, coordinates, raw saves
and output binaries are not written into reports. Private data never needs an
upload. Keep private reports under ignored `qa-evidence/performance/`.

Each real world additionally executes a 32×32 lossless region read/write,
whole-world conditional tile rule, complete whole-world circuit load/query/
trigger/tick/save/reopen/close. Existing engine host budgets bound input,
region records and VM memory; these are workload safety bounds, not invented
performance pass thresholds. Modern world bestiary/chest edits and real PLR
attribute/inventory round trips run on detached in-memory candidates.

Start a new environment/large fixture with 3 measured cycles and one warmup,
then use 50-cycle soak where the measured runtime and host resources permit.
Serialize all large benchmark runs and compiler processes. A process killed
while other heavy jobs run cannot establish a product memory defect.

## Memory and interrupted runs

Node reports RSS, JS used/capacity heap, external/ArrayBuffer bytes, WASM linear
capacity, and actual exported tx allocator native/persistent and bridge live
payload bytes. Capacity/high-water values are not live allocation counts.
Allocator headers/libc allocations are outside tx live-payload counters.
WASM bridge payload and explicit document/session owner counts must return to
zero at complete cycle boundaries. Native reports process RSS/max RSS and
explicit owners. Configure a separate test build with
`cmake -S native -B build/native-perf -DCMAKE_BUILD_TYPE=Release -DABC_PERF_COUNTERS=ON`
and select that built library for read-only tx live-payload/peak/world-owner
counters. The optional ABI is off in production, changes no allocator behavior,
and is read only between completed serialized calls. The workload verifies a
live document raises the counter and closed owners restore zero. These counters
exclude Dart, QuickJS, libc and headers, and saturate at UINT32_MAX. Without
that optional build, unavailable counters remain null. The profile app can
add VM heap metrics. RSS growth alone does not prove a leak.

`--expose-gc` adds a separate after-close-GC sample; the ordinary after-close
sample is retained too. Forced collection is outside operation timing. Native
integration retains unforced RSS as its primary sample. With explicit
`ABC_PERF_GC_DIAGNOSTICS=1`, it reuses the profile VM-service probe only after
all owners close, adding a separate after-close-GC heap/RSS sample outside
operation timings. An unavailable VM service is reported explicitly, with any
private connection URI removed. Baselines must use the same GC diagnostic mode. First-use timing is
the first complete workload cycle after fixture preparation. An operation may
repeat within that cycle; OS caches are not flushed and codec bootstrap may already have
occurred while generating the synthetic player.

Core suites append sanitized begin/end events with RSS/high-water to
`REPORT.events.jsonl`, and checkpoint a `running` report after each cycle.
Forced termination leaves that evidence intact. It never becomes a passed
run, and retries must use a distinct report path when preserving comparisons.
All failures and slow samples must be retained; never silently omit a run.

## Baselines and comparison

```sh
python3 tool/perf/test_compare.py
python3 tool/perf/compare.py \
  --baseline baseline-1.json --baseline baseline-2.json --baseline baseline-3.json \
  --candidate candidate-1.json --candidate candidate-2.json --candidate candidate-3.json \
  --require-baseline --output comparison.json
```

Use at least three independent fresh-process runs of the base revision and
three of the candidate, on the same controlled machine with matching runtime,
build mode, fixture inventory, tier and cycle counts. Interleave base/candidate
runs to reduce drift. Do not compare debug Flutter test latency to a release
app or compare unrelated CI hardware. Keep the full raw reports.

Reports record `ABC_PERF_COMMIT` (or `GITHUB_SHA`, then observed Git HEAD), the
observed worktree commit and dirty state. Dirty/unknown source reports are smoke
evidence and are rejected as controlled acceptance baselines. Reports also
record fixture SHA-256, selected binary/loader hashes, Node/Dart/Flutter versions
where observable, Emscripten manifest version and host compiler. The optional
native ABI supplies its actual build compiler. Keep private fixture hashes in
local reports; strip them from public summaries.

The comparator validates distributions and owners before comparing. The
statistical unit is a whole process run; within-run samples are correlated.
It reports deterministic bootstrap 95% intervals for the difference of run
medians and requires complete separation of observed run values to flag a
regression. Cold first-use and warm repeated-call median/p95 values are compared
as separate phase-qualified metrics across those same independent processes.
First-use does not imply flushed OS caches; a cold row can have only one sample
inside each process. There is no guessed millisecond, percentage or RSS threshold and
no outlier removal. Missing repeats/baseline are explicitly inconclusive.
Small-sample p95 has coarse order-statistic resolution; longer soak and profile
frame results are necessary to judge tails and human-perceived fluidity.

Diagnose a regression, fix the responsible code, rerun correctness and repeat
the same controlled comparison. Changed operation coverage or fixture content
requires a new comparable baseline. Reporting `passed` means the workload and
its correctness checks completed; it does not, by itself, establish performance
acceptance against a prior release or every hardware target.

### Versioned CI baseline

Automatic performance runs compare with the first complete calibration run
37909644872, commit a5612b474fc8dc50d41b3bc6b87234d30ba97e02. A manual
`baseline_run_id` can select another successful run of the same repository and
workflow. The aggregate checks the selected run, the pinned default commit,
each report digest and each downloaded execution's commit before comparison.
Only the aggregate job uses the existing `actions: read` permission. Expired or
missing baseline artifacts fail visibly; they do not silently become a pass.
Runner/toolchain differences remain inconclusive. The baseline's own first
calibration had no comparison and was not a regression acceptance result.
