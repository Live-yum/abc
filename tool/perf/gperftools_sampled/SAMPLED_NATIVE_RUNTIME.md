# Sampled q0 native wiring (offline implementation)

These new files implement a separate sampled runtime and target launcher. No
application, official allocator runtime, SDK, CI, GitHub, q7 or product arm has
been executed by the offline tests. Header compilation is not provider runtime
validation. The old full-profiler entrypoint, adapter and launcher are unchanged.

## Fixed ABI and metadata

`sample_runtime.h` exports four synchronous C entrypoints: initialize(),
q0(uint64_t Dart gauge time), close(), metadata_json(). Metadata uses
`abc.gperftools-sampled-runtime.v1`, camelCase lifecycle fields and nested
snake_case sample-wrapper fields. The static JSON buffer occupies 16 KiB and is
always NUL-terminated. Shared startup/closed example JSON files lock field
names/types with the Dart bridge. `q0TransportAccepted` is true only after sample
transport, both complete map snapshots, receipt publication, and matching ACK.
It never means maps-role acceptance, completed ownership cycles, precise heap
accounting, full eight-round completion, or application correctness.

The runtime records real PID, output/target/provider observed identity, public
provider checks, call counts, timing, and descriptor cleanup. The runtime's
`observer` FD counters and the wrapper's `sample.output_*` counters are separate.
Startup retains exactly target/library/output FDs, after opening and closing the
launch token. Thus startup opened=4, closed=1, held=3. `close()` releases its own
remaining descriptors and the one-byte ownership probe once. It does not stop
or report state for a full profiler. Repeated q0 consumes no additional sample
API invocation; repeated close never repeats close/free.

## Sealing/build order

`sampled_seal_config.py` is a pure offline identity/header helper. No automatic
compiler or target execution occurs. Call file_identity(target, executable=True),
file_identity(library), output_identity(output), then
render_header(target, library, output, helper_path). Compile the helper using
`-DABC_SAMPLE_SEALED_CONFIG="/absolute/runtime-seal.h"`. After that build, obtain
file_identity(helper) and call render_header(..., helper=actual_helper_identity)
for the launcher header. The launcher requires this separate sealed helper hash;
embedding the helper's own hash inside itself would be circular.

The final helper is normally compiled/linked with the matching official public
C++ header and exact official library. The official path is fixed at
`/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16`; production has no path fallback.
Only the explicitly named `ABC_SAMPLE_OFFLINE_TESTING` compile macro permits the
inert synthetic provider paths used by tests. It does not replace/bypass the
actual provider guard. Clean child environments are required for compilers,
driver and launcher. The old SHA header is copied unchanged; its unused static
functions can be suppressed by `-Wno-unused-function` when compiling this TU.

The launcher verifies target, official library, helper, output and ELF identity;
reserves O_EXCL launch.once; sets only target LD_PRELOAD to the canonical provider,
TCMALLOC_SAMPLE_PARAMETER=524288 and ABC_SAMPLED_DIAGNOSTIC=1; sets sampled helper,
output, hello and ready paths; then fexecve() executes the retained verified target
FD with unchanged argv/PID. No HEAP* variable, full-profiler API, helper preload,
or secondary target is used. Any attempted exec consumes the reservation.
HELLO and READY are `<output>/sampled-hello.json` and `sampled-ready.json`.

## Real public provider guard

At initialization and q0 boundaries, retained target/provider FDs are rehashed
and compared with the sealed SHA/dev/inode/size. Current canonical path metadata,
actual `/proc/self/exe` identity and output identity are rechecked. Current
RTLD_DEFAULT malloc/calloc/realloc/free addresses and the compiler-resolved public
`&MallocExtension::instance` must resolve through dladdr to the same canonical
sealed DSO/base. The returned instance must remain the original object, and its
public GetOwnership must say kOwned for a retained live one-byte allocation from
the verified malloc. The runtime uses no guessed mangled symbol, private
allocator API, vtable offsets or virtual pointer extraction. Ordinary public
virtual dispatch is used by the wrapper and ownership check.

These are current bounded observations, not immutable filesystem or mapping
locks. The loader/dlopen still open canonical paths after launcher checks; paths
and maps can change between observations. Public API identity/ownership checks
corroborate the provider; they do not independently inspect a virtual method's
machine code or freeze the process address space.

## Cut and failure bounds

- q0 is the only cut and is attempted once, on the existing synchronous quiet
  hook. The caller owns the original two-VM/seven-gauge boundary.
- Before/after `/proc/self/maps` each use one preallocated 1 MiB buffer (2 MiB
  total). Available partial bytes are retained as failure evidence where output
  identity permits writing; incomplete maps cannot receive a successful receipt.
- Existing sample_wrapper keeps a fresh empty string, makes at most one public
  GetHeapSample call, and accepts only complete returned bytes strictly below
  1 MiB. Oversized data is never truncated. The returned dynamic string capacity
  is recorded; this post-return limit cannot bound its peak allocations.
- Successful raw sample bytes are `q0.sample.heap`; later maps/ACK failure retains
  them. Existing wrapper failures that produce no bounded publishable raw data
  (exception, empty or oversized return, provider mismatch) retain size/status
  metadata and maps, not a fabricated/truncated raw file. Failed output pending
  files are retained. The existing wrapper was not modified.
- q0 hook limit is 10 seconds. Native ACK allows at most 2 seconds after receipt
  publication, additionally capped by the remaining 10-second hook. Existing
  native poll interval remains 1 ms. Timing checks reject after return and cannot
  preempt blocked API/syscalls. Parent process supervision remains necessary.
- No retry, extra sample, automated q7/product progression, or evidence deletion.

Maps are `q0.sample.before.maps` and `q0.sample.after.maps`. Atomic no-replace
receipt `q0.sample.receipt` contains exactly:

`ABC_SAMPLED_RECEIPT_V1 0 0 PID API_START_NS API_END_NS BEFORE_BYTES AFTER_BYTES q0.sample.heap\n`

ACK `q0.sample.ack` must be a regular owned mode-0600, single-link file containing
exactly `ABC_SAMPLED_ACK_V1 0 0 OK\n`. Preexisting cut artifacts are rejected.
No-replace pending-to-final rename avoids accepting partially published receipt
bytes. ACK publication must likewise be atomic without a transient second link.

## Offline verification

`python3 -m unittest -v test_sample_runtime.py` builds only an API-shaped synthetic
DSO and inert target. It verifies real dlsym/dladdr checks against that DSO,
identity/hash changes, receipt separation, single launch/q0, ACK failure retention,
FD cleanup, fixture shape, environment rejection, output identity and ownership
rechecks, and no truncation of oversized samples. The synthetic provider uses
libc-forwarding scaffolding only in its test file. It is never an official
allocator runtime test. Compile-only checks against the locally materialized
matching official header are an additional separate verification.
