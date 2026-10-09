import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'engine.dart';
import 'circuit_rules_backend.dart';
import 'world_map_backend.dart';

@JS('terraCircuitRules')
external _CircuitRulesBridge get _circuitRulesBridge;

extension type _CircuitRulesBridge(JSObject _) implements JSObject {
  external JSPromise<JSString> invoke(JSString method, JSString args);
}

@JS('terraForge')
external _Bridge get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<JSString> createPlayer(JSString name);
  external JSPromise<JSString> open(JSUint8Array bytes, JSString kind);
  external JSPromise<JSString> inspect(JSNumber handle);
  external JSPromise<JSAny?> mutate(
    JSNumber handle,
    JSString operation,
    JSString args,
  );
  external JSPromise<JSUint8Array> save(JSNumber handle);
  external JSPromise<JSUint8Array> generateMap(
    JSNumber handle,
    JSString markers,
  );
  external JSPromise<JSUint8Array?> preview(JSNumber handle);
  external JSPromise<JSAny?> close(JSNumber handle);
}

TerraEngine createTerraEngine() => WebTerraEngine();
TerraEngine createWebEngine() => createTerraEngine();

class WebTerraEngine
    implements
        TerraEngine,
        CreatablePlayerEngine,
        CircuitRulesBackend,
        WorldMapBackend {
  @override
  Future<Uint8List> generateWorldMap(
    EngineDocument world, {
    Map<String, Object?>? markers,
  }) => _guard(() async {
    if (world.kind != 'wld') throw const EngineException('只有世界可以生成 MAP');
    final request = markers == null ? null : validatedMapMarkers(markers);
    final bytes = await _bridge
        .generateMap(world.handle.toJS, jsonEncode(request).toJS)
        .toDart;
    return Uint8List.fromList(bytes.toDart);
  });
  @override
  Future<Object?> invokeCircuitRules(String method, List<Object?> args) =>
      _guard(() async {
        final response = await _circuitRulesBridge
            .invoke(method.toJS, jsonEncode(args).toJS)
            .toDart;
        return jsonDecode(response.toDart);
      });

  @override
  Future<EngineDocument> createPlayer(String name) => _guard(() async {
    final value = await _bridge.createPlayer(name.toJS).toDart;
    final data = jsonDecode(value.toDart) as Map<String, dynamic>;
    return EngineDocument(
      data['handle'] as int,
      data['kind'] as String,
      data['metadata'] as Map<String, dynamic>,
    );
  });

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (error) {
      throw EngineException(error.toString());
    }
  }

  @override
  Future<EngineDocument> open(Uint8List bytes, {required String kind}) =>
      _guard(() async {
        final value = await _bridge.open(bytes.toJS, kind.toJS).toDart;
        final data = jsonDecode(value.toDart) as Map<String, dynamic>;
        return EngineDocument(
          data['handle'] as int,
          data['kind'] as String,
          data['metadata'] as Map<String, dynamic>,
        );
      });

  @override
  Future<Map<String, dynamic>> inspect(EngineDocument doc) => _guard(() async {
    final value = await _bridge.inspect(doc.handle.toJS).toDart;
    return jsonDecode(value.toDart) as Map<String, dynamic>;
  });

  @override
  Future<void> mutate(
    EngineDocument doc,
    String operation,
    Map<String, dynamic> args,
  ) => _guard(() async {
    await _bridge
        .mutate(doc.handle.toJS, operation.toJS, jsonEncode(args).toJS)
        .toDart;
  });

  @override
  Future<Uint8List> save(EngineDocument doc) => _guard(() async {
    final bytes = await _bridge.save(doc.handle.toJS).toDart;
    return Uint8List.fromList(bytes.toDart);
  });

  @override
  Future<Uint8List?> preview(EngineDocument doc) => _guard(() async {
    final bytes = await _bridge.preview(doc.handle.toJS).toDart;
    return bytes == null ? null : Uint8List.fromList(bytes.toDart);
  });

  @override
  Future<void> close(EngineDocument doc) => _guard(() async {
    await _bridge.close(doc.handle.toJS).toDart;
  });
}
