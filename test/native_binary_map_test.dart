import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/terraria_map.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/world_map_backend.dart';

void main() {
  test(
    'Native WLD→binary MAP, marked MAP, failed request recovery and exact source',
    () async {
      final original = await File('assets/qa/synthetic-objects.wld')
          .readAsBytes();
      final engine = createTerraEngine(), maps = engine as WorldMapBackend;
      final world = await engine.open(original, kind: 'wld');
      try {
        for (var cycle = 0; cycle < 3; cycle++) {
          final bytes = await maps.generateWorldMap(world);
          final map = TerrariaMapSession.decode(bytes);
          expect(map.chunked, isTrue);
          expect(map.width * map.height, greaterThan(0));
          final marked = await maps.generateWorldMap(
            world,
            markers: {
              'tile_markers': [
                {'tile_type': 55, 'color': '#FF00FF', 'radius': 2},
              ],
              'chest_markers': [
                {'item_id': 8, 'color': '#00FFFF', 'radius': 2},
              ],
            },
          );
          final markedMap = TerrariaMapSession.decode(marked);
          expect(marked, isNot(bytes));
          expect(markedMap.width, map.width);
          map.editRect(0, 0, 1, 1, light: 123);
          final readback = TerrariaMapSession.decode(map.exportBytes());
          expect(readback.cellAt(0, 0).light, 123);
          readback.close();
          markedMap.close();
          map.close();
          expect(await engine.save(world), original);
        }
        await expectLater(
          maps.generateWorldMap(
            world,
            markers: {
              'tile_markers': [
                {'tile_type': 'bad'},
              ],
            },
          ),
          throwsA(isA<Exception>()),
        );
        final recovered = TerrariaMapSession.decode(
          await maps.generateWorldMap(world),
        );
        recovered.close();
        expect(await engine.save(world), original);
        expect(
          await File('assets/qa/synthetic-objects.wld').readAsBytes(),
          original,
        );
      } finally {
        await engine.close(world);
      }
      await expectLater(
        maps.generateWorldMap(world),
        throwsA(isA<Exception>()),
      );
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires native engine'
        : false,
  );
}
