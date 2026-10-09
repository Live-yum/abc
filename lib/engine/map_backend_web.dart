import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import '../domain/terraria_map.dart';
import 'map_backend.dart';

@JS('createTerraMapClient')
external _Client _createClient();

extension type _Client(JSObject _) implements JSObject {
  external JSPromise<_Reply> invoke(
    JSString method,
    JSString args,
    JSUint8Array? bytes,
  );
  external void dispose();
}

extension type _Reply(JSObject _) implements JSObject {
  external JSString get json;
  external JSUint8Array? get bytes;
}

MapBackend createMapBackend() => _WebMapBackend();

class _WebMapBackend implements MapBackend {
  _Client? _client;
  int _token = 0, _generation = 0;
  bool _disposed = false;
  Future<_Reply> _call(
    String method,
    Map<String, Object?> args, [
    Uint8List? bytes,
  ]) async {
    if (_disposed) throw StateError('MAP backend disposed');
    final generation = _generation;
    final response = await (_client ??= _createClient())
        .invoke(method.toJS, jsonEncode(args).toJS, bytes?.toJS)
        .toDart;
    if (generation != _generation || _disposed) {
      throw StateError('MAP operation superseded');
    }
    return response;
  }

  Future<MapSessionInfo> _info(
    String method,
    Map<String, Object?> args, [
    Uint8List? bytes,
  ]) async {
    final generation = _generation;
    final response = await _call(method, args, bytes);
    if (generation != _generation || _disposed) {
      throw StateError('MAP operation superseded');
    }
    final info = MapSessionInfo.fromJson(
      jsonDecode(response.json.toDart) as Map<String, dynamic>,
    );
    _token = info.token;
    return info;
  }

  @override
  Future<MapSessionInfo> open(
    Uint8List bytes, {
    Map<String, Object?>? expectedWorld,
  }) => _info('open', {'expectedWorld': expectedWorld}, bytes);
  @override
  Future<MapSessionInfo> editRect(
    int x,
    int y,
    int width,
    int height, {
    int? light,
    int? color,
  }) => _info('edit', {
    'token': _token,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'light': light,
    'color': color,
  });
  @override
  Future<MapSessionInfo> undo() => _info('undo', {'token': _token});
  @override
  Future<MapSessionInfo> redo() => _info('redo', {'token': _token});
  @override
  Future<TerrariaMapRaster> render({int maxWidth = 960}) async {
    final response = await _call('render', {
      'token': _token,
      'maxWidth': maxWidth,
    });
    final meta = jsonDecode(response.json.toDart) as Map<String, dynamic>;
    return TerrariaMapRaster(
      meta['width'] as int,
      meta['height'] as int,
      response.bytes!.toDart,
    );
  }

  @override
  Future<Uint8List> exportVerified() async =>
      (await _call('export', {'token': _token})).bytes!.toDart;
  @override
  Future<void> close() async {
    _generation++;
    _client?.dispose();
    _client = null;
    _token = 0;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await close();
  }
}
