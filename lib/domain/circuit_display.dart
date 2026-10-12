import 'dart:typed_data';

import '../engine/world_circuit_backend.dart';

/// A selected world rectangle containing native PixelBox cells.
/// Sparse gaps are transparent; an actual unlit PixelBox is opaque black.
class CircuitDisplayRegion {
  final String name;
  final int x, y, width, height;
  const CircuitDisplayRegion(
    this.name,
    this.x,
    this.y,
    this.width,
    this.height,
  );

  WorldCircuitCommand get command =>
      WorldCircuitCommand.pixels(x, y, width, height);

  void validate() {
    if (x < 0 ||
        y < 0 ||
        width < 1 ||
        height < 1 ||
        width > 65536 ||
        height > 65536 ||
        width * height > 65536) {
      throw const FormatException('像素选区须为有效世界矩形，最多 65536 格。');
    }
    WorldCircuitCommand.pixels(x, y, width, height);
  }

  Uint8List decode(WorldCircuitResult response) {
    validate();
    if (response.resultKind != 9 ||
        response.records.length % 16 != 0 ||
        response.records.length ~/ 16 > width * height) {
      throw const FormatException('像素选区返回了无效的稀疏记录。');
    }
    final rgba = Uint8List(width * height * 4);
    final seen = Uint8List(width * height);
    final data = ByteData.sublistView(response.records);
    for (var at = 0; at < response.records.length; at += 16) {
      final px = data.getUint32(at, Endian.little) - x;
      final py = data.getUint32(at + 4, Endian.little) - y;
      final tile = data.getUint32(at + 8, Endian.little) & 65535;
      final frameX = data.getInt16(at + 12, Endian.little);
      final frameY = data.getInt16(at + 14, Endian.little);
      if (px < 0 ||
          py < 0 ||
          px >= width ||
          py >= height ||
          tile != 445 ||
          (frameX != 0 && frameX != 18) ||
          frameY != 0) {
        throw const FormatException('选区包含无效或不支持的原版 PixelBox 状态。');
      }
      final index = py * width + px;
      if (seen[index] != 0) throw const FormatException('像素选区记录重复。');
      seen[index] = 1;
      final value = frameX == 18 ? 255 : 0;
      rgba[index * 4] = value;
      rgba[index * 4 + 1] = value;
      rgba[index * 4 + 2] = value;
      rgba[index * 4 + 3] = 255;
    }
    return rgba;
  }
}
