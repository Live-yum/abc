import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// This test-only ABI is absent from production builds. Invoke only after all
/// serialized owner calls finish; it intentionally does not synchronize C.
class NativeAllocationCounters {
  final DynamicLibrary library;
  NativeAllocationCounters(String path) : library = DynamicLibrary.open(path);

  bool get available => library.providesSymbol('abc_perf_abi_version');
  int _read(String symbol) =>
      library.lookupFunction<Uint32 Function(), int Function()>(symbol)();

  String? get compiler => available
      ? library
            .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
              'abc_perf_compiler',
            )()
            .toDartString()
      : null;

  Map<String, Object?> snapshot() => available
      ? {
          'nativeTotalLiveBytes': _read('abc_perf_total_live_bytes'),
          'nativeLiveBytes': _read('abc_perf_native_live_bytes'),
          'nativeBridgeLiveBytes': _read('abc_perf_bridge_live_bytes'),
          'nativeAllocatorPeakBytes': _read('abc_perf_peak_bytes'),
          'nativeWorldOpenCount': _read('abc_perf_world_open_count'),
        }
      : {
          'nativeTotalLiveBytes': null,
          'nativeLiveBytes': null,
          'nativeBridgeLiveBytes': null,
          'nativeAllocatorPeakBytes': null,
          'nativeWorldOpenCount': null,
        };
}
