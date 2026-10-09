import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/domain/terrain_rule_plan.dart';

AdvancedRegionDocument region(
  List<int> blocks, {
  List<int>? walls,
  bool objects = false,
}) {
  final bytes = ByteData(blocks.length * 32);
  for (var i = 0; i < blocks.length; i++) {
    final at = i * 32;
    bytes.setUint32(at, i, Endian.little);
    bytes.setUint32(at + 8, blocks[i] | (127 << 16), Endian.little);
    bytes.setUint32(at + 12, 0xfffeffff, Endian.little);
    bytes.setUint32(
      at + 16,
      (walls?[i] ?? 5) | (7 << 16) | (9 << 24),
      Endian.little,
    );
    bytes.setUint32(
      at + 20,
      128 | (4 << 8) | (7 << 16) | (15 << 24),
      Endian.little,
    );
  }
  final companion = ByteData(32)
    ..setUint32(0, 0x31424f43, Endian.little)
    ..setUint32(4, 1, Endian.little)
    ..setUint32(16, 32, Endian.little);
  return AdvancedRegionDocument(
    width: blocks.length,
    height: 1,
    records: bytes.buffer.asUint8List(),
    objects: objects ? companion.buffer.asUint8List() : null,
  );
}

Map<String, Object?> rule(Object source, Object target, {String? layer}) => {
  'type': 'terrain',
  'source': source,
  'target': target,
  'layer': ?layer,
};

void main() {
  test(
    'simultaneous swaps use original records and preserve unrelated bytes',
    () {
      final doc = region([1, 2, 3], walls: [2, 1, 3], objects: true);
      final original = doc.records, objects = doc.objects;
      final plan = TerrainRulePlan.prepare(doc, [
        rule('1', 2),
        rule(2, 1),
        rule(1, 2, layer: 'wall'),
        rule(2, 1, layer: 'wall'),
      ]);
      expect(plan.changedCells, 2);
      expect(plan.blockChanges, 2);
      expect(plan.wallChanges, 2);
      expect(plan.matchedCounts, [1, 1, 1, 1]);
      expect(plan.sourceRevision, 0);
      expect(doc.records, original);
      doc.replaceRecords(plan.records);
      expect(
        [for (var i = 0; i < 3; i++) doc.cellAtIndex(i)['block']],
        [2, 1, 3],
      );
      expect(
        [for (var i = 0; i < 3; i++) doc.cellAtIndex(i)['wall']],
        [1, 2, 3],
      );
      for (var i = 0; i < original.length; i++) {
        if ([8, 9, 16, 17].contains(i % 32)) continue;
        expect(doc.records[i], original[i], reason: 'byte $i');
      }
      expect(doc.objects, objects);
      expect(doc.cellAtIndex(0)['frameX'], -1);
      expect(doc.cellAtIndex(0)['frameY'], -2);
      expect(doc.cellAtIndex(0)['flags'], 127);
    },
  );

  test('no chaining, including no-op matches', () {
    final doc = region([1, 2, 3]);
    final plan = TerrainRulePlan.prepare(doc, [
      rule(1, 2),
      rule(2, 3),
      rule(3, 3),
    ]);
    doc.replaceRecords(plan.records);
    expect(
      [for (var i = 0; i < 3; i++) doc.cellAtIndex(i)['block']],
      [2, 3, 3],
    );
    expect(plan.matchedCounts, [1, 1, 1]);
    expect(plan.changedCells, 2);
  });

  test('block zero is active Dirt; inactive cells never match blocks', () {
    final doc = region([0, 1, 1]);
    final candidate = doc.records;
    ByteData.sublistView(candidate).setUint16(2 * 32 + 10, 126, Endian.little);
    doc.replaceRecords(candidate);
    final plan = TerrainRulePlan.prepare(doc, [rule('0', 65535), rule(1, 0)]);
    doc.replaceRecords(plan.records);
    expect(doc.cellAtIndex(0)['block'], 65535);
    expect(doc.cellAtIndex(1)['block'], 0);
    expect(doc.cellAtIndex(1)['active'], 1);
    expect(doc.cellAtIndex(2)['block'], 1);
    expect(doc.cellAtIndex(2)['active'], 0);
    expect(plan.matchedCounts, [1, 1]);
  });

  test('wall removal clears only wall paint; wall zero may be a source', () {
    final doc = region([5, 5], walls: [5, 0]);
    final original = doc.records;
    final plan = TerrainRulePlan.prepare(doc, [
      rule(5, 0, layer: 'wall'),
      rule(0, 65535, layer: 'wall'),
    ]);
    doc.replaceRecords(plan.records);
    expect(doc.cellAtIndex(0)['wall'], 0);
    expect(doc.cellAtIndex(0)['wallPaint'], 0);
    expect(doc.cellAtIndex(1)['wall'], 65535);
    expect(doc.cellAtIndex(1)['wallPaint'], 9);
    for (var i = 0; i < original.length; i++) {
      if ([16, 17, 19].contains(i % 32)) continue;
      expect(doc.records[i], original[i]);
    }
  });

  test(
    'duplicate sources reject per layer, different layers can share source',
    () {
      final doc = region([1]);
      expect(
        () => TerrainRulePlan.prepare(doc, [rule('01', 2), rule(1, 3)]),
        throwsFormatException,
      );
      expect(
        () => TerrainRulePlan.prepare(doc, [
          rule(1, 2),
          rule(1, 3, layer: 'wall'),
        ]),
        returnsNormally,
      );
    },
  );

  test('invalid rules are atomic and bounds are enforced', () {
    final doc = region([1]);
    final original = doc.records;
    for (final bad in <Map<String, Object?>>[
      rule(-1, 2),
      rule(65536, 2),
      rule('1.0', 2),
      rule(' 1', 2),
      rule(1.0, 2),
      rule(1, -1),
      rule(1, 65536),
      rule(1, '2'),
      rule(1, 2.0),
      rule(1, 2, layer: 'liquid'),
      {...rule(1, 2), 'layer': null},
      {...rule(1, 2), 'type': 'other'},
    ]) {
      expect(
        () => TerrainRulePlan.prepare(doc, [rule(2, 3), bad]),
        throwsFormatException,
      );
      expect(doc.records, original);
      expect(doc.revision, 0);
      expect(doc.canUndo, false);
    }
    expect(
      () => TerrainRulePlan.prepare(doc, List.filled(65536, rule(1, 2))),
      throwsFormatException,
    );
    final oversized = ByteData((TerrainRulePlan.maxRecords + 1) * 32);
    for (var i = 0; i <= TerrainRulePlan.maxRecords; i++) {
      oversized.setUint32(i * 32, i ~/ 512, Endian.little);
      oversized.setUint32(i * 32 + 4, i % 512, Endian.little);
    }
    final large = AdvancedRegionDocument(
      width: 513,
      height: 512,
      records: oversized.buffer.asUint8List(),
    );
    expect(() => TerrainRulePlan.prepare(large, []), throwsFormatException);
  });

  test(
    'replacement is one undo/redo entry; defensive copies and no-op history',
    () {
      final doc = region([1, 2]);
      final original = doc.records;
      final plan = TerrainRulePlan.prepare(doc, [rule(1, 2), rule(2, 3)]);
      plan.records.fillRange(0, 64, 255);
      expect(() => plan.matchedCounts[0] = 50, throwsUnsupportedError);
      final candidate = plan.records;
      doc.replaceRecords(candidate);
      final expected = doc.records;
      candidate.fillRange(0, 64, 255);
      expect(doc.records, expected);
      expect(doc.historyBytes, 64);
      expect(doc.revision, 1);
      doc.undo();
      expect(doc.records, original);
      expect(doc.canUndo, false);
      expect(doc.canRedo, true);
      doc.replaceRecords(original);
      expect(doc.canRedo, true);
      expect(doc.revision, 2);
      expect(doc.historyBytes, 64);
      doc.redo();
      expect(doc.records, expected);
      expect(doc.revision, 3);
      expect(doc.historyBytes, 64);
    },
  );

  test(
    'replacement snapshots remain within the shared 32 MiB history budget',
    () {
      final bytes = ByteData(TerrainRulePlan.maxRecords * 32);
      for (var i = 0; i < TerrainRulePlan.maxRecords; i++) {
        bytes.setUint32(i * 32, i ~/ 512, Endian.little);
        bytes.setUint32(i * 32 + 4, i % 512, Endian.little);
      }
      final doc = AdvancedRegionDocument(
        width: 512,
        height: 512,
        records: bytes.buffer.asUint8List(),
      );
      expect(TerrainRulePlan.prepare(doc, []).changedCells, 0);
      for (var value = 1; value <= 5; value++) {
        final candidate = doc.records;
        ByteData.sublistView(candidate).setUint16(16, value, Endian.little);
        doc.replaceRecords(candidate);
        expect(
          doc.historyBytes,
          lessThanOrEqualTo(AdvancedRegionDocument.maxHistoryBytes),
        );
      }
      expect(doc.historyBytes, AdvancedRegionDocument.maxHistoryBytes);
      for (var value = 4; value >= 1; value--) {
        doc.undo();
        expect(doc.cellAtIndex(0)['wall'], value);
      }
      expect(doc.canUndo, false);
      doc.redo();
      expect(doc.cellAtIndex(0)['wall'], 2);
      final candidate = doc.records;
      ByteData.sublistView(candidate).setUint16(16, 10, Endian.little);
      doc.replaceRecords(candidate);
      expect(doc.canRedo, false);
      expect(doc.historyBytes, 16 * 1024 * 1024);
    },
  );

  test('malformed replacements retain state, history and companion', () {
    final doc = region([1, 2], objects: true);
    final original = doc.records, objects = doc.objects;
    final badCandidates = <Uint8List>[Uint8List(32)];
    for (final edit in <void Function(ByteData)>[
      (d) => d.setUint32(32, 0, Endian.little),
      (d) => d.setUint32(24, 1, Endian.little),
      (d) => d.setUint32(28, 1, Endian.little),
      (d) => d.setUint16(10, 128, Endian.little),
      (d) => d.setUint8(23, 16),
      (d) => d.setUint8(21, 5),
      (d) => d.setUint8(22, 8),
      (d) => d.setUint8(20, 0),
    ]) {
      final bytes = doc.records;
      edit(ByteData.sublistView(bytes));
      badCandidates.add(bytes);
    }
    for (final candidate in badCandidates) {
      expect(() => doc.replaceRecords(candidate), throwsFormatException);
      expect(doc.records, original);
      expect(doc.objects, objects);
      expect(doc.revision, 0);
      expect(doc.historyBytes, 0);
    }
    final sparse = AdvancedRegionDocument(
      width: 3,
      height: 1,
      records: original,
    );
    final moved = sparse.records;
    ByteData.sublistView(moved).setUint32(32, 2, Endian.little);
    expect(() => sparse.replaceRecords(moved), throwsFormatException);
    expect(sparse.records, original);
    doc.beginStroke();
    expect(() => doc.replaceRecords(original), throwsStateError);
    expect(doc.strokeOpen, true);
    doc.cancelStroke();
  });
}
