import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/fusion_placement.dart';
import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/domain/resource_catalog.dart';

import 'support/fusion_placement_fixture.dart';

void main() {
  final catalog = FusionPlacementCatalog(placementCatalog());
  test('display reader returns validated contents and rejects malformed payload/footprint', () {
    final document = blankRegion();
    FusionPlacementPlan.preview(
      document: document,
      brush: catalog.brush(1000, display: true),
      x: 2,
      y: 1,
      worldVersion: 326,
    ).apply(document);
    final items = FusionDisplayItem.readAll(document);
    expect(items.length, 1);
    expect(
      [
        items.single.x,
        items.single.y,
        items.single.width,
        items.single.height,
        items.single.itemId,
        items.single.prefix,
        items.single.stack,
      ],
      [2, 1, 2, 2, 1000, 0, 1],
    );
    expect(() => items.clear(), throwsUnsupportedError);
    final bad = document.objects!;
    ByteData.sublistView(bad).setInt16(67, -1, Endian.little);
    final malformed = AdvancedRegionDocument(
      width: document.width,
      height: document.height,
      sourceX: document.sourceX,
      sourceY: document.sourceY,
      records: document.records,
      objects: bad,
    );
    expect(() => FusionDisplayItem.readAll(malformed), throwsFormatException);
    document.setCell(2, 1, {'active': 0});
    expect(() => FusionDisplayItem.readAll(document), throwsFormatException);
    expect(FusionDisplayItem.readAll(blankRegion()), isEmpty);
    final empty = blankRegion();
    FusionPlacementPlan.preview(
      document: empty,
      brush: catalog.brush(3276),
      x: 0,
      y: 0,
      worldVersion: 326,
    ).apply(empty);
    expect(FusionDisplayItem.readAll(empty), isEmpty);
  });

  test(
    'history admission failure leaves implicit stroke closed and bytes intact',
    () {
      final source = blankRegion();
      final document = AdvancedRegionDocument(
        width: source.width,
        height: source.height,
        sourceX: source.sourceX,
        sourceY: source.sourceY,
        records: source.records,
        historyBudgetBytes: 1,
      );
      expect(() => document.setCell(0, 0, {'wall': 1}), throwsStateError);
      expect(document.strokeOpen, isFalse);
      expect(document.records, source.records);
      expect(document.canUndo, isFalse);
    },
  );

  test(
    'oversized paired snapshot rejects staging, and undo prunes oversized redo',
    () {
      final source = blankRegion();
      final document = AdvancedRegionDocument(
        width: source.width,
        height: source.height,
        sourceX: source.sourceX,
        sourceY: source.sourceY,
        records: source.records,
        historyBudgetBytes: source.records.length,
      );
      final before = document.encode();
      FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(1000, display: true),
        x: 0,
        y: 0,
        worldVersion: 326,
      ).apply(document);
      final another = FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(1000, display: true),
        x: 3,
        y: 2,
        worldVersion: 326,
      );
      expect(another.blockers.join(), contains('撤销预算'));
      expect(() => another.apply(document), throwsStateError);
      document.undo();
      expect(document.encode(), before);
      expect(document.canRedo, isFalse);
      expect(document.historyBytes, 0);
    },
  );

  test(
    'exact alternate and unequal row geometry produce ordered core records',
    () {
      final document = blankRegion();
      document.setCell(1, 1, {
        'wall': 2,
        'wallPaint': 4,
        'liquid': 123,
        'liquidType': 3,
        'wires': 15,
        'actuator': 1,
        'invisibleWall': 1,
        'fullbrightWall': 1,
      });
      final brush = catalog.brush(34, variantIndex: 1);
      final plan = FusionPlacementPlan.preview(
        document: document,
        brush: brush,
        x: 1,
        y: 1,
        worldVersion: 326,
      );
      expect(plan.canPlace, isTrue);
      final fragment = plan.fragment;
      expect(fragment.recordCount, 6);
      expect(fragment.cellAt(0, 0)!['frameX'], 36);
      expect(fragment.cellAt(1, 0)!['frameX'], 54);
      expect(fragment.cellAt(0, 0)!['frameY'], 24);
      expect(fragment.cellAt(0, 1)!['frameY'], 42);
      expect(fragment.cellAt(0, 2)!['frameY'], 64);
      expect(fragment.objects, isNull);
      final before = document.records;
      plan.apply(document);
      final cell = document.cellAt(1, 1)!;
      expect(cell['active'], 1);
      expect(cell['block'], 15);
      expect(cell['wall'], 2);
      expect(cell['wallPaint'], 4);
      expect(cell['liquid'], 123);
      expect(cell['liquidType'], 3);
      expect(cell['wires'], 15);
      expect(cell['actuator'], 1);
      expect(cell['invisibleWall'], 1);
      expect(cell['fullbrightWall'], 1);
      document.undo();
      expect(document.records, before);
      document.redo();
      expect(document.cellAt(2, 3)!['frameY'], 64);
    },
  );

  test('display payload is int16 item, byte prefix, int16 stack and anchors rebase', () {
    final document = blankRegion();
    final before = document.encode();
    final plan = FusionPlacementPlan.preview(
      document: document,
      brush: catalog.brush(1000, display: true),
      x: 2,
      y: 1,
      worldVersion: 326,
    );
    final fragment = plan.fragment;
    expect(fragment.sourceX, 12);
    expect(fragment.sourceY, 21);
    expect(fragment.objects!.sublist(64), [232, 3, 0, 1, 0]);
    final payload = ByteData.sublistView(fragment.objects!);
    expect(payload.getUint32(40, Endian.little), 0);
    expect(payload.getUint32(44, Endian.little), 0);
    expect(payload.getUint32(32, Endian.little), 5);
    expect(payload.getUint32(36, Endian.little), 1);
    plan.apply(document);
    final saved = document.encode();
    expect(document.objectCount, 1);
    final objects = ByteData.sublistView(document.objects!);
    expect(objects.getUint32(40, Endian.little), 2);
    expect(objects.getUint32(44, Endian.little), 1);
    expect(objects.getUint32(20, Endian.little), 10);
    final decoded = AdvancedRegionDocument.decode(saved);
    expect(decoded.records, document.records);
    expect(decoded.objects, document.objects);
    document.undo();
    expect(document.encode(), before);
    expect(document.objectCount, 0);
    expect(document.historyBytes, document.records.length + 69);
    document.redo();
    expect(document.encode(), saved);
    expect(document.historyBytes, document.records.length);
  });

  test(
    'append preserves existing object payload; multiple edits undo both halves',
    () {
      final document = blankRegion();
      FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(1000, display: true),
        x: 0,
        y: 0,
        worldVersion: 326,
      ).apply(document);
      final first = document.encode(), firstObjects = document.objects!;
      FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(34, display: true),
        x: 3,
        y: 2,
        worldVersion: 326,
      ).apply(document);
      expect(document.objectCount, 2);
      expect(
        document.objects!.sublist(32, firstObjects.length),
        firstObjects.sublist(32),
      );
      expect(document.objects!.sublist(document.objects!.length - 5), [
        34,
        0,
        0,
        1,
        0,
      ]);
      final second = document.encode();
      document.undo();
      expect(document.encode(), first);
      document.redo();
      expect(document.encode(), second);
      document.undo();
      document.setCell(5, 4, {'wall': 3});
      expect(document.canRedo, isFalse);
      expect(document.objectCount, 1);
    },
  );

  test(
    'ordinary item frame remains empty, never displays its own inventory ID',
    () {
      final plan = FusionPlacementPlan.preview(
        document: blankRegion(),
        brush: catalog.brush(3276),
        x: 0,
        y: 0,
        worldVersion: 326,
      );
      expect(plan.fragment.objects!.sublist(64), [0, 0, 0, 0, 0]);
    },
  );

  test('bounds, missing cells, occupied foreground and old metadata version reject atomically', () {
    final document = blankRegion();
    document.setCell(2, 2, {'active': 1, 'block': 1});
    final original = document.encode(), revision = document.revision;
    for (final position in [(1, 1), (-1, 0), (5, 4)]) {
      final plan = FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(34),
        x: position.$1,
        y: position.$2,
        worldVersion: 326,
      );
      expect(plan.canPlace, isFalse);
      expect(() => plan.apply(document), throwsStateError);
    }
    final old = FusionPlacementPlan.preview(
      document: document,
      brush: catalog.brush(1000, display: true),
      x: 0,
      y: 0,
      worldVersion: 325,
    );
    expect(old.blockers.join(), contains('326'));
    expect(document.encode(), original);
    expect(document.revision, revision);
    final sparse = AdvancedRegionDocument(
      width: 6,
      height: 5,
      records: document.records.sublist(0, 32),
    );
    expect(
      FusionPlacementPlan.preview(
        document: sparse,
        brush: catalog.brush(34),
        x: 0,
        y: 0,
        worldVersion: 326,
      ).blockers.join(),
      contains('稀疏'),
    );
  });

  test(
    'stale previews cannot overwrite later edits or reapply after staging',
    () {
      final document = blankRegion();
      final plan = FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(34),
        x: 0,
        y: 0,
        worldVersion: 326,
      );
      document.setCell(5, 4, {'wall': 2});
      expect(() => plan.fragment, throwsStateError);
      expect(() => plan.apply(document), throwsStateError);
      final fresh = FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(34),
        x: 0,
        y: 0,
        worldVersion: 326,
      );
      fresh.apply(document);
      expect(() => fresh.apply(document), throwsStateError);
    },
  );

  test('missing rows and version mismatch stay disabled', () {
    expect(catalog.unavailableReason(48), isNull);
    expect(catalog.unavailableReason(999), contains('占格'));
    expect(catalog.unavailableReason(1000), contains('展示框'));
    expect(catalog.brush(48).isContainer, isTrue);
    expect(() => catalog.brush(34, variantIndex: 2), throwsRangeError);
    expect(
      () => FusionPlacementCatalog(placementCatalog(version: 'other')),
      throwsFormatException,
    );
    expect(catalog.search(display: true, query: '1000').single.numericId, 1000);
    expect(catalog.search(query: 'tile:15').single.numericId, 34);
  });

  test('invalid row heights and full-frame overflow are rejected', () {
    for (final patch in [
      {
        'coordinateHeights': [16],
      },
      {'frameX': 32760},
      {'coordinatePadding': -1},
    ]) {
      final row = placementCatalog().families['tile-object-data']!.first;
      expect(
        () => FusionPlacementGeometry.fromEntry(
          CatalogEntry(row.family, {...row.fields, ...patch}),
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'existing companion anchors reject even if their tile layer was erased',
    () {
      final document = blankRegion();
      FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(1000, display: true),
        x: 0,
        y: 0,
        worldVersion: 326,
      ).apply(document);
      for (var x = 0; x < 2; x++) {
        for (var y = 0; y < 2; y++) {
          document.setCell(x, y, {'active': 0});
        }
      }
      final plan = FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(1000, display: true),
        x: 1,
        y: 1,
        worldVersion: 326,
      );
      expect(plan.canPlace, isFalse);
      expect(plan.blockers.join(), contains('附加记录重叠'));
    },
  );

  test('malformed companion and wrong source origin reject before staging', () {
    final good = FusionPlacementPlan.preview(
      document: blankRegion(),
      brush: catalog.brush(1000, display: true),
      x: 0,
      y: 0,
      worldVersion: 326,
    ).fragment.objects!;
    for (final offset in [20, 56, 52]) {
      final bad = Uint8List.fromList(good);
      ByteData.sublistView(bad).setUint32(offset, 999, Endian.little);
      final document = blankRegion(objects: bad);
      final plan = FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(34),
        x: 3,
        y: 1,
        worldVersion: 326,
      );
      expect(plan.canPlace, isFalse);
      expect(document.canUndo, isFalse);
    }
  });
}
