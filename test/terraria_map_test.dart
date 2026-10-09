import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/terraria_map.dart';

import '../tool/perf/map_fixture.dart';

void main() {
  for (final chunked in [false, true]) {
    group(chunked ? 'Chunked MAP 315' : 'Legacy MAP 319', () {
      test('fully decodes binary cells and untouched export is byte-exact', () {
        final bytes = syntheticMap(chunked: chunked);
        final map = TerrariaMapSession.decode(bytes);
        expect(map.width, 130);
        expect(map.height, 70);
        expect(map.cellAt(64, 33).light, chunked ? 33 : 97);
        expect(map.cellAt(64, 33).color, chunked ? 0 : 1);
        expect(map.exportBytes(), bytes);
        bytes.fillRange(0, bytes.length, 0);
        expect(map.exportBytes().first, chunked ? 59 : 63);
        map.close();
        expect(map.ownedBytes, 0);
        expect(() => map.exportBytes(), throwsStateError);
        map.close();
      });
      test('atomic rectangular edit, undo, redo, export and full reopen', () {
        final source = syntheticMap(chunked: chunked);
        final map = TerrariaMapSession.decode(source);
        final before = map.cellAt(63, 63), untouched = map.cellAt(70, 69);
        expect(map.editRect(63, 63, 3, 3, light: 217, color: 28), 9);
        expect(map.isModified, isTrue);
        expect(map.canUndo, isTrue);
        final result = map.exportBytes(),
            reopened = TerrariaMapSession.decode(result);
        for (var y = 0; y < map.height; y++) {
          for (var x = 0; x < map.width; x++) {
            final expected = map.cellAt(x, y), actual = reopened.cellAt(x, y);
            expect(
              [actual.option, actual.light, actual.color, actual.legacyKind],
              [
                expected.option,
                expected.light,
                expected.color,
                expected.legacyKind,
              ],
            );
          }
        }
        expect(reopened.cellAt(63, 63).option, before.option);
        expect(reopened.cellAt(70, 69).light, untouched.light);
        map.undo();
        expect(map.isModified, isFalse);
        expect(map.exportBytes(), source);
        map.redo();
        expect(map.cellAt(63, 63).light, 217);
        expect(() => map.editRect(129, 69, 2, 2, light: 10), throwsRangeError);
        expect(map.cellAt(63, 63).light, 217);
        reopened.close();
        map.close();
      });
      test(
        'region and exploration rendering return real independent buffers',
        () {
          final map = TerrariaMapSession.decode(syntheticMap(chunked: chunked));
          final region = map.readRegion(0, 0, 64, 64);
          region.fillRange(0, region.length, 0);
          expect(map.cellAt(64, 33).light, chunked ? 33 : 97);
          final raster = map.renderExplorationRgba(maxWidth: 65);
          expect(
            [raster.width, raster.height, raster.rgba.length],
            [65, 35, 9100],
          );
          expect(raster.rgba[3], 255);
          map.close();
        },
      );
      test(
        'rejects invalid dimensions and truncation without accepting headers',
        () {
          final input = syntheticMap(chunked: chunked);
          expect(
            () =>
                TerrariaMapSession.decode(Uint8List.sublistView(input, 0, 60)),
            throwsA(isA<FormatException>()),
          );
          final badVersion = Uint8List.fromList(input);
          ByteData.sublistView(badVersion).setUint32(0, 65535, Endian.little);
          expect(
            () => TerrariaMapSession.decode(badVersion),
            throwsFormatException,
          );
        },
      );
    });
  }
  test('chunk checksum corruption is rejected', () {
    final input = syntheticMap();
    input[input.length - 1] ^= 1;
    expect(() => TerrariaMapSession.decode(input), throwsFormatException);
  });
  test('repeated undo/redo and branch edits preserve original identity', () {
    final bytes = syntheticMap(),
        map = TerrariaMapSession.decode(syntheticMap());
    map.editRect(0, 0, 1, 1, light: 77);
    map.editRect(0, 0, 1, 1, light: 88);
    map.undo();
    expect(map.cellAt(0, 0).light, 77);
    map.undo();
    expect(map.exportBytes(), bytes);
    map.redo();
    map.editRect(0, 0, 1, 1, light: 99);
    expect(map.canRedo, isFalse);
    map.undo();
    map.undo();
    expect(map.exportBytes(), bytes);
    map.close();
  });
}
