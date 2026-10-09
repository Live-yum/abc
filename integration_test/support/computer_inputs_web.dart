import 'dart:js_interop';

import 'package:terraforge/engine/world_circuit_backend.dart';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response(JSObject _) implements JSObject {
  external JSBoolean get ok;
  external JSPromise<_Blob> blob();
}

extension type _Blob(JSObject _) implements JSObject {
  external JSNumber get size;
}

Future<WorldCircuitSource> computerInput() async {
  Future<WorldCircuitSource> input(String address, String name) async {
    final uri = Uri.parse(address);
    if (!const ['localhost', '127.0.0.1', '::1'].contains(uri.host) ||
        !const ['http', 'https'].contains(uri.scheme)) {
      throw StateError(
        'Computer profile fixtures require explicit loopback URLs.',
      );
    }
    final response = await _fetch(address.toJS).toDart;
    if (!response.ok.toDart) {
      throw StateError('Cannot read the local computer fixture.');
    }
    final blob = await response.blob().toDart;
    return WorldCircuitSource.blob(
      blob: blob,
      length: blob.size.toDartInt,
      name: name,
    );
  }

  final result = await input(
    const String.fromEnvironment('COMPUTERRARIA_WLD_URL'),
    'computerraria.wld',
  );
  if (result.length != 405983441) {
    throw StateError(
      'This profile accepts only the pinned public Computerraria WLD.',
    );
  }
  return result;
}
