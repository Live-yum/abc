import 'dart:typed_data';

import '../domain/terraria_map.dart';
import 'map_backend_native.dart'
    if (dart.library.js_interop) 'map_backend_web.dart'
    as platform;

MapBackend createMapBackend() => platform.createMapBackend();

/// Bounded metadata only. All full MAP grids and history remain in the owner.
class MapSessionInfo {
  final int token, version, width, height, worldId, revision, ownedBytes;
  final String worldName;
  final bool chunked, isModified, canUndo, canRedo;
  const MapSessionInfo({
    required this.token,
    required this.version,
    required this.width,
    required this.height,
    required this.worldId,
    required this.worldName,
    required this.chunked,
    required this.isModified,
    required this.canUndo,
    required this.canRedo,
    required this.revision,
    required this.ownedBytes,
  });
  bool get isClosed => false;
  factory MapSessionInfo.fromJson(Map<String, dynamic> data) => MapSessionInfo(
    token: data['token'] as int,
    version: data['version'] as int,
    width: data['width'] as int,
    height: data['height'] as int,
    worldId: data['worldId'] as int,
    worldName: data['worldName'] as String,
    chunked: data['chunked'] as bool,
    isModified: data['modified'] as bool,
    canUndo: data['canUndo'] as bool,
    canRedo: data['canRedo'] as bool,
    revision: data['revision'] as int,
    ownedBytes: data['ownedBytes'] as int,
  );
}

abstract interface class MapBackend {
  /// Decode candidate first; a rejected file leaves the previous session intact.
  Future<MapSessionInfo> open(
    Uint8List bytes, {
    Map<String, Object?>? expectedWorld,
  });
  Future<MapSessionInfo> editRect(
    int x,
    int y,
    int width,
    int height, {
    int? light,
    int? color,
  });
  Future<MapSessionInfo> undo();
  Future<MapSessionInfo> redo();
  Future<TerrariaMapRaster> render({int maxWidth = 960});

  /// Encode and fully reopen/compare every tile inside the owning worker.
  Future<Uint8List> exportVerified();
  Future<void> close();
  Future<void> dispose();
}
