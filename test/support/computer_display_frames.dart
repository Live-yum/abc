import 'dart:typed_data';

import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

WorldCircuitResult displayFrame(
  ComputerDisplayRegion region, {
  int phase = 0,
  bool reversed = false,
  Uint8List? rgba,
}) {
  final count = region.width * region.height;
  final bytes = Uint8List(count * 16), data = ByteData.sublistView(bytes);
  for (var record = 0; record < count; record++) {
    final index = reversed ? count - record - 1 : record;
    final at = record * 16;
    data.setUint32(at, region.x + index % region.width, Endian.little);
    data.setUint32(at + 4, region.y + index ~/ region.width, Endian.little);
    data.setUint32(at + 8, 445, Endian.little);
    final lit = rgba == null ? (index + phase).isOdd : rgba[index * 4] == 255;
    data.setInt16(at + 12, lit ? 18 : 0, Endian.little);
  }
  return WorldCircuitResult(
    1,
    List<int>.filled(24, 0),
    bytes,
    resultKind: 9,
  );
}

/// The pre-candidate decoder, retained only as the independent A/B reference.
Uint8List referenceDisplayDecode(
  ComputerDisplayRegion region,
  WorldCircuitResult response, {
  Uint8List Function(int)? allocateRgba,
}) {
  final width = region.width, height = region.height;
  if (response.resultKind != 9 ||
      response.records.length != width * height * 16) {
    throw const FormatException('显示器像素数量与已核验布局不匹配。');
  }
  final out = (allocateRgba ?? Uint8List.new)(width * height * 4);
  final seen = Uint8List(width * height);
  final d = ByteData.sublistView(response.records);
  for (var at = 0; at < response.records.length; at += 16) {
    final px = d.getUint32(at, Endian.little) - region.x;
    final py = d.getUint32(at + 4, Endian.little) - region.y;
    final tile = d.getUint32(at + 8, Endian.little) & 65535;
    final fx = d.getInt16(at + 12, Endian.little);
    final fy = d.getInt16(at + 14, Endian.little);
    if (px < 0 ||
        py < 0 ||
        px >= width ||
        py >= height ||
        tile != 445 ||
        fx < 0 ||
        fx % 18 != 0 ||
        fy < 0 ||
        fy % 18 != 0 ||
        (fx > 18 || fy != 0)) {
      throw const FormatException('显示器返回了无效的实际像素状态。');
    }
    final index = py * width + px;
    if (seen[index] != 0) throw const FormatException('显示器像素重复。');
    seen[index] = 1;
    final rgb = fx == 18 ? 0xffffff : 0;
    out[index * 4] = (rgb >> 16) & 255;
    out[index * 4 + 1] = (rgb >> 8) & 255;
    out[index * 4 + 2] = rgb & 255;
    out[index * 4 + 3] = 255;
  }
  return out;
}
