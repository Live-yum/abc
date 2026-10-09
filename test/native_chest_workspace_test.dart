import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/domain/prefix_rules.dart';

class _Files implements FileGateway {
  Uint8List source;
  String fileName = 'chests.wld';
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async => PickedFile(fileName, source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  test(
    'real chest rename, prefix preservation, sorting, explicit clear and complete undo',
    () async {
      final engine = createTerraEngine();
      final doc = await engine.open(
        await File('assets/qa/synthetic-objects.wld').readAsBytes(),
        kind: 'wld',
      );
      final metadata = await engine.inspect(doc);
      final chests = jsonDecode(jsonEncode(metadata['chests'])) as List;
      (chests[0]['items'] as List)[2] = {
        'itemType': 1,
        'stack': 1,
        'prefix': 0,
      };
      (chests[0]['items'] as List)[10] = {
        'itemType': 8,
        'stack': 3,
        'prefix': 3,
      };
      await engine.mutate(doc, 'replace_chests', {'chests': chests});
      final original = await engine.save(doc);
      await engine.close(doc);
      final files = _Files(original);
      final workspace = Workspace(engine: engine, files: files);
      await workspace.dispatch('import', {'kind': 'world'});
      List current() =>
          ((workspace.view.world['chests'] as List).first as Map)['items']
              as List;
      expect(workspace.view.result['modifiedChests'], isEmpty);
      await workspace.dispatch('stageChest', {'index': 0, 'name': '整理测试'});
      expect(workspace.view.error, isEmpty);
      expect((workspace.view.world['chests'] as List).first['name'], '整理测试');
      expect(workspace.view.result['modifiedChests'], [0]);
      await workspace.dispatch('stageChest', {
        'index': 0,
        'slot': 0,
        'itemId': 8,
        'quantity': 8,
      });
      expect(workspace.view.error, isEmpty);
      expect(
        (current()[0] as Map)['prefix'],
        3,
        reason: 'Omitted prefix must preserve the actual prefix',
      );
      await workspace.dispatch('stageChest', {
        'index': 0,
        'slot': 0,
        'itemId': 8,
        'quantity': 0,
      });
      expect(workspace.view.error, isNotEmpty);
      expect((current()[0] as Map)['stack'], 8);
      await workspace.dispatch('chestOrganize', {'index': 0});
      expect(workspace.view.error, isEmpty);
      expect((current()[0] as Map)['itemType'], 1);
      expect(
        current().whereType<Map>().length,
        3,
        reason: 'Unmatched resources only sort, never merge',
      );
      await workspace.dispatch('chestBestPrefixes', {'confirmed': true});
      expect(workspace.view.error, contains('匹配'));
      await workspace.dispatch('chestClear', {'index': 0});
      expect(workspace.view.error, contains('确认'));
      expect(current().whereType<Map>().length, 3);
      await workspace.dispatch('chestClear', {'index': 0, 'confirmed': true});
      expect(workspace.view.error, isEmpty);
      expect(current().every((item) => item == null), isTrue);
      expect(current().length, 40);
      for (var i = 0; i < 4; i++) {
        await workspace.dispatch('undo', {'canvas': 'world'});
      }
      expect(workspace.view.result['modifiedChests'], isEmpty);
      await workspace.dispatch('export', {'kind': 'world'});
      expect(files.output, original);
      await workspace.close();
      workspace.dispose();
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires native engine'
        : false,
  );
  test(
    'verified v326 catalog reforge survives real WLD readback and undo',
    () async {
      final files = _Files(
        await File(Platform.environment['ABC_PRIVATE_PACK']!).readAsBytes(),
      )..fileName = 'resources.abcpack';
      final app = Workspace(engine: createTerraEngine(), files: files);
      await app.dispatch('import', {'kind': 'resources'});
      expect(app.view.error, isEmpty);
      final original = await File(Platform.environment['ABC_PRIVATE_WORLD326']!)
          .readAsBytes();
      files.source = original;
      files.fileName = 'verified-chest.wld';
      await app.dispatch('import', {'kind': 'world'});
      expect(app.view.error, isEmpty);
      expect(app.view.result['chestRulesVerified'], isTrue);
      expect(app.view.world['chests'], isNotEmpty);
      await app.dispatch('stageChest', {
        'index': 0,
        'slot': 0,
        'itemId': 1,
        'quantity': 1,
        'prefix': 0,
      });
      expect(app.view.error, isEmpty);
      await app.dispatch('export', {'kind': 'world'});
      final beforeReforge = files.output;
      final expected = PrefixRules(app.view.resources!.catalog)
          .bestPrefix(1, version: 326, current: 0);
      expect(expected, isNotNull);
      await app.dispatch('chestBestPrefixes', {'index': 0, 'confirmed': true});
      expect(app.view.error, isEmpty);
      final items =
          ((app.view.world['chests'] as List).first as Map)['items'] as List;
      expect((items.first as Map)['prefix'], expected!.id);
      await app.dispatch('undo', {'canvas': 'world'});
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, beforeReforge);
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
        ? 'Requires native engine and external verified v326 fixture/catalog'
        : false,
  );
}
