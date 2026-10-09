import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  final Uint8List source;
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('terrain.wld', source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  final enabled = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] != null;
  test('environment rules preview, confirm, real world write and two independent undo histories', () async {
    final original = await File('assets/qa/synthetic-circuit.wld')
        .readAsBytes();
    final engine = createTerraEngine(), files = _Files(original);
    final app = Workspace(
      engine: engine,
      files: files,
      regionBackend: engine as RegionBackend,
    );
    await app.dispatch('import', {'kind': 'world'});
    await app.dispatch('fusionRegion', {
      'x': 1,
      'y': 1,
      'width': 2,
      'height': 2,
    });
    expect(app.view.error, isEmpty);
    final before = app.view.region!.records;
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'terrain', 'layer': 'block', 'source': '1', 'target': 0},
        {'type': 'terrain', 'layer': 'wall', 'source': '0', 'target': 3},
      ],
    });
    await app.dispatch('terrainPreview');
    expect(app.view.error, isEmpty);
    expect((app.view.result['terrainPlan'] as Map)['changedCells'], 4);
    expect(app.view.region!.records, before);
    await app.dispatch('terrainApply');
    expect(app.view.error, contains('确认'));
    expect(app.view.region!.records, before);
    await app.dispatch('terrainApply', {'confirmed': true});
    expect(app.view.error, isEmpty);
    final converted = app.view.region!.records;
    expect(converted, isNot(before));
    expect(app.view.region!.cellAt(0, 0)!['block'], 0);
    expect(app.view.region!.cellAt(0, 0)!['active'], 1);
    expect(app.view.region!.cellAt(0, 0)!['wall'], 3);
    await app.dispatch('undo', {'canvas': 'fusion'});
    expect(app.view.region!.records, before);
    await app.dispatch('redo', {'canvas': 'fusion'});
    expect(app.view.region!.records, converted);
    await app.dispatch('export', {'kind': 'world'});
    expect(
      files.output,
      original,
      reason: 'Canvas confirmation cannot alter WLD',
    );
    await app.dispatch('write', {
      'source': 'fusion',
      'x': 1,
      'y': 1,
      'mode': 'replace',
      'overwrite': true,
    });
    expect(app.view.error, isEmpty);
    expect(files.output, isNot(original));
    await app.dispatch('fusionRegion', {
      'x': 1,
      'y': 1,
      'width': 2,
      'height': 2,
    });
    expect(app.view.region!.cellAt(0, 0)!['block'], 0);
    expect(app.view.region!.cellAt(0, 0)!['wall'], 3);
    await app.dispatch('undo', {'canvas': 'world'});
    await app.dispatch('export', {'kind': 'world'});
    expect(files.output, original);
    await app.close();
    app.dispose();
  }, skip: enabled ? false : 'Requires compiled native engine');

  test('changed region and changed rules invalidate preview; invalid save is atomic', () async {
    final original = await File('assets/qa/synthetic-circuit.wld')
        .readAsBytes();
    final engine = createTerraEngine(), files = _Files(original);
    final app = Workspace(
      engine: engine,
      files: files,
      regionBackend: engine as RegionBackend,
    );
    await app.dispatch('import', {'kind': 'world'});
    await app.dispatch('fusionRegion', {
      'x': 1,
      'y': 1,
      'width': 1,
      'height': 1,
    });
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'terrain', 'source': '1', 'target': 0},
      ],
    });
    await app.dispatch('terrainPreview');
    await app.dispatch('regionEdit', {
      'patch': {'wall': 2},
    });
    expect((app.view.result['terrainPlan'] as Map)['stale'], isTrue);
    await app.dispatch('terrainApply', {'confirmed': true});
    expect(app.view.error, contains('重新预览'));
    expect(app.view.region!.cellAt(0, 0)!['block'], 1);
    await app.dispatch('terrainPreview');
    final rules = List.of(app.view.mapping);
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'terrain', 'source': 'no', 'target': 0},
      ],
    });
    expect(app.view.error, isNotEmpty);
    expect(app.view.mapping, rules);
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'terrain', 'source': '1', 'target': 2},
      ],
    });
    expect(app.view.result['terrainPlan'], isNull);
    await app.dispatch('terrainApply', {'confirmed': true});
    expect(app.view.error, contains('重新预览'));
    await app.close();
    app.dispose();
  }, skip: enabled ? false : 'Requires compiled native engine');
}
