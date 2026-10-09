import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/fusion_placement.dart';
import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/resource_store.dart';

void main() {
  final env = Platform.environment;
  final enabled = [
    'TERRAFORGE_ENGINE_LIBRARY',
    'ABC_PRIVATE_PACK',
    'ABC_PRIVATE_WORLD326',
  ].every(env.containsKey);
  test(
    'local release furniture and every companion payload family pass native readback',
    () async {
      final catalog = FusionPlacementCatalog(
        ResourceStore.importPack(
          await File(env['ABC_PRIVATE_PACK']!).readAsBytes(),
        ).catalog,
      );
      final backend = createTerraEngine() as RegionBackend;
      final world = await File(env['ABC_PRIVATE_WORLD326']!).readAsBytes();
      final region = AdvancedRegionDocument(
        width: 6,
        height: 6,
        sourceX: 100,
        sourceY: 20,
        records: await backend.readRegion(world, 100, 20, 6, 6),
        objects: await backend.readRegionObjects(world, 100, 20, 6, 6),
      );
      final cases = <Map<String, Object?>>[];
      const metadataTiles = [
        21,
        88,
        467,
        55,
        85,
        425,
        573,
        378,
        395,
        423,
        470,
        471,
        475,
        520,
        597,
        698,
        723,
        724,
      ];
      final selections = <(int, bool, bool)>[
        (34, false, true),
        (32, false, true),
        (1, true, true),
      ];
      for (final tile in metadataTiles) {
        final items = catalog.entries
            .where(
              (item) =>
                  item.fields['createTile'] == tile &&
                  catalog.unavailableReason(item.numericId!) == null,
            )
            .toList();
        expect(
          items,
          isNotEmpty,
          reason: 'Missing release geometry for Tile $tile',
        );
        // Sensors have seven distinct check styles; the other families need one
        // actual selected release row each for their independent payload schema.
        for (final item in tile == 423 ? items : items.take(1)) {
          selections.add((item.numericId!, false, false));
        }
      }
      final verifiedTiles = <int>{};
      for (final selection in selections) {
        final shapes = catalog.variants(selection.$1, display: selection.$2);
        expect(shapes, isNotEmpty);
        for (
          var variant = 0;
          variant < (selection.$3 ? shapes.length : 1);
          variant++
        ) {
          final tile = shapes[variant].tile;
          final brush = catalog.brush(
            selection.$1,
            display: selection.$2,
            variantIndex: variant,
            name: {21, 88, 467}.contains(tile) ? '验证箱😀' : '',
            text: {55, 85, 425, 573}.contains(tile) ? '标牌验证\nΩ😀' : '',
            logicOn: tile == 423,
          );
          final plan = FusionPlacementPlan.preview(
            document: region,
            brush: brush,
            x: 1,
            y: 1,
            worldVersion: 326,
          );
          expect(plan.blockers, isEmpty);
          final fragment = plan.fragment,
              request = fragment.stampRequest(101, 21);
          final result = await backend.regionOperation(
            world,
            'stamp_tiles',
            request,
            records: fragment.records,
            objects: fragment.objects,
          );
          expect(
            await backend.readRegion(
              result,
              101,
              21,
              fragment.width,
              fragment.height,
            ),
            fragment.records,
          );
          final objects = await backend.readRegionObjects(
            result,
            101,
            21,
            fragment.width,
            fragment.height,
          );
          if (brush.requiresObjects) {
            expect(objects, fragment.objects, reason: 'Tile $tile companion');
            verifiedTiles.add(tile);
            if (brush.display) {
              expect(objects.sublist(objects.length - 5), [1, 0, 0, 1, 0]);
            }
            final corrupted = Uint8List.fromList(fragment.objects!);
            ByteData.sublistView(corrupted)
                .setUint32(52, corrupted.length, Endian.little);
            await expectLater(
              backend.regionOperation(
                world,
                'stamp_tiles',
                request,
                records: fragment.records,
                objects: corrupted,
              ),
              throwsA(isA<Exception>()),
            );
            expect(
              await backend.readRegion(world, 100, 20, 6, 6),
              region.records,
            );
          }
          final occupied = AdvancedRegionDocument(
            width: 6,
            height: 6,
            sourceX: 100,
            sourceY: 20,
            records: await backend.readRegion(result, 100, 20, 6, 6),
            objects: await backend.readRegionObjects(result, 100, 20, 6, 6),
          );
          expect(
            FusionPlacementPlan.preview(
              document: occupied,
              brush: brush,
              x: 1,
              y: 1,
              worldVersion: 326,
            ).canPlace,
            isFalse,
          );
          if (brush.requiresObjects) {
            await expectLater(
              backend.regionOperation(
                result,
                'stamp_tiles',
                request,
                records: fragment.records,
                objects: fragment.objects,
              ),
              throwsA(isA<Exception>()),
            );
          }
          cases.add({
            'name': '${selection.$1}:$variant:${selection.$2}',
            'display': brush.display,
            'tile': tile,
            'request': request,
            'records': base64Encode(fragment.records),
            'objects': fragment.objects == null
                ? null
                : base64Encode(fragment.objects!),
          });
        }
      }
      expect(verifiedTiles, containsAll(metadataTiles));
      expect(await File(env['ABC_PRIVATE_WORLD326']!).readAsBytes(), world);
      if (env['ABC_FUSION_PROOF_DIR'] != null) {
        final output = Directory(env['ABC_FUSION_PROOF_DIR']!);
        await output.create(recursive: true);
        await File('${output.path}/source.wld').writeAsBytes(world);
        await File('${output.path}/placements.json')
            .writeAsString(jsonEncode(cases));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: enabled
        ? false
        : 'Requires private local engine, resource pack and WLD326 fixture',
  );
}
