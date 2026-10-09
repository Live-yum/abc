import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  Uint8List source;
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('overlay.wld', source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  test(
    'real native world viewport reads wire/lava bytes without changing the save',
    () async {
      final source = await File('assets/qa/synthetic-circuit.wld')
          .readAsBytes();
      final engine = createTerraEngine(), backend = engine as RegionBackend;
      final records = await backend.readRegion(source, 1, 1, 1, 1);
      ByteData.sublistView(records)
          .setUint32(20, 200 | (2 << 8) | (7 << 24), Endian.little);
      final candidate = await backend.replaceRegion(
        source,
        1,
        1,
        1,
        1,
        records,
      );
      final files = _Files(candidate);
      final workspace = Workspace(
        engine: engine,
        files: files,
        regionBackend: backend,
      );
      await workspace.dispatch('import', {'kind': 'world'});
      await workspace.dispatch('worldOverlay', {
        'x': 1,
        'y': 1,
        'width': 1,
        'height': 1,
      });
      expect(workspace.view.error, isEmpty);
      final overlay = workspace.view.worldOverlay!;
      expect(overlay.wireMasks.single, 7);
      expect(overlay.liquidAmounts.single, 200);
      expect(overlay.liquidKinds.single, 2);
      expect(workspace.view.result['worldModified'], isFalse);
      await workspace.dispatch('export', {'kind': 'world'});
      expect(files.output, candidate);
      await workspace.dispatch('stageWorld', {
        'field': 'name',
        'value': 'Overlay edit',
      });
      expect(workspace.view.error, isEmpty);
      expect(workspace.view.worldOverlay, isNull);
      await workspace.close();
      workspace.dispose();
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires compiled native engine'
        : false,
  );
}
