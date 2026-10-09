import 'dart:typed_data';

import '../domain/terraria_map.dart';

class MapWorkerReply {
  final Map<String, Object?> metadata;
  final Uint8List? bytes;
  const MapWorkerReply(this.metadata, [this.bytes]);
}

/// Shared synchronous implementation, invoked exclusively inside an isolate
/// or a dedicated Web Worker. No full decoded grid crosses the owner boundary.
class MapWorkerOwner {
  TerrariaMapSession? _map;
  int _token = 0;
  MapWorkerReply invoke(
    String method,
    Map<String, dynamic> args, [
    Uint8List? bytes,
  ]) {
    if (method == 'open') {
      if (bytes == null) throw ArgumentError('MAP input bytes missing');
      final candidate = TerrariaMapSession.decode(bytes);
      final expected = args['expectedWorld'] as Map?;
      if (expected != null) {
        final actual = candidate.metadata;
        if (expected.entries.any(
          (e) =>
              !{'worldId', 'worldName', 'width', 'height'}.contains(e.key) ||
              actual[e.key] != e.value,
        )) {
          candidate.close();
          throw StateError(
            'Generated MAP world identity does not match source world',
          );
        }
      }
      _map?.close();
      _map = candidate;
      _token++;
      return _info();
    }
    if (method == 'close') {
      _map?.close();
      _map = null;
      _token++;
      return const MapWorkerReply({'closed': true, 'ownedBytes': 0});
    }
    final map = _map;
    if (map == null || args['token'] != _token) {
      throw StateError('MAP session is closed or superseded');
    }
    switch (method) {
      case 'edit':
        map.editRect(
          args['x'] as int,
          args['y'] as int,
          args['width'] as int,
          args['height'] as int,
          light: args['light'] as int?,
          color: args['color'] as int?,
        );
        return _info();
      case 'undo':
        map.undo();
        return _info();
      case 'redo':
        map.redo();
        return _info();
      case 'render':
        final raster = map.renderExplorationRgba(
          maxWidth: args['maxWidth'] as int? ?? 960,
        );
        return MapWorkerReply({
          'token': _token,
          'revision': map.revision,
          'width': raster.width,
          'height': raster.height,
        }, raster.rgba);
      case 'export':
        final output = map.exportBytes();
        final reopened = TerrariaMapSession.decode(output);
        try {
          if (!map.contentEquals(reopened)) {
            throw StateError('MAP export read-back mismatch');
          }
        } finally {
          reopened.close();
        }
        return MapWorkerReply({
          'token': _token,
          'verified': true,
          'bytes': output.length,
        }, output);
      default:
        throw ArgumentError('Unsupported MAP worker operation');
    }
  }

  MapWorkerReply _info() {
    final map = _map!;
    return MapWorkerReply({
      ...map.metadata,
      'token': _token,
      'revision': map.revision,
      'canUndo': map.canUndo,
      'canRedo': map.canRedo,
      'ownedBytes': map.ownedBytes,
    });
  }
}
