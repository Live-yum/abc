# Public CI performance evidence

`.github/workflows/performance.yml` runs independently from the five functional
build jobs. It checks out the requested PR head, sets `ABC_PERF_COMMIT` to that
same hash, and observes actual HEAD and worktree dirtiness again in every
process manifest and benchmark. Dirty or unknown snapshots cannot become a
controlled baseline. Rules and the Dart2JS MAP worker are rebuilt and checked
for source-tree differences before measurements. WASM engines are rebuilt with
pinned Emscripten into ignored build output, preserving a clean source tree.

All public inputs are repository-authored synthetic WLD, PLR, binary MAP,
resource/catalog and cloud protocol fixtures, plus the attributed circuit
demos. No personal saves, private resource packs, account calls, credentials,
production services or external service writes are part of this workflow.

## Jobs and counts

| Workload | Fresh processes | Cycles per process | Build / execution | Job bound |
|---|---:|---|---|---:|
| Native engine + Workspace actions | 3 | 1 first-use + 5 excluded warmup + 25 measured | Release C engine with optional read-only allocation counters; debug Flutter test host | 90 min |
| WASM bridge and rules | 3 | 1 first-use + 5 excluded warmup + 25 measured | Release WASM under Node, including separate after-close GC samples | 90 min |
| Cloud local protocol/vault and resource local transport/storage | 3 each, sequential | 1 first-use + 5 excluded warmup + 25 measured | Debug Flutter test host; synthetic transports | 45 min |
| Binary MAP generation / AOT codec / Dart2JS codec / actual isolate owner | 3 each, four separate matrix runners | 1 first-use + 25 repeated; **0 excluded warmup** in the current MAP protocol | Release C / Dart AOT / Dart2JS Node / real Dart isolate | 60 min each |
| Flutter Linux UI profile | 5 | 2 excluded warmup + 8 measured complete app lifecycles | Real profile application, Xvfb, observed Mesa software renderer | 90 min |

These counts are explicit; the MAP protocol does not silently pretend to use
the other core suites' five excluded warmup cycles. Row counts can exceed cycle
counts when an operation is invoked multiple times per lifecycle. Core API and
debug test timings are never FPS. Node worker timer progress is never a browser
frame measurement. Only `flutter-ui` profile reports contain actual Flutter
engine frame timing and VM heap evidence.

Heavy processes and compilers run sequentially within each runner. Independent
jobs may use separate hosts. Per-process timeouts preserve their log and
execution manifest; they indicate incomplete evidence, not a guessed speed
threshold. A timeout/failure never disappears from the comparison.

## Reports and failure evidence

Every invocation has a unique execution ID, source/machine provenance, start
and completion state, exit code, elapsed time, full log, and SHA-256 of its raw
JSON. Core journals and checkpoints remain beside the reports. Upload steps
use `always()`, including after failed measurements. A runner killed before
upload can still lose its files; the aggregate job detects absent repetitions
and fails instead of claiming complete evidence.

Artifacts named `perf-raw-*` contain the raw JSON, execution manifests, logs and
available journals. `perf-linux-profile-bundle` contains the complete Linux
profile app for compatible-machine reproduction. `perf-raw-ui` also retains
the actual `glxinfo -B` output. All artifacts have a 30-day retention request.

`perf-coverage-and-comparison` contains:

- `coverage.json`, `coverage.csv`, `coverage.md`: actual operation/action/variant,
  runtime, fixture, cycle counts, median/p95/max, frame summaries, process memory
  scope and provenance. Each fresh process remains separate; no pooled timing
  distribution or outlier removal disguises between-run variation.
- Explicit declared/missing action variants from `action_gaps.json`. Direct
  profile-controller rows are joined by the recorded dispatcher name. Core API
  timing cannot satisfy UI dispatcher coverage. Controller latency receives no
  invented frame samples; its associated profile macro scopes remain available.
- `comparison.json`, `comparison.md` and optional per-suite comparator output.
  Rejected/partial raw reports remain listed, and missing required executions
  fail validation. Full reports and memory/frame raw samples remain authoritative.

## Select a baseline

An ordinary push/PR run validates its workloads and records **inconclusive first
calibration** when no baseline was selected. A green workflow in that state
means completed correctness/evidence collection, not passed performance
regression acceptance.

To compare, manually dispatch **Public performance evidence** on the candidate
revision and set `baseline_run_id` to a completed successful run of this same
workflow in this same repository. Use a different baseline revision. The
bounded GitHub API lookup verifies run identity and completion, and the pinned
download action retrieves only `perf-raw-*` from that run. The only additional
job permission is `actions: read`; no new token, credential or repository
setting is created. Expired, missing, failed or mismatched baseline artifacts
cannot silently become a passing comparison.

At least three independent core processes or five profile processes per
revision are required. Manifests reject duplicate executions, digest changes,
mixed source heads, dirty trees, changed fixture inventories and changed
conditions within a group. The existing `compare.py` and `ui_compare.py` then
require matching report identity, operation coverage and run conditions.
Cold first-use and warm repeated-call median/p95 metrics are compared separately,
with phase included in each metric key. A cold-only regression cannot be hidden
by unchanged warm latency; both use the same independent-process noise rules.
Observed runner image, CPU, OS and toolchain metadata must also match. Built
program hashes remain provenance because the program itself can change between
revisions. All baseline/candidate samples, including slow runs, remain intact.
A detected regression fails the aggregate job. An explicitly requested but
unusable/mismatched baseline also fails with a reason; it is not a regression
claim.

Hosted runner metadata cannot prove the same physical machine or ambient load.
For stronger acceptance, collect alternating revisions on a controlled device
with the exact same harness, settings and fixture bytes, and use the same
comparators. Linux software-renderer evidence does not cover physical
Android/iOS/macOS devices or Flutter Web. First calibration, statistical
non-detection, lack of a personal MAP fixture and unmeasured variants remain
explicit limitations.

## Local static verification

```sh
python3 -m unittest discover -s tool/perf -p '*test*.py'
python3 tool/perf/coverage_report.py --reports build/perf/candidate --output build/perf/summary
python3 tool/perf/compare_ci.py --candidate build/perf/candidate --output build/perf/summary
```

The last command requires the complete CI execution manifests. It will reject
an unborn/dirty developer tree and cannot convert a debug profile smoke into
acceptance. See `README.md` and `UI_PROFILE.md` for direct core and real-device
reproduction commands.
