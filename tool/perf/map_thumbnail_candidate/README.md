# Fixed-main MAP thumbnail candidate

Prepared only. No local Dart/Flutter execution, compilation, dependency resolution,
benchmark, remote write, upload, or performance pass is claimed. The original
General gate remains failed. Its historical MAP shifts used identically recorded
program hashes and cannot be attributed to this proposed change.

## Candidate and source identity

Baseline A is commit `cf36cd2bf1d447a887d3ea4d19611020368de22c`, tree
`9ff4ca286afa3e545901c498de167ee0c5dfc61d`. B applies only `candidate.patch` to
`lib/domain/terraria_map.dart`. It precomputes the same nearest-floor X coordinates
once per render, and moves the source/output row multiplication out of the inner
loop. The grayscale, alpha bytes, emptiness rule, dimensions, floating-point scale,
clamping, caller-owned buffer and lifecycle behavior remain subject to the oracle.

The X table is a temporary `Uint16List` of output width, costing `2 * outputWidth`
bytes plus an object header: 1,920 data bytes for the large fixture and 1,024 for the
small one. Accepted source width is at most 32,768, so the largest source X is
32,767 and fits exactly. No cache, incremental rendering, palette conversion,
endian-sensitive store, UI style, layout or product call path is introduced.

Official CI formats B before making its local derived commit. A is never formatted.
The runner verifies that everything before/after the render method remains byte
identical. The shared observer source is formatted in both checkouts and must have
identical hashes. The oracle uses A's package configuration and fixture source.
`candidateSha256` describes the preparation patch result; it is not a prediction
of formatted execution bytes. Actual renderer, executed patch, observer and oracle
sources are archived with their own hashes. Use those B renderer bytes for any
later integration, after reviewing results.

## One bounded official diagnostic

The workflow triggers only on a push to `codex/map-render-paired-cf36`. There is no
pull-request, main, scheduled, or manual trigger. Publish the reviewed diagnostic
once to that branch; another branch push would create another run, so do not push
follow-up fixes or manually rerun without reviewing the first result. The package
does not itself authorize a push. It adds only `contents: read`, uses the existing
setup-flutter action from the pinned baseline checkout, pins the existing official
checkout/setup-node/upload actions, and sets `CI=true`.

All measurement groups run serially in one Ubuntu job. For each runtime (AOT then
Node dart2js), each group uses exactly B,A,A,B,B,A, with no retries or outlier removal:

1. Six frozen latency processes, using the unchanged `map_actions` programs,
   `run_ci_suite.py`, `map_perf_core.dart` and `compare.py`: 26 cycles per fixture,
   one cold invocation and 25 warm invocations. Twelve processes total.
2. Six separate memory-observer processes for the large legacy fixture, then six
   for the small chunk fixture. Twenty-four processes total. Each opens one fixture,
   renders it 26 times, verifies unchanged export, closes and observes a quiet period.
3. A separate correctness program per runtime must pass before that runtime's
   measurement slots run. Its execution is never a latency sample.

Here cold means the first invocation of that operation for that fixture within a
fresh process. OS/page/disk caches are not flushed, so it never means cold storage.

The job hard limit is 40 minutes. The runner has a shared 24-minute budget, requires
each full per-command timeout plus cleanup reserve to fit, and records unstarted
slots with a reason. Frozen process timeout is 180 seconds (the existing child
driver gets 160), memory process 40, oracle execution 240, build command 180. The
runner step is capped at 25 minutes and validation at five. Previous General raw
reports took about 3.3 seconds per AOT process and 34 seconds per dart2js process;
those are planning observations, not a guarantee about this run. Setup and build
failures, timeouts, all logs and partial results remain in the final artifact.

## Inputs and measured meaning

Large input: 4,200 × 1,200 source cells; `maxWidth=960`; 960 × 275 output pixels,
1,056,000 RGBA bytes. Small input: 512 × 256 cells and output pixels, 524,288 RGBA
bytes. The contract freezes fixture sizes and hashes separately by runtime: the
existing chunk encoder produces different compressed bytes under AOT and dart2js.
Node's frozen harness also includes `local-map-1`, an identical copy of the authored
large legacy fixture, matching the current frozen protocol. No personal files occur.

`map.render_exploration` times one entire RGBA thumbnail construction from an already
decoded session. Decode, worker transfer, UI texture upload, Flutter frames and
navigation are outside that scope. The product invokes this renderer on MAP
open/adopt, edit, undo and redo. It is not automatically a once-per-frame operation.
Node Stopwatch timings have millisecond resolution. The result cannot establish
browser or mobile frame pacing or visually smoother interaction by itself.

Memory processes use the same source fixture and renderer, but intentionally have
different observation overhead and lifecycle sequencing. They never enter the
frozen latency comparison. OS observations every nominal 10 ms capture sampled RSS,
whole-process VmHWM, PSS/USS when available, threads and descriptors. Native managed
heap/external/array-buffer figures are unavailable and stay null; Node supplies
these counters. A 500 ms pre-decode quiet window is compared with the final
1,000–1,500 ms of the fixed 1,500 ms post-close window. Report absolute peaks and
quiet values plus quiet-minus-baseline differences. No forced GC or wait-until-good
loop occurs. Sampled peaks can miss short allocations; VmHWM includes startup,
fixture creation, decode and verification; quiet does not prove full GC or RSS
reclamation. `ownedBytes=0` proves the session's declared buffer release only.

## Correctness, evidence and decision

See `oracle-review.md` for the finite oracle: 74 fixture pairs, 1,488 complete RGBA
comparisons, 30,720 independently specified decoded-cell checks, all light bytes,
empty states, paint boundaries, edit/undo/redo, buffer independence, typed exceptions,
and 20 independently specified exact nearest-floor scale cases. Broad scale tests
preserve the existing floating-point ceil behavior, including possible extra output
columns at roundoff boundaries. Both runtime receipts must match the frozen counts.
These expected results have not been established by a compiler or runtime locally.

Every process records actual program hashes before/after, source commit/tree/dirty
state, command/log hashes, runner image/CPU/kernel, job and boot identity. Raw reports,
programs, fixtures, actual formatted sources and all fixed slots are retained. The
validator checks the outer execution identity as well as original report validation;
an inner comparator `machine: {}` is not used as evidence of machine equality.

`summary.json` exposes absolute cold/warm median and p95 deltas in milliseconds,
each process's raw render maxima, the unchanged full comparator outcomes, and memory
comparisons in bytes/counts. Complete groups can still be compared when another
measurement group fails; incomplete groups are labelled and never replaced with a
selected subset. No thresholds or existing gate outcomes are changed. A green
diagnostic only means complete evidence and no regression from the unchanged frozen
comparator. It is not an adoption decision: review render benefit on both runtimes,
every non-render regression, memory regressions/unavailable metrics, and correctness.
If benefits are not established, keep the candidate out of the product. If they are,
integrate only the verified B renderer into the authorized performance follow-up,
then run that change's required checks before proposing a draft PR.
