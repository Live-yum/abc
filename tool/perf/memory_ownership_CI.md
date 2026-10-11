# Fixed-product memory ownership diagnostic

This is a diagnostic derivative of product commit
`9d4cd5a0f9db03042a3986689fea374ba92d78b8`, not a product optimization.
Its workflow runs only on `codex/memory-ownership-protocol-9d4`, on the first attempt.
It does not subscribe to pull requests or update shipping Web artifacts.

The original source/runtime verifier runs against a separate pristine 9d4
checkout. The derived checkout is verified against an exact changed-file
manifest, including all unchanged product blobs and executable modes. Its C
owner getters are explicitly a diagnostic overlay; its modified native sources
are not asserted to match the original shipping runtime provenance.

## Gates before the two observations

Pure Python tests check both the new schema and the original validators. Each
required discovery pattern must execute a nonzero test suite. The original
counter-disabled validator continues to reject counter-enabled measurements.

Official Dart formatting is applied only to evidence copies. The workflow
archives those copies and their patch, then checks the unchanged checkout and
stops on formatting differences. Static analysis, native contracts, focused
Dart tests and a separate tiny Profile image-callback smoke must all pass before
either measured process starts. Preflight failures retain evidence and do not
start the measurement step.

The existing default and opt-in focused Dart processes each export a small
contract fixture using the same lifecycle producer as the measured entrypoint.
The unchanged strict Python cycle consumer accepts eight completed idle slots
and rejects the interrupted seven-completed/one-running fixture. Both real Dart
outputs must match before either memory arm starts. These fixtures are protocol
contracts, not memory measurements.

This is the explicitly corrected group after run `38134933645`. That original
run completed only the idle companion process and was rejected because its
producer used `idle`/zero completed cycles while the strict consumer required
`completed`/eight. Its measurements and failed result remain separate and are
not combined with this group; the product process was never started there.

Native gates check default-OFF exports and circuit object code against the
fixed base, reject OWNER=ON/PERF=OFF, exercise invalid/censored ABI values and
unsupported libc paths, then test the actual Profile library with the small
repository-authored WLD. The real CMake cache, generated Ninja target flags,
symbol exports and ABI return values must prove both options ON. Seeding a
cache option alone is not proof that Flutter preserved it.

## One bounded group

One runner invokes two fresh processes serially: `probe-only`, followed by
`product-with-ownership`. Both use the same Profile target and compile-time
opt-in; a runtime environment variable selects the arm. All three actual
application/native binaries and the separate allocator helper must have equal
hashes between arms. Each arm has a 900-second total limit, including a
300-second build/hello limit and 600 seconds after the hello; the group has a
2000-second bound. There are no retries or parallel arms.

The hello records only source/arm identity and the owned application PID. The
runner verifies UID, process ancestry, process-group identity and start times
while the new process is alive. Before the first gauge or schedule origin, the
app waits at most 60 seconds for a new atomic READY acknowledgement. The runner
captures the actual build/code, verifies source/ABI identity and equal second-arm
binaries, then acknowledges; a mismatch cannot start that arm's gauges. One
bounded executable hash through the already verified child's proc directory
also binds the live executable to the recorded bundle; it retains no path or
memory map and closes its temporary descriptor before acknowledgement. Code is
checked again after completion. It adds no periodic external memory sampler.
VM service authentication URLs are redacted before logs are persisted. Raw
diagnostic and original OS/frame journals remain separate artifacts; actual
code has its own small artifacts.

The product arm reuses the unchanged generic eight-cycle lifecycle, including
its cancellation, reset, save/reopen, drain and quiet periods. This is generic
control/lifetime coverage on a public WLD. It does not supply NPC/player
movement, claim autonomous original-world CPU execution or add ROM/Pong work.

The probe-only arm derives idle deadlines from the pinned 9d4 report
(`memory_ownership_schedule.json`). It preserves all full quiet periods and
records overruns rather than shortening them to meet historical deadlines.
The schedule has 17 original VM helper slots and 52 gauge locations. Seventeen
slots does not imply seventeen allocation-profile RPCs: the existing helper
deduplicates live isolate groups; successful and exited-group calls are
reconciled against bounded transport telemetry. The diagnostic adds no GC
helper calls, heap snapshots, allocator trimming or cache eviction.

## Interpretation

The new report is `abc.memory-ownership.v1`, explicitly counter-enabled with
owner ABI 1. Native counters, scalar Dart owner/transport/lease gauges, image
handle balance, image-cache counts, local FD categories and allocator fields
have their own capture intervals. Cross-source reads are not atomic. A
non-atomic RSS/high-water disagreement retains the original measurements and
warning; same-source OS and heap invariants remain strict.

Saturated native byte counters retain their censor mask. Unsupported helper or
observer data is null/unavailable, never zero-filled. FD numbers, resolved
paths and target strings are not included. Image counters retain no `Image`
objects and do not estimate exclusive physical GPU/CPU residency. The fixed
52-slot libc capture buffer is 6656 bytes and is recorded as observer overhead.

Logical owner capacities and allocator totals overlap; they cannot be added to
reconstruct RSS. The two bounded processes cannot establish a long-term
plateau, prove a leak, or uniquely assign causality. Evidence validity is
reported separately from stability and performance acceptance. Every prior
product CI failure and original raw measurement remains unchanged.
