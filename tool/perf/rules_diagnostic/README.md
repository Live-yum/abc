# Fixed-pin rules-only auxiliary diagnosis

This is a single bounded six-process ABBAAB diagnostic, not product acceptance.
The original full-suite failure remains unresolved:
https://github.com/Live-yum/abc/actions/runs/37920825896

The fixed same-runner evidence under investigation is:
https://github.com/Live-yum/abc/actions/runs/37945670244

## Reproducible inputs

A is `a5612b474fc8dc50d41b3bc6b87234d30ba97e02`; B is
`cddd936f95d31b14a76503e13ffc89173110a057`. The workflow checks out both separately
and verifies exact commit, tree and clean worktree. The prepare script also
verifies pinned SHA-256 values for committed world.js/world.wasm, the identical
rules bundle, original benchmark, metrics, comparator and Flutter version marker.
No WASM, Flutter or native code is built. No network is used by these scripts.

Prepared inputs and generated files live under ignored `build/`, outside source.
The generated input manifest uses repository/commit origins, never local source
paths. The generated source manifest hashes the complete diagnostic implementation
and generated runner. Both are checked before and after each process.

The original rulesCycle block is copied byte-for-byte into the runner. Its
synthetic operations and all 15 demos, cold cycle, five warmups, 25 measured cycles
and afterClose/two explicit GCs are unchanged. Only preceding document, region,
TCW and largeWorld work is removed; the rules module is the sole retained module.
No operation-specific GC, dropped samples, thresholds or second-stage SHA switch
are introduced. Node v22.23.3/V8 12.4.254.21-node.57 is mandatory.

## CI and local validation

The independent workflow is `.github/workflows/rules-only-diagnostic.yml`.
Relevant pull-request opened/synchronize events run one six-process `off` job.
It also has workflow_dispatch with `off` (default) and explicitly selected
`auxiliary`. There is no matrix or automatic second observation group. A separate
dispatch has a separate output directory/artifact name. GitHub may rerun a
matching PR event after later updates; no persistent once-ever marker is claimed.
Concurrency does not cancel an in-progress diagnostic. Repository permission is
read-only; checkout credentials are not persisted.

Prepare from clean pinned checkouts:

    python3 tool/perf/rules_diagnostic/prepare_inputs.py --baseline-source build/rules-pins/baseline --candidate-source build/rules-pins/candidate --output-dir build/perf/rules-diagnostic/prepared

Validate without executing a benchmark:

    python3 build/perf/rules-diagnostic/prepared/run_diagnostic.py
    python3 build/perf/rules-diagnostic/prepared/test_diagnostic.py

Future explicitly authorized execution:

    python3 build/perf/rules-diagnostic/prepared/run_diagnostic.py --execute --observations off --timeout-seconds 300 --output-dir build/perf/rules-diagnostic/off

`--allow-file-snapshot-for-validation` permits preparation from hash-verified
files for lightweight local validator tests when Git checkouts are unavailable.
It marks the manifest accordingly; execution refuses such packages. It cannot be
used to bypass the CI checkout verification or runtime pin.

## Observation scope

Default `off` produces no extra heap/RSS/GC probe evidence. Do not describe an off
result as GC attribution. Explicit `auxiliary` adds per-cycle JSONL files with
operation envelopes, JS heap/RSS, module count/capacity, native/bridge live bytes,
owner count, and actual GC start/duration plus callback delivery times.

Sampling and synchronous writes surround the original measure() call, outside
its timer. Envelopes also include original journal/bookkeeping, so they are not
exact timer boundaries. Attribute GC by start/duration, not delivery cycle.
Observer records are streamed immediately; no cross-cycle array is retained.
Two diagnostic event-loop turns and takeRecords() drain each cycle before its
file closes. These turns are outside operation timers. Final record/file-close
overhead is excluded from recorded totals.

Boundary, callback and write wall times are recorded; nested totals overlap.
Callbacks can run inside an awaited timed operation. Extra observation itself
changes allocations and GC scheduling, so compare only identical modes. An
instrumented result cannot replace an uninstrumented regression result.

## Bounded stopping and interpretation

The original six full-suite processes took 95.8–97.8 seconds each, about 9.7 minutes
combined. Rules-only is expected to be similar or shorter; this is an estimate.
Each process has a maximum 300-second timeout. The diagnostic has a 1,500-second
budget and stops before admitting another full timeout beyond that budget. CI
warns when projected six-process time exceeds 1,200 seconds. Job timeout is 35
minutes, leaving time to preserve partial results. No failed slot is replaced.

Stop on changed inputs/runtime/host, correctness/owner failure, invalid or absent
report, timeout, cancellation, or after six successful processes and one
comparison. Preserve partial session metadata, logs and completed reports.
No automatic next-stage or additional group is scheduled.

The wrapper uses original compare.py validate/identity/aggregate/compare_values:
5,000 bootstrap resamples, 95% interval and complete process separation, without
excluded samples. Hashed snapshots are truthfully represented; no clean Git
worktree is fabricated for generated output. The result is a separate diagnostic
schema and always carries overallAcceptance=unestablished.

There is no full-suite control repeated on this new runner. Therefore:

- If rules-only separation disappears, it supports either prior prefix/heap
  context OR a different job environment. It does not establish native SHA as
  causal, equivalence, or repair of any original regression.
- If it persists, the preceding prefix is not necessary for separation in this
  experiment. Rules-module binary layout/runtime effects remain candidates;
  unchanged JavaScript does not make the measurement noise automatically.
- Only auxiliary mode can provide GC timing association, and RSS contraction
  alone does not prove GC. Opposite reset/reopen GC timing may support relocation.
- Never pool new isolated measurements with original full-suite measurements.
- Keep all 50 original regression rows unresolved. Neither result gives an
  automatic green light or proves real WLD/UI smoothness.

Original fixture hashes and assertions remain. The workload does not generate
cross-version canonical hashes for every mutation, export or execution packet;
full output equivalence is not claimed.
