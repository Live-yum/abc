import 'dart:typed_data';

import 'region_document.dart';

/// A bounded, original-record-based block/wall transformation candidate.
///
/// This deliberately has no game-specific preset table and makes no claim that
/// structural furniture or the resulting world can safely be written. The
/// authoritative native core must still validate any eventual world operation.
class TerrainRulePlan {
  static const maxRules = 65535;
  static const maxRecords = 262144;

  final Uint8List _records;
  final int changedCells;
  final int blockChanges;
  final int wallChanges;
  final List<int> matchedCounts;
  final int sourceRevision;

  TerrainRulePlan._(
    this._records,
    this.changedCells,
    this.blockChanges,
    this.wallChanges,
    List<int> matchedCounts,
    this.sourceRevision,
  ) : matchedCounts = List<int>.unmodifiable(matchedCounts);

  Uint8List get records => Uint8List.fromList(_records);

  factory TerrainRulePlan.prepare(
    AdvancedRegionDocument region,
    List<Map<String, Object?>> rules,
  ) {
    if (rules.length > maxRules || region.recordCount > maxRecords) {
      throw const FormatException(
        'Terrain rule plan exceeds its bounded budget',
      );
    }
    final blocks = <int, ({int index, int target})>{};
    final walls = <int, ({int index, int target})>{};
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      final source = rule['source'];
      final sourceId = source is int
          ? source
          : source is String && RegExp(r'^[0-9]+$').hasMatch(source)
          ? int.tryParse(source)
          : null;
      final target = rule['target'];
      final layer = rule.containsKey('layer') ? rule['layer'] : 'block';
      if (rule['type'] != 'terrain' ||
          sourceId == null ||
          sourceId < 0 ||
          sourceId > 65535 ||
          target is! int ||
          target < 0 ||
          target > 65535 ||
          (layer != 'block' && layer != 'wall')) {
        throw FormatException('Invalid terrain rule at index $i');
      }
      final lookup = layer == 'block' ? blocks : walls;
      if (lookup.containsKey(sourceId)) {
        throw FormatException('Duplicate $layer source at rule index $i');
      }
      lookup[sourceId] = (index: i, target: target);
    }
    final revision = region.revision;
    final records = region.records;
    final data = ByteData.sublistView(records);
    final matches = List<int>.filled(rules.length, 0);
    var changedCells = 0, blockChanges = 0, wallChanges = 0;
    for (var at = 0; at < records.length; at += 32) {
      // Look up once from each ORIGINAL layer, so swaps never cascade.
      final block = data.getUint16(at + 8, Endian.little);
      final wall = data.getUint16(at + 16, Endian.little);
      final active = (data.getUint16(at + 10, Endian.little) & 1) != 0;
      final blockRule = active ? blocks[block] : null;
      final wallRule = walls[wall];
      var changed = false;
      if (blockRule != null) {
        matches[blockRule.index]++;
        if (blockRule.target != block) {
          data.setUint16(at + 8, blockRule.target, Endian.little);
          blockChanges++;
          changed = true;
        }
      }
      if (wallRule != null) {
        matches[wallRule.index]++;
        final clearsPaint = wallRule.target == 0 && data.getUint8(at + 19) != 0;
        if (wallRule.target != wall || clearsPaint) {
          data.setUint16(at + 16, wallRule.target, Endian.little);
          if (wallRule.target == 0) data.setUint8(at + 19, 0);
          wallChanges++;
          changed = true;
        }
      }
      if (changed) changedCells++;
    }
    return TerrainRulePlan._(
      records,
      changedCells,
      blockChanges,
      wallChanges,
      matches,
      revision,
    );
  }
}
