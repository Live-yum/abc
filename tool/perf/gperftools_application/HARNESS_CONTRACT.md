# Bounded application harness wiring

This layer changes only the diagnostic integration harness. It does not change
production code, native bridge code, the original runner/validator, or workflow.
The original diagnostic source is
`5a161bf1215361e56358ed6476dbf97a69e53803`, with frozen product base
`9d4cd5a0f9db03042a3986689fea374ba92d78b8`.

## Preserved workload and observation order

The ownership harness has exactly six marked additive blocks: import, lifetime,
initialization, appended hello evidence, quiet hook, and outer-finally Stop.
Removing those blocks recovers the original file byte for byte, SHA256
`3a9806165d2c5e025122a3118683259c4a42d54c682b7276ab57f5b87096e3d8`.
The original eight-cycle control/product bodies, original WLD and ROI, 17 VM
group requests, 52 gauges, original GC order, save/reopen assertions, and image
coverage failure remain unchanged. No extra warm-up, GC, trim or cache clearing
is added. The existing scalar report schema and binary identities remain intact.

Native initialization runs at entry to the original outer try, before reading the
schedule and before the original hello. The original ready gate must be accepted
before `inputs.computerInput()` can read WLD. Quiet retains its original wait,
drain-start, three 16 ms pumps, 1,200 ms wait, drain-end, and awaited gauge with
write/flush. Only q0/q7 in phase `released` then call synchronous, nonleaf FFI.
This position is before the cycle's original `after-close-released` GC.

`gaugeDartUs` is the Dart Timeline completion stamp taken immediately after the
original awaited gauge returns. It is not the original gauge sample timestamp,
and the dump is not simultaneous with that sample. Dart enter/exit brackets and
native CLOCK_MONOTONIC nanosecond brackets are separate clock domains. The native
metadata supplies Dump and ACK times; no cross-domain subtraction is allowed.

The first operation added at entry to the original outer finally invokes the
idempotent native Stop, verifies its result, and serializes final sidecar evidence
before original sampler/report finalization. Native failure may already have
performed the one underlying Stop; the outer finally's ABI call cannot add a
second underlying Stop or dump. A success requires two accepted cuts, one native
Stop, stopped state verified, and all three retained observer FDs closed.
Initialization/load failures are failures, never successful entry evidence.

## Observer overhead

The helper DSO stays loaded until process exit. Native static context reserves
two 1 MiB maps buffers and reports its actual observer context/runtime bytes.
Dart constructs the probe, retains its startup map and helper library reference,
and allocates three two-element Int64 timing arrays plus one two-element Int32
status array before native initialization/hello. Their typed payload totals 56
bytes; object headers, native wrappers, maps, strings, Timeline activity, and
serialization allocations are additional observer overhead and are not claimed
as fully enumerated. Initialization and finalization allocations also count as
observer overhead. Synchronous Dump/ACK plus continuously enabled tcmalloc hooks
change allocator behavior and timing; this layer provides no correction for the
original glibc RSS growth and no performance acceptance claim.

## Environment and hello extension

Require `ABC_STACK_HELPER` (canonical absolute helper DSO), `ABC_STACK_ARM` (the
exact original arm), and launcher-supplied `ABC_STACK_OUTPUT` (sealed private
sidecar directory). The arm must equal original `MEMORY_OWNER_ARM`. Cache paths
before native initialization clears child-inherited profiler variables.

Append `stackAttribution` to original `abc.memory-ownership-hello.v1`:

- schema: `abc.gperftools-application-startup.v1`
- arm, hostPid, helperPath, targetPath (resolved `/proc/self/exe`), allocatorPath
  (fixed official full DSO), outputPath
- initialization: statusCode, startUs, endUs, clockDomain
  (`dart:developer.Timeline.now`), runningVerifiedAtInitialization, native

The `native` initialization object contains abi, offline, initialized, failure,
slotsUsed, dumpCount, stopCalls, stopRequested, stopVerified, cleanupFailure,
observerPreallocatedBytes, stopStartNs, stopEndNs, observerMapsBytes,
observerHeldFds, observerClosedFds, observerFdCloseAttempts,
observerFdCleanupFailure. No native cuts are serialized into the hello.
Successful initialization has ABI 1, offline 0, initialized 1, failure 0,
2097152 map bytes, three held FDs, and zero used cuts/dumps/stops/cleanup errors.
`runningVerifiedAtInitialization` means the native initializer checked provider
identity and running state successfully at that time. It is not a later query.

Path strings are claims, not sufficient identity proof. Before sending original
ready, the supervisor must independently bind the owned PID and actual proc
executable/maps to the sealed target/helper/tcmalloc/engine/libapp identities,
source build and original hello. A failure forbids ready, WLD, and the second arm.

## Final sidecar

`<ABC_STACK_OUTPUT>/dart-probe.json` is a fresh sibling of heap/maps files, never
inside original `raw/`. Schema is `abc.gperftools-dart-probe.v1`, with arm,
hostPid, status, startup (same object as hello), stopStatusCode, stopStartUs,
stopEndUs, dartClockDomain, nativeClockDomain, clockDomainsComparable false,
native, and dartCuts. Final native includes the initialization fields plus two
fixed cuts, each containing cycle, accepted, gaugeDartUs, enterNs, dumpStartNs,
dumpEndNs, ackEndNs, exitNs, mapsBeforeSize, mapsAfterSize. Dart cuts contain cycle,
gaugeDartUs, enterUs, exitUs, statusCode for attempted slots only.

The final sidecar is written after Stop but before the original report completes.
The supervisor seals it only after process termination and must also verify the
original workload report independently. Partial files are preserved on failure.
Successful sidecar status alone does not prove original workload completion.

## Offline verification and remaining gate

`test_dart_source_contract.py` uses Python only. Fourteen tests check inverse
byte identity, 12 frozen companion files, audited C header hash and FFI field
order/width, Linux x86_64 structure sizes 72/232, lifecycle placement and exact
two-slot bounds. Negative tests reject original gauge/GC/cycle changes, retained
or final dumps, hooks moved before gauges, Stop moved after cleanup, leaf calls,
extra dumps, and relaxed call counts. It does not execute C, Dart, Flutter,
profiler, WLD, or a fake target.

The pinned Flutter SDK must still compile this source in the authorized GitHub
CI before the one fixed pair. Passing offline contracts is not a compilation,
real FFI, target startup, profiling, original image, or performance pass.
`File.createSync(exclusive: true)` is a documented Dart API:
<https://api.dart.dev/dart-io/File/createSync.html>.
