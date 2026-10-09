import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'engine.dart';

typedef _PropagateC = Int32 Function(
  Uint32,
  Uint32,
  Pointer<Uint32>,
  Uint32,
  Uint32,
  Uint32,
  Uint32,
  Pointer<Uint32>,
  Uint32,
  Pointer<Uint32>,
);
typedef _Propagate = int Function(
  int,
  int,
  Pointer<Uint32>,
  int,
  int,
  int,
  int,
  Pointer<Uint32>,
  int,
  Pointer<Uint32>,
);

/// Call only in the existing serialized native engine isolate.
class CircuitNativeBindings {
  final _Propagate _propagate;
  CircuitNativeBindings(DynamicLibrary library)
    : _propagate = library.lookupFunction<_PropagateC, _Propagate>(
        'abc_circuit_propagate',
      );
  List<int> propagate(List<dynamic> args) {
    final cells = (args[2] as List).cast<int>();
    if (cells.length % 4 != 0 || cells.length > 65536 * 4) {
      throw const EngineException('电路数据超过安全限制');
    }
    final count = cells.length ~/ 4;
    final input = calloc<Uint32>(cells.isEmpty ? 1 : cells.length);
    final output = calloc<Uint32>(count == 0 ? 1 : count);
    final size = calloc<Uint32>();
    try {
      input.asTypedList(cells.length).setAll(0, cells);
      final status = _propagate(
        args[0] as int,
        args[1] as int,
        input,
        count,
        args[3] as int,
        args[4] as int,
        args[5] as int,
        output,
        count,
        size,
      );
      if (status != 0) throw EngineException('原生电路执行失败：$status', status);
      if (size.value > count) throw const EngineException('电路输出越界');
      return output.asTypedList(size.value).toList();
    } finally {
      calloc.free(input);
      calloc.free(output);
      calloc.free(size);
    }
  }
}
