import 'dart:typed_data';

/// Lossless core tile records: eight little-endian u32 words per cell,
/// x/y relative to the region, column-major. Includes every tile layer.
/// Object companions are COB1, not TXCI (TXCI is a colour lookup index).
abstract interface class RegionBackend {
  /// Core pixel ABI1: candidate flags painted=1, wall=2. Matching flags:
  /// unpainted=1, require wall=2, prefer wall=4, require tile=8, painted=16.
  /// Results are candidate offsets; 0xffffffff means no eligible match.
  Future<Uint32List> matchColors(
    Uint32List rgb,
    Uint32List candidateRgb,
    Uint32List candidateFlags, {
    int flags = 0,
  });
  Future<Uint8List> readRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  );
  Future<Uint8List> readRegionObjects(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
  );
  Future<Uint8List> replaceRegion(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
    Uint8List records,
  );
  Future<Uint8List> regionOperation(
    Uint8List world,
    String operation,
    Map<String, dynamic> request, {
    Uint8List? records,
    Uint8List? objects,
  });
  Future<Uint8List> writeIndexedPixels(
    Uint8List world,
    int x,
    int y,
    int width,
    int height,
    Uint8List maps,
    Uint16List indices,
  );
}

/// Palette records have RGBA, little-endian tile/wall IDs, tile/wall paint,
/// mode (0 empty, 1 tile, 2 wall, 3 skip, 4 tile+wall), inactive flag.
void validateIndexedPixels(
  int width,
  int height,
  Uint8List maps,
  Uint16List indices,
) {
  if (width < 1 ||
      height < 1 ||
      width > 16384 ||
      height > 16384 ||
      width * height != indices.length ||
      width * height > 262144 ||
      maps.isEmpty ||
      maps.length % 12 != 0 ||
      maps.length ~/ 12 > 65536) {
    throw ArgumentError('Invalid pixel canvas or 12-byte palette');
  }
  final count = maps.length ~/ 12;
  if (indices.any((index) => index >= count)) {
    throw ArgumentError('Pixel index outside palette');
  }
}

void validateColorMatch(
  Uint32List rgb,
  Uint32List candidateRgb,
  Uint32List candidateFlags,
  int flags,
) {
  if (rgb.length > 65536 ||
      candidateRgb.length > 65536 ||
      candidateRgb.length != candidateFlags.length ||
      flags < 0 ||
      flags > 31 ||
      ((flags & 2) != 0 && (flags & 8) != 0) ||
      ((flags & 1) != 0 && (flags & 16) != 0) ||
      rgb.any((v) => v > 0xffffff) ||
      candidateRgb.any((v) => v > 0xffffff) ||
      candidateFlags.any((v) => v > 3)) {
    throw ArgumentError('Invalid core colour match request');
  }
}

void validateRegionBounds(int x, int y, int width, int height) {
  if (x < 0 ||
      y < 0 ||
      x > 0x7fffffff ||
      y > 0x7fffffff ||
      width < 1 ||
      height < 1 ||
      width > 16384 ||
      height > 16384 ||
      width * height > 262144) {
    throw ArgumentError('Region bounds exceed the safe host limits');
  }
}
