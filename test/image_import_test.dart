import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:terraforge/domain/image_import.dart';

void main() {
  test(
    'image header budget rejects oversized dimension before raster decode',
    () {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 8193, height: 1)),
      );
      expect(() => importPixelImage(bytes), throwsFormatException);
    },
  );
  test('pixel import preserves aspect ratio with transparent letterbox', () {
    final source = img.Image(width: 100, height: 10, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(10, 20, 30, 255));
    final pixels = importPixelImage(Uint8List.fromList(img.encodePng(source)));
    expect(pixels.length, 34 * 22);
    expect(pixels.first, 0);
    expect(pixels.where((p) => p != 0).length, 34 * 3);
  });
  test('unknown bytes are rejected', () {
    expect(
      () => importPixelImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
