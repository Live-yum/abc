# Native launcher and two-cut hook contracts

These are offline-testable components for the approved design SHA-256
`9f5eadc5e092e1ed49f91415d5835cc14091cbed77218a251b7a00d344ed5dae`.
They have not run a real application, Flutter SDK, workload, or profiler.
The tests compile inert ELF/DSO fixtures and a provider stub; no fixture is
evidence of real allocation capture or of actual Flutter startup.

## Build and identity contract

`target_launcher.c` and `quiet_dump_linux.c` require the same generated
`ABC_SEALED_CONFIG` header. There is no default target path or runnable live
configuration. It defines `abc_sealed_target`, `abc_sealed_library` as
`struct abc_file_identity`, and `abc_sealed_arms[2]` as
`struct abc_arm_identity`, declared by `native_identity.h`. Each file is bound
by absolute canonical path, device, inode, byte length, and SHA-256. Each arm
has its exact output directory device/inode and name, either `probe-only` or
`product-with-ownership`. Output must already exist as a private, owned 0700
directory. The same launcher and helper bytes serve both arms; the clean
driver sets only `ABC_STACK_ARM` to select the sealed arm. The supervisor
must prepare/seal these paths after verifying official package and build
identity. It must not provide an arbitrary path from target arguments.

Outside the explicitly compiled `ABC_OFFLINE_TESTING` fixture mode, the
launcher permits only `/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16` as
the preload path. Neither tool installs anything. The official package,
version, build ID and sealed helper/launcher hashes remain external start
gate obligations, not facts inferred from a filename.

The clean driver must remove profiler/loader environment variables before
starting the launcher. A launcher cannot undo a library that the loader
already injected into its own process. It then filters LD_, HEAP, TCMALLOC,
CPUPROFILE and MALLOC prefixes and stale ABC_STACK_OUTPUT, while preserving
the original workload environment, display, working directory, engine
switches, and every argv byte including argv[0]. It adds only the reviewed
profile environment and fixed output path to the target exec. In particular,
HEAPPROFILESIGNAL is absent, and all eight automatic/cleanup/mmap flags are
zero. The test DSO's constructor runs in the inert target and demonstrates
target delivery; compiler/driver/analyst test processes receive clean envs.
The launcher rejects an entry environment containing LD_PRELOAD or LD_AUDIT,
including an empty value, before target validation or token reservation.

The launcher reserves `launch.once` with O_EXCL/O_NOFOLLOW and fsync before
fd-bound execve. The fd binds the exact target ELF inode and preserves PID.
The token survives every failure after reservation and prevents internal
three-attempt Flutter retries from creating a second target. No executable
is renamed/copied by the launcher. The library remains loaded by its fixed
path, not by fd; the audited official root-installed file is assumed stable
between launch validation and loading, and the live target provider gate is
still mandatory. Actual Flutter asset lookup with the preserved launcher
argv[0], original hello, and engine-switch interpretation await real CI.

## Hook contract

`quiet_dump_bridge.c` is a bounded synchronous state machine.
`quiet_dump_linux.c` adapts it to the Linux provider and file operations.
The adapter has no constructor and never calls HeapProfilerStart or
GetHeapProfile. Startup resolves malloc/calloc/realloc/free and
Dump/Stop/IsRunning, requiring the same expected DSO path and base, checks
the target and output identities, validates profile env, then clears those
variables for future children. Full provider identity is rechecked at cuts.

Call `abc_quiet_initialize()` before the original hello; verify ABI 1 first.
The only allowed observation calls are `abc_quiet_after_gauge(0, dartTimeUs)`
and then `abc_quiet_after_gauge(7, dartTimeUs)`, after each original released
quiet-end gauge write/flush and before the subsequent original GC. Caller
integration owns the phase and original sequence checks; the native core
enforces cycle/order/repetition. Use ordinary synchronous FFI, not leaf.
The reasons are fixed `q0.released-quiet-end` / `q7.released-quiet-end`.

Two fixed cut slots and two reusable 1 MiB maps buffers are allocated in
static storage before hello, reported as observer bytes. Each cut reads a
complete bounded maps file before/after the Dump, saves the original bytes,
then publishes a receipt only after Dump returns. The external supervisor
must independently verify the heap, four counts, maps and complete file
inventory before ACK. Native Dump's void return is never treated as proof
of completeness. A failed cut consumes its slot, records its first error,
and stops; no retry, third dump, GC, or signal cut is possible.

The maps buffers contribute exactly 2,097,152 static bytes. Metadata also
reports the native context plus runtime structure size, and three retained
observer FDs after successful initialization: target ELF, allocator DSO,
and output directory. Transient maps/provider/receipt/ACK FDs add observer
work during the hook. These are instrumentation resources in the original
FD/RSS samples and must not be attributed to product handle/memory growth.
Stop closes retained FDs once, including after a profiler Stop failure;
partial initialization closes everything acquired so far. A failed close
records errno separately, with separate close-attempt and successful-close
counts. Further Stop or initialization calls cannot close a reused FD or
open a second set. The tests verify that a newly reused sentinel FD survives
repeated cleanup, and preserve failed-cleanup evidence.

Call `abc_quiet_stop()` immediately on entry to the original outer finally,
including after successful final quiet/gauges and on failure. It is
idempotent: exactly one actual Stop call, then IsRunning must be false.
The first cut error and a failed Stop are preserved separately. No atexit
handler or final dump is added. A killed/stuck target cannot execute its
finally; independent supervisor cleanup and unexpected-exit-file checks
remain necessary. A failed startup provider gate never invokes an
unverified Stop pointer; such a run is invalid and any exit profile is kept.

`abc_quiet_metadata()` returns ABI-stable declared C fields with native
CLOCK_MONOTONIC nanoseconds for hook/Dump/ACK/Stop and a separate caller
Dart microsecond field. No cross-domain subtraction is valid. ACK end is
when the target observed the externally approved ACK, a bound on external
validation completion rather than the supervisor's exact timestamp.
The Dart integration must copy/serialize metadata only after observation.

## Receipt protocol and limits

Files are `q0.before.maps`, `q0.after.maps`, `q0.receipt`, `q0.ack`, and q7
equivalents. Heap names are exactly `heap.0001.heap` and `heap.0002.heap`.
Complete receipts are atomically published with renameat2 NOREPLACE from a
new `.pending` file. Existing names, symlinks and partial failure files are
never overwritten. Each ASCII receipt is at most 512 bytes:

```
ABC_HEAP_RECEIPT_V1 <slot> <cycle> <pid> <dump_start_ns> <dump_end_ns> <maps_before_size> <maps_after_size> <heap_basename>\n
ABC_HEAP_ACK_V1 <slot> <cycle> OK\n
```

ACK must be an exact regular non-symlink bounded file. The target waits at
most 2 seconds within the total 10-second hook budget. These in-process
checks cannot interrupt a blocked Dump or IO operation; the independent
supervisor owns hard timeout enforcement and safe process-group cleanup.
No RLIMIT_RSS or security-setting mutation is introduced.

## Offline verification

Run `python -m unittest discover -s memory-ownership-next/gperftools-application-contracts -p test_native_contracts.py -v`
from the task root. Tests compile with `-Wall -Wextra -Werror`, check exact
argv/environment/PID and one exec among three attempts, byte tampering,
symlinks, wrong output identity, both arms using identical launcher bytes,
fixed two-cut ordering, map caps/errors, late/bad ACKs, provider changes,
timeouts, normal/abnormal Stop, failed cleanup evidence, exact known file
bytes and receipt atomicity. The helper's real provider startup is compiled
but intentionally never run. Full Linux module/build-ID/map completeness,
Flutter init, all original 52 gauges / 17 VM calls, and an actual profile
remain separate application-start gates.
