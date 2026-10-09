# Fixed-source Native READ AOT paired diagnostic

This diagnostic isolates one Dart wrapper change while both arms use the same
unchanged C engine. It runs a complete **BAABBA** sequence: six fresh processes,
eight original-world cycles each. It is host-wrapper evidence, not Flutter UI,
frame timing, application-owner-isolate, or long-run leak certification.

The initial local ABBAAB study remains separate, including its first-process
interference. A subsequent local BAABBA attempt lost its executor before a terminal
record: eight cycles in its first process survived, but cancellation recovery and
the full six-process study did not finish. Its exit code and cause are unknown.
That partial attempt is neither a product crash nor a successful confirmation.
This CI study starts all six processes anew and substitutes none of those samples.

## Reviewed inputs and derivation

- Product source: `1dac431c45f82bcc298ea4bbce6abebb126dfc33`, checked out separately
  and required to remain clean. Production `lib/` is never modified by this diagnostic.
- Baseline binding SHA-256:
  `5223b0ca10cdb243568927fd7ab911302438a7324ca7a7c456de913ef2c83aa2`
- Candidate binding SHA-256:
  `478fcac164a132beee8e138046274bdd7156e633ceb080e6ee774e6b1bb19411`
- `candidate_binding.dart.txt` is the exact reviewed Dart source, stored as a text
  fixture so broad repository Dart analysis does not mistake it for a stand-alone
  library. Only B's temporary prepared copy receives these bytes. The other three
  imported product Dart files must be byte-identical in A and B.
- Original public Computerraria WLD: 405,983,441 bytes,
  `55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.
  The fixed product's existing `tool/computerraria_inputs.py` retrieves and verifies
  the original pinned MIT public archive. No private world is accepted.
- Original Pong: 2,288 bytes,
  `d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d`.
- The fixed product's official setup action installs Flutter 3.47.6 and verifies
  revision `5fc346839b5d0eef006ed8404392afb4dfae428d`; the harness requires Dart 3.13.5.
  Product dependencies use its existing enforced lockfile. The tiny standalone
  package uses the committed enforced lockfile and cached exact ffi/crypto dependencies.

`source-manifest.json` pins the human-readable workflow, runner, worker, fixture,
lockfile and contracts. Runtime `manifest.json` additionally pins the copied
product sources, SDK/compiler inputs, actual native library and original fixtures.

## CI build and execution

The isolated workflow runs only by manual dispatch or a matching push to
`codex/native-read-paired-diagnostic-1dac`. It has `contents: read`, disables checkout
credential persistence, does not cancel other runs, and has no pull-request trigger.

The workflow builds the fixed product's native CMake target once using clang,
Ninja, Profile, `-O3 -DNDEBUG`, and `ABC_PERF_COUNTERS=OFF`. The official provenance
script records the clean source commit, source hashes, actual generated compiler
flags and resulting `.so` identity. A and B share those exact newly built bytes.
It then compiles each actual pure-Dart wrapper once with the same SDK. No local
AOT file or local `.so` is copied into CI, and no claim of identical local/CI
compiler output is made.

Only one measured process runs at a time. Each process has a 600-second bound;
the first failure, timeout, signal exit or invalid report stops the study. Partial
logs and reports remain, later slots are explicitly not run, and original-source
hash verification is attempted during failure cleanup. There is no single-arm
resume, replacement sample, outlier exclusion or absolute performance threshold.
Pairing is B1–A2, A3–B4, B5–A6; differences are B minus A.

Each cycle opens the original WLD, checks its actual source SHA and full graph,
runs the existing 48-signature physical CPU program and real two-pixel display
program, then loads original Pong and observes twelve 128-clock batches of real
RAM/stack/display changes. It closes the session, verifies old-handle rejection
and scratch cleanup, and waits 1,200 ms. After the eight measured cycles, one
first-hash-yield cancellation and full reopen/query/close verify bounded recovery.

The parent sampler reads `/proc` every 100 ms and at acknowledged boundaries.
The worker waits for the boundary sample before proceeding, so closequiet samples
cannot race the next open. RSS, HWM, smaps RSS/PSS/USS, FD count and thread count
remain separate. Native allocation counters are unavailable and recorded null.
There is no VM service, AllocationProfile, forced GC, malloc_trim, cache dropping
or system-limit adjustment. Existing progress is sampled at 20 ms for approximate
hash/decode/compile intervals; exact full-open duration is measured directly.

## Evidence and limitations

An `always()` finalizer preserves raw stdout/stderr, every `/proc` sample, partial
or complete reports, manifests, build logs, compiler versions and source/native
provenance. An explicit final status rejects any incomplete study. Uploads exclude
the WLD, archive, AOT executables, shared library and native scratch. As with any
CI workflow, total runner loss can prevent artifact upload; absent terminal
evidence must remain unknown/incomplete, not be inferred as a crash or success.

The independent units are three processes per arm, with seven warm observations
inside each process. First-open means process-cold, not cold OS page cache. `/proc`
reads are sequential rather than atomic, and 100 ms sampling can miss short peaks.
Eight cycles cannot prove a permanent memory plateau. Phase timers carry sampling
error. Report this job's internal A/B comparisons; do not pool its absolute values
with local runs or earlier Flutter/VM-probed observations.

Local review checks are Python contracts, source-manifest verification, YAML and
shell syntax validation. The full CI build and full-world run remain separate
stages and are not claimed passed before their actual results exist.
