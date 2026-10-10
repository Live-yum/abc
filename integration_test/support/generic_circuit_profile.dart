import 'dart:typed_data';

const genericCircuitWorkloadId = 'generic-wld-controls-v1';
// Identity of a public stress input, not an application compatibility rule.
const publicCircuitFixtureSha256 =
    '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33';

class GenericCircuitSelection {
  GenericCircuitSelection(this.displayRegion, this.trigger);
  final Map<String, int> displayRegion;
  final Map<String, Object?> trigger;

  /// Select a real wired cell in the viewport chosen by the application.
  /// No CPU coordinates, tile type, display geometry or ROM is assumed.
  factory GenericCircuitSelection.fromState(Map state) {
    final width = state['width'] as int, height = state['height'] as int;
    final records = state['records'] as Uint8List;
    if (width < 1 || height < 1 || records.length % 16 != 0) {
      throw StateError('Invalid loaded wiring viewport');
    }
    final data = ByteData.sublistView(records);
    for (var at = 0; at < records.length; at += 16) {
      final x = data.getUint32(at, Endian.little);
      final y = data.getUint32(at + 4, Endian.little);
      final mask = (data.getUint32(at + 8, Endian.little) >> 24) & 15;
      if (mask == 0 || x >= width || y >= height) {
        continue;
      }
      final w = width < 32 ? width : 32;
      final h = height < 32 ? height : 32;
      final rx = (x - w ~/ 2).clamp(0, width - w).toInt();
      final ry = (y - h ~/ 2).clamp(0, height - h).toInt();
      return GenericCircuitSelection(
        {'x': rx, 'y': ry, 'width': w, 'height': h},
        {'x': x, 'y': y, 'mask': mask, 'direct': true},
      );
    }
    throw StateError('No actual wired cell in the initial viewport; action unmeasured');
  }
}
