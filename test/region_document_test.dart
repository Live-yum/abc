import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/region_document.dart';

Uint8List records() {
  final d = ByteData(64);
  for (var i = 0; i < 2; i++) {
    d.setUint32(i * 32, i, Endian.little);
    d.setUint32(i * 32 + 8, 1 | (1 << 16), Endian.little);
  }
  return d.buffer.asUint8List();
}

void main() {
  test(
    'Grouped stroke is one snapshot; revisions and rollback are monotonic',
    () {
      final d = AdvancedRegionDocument(width: 2, height: 1, records: records());
      d.beginStroke();
      d.setCell(0, 0, {'wall': 1});
      d.setCell(1, 0, {'wall': 2});
      expect(d.historyBytes, 0);
      expect(d.revision, 2);
      d.endStroke();
      expect(d.historyBytes, 64);
      d.undo();
      expect(d.records, records());
      expect(d.revision, 3);
      d.redo();
      expect(d.cellAt(1, 0)!['wall'], 2);
      expect(d.revision, 4);
      d.beginStroke();
      d.setCell(0, 0, {'wall': 3});
      d.cancelStroke();
      expect(d.cellAt(0, 0)!['wall'], 1);
      expect(d.revision, 6);
    },
  );
  test('Sparse binary lookup and immutable companion', () {
    final o = ByteData(32)
      ..setUint32(0, 0x31424f43, Endian.little)
      ..setUint32(4, 1, Endian.little)
      ..setUint32(16, 32, Endian.little);
    final d = AdvancedRegionDocument(
      width: 3,
      height: 2,
      records: records(),
      objects: o.buffer.asUint8List(),
    );
    expect(d.indexAt(1, 0), 1);
    expect(d.indexAt(0, 1), -1);
    expect(d.indexAt(-1, 0), -1);
    d.objects!.fillRange(0, 32, 255);
    expect(d.objectCount, 0);
  });
  test('All layers survive schema/history roundtrip', () {
    final d = AdvancedRegionDocument(width: 2, height: 1, records: records());
    d.setCell(1, 0, {
      'wall': 2,
      'blockPaint': 3,
      'wallPaint': 4,
      'liquid': 255,
      'liquidType': 4,
      'slope': 7,
      'wires': 15,
      'actuator': 1,
      'inactive': 1,
      'fullbrightBlock': 1,
      'invisibleWall': 1,
    });
    final saved = d.records;
    final decoded = AdvancedRegionDocument.decode(d.encode());
    expect(decoded.records, saved);
    expect(decoded.cellAt(1, 0)!['wires'], 15);
    d.undo();
    expect(d.records, records());
    d.redo();
    expect(d.records, saved);
    expect(d.historyBytes, 64);
  });
  test('Read buffers cannot mutate history', () {
    final d = AdvancedRegionDocument(width: 2, height: 1, records: records());
    d.records.fillRange(0, 64, 255);
    expect(d.records, records());
  });
  test('Reject invalid values and ordering before changing state', () {
    final d = AdvancedRegionDocument(width: 2, height: 1, records: records());
    expect(() => d.setCell(0, 0, {'wires': 16}), throwsArgumentError);
    expect(() => d.setCell(0, 0, {'frameX': 4}), throwsArgumentError);
    expect(d.canUndo, false);
    final bad = records();
    ByteData.sublistView(bad).setUint32(32, 0, Endian.little);
    expect(
      () => AdvancedRegionDocument(width: 2, height: 1, records: bad),
      throwsFormatException,
    );
  });
  test('Liquid clear normalizes type; sparse absent cell rejects', () {
    final d = AdvancedRegionDocument(width: 3, height: 1, records: records());
    d.setCell(0, 0, {'liquid': 128, 'liquidType': 2});
    d.setCell(0, 0, {'liquid': 0});
    expect(d.cellAt(0, 0)!['liquidType'], 0);
    expect(() => d.setCell(2, 0, {'wall': 1}), throwsFormatException);
  });
}
