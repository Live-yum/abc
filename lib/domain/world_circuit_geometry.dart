import 'dart:typed_data';

import '../engine/world_circuit_backend.dart';
import 'fusion_placement.dart';
import 'resource_catalog.dart';

/// Exact imported placement frames for command 7. This is not a catalog of all
/// procedural or electrically changed frames. Unsupported support rules remain
/// visible to the host even though zero is the ABI's legacy anchor value.
class WorldCircuitGeometry {
  final List<int> records;
  final Set<(int, int)> _verifiedSupports;
  final Set<int> _framedTypes;
  final int ambiguousFrameCount, unverifiedSupportFrameCount;
  WorldCircuitGeometry._(
    List<int> records,
    this._verifiedSupports,
    this._framedTypes,
    this.ambiguousFrameCount,
    this.unverifiedSupportFrameCount,
  ) : records = List.unmodifiable(records);

  factory WorldCircuitGeometry.fromCatalog(
    ResourceCatalog catalog, {
    required int worldVersion,
  }) {
    if (worldVersion != 326 || catalog.gameVersion != '1.4.5.8') {
      throw const FormatException('世界电路占格需要对应 WLD 326 的 1.4.5.8 本地资源包');
    }
    final rows = catalog.families['tile-object-data'];
    if (rows == null || rows.isEmpty || rows.length > 20000) {
      throw const FormatException('本地资源包缺少有界的 tile-object-data');
    }
    final shapes = <(int, int), (int, int?)?>{};
    final types = <int>{};
    for (final entry in rows) {
      final row = FusionPlacementGeometry.fromEntry(entry);
      types.add(row.tile);
      final explicitAnchor = entry.fields['circuitAnchor'];
      if (explicitAnchor != null &&
          (explicitAnchor is! int ||
              explicitAnchor < 0 ||
              explicitAnchor > 17)) {
        throw const FormatException('电路占格支撑代码无效');
      }
      final anchor = explicitAnchor as int? ?? _documentedAnchor(row);
      for (var dx = 0; dx < row.width; dx++) {
        for (var dy = 0; dy < row.height; dy++) {
          final frame = row.frameAt(dx, dy);
          final key = (
            row.tile,
            (frame.$1 & 65535) | ((frame.$2 & 65535) << 16),
          );
          final value = (
            dx | (dy << 8) | (row.width << 16) | (row.height << 24),
            anchor,
          );
          if (shapes.containsKey(key)) {
            final prior = shapes[key];
            if (prior != null && prior != value) {
              if (prior.$1 != value.$1 ||
                  (prior.$2 != null && value.$2 != null)) {
                shapes[key] = null;
              } else {
                // An unverified alternate with the same footprint invalidates
                // support confidence, without inventing a geometry conflict.
                shapes[key] = (value.$1, null);
              }
            }
          } else {
            if (shapes.length >= 65536) {
              throw const FormatException('电路占格超过 65536 条记录上限');
            }
            shapes[key] = value;
          }
        }
      }
    }
    final records = <int>[], verified = <(int, int)>{};
    var ambiguous = 0, unverified = 0;
    for (final entry in shapes.entries) {
      final shape = entry.value;
      if (shape == null) {
        ambiguous++;
        continue;
      }
      records.addAll([entry.key.$1, entry.key.$2, shape.$1, shape.$2 ?? 0]);
      if (shape.$2 != null) {
        verified.add(entry.key);
      } else {
        unverified++;
      }
    }
    return WorldCircuitGeometry._(
      records,
      Set.unmodifiable(verified),
      Set.unmodifiable(types),
      ambiguous,
      unverified,
    );
  }

  /// Unknown anchor rules and simulation frames outside the imported catalog
  /// may be inspected but require verification before a world placement.
  bool supportsVerifiedFor(WorldCircuitExtraction extraction) {
    final bytes = extraction.records, data = ByteData.sublistView(bytes);
    for (var at = 0; at < bytes.length; at += 32) {
      final tile = data.getUint32(at + 8, Endian.little), type = tile & 65535;
      if ((tile & (1 << 16)) == 0 || !_framedTypes.contains(type)) continue;
      if (!_verifiedSupports.contains((
        type,
        data.getUint32(at + 12, Endian.little),
      ))) {
        return false;
      }
    }
    return true;
  }
}

/// Narrow rules checked against pinned 1.4.5.8 placement/WorldGen semantics.
/// Codes are the public terra_circuit_world.h 0..17 placement ABI. Dimensions
/// must agree; all other layouts need explicit circuitAnchor metadata.
int? _documentedAnchor(FusionPlacementGeometry row) {
  final shape = (row.width, row.height), tile = row.tile;
  if (row.frameX < 0 || row.frameY < 0) return null;
  // Alternate indices can change attachment side, not only visual facing.
  // Only these frame-specific public rules cover all alternates here.
  if (row.alternate != 0 && ![4, 11, 55, 425, 573, 442].contains(tile)) {
    return null;
  }
  if (tile == 4 && shape == (1, 1)) return 13;
  if (tile == 10 && shape == (1, 3)) return 3;
  if (tile == 11 && shape == (2, 3)) return row.frameX % 72 >= 36 ? 10 : 9;
  if (tile == 136 && shape == (1, 1)) return 5;
  if (tile == 132 && shape == (2, 2)) return 7;
  if (tile == 419 && shape == (1, 1)) return 8;
  if ([19, 144, 420, 423].contains(tile) && shape == (1, 1)) return 0;
  if ([21, 467, 85, 395].contains(tile) && shape == (2, 2)) return 1;
  if ([88].contains(tile) && shape == (3, 2)) return 1;
  if ([378, 470].contains(tile) && shape == (2, 3)) return 1;
  if ([475, 597].contains(tile) && shape == (3, 4)) return 1;
  if (tile == 471 && shape == (3, 3)) return 6;
  if (tile == 520 && shape == (1, 1)) return 1;
  if (tile == 698 && shape == (1, 2)) return 2;
  if ([135, 141, 428, 723, 724].contains(tile) && shape == (1, 1)) return 1;
  if ([55, 425, 573].contains(tile) && shape == (2, 2)) {
    return [1, 2, 15, 16, 6][row.frameX ~/ 36 % 5];
  }
  if (tile == 442 && shape == (1, 1)) {
    return [1, 2, 15, 16][row.frameX ~/ 22 % 4];
  }
  return null;
}
