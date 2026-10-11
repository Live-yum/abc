# Flutter ownership observation contract

This diagnostic overlay targets product base
`9d4cd5a0f9db03042a3986689fea374ba92d78b8`. It does not alter the original
`runComputerMemoryDiagnosticCycle`, original VM heap helper, original journal,
or ComputerDisplay rendering implementation.

## Entry points and build identity

- Measured target: `integration_test/computer_memory_ownership_test.dart`.
- Profile preflight target, in its own process before measurement:
  `integration_test/memory_ownership_profile_smoke_test.dart`.
- Compile define: `ABC_MEMORY_OWNERSHIP=true`.
- Runtime environment `MEMORY_OWNER_ARM`: exactly `probe-only`, then
  `product-with-ownership`, in two fresh serial processes from the same bundle.
- `ABC_OWNER_SCHEDULE`: the verified 9d4 timing-only schedule with schema
  `abc.memory-ownership-schedule.v1`; the older 51bc8ea schedule is rejected.
- `ABC_OWNER_LIBC_HELPER`: absolute path to the separately built official-header
  helper from `tool/perf/native_owner_libc_probe.c`.
- `ABC_OWNER_HELLO`: new runner-owned handshake path. A flushed `.pending`
  sibling is renamed into place; existing final or temporary files are rejected.
- `ABC_OWNER_READY`: new runner-owned identity acknowledgement path. It must
  be absent before hello, and the runner publishes it atomically only after
  checking the live owned process, source/build hashes and equality to the first
  arm's native bundle. Before source input or any gauge, the target waits at most
  60 seconds, with 25ms file-existence checks. Invalid content fails immediately
  without retry or starting measurement.
- `ABC_MEMORY_RAW_DIRECTORY`: new per-arm directory.
- Existing `TERRA_UI_PROFILE_OUTPUT`, `TERRA_UI_PROFILE_STANDALONE_OUTPUT`,
  `PERF_*` defines and renderer environment retain their existing purposes.

The hello schema is `abc.memory-ownership-hello.v1`, with `arm`, `hostPid`,
`sourceCommit`, `baseProductCommit`, and `startedUs`. The measured process never
loads a native engine merely to produce hello/baseline or probe-only gauges.
The profile smoke creates, clones and disposes a tiny image in a separate
process; the two measured processes do no synthetic image/decoder warm-up.
The ready schema is `abc.memory-ownership-ready.v1`, with exactly `arm`,
`hostPid`, `sourceCommit`, `baseProductCommit`, and a 64-hex `buildSha256`.
`startupIdentityGate` preserves those validated fields plus `readyReceivedUs`.
This one-time startup gate precedes the schedule origin and all 52 gauges; its
file checks are not a memory sampler. A failure leaves the gate null and retains
the failed diagnostic report. Python and Dart timestamps are separate domains.
The runner's 900-second process envelope consists of up to 300 seconds for
startup and a 600-second measurement window after hello. The Dart integration
test separately has a 10-minute timeout from test entry, so its setup time also
consumes that internal bound. READY waiting consumes the post-hello 600-second
window as well; it does not extend any timeout.

## Complete report

Schema `abc.memory-ownership.v1` retains the generic product report envelope and
all original product-cycle assertions, with `arm`, `baseProductCommit`,
`plannedCheckpoints:17`, `vmProbeCalls:17`, `plannedOwnershipGauges:52`,
`ownershipGauges`, `imageObserverSummary`, schedule hash/origin/observations.
`ownershipGaugeWrites` records one scalar receipt per attempted persisted row:
`id`, `sequence`, `startUs`, `endUs`, `bytes`, and `status`. Its span starts
before JSON encoding and UTF8 conversion and ends after write/flush. A successful
receipt has `status:written` and exact UTF8 JSONL bytes including newline; a
failed attempt has `status:failed`, null bytes, and rethrows without retry.
Receipt creation happens after that span, retains no row, and never rewrites it.
`allocatorInitialization` records the existing libc initialization C call's
`startUs`, `endUs`, `statusCode`, availability/reason, and clock domain. This
setup observation precedes hello and every one of the 52 unchanged snapshots;
it does not include DSO loading, symbol lookup or buffer allocation costs.
`vmProbeCalls` counts helper attempts, including failed ones. Each helper still
requests one allocation profile per live isolate group, not necessarily one
RPC per checkpoint. Probe-only cycles have zero product work and start with
`status:running`. They become `status:completed` only after the second checkpoint
succeeds; interrupted slots remain running and do not increment completedCycles.

The 52 IDs are:

1. `initialization`, `baseline.before-gc`, `baseline.after-gc`.
2. For each cycle 0 through 7, `cycle-I.retained-quiet-end`,
   `cycle-I.after-close-retained.before-gc`,
   `cycle-I.after-close-retained.after-gc`, `cycle-I.released-quiet-end`,
   `cycle-I.after-close-released.before-gc`,
   `cycle-I.after-close-released.after-gc`.
3. `final-quiet-end` with cycle 8.

The gauge phase is the ID suffix after `cycle-I.`; baseline phases retain the
`baseline.` prefix. Gauge rows contain `sequence`, `id`, `cycle`, `phase`,
`startUs`, `mainStartUs`, `mainEndUs`, `captureEndUs`, `serializedAfterUs`,
`endUs`, `atomic:false` and these distinct sources:

- `images`: installation/stop timestamps, created/disposed handle totals,
  observed balance/high water, active/callback identity flags, replacement and
  predecessor-error evidence. Only scalar counters are held. Handles created
  before observer installation are explicitly unknown; no Image references,
  allocation stacks or estimated GPU bytes are retained.
- `imageCache`: `currentSize`, `currentSizeBytes`, `liveImageCount`,
  `pendingImageCount`. These are overlapping populations and do not cover direct
  ComputerDisplay/RawImage decodes.
- `wrapper`: last-result presence; records/world/objects/stats lengths; source
  descriptor/token presence. No buffers, source path, token or descriptor is
  serialized. No collection of prior backends/workspaces is created.
- `worker`: `worker-not-started` with null identity/owner, or `acknowledged` with
  stable `workerGeneration`, request/ACK times and production pending counts
  excluding the diagnostic RPC. `owner` has its own times, ordinary document
  handle count, binding-presence flag, independent `host` and `native` values.
- `host`: start/end times; session/closing/world/circuit/file/output-lease
  gauges; read/hash allocated, successfully freed, outstanding bytes, cleanup
  failures and accounting certainty. A throwing free makes accounting uncertain
  even when a test allocator physically freed memory before throwing.
- `native`: independent C-call times, ABI/version/layout, 16 `rawWords`, censor
  mask, nine named values and known 128-byte observer buffer. Missing symbols
  never become zeros. C static owner counts remain independent from Dart maps.
- `fd`: own-process raw numeric enumeration count, category counts
  (`socket`, `pipe`, `anonymous-inode`, `path-like`, `other`), vanished/unreadable
  and ignored-nonnumeric counts, per-stage timestamps, controlled error
  kind/code, status, ceiling 4096 and explicit self-enumerator/non-atomic flags.
  Targets, FD names/numbers and arbitrary exceptions never enter the report.
- `allocator`: `abc.native-retention-mallinfo2.v1`, call sequence/times,
  availability/reason, ABI metadata and the ten official mallinfo2 fields.
  Unsupported slots are null. All 52 wire slots are preallocated before the
  initialization sample, with a hard call budget of 52.

Per checkpoint, the sequence is original OS-before, worker/main/FD-before,
libc-before, VM start, exactly one existing telemetry/helper invocation, VM end,
libc-after, worker/main/FD-after, original OS-after, then JSON materialization
and persistence of both gauges. Capture spans remain distinct from persistence
times. Gauge `serializedAfterUs` and `endUs` are pre-encoding markers, not
write-completion times; use the independent receipts for encoding/write/flush
cost. Existing quiet-end markers precede new observation work; offline quiet
end selection must keep using those original markers.

`raw.ownershipGauges` describes `ownership-gauges.jsonl`; each line equals the
corresponding report row. `raw.allocatorCaptures` describes
`allocator-captures.jsonl`, preserving all completed fixed-buffer calls even
when a later VM/OS/gauge operation fails. Allocator raw rows use
`sequence/startUs/endUs/statusCode/rawWords/rawWordEncoding`; all 16 words are
unsigned decimal strings so `UINT64_MAX` is unambiguous on Dart's signed-int
runtime. Completed partial gauges have `partial:true`; an aborted pre-VM
observation has `abortedBeforeVm:true`. Complete-run validation rejects gaps.
Every product row from cycle 0 onward requires an acknowledged worker and an
available native observation. Initialization/baseline and all probe-only rows
require `worker-not-started`. Any invalid observer or worker state is marked
partial before persistence and stops later samples; a pre-VM failure also
stops that VM invocation. A thrown diagnostic-owner request becomes a failed
partial worker envelope with null owner/generation/pending values and a fixed
error category; it never becomes a zero owner count.

`Directory.listSync` allocation grows with FD count. The 4096 ceiling is checked
after one enumeration, not claimed as a hard first-list allocation bound.
Exceeding it or another FD error writes an incomplete row and stops subsequent
sampling. The raw count may include the temporary enumeration descriptor; no
unverified subtraction of one is made. Image callback replacement is likewise
incomplete, preserves the replacement, and does not trigger reinstallation.

## Focused CI verification

Local Dart/Flutter execution was deliberately not used in the task environment.
Official CI must format/analyze these exact files and run:

- `test/memory_ownership_gauges_test.dart` with the diagnostic define both absent
  and true (baseline access must not start a worker).
- `test/memory_ownership_retention_test.dart` with `ABC_OWNER_LIBC_HELPER` set.
- `test/memory_ownership_worker_test.dart` against the selected native library,
  checking lazy no-start, FIFO close/snapshot ordering and stable generation.
- Existing `test/profile_memory_test.dart` and `test/computer_display_test.dart`.
- Extended `test/native_world_circuit_read_buffer_test.dart`,
  `test/native_world_circuit_hash_test.dart` with the diagnostic define true,
  preserving all existing failures and cancellation assertions.
- Extended `test/native_world_circuit_ownership_test.dart` against the selected
  CI native library, with the define true, for session/file/lease retry gauges.
- The independent real-profile image hook smoke target above.

The smoke and focused contracts are preflight, not extra measured arms. The
two measured processes have one invocation each and unchanged 8-cycle/17-probe
and quiet budgets. No extra class reports, GC, cache eviction, allocator trim,
retry matrix, dropped first/cancelled work or stability threshold is added.
Completion proves observation integrity only. GPU/driver/graphics residency and
untracked native ownership remain explicitly unavailable; metrics must not be
added together or subtracted from RSS to manufacture a native total.
