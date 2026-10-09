import 'dart:js_interop';

import 'package:crypto/crypto.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type _Response(JSObject _) implements JSObject {
  external JSBoolean get ok;
  external JSPromise<_Blob> blob();
}

extension type _Blob(JSObject _) implements JSObject {
  external JSNumber get size;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

Future<({WorldCircuitSource world, WorldCircuitSource twld})>
computerInputs() async {
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

  final result = (
    world: await input(
      const String.fromEnvironment('COMPUTERRARIA_WLD_URL'),
      'computerraria.wld',
    ),
    twld: await input(
      const String.fromEnvironment('COMPUTERRARIA_TWLD_URL'),
      'computerraria.twld',
    ),
  );
  if (result.world.length != 405983441 || result.twld.length != 427712) {
    throw StateError(
      'This profile accepts only the pinned public Computerraria pair.',
    );
  }
  final sidecar = await _Blob(result.twld.blob! as JSObject)
      .arrayBuffer()
      .toDart;
  if (sha256.convert(sidecar.toDart.asUint8List()).toString() !=
      'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8') {
    throw StateError('The public companion fixture hash differs.');
  }
  return result;
}
