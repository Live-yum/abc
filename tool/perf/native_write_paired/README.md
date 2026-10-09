# Fixed-source Native WRITE paired diagnostic

This is a six-process **BAABBA** comparison of the actual pure-Dart AOT host
wrapper. A is product `661f9f17531e87f0b3f9f7028d70a94814c21234`, tree
`9ff4ca286afa3e545901c498de167ee0c5dfc61d` (828 tracked files). B changes only two
kind-2 WRITE branches to borrow C memory through synchronous `writeFromSync`
before acknowledgment. Kind-3 RESULT continues to copy retained data.

This study covers the streamed wrapper. It does not measure Flutter frames,
application-owner FIFO performance, or the byte API. The separate 20 new contracts
cover both pumps, WRITE lifetime/failure/cancellation, retained RESULT ownership,
and the real production owner queue. No new result is claimed until CI actually
finishes. Earlier READ studies, local interruptions and Flutter memory diagnostics
remain separate evidence; their absolute numbers are not pooled with this run.

## Fixed inputs and candidate

- Baseline binding SHA-256: `424ef0660b6a9363a1957f058a6cf5ec34be9946154370acff2657bd566bae09`
- Candidate binding SHA-256: `7b423084073971f6f1c903093be1554e168015b704c2bcadf265bde27f7cc014`
- Public Computerraria WLD: 405,983,441 bytes,
  `55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`
- Original Pong: 2,288 bytes,
  `d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d`
- Physical CPU/display fixtures: product `native/fixtures/computerraria/programs.json`,
  `488395bb26e3aa4422c4b9415410773cd3e78f8da8cbbe9626d434b4527ad86c`
- Official Flutter 3.47.6, revision `5fc346839b5d0eef006ed8404392afb4dfae428d`,
  Dart 3.13.5. Product and standalone dependencies use enforced committed locks.

`source-manifest.json` pins every human-readable diagnostic file and the three
contract fixtures. The candidate binding and tests are text fixtures; they are
copied only to temporary CI candidate directories. The fixed product checkout
remains unchanged. `prepare_contracts.py` copies only the 828 tracked files,
then applies the one binding and three tests. It never copies baseline
`.dart_tool`. After normal CI pub resolution it verifies that `terraforge` resolves
to the candidate root and that its binding and tests retain the exact reviewed
hashes. Format, analysis, all 19 stub contracts and the one real owner contract
must succeed without skipped tests before measurement. A failed format gate also
retains official formatter `--output=show` output for the binding and two Dart test
files, without modifying them or continuing to measurement.

## Prespecified workload and budget

Six fresh processes run sequentially as B1, A2, A3, B4, B5, A6. Pairing is
A2/B1, A3/B4, A6/B5, reporting B minus A. Each process runs these four scenarios
once, in this exact order:

1. OFF/reset: open original, run bounded physical correctness, close and reopen
   the original WLD, verify pristine state, exercise the reopened CPU/display.
2. ON/reset: the same operations with optimization explicitly enabled.
3. OFF/save-reopen: open original, run bounded physical correctness, save to an
   independently hashed lease, close, reopen that lease, verify saved physical
   state, exercise the reopened CPU/display, close and release the lease.
4. ON/save-reopen: the same save operations with optimization explicitly enabled.

There are exactly eight measured imports and two SAVE operations per process:
48 imports and 12 saves across 24 scenarios. No new cycles are added. After the
four measured scenarios, the retained hash-yield cancellation and full
reopen/query/close run once as a separate recovery check. Every process is bounded
at 600 seconds; at most 3,600 seconds of measured-process execution is admitted.
The workflow keeps the 95-minute job cap, including build/setup and evidence
collection. First failure, timeout, signal or invalid report stops further
process launches. Existing raw files are retained, later slots are notRun, and
original-source rehash is attempted even on failure. There is no single-arm
resume or replacement, outlier exclusion, or absolute performance threshold.

The first original open is process-cold. All later opens, including reset and
saved reopen, are warm. Verification reads the WLD and warms OS file cache; cold
never means a cold OS page cache. Three processes per arm are the independent
units. The four different scenarios are compared by matching scenario and phase,
not treated as independent replicates or pooled into one latency claim.

## Correctness and ownership

Each initial open verifies the source SHA, full graph identity and default OFF.
Each mode executes the same 48-signature real CPU fixture, physical display fixture,
and unchanged Pong with twelve 128-clock batches. CPU/RAM must advance in both
modes. OFF correctly produces a dark display under game rules; ON must produce
the two target pixels and moving Pong frames. Native `reserved` flags are 4 for
OFF and 14 for ON on this qualified topology; SAVE uses its separate result-kind,
result-count and lease contract.

Passive snapshots cover ready, all 48 fixture RAM addresses, 16 Pong RAM words,
256 stack words, the 2,288-byte Pong ROM range, and all 3,072 physical pixels.
They do not reset the CPU or bus. Save must leave this snapshot unchanged, the
lease must survive session close, and reopen must reproduce the paused snapshot
before any active program is run. Reset must reproduce the pristine original
snapshot. Reopened mode defaults OFF and is explicitly restored to the scenario.

Only after those comparisons does the reopened session execute CPU signatures
and display set/clear. As in product `native/computerraria_acceptance.dart`, the
post-save display assertion concerns the first 32 pixels of row zero: the fixture
writes the complete first MMIO word as `0x80000001`, then clear writes zero.
Other pixels may retain or change prior Pong state and are not asserted black.
Actual CPU results and target pixel rows enter the report before assertions so a
baseline failure is observable. This is bounded physical evidence, not a claim
that every internal CPU register is serialized.

Saved file length and independent streamed SHA must match the lease and SAVE
result count. The file is hashed again after reopened commands. Release removes
its file and owned directory, and repeated release succeeds. Session-close checks
permit only registered live output leases; after release no circuit scratch may
remain. Both intermediate and final old handles must be rejected. The original
WLD is independently hashed after every scenario and after the process suite.

Source-2 compiled-spool WRITE is exercised by real open/reopen, and source-3 WLD
WRITE by real SAVE. Their byte/ack ownership is independently covered by stub
contracts. Counters remain OFF for performance, so no per-event WRITE count is
invented. Native live allocation counters are unavailable and recorded null.

## Build, timing, sampling and retained evidence

The isolated workflow triggers only a matching push to
`codex/native-write-paired-diagnostic-661`; the job checks that exact branch.
It has `contents: read`, checkout credential persistence disabled, no PR or
manual trigger, and no cancellation of other runs. It obtains the same public
input through the fixed product's existing verified downloader.

The unchanged 661 native engine is built once with clang/Ninja, Profile,
`-O3 -DNDEBUG`, and `ABC_PERF_COUNTERS=OFF`. Official provenance records actual
source hashes, generated flags, compiler and shared `.so` bytes. Each AOT is
compiled once with the same SDK and dependency bytes after analysis. Local AOT
or private files are not uploaded and CI binary identity is not assumed equal
to prior builds.

Direct timers separately measure initial open, save (including lease and output
hash), reopen, correctness and close. Existing progress is observed every 20 ms
for approximate hash/decode/compile and save run/hash-output stages; missing
stages stay missing. Independent fixture/source verification is outside operation
timers. At each named boundary the worker waits for the external sampler's ack.
The sampler reads status RSS/HWM, smaps RSS/PSS/USS, FD and threads every 100 ms
and at boundaries. Close quiet remains 1,200 ms after each full scenario.

All observations and phase boundaries are kept. HWM is a lifetime high-water
measure; RSS/PSS/USS are separate current observations. USS is the sum of private
clean/dirty/Hugetlb. Proc reads are sequential, not atomic, and sampled peaks can
miss brief maxima. Four distinct scenarios cannot prove a memory growth rate,
absence of leaks or long-run plateau. No forced GC, VM service/AllocationProfile,
malloc_trim, file-cache flushing or system-limit adjustment is used.

Always-run collection preserves raw worker stdout/stderr, every OS sample,
complete/partial reports, source/build/session manifests, native/contract
provenance, compiler versions and logs. Uploads exclude the WLD, saved worlds,
archives, AOT binaries, shared libraries and scratch. An explicit terminal check
fails incomplete studies. Runner disappearance may prevent collection entirely;
missing terminal evidence means unknown/incomplete, never inferred success or a
product crash.

Preparation validation is limited to static inspection and Python contracts.
Dart formatting, analysis, Flutter contracts, AOT compilation and actual full-world
measurements remain pending their normal GitHub CI execution; they are never
reported passed from static review alone.
