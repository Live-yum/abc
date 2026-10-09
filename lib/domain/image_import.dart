import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Header budgets are checked before frame allocation. Only the first static
/// frame is accepted; no animation is silently flattened or fully decoded.
List<int> importPixelImage(Uint8List bytes) {
  if (bytes.length < 16 || bytes.length > 32 * 1024 * 1024) {
    throw const FormatException('图片文件大小无效。');
  }
  try {
    return _decodePixels(bytes);
  } on RangeError {
    throw const FormatException('图片内容损坏。');
  }
}

List<int> _decodePixels(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width < 1 || info.height < 1) {
    throw const FormatException('无法读取图片头。');
  }
  if (info.width > 8192 ||
      info.height > 8192 ||
      info.width * info.height > 8000000 ||
      info.numFrames != 1) {
    throw const FormatException('图片须为单帧，最长边不超过 8192，总像素不超过 800 万。');
  }
  final image = decoder!.decodeFrame(0);
  if (image == null) {
    throw const FormatException('无法解码图片。');
  }
  const width = 34, height = 22;
  final scale = math.min(width / image.width, height / image.height);
  final w = math.max(1, (image.width * scale).round()),
      h = math.max(1, (image.height * scale).round());
  final small = img.copyResize(
    image,
    width: w,
    height: h,
    interpolation: img.Interpolation.average,
  );
  final pixels = List<int>.filled(width * height, 0),
      left = (width - w) ~/ 2,
      top = (height - h) ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      pixels[(y + top) * width + x + left] =
          (p.a.toInt() << 24) |
          (p.r.toInt() << 16) |
          (p.g.toInt() << 8) |
          p.b.toInt();
    }
  }
  return pixels;
}
