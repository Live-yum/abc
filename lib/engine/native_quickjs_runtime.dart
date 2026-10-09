import 'dart:ffi';
import 'dart:io';

import 'package:flutter_js/javascript_runtime.dart';
import 'package:flutter_js/quickjs/ffi.dart' as qjs;
import 'package:flutter_js/quickjs/quickjs_runtime2.dart';

/// flutter_js is pinned because this host uses its public runtime registry to
/// apply QuickJS's own heap limit. Some 0.8.7 binaries omit the optional
/// jsSetMemoryLimit wrapper, but export the underlying JS_SetMemoryLimit API.
/// The pointer is discovered and used entirely within the engine isolate.
QuickJsRuntime2 createBoundedQuickJsRuntime({
  int heapBytes = 256 * 1024 * 1024,
}) {
  final library = Platform.isWindows
      ? DynamicLibrary.open('quickjs_c_bridge.dll')
      : Platform.isAndroid
      ? DynamicLibrary.open('libfastdev_quickjs_runtime.so')
      : DynamicLibrary.open(
          Platform.environment['FLUTTER_TEST'] == 'true'
              ? Platform.environment['LIBQUICKJSC_TEST_PATH'] ??
                    'libquickjs_c_bridge_plugin.so'
              : Platform.environment['LIBQUICKJSC_PATH'] ??
                    'libquickjs_c_bridge_plugin.so',
        );
  final setLimit = library
      .lookupFunction<
        Void Function(Pointer<qjs.JSRuntime>, UintPtr),
        void Function(Pointer<qjs.JSRuntime>, int)
      >(
        library.providesSymbol('jsSetMemoryLimit')
            ? 'jsSetMemoryLimit'
            : 'JS_SetMemoryLimit',
      );
  final before = qjs.runtimeOpaques.keys.toSet();
  final runtime = _BoundedQuickJsRuntime();
  try {
    final created = qjs.runtimeOpaques.keys.where(
      (key) => !before.contains(key),
    );
    if (created.length != 1) {
      throw StateError('Could not identify the circuit JavaScript owner');
    }
    runtime.owner = created.single;
    setLimit(runtime.owner!, heapBytes);
    return runtime;
  } catch (_) {
    JavascriptRuntime.channelFunctionsRegistered.remove(
      runtime.getEngineInstanceId(),
    );
    runtime.dispose();
    rethrow;
  }
}

class _BoundedQuickJsRuntime extends QuickJsRuntime2 {
  _BoundedQuickJsRuntime() : super(stackSize: 2 * 1024 * 1024);

  Pointer<qjs.JSRuntime>? owner;
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      super.dispose();
    } finally {
      // flutter_js 0.8.7 frees C memory but leaves this registry entry alive,
      // retaining callbacks and making a reused native address look occupied.
      qjs.runtimeOpaques.remove(owner);
      JavascriptRuntime.channelFunctionsRegistered.remove(
        getEngineInstanceId(),
      );
    }
  }
}
