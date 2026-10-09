import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/vault_native.dart';

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
  final enabled = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] != null;
  test('actual application copies complete objects and preserves originals through failed structural edit', () async {
    final original = await File('assets/qa/synthetic-objects.wld')
        .readAsBytes();
    final files = _Files()..input = PickedFile('objects.wld', original),
        engine = createTerraEngine();
    final directory = await Directory.systemTemp.createTemp(
      'terra-region-vault',
    );
    addTearDown(() => directory.delete(recursive: true));
    final vault = NativeLocalVault(directory: () async => directory);
    final app = Workspace(
      engine: engine,
      files: files,
      vault: vault,
      regionBackend: engine as RegionBackend,
    );
    await app.dispatch('import', {'kind': 'world'});
    expect(app.view.error, isEmpty);
    await app.dispatch('fusionRegion', {
      'x': 1,
      'y': 2,
      'width': 8,
      'height': 3,
    });
    expect(app.view.error, isEmpty);
    expect(app.view.region!.objectCount, 3);
    final originalChestCount = (app.view.world['chests'] as List).length;
    await app.dispatch('write', {
      'source': 'fusion',
      'x': 1,
      'y': 10,
      'mode': 'overlay',
    });
    expect(app.view.error, isEmpty);
    expect((app.view.world['chests'] as List).length, originalChestCount + 1);
    expect(files.output, isNotEmpty);
    await app.dispatch('regionSelect', {'x': 0, 'y': 0});
    await app.dispatch('regionEdit', {
      'patch': {'active': 0},
    });
    expect(app.view.error, isEmpty);
    await app.dispatch('write', {
      'source': 'fusion',
      'x': 1,
      'y': 2,
      'mode': 'replace',
      'overwrite': true,
    });
    expect(app.view.error, isNotEmpty);
    expect((app.view.world['chests'] as List).length, originalChestCount + 1);
    expect(app.view.result['worldCanUndo'], isTrue);
    await app.dispatch('undo', {'canvas': 'world'});
    expect(app.view.error, isEmpty);
    expect(app.view.result['worldCanUndo'], isFalse);
    expect(app.view.result['worldModified'], isFalse);
    expect(app.view.status, contains('已撤销'));
    expect(await vault.read(app.view.files.first.id), original);
    await app.dispatch('export', {'kind': 'world'});
    expect(files.output, original);
    expect(
      await File('assets/qa/synthetic-objects.wld').readAsBytes(),
      original,
    );
    await app.close();
    app.dispose();
  }, skip: !enabled ? 'Requires compiled native engine' : false);
  test('actual indexed pixel transaction preserves wall and Dirt0 with explicit overwrite', () async {
    final bytes = await File('assets/qa/synthetic-circuit.wld').readAsBytes();
    final files = _Files()..input = PickedFile('pixel.wld', bytes),
        engine = createTerraEngine();
    final app = Workspace(
      engine: engine,
      files: files,
      regionBackend: engine as RegionBackend,
    );
    await app.dispatch('import', {'kind': 'world'});
    expect(app.view.error, isEmpty);
    await app.dispatch('resize', {'canvas': 'pixel', 'width': 1, 'height': 1});
    await app.dispatch('paint', {
      'canvas': 'pixel',
      'x': 0,
      'y': 0,
      'color': 0xff123456,
      'tool': 'brush',
    });
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'color', 'source': '#123456', 'target': 0},
      ],
    });
    await app.dispatch('write', {
      'source': 'pixel',
      'x': 3,
      'y': 18,
      'overwrite': true,
    });
    expect(app.view.error, isEmpty);
    expect(files.output, isNotEmpty);
    await app.close();
    final records = await (engine as RegionBackend).readRegion(
      files.output!,
      3,
      18,
      1,
      1,
    );
    final data = ByteData.sublistView(records),
        word = data.getUint32(8, Endian.little);
    expect(word & 65535, 0);
    expect((word >> 16) & 1, 1);
    app.dispose();
  }, skip: !enabled ? 'Requires compiled native engine' : false);
}
