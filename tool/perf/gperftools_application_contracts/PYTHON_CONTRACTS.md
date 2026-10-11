# Offline Python supervision and evidence contracts

This directory implements reusable offline contracts, not an application runner.
There is no executable Flutter/profiler/SDK/WLD entry point here. The approved
application design SHA is
`9f5eadc5e092e1ed49f91415d5835cc14091cbed77218a251b7a00d344ed5dae`.
No real pair is authorized or evidenced by these tests.

## What is checked

- `application_contract.py`: bounded no-follow regular-file reads; upstream
  `<1 MiB` heapprofile grammar; all four integer bucket/header sums; zero-live
  historical buckets; executable mapping for every required PC; stable complete
  pre/post map sets; receipt identities and the two approved q0/q7 slots; exact
  official raw integer and stack accounting; resource inventory; original OS
  log consumption; separate arm and legacy-validator outcomes.
- `bounded_supervision.py`: 300-second build/hello, 600-second post-hello,
  900-second arm, 2,000-second pair, 60-second identity, 10-second hook and
  2-second nested ACK deadlines. The two modes for each endpoint share one
  120-second analysis allowance and the enclosing arm/pair deadline. The first
  failed arm prevents the second; names are `probe-only` and
  `product-with-ownership`. There is no retry and no automatic pair launcher.
- The supervisor creates a fresh session/group for each ordinary tool or stub.
  `waitid(WNOWAIT)` retains the owned leader while TERM then KILL are sent. Only
  then is it reaped. Subsequent group probes use signal 0 and never send a real
  signal. Cleanup failure is a recorded failure alongside the original error.
  A 1.5-second cleanup reserve is inside the supplied deadline, never added to it.
- `TargetProcessIdentity` retains a `/proc/PID` directory FD and the kernel's
  `/proc/PID/exe` FD, checking same UID, owned PGID, starttime, exact executable
  path/size/SHA before and after inspection. It never launches or signals a PID.
  Its test binds an ordinary Python stub only. A real target's PID must come from
  the independently audited original hello and owned-group evidence.

`clean_tool_env` and `run_bounded` are explicitly for offline stubs, ordinary
compiler and analyst tools. They are **not** a Flutter-driver interface: they do
not preserve SDK CI variables or workload variables. Future authorized driver
integration must use the separate `prebuilt_contract.py` driver environment and
loaded-entrypoint contract, preserving its reviewed original variables. This
prevents accidentally claiming the generic stub runner is ready to launch the
application.

## Immutable dependencies and reproducibility

Only two fixed sibling layouts are accepted: authoring
`gperftools-preflight-index/` and repository `tool/perf/gperftools_preflight/`.
No environment variable, PYTHONPATH search, network fetch or package installation
selects these dependencies. Both source hashes are checked before import:

- `profile_contract.py`: `07cee15d0c0c3f6d3be56b60f2339fd419def81d3fcaea4236660468a9f25d79`
- `pprof_raw.py`: `3bc28fc584db560c865f7f7aa8e3acc72debfe6e40257e8b861367e320093646`

The historical q0 and q7 heap/raw fixtures are byte-for-byte copies of retained
small-contract evidence from `gperftools-preflight-evidence-ac4596f`.
`fixtures/fixture-manifest.json` records their origin, size and SHA. The maps
fixtures are explicitly reconstructed offline `/proc/maps` syntax examples,
not captured before/after application maps. They do not prove a real runtime
bracket or actual module identity. The stub script generates only synthetic
process/output faults.

## Receipt and ACK protocol

Native and Python contracts share a single bounded ASCII line, at most 512 bytes:

```
ABC_HEAP_RECEIPT_V1 <slot> <cycle> <pid> <dump_start_ns> <dump_end_ns> <before_bytes> <after_bytes> <heap_basename>\n
ABC_HEAP_ACK_V1 <slot> <cycle> OK\n
```

Slot 0/cycle 0 uses `heap.0001.heap`, `q0.before.maps`, `q0.after.maps`,
`q0.receipt`, and `q0.ack`. Slot 1/cycle 7 uses `heap.0002.heap` and `q7.*`.
`validate_cut` parses the receipt, both complete raw maps and the heap before
an ACK may be published. The writer exclusively creates `q0.ack.pending` or
`q7.ack.pending`, completes unbuffered writes and fsync, then atomically links the
finished file to the final ACK name without overwrite. Successful publication
removes pending; write/sync/link failure retains pending evidence. Existing final
ACKs and symlinks are never replaced. Runtime allowlists permit only the pending
name corresponding to an explicitly declared final ACK; final sealing still
requires only the completed names. The maximum ACK wait is two
seconds and is nested inside the full ten-second hook. Native monotonic times
and Dart gauge/Timeline times remain distinct clock domains; no subtraction
across domains is performed here. Separate native timing metadata retains
entry/dump/ACK/exit times.

## Completeness and attribution

Heap files are strictly smaller than the fixed upstream 1 MiB buffer. Every
bucket and all four live/cumulative sums must agree with the header. Required
PCs must map to executable ranges. All stable pre/post map entries, including
anonymous tail entries without a bucket PC, must appear in the dump; dump entries
must be known in the bracket. File-backed executable sets must be identical
across all three sources; `/proc` device identity must be stable. This catches
whole-line truncation that trailing newlines cannot detect. Anonymous/JIT/kernel
frames remain raw mappings and are never labeled ELF/product functions.

The official raw reader retains its independent **16 MiB** cap. The child's
64 MiB RLIMIT_FSIZE is only a last-resort output safety guard. Source buckets are
compared against every raw stack and exact integer count after the pinned
upstream caller-PC decrement and allocator-frame-removal/merge rules. Historical
zero-live stacks cannot disappear just because totals remain equal. Raw symbol
text is used to reproduce official tool behavior, not to establish exact ELF
function identity; nearest-symbol names are not accepted as attribution proof.

`validate_module_records` checks the inventory for every executable file,
per-module 64 MiB bound, SHA/build ID, PT_LOAD extents, page/load-bias alignment,
exact symbol extents and explicit matching-debug availability. It explicitly
returns `loadedIdentityProven: false`: records alone do not bind actual retained
module bytes or certify the real loaded process. `normalized_file_pc` yields
only `(ELF build ID, ELF virtual offset)` for an exact executable PT_LOAD extent.
A future integration must obtain and seal all actual module identities and
provider evidence. Missing matching private Flutter symbols means only precise
module/address reporting, not a VM/Skia/cache subdivision.

## Resource polling versus sealing

`check_sidecar_caps` is the runtime **metadata-only** upper-bound check. It permits
zero-byte in-progress heap/maps files until their receipt arrives and does not
open or hash payloads. It checks all retained bytes (256 MiB), exact expected-file
allowlists, maximum two heaps per arm/four per pair, `<1 MiB` heaps, `<=1 MiB`
maps and `<=16 MiB` raw files. The final `inspect_sidecar` pass requires completed
nonempty evidence and hashes each retained payload once. It does not discard
files or discount actual disk use for duplicate content; duplicate SHA references
are recorded for later explicit storage deduplication. Partial/oversized evidence
is left in place on failure.

`OsJournalTail` incrementally consumes the existing sequential `os-N.jsonl`
chunks, retains global sequence across original rotations, and reads at most
1 MiB per sweep. It takes no new RSS sample. Observed RSS above 2 GiB fails;
exactly 2 GiB is at the stop line. This is not a kernel RSS limit and may overshoot
between the original sampler's writes. Original JSON 4 MiB and line 64 KiB caps
remain. Missing/stalled writes remain subject to the enclosing hook/runtime
limits. Finishing requires the original chunk list in order.

## Report semantics and test command

`arm_completion` carries the original validator report and its raw-byte SHA
without rewriting its outcome. `workloadComplete`, `heapFilesComplete` and
`stackAttributionAvailable` are separate from the original image-coverage failure.
Status 3/interposed libc null values remain null. No product net-leak, individual
object identity, plateau, remediation or original glibc reconciliation is claimed.
The caller must supply actual validated workload completion, including the
unchanged eight cycles/52 gauges/17 VM requests and original image failure.

From this directory:

```
python -m unittest -v test_ack_atomic test_application_contract test_bounded_supervision
```

51 focused offline tests pass (the historical v1 run contained 45). Coverage includes actual historical raw/heap
fixtures; whole-line missing buckets/maps and zero-live raw records; counter
swaps; missing/changed providers/maps/required PCs; size caps; malformed receipt
and late ACK; incremental/rotated OS logs and RSS stop; partial evidence; fast
failure; fast oversized output; hanging/TERM-ignoring stubs; retained-child
cleanup; already-reaped leader refusal; shared deadlines; and first-arm-stop.
These tests are offline contract evidence, never actual application acceptance.

The real integration-test hook is not wired by this offline Python package.
The separate native stub contract is not a real profiler provider adapter.
Passing these contracts does not prove an application launch, its loaded SDK/
engine-switch behavior, complete real profile/maps, or real target module identity.
Those remain explicit startup blockers until the separately authorized integration
is implemented, audited, and actually exercised.

The ACK publication revision adds six tests, including a bounded cross-process
writer that pauses after eight pending bytes while the actual native wait_ack
reader remains waiting. Final ACK is absent until complete fsync/publication.
Write/fsync failures and existing ACK/pending symlinks preserve failure evidence.
The historical source manifest and 45-test log are unchanged; the revision is
recorded separately in `python-source-manifest-ack-v2.json`,
`python-ack-test-results.txt`, and `ack-publication-fix.patch`.
