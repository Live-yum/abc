import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/platform/files.dart';

class LocalFiles implements FileGateway {
  PickedFile? next;
  Uint8List? output;
  String? filename;
  @override
  Future<PickedFile?> pick(String kind) async => next;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    filename = name;
    output = Uint8List.fromList(bytes);
    return true;
  }
}

void main() {
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  final fixture = Platform.environment['TERRAFORGE_WORLD_FIXTURE'];
  test(
    'real native application transactions preserve originals and recover failed edits',
    () async {
      final bytes = await File(fixture!).readAsBytes(),
          files = LocalFiles()
            ..next = PickedFile(
              'synthetic.wld',
              await File(fixture).readAsBytes(),
            );
      final workspace = Workspace(engine: createTerraEngine(), files: files);
      await workspace.dispatch('import', {'kind': 'world'});
      expect(workspace.view.error, isEmpty);
      expect(workspace.view.world, isNotEmpty);
      expect(workspace.view.worldPreview, isNotNull);
      await workspace.dispatch('stageWorld', {
        'field': 'name',
        'value': 'TerraForge transaction',
      });
      expect(workspace.view.error, isEmpty);
      expect(workspace.view.world['name'], 'TerraForge transaction');
      await workspace.dispatch('stageWorld', {
        'field': 'worldName',
        'value': 123,
      });
      expect(workspace.view.error, isNotEmpty);
      expect(workspace.view.world['name'], 'TerraForge transaction');
      await workspace.dispatch('export', {'kind': 'world'});
      expect(workspace.view.error, isEmpty);
      expect(files.filename, 'synthetic_terraforge.wld');
      expect(files.output, isNotEmpty);
      expect(await File(fixture).readAsBytes(), bytes);
      await workspace.dispatch('undo', {'canvas': 'world'});
      expect(workspace.view.error, isEmpty);
      await workspace.dispatch('export', {'kind': 'world'});
      expect(files.output, bytes);
      await workspace.dispatch('newPlayer', {'name': 'TerraForge fixture'});
      expect(workspace.view.error, isEmpty);
      await workspace.dispatch('stageInventory', {
        'slot': 0,
        'itemId': 8,
        'quantity': 50,
        'prefix': 0,
      });
      expect(workspace.view.error, isEmpty);
      await workspace.dispatch('export', {'kind': 'player'});
      expect(workspace.view.error, isEmpty);
      expect(files.output, isNotEmpty);
      await workspace.close();
      workspace.dispose();
    },
    skip: library == null || fixture == null
        ? 'Native integration requires generated fixture and built engine.'
        : false,
  );
}
