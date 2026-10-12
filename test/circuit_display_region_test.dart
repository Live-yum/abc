import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/circuit_display.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

WorldCircuitResult pixels(List<List<int>> points, {int kind = 9}) {
  final bytes = Uint8List(points.length * 16);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < points.length; i++) {
    final p = points[i], at = i * 16;
    data.setUint32(at, p[0], Endian.little);
    data.setUint32(at + 4, p[1], Endian.little);
    data.setUint32(at + 8, p[2], Endian.little);
    data.setInt16(at + 12, p[3], Endian.little);
    data.setInt16(at + 14, p[4], Endian.little);
  }
  return WorldCircuitResult(
    1,
    List.filled(24, 0),
    bytes,
    resultKind: kind,
    resultCount: points.length,
  );
}

void main() {
  const region = CircuitDisplayRegion('custom selection', 11, 7, 3, 2);
  test('arbitrary sparse rectangle distinguishes gaps from unlit devices', () {
    final rgba = region.decode(
      pixels([
        [11, 7, 445, 0, 0],
        [13, 8, 445, 18, 0],
      ]),
    );
    expect(rgba.length, 24);
    expect(rgba.sublist(0, 4), [0, 0, 0, 255]);
    expect(rgba.sublist(4, 20), everyElement(0));
    expect(rgba.sublist(20), [255, 255, 255, 255]);
  });
  test('empty native selection is a transparent frame', () {
    expect(region.decode(pixels([])), everyElement(0));
  });
  test('duplicate, out-of-region and unsupported frames fail', () {
    for (final records in [
      [
        [11, 7, 445, 0, 0],
        [11, 7, 445, 18, 0],
      ],
      [
        [10, 7, 445, 0, 0],
      ],
      [
        [14, 7, 445, 0, 0],
      ],
      [
        [11, 7, 419, 0, 0],
      ],
      [
        [11, 7, 445, 36, 0],
      ],
      [
        [11, 7, 445, 0, 18],
      ],
    ]) {
      expect(() => region.decode(pixels(records)), throwsFormatException);
    }
    expect(() => region.decode(pixels([], kind: 1)), throwsFormatException);
  });
  test(
    'selection bounds use generic ABI rather than fixed screen dimensions',
    () {
      (const CircuitDisplayRegion('max', 0, 0, 256, 256)).validate();
      for (final invalid in [
        const CircuitDisplayRegion('negative', -1, 0, 1, 1),
        const CircuitDisplayRegion('zero', 0, 0, 0, 1),
        const CircuitDisplayRegion('large', 0, 0, 257, 256),
        const CircuitDisplayRegion('overflow', 0, 0, 0xffffffff, 0xffffffff),
      ]) {
        expect(invalid.validate, throwsFormatException);
      }
    },
  );
}
