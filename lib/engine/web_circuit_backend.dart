import 'dart:convert';
import 'dart:js_interop';

import 'circuit_backend.dart';

@JS('terraCircuit')
external _Bridge get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<JSString> propagate(
    JSNumber width,
    JSNumber height,
    JSString cells,
    JSNumber x,
    JSNumber y,
    JSNumber colour,
  );
}

class WebCircuitBackend implements CircuitBackend {
  @override
  Future<List<int>> propagate(
    int width,
    int height,
    List<int> cells,
    int x,
    int y,
    int colour,
  ) async {
    final result = await _bridge
        .propagate(
          width.toJS,
          height.toJS,
          jsonEncode(cells).toJS,
          x.toJS,
          y.toJS,
          colour.toJS,
        )
        .toDart;
    return (jsonDecode(result.toDart) as List).cast<int>();
  }
}
