# Native engine owner lifecycle regression

`test/native_engine_lifecycle_test.dart` runs the actual Flutter NativeEngine,
QuickJS rules host, streamed world circuit, and Workspace controllers. It uses
only `assets/qa/synthetic-circuit.wld` and generated players. This is an ownership
regression, not a UI frame-rate or long-duration performance benchmark.

The native factory deliberately returns one process-owned engine. Repeated
`Workspace.close()` calls release document/session owners while leaving that
shared engine available for another Workspace. Shutting the engine down after
each Workspace would invalidate legitimate reuse.

## Run

Build the native engine with `ABC_PERF_COUNTERS=ON`, then use the pinned Flutter
version from `.flutter-version`:

```sh
export TERRAFORGE_ENGINE_LIBRARY="$PWD/build/native-release/libabc_engine.so"
export LIBQUICKJSC_TEST_PATH="$PUB_CACHE/hosted/pub.dev/flutter_js-0.8.7/linux/shared/libquickjs_c_bridge_plugin.so"
export TERRAFORGE_LIFECYCLE_VM=true
export TERRAFORGE_LIFECYCLE_OUTPUT="$PWD/build/native-engine-lifecycle.json"
flutter test --no-pub --enable-vmservice --concurrency=1 \
  test/native_engine_lifecycle_test.dart --reporter=expanded
```

The VM-specific test is opt-in so ordinary widget tests do not accidentally
claim to measure owners without a VM service. The output directory must exist.
Use a task-specific `TMPDIR` when the system temporary filesystem is small.

## What the regression establishes

Eight complete cycles exercise world import, player creation, close/reopen on
the same controller, rules editor initialization, ranged source circuit import,
trigger/step, successful and cancelled export, reset, repeated close, and
controller disposal. Each cycle checks:

- Exactly one native engine worker is added to the initial VM topology.
- The same isolate IDs and live-port counts persist across all cycles.
- Native live-byte counters do not grow and open world handles return to zero.
- Export leases disappear after both accepted and cancelled saves.
- Session/output temporary directories return to their original set.
- The synthetic original file remains byte-identical.

Heap and external bytes are sampled once per unique isolate group after a GC
request. `Isolate.spawn` workers share their group's heap; summing per-isolate
`getMemoryUsage` values double-counts that heap. See the Dart VM implementation
of [Isolate::PrintMemoryUsageJSON](https://github.com/dart-lang/sdk/blob/main/runtime/vm/isolate.cc)
and the explicit `getIsolateGroupMemoryUsage` VM-service API. The report records
both isolate and group identities so the counting boundary is reviewable.

The process-owned QuickJS runtime also remains initialized. Native C counters
do not include all QuickJS/libc allocations. RSS includes allocator/cache
retention and the Flutter test harness. Neither a positive RSS slope nor a
single passing test establishes the presence or absence of every possible leak.
Full-world/profile/soak evidence is separate.
