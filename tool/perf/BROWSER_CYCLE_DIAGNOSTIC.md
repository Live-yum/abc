# Three complete WLD browser interaction cycles

This is an opt-in engineering diagnostic, implemented separately from the
preserved [single-load control](BROWSER_LOAD_DIAGNOSTIC.md). Passing the local
contracts means the harness contracts passed; it does not mean a browser run,
Pong interaction, memory improvement or stability has been observed.

No application files are changed. The diagnostic starts one fresh headless
Chrome with its ordinary sandbox, one temporary profile and one process sampler.
It uses only that owned process's loopback CDP endpoint. All three cycles use the
same browser and the original Flutter controls, File picker, worker bridge and
engine. No backend operation or Dart handler is called by the driver, and no
application state is patched. No security setting, credential, production
service, existing browser or running CI task is changed.

## Fixed official product

The default `prepare` / `run` path retains the exact `cddd936...` control and v1
single-load schemas. The cycle path has a separate required product manifest,
[the verified 1dac431 pin](browser_load_product_1dac431.json):

- Commit: `1dac431c45f82bcc298ea4bbce6abebb126dfc33`
- Official Flutter CI run: `37963125990`
- Artifact: `11632794168`, `terraforge-web-1dac431c45f82bcc298ea4bbce6abebb126dfc33`
- ZIP: 22,368,523 bytes, SHA-256 `20abe0271361ad0897d35e84e148a86fcc32c85077fa02ecf47e1e75d863f4db`
- Tar: 22,377,995 bytes, SHA-256 `93c8072cedd674ca614d1bfe410cb69ca474644fc902478d749a0603689a5502`
- `main.dart.js`: 4,189,393 bytes, SHA-256 `7ed0b5505599b2e2e84d7e0b79c7b09a6cda11527b97f8c237adcc96a4a894b1`
- `engine/world.wasm`: 406,930 bytes, SHA-256 `a9af2ce7aed0b4304c21f59e4500fd9116221588840e39af1e453459d8bf4a08`
- `engine/world.js`: 21,694 bytes, SHA-256 `50bb9a182ac1c596d5c67b84ced4d77c69a29d6bf41a4346807d46920962b47d`

Preparation requires a successful official `.github/workflows/ci.yml` run in the
same repository with precisely the selected commit, artifact name/ID, ZIP bytes
and SHA-256, tar bytes and SHA-256, and required product-file bytes and SHA-256.
There is no moving-head resolution or fallback to a different build. Every
extracted file is hashed in `build.json`; `run-cycles` verifies those files have
not changed before starting Chrome. Product and diagnostic source revisions
remain distinct. The cycle module itself is included in diagnostic file hashes.

The complete public WLD remains 405,983,441 bytes, SHA-256
`55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.
The original picker supplies a native File on every cycle. The preflight hash
read warms the OS file cache; subsequent cycles also retain browser/cache history.
None is a cold-cache or independent-device sample.

## Fixed interaction protocol

Each cycle has the following ordered stages, with monotonic host timestamps and
its cycle number in the original event journal:

1. Choose the complete public WLD with the original UI picker. Release the CDP
   object reference immediately. Observe a 10-second pre-import baseline.
2. Import through the UI. Require the latest open call's own successful ACK,
   complete source hash/ABI, one current public session, an owned worker, the
   verified computer label and enabled controls. Verify the optimization switch
   is OFF, the engine reports OFF, and optimized topology is supported. Idle for
   15 seconds, then explicitly click optimization ON and require its command ACK
   and visible switch state.
3. Click the built-in Pong program, require its program label and enabled step
   control. Click `128 个脉冲` exactly 40 times, for 5,120 physical pulses, with
   each actual clock completion, physical monitor result and UI pulse count
   checked. Retain ten every-fourth-batch display checkpoints. Require non-dark
   output and more than one distinct physical display fingerprint.
4. Start the live physical clock and click the actual monitor to focus it. Send
   trusted ArrowUp/ArrowDown keydown/keyup through `Input.dispatchKeyEvent`.
   Choose the first direction away from the nearest vertical boundary, then
   reverse once. Require each direction's actual sensor-command ACK and a
   monitor x=0 paddle-center change in the corresponding direction before
   releasing it. Retain the initial/changed positions, raw DOM key events, call
   IDs and accepted physical pulse counts. After release, allow the first 128
   pulses to drain, then anchor a fresh 128-pulse interval to the actual drain observation
   and require no new matching sensor ACK through that interval. A delayed poll
   cannot reuse an already-passed pulse threshold. This is a fixed two-direction sequence, without retries.
5. Observe five more seconds of live clocks and changing physical monitor
   output. Pause through the UI, drain pending calls and require both bridge
   clock count and visible UI pulse count to remain unchanged for two seconds.
6. Reset through the original UI and its discard confirmation. Require a newly
   acknowledged import with a different public session, the old session's close
   ACK, default OFF, zero UI pulses, empty original ROM and a fresh dark physical
   monitor result from the replacement session.
7. Close through the UI. Require the current ordinary close's ACK, all observed
   public sessions removed, all created world workers retired, and no pending
   bridge calls. Observe exactly the same first 20 seconds after close on every
   cycle, without calling `progress` or any backend method. Freeze bridge/open/close/worker counts at close completion and reject any
   change during that tail, including balanced transient recreation. Recheck
   after the screenshot and require exactly the planned original/reset imports
   and their two closes.

The 40 × 128 pulse budget, four-batch checkpoints, lit/changing display assertion,
x=0 paddle center, up/down physical sensor coordinates and two-batch release
proof follow `integration_test/computer_world_profile_test.dart` and the actual
`ComputerrariaComputer` ABI. The profile's dispatcher-held input during stepping
cannot be reproduced by clicking a step control while keeping monitor focus:
that UI blur releases keys. This protocol therefore labels its boot as **no-input
UI boot** and exercises genuine focused keyboard input during the subsequent
live run. It does not claim dispatcher-trace parity or a CPU/RAM signature test.

Screenshots occur only after each fixed boot and after each close, plus at most
one on failure. The monitor evidence comes from actual 64 × 48 PixelBox command
results, with the production coordinate/tile/frame/uniqueness validation. Each
record includes the 3,072-pixel count, lit count, interior-lit count, left-paddle
center and bounded FNV-1a fingerprints of records/normalized pixels. FNV-1a is a
change fingerprint, not a cryptographic identity assertion. Full display buffers
are never serialized or retained by the observer. The observer performs bounded
49,152-byte reads and temporary 3,072-byte arrays; that overhead, accessibility,
CDP and screenshots are part of this engineering environment.

A raw trusted key event proves browser delivery; the correlated command ACK
proves the physical sensor operation completed; the decoded paddle observation
proves a physical display state changed. These do not measure end-to-end screen
presentation latency, perceived playability or screen FPS.

## Ownership, failures and bounds

Every observed bridge call has a unique call ID. Readiness cannot reuse an older
open ACK, ordinary close cannot reuse reset's earlier close ACK, and a display
result with an older session cannot prove the current display. Reset creates a
replacement worker; worker creation/termination totals are derived from raw
identified events rather than assuming a single owner for the whole cycle.
Only known worker IDs and current public handles are accepted. No worker or
public-session objects are retained in the result, only scalar identifiers.

The driver has a 3,240-second soft deadline. Python polls every 500 ms and stops
active work at 3,270 seconds from runner start, reserving 30 seconds of the
3,300-second budget for owned-process cleanup. CDP calls have 15-second bounds,
loads/resets have 610-second individual waits, each boot step/program load has a
120-second wait, and each input/paddle/release wait has a 15-second bound.
Off-screen controls get at most twelve ordinary mouse-wheel reveal attempts
after DOM scroll-into-view; the driver rejects unresolved geometry. There are
exactly three cycles and forty boot steps per cycle; timeouts are
failures and are never retried automatically. The workflow run step has a
60-minute outside limit; its cycle job has a 70-minute limit including preparation.
The preserved baseline still uses its 780-second driver wait and 15/25-minute
step/job limits.

Resource stop thresholds are 6 GiB sampled aggregate owned-Chrome RSS and
512 MiB total evidence. These are sampled stop thresholds, not kernel memory
reservations or exclusive-byte attribution, so a transient overshoot is possible.
Individual retained bounds are 256 MiB OS samples, 64 MiB browser events, 16 MiB
per Chrome/driver log, 8 MiB per screenshot and 4 MiB failure accessibility data.
The log sinks continue draining while flagging overflow, then the watchdog stops
the attempt. All prior raw lines and partial results survive failures and bounds.
Cleanup targets only the directly launched processes and descendants rechecked
against Linux PID start ticks. No forced GC, allocator trimming, sandbox bypass,
process-wide user cleanup or security-setting change is used.

`observed` means the declared interaction/evidence contract completed. It is not
a performance threshold pass. Timeouts, crashes, UI/ABI changes, stale handles,
missing ACKs, dark/unchanging Pong, keyboard/paddle failure, background activity
after pause/close and resource bounds remain explicit failed/partial evidence.
Missing process measurements remain null/inconclusive. No failed cycle is omitted,
replaced or called warmup.

## Memory windows and result protocol

The separate schemas are `abc.browser-cycle-driver.v1` and
`abc.browser-cycle-diagnostic.v1`. Evidence stays under
`build/browser-cycle-diagnostic/evidence/`, including the complete original
`os-memory.ndjson`, `browser-events.ndjson`, selected build provenance, bounded
logs, per-cycle screenshots, `driver-result.json` and `execution.json`.

The OS sampler runs continuously across the same browser. Python validates the
cycle ID and strictly ordered, nonduplicated stage markers before deriving
windows. Each adjacent stage has its own sample count and peak. Non-atomic
samples crossing stage boundaries are excluded. A failed/truncated cycle is
clamped before the next cycle, preserving its available peaks without inventing
its release or absorbing later memory.

For each completed cycle, `afterClose` is the arithmetic mean of complete-tree
samples wholly inside `[close-complete, close-complete + 20 seconds)`. An absent
PSS in this window makes its PSS mean/delta null. Successive cycle means and
deltas use this identical elapsed window. Stage completeness, maximum sample
gap, available phase peaks and missing sample counts are retained. These three
same-browser observations do not prove leak freedom, allocator ownership,
long-run stability, normal-user responsiveness or improvement over another build.

Aggregate RSS can double-count shared pages; PSS is a separate proportional
estimate, not exclusive ownership. Native allocation/WASM capacity overlap OS
memory and must not be added. Per-process VmHWM is a lifetime measure and must
not be summed into a phase peak. Sampling can miss short peaks; process-tree
enumeration can miss very short-lived/double-forked children. There is no leak or
stability pass/fail threshold in this diagnostic.

## Opt-in entry points and lightweight validation

The same workflow preserves single-load behavior for diagnostic PR events and
its default manual dispatch. Only a push to exactly
`refs/heads/codex/diagnostic-browser-cycles`, or manual `mode=cycles`, selects the
cycle path. Push scope rejects deleted/wrong branches, malformed/unresolvable
SHAs and head mismatch; a first branch creation with all-zero `before` selects
one attempt, while later pushes require a diagnostic-file diff. The concurrency
group includes the run ID and never cancels another run. Only this workflow is
changed; acceptance/performance workflows remain separate.

Authorized CI entry points, not a claim that they have been executed:

```sh
python3 tool/perf/browser_load_diagnostic.py prepare-cycles --product-manifest tool/perf/browser_load_product_1dac431.json
python3 tool/perf/browser_load_diagnostic.py run-cycles
```

Local synthetic contracts, without Chrome or product execution:

```sh
python3 -m unittest discover -s tool/perf -p 'browser_load_*test.py'
node --test tool/perf/browser_load_driver_test.mjs
python3 -m py_compile tool/perf/browser_load_diagnostic.py
node --check tool/perf/browser_load_driver.mjs
node --check tool/perf/browser_load_cycles.mjs
```
