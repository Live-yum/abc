import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/fusion_placement.dart';
import 'package:terraforge/domain/region_document.dart';

import 'support/fusion_placement_fixture.dart';

void main() {
  final catalog = FusionPlacementCatalog(metadataPlacementCatalog());
  const containers = {21, 88, 467}, signs = {55, 85, 425, 573};
  const entities = [378, 395, 423, 470, 471, 475, 520, 597, 698, 723, 724];

  for (final tile in metadataTestShapes.keys) {
    test('tile $tile creates exact empty/default schema and paired undo', () {
      final document = blankRegion();
      final original = document.encode();
      final brush = catalog.brush(
        6000 + tile,
        name: containers.contains(tile) ? '箱😀' : '',
        text: signs.contains(tile) ? '标牌\nΩ😀' : '',
        logicOn: tile == 423,
      );
      final plan = FusionPlacementPlan.preview(
        document: document,
        brush: brush,
        x: 1,
        y: 1,
        worldVersion: 326,
      );
      expect(plan.blockers, isEmpty);
      final fragment = plan.fragment;
      final bytes = fragment.objects!, header = ByteData.sublistView(bytes);
      final payload = bytes.sublist(64);
      final section = containers.contains(tile)
          ? 2
          : signs.contains(tile)
          ? 3
          : 5;
      expect(header.getUint32(32, Endian.little), section);
      expect(
        header.getUint32(36, Endian.little),
        section == 5 ? entities.indexOf(tile) : 0,
      );
      expect(header.getUint32(48, Endian.little), tile);
      expect(header.getUint32(52, Endian.little), payload.length);
      expect(header.getUint32(16, Endian.little), bytes.length);
      expect(header.getUint32(20, Endian.little), 11);
      expect(header.getUint32(24, Endian.little), 21);
      if (section == 2) {
        final name = utf8.encode('箱😀');
        expect(payload.sublist(0, name.length + 1), [name.length, ...name]);
        expect(
          ByteData.sublistView(payload)
              .getUint32(name.length + 1, Endian.little),
          40,
        );
        expect(payload.sublist(name.length + 5), List.filled(80, 0));
        expect(brush.intent(1, 1)['name'], '箱😀');
      } else if (section == 3) {
        final text = utf8.encode('标牌\nΩ😀');
        expect(payload, [text.length, ...text]);
        expect(brush.intent(1, 1)['text'], '标牌\nΩ😀');
      } else {
        final expected = switch (tile) {
          378 => [255, 255],
          423 => [7, 1],
          470 => [0, 0, 0, 0],
          475 => [0],
          597 => <int>[],
          723 || 724 => [(6000 + tile) & 255, (6000 + tile) >> 8],
          _ => [0, 0, 0, 0, 0],
        };
        expect(payload, expected);
      }
      plan.apply(document);
      final placed = document.encode();
      expect(document.objectCount, 1);
      expect(AdvancedRegionDocument.decode(placed).objects, document.objects);
      // Re-parsing the existing object must reject a second overlapping object.
      expect(
        FusionPlacementPlan.preview(
          document: document,
          brush: brush,
          x: 1,
          y: 1,
          worldVersion: 326,
        ).canPlace,
        isFalse,
      );
      document.undo();
      expect(document.encode(), original);
      document.redo();
      expect(document.encode(), placed);
    });
  }

  test(
    'all companion families are WLD326-only and failures preserve both halves',
    () {
      for (final tile in metadataTestShapes.keys) {
        final document = blankRegion(), brush = catalog.brush(6000 + tile);
        final original = document.encode(), revision = document.revision;
        final old = FusionPlacementPlan.preview(
          document: document,
          brush: brush,
          x: 0,
          y: 0,
          worldVersion: 325,
        );
        expect(old.blockers.join(), contains('326'));
        expect(() => old.apply(document), throwsStateError);
        expect(document.encode(), original);
        expect(document.revision, revision);
        expect(document.canUndo, isFalse);
      }
    },
  );

  test(
    'UTF-8 budgets, multi-byte lengths and type-specific options are bounded',
    () {
      expect(() => catalog.brush(6021, name: '😀' * 11), throwsFormatException);
      expect(() => catalog.brush(6021, name: 'a' * 21), throwsFormatException);
      expect(
        () => catalog.brush(6021, name: 'bad\nname'),
        throwsFormatException,
      );
      expect(
        () => catalog.brush(6055, text: '😀' * 262145),
        throwsArgumentError,
      );
      expect(
        () => catalog.brush(6378, name: 'wrong target'),
        throwsArgumentError,
      );
      expect(
        () => catalog.brush(6021, text: 'wrong target'),
        throwsArgumentError,
      );
      expect(() => catalog.brush(6021, logicOn: true), throwsArgumentError);
      final doc = blankRegion();
      final brush = catalog.brush(6055, text: 'a' * 128);
      final bytes = FusionPlacementPlan.preview(
        document: doc,
        brush: brush,
        x: 0,
        y: 0,
        worldVersion: 326,
      ).fragment.objects!;
      expect(bytes.sublist(64, 66), [128, 1]);
      expect(catalog.brush(6021, name: '😀' * 10).name.length, 20);
      expect(catalog.brush(6423).intent(0, 0)['logicOn'], isFalse);
    },
  );

  test('companion dimensions and exact core frame grid are required', () {
    for (final patch in [
      <String, Object?>{'width': 3},
      <String, Object?>{
        'coordinateHeights': [20, 16],
      },
      <String, Object?>{'frameX': 18},
      <String, Object?>{'frameY': -1},
      <String, Object?>{'frameY': 36},
      <String, Object?>{'coordinateWidth': 18},
    ]) {
      final invalid = FusionPlacementCatalog(
        metadataPlacementCatalog(overrides: {21: patch}),
      );
      expect(invalid.unavailableReason(6021), contains('占格'));
      expect(() => invalid.brush(6021), throwsStateError);
    }
  });

  test(
    'existing malformed payload cannot be appended to or silently replaced',
    () {
      final valid = FusionPlacementPlan.preview(
        document: blankRegion(),
        brush: catalog.brush(6423),
        x: 0,
        y: 0,
        worldVersion: 326,
      ).fragment.objects!;
      for (final payload in [
        [8, 0],
        [1, 2],
      ]) {
        final broken = Uint8List.fromList(valid)..setAll(64, payload);
        final document = blankRegion(objects: broken),
            before = blankRegion(objects: broken).encode();
        final plan = FusionPlacementPlan.preview(
          document: document,
          brush: catalog.brush(6021),
          x: 3,
          y: 2,
          worldVersion: 326,
        );
        expect(plan.canPlace, isFalse);
        expect(() => plan.apply(document), throwsStateError);
        expect(document.encode(), before);
        expect(document.canUndo, isFalse);
      }
    },
  );

  test(
    'mixed companions append without changing existing text or inventory',
    () {
      final document = blankRegion(width: 10, height: 10);
      FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(6021, name: 'Keep this'),
        x: 0,
        y: 0,
        worldVersion: 326,
      ).apply(document);
      final before = document.encode(), original = document.objects!;
      FusionPlacementPlan.preview(
        document: document,
        brush: catalog.brush(6055, text: 'Next'),
        x: 3,
        y: 3,
        worldVersion: 326,
      ).apply(document);
      expect(document.objectCount, 2);
      expect(
        document.objects!.sublist(32, original.length),
        original.sublist(32),
      );
      final after = document.encode();
      document.undo();
      expect(document.encode(), before);
      document.redo();
      expect(document.encode(), after);
    },
  );
}
