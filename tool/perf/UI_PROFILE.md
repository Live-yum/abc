# Real Flutter UI profile benchmark

The developer-only `integration_test/ui_profile_test.dart` runs the production
`TerraForgeApp`, `Workspace`, native engine and rules runtime. It is never
imported by the production entry point. Use `flutter drive --profile`; ordinary
widget-test elapsed time, Dart tests, Node timings and build success are not FPS
or proof of device smoothness.

## Reproduce

Install the normal Linux Flutter desktop build dependencies plus `xvfb` and
`mesa-utils`, resolve the pinned Flutter dependencies, and build the pinned
rules artifacts as in CI. Run:

```sh
export LIBGL_ALWAYS_SOFTWARE=1
export TERRA_PERF_RUNNER=ubuntu-24.04-xvfb
# Keep the exact glxinfo -B output beside the JSON artifact. Record its renderer.
export TERRA_PERF_RENDERER=llvmpipe-from-glxinfo
xvfb-run -a -s '-screen 0 1440x1000x24' \
  bash tool/perf/ui_profile.sh linux build/perf/ui-profile.json
```

`TERRA_PERF_RENDERER` must describe the actually observed renderer. A software
renderer on hosted CI is useful for reproducibility; it does not represent
Android, iOS, macOS or a user's GPU. `FLUTTER_BIN` can select a pinned SDK.
`TERRA_PERF_ITERATIONS` (default 8) and `TERRA_PERF_WARMUP` (default 2) control
complete application lifecycles. The JSON records the physical window size,
pixel ratio, reported refresh rate, OS, runtime, renderer, runner and commit.
An Xvfb screen size does not force the app window to that size; trust the report.
The source revision is `ABC_PERF_COMMIT`, then `GITHUB_SHA`, then checked-out
`HEAD`. PR CI should set `ABC_PERF_COMMIT` to its requested source head because
`GITHUB_SHA` can identify a synthetic merge commit. The actual checked-out hash
and dirty state are recorded separately. Profile acceptance requires a clean,
committed snapshot; an unborn local tree can only produce a debug workflow smoke.
Each input byte fixture has a SHA-256; generated PLR records the generator-input
configuration digest, and synthetic resource installs record manifest digests.

Keep the complete generated `build/linux/x64/profile/bundle` directory to run
the exact profile harness on another compatible Linux desktop without building
again. Start its `terraforge` executable with
`TERRA_UI_PROFILE_STANDALONE_OUTPUT=/absolute/local/report.json`; the harness
writes its full report at completion, including failures. The VM service must
be enabled for heap collection (normal profile Flutter runner arguments).
`flutter drive --use-application-binary=...` or `--use-existing-app=<VM service URI>`
can also run/attach the supplied driver using Flutter's supported tooling.
The binary remains a developer benchmark, not a production app. Confirm runtime
library compatibility and the new machine's renderer; do not relabel the CI
runner metadata as a newly measured physical device.

For an explicitly authorized local native-file run, set
`TERRA_PERF_LOCAL_INPUTS=/absolute/local/manifest.json`. The manifest is an array
of objects such as `{"kind":"world","path":"/absolute/file.wld"}` or
`{"kind":"player","path":"/absolute/file.plr"}` or
`{"kind":"map","path":"/absolute/file.map"}`. These add separate measured
workflows; they do not replace synthetic fixtures with assumptions about real
chest/tile coordinates. Reports use anonymous input IDs, byte sizes and SHA-256,
and omit source paths/original filenames. This option is rejected on GitHub
Actions and is not implemented as browser file injection. Keep personal input
manifests and their resulting reports outside public CI artifacts.

For a connected Android/iOS/macOS device, use its actual Flutter device ID in
place of `linux`. A valid build is not a performed device test. Physical iOS
profiling also needs the developer's normal signing setup. This harness does
not create signing credentials. Browser profile frames and browser heap need
their own supported runner; the source has conditional platform imports but
Linux evidence cannot be reused as Web acceptance.

## What the report measures

Each repetition mounts a new workspace, exercises all 12 navigation sections,
loads WLD, reopens it, pans/pinches its actual map, loads and toggles wire/liquid
overlays, edits world headers and chest slots, sorts/clears chests, performs
world rules preview/apply, then exports and reopens actual encoded bytes. It
also separately decodes 512×256 legacy and chunked binary MAP fixtures, renders
their rasters, pans/pinches, edits/undoes/redoes, exports/reopens, rejects corrupt
inputs without losing the current session, and generates a MAP from WLD.
It creates a native PLR, edits inventory/header, visits player tabs and verifies
save/reopen. It draws a 256×144 pixel canvas and pans/pinches the full-layer
region canvas. Standalone, actual-world and authoritative rules circuits cover
their available open, viewport, editing, copy/paste/route, undo/redo, trigger,
tick, run/pause, reset, export/reopen and owner-close paths. Resource installation
uses the actual service and panel with synthetic cancel, corrupt-object failure
and retry. Import-dialog cancellation, picker cancellation, corrupt WLD failure
and cancelled export are exercised too.

Navigation, dialogs and canvas gestures use real pointer events. Controller
actions use the same production dispatch methods with their production views
mounted. The report labels this distinction per operation; it does not claim
that every command was invoked by clicking a button. In-memory synthetic file
and resource gateways omit system chooser, share sheet, filesystem and network
latency. Default CI runs access no private/game files or remote services. Small synthetic
worlds are workflow stress tests, not large-world throughput acceptance; private MAP and
licensed texture/resource performance remain explicitly unmeasured here.

The engine's actual `FrameTiming` batches provide raw per-iteration UI, raster
and total-span microseconds, frame counts, median/p95/max and work-over-budget
counts. Delayed callbacks are matched to operation windows using monotonic
frame timestamps. The budget comes from the display's reported refresh rate
(with a documented 60 Hz fallback if unavailable). UI/raster budget exceedance
is not a measured compositor dropped-frame count. End-to-end operation latency
includes deliberate frame pumps/gesture pacing; it is never converted to FPS.
The separate `controllerOperations` array records exact awaited production
dispatch latency through a test-only `TerraController` decorator. All UI calls
and explicit scenario actions use the decorator. Rows expose action and
allowlisted kind/canvas/rules-method variants, raw samples and associated macro
frame scopes, but no filenames or private argument values. The scope family
distinguishes project-import workflows. A returned future is not an acceptance
claim: the workflow separately verifies successful or deliberately rejected
state. Controller-only records do not acquire invented frame samples.
Set `TERRA_PERF_TRACE_TIMELINE=true` for a separate diagnostic run that also
embeds the Dart/Embedder/GC timeline with named operation spans. Timeline tracing
adds overhead and its report must only be compared to equally traced runs.

Between lifecycles, owners close, widgets unmount and references leave scope.
Only then does the VM-service probe request GC for all isolates and record Dart
heap usage/capacity/external bytes, process RSS and max RSS. GC is outside frame
measurement windows. RSS includes native engines, image/GPU caches and allocator
retention; it is not equivalent to Dart retained heap. The raw cycle series is
preserved. One passing run does not prove absence of leaks.
Raw benchmark samples remain resident until report writing; their growing frame
and operation counts are included in each memory snapshot. Compare identical
harness workloads and baseline runs, rather than labeling measurement-bookkeeping
growth as an application leak.

## Gates and comparisons

`ui_validate.py` rejects a debug run, a partial workload, missing required direct
controller dispatches, absent actual frame samples or missing native RSS/heap
readings and environment provenance. It deliberately has no guessed
absolute millisecond or megabyte limits. A first run establishes candidate
baseline evidence, not a speed/stability pass.

Collect at least five independent process runs for each revision on matching
devices, renderers, OS/SDK versions, fixtures and iteration settings, preferably
alternating revisions to avoid load/thermal bias. Then run:

```sh
python3 tool/perf/ui_compare.py \
  --baseline build/perf/base-*.json \
  --candidate build/perf/new-*.json \
  --output build/perf/ui-comparison.json
```

The comparator uses run-level medians, exact discrete bootstrap intervals and simultaneous
multiple-metric correction, including robust post-close memory slopes and tail
medians. Its odd-median and even-middle-pair integer distributions avoid
per-metric Monte Carlo draws; the formulas are verified against exhaustive
bootstrap enumeration. Frames within a run are correlated and are not treated as independent
benchmark runs. Only a confidence interval wholly above zero reports a
regression. Output/exit codes are regression/1, inconclusive/2, and
no-detected-regression/0. Missing baseline, changed conditions and incomplete
evidence remain inconclusive. Duplicate process run IDs cannot be reused as
independent baseline samples. No detected difference is not an equivalence test.
Inspect long-tail frame samples and retained-memory trends alongside statistics.
Harness operation/driver timeouts detect stuck tests; they are not UI smoothness
or throughput acceptance thresholds.

Run `python3 -m unittest discover -s tool/perf -p ui_checks_test.py` to verify the
evidence gate and its false-pass protections.

## Verification status

This file describes the executable protocol. Actual results must be read from
the emitted JSON/CI artifact, including its status and runtime fields. A local
debug workflow smoke test or analyzer pass must not be reported as completed
profile acceptance. No device-specific numeric results are baked into this
document.
