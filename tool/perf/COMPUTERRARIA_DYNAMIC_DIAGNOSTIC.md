# Bounded dynamic Computerraria UI diagnostic

This separate, narrowly triggered diagnostic measures the real Linux Flutter
profile application with the full public Computerraria WLD. It does not change
the production UI, ordinary generic-world profile, or existing acceptance jobs.
The explicit physical computer/Pong setup exists only in the integration test.

Publish the exact candidate to `codex/computerraria-dynamic-5217`; only push to
that branch starts this workflow, with a matching job-level branch guard. A
manual dispatch on the same branch is also declared for when GitHub exposes it.
No change to main or broad acceptance matrix is needed to trigger this job.
It uses the existing pinned Flutter 3.47.6 setup and verifies the
checkout is clean, the requested commit matches `HEAD`, the complete public WLD
matches its pinned length/SHA-256, and the test-only Pong program matches its
upstream build provenance. The actual `glxinfo` renderer is recorded.

One fresh `flutter drive --profile -d linux` invocation compiles and launches
`integration_test/computerraria_dynamic_profile_test.dart` under Xvfb. Its fixed
20-minute process bound includes compilation and driver overhead. There is no
retry, extra process, resume, or reuse of a prior Linux profile bundle. The test
prepares one program-loaded derived WLD and records standard/OFF and optimized/ON
separately, each with a fixed 12-by-128 external-clock pulse trace. ON additionally
has a fixed 15-second dynamic window. Preparation, save, close, and reopen are
outside that window; one import-cancellation attempt is also retained.

The original WLD's autonomous NPC/pressure-plate clock is unsupported by the
production circuit runtime. This test explicitly supplies electrical clock
pulses to a derived program-loaded WLD. Passing it does not establish automatic
operation of the original complete world.

The ON window includes bounded observation: full production-view reads, native
record decoding and hashes, plus an actual production RawImage clone/readback at
most every 250ms. Each read records its wall duration, actual decoded pixel hash
and full-viewport visibility. At least three distinct decoded images must match
actual native frames during Run. Clones are disposed and any pending read is
drained on completion or failure. PNG capture happens after the timed window.
These are observed dynamic workload timings, not observer-free product FPS.

```sh
export ABC_PERF_COMMIT="$(git rev-parse HEAD)"
python3 tool/computerraria_inputs.py
export COMPUTERRARIA_WLD="$PWD/build/public-computerraria/computerraria.wld"
export COMPUTERRARIA_PONG="$PWD/test/fixtures/computerraria/pong.bin"
export TMPDIR="$PWD/build/computerraria/tmp/dynamic-diagnostic"
mkdir -p "$TMPDIR"
# Set TERRA_PERF_RENDERER to this Xvfb host's observed glxinfo renderer string.
xvfb-run -a -s '-screen 0 1440x1000x24' \
  bash tool/perf/computerraria_dynamic_profile.sh \
  build/computerraria/dynamic-diagnostic/dynamic.json
```

Use a new diagnostic directory and fresh build directory for every invocation.
The runner sets `TERRA_UI_PROFILE_OUTPUT` and `TERRA_UI_PROFILE_STANDALONE_OUTPUT` for the
existing integration driver and failure mirror. The report schema is
`abc.computerraria-dynamic-ui.v1`; a standalone report without the driver result
is partial evidence and cannot pass. Each report must identify the actual host
PID, workload `public-derived-computerraria-external-clock-v1`, and exact clean
source commit. The runner requires passed results for both modes, 3,072 actual
pixels, unchanged original-source bytes, a changed saved WLD, pixel/RAM
preservation after reopening, exact continuation, reset and close boundaries,
the expected dark OFF trace, three distinct nontrivial ON fixed frames, and at
least two changed ON dynamic frames. Every named preparation/fixed/dynamic/reopen
PNG must exist and match its recorded SHA-256 and decoded-pixel evidence.
Failed runs keep
their completed records, sanitized process log, exit/timeout status, and any
actual build artifact hashes.
When complete, build provenance records executable, native library and AOT
library hashes, source hashes, CMake settings and effective native compiler
flags. It requires ordinary `ABC_PERF_COUNTERS=OFF`; native allocation counters
are not measured by this diagnostic. The runner attaches the provenance digest
after the process ends without changing measurement rows.

CI formats copies under the artifact directory and saves those three Dart files,
an applicable patch and explicit `changes-needed`/`unchanged` status. Formatting
is advisory, and it does not modify tracked sources or establish format compliance.
Analysis and
actual profile compilation are gating. All three new Dart files are checked.
Focused backend tests verify injected-clock/original-tick/pixel ordering, the
fixed budget, disarming during an in-flight clock, and missing-pixel rejection
before the full-world application process. CI
uploads only the independent diagnostic directory's JSON, text, sanitized logs,
PNG screenshots, formatted diagnostic Dart copies and format patch, including
format/analyze logs and workflow step outcomes.
Public WLD inputs and derived saved worlds live outside that directory and are never
uploaded. VM service URLs are redacted before log persistence, and the runner
terminates its owned process group on completion, interruption, or timeout.

Successful evidence establishes this bounded test on its named commit and
software-rendered Linux host. OFF and ON remain distinct workloads; a changed
native state is not itself a visible animation. This is not a device FPS,
browser responsiveness, input-to-display latency, stable baseline, or leak-free
claim. No execution result exists until the dispatched CI run finishes.
