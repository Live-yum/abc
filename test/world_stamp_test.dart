import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/world_stamp.dart';
import 'package:terraforge/domain/fusion_document.dart';

// Original hand-encoded section fixture. No game assets or engine-generated data.
Uint8List fixture({
  int version = 139,
  int height = 300,
  List<int>? tiles,
  int chests = 0,
  List<int>? chestData,
  List<int>? signData,
}) {
  final count = version == 139 ? 7 : 11;
  final header = BytesBuilder();
  header.add([1, 65]);
  if (version == 326) header.add([0, ...List.filled(24, 0)]);
  final dimensions = ByteData(28)
    ..setInt32(20, height, Endian.little)
    ..setInt32(24, 2, Endian.little);
  header.add(dimensions.buffer.asUint8List());
  final sections = <List<int>>[
    header.takeBytes(),
    tiles ??
        [
          130,
          1,
          (height - 1) & 255,
          (height - 1) >> 8,
          130,
          1,
          (height - 1) & 255,
          (height - 1) >> 8,
        ],
    chestData ??
        [
          chests,
          0,
          if (version == 139) ...[40, 0],
        ],
    signData ?? [0, 0],
    [0],
    [0, 0, 0, 0],
  ];
  while (sections.length < count) {
    sections.add([0, 0, 0, 0]);
  }
  final size = 26 + count * 4 + 2 + 4;
  final format = ByteData(size)
    ..setInt32(0, version, Endian.little)
    ..setUint16(24, count, Endian.little)
    ..setUint16(26 + count * 4, 31, Endian.little);
  format.buffer.asUint8List().setRange(4, 12, [
    114,
    101,
    108,
    111,
    103,
    105,
    99,
    2,
  ]);
  var cursor = size;
  for (var i = 0; i < count; i++) {
    format.setInt32(26 + i * 4, cursor, Endian.little);
    cursor += sections[i].length;
  }
  return (BytesBuilder()
        ..add(format.buffer.asUint8List())
        ..add(sections.expand((s) => s).toList()))
      .takeBytes();
}

List<StampCell?> read(
  Uint8List b, {
  int x = 0,
  int y = 0,
  int width = 2,
  int height = 300,
}) => WorldStamp.extract(b, x: x, y: y, width: width, height: height);
void main() {
  for (final version in [139, 326]) {
    test(
      'release $version splits RLE, preserves all non-tile bytes, source immutable',
      () {
        final source = fixture(version: version),
            snapshot = Uint8List.fromList(source);
        final out = WorldStamp.apply(
          source,
          x: 0,
          y: 255,
          width: 2,
          height: 2,
          cells: [
            const StampCell(block: 0, blockPaint: 3),
            null,
            const StampCell(wall: 1, wallPaint: 4),
            const StampCell(block: -1),
          ],
          overwrite: true,
        );
        expect(source, snapshot);
        final cells = read(out);
        expect(cells[255 * 2]!.block, 0);
        expect(cells[255 * 2]!.blockPaint, 3);
        expect(cells[255 * 2 + 1]!.block, 1);
        expect(cells[256 * 2]!.wall, 1);
        expect(cells[256 * 2]!.block, 1);
        expect(cells[256 * 2 + 1]!.block, -1);
        final before = ByteData.sublistView(source),
            after = ByteData.sublistView(out),
            count = version == 139 ? 7 : 11;
        final p1 = before.getInt32(30, Endian.little),
            p2 = before.getInt32(34, Endian.little),
            q2 = after.getInt32(34, Endian.little);
        expect(out.sublist(p1 - 30, p1), source.sublist(p1 - 30, p1));
        expect(out.sublist(q2), source.sublist(p2));
        for (var i = 2; i < count; i++) {
          expect(
            after.getInt32(26 + 4 * i, Endian.little) -
                before.getInt32(26 + 4 * i, Endian.little),
            out.length - source.length,
          );
        }
      },
    );
  }
  test('transparent stamp is byte-identical', () {
    final source = fixture();
    expect(
      WorldStamp.apply(source, x: 0, y: 0, width: 1, height: 1, cells: [null]),
      source,
    );
  });
  test('occupied layer requires explicit overwrite', () {
    expect(
      () => WorldStamp.apply(
        fixture(),
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        cells: [const StampCell(block: 0)],
      ),
      throwsFormatException,
    );
  });
  test('rejects bounds, future versions, entities, unsupported material and truncated run', () {
    expect(
      () => WorldStamp.apply(
        fixture(),
        x: 2,
        y: 0,
        width: 1,
        height: 1,
        cells: [null],
      ),
      throwsFormatException,
    );
    final future = fixture();
    ByteData.sublistView(future).setInt32(0, 327, Endian.little);
    expect(() => read(future), throwsFormatException);
    expect(() => read(fixture(chests: 1)), throwsFormatException);
    expect(
      () => WorldStamp.apply(
        fixture(),
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        cells: [const StampCell(block: 21)],
      ),
      throwsFormatException,
    );
    expect(
      () => read(fixture(tiles: [130, 1, 255, 127])),
      throwsFormatException,
    );
  });
  test('rejects wired target and adjacent framed furniture', () {
    expect(
      () => read(fixture(height: 1, tiles: [3, 2, 1, 2, 1]), height: 1),
      throwsFormatException,
    );
    final source = fixture(height: 1, tiles: [2, 1, 2, 2, 0, 0, 0, 0]);
    source[56] = 4;
    expect(
      () => WorldStamp.apply(
        source,
        x: 0,
        y: 0,
        width: 1,
        height: 1,
        cells: [const StampCell(block: 0)],
        overwrite: true,
      ),
      throwsFormatException,
    );
  });
  for (final version in [139, 326]) {
    test(
      'release $version preserves remote chests/signs and rejects nearby anchors',
      () {
        List<int> integer(int n) =>
            (ByteData(4)..setInt32(0, n, Endian.little)).buffer.asUint8List();
        List<int> chest(int y) => [
          1,
          0,
          if (version == 139) ...[1, 0],
          ...integer(0),
          ...integer(y),
          1,
          67,
          if (version == 326) ...integer(1),
          5,
          0,
          ...integer(1),
          0,
        ];
        List<int> sign(int y) => [1, 0, 1, 83, ...integer(1), ...integer(y)];
        final source = fixture(
          version: version,
          chestData: chest(200),
          signData: sign(201),
        );
        final output = WorldStamp.apply(
          source,
          x: 0,
          y: 10,
          width: 1,
          height: 1,
          cells: [const StampCell(block: 0)],
          overwrite: true,
        );
        expect(
          WorldStamp.extract(
            output,
            x: 0,
            y: 10,
            width: 1,
            height: 1,
          ).single!.block,
          0,
        );
        expect(
          () => WorldStamp.apply(
            fixture(version: version, chestData: chest(11)),
            x: 0,
            y: 10,
            width: 1,
            height: 1,
            cells: [const StampCell(block: 0)],
            overwrite: true,
          ),
          throwsFormatException,
        );
        expect(
          () => WorldStamp.apply(
            fixture(version: version, signData: sign(11)),
            x: 0,
            y: 10,
            width: 1,
            height: 1,
            cells: [const StampCell(block: 0)],
            overwrite: true,
          ),
          throwsFormatException,
        );
      },
    );
  }
  test(
    'fusion history stays within byte budget and rejects unknown import fields',
    () {
      final large = FusionDocument(1024, 1024);
      large.paint(0, 0, const StampCell(block: 1));
      expect(large.canUndo, false);
      expect(large.cells.first!.block, 1);
      final json = FusionDocument(1, 1).toJson();
      expect(
        () => FusionDocument.fromJson({...json, 'entities': []}),
        throwsFormatException,
      );
      expect(
        () => FusionDocument.fromJson({
          ...json,
          'cells': [
            {'block': 1, 'frameX': 0},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => FusionDocument.fromJson({
          ...json,
          'cells': [
            {'blockPaint': 2},
          ],
        }),
        throwsFormatException,
      );
    },
  );
  test('fusion projects group strokes and round trip clear vs skip', () {
    final doc = FusionDocument(2, 2);
    doc.beginStroke();
    doc.paint(0, 0, const StampCell(block: -1));
    doc.paint(1, 0, const StampCell(wall: 1));
    doc.endStroke();
    final parsed = FusionDocument.fromJson(doc.toJson());
    expect(parsed.cells[0]!.block, -1);
    expect(parsed.cells[2], null);
    doc.undo();
    expect(doc.cells.every((c) => c == null), true);
    doc.redo();
    expect(doc.cells[1]!.wall, 1);
  });
}
