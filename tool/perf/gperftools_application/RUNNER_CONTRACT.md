# Fixed application capture runner

This new diagnostic workflow does not run locally during authoring. Offline C and
Python stubs do not prove Dart compilation, real FFI, Flutter startup, profiling,
WLD completion, image coverage, or performance. The first authorized CI can fail
at any gate and must preserve that failure without rerunning either application.

## Source and startup

The new source gate checks the entire independent 886-file 9d4 product checkout,
the entire independent 5a161bf inherited diagnostic checkout, the full new Git
tree and every actual worktree byte/mode. Only the original integration harness
may change among inherited files; new paths are diagnostic tooling, support and
the one new workflow. The old workflow may be omitted. A separate source manifest
excludes its own recursive hash, while its actual Git blob and independently
recorded SHA bind it. No product, original cycle/ROI/input/schedule, scalar
observer, 17 VM request, 52 gauge, GC, or old validator code is rewritten here.

The immutable ac459 package gate is pinned by its exact source-manifest SHA and
code hashes; its own inventory check verifies all nine frozen files. The workflow
runs only the package-identity portion. It does not run another synthetic capture.
Offline contracts, normal SDK setup, non-mutating official formatter output,
analyze, original native OFF equivalence and helper construction precede the one
application pair. Formatter output alone is not a format-clean claim.

One explicit original integration build uses pinned Flutter 3.47.6 revision
5fc346839b5d0eef006ed8404392afb4dfae428d, original defines and flags. A preexisting
application bundle/cache is rejected. The same native sealed launcher, target,
libapp, engine and both helpers are reused for both arms. The launcher takes a
per-arm O_EXCL token, retains target identity and execs the original executable
with Flutter's original argv/engine switches. Compiler, driver and analyst
retain original CI/workload variables but have profiler/loader variables removed.
Only the target receives tcmalloc/preload and the fixed automatic-dump-disabled
environment. Local actual entry and later GitHub run attempts are rejected.

Before READY, the original hello and native successful provider/running
initialization are bound to the actual owned target PID, retained proc/executable
FDs, source/build hashes, launch token and module maps. All actually loaded
file-backed executable modules are retained and verified by device/inode, SHA,
GNU build ID, PT_LOAD, load bias and available exact symbol extents. Matching
embedded or already-installed build-ID debug information is retained; no debug
information is downloaded and no nearest symbol is invented. Absent function
symbols remain explicit unknown stack buckets. Every module is at most 64 MiB;
a large rendering DSO can therefore stop the run before WLD, even when no later
heap stack would have used it. This cap is not expanded or silently skipped.

The original engine is loaded lazily. It is sealed and its ELF bytes retained
before READY, explicitly marked not loaded if absent from startup maps. Only
this presealed engine may first appear at an endpoint. Its actual maps must then
match the retained device/inode and PT_LOAD/load bias within the unchanged ACK
budget. No engine preloading or extra application operation is introduced.
Another new or changed executable mapping fails the pair.

## Budgets and evidence

The first arm includes explicit build and hello in 300 seconds. Runtime is 600,
arm 900, pair 2,000, startup identity 60, hook 10, ACK 2 and each profile's two
integer analyses together 120 seconds, always intersected with remaining budgets.
Analysis runs within the same pair. Each command is single attempt and uses a
fresh owned process group. WNOWAIT retains its leader until TERM/KILL cleanup;
no numeric group is signalled after reap. Both original application success and
owned-group cleanup must complete before another arm starts.

The external hook watchdog incrementally reads the original synchronously
flushed ownership gauge journal. Observing q0/q7 released-quiet-end starts its
10-second budget, so a Dump that hangs before publishing a receipt is stopped.
This has observation/polling latency (10 ms nominal poll), not a kernel hard
timeout. Native elapsed checks retain their exact 10-second interval on return.
No extra gauge, RSS sampler, VM request or GC is introduced. Only the original
os-*.jsonl samples are incrementally consumed for the observed 2 GiB target RSS
stop line; this is not a hard RSS limit and sampling/writing can overshoot.

Heap/maps completeness and prebound module checks precede atomic ACK-v2
publication. The supervisor conservatively requires ACK within two seconds of
native dumpEnd; native itself starts its two-second wait after receipt publication.
That stricter supervisor check does not add time. Native/Python comparisons are
permitted only after verifying both use the same Linux CLOCK_MONOTONIC; Dart's
Timeline timestamps are compared only with other Dart timestamps. Original gauge
write/flush receipts are also checked before the Dart hook's gauge timestamp.

There are four endpoint heaps, each strictly below 1 MiB, and eight official raw
integer files, each at most 16 MiB. Exactly eight endpoint bracket maps plus two
retained startup identity maps are allowed: ten retained maps, at most 1 MiB
each and 10 MiB aggregate. Each startup gate also rereads maps once to check
stability after ELF binding; those two bounded consistency reads are not retained
as extra records. Thus a complete pair performs twelve explicit observer proc-maps reads and
retains ten observer maps files, with no additional workload endpoint. Profiler
internal MAPPED_LIBRARIES collection and any runtime/unwinder maps reads are
outside this explicit observer count; it is not a total system-call count. All new sidecars,
including startup maps, modules, symbols, helper binaries, raw files and logs,
share the 256 MiB aggregate cap. Module bytes are deduplicated by SHA.

Auxiliary commands retain RLIMIT_FSIZE=64 MiB and core=0. Flutter build/driver
and their application inherit the original file-size limit and only disable core
dumps, preserving the original ~406 MB WLD save/reopen operation. Application
stdout plus stderr share the original 8 MiB accepted log budget; new auxiliary
logs keep the 2 MiB per-stream limit. Sidecar file caps are observed separately,
with no truncation or deletion of failed partial evidence.

## Outcomes and artifact categories

Every stage failure stops the pair. Control failure forbids product startup.
There are no automatic second applications, rebuilds, tool retries, extra dumps,
or larger buffers. Separate workloadComplete, heapFilesComplete and
stackAttributionAvailable facts do not override the original validator. The
original guarded image failure remains exactly
`ownership: product image callback observation never fired`; it can coexist with
completed endpoint capture. The overall workflow remains failed when original
acceptance fails. No cross-arm subtraction, individual-object survival,
retaining-owner claim, original glibc reconciliation or performance verdict is
produced.

Artifacts are natural evidence categories: small summaries and indices, original
scalar/raw evidence per arm, heap/maps/receipts per arm, one official integer
analysis per arm/endpoint/mode, complete command logs, and sealed ELF/package
bytes. Large code evidence remains preserved even when a small artifact consumer
cannot materialize that category. No arbitrary byte splitting is used.
