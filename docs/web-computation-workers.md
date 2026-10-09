# Web computation ownership

The browser document bridge (WLD/PLR import, inspection, mutation, checked export,
thumbnail, player creation/projection, and binary MAP generation), whole-world
TCW bridge, and legacy circuit traversal now execute their existing WASM bridges
inside separate dedicated workers. Region processing, full circuit rules, and
MAP decoding keep their own independent workers. Loading the application no
longer loads a document or TCW WASM engine into the UI thread. Browser worker
unavailability fails explicitly; there is no synchronous engine fallback.

The public `terraForge`, `terraWorldCircuit`, and `terraCircuit` asynchronous
methods retain their Dart-facing signatures. Existing `createBridge`,
`createWorldCircuitBridge`, and `createCircuitBridge` Node exports still expose
the direct bridges for core contracts and baseline performance measurements.
The document, TCW, region, and rules worlds are never interchangeable handles.

`terra_worker_rpc.js` serializes each owner. It accepts only its fixed method
allowlist, validates argument shape and byte limits on both sides, limits the
queue to 16 requests and 96 MiB, and limits document ownership to 32 documents
(one WLD, as enforced by the underlying document bridge). WLD input is limited
to 64 MiB through the legacy byte API, PLR to 2 MiB, TWLD byte input to 16 MiB,
JSON to at most 8 MiB, and materialized worker output to 160 MiB total. The engine enforces tighter method-specific output bounds,
including 128 MiB binary MAP. Default request deadlines include queueing and
are 120 seconds, or 600 seconds for whole-world circuits. Test callers can set
a bounded deadline up to 600 seconds.

Inputs are copied when accepted and those copies are transferred at dispatch.
The application retains its original buffers, and later application mutations
cannot change a queued request. Worker outputs are transferred; the underlying
bridges already return independent copies of their retained state. Exactly one
request runs per owner, and the worker independently serializes requests.

Whole-world circuits also expose `openSource(worldBlob, twldBlob)` through
`WorldCircuitSourceBackend`. Immutable File/Blob handles cross the worker
boundary without a world-sized byte clone. The worker hashes the WLD
incrementally, opens it through `terra_world_stream_*`, and keeps ranged input
owners alive until the circuit and world close. Every Blob read is at most
1 MiB; source ranges are checked against the actual file size, up to the core's
2,147,483,647-byte stream limit. Optional gzip TWLD input goes directly to the
native streaming decoder; the host never materializes its expanded contents.

Scratch and staged save output use random-access OPFS files in the worker.
Large imports require OPFS; unsupported or denied storage fails explicitly.
Small old inputs may use a 64 MiB shared, paged memory fallback. Scratch is
removed at close. Completed paired saves return `worldSource`/`twldSource`
File/Blob descriptors instead of byte arrays; these outputs survive session
close and reset. Call `releaseWorldCircuitSource` on each owned output after
export or adoption. Caller-owned picker inputs carry no release token and are
never deleted. An abrupt worker loss or page exit may leave temporary OPFS files
for browser site-storage cleanup; completed output is not claimed to survive a
lost computation owner.

The native circuit allocation budget is explicitly 192 MiB. This is separate
from Wasm heap capacity, file cache, and browser process memory. Progress exposes
native active/peak bytes, Wasm heap bytes, source/scratch I/O, largest requests,
and in-memory fallback storage. `worldCircuitProgress` and
`cancelWorldCircuitOperation` use an independent control lane, so they work while
a queued import or simulation command is active. Pumps yield cooperatively;
cancelling a command invokes native rollback and retains a usable session,
while cancelling import closes its partial native and scratch owners. The
existing owner-wide `cancel()` retains its worker-termination behavior.

Circuit optimization is explicitly OFF in new sessions. Command 10 toggles
only the native generation-stamp device-dedup fast path after queued work has
settled. The prior compiled/group/lazy execution remains the OFF baseline.
The host requires `circuitWorldOptimization: 1`, validates mask 0/1 and no
records/flags, and checks READY bit 1 confirms the requested mode. READY bit 0
continues to report the independent TWLD pixel-compatibility profile. Toggling
keeps the same source, native session, electrical state, and display pixels.

The client allocates monotonically increasing public handles and maps them to
the current worker's native handles. Close immediately rejects new operations
on that handle, then releases it in queue order. Repeated/stale close is a harmless cleanup
no-op and never targets a new owner. `reset()`, `cancel()`, and
`dispose()` terminate that owner and reject all active/queued calls. Timeout,
worker error, or malformed output also invalidate the entire owner. A later
explicit open may create a fresh worker, but it cannot reuse an old public
handle. Generation checks discard late messages. Mutations are never retried
after owner loss: the caller must explicitly reopen a retained source, and an
unreturned mutation result is uncertain. These controls do not cancel other
owners. Page exit disposes each browser owner.

Verification commands:

- `node test/web/engine_worker_lifecycle.cjs`: lightweight bounds, snapshot,
  serialization, timeout, cancellation, no replay, stale-handle, recovery, and
  absent-worker contracts.
- `node test/web/world_circuit_optimization_contract.cjs`: default OFF,
  independent mode/profile metadata, queued idle toggles, display preservation,
  capability checks and invalid-command rejection.
- `node test/web/world_circuit_streaming_contract.cjs`: synthetic >128 MiB
  ranged input, incremental hash, sparse OPFS I/O, output lifetime, cancellation,
  native budget and bounded-read contracts.
- `node test/web/engine_worker_smoke.cjs`: actual browser worker bootstrap in
  Node workers, with local-only script/WASM adapters and the original generated
  fixtures. WLD/PLR exports, thumbnails, generated MAP, and TCW saved output are
  compared against direct bridge baselines. It verifies real worker termination,
  explicit reopen, source preservation, and four-colour traversal.

`TERRA_ENGINE_WORKER_REPORT` optionally names a local JSON report for the second
command. Its event-loop measurements describe the Node host only. They do not
measure browser frames, Flutter UI smoothness, mobile devices, or platform FPS.
The small original fixtures establish correctness, not large-world throughput.

For opt-in acceptance of the public full Computerraria fixture, run:

```sh
node test/web/computerraria_file_acceptance.cjs \
  web/engine/world.js web/engine/world.wasm \
  /path/to/Computer.wld /path/to/Computer.twld /path/to/report.json \
  --pong /path/to/Pong.bin --save
```

The harness verifies physical CPU signatures, the actual one-bit ROM negative
control, CPU-written/cleared native pixels, direct-query/viewport parity, changing
upstream Pong display states, and optional paired save/reopen. `--input` accepts
the separately built physical input probe. It uses Node File/Blob input and
temporary random-access files; it does not establish browser OPFS support or
Flutter frame rate. It must use the exact newly built Web artifacts, whose
linear-memory limit leaves headroom above the 192 MiB circuit budget.

The full acceptance harness defaults to OFF; pass `--optimized` for a separate
ON run using the same newly built artifact and program fixtures. During Pong,
it verifies an idle mode flip preserves exact native mono/color bytes, ready/RAM
lamps and electrical counters, runs another physical clock batch, then restores
the requested mode. Reports separate 128-clock batch median/p95 and physical
pulse rate by mode from program loading and pixel-query time.
