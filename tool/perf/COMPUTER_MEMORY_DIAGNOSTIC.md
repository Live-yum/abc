# Bounded WLD memory attribution diagnostic

This is an independent, opt-in Linux Flutter profile diagnostic. It does not
change product code, enable native allocation counters, establish a performance
baseline, or run a device FPS benchmark. No older report is concatenated with it.

## Fixed work and stopping condition

Invoke exactly once in the existing public Computerraria UI CI job, after the
original three-process profile bundle has been archived. Reuse that job's pinned
Flutter SDK, public WLD, bundled original Pong, build dependencies and Xvfb. No
new service, credential or permission is needed.

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' \
  bash tool/perf/computer_memory_diagnostic.sh \
  build/computerraria/memory-diagnostic/memory.json
```

The runner requires a clean committed checkout, matching `ABC_PERF_COMMIT`,
`COMPUTERRARIA_WLD`, and an observed `TERRA_PERF_RENDERER`. The test accepts only
the 405,983,441-byte public WLD; the production import verifies its full SHA-256
and physical computer anchors. It loads `assets/computer/pong.bin` using the
unchanged production command and integrity check. TWLD and full-world UI byte
buffers are excluded.

One application process performs eight logical cycles, with optimization
OFF/ON/OFF/ON/OFF/ON/OFF/ON. Each starts from the original WLD, loads Pong,
executes exactly 4,096 real physical pulses in 32 awaited batches of 128 through
the existing native circuit owner, renders between batches, pauses, performs its
predefined lifecycle operation, and closes/disposes. This fixed budget reaches
Pong's display work: ON must show nonempty and changing monitor pixels; OFF keeps
its existing game-rule black-screen allowance. All 32 decoded monitor hashes and
lit-pixel counts are recorded as raw trace rows and released with their chunks.
Cycles 0/1 and 4/5 reset to the original WLD; cycles 2/3 and 6/7 save, close,
dispose, and reopen their streamed exports before final close. The first cycle
also records one cancelled initial import before its first complete import.
Reset and reopen each require another native open: the report distinguishes the
eight logical cycles from the underlying 16 complete native opens, plus the
initial cancellation attempt. That separately identified attempt may reach
native ready before the cancellation is processed; its actual outcome and any
acknowledged close are kept. OFF and ON use the same paired scenario.

All first-use, cancellation, reset and reopen evidence is retained. A test error
stops subsequent cycles; completed raw files and available failure evidence are
kept. The integration test has a 40-minute limit and its single runner invocation
has a 45-minute limit including build/driver overhead. There is no retry, resume,
extra process or data-dependent extension. Reruns require a new output location.

## Two checkpoints after each final close

1. Close the native session, await workspace close, unmount/dispose, and remove
   the test's owned temporary WLD storage. Perform three 16 ms frame barriers and
   a fixed 1,200 ms real-time quiet interval. Sample with all received recorder
   data and the backend wrapper's final `latest` result still retained.
2. Freeze raw-list prefix lengths, stream those full prefixes to a new JSONL
   chunk, flush, close, and reread its SHA-256. Compare both byte count and digest
   before releasing only that prefix. Clear the wrapper's `latest` reference.
   Repeat the same frame barriers/quiet interval, persist and release one fixed
   late-tail prefix, request GC, and sample again.

Both checkpoints bracket the existing VM service's per-isolate-group GC and
heap measurement with full OS points. Reports retain start/end times for OS
status, smaps, and the VM operation. They are sequential, non-atomic observations;
RSS/PSS/USS and Dart heap overlap and must not be added or blindly subtracted as
independent allocation buckets. Each checkpoint includes RSS, PSS, USS,
heapUsed, heapCapacity, external, isolate/group counts, recorder counts, and the
wrapper retention flag. Residual late callbacks are counted rather than hidden.
Releasing recorded objects does not promise that Dart list backing capacity or
allocator pages are immediately returned to the operating system.
Checkpoint differences include the intervening drain, GC and sampler activity;
they cannot by themselves assign all changed bytes to harness retention.

## Raw evidence and timing limits

The test uses the existing `ProfileRecorder` and controller proxy without
modifying them. Its own timing callback stores every public FrameTiming field,
including engine frame number, all six timestamps, and raster cache counters,
plus a global received sequence, callback batch number and receipt timestamp.
Operation windows, controller dispatches and other recorder collections are
saved without summary-only reduction. Chunk descriptors contain read/write
digests, byte counts, frame/record counts, and capture boundaries.

The callback remains attached across cycle boundaries. A callback received
during a chunk's asynchronous hash verification appends after the frozen prefix;
prefix removal cannot erase it. Offline validation attributes frames by their
timestamps and reports late arrivals and duplicate engine frame numbers without
discarding records. After the final fixed drain, collection stops at an explicit
timestamp and the final received tail is persisted. This proves preservation of
received callbacks, not receipt of frames still buffered inside Flutter after
that cutoff. Frame barriers do not prove complete asynchronous graphics release.

A single persistent sampler isolate writes every successful OS sample directly
to JSONL, targeting `/proc/<hostPid>/status` every 10 ms and `smaps_rollup` every
100 ms, with forced smaps at boundaries. It does not accumulate the time series
in RAM. Actual intervals and gaps can be recomputed from raw timestamps. Native
owner, VM service, sampler and small report/chunk metadata remain in the process
and are part of its footprint. Source clocks are monotonic microseconds;
`rasterFinishWallTime` is separately preserved and not used for monotonic
attribution. Lifetime VmHWM is never treated as a resettable per-cycle peak.

## Artifacts and interpretation

Keep the independent `memory-diagnostic/` directory in its own CI artifact,
outside the original native/web/UI acceptance-report directories. The runner
writes the report and standalone mirror, complete raw JSONL chunks, a sanitized
log, exact build/source provenance, execution manifest and offline summary.
The provenance records the actual executable, libapp and native library hashes,
source-file manifest hash, CMake settings and native compile flags. The runner
attaches its provenance hash and source manifest hash after the process exits;
it does not change measurement rows. The execution manifest hashes all delivered
evidence and preserves exit codes. Local VM service URLs are redacted before log
persistence and from failure-report text; the runner stops its owned process
group on exit, interruption or timeout.

The runner requires `ABC_PERF_COUNTERS=OFF` in the actual profile CMake cache.
Native counter values are explicitly unavailable, never zero. This diagnostic
therefore cannot quantify exact post-close libc, allocator, QuickJS or graphics
allocations. It cannot label retained RSS as a product leak, and would not make
that claim even if a narrower engine counter reached zero. A counter-enabled
future artifact would be a separately identified experiment.

The validator checks report validity and evidence preservation, not a memory
budget. It lists every retained/released metric and difference, plus full-window
and per-mode trends. There is no invented absolute MB threshold. Sustained
increase means that no plateau was observed in this bounded window; a fluctuating
or decreasing series alone does not establish a plateau or prove leak freedom.
Only the observed eight-cycle window is described. This Linux experiment does
not resolve the separate browser Error 9 or measure browser OS loading peaks.

Lightweight checks, without launching Flutter or opening a real WLD:

```sh
python3 -m unittest discover -s tool/perf -p 'computer_memory_checks_test.py'
python3 -m py_compile tool/perf/computer_memory_run.py tool/perf/computer_memory_validate.py
bash -n tool/perf/computer_memory_diagnostic.sh
dart format --output=none --set-exit-if-changed \
  integration_test/computer_memory_diagnostic_test.dart \
  integration_test/support/computer_memory_journal.dart
```
