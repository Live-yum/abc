# Public dispatcher coverage additions

These are executable **test declarations**, not completed performance results.
Only passed raw reports establish measured coverage. No production code changes
or private saves, catalogs, account credentials or metrics are included.

## Audit of the earlier report

The old inventory contains 124 actions. Current source has 134: 117 Workspace
and 17 CircuitRulesWorkspace actions. Ten early computer actions were missing
from the checked-in inventory; the generator already understands their syntax.
An old general UI report's 102 controller rows represent **71 distinct action
names**, of which 70 matched the old inventory. Five report-level unmapped rows
were `worldCircuitReleaseKeys`, not five absent implementations.

The 20 earlier action gaps have these causes and narrowly scoped remedies:

| Actions | Actual cause | Public remedy / remaining limit |
|---|---|---|
| preparePlayerConversion, cancelPlayerConversion, applyPlayerConversion | Existing native workload is inside an all-or-nothing private-catalog + modern-world guard | Generated native PLR v279/v326 plus an explicitly invented catalog contract; successful application and export readback, cancel, reprepare, undo. This does not prove authentic game catalog compatibility. |
| bestiaryEntry, bestiaryUnlockKnown, stageBestiary | Public v139 worlds had no bestiary section | Original 16x32 WLD326 generator; native edits preserve the unknown record and survive independent export reopen. |
| chestBestPrefixes | Verified dispatcher branch requires world 326 and catalog tag 1.4.5.8 | Original WLD326 chest + invented item/prefix metadata; changed prefix survives native readback. |
| playerBestPrefixes | Skipped by the same unnecessary private-world guard | Generated native v326 PLR + invented prefix metadata; verify changed prefix and preserved favorite after export. |
| fusionPlace, fusionDiscardPlacement, fusionInsert | Catalog branch was private-only; display companion records require WLD326 | Public modern world and existing synthetic placement geometry; verify stage/discard exact region restoration, real insertion readback, and undo. Both stage/restage IDs remain distinct. |
| pixelMatch | Synthetic default pack has no stable-RGB family | One invented stable RGB entry; real native color matcher and checked output mapping. |
| worldPresetClone | Private-catalog guard | Invented preset with hashes bound to its actual synthetic JSON; editable independent clone checked. |
| cloudPrepareUpload, cloudUploadPrepared, cloudRecommendationDownload | Existing cloud suite already called Workspace.dispatch but report IDs were not mapped | Exact audited local-dispatch mapping; new suite also covers the native-preview path. HTTP, auth and provider remain synthetic, never live coverage. |
| cloudDiscardUpload, cloudDownload | No existing successful direct dispatcher workload | In-process synthetic HTTP/session, actual local vault and native WLD preview; verify cleared pending data and exact downloaded bytes. |
| generate | Production explicitly reports no generation service | Unsupported service, not an invented success timing. |
| openSynthetic | Compile-time QA entry is disabled in production | Production-not-applicable; ordinary import timings do not pretend to measure this disabled entry. |

The old 34 missing declared rows also include partial variants of import,
export, resize, paint, stageChest, playerSlotEdit, fusionRegion and undo.
Their individual IDs are retained. The new public suite supplies those exact
catalog/conversion/placement variants instead of declaring the whole action
complete from a different parameter branch.

## Small native dispatcher suite

Generate the 1,365-byte deterministic input, then use an existing release native
engine. Run only when the serialized benchmark lane is available:

```sh
python3 tool/perf/generate_synthetic_modern_world.py assets/qa/synthetic-modern.wld
python3 tool/perf/verify_synthetic_modern_world.py "$TERRAFORGE_ENGINE_LIBRARY"
ABC_DISPATCH_PERF_REPORT=build/perf/public-dispatch.json \
ABC_PERF_CYCLES=3 ABC_PERF_WARMUP=1 \
flutter test --no-pub --concurrency=1 test/performance/public_dispatch_actions_test.dart
```

Defaults remain 25 measured cycles and five warmups, plus a separate first-use
cycle. Operation assertions and fixture preparation are outside exact awaited
Workspace.dispatch timers. Each row records action, controller, scenario,
fixture, raw samples, first-use/warm phase, median/p95/max, byte count and
source/toolchain provenance. Every cycle closes all tracked document owners;
native counter zero checks are enforced when the optional counter ABI exists.
RSS and high-water samples remain process-wide. Optional
`ABC_PERF_GC_DIAGNOSTICS=1` adds the existing unique-isolate-group heap probe after
closure, separately from unforced samples and operation timings. Missing heap
data stays explicitly unavailable. This test has no Flutter frame evidence.

The existing Native CI job runs three independent processes sequentially after
its original workload, with the same release counter library and no new job or
parallel heavy lane. Raw reports, journals, logs and execution manifests are
included in its existing artifact. The aggregate requires all three executions
and all 36 scenario IDs in both cold and warm phases, with complete cleanup
memory. Against the verified a5612b4 calibration, this newly introduced suite is
`new-workload-uncompared` and the aggregate is inconclusive, never a fabricated
regression pass. Missing or partial later baselines still fail validation.

The generator writes the release-326 section table, explicit fixed header
groups, 16x32 tile stream, one 40-slot chest, empty bestiary/other collections and
a matching footer. Its preflight verifies chest and bestiary mutations through
save/close/reopen and checks the unchanged original bytes independently. It
contains no derived game world, artwork or extracted game data.

## Full-world action audit and extension

Existing validated Computerraria UI macros contain exact ChooseWorld, Import,
Cancel, LoadPong, Optimization, Input and Pause actions. Cancel occurs in the
explicit `computer.cancel-import.standard` workflow, not implicit cleanup.
ReleaseKeys has existing general-profile direct samples. Earlier full-world
reports lack exact dispatcher timers: coverage links their whole macro duration
to each contained action and never divides or relabels that latency.

The profile extension reuses the already imported public world, adds a picked
four-byte RV32I program, and reads all 32 actual first-word ROM lamps to verify
the write. It restores Pong and verifies unchanged pre-test RAM, CPU and display
signatures before the original deterministic trace. A separate explicit display
refresh checks pixels, size, increased poll count and unchanged physical pulse
count. No additional world import is added for these cases.

The existing controller decorator now records exact awaited samples for all
full-world dispatches, grouped by standard/optimized mode. All old macro timers
are preserved. Between-cycle reports include retained harness sample/frame/window
counts. This added instrumentation and work changes the measurement workload:
old reports are not comparable latency or memory baselines for the new suite.
New operation IDs remain unpaired/uncompared until matched independent baseline
and candidate runs exist. No baseline outcome is inferred from a successful test.

Every full-world reset now also runs inside the existing OS memory sampling
window, with `kind=reset-original` and the actual exported-session source label.
Two cycles in both modes require 13 windows: one cancelled import, four initial
imports, four saved reimports and four resets. The eight independent closure
samples are checked against their actual preceding load. Older nine-window
reports remain historical initial/reimport evidence and do not cover reset
loading peaks; the extended profile explicitly requires all reset windows.

`coverage_report.py` separately labels native/core, explicit native dispatcher,
local cloud dispatcher, exact profile dispatcher and action-containing profile
macros. Full-world reports require their existing validation, matching completed
execution manifest, digest and retained log. Standalone mirrors are not counted
as independent runs. It preserves missing declared variants, live-cloud limits,
source revision and actual frame availability.
