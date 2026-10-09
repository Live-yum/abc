# Authoritative circuit rules host

The full component editor uses the user-authorized `Live-yan/viewer-app` circuit domain,
editor, catalog and computation session at commit
`366ebc57751cadfb077f968f4d5069028b3bf9a6`. Its exact module subset is attributed
under `vendor/viewer-circuit`; the original reference checkout stays unchanged.
The Flutter host does not translate the device
rules into a second Dart implementation. This host is separate from the legacy
small `terraforge.circuit` sandbox and from `.wld` world sessions.

The retained document format is `viewer-terralogic`, schema version 1. The
authoritative parser validates the game's target/source, four wire colors,
tiles, coordinates, native object data, mechanical state and simulation state.
It also owns the original editor history and placement checks. Importing an
invalid document keeps the current editor recoverable. The current pinned
catalog contains 2,776 palette entries and 15 built-in examples.

## Building attributed artifacts

Use the pinned root dependency and included source subset:

```sh
npm ci
node tool/build_circuit_rules.mjs
```

An optional source override supports an authorized checkout or previously
retrieved archive. Each imported file must match its pinned Git commit or the
retrieval manifest's Git blob SHA and byte length. The included subset uses
its own `retrieved-source-manifest.json` automatically:

```sh
node tool/build_circuit_rules.mjs /path/to/authorized/source \
  /path/to/retrieved-source-manifest.json
```

The helper uses the project's pinned `esbuild` 0.20.1, resolves only the
required module closure, rejects external imports and records exact SHA-256
hashes for the 40 source modules, original adapters, host files, build helper
and both outputs. Generated files are:

- `assets/private/circuit_rules_native.js`
- `assets/private/circuit_rules.provenance.json`
- `web/engine/circuit_rules_web.js`

These generated outputs can be recreated during builds. The user explicitly
authorized including the referenced engine/rules source,
required tables and compiled artifacts in abc. Preserve the original source
attribution and generated provenance with verified runtime distributions; this authorization
does not create a new upstream license grant. Game artwork, game executables
and personal saves remain excluded. The packaging helper itself contains no
copied implementation or catalog tables. The historical `assets/private/`
directory name is retained for asset-loader compatibility.

The Web worker also requires the independently verified `world.js` and
`world.wasm` in `web/engine/`; use the existing authorized Web-engine build
workflow. All resources are local app assets. No remote service, hidden
metadata endpoint or dynamically downloaded game data is used.

## Execution and ownership

Both hosts implement `CircuitRulesBackend.invokeCircuitRules(method, args)`
with JSON-only values. The public methods are capabilities/catalog; editor
new/open/demo/snapshot/command/close; and simulation command/reset/cancel.
There is no arbitrary property lookup or script evaluation at the public API.

Native runs the attributed bundle inside the serialized engine isolate's embedded
JavaScript runtime. A synchronous `terraCircuitNative` callback sends bounded
word arrays to the native traversal ABI. Synthetic JavaScript heap offsets are
only marshalling-buffer positions. They are never native pointers and never
truncate a 64-bit address. Device events are applied before traversal resumes,
preserving dynamic topology, junction, pixel and original color-pass order.
The diagnostic backend label is `native` for this transport.

Web uses a dedicated worker containing the same original rules and actual WASM
traversal. It yields between complete atomic commands. New document, reset,
cancel and close invalidate obsolete queued work and ignore old responses.
Cancel takes effect after an already-running atomic command; it does not split
the original rules transaction. Dispose/page exit terminates the owner.
Worker startup failure can be retried; timeout or worker loss rejects pending
requests and requires reopening the circuit. It never silently retries a
mutating command in a fresh owner.

`host.reset` is intercepted by each host, never dispatched to the domain
facade. It disposes the circuit owner and clears its startup cache; the next
call starts a fresh owner. Existing world, player and region owners remain
untouched. Recovery reopens the caller's last accepted document explicitly.

Boundaries include 8 MiB document UTF-8, 16 MiB request/reply UTF-8, 32 pending
Web requests/32 MiB combined queued input, four retained editor/computation
sessions per category, 256 MiB conservative retained-JavaScript admission,
250,000 cells per editing operation, 8,192 trigger points and at most 60 ticks
per simulation call. Native allocation/work limits and authoritative history,
trace and command limits remain in force. These estimates are admission
budgets, not exact total-process heap measurements.

## Verification

```sh
node --test test/web/circuit_rules_lifecycle.cjs
TERRA_CIRCUIT_SOURCE="$PWD/vendor/viewer-circuit" \
TERRA_WORLD_RUNTIME=/path/to/verified/world.js \
TERRA_CIRCUIT_CORPUS="$PWD/qa-evidence/circuit-rules-corpus.json" \
  node --expose-gc --max-old-space-size=256 tool/test_circuit_rules.mjs
```

The local parity runner checks all 15 demos and editor import/export,
copy/paste/rotation, undo/redo, actuator changes, simulation reset, malformed
commands, rejected import preservation, session limits and stale IDs. It
compares the Web bundle and native transport shim against the original
JavaScript computation oracle using actual WASM; transport diagnostics are
excluded from behavioral comparisons. It checks release of every callback
allocation and native traversal handle. The generated replay corpus
stays in ignored `qa-evidence/`, and uses document hashes to avoid duplicating
large examples. Its bounded native replay subset covers the first four demo
commands followed by reset; the JS/WASM runner executes the full sequence.

The lifecycle tests separately cover byte/queue bounds, whitelists,
cancellation, stale generations, close/replacement, startup retry, disposal
during startup, timeout and owner recreation. Native runtime proof tests cover
the real embedded engine/FFI path separately; the shim test alone is not a
target-platform native build or in-game compatibility certification.
