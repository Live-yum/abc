import 'dart:typed_data';

import 'engine.dart';

/// Produces a real binary Terraria .map from an existing world session.
/// The result is a generated fully explored map, not a player's explored save.
abstract interface class WorldMapBackend {
  Future<Uint8List> generateWorldMap(
    EngineDocument world, {
    Map<String, Object?>? markers,
  });
}

Map<String, Object?> validatedMapMarkers(Map<String, Object?>? markers) {
  if (markers == null) return const {};
  if (markers.keys.any(
    (key) => !{'chest_markers', 'tile_markers'}.contains(key),
  )) {
    throw const EngineException('MAP 标记只接受箱子物品和方块标记');
  }
  return Map<String, Object?>.from(markers);
}
