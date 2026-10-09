import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Repository-authored protocol fixtures, never samples of a user's save.
Uint8List syntheticMap({
  bool chunked = true,
  int width = 130,
  int height = 70,
}) {
  final header = BytesBuilder();
  void u32(int n) => header.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  void u16(int n) => header.add(
    (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List(),
  );
  u32(chunked ? 33083 : 319);
  header.add(utf8.encode('relogic'));
  header.addByte(1);
  u32(7);
  u32(1);
  u32(0);
  final name = utf8.encode('Repository MAP fixture');
  header.addByte(name.length);
  header.add(name);
  u32(17);
  u32(height);
  u32(width);
  for (final count in [2, 2, 4, 256, 256, 256]) {
    u16(count);
  }
  header.add([1, 0, 2]); // Tile 0 has two options; other types have one.
  if (chunked) {
    for (var cy = 0; cy < height; cy += 64) {
      for (var cx = 0; cx < width; cx += 64) {
        final raw = ByteData(16384);
        for (var y = 0; y < 64; y++) {
          for (var x = 0; x < 64; x++) {
            // Padding deliberately nonzero to detect accidental boundary loss.
            final value = cx + x >= width || cy + y >= height
                ? 0xabcdef12
                : (1 + ((cx + x) ~/ 13) % 4) |
                      (((cy + y) % 256) << 16) |
                      (((cx + x) % 32) << 24);
            raw.setUint32((y * 64 + x) * 4, value, Endian.little);
          }
        }
        final compressed = const ZLibEncoder().encodeBytes(
          raw.buffer.asUint8List(),
        );
        u32(compressed.length);
        header.add(compressed);
      }
    }
  } else {
    final raw = OutputMemoryStream(size: 65536);
    for (var y = 0; y < height; y++) {
      final kind = y % 9, encodedKind = kind == 8 ? 3 : kind;
      final option = y % 2;
      final extra = (y % 32) << 1 | (kind == 8 ? 64 : 0);
      final run = width - 1;
      raw.writeByte(
        (encodedKind << 1) |
            (extra == 0 ? 0 : 1) |
            32 |
            (run == 0
                ? 0
                : run <= 255
                ? 64
                : 128),
      );
      if (extra != 0) raw.writeByte(extra);
      if (kind == 1 || kind == 2 || kind == 7) raw.writeByte(option);
      raw.writeByte(y % 256);
      if (run > 0) {
        raw.writeByte(run & 255);
        if (run > 255) raw.writeByte(run >> 8);
      }
      for (var x = 1; x < width; x++) {
        raw.writeByte((x + y) % 256);
      }
    }
    final compressed = const ZLibEncoder().encodeBytes(raw.getBytes());
    header.add(Uint8List.sublistView(compressed, 2, compressed.length - 4));
  }
  return header.takeBytes();
}
