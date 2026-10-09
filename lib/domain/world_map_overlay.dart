import 'dart:typed_data';

/// A complete, immutable snapshot of a bounded engine region. Arrays are
/// row-major; native records may arrive in any order. Liquid kinds preserve the engine ABI:
/// dry=0, water=1, lava=2, honey=3, shimmer=4.
class WorldMapOverlay {
  static const maxCells = 262144;
  static const maxCoordinate = 0x7fffffff;
  final int x, y, width, height;
  final Uint8List wireMasks, liquidAmounts, liquidKinds;
  final List<int> wireCounts, liquidCounts;
  int get cellCount => width * height;
  int get liquidCellCount => liquidCounts.fold(0, (a, b) => a + b);
  int get wiredCellCount => wireMasks.where((mask) => mask != 0).length;

  WorldMapOverlay._({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.wireMasks,
    required this.liquidAmounts,
    required this.liquidKinds,
    required this.wireCounts,
    required this.liquidCounts,
  });

  factory WorldMapOverlay.fromRecords({
    required int x,
    required int y,
    required int width,
    required int height,
    required Uint8List records,
  }) {
    if (x < 0 ||
        y < 0 ||
        width <= 0 ||
        height <= 0 ||
        width > maxCells ||
        height > maxCells ||
        width * height > maxCells ||
        x > maxCoordinate - width ||
        y > maxCoordinate - height) {
      throw const FormatException('Invalid map overlay bounds');
    }
    final count = width * height;
    if (records.length != count * 32) {
      throw const FormatException('Map overlay requires one record per cell');
    }
    final wireMasks = Uint8List(count),
        amounts = Uint8List(count),
        kinds = Uint8List(count),
        seen = Uint8List(count);
    final wireCounts = List<int>.filled(4, 0),
        liquidCounts = List<int>.filled(4, 0);
    final data = ByteData.sublistView(records);
    for (var at = 0; at < records.length; at += 32) {
      final rx = data.getUint32(at, Endian.little),
          ry = data.getUint32(at + 4, Endian.little),
          layers = data.getUint32(at + 20, Endian.little);
      if (rx >= width || ry >= height) {
        throw const FormatException('Map overlay record outside bounds');
      }
      final index = ry * width + rx;
      if (seen[index] != 0) {
        throw const FormatException('Duplicate map overlay coordinate');
      }
      seen[index] = 1;
      final amount = layers & 255,
          rawKind = (layers >> 8) & 255,
          wires = layers >> 24,
          slope = (layers >> 16) & 255;
      if ((data.getUint32(at + 8, Endian.little) >> 16) > 127 ||
          wires > 15 ||
          rawKind > 4 ||
          slope > 7 ||
          ((amount == 0) != (rawKind == 0)) ||
          data.getUint32(at + 24, Endian.little) != 0 ||
          data.getUint32(at + 28, Endian.little) != 0) {
        throw const FormatException('Invalid map overlay layers');
      }
      wireMasks[index] = wires;
      amounts[index] = amount;
      kinds[index] = rawKind;
      for (var bit = 0; bit < 4; bit++) {
        if ((wires & (1 << bit)) != 0) wireCounts[bit]++;
      }
      if (amount != 0) liquidCounts[kinds[index] - 1]++;
    }
    return WorldMapOverlay._(
      x: x,
      y: y,
      width: width,
      height: height,
      wireMasks: wireMasks.asUnmodifiableView(),
      liquidAmounts: amounts.asUnmodifiableView(),
      liquidKinds: kinds.asUnmodifiableView(),
      wireCounts: List<int>.unmodifiable(wireCounts),
      liquidCounts: List<int>.unmodifiable(liquidCounts),
    );
  }
}
