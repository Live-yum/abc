import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/region_brush.dart';
import 'package:terraforge/domain/resource_catalog.dart';

import 'support/fusion_placement_fixture.dart';

ResourceCatalog brushCatalog() => ResourceCatalog(
  gameVersion: 'synthetic',
  provenance: const {'fixture': true},
  families: {
    'tile-atlases': [
      for (final id in [0, 1, 30])
        CatalogEntry('tile-atlases', {'id': id, 'frameImportant': false}),
      CatalogEntry('tile-atlases', {'id': 21, 'frameImportant': true}),
    ],
  },
);

Map<String, int> layeredCell() => {
  'active': 1,
  'block': 1,
  'wall': 7,
  'blockPaint': 5,
  'wallPaint': 6,
  'liquid': 200,
  'liquidType': 3,
  'wires': 10,
  'slope': 2,
  'actuator': 1,
  'inactive': 1,
  'invisibleBlock': 1,
  'invisibleWall': 1,
  'fullbrightBlock': 1,
  'fullbrightWall': 1,
};

void main() {
  test(
    'intent is strict, roundtrips and never accepts arbitrary tile fields',
    () {
      final intents = <Map<String, Object?>>[
        {'kind': 'block', 'id': 0},
        {'kind': 'wall', 'id': 65535},
        {'kind': 'paint', 'layer': 'block', 'paint': 30},
        {'kind': 'paint', 'layer': 'wall', 'paint': 0},
        {'kind': 'liquid', 'liquidType': 4, 'amount': 0},
        {'kind': 'wire', 'mask': 15, 'remove': true},
        {'kind': 'shape', 'shape': 5},
        {'kind': 'actuator', 'remove': false},
        {'kind': 'erase', 'layer': 'all'},
      ];
      for (final intent in intents) {
        final brush = RegionBrush.fromIntent(intent);
        expect(brush.intent, intent);
        expect(brush, RegionBrush.fromIntent(intent));
        expect(brush.hashCode, RegionBrush.fromIntent(intent).hashCode);
        expect(() => brush.intent['kind'] = 'erase', throwsUnsupportedError);
        expect(
          () => RegionBrush.fromIntent({...intent, 'frameX': 18}),
          throwsFormatException,
        );
      }
      final input = <String, Object?>{'kind': 'block', 'id': 1};
      final snapshot = RegionBrush.fromIntent(input);
      input['id'] = 21;
      expect(snapshot.id, 1);
      expect(snapshot, isNot(RegionBrush.fromIntent(input)));
    },
  );

  test('rejects invalid types, ranges, missing keys and combinations', () {
    for (final intent in <Map<String, Object?>>[
      {},
      {'kind': 'unknown'},
      {'kind': 'block', 'id': -1},
      {'kind': 'block', 'id': 65536},
      {'kind': 'wall', 'id': 1.0},
      {'kind': 'block', 'id': '1'},
      {'kind': 'paint', 'layer': 'liquid', 'paint': 3},
      {'kind': 'paint', 'layer': 'block', 'paint': 31},
      {'kind': 'liquid', 'liquidType': 0, 'amount': 0},
      {'kind': 'liquid', 'liquidType': 5, 'amount': 255},
      {'kind': 'liquid', 'liquidType': 1, 'amount': 256},
      {'kind': 'wire', 'mask': 0, 'remove': false},
      {'kind': 'wire', 'mask': 16, 'remove': false},
      {'kind': 'wire', 'mask': 1, 'remove': 0},
      {'kind': 'shape', 'shape': 6},
      {'kind': 'actuator'},
      {'kind': 'actuator', 'remove': false, 'inactive': true},
      {'kind': 'erase', 'layer': 'furniture'},
    ]) {
      expect(() => RegionBrush.fromIntent(intent), throwsFormatException);
    }
  });

  test('selected multiple wire channels preserve all unselected bits', () {
    final cell = layeredCell();
    final add = RegionBrush.fromIntent({
      'kind': 'wire',
      'mask': 5,
      'remove': false,
    });
    final remove = RegionBrush.fromIntent({
      'kind': 'wire',
      'mask': 9,
      'remove': true,
    });
    expect(add.patchFor(cell), {'wires': 15});
    expect(remove.patchFor(cell), {'wires': 2});
    expect(cell, layeredCell());
    expect(add.patchFor({...cell, 'wires': 15}), isNull);
  });

  test('all four liquid kinds and zero amount have canonical patches', () {
    for (var type = 1; type <= 4; type++) {
      final brush = RegionBrush.fromIntent({
        'kind': 'liquid',
        'liquidType': type,
        'amount': 73,
      });
      expect(brush.patchFor(layeredCell()), {'liquid': 73, 'liquidType': type});
      final clear = RegionBrush.fromIntent({...brush.intent, 'amount': 0});
      expect(clear.patchFor(layeredCell()), {'liquid': 0, 'liquidType': 0});
    }
  });

  test(
    'paint targets only its layer, including furniture; missing layer skips',
    () {
      final block = RegionBrush.fromIntent({
        'kind': 'paint',
        'layer': 'block',
        'paint': 30,
      });
      final wall = RegionBrush.fromIntent({
        'kind': 'paint',
        'layer': 'wall',
        'paint': 0,
      });
      expect(block.patchFor({...layeredCell(), 'block': 21}), {
        'blockPaint': 30,
      });
      expect(wall.patchFor(layeredCell()), {'wallPaint': 0});
      expect(block.patchFor({...layeredCell(), 'active': 0}), isNull);
      expect(wall.patchFor({...layeredCell(), 'wall': 0}), isNull);
      expect(block.patchFor(null), isNull);
      expect(RegionBrush.wall(42).patchFor(layeredCell()), {
        'wall': 42,
        'wallPaint': 0,
      });
    },
  );

  test(
    'ordinary replacement resets foreground attributes and preserves others',
    () {
      final patch = RegionBrush.block(0)
          .patchFor(layeredCell(), catalog: brushCatalog());
      expect(patch, {
        'active': 1,
        'block': 0,
        'blockPaint': 0,
        'slope': 0,
        'inactive': 0,
        'invisibleBlock': 0,
        'fullbrightBlock': 0,
      });
      expect(() => patch!['wall'] = 0, throwsUnsupportedError);
      expect(
        RegionBrush.block(30)
            .patchFor({'active': 0}, catalog: brushCatalog())!['block'],
        30,
      );
    },
  );

  test('all six shapes require verified active ordinary cells', () {
    for (var shape = 0; shape <= 5; shape++) {
      final brush = RegionBrush.fromIntent({'kind': 'shape', 'shape': shape});
      final cell = {...layeredCell(), 'slope': 7};
      expect(brush.patchFor(cell, catalog: brushCatalog()), {'slope': shape});
      expect(brush.patchFor({...cell, 'active': 0}), isNull);
      expect(() => brush.patchFor(cell), throwsFormatException);
      expect(
        () => brush.patchFor({...cell, 'block': 21}, catalog: brushCatalog()),
        throwsFormatException,
      );
    }
  });

  test(
    'unknown or framed foreground cannot be overwritten or partly erased',
    () {
      final brushes = [
        RegionBrush.block(1),
        RegionBrush.fromIntent({'kind': 'erase', 'layer': 'block'}),
        RegionBrush.fromIntent({'kind': 'erase', 'layer': 'all'}),
      ];
      for (final brush in brushes) {
        for (final id in [21, 999]) {
          final cell = {...layeredCell(), 'block': id};
          expect(
            () => brush.patchFor(cell, catalog: brushCatalog()),
            throwsFormatException,
          );
          expect(cell['wall'], 7);
          expect(cell['wires'], 10);
        }
      }
      expect(
        () =>
            RegionBrush.block(21)
                .patchFor({'active': 0}, catalog: brushCatalog()),
        throwsFormatException,
      );
      expect(
        () => RegionBrush.block(1).patchFor(layeredCell()),
        throwsFormatException,
      );
    },
  );

  test(
    'actuator removal restores active state but never edits foreground type',
    () {
      final install = RegionBrush.fromIntent({
        'kind': 'actuator',
        'remove': false,
      });
      final remove = RegionBrush.fromIntent({
        'kind': 'actuator',
        'remove': true,
      });
      expect(install.patchFor({...layeredCell(), 'actuator': 0}), {
        'actuator': 1,
      });
      expect(remove.patchFor(layeredCell()), {'actuator': 0, 'inactive': 0});
    },
  );

  test(
    'erase is layer-specific and retains foreground for cosmetic erasure',
    () {
      final cell = {...layeredCell(), 'block': 21};
      for (final entry in <String, Map<String, int>>{
        'wall': {
          'wall': 0,
          'wallPaint': 0,
          'invisibleWall': 0,
          'fullbrightWall': 0,
        },
        'liquid': {'liquid': 0, 'liquidType': 0},
        'wire': {'wires': 0, 'actuator': 0, 'inactive': 0},
      }.entries) {
        expect(
          RegionBrush.fromIntent({'kind': 'erase', 'layer': entry.key})
              .patchFor(cell),
          entry.value,
        );
      }
      final all = RegionBrush.fromIntent({'kind': 'erase', 'layer': 'all'});
      expect(
        all.patchFor(layeredCell(), catalog: brushCatalog())!.values,
        everyElement(0),
      );
    },
  );

  test(
    'brush stroke preserves unrelated records and groups history atomically',
    () {
      final document = blankRegion(width: 3, height: 1);
      document.setCell(0, 0, layeredCell());
      document.setCell(1, 0, {...layeredCell(), 'block': 21});
      final before = document.records;
      final brush = RegionBrush.fromIntent({
        'kind': 'wire',
        'mask': 5,
        'remove': false,
      });
      document.beginStroke();
      for (var x = 0; x < 2; x++) {
        final patch = brush.patchFor(document.cellAt(x, 0));
        if (patch != null) document.setCell(x, 0, patch);
      }
      document.endStroke();
      final after = document.records;
      for (var index = 0; index < before.length; index++) {
        if (index != 23 && index != 55) expect(after[index], before[index]);
      }
      expect(document.cellAt(1, 0)!['block'], 21);
      document.undo();
      expect(document.records, before);
      document.redo();
      expect(document.records, after);
    },
  );
}
