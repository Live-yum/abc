import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  final Uint8List source;
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('circuit.wld', source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = Uint8List.fromList(bytes);
    return true;
  }
}

void main() {
  test(
    'native world fragment list and extraction populate Fusion without changing saved world',
    () async {
      final engine = createTerraEngine();
      final source = await (engine as RegionBackend).regionOperation(
        await File('assets/qa/synthetic-circuit.wld').readAsBytes(),
        'batch_update_tiles',
        {
          'rules': [
            {
              'where': <String, Object?>{},
              'patch': {'is_active': false},
            },
          ],
        },
      );
      final files = _Files(source);
      final app = Workspace(
        engine: engine,
        files: files,
        worldCircuitBackend: engine as WorldCircuitBackend,
      );
      await app.dispatch('import', {'kind': 'world'});
      await app.dispatch('worldCircuitOpen');
      expect(app.view.error, isEmpty);
      await app.dispatch('worldCircuitFragments');
      expect(app.view.error, isEmpty);
      final state = app.view.result['worldCircuit'] as Map;
      final items = (state['fragments'] as Map)['items'] as List;
      expect(items, isNotEmpty);
      await app.dispatch('worldCircuitExtract', {
        'id': (items.first as Map)['id'],
      });
      expect(app.view.error, isEmpty);
      expect(app.view.region!.recordCount, greaterThan(0));
      expect((app.view.result['worldCircuit'] as Map)['dirty'], isFalse);
      expect(app.view.result['worldModified'], isFalse);
      await app.dispatch('worldCircuitClose');
      expect(app.view.error, isEmpty);
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, source);
      await app.close();
      app.dispose();
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires native engine'
        : false,
  );
  test(
    'unknown framed fragment rejects extraction without changing the world',
    () async {
      final source = await File('assets/qa/synthetic-circuit.wld')
          .readAsBytes();
      final files = _Files(source), engine = createTerraEngine();
      final app = Workspace(
        engine: engine,
        files: files,
        worldCircuitBackend: engine as WorldCircuitBackend,
      );
      await app.dispatch('import', {'kind': 'world'});
      await app.dispatch('worldCircuitOpen');
      await app.dispatch('worldCircuitFragments');
      expect(app.view.error, isEmpty);
      final rows =
          ((app.view.result['worldCircuit'] as Map)['fragments']
                  as Map)['items']
              as List;
      final unsupported = rows.cast<Map>().firstWhere(
        (r) => r['complete'] != true,
      );
      await app.dispatch('worldCircuitExtract', {'id': unsupported['id']});
      expect(app.view.error, contains('占格未完整核验'));
      expect(app.view.region, isNull);
      await app.dispatch('worldCircuitClose');
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, source);
      await app.close();
      app.dispose();
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires native engine'
        : false,
  );
}
