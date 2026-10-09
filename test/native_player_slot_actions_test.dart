import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/prefix_rules.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => PickedFile(
    'resources.abcpack',
    await File(Platform.environment['ABC_PRIVATE_PACK']!).readAsBytes(),
  );
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = Uint8List.fromList(bytes);
    return true;
  }
}

void main() {
  test(
    'player slot paste and confirmed bulk prefixes survive codec and undo',
    () async {
      final files = _Files();
      final workspace = Workspace(engine: createTerraEngine(), files: files);
      await workspace.dispatch('import', {'kind': 'resources'});
      expect(workspace.view.error, isEmpty);
      await workspace.dispatch('newPlayer', {'name': 'Slot fixture'});
      expect(workspace.view.player['version'], 326);
      await workspace.dispatch('export', {'kind': 'player'});
      final original = files.output;
      final slot = {'itemType': 1, 'stack': 1, 'prefix': 0, 'favorited': true};
      await workspace.dispatch('playerSlotEdit', {
        'group': 'inventory',
        'index': 0,
        'slot': slot,
      });
      expect(workspace.view.error, isEmpty);
      await workspace.dispatch('playerSlotEdit', {
        'group': 'inventory',
        'index': 1,
        'slot': slot,
      });
      expect(workspace.view.error, isEmpty);
      await workspace.dispatch('export', {'kind': 'player'});
      final beforeReforge = files.output;
      await workspace.dispatch('playerBestPrefixes', {
        'groups': ['inventory'],
      });
      expect(workspace.view.error, contains('确认'));
      final expected = PrefixRules(workspace.view.resources!.catalog)
          .bestPrefix(1, version: 326, current: 0)!
          .id;
      await workspace.dispatch('playerBestPrefixes', {
        'groups': ['inventory'],
        'confirmed': true,
      });
      expect(workspace.view.error, isEmpty);
      final inventory = workspace.view.player['inventory'] as List;
      expect((inventory[0] as Map)['prefix'], expected);
      expect((inventory[1] as Map)['prefix'], expected);
      expect((inventory[1] as Map)['favorited'], true);
      await workspace.dispatch('undo', {'canvas': 'player'});
      await workspace.dispatch('export', {'kind': 'player'});
      expect(files.output, beforeReforge);
      for (var i = 0; i < 2; i++) {
        await workspace.dispatch('undo', {'canvas': 'player'});
      }
      await workspace.dispatch('export', {'kind': 'player'});
      expect(files.output, original);
      await workspace.close();
      workspace.dispose();
    },
    skip:
        Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null ||
            Platform.environment['ABC_PRIVATE_PACK'] == null
        ? 'Requires native engine and local catalog'
        : false,
  );
}
