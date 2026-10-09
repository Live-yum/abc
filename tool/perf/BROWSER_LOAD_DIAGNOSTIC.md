# One complete WLD browser load diagnostic

This separate engineering run observes one complete public Computerraria WLD
load in a fresh, real headless Chrome, through the original Flutter UI and File
picker. It then idles for 15 seconds, closes through the UI, and observes a
20-second release tail. It does not run Pong, repeat the load, retry a failure,
deploy anything, or modify application code or existing acceptance workflows.

## Exact product and input

The first reproduction deliberately uses the original successful official
Flutter CI package, independently of the diagnostic source revision:

- Product source: `cddd936f95d31b14a76503e13ffc89173110a057`
- Official Flutter CI run: `37920825904`
- Artifact: `11611983230`, `terraforge-web-cddd936f95d31b14a76503e13ffc89173110a057`
- Artifact ZIP: 22,366,110 bytes, SHA-256
  `fa7e9e4575109f388cae6533193bd96bf6b15d42bd767130d5de03c811ba8a92`
- `main.dart.js`: `35ca45df21710b3463cb51866b0ede28ef9eea449fb0310c82889de26625277e`
- `engine/world.wasm`: `a9af2ce7aed0b4304c21f59e4500fd9116221588840e39af1e453459d8bf4a08`
- `engine/world.js`: `50bb9a182ac1c596d5c67b84ced4d77c69a29d6bf41a4346807d46920962b47d`
- Public WLD: 405,983,441 bytes, SHA-256
  `55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`

The existing public fixture downloader checks the pinned upstream source.
The runner independently streams the fixture hash before Chrome starts, and
the actual product streaming import must return that same hash. No TWLD is used.
This is a fresh browser/process measurement, not a cold operating-system file-cache
measurement: the verification read can warm the fixture cache. File-picker interaction
and the preliminary verification read are outside the application loading window.
Expired, missing, replaced, or mismatched artifacts fail; there is no fallback
to another build. A later product comparison requires an explicit new pin.

`build.json` records the official run/artifact identity, ZIP/tar hashes, every
served product file hash, the clean diagnostic checkout SHA, and diagnostic
script hashes. Product source and diagnostic source are distinct fields.

## Isolated browser and safety boundary

The workflow uses the GitHub Ubuntu 24.04 runner's existing official
`/opt/google/chrome/chrome`, as a non-root user. It records the package version,
binary hash, full launch arguments, kernel, runner image, viewport, user agent,
and hardware hints. It does not install a browser or driver. Node 22's built-in
WebSocket implements the small CDP client, so no automation package, driver
launch defaults, new credential, or persistent browser access is involved.

Chrome has a fresh temporary profile and loopback debugging socket. No security
disabling switches, changes to SUID files, AppArmor, sysctl, network policy, or
existing user/cloud browser sessions are used. The renderer must have observable
`NoNewPrivs=1` and `Seccomp=2` before app navigation. These are recorded sandbox
signals, not a complete security audit. Startup or sandbox-evidence failure is
inconclusive and stops without loading the fixture. Missing PSS is recorded as
null with the read error; available RSS evidence is retained, and a nominally
completed run with missing memory evidence remains inconclusive. No permission
escalation is attempted to fill a measurement gap.

The app is served on loopback. CDP selects the file by absolute path in the
product's real hidden `input[type=file]`. Chrome supplies the native File object
to `PlatformWorldCircuitFiles`; the diagnostic does not fetch the 406 MB input
into JavaScript, create a full ArrayBuffer, replace the gateway, or call engine
open directly. Navigation, import, and close use accessible product controls.
Readiness requires one File import, the pinned source hash and ABI result,
the product's verified Computerraria UI label, and an enabled Close control.
A progress label or first engine-ready event alone does not pass.

The scalar observer replaces only the global bridge reference with a frozen
facade around the original frozen RPC client. It forwards original File and
result identities and does not serialize/retain records or buffers. All
unobserved methods are passed through. The original release JavaScript uses
the global bridge getter at each invocation. Worker creation/termination is
observed to verify acknowledged retirement. No progress call is added after
close, because it could create a fresh worker. Accessibility and observer
overhead are part of this diagnostic environment.

## Evidence and interpretation

Evidence is streamed during the attempt under
`build/browser-load-diagnostic/evidence/` and uploaded even on failure:

- `browser-events.ndjson`: host-monotonic receipt times, page timestamps,
  product progress stages, native active/peak counters, WASM capacity, source
  hash, UI boundaries, worker lifetime, and CDP crash/error events
- `os-memory.ndjson`: each owned PID plus Linux start ticks, process type,
  RSS, proportional PSS, process-lifetime VmHWM, read start/end times,
  aggregate RSS/PSS, and process-disappearance observations
- `execution.json`: explicit observed/failed/inconclusive state, direct Chrome
  wait return code/signal, driver exit, requested termination, bounded-window
  baseline/peak/delta/release summary, maximum actual sample gap, completeness,
  and hashes of the retained raw evidence
- `driver-result.json`, sandbox preflight, Chrome/driver logs, and screenshots
  before load, ready, and after close; failure screenshot/accessibility tree
  when the process remains responsive

Sampling requests an interval of 250 ms; actual gaps and non-atomic reads are
preserved. The process set is the browser plus descendants observed through
Linux child lists; very short-lived or double-forked children can escape that
enumeration. Shorter peaks can be missed. Per-process VmHWM is a lifetime measure,
not a resettable phase peak; different processes' high-water marks must not be
added. Aggregate RSS can double count shared pages; aggregate PSS is a weighted
estimate, not exclusive ownership. WASM capacity, native-active counters and
OS memory overlap and must not be added together. Each RSS/PSS peak is the
maximum observed aggregate for that metric and need not occur at the same time.

The baseline is the last available complete-tree sample for each metric in the
10-second pre-load quiet window. `loadingPeak` strictly covers load-start up to
the verified UI ready boundary, excluding that boundary. `readyIdlePeak` covers
ready up to Close-start, excluding Close-start. `lifecyclePeak` covers load-start
through the release-complete boundary, including close/cleanup. Later idle or
close spikes cannot inflate the reported loading peak. Separate load/lifecycle
deltas use the same baseline; release is measured from the lifecycle peak.
The release point is the last available post-close sample before the 20-second
tail ends. Missing fields stay null; partial samples and truncated JSON lines
cannot make a run pass. No forced GC is requested. A smaller after-close value
does not by itself identify allocation ownership or prove leak freedom.

Only `Popen.wait()` on the directly launched Chrome yields its actual OS return
code. A renderer's CDP crash status/code or disappearance is separate evidence;
unknown renderer exit status stays null. Unexpected remaining owned descendants
are cleaned up with PID/start-tick checks and make the result inconclusive.
The driver has a 780-second hard bound, the run step 15 minutes, and the job
25 minutes. Logs and already-flushed raw samples survive early crashes/timeouts.

The result describes this one CI environment. It neither measures actual screen
FPS nor establishes the cause of a separate cloud browser's Error 9.

## Running and local validation

The new workflow runs only for opened/synchronized PR changes to its own
workflow/diagnostic files or a manual dispatch. Because GitHub PR path filters
use a cumulative base-to-head diff, a separate lightweight scope job checks the
actual synchronize event's `before` to head diff. An opened PR uses base to head.
Both endpoints must be exact 40-character lowercase SHAs resolvable to commits;
missing/malformed endpoints or unsupported events fail closed. Manual dispatch
also requires a resolvable head and explicitly selects one attempt. Unrelated
synchronize changes skip the browser job and produce neither a measurement
artifact nor a claim of a passing measurement. Its unique run concurrency group never cancels another
diagnostic or existing CI workflow. It requires only same-repository read access
to the pinned artifact through the existing ephemeral GitHub token. It never
publishes the public fixture or the temporary browser profile.

Lightweight contracts, without Flutter compilation or Chrome launch:

```sh
python3 -m unittest discover -s tool/perf -p 'browser_load_checks_test.py'
node --test tool/perf/browser_load_driver_test.mjs
python3 -m py_compile tool/perf/browser_load_diagnostic.py
node --check tool/perf/browser_load_driver.mjs
```

The tests cover incomplete memory data, partial failures, process identity,
sandbox signals, unsafe archives, true-ready requirements, ambiguous/disabled
controls, and instrumentation of an actually frozen bridge without payload
copies. A browser/OS observation is still required; passing these contracts
does not claim that the actual lifecycle has run.
