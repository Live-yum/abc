import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/terraria_map.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/world_map_backend.dart';
import 'package:terraforge/platform/files.dart';

import '../tool/perf/map_fixture.dart';
import 'cloud_reference_contract_test.dart' show MemoryVault;
import 'workspace_test.dart' show FakeEngine, FakeFiles;

class MapEngine extends FakeEngine implements WorldMapBackend {
  final output = syntheticMap();
  Map<String, Object?>? markers;
  bool corruptOutput = false;
  @override
  Future<Map<String, dynamic>> inspect(EngineDocument document) async => {
    'name': 'Repository MAP fixture',
    'worldId': 17,
    'maxTilesX': 130,
    'maxTilesY': 70,
    'version': 326,
  };
  @override
  Future<Uint8List> generateWorldMap(
    EngineDocument world, {
    Map<String, Object?>? markers,
  }) async {
    this.markers = markers;
    return corruptOutput
        ? Uint8List.fromList([1, 2, 3])
        : Uint8List.fromList(output);
  }
}

void main() {
  for (final chunked in [true, false]) {
    test(
      'Workspace MAP $chunked imports, edits, verifies exports, restores and releases',
      () async {
        final source = syntheticMap(chunked: chunked);
        final files = FakeFiles()..next = PickedFile('original.map', source);
        final vault = MemoryVault();
        final workspace = Workspace(
          engine: FakeEngine(),
          files: files,
          vault: vault,
        );
        addTearDown(workspace.dispose);
        await workspace.dispatch('importMap');
        expect(workspace.view.error, isEmpty);
        expect(workspace.view.mapRaster, isNotNull);
        await workspace.dispatch('editMapRect', {
          'x': 3,
          'y': 4,
          'width': 2,
          'height': 2,
          'light': 17,
          'color': 9,
        });
        expect(workspace.view.error, isEmpty);
        expect(workspace.view.map!.isModified, isTrue);
        await workspace.dispatch('exportMap');
        expect(workspace.view.error, isEmpty);
        expect(files.saved, 'original_terraforge.map');
        final exported = TerrariaMapSession.decode(files.bytes!);
        expect(exported.cellAt(3, 4).light, 17);
        expect(exported.cellAt(3, 4).color, 9);
        exported.close();
        await workspace.dispatch('undoMap');
        expect(workspace.view.map!.isModified, isFalse);
        await workspace.dispatch('exportMap');
        expect(files.bytes, source);
        await workspace.dispatch('redoMap');
        expect(workspace.view.map!.isModified, isTrue);
        final map = workspace.view.map!;
        files.next = PickedFile('bad.map', Uint8List.fromList([1, 2, 3]));
        await workspace.dispatch('importMap');
        expect(workspace.view.error, isNotEmpty);
        expect(workspace.view.map, same(map));
        final previous = await workspace.mapBackend.exportVerified();
        await workspace.dispatch('editMapRect', {
          'x': 129,
          'y': 69,
          'width': 2,
          'height': 2,
          'light': 7,
        });
        expect(workspace.view.error, isNotEmpty);
        expect(await workspace.mapBackend.exportVerified(), previous);
        files.next = null;
        await workspace.dispatch('importMap');
        expect(workspace.view.map, same(map));
        await workspace.dispatch('closeMap');
        expect(workspace.view.mapRaster, isNull);
        expect(workspace.view.map, isNull);
        final originalEntry = vault.entries.values.singleWhere(
          (e) => e.name == 'original.map',
        );
        await workspace.dispatch('openFile', {'id': originalEntry.id});
        expect(workspace.view.error, isEmpty);
        expect(await workspace.mapBackend.exportVerified(), source);
        await workspace.close();
        expect(workspace.view.map, isNull);
        expect(workspace.view.mapRaster, isNull);
      },
    );
  }

  test(
    'WLD to MAP publishes only decoded matching output and retains the WLD',
    () async {
      final engine = MapEngine(),
          files = FakeFiles()
            ..next = PickedFile('world.wld', Uint8List.fromList([4, 5, 6, 7]));
      final workspace = Workspace(
        engine: engine,
        files: files,
        vault: MemoryVault(),
      );
      addTearDown(workspace.dispose);
      await workspace.dispatch('import', {'kind': 'world'});
      expect(workspace.view.error, isEmpty);
      final before = Uint8List.fromList(engine.handles.values.single);
      expect(workspace.view.canGenerateWorldMap, isTrue);
      await workspace.dispatch('generateMapFromWorld');
      expect(workspace.view.error, isEmpty);
      expect(workspace.view.map!.worldId, 17);
      expect(engine.handles.values.single, before);
      expect(engine.markers, isNull);
      expect(workspace.view.status, contains('全亮 MAP'));
      final old = workspace.view.map!;
      engine.corruptOutput = true;
      await workspace.dispatch('generateMapFromWorld');
      expect(workspace.view.error, isNotEmpty);
      expect(workspace.view.map, same(old));
      expect(engine.handles.values.single, before);
      await workspace.close();
    },
  );
}
