import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/world_rules.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  final Uint8List source;
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('rules.wld', source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  final enabled = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] != null;
  test('actual whole-world conditional limit preview, stale protection, apply and byte-exact undo', () async {
    final original = await File('assets/qa/synthetic-circuit.wld')
        .readAsBytes();
    final engine = createTerraEngine(), files = _Files(original);
    final app = Workspace(
      engine: engine,
      files: files,
      regionBackend: engine as RegionBackend,
    );
    final scheme = WorldRuleScheme(
      name: 'One stone',
      rules: [
        WorldTileRule(
          where: {'type': 1, 'wire_red': false},
          patch: {'wall': 2, 'wire_red': true},
          limit: 1,
        ),
      ],
    );
    await app.dispatch('import', {'kind': 'world'});
    await app.dispatch('worldRulesPreview', {'scheme': scheme.toJson()});
    expect(app.view.error, isEmpty);
    expect(app.view.result['worldRulesPreview'], isNotNull);
    expect(app.view.worldRulePreviewPng, isNotNull);
    await app.dispatch('export', {'kind': 'world'});
    expect(files.output, original, reason: 'Preview must not commit');
    await app.dispatch('worldRulesApply', {'scheme': scheme.toJson()});
    expect(app.view.error, contains('确认'));
    await app.dispatch('stageWorld', {
      'field': 'name',
      'value': 'Changed after preview',
    });
    expect(app.view.error, isEmpty);
    expect((app.view.result['worldRulesPreview'] as Map)['stale'], isTrue);
    await app.dispatch('worldRulesApply', {
      'scheme': scheme.toJson(),
      'confirmed': true,
    });
    expect(app.view.error, contains('重新'));
    await app.dispatch('undo', {'canvas': 'world'});
    await app.dispatch('worldRulesApply', {
      'scheme': scheme.toJson(),
      'confirmed': true,
    });
    expect(app.view.error, isEmpty);
    expect(app.view.result['worldRulesPreview'], isNull);
    await app.dispatch('fusionRegion', {
      'x': 0,
      'y': 0,
      'width': 7,
      'height': 32,
    });
    expect(app.view.error, isEmpty);
    expect(app.view.region!.cellAt(0, 0)!['wall'], 2);
    expect(app.view.region!.cellAt(0, 0)!['wires'], 1);
    expect(
      [
        for (var i = 0; i < app.view.region!.recordCount; i++)
          app.view.region!.cellAtIndex(i),
      ].where((c) => c['wall'] == 2),
      hasLength(1),
    );
    await app.dispatch('undo', {'canvas': 'world'});
    await app.dispatch('export', {'kind': 'world'});
    expect(files.output, original);
    await app.close();
    app.dispose();
  }, skip: enabled ? false : 'Requires native engine');

  test('all four core-generated biome presets create independently readable candidates', () async {
    final source = await File('assets/qa/synthetic-circuit.wld').readAsBytes();
    final engine = createTerraEngine(), files = _Files(source);
    final app = Workspace(
      engine: engine,
      files: files,
      regionBackend: engine as RegionBackend,
    );
    await app.dispatch('import', {'kind': 'world'});
    for (final mode in WorldRuleScheme.builtinModes) {
      final scheme = WorldRuleScheme(name: mode, biomeMode: mode);
      await app.dispatch('worldRulesPreview', {'scheme': scheme.toJson()});
      expect(app.view.error, isEmpty, reason: mode);
      expect(
        (app.view.result['worldRulesPreview'] as Map)['fingerprint'],
        scheme.fingerprint,
      );
    }
    await app.dispatch('export', {'kind': 'world'});
    expect(files.output, source);
    await app.close();
    app.dispose();
  }, skip: enabled ? false : 'Requires native engine');
}
