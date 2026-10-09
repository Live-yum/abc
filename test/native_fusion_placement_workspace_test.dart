import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  PickedFile? input;
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => input;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = Uint8List.fromList(bytes);
    return true;
  }
}

void main() {
  test(
    'new display placement stages paired history, confirms narrow insertion, rejects stale source and undoes exactly',
    () async {
      final files = _Files(), engine = createTerraEngine();
      final app = Workspace(
        engine: engine,
        files: files,
        regionBackend: engine as RegionBackend,
      );
      files.input = PickedFile(
        'resources.abcpack',
        await File(Platform.environment['ABC_PRIVATE_PACK']!).readAsBytes(),
      );
      await app.dispatch('import', {'kind': 'resources'});
      expect(app.view.error, isEmpty);
      final original = await File(Platform.environment['ABC_PRIVATE_WORLD326']!)
          .readAsBytes();
      files.input = PickedFile('placement.wld', original);
      await app.dispatch('import', {'kind': 'world'});
      expect(app.view.error, isEmpty);
      await app.dispatch('fusionRegion', {
        'x': 100,
        'y': 20,
        'width': 6,
        'height': 6,
      });
      expect(app.view.error, isEmpty);
      final before = app.view.region!.records,
          objects = app.view.region!.objects;
      final intent = {
        'itemId': 1,
        'variantIndex': 0,
        'display': true,
        'x': 1,
        'y': 1,
      };
      await app.dispatch('fusionPlace', intent);
      expect(app.view.error, isEmpty);
      expect(app.view.region!.objectCount, 1);
      expect(app.view.result['worldModified'], isFalse);
      await app.dispatch('fusionDiscardPlacement');
      expect(app.view.region!.records, before);
      expect(app.view.region!.objects, objects);
      await app.dispatch('fusionPlace', intent);
      await app.dispatch('fusionInsert');
      expect(app.view.error, contains('确认'));
      await app.dispatch('stageWorld', {
        'field': 'name',
        'value': 'Changed source',
      });
      await app.dispatch('fusionInsert', {'confirmed': true});
      expect(app.view.error, contains('变化'));
      await app.dispatch('undo', {'canvas': 'world'});
      await app.dispatch('fusionInsert', {'confirmed': true});
      expect(app.view.error, isEmpty);
      expect(app.view.result['fusionPlacement'], isNull);
      await app.dispatch('fusionRegion', {
        'x': 101,
        'y': 21,
        'width': 2,
        'height': 2,
      });
      expect(app.view.error, isEmpty);
      expect(app.view.region!.objectCount, 1);
      expect(app.view.region!.cellAt(0, 0)!['block'], 395);
      final blankRecords = app.view.region!.records;
      final blankData = ByteData.sublistView(blankRecords);
      for (var i = 0; i < 4; i++) {
        blankData.setUint32(i * 32 + 8, 0, Endian.little);
        blankData.setUint32(i * 32 + 12, 0, Endian.little);
      }
      final deceptive = AdvancedRegionDocument(
        width: 2,
        height: 2,
        records: blankRecords,
        sourceX: 101,
        sourceY: 21,
      );
      files.input = PickedFile(
        'blank.abc-region.json',
        Uint8List.fromList(utf8.encode(deceptive.encode())),
      );
      await app.dispatch('import', {'kind': 'project'});
      expect(app.view.error, isEmpty);
      await app.dispatch('fusionPlace', {
        'itemId': 1,
        'variantIndex': 0,
        'display': true,
        'x': 0,
        'y': 0,
      });
      expect(app.view.error, isEmpty);
      await app.dispatch('fusionInsert', {'confirmed': true});
      expect(app.view.error, contains('实际世界目标'));
      await app.dispatch('fusionDiscardPlacement');
      await app.dispatch('undo', {'canvas': 'world'});
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, original);
      await app.close();
      app.dispose();
    },
    skip:
        Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null ||
            Platform.environment['ABC_PRIVATE_PACK'] == null ||
            Platform.environment['ABC_PRIVATE_WORLD326'] == null
        ? 'Requires private local engine/catalog fixture'
        : false,
  );
}
