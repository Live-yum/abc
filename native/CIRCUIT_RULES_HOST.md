# Native circuit rules host

`NativeCircuitRulesRuntime` runs the authorized, generated rules bundle
inside the existing serialized engine isolate. It uses JavaScriptCore on iOS /
macOS and the pinned `flutter_js` 0.8.7 QuickJS runtime on other native targets.
The source subset and generated bundle are included with the user's publication
authorization. `npm ci && npm run build:circuit-rules` rebuilds them entirely from
`vendor/viewer-circuit`. See `assets/private/README.txt` and
`THIRD_PARTY_NOTICES.md` for provenance and retained upstream rights.

The synchronous `terraCircuitNative` callback dispatches copied JSON integers to
`abc_circuit_rules_*`. Native pointers never cross JavaScript or isolate messages.
The retained traversal pauses at a device before expanding outgoing edges, so
the private JavaScript device rule can apply topology patches before C resumes.
Callbacks must not enqueue `_NativeEngine._call`: the owner isolate is already
waiting for that callback.

## Bounds and lifecycle

- Requests and reply payloads are bounded to 16 MiB (plus 8 KiB host envelope
  allowance on replies); method names, argument counts,
  integer domains, callback arities and fixed record strides are checked.
- The retained private facade imposes document, operation, trace, session and
  aggregate retained-memory budgets. Input validation remains in that facade.
- Each C graph is limited to 1,048,576 cells and 128 MiB. The Dart bridge reserves
  at most 256 MiB across eight handles, including temporary replacement graphs.
  Actual defaults in the retained traversal reserve 64 MiB per graph.
- Native load/compile/patch/step calls process at most 4,096 records; an activation
  accepts at most 8,192 seeds. Native work limits cancel a failed traversal.
- QuickJS has a tested 256 MiB C heap limit and a 2 MiB stack limit. The pinned
  package's Linux binary lacks `jsSetMemoryLimit`, so the host calls its exported
  core `JS_SetMemoryLimit` API against the one newly registered runtime. It fails
  initialization if that limit cannot be applied. JavaScriptCore has no equivalent
  portable heap-cap API here; it relies on the facade and bridge admission limits.
  These are separate JavaScript and native graph budgets, not a whole-process cap.
- Runtime timers and Promise results are rejected; all operations are synchronous
  in the owner. Flutter remains asynchronous across its isolate boundary.
- Disposal releases facade sessions, all owned native handles, callbacks and the
  QuickJS registry entry that the pinned dependency otherwise retains. Failed
  bundle initialization also releases partially created handles. Asset reads do
  not cache failures, and an explicit `dispose` permits a later fresh owner.
  `host.reset` is intercepted by the host and has the same lazy reinitialization
  behavior. It queues behind active work and preserves unrelated WLD/TCW handles.

Circuit, TCW and player allocations use the engine's persistent allocation domain.
World close/rewind releases the separate native arena, so a retained low-level
circuit graph survives WLD/TCW close and reopen. They still require one serialized
C owner; this does not authorize opening incompatible simultaneous WLD sessions.

## Executable Linux verification

Build the included native engine and generated bundle, then run:

```sh
TERRAFORGE_ENGINE_LIBRARY=/absolute/path/libabc_engine.so \
LIBQUICKJSC_TEST_PATH=/absolute/pub-cache/flutter_js-0.8.7/linux/shared/libquickjs_c_bridge_plugin.so \
CI=true flutter test --no-pub --concurrency=1 native/circuit_rules_runtime_smoke_test.dart native/circuit_rules_bundle_test.dart
```

The smoke test verifies pause/patch/resume in a real QuickJS isolate, error and
budget handling, the C heap limit, repeated failed-init/dispose/recreate cycles,
and WLD + TCW coexistence across close/reopen. The bundle test runs all 15 retained
demos, checks native traversal without fallback, 60-tick execution, reset,
export/import, initialization retry and existing WLD/PLR/region APIs. The large
register fixture has 10,304 tiles and 26,688 wire cells; its complete multi-operation
Linux test took about 31 seconds. The other demos took below one second each.

After `tool/test_circuit_rules.mjs` generates the ignored local corpus,
`native/circuit_rules_corpus_test.dart` replays 154 sequential shared cases in
QuickJS + FFI. It compares normalized packet values and SHA-256 hashes of exact
serialized documents against the authoritative-source/Web corpus. This covers
all 15 demos, editing, undo/redo, clipboard transformations, actuation, import
failures, retained-owner limits and stale sessions. That replay passed locally.

Android, iOS and macOS compilation and runtime behavior remain unverified until
run on those target toolchains/devices. Linux QuickJS results do not establish
JavaScriptCore behavior or target-platform packaging. The CI native job performs
the runtime, all-demo and shared-corpus proofs using the pinned Linux QuickJS
library. Public CI keeps real private saves and resource packs out of its inputs;
tests requiring them may skip and must not be described as a zero-skip run.
