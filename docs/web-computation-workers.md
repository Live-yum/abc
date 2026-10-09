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
to 64 MiB, PLR to 2 MiB, TWLD to 16 MiB, JSON to at most 8 MiB, and worker output
to 160 MiB total. The engine enforces tighter method-specific output bounds,
including 128 MiB binary MAP. Default request deadlines include queueing and
are 120 seconds. Test callers can set a bounded deadline up to 600 seconds.

Inputs are copied when accepted and those copies are transferred at dispatch.
The application retains its original buffers, and later application mutations
cannot change a queued request. Worker outputs are transferred; the underlying
bridges already return independent copies of their retained state. Exactly one
request runs per owner, and the worker independently serializes requests.

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
- `node test/web/engine_worker_smoke.cjs`: actual browser worker bootstrap in
  Node workers, with local-only script/WASM adapters and the original generated
  fixtures. WLD/PLR exports, thumbnails, generated MAP, and TCW saved output are
  compared against direct bridge baselines. It verifies real worker termination,
  explicit reopen, source preservation, and four-colour traversal.

`TERRA_ENGINE_WORKER_REPORT` optionally names a local JSON report for the second
command. Its event-loop measurements describe the Node host only. They do not
measure browser frames, Flutter UI smoothness, mobile devices, or platform FPS.
The small original fixtures establish correctness, not large-world throughput.
