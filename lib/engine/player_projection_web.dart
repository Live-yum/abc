import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'engine.dart';
import 'player_projection_backend.dart';

@JS('terraForge')
external _ProjectionBridge get _bridge;

extension type _ProjectionBridge(JSObject _) implements JSObject {
  external JSPromise<JSUint8Array> projectPlayer(JSString candidate);
}

class WebPlayerProjectionBackend implements PlayerProjectionBackend {
  @override
  Future<Uint8List> projectPlayer(Map<String, Object?> candidate) async {
    try {
      final result = await _bridge
          .projectPlayer(jsonEncode(candidate).toJS)
          .toDart;
      return Uint8List.fromList(result.toDart);
    } catch (error) {
      throw EngineException(error.toString());
    }
  }
}
