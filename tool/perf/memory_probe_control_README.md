# Fixed-product paired memory measurement control

This independent measurement-overhead experiment does not replace the original
full-WLD result or its validator. The verified eight-cycle original run remains
an unresolved observation: released-point RSS rose **199.051 MiB**, and the ends
of the same released-quiet window rose **205.461 MiB**. Its last released point
was 727.332 MiB; the additional final quiet ended at 697.215 MiB. No product leak,
leak freedom, plateau, or frame-rate conclusion follows from those figures alone.

## Exactly two processes

1. **probe-only**: no WLD, no edit, no native worker. Replays eight nominal idle
   workload slots, the original 17 VM checkpoints, frame journal persistence,
   prefix release, and the same quiet/barrier schedule. It calls the unchanged
   public `memorySnapshot` helper through a VM-service client that records only
   response-size and per-class-count scalars. Profile bodies are not saved.
2. **product-os-only**: the original eight fixed WLD/Pong cycles, including the
   initial cancellation, reset and streamed save/reopen, using the original
   action implementation. All 17 nominal checkpoint slots are OS-only; no VM
   service call or `getAllocationProfile` is invoked. Each omitted VM operation
   is replaced by its original bounded nominal elapsed time, recorded as a wait.

Both arms retain the existing in-process 10 ms RSS / 100 ms smaps sampler and
FrameTiming journal, and add the same independent external OS observer. A has
main+sampler isolates; B additionally starts the original process-owned native
worker. That difference is intentional and explicit; no dummy worker is added.
B's topology is not claimed as measured through the VM service.

The external observer checks the handshake PID, UID, process group, ancestry and
`/proc` start time, then reads only that owned application's memory records.
Identity is checked before and after reads to fail on exit/PID reuse. It streams
all samples to JSONL; missing data, a failed monitor, or a missing acknowledgment
fails the experiment instead of becoming zero. It never requests an allocation
profile. Its Python monotonic nanoseconds and Dart Timeline microseconds are
separate clock domains linked by request/acknowledgment identity, not subtracted
as though their epochs were identical.

## Timing and budget

`memory_probe_control_schedule.json` contains timing-only configuration derived
from [public CI run 37945670140](https://github.com/Live-yum/abc/actions/runs/37945670140),
commit `51bc8eaa76b145b0d9bec3c95977779af43b676c`, verified report SHA-256
`16d8f3139d6ce141e597b87db27a42e68719ce3278e5bb696a56cf7f191c4711`.
Only relative microseconds, phase names and public provenance are retained; no
original PID, local source path, service URI or original measurement series is
embedded in the configuration.

There is one baseline and two checkpoints per cycle: **17 total**. No first-use
or cancelled operation is excluded. Each existing quiet is three 16 ms frame
barriers followed by at least 1,200 ms of real time. The final quiet has the same
shape in both arms. Cycles 0–6 originally had only 17–19 ms after the last probe
before the next cycle; the control keeps a separate short `pre-next-work`
endpoint and does not invent a full quiet interval there. Added external
observations and actual overruns are recorded; waiting never compresses product
operations or hides late timing. Nominal replay is approximately 434 seconds.

Each arm is invoked once, serially, with **300 seconds for build/hello and
600 seconds from application hello**, also bounded by 900 seconds total.
A failed ordinary arm does not trigger a retry or erase its evidence; B can still
run independently. A source/identity invariant failure stops unsafe continuation.
There is no matrix, retry, four-arm expansion, or extra WLD soak. The workflow
runs for a real change in diagnostic files (`before→head` for synchronize,
`base→head` for opened), or one explicit manual dispatch. It does not cancel an
in-progress diagnostic.

## Product and source identity

The measured product is always the fixed `51bc8ea` tree, whose product code is
the original `cddd936` snapshot. A separate CI checkout is made at that commit;
only explicit diagnostic additions are overlaid. The original test's `_cycle`
name is made public at its declaration and call, plus a single lint annotation
for its existing private return wrapper. The rest of its bytes come directly
from the fixed commit, even when the workflow head has newer lint or UI changes.

The publication head should merge these small entry-point changes into its
current test file, preserving existing lint fixes. CI does **not** copy that
head's original-test body into the measured source. `memory_probe_control_prepare.py`
creates a local-only derived commit and saves the exact binary patch, patch
SHA-256, base/overlay/derived commits, derived tree and file hashes. The runner
checks every tracked non-diagnostic blob and actual file bytes against the fixed
base, before and after each arm. No `lib`, `native`, UI, allocator, credential,
security setting or published branch changes are part of preparation.

The original native counters stay **OFF**. Each arm preserves its actual
Profile/O3/NDEBUG build provenance and executable/native/app hashes before the
next target build can replace them. New reports use
`abc.memory-probe-control.v1`; they cannot be fed to the original acceptance
validator or concatenated with the old 15/8-cycle result groups.

## Interpretation and remaining limits

The probe arm requests a full AllocationProfile inside the process being
measured. Its response is decoded into JSON and ClassHeapStats before the
unchanged helper asks for isolate-group memory. The transport observer counts
UTF-8 length without allocating an extra response-sized encoding; it records
response count/total/maximum, class count, profile-reported heap/capacity/external
and `dateLastServiceGC` when supplied. `gc:true` requests a collection; it does
not guarantee one. Observer overhead still exists and is identified.

Compare matched named quiet endpoints and actual timing first. Keep immediate
pre/post-probe spikes and short pre-next-work windows separate. Heap used,
heap capacity, external, RSS, PSS and USS are overlapping views and must not be
added. Two arms change both workload and probe presence, so their difference is
not an exact subtraction of probe bytes from product bytes and cannot isolate
every allocator or graphics owner. The original run supplies context, not an
interchangeable third arm under identical instrumentation.

No `malloc_trim`, allocator patch, larger pass threshold, counter-enabled build,
headless engine variant or new product fix is included. Public raster-cache
fields are kept but do not account for all graphics memory. No observed display
refresh is available, so no assumed 60 Hz jank threshold or FPS pass is emitted.
All received frames, slow tails and raw OS records remain preserved. Engine
frames not emitted before the bounded stop are still unknowable.

## Local verification and CI

Only lightweight contracts should run locally in the constrained task
computer. Do not launch Flutter profile, compile the app, or open the full world
there. In an assembled repository checkout:

```sh
python3 -m unittest discover -s tool/perf -p 'memory_probe_control*_test.py' -v
python3 -m py_compile tool/perf/memory_probe_control*.py
dart format --output=none --set-exit-if-changed \
  integration_test/computer_memory_probe_control_test.dart \
  integration_test/support/computer_memory_probe_telemetry.dart
```

The dedicated workflow installs the pinned original Flutter revision, resolves
its unchanged lockfile, performs target syntax/analyzer checks, fetches the
already-authorized public WLD, and invokes the paired runner once under Xvfb.
Partial artifacts are uploaded on failure. A passing control validator means
that control evidence is complete, not that memory stability is accepted.

### Sequential ProcessInfo RSS observations

The pinned Linux Dart runtime reads `ProcessInfo.currentRss` from
`/proc/self/statm`, then obtains `ProcessInfo.maxRss` separately from
`getrusage(RUSAGE_SELF).ru_maxrss`. These are not one atomic snapshot.
The exact SDK implementation is
[process_linux.cc](https://github.com/dart-lang/sdk/blob/04bcd1036cdc799ac6564988f159ee454d42c822/runtime/bin/process_linux.cc#L975);
[Linux documents asynchronous RSS accounting](https://www.kernel.org/doc/html/latest/filesystems/proc.html).

For this verified platform/SDK and explicitly non-atomic VM checkpoint only,
RSS above the separately reported HWM produces `rssSamplingDisagreements` and
a visible warning, retaining both raw values, their difference, the measurement
window, sources and read order. Values are never clamped or replaced. Unknown
sampling provenance, atomic contradictions, same-status OS HWM contradictions,
and heap-used above heap-capacity still fail validation. Growth calculations,
raw reconciliation and the absence of a plateau/no-leak acceptance gate are
unchanged. Historical reports and their original failed validation remain intact;
a revised validator output is a separately identified interpretation.
