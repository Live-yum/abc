import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/world_rule_presets.dart';
import 'package:terraforge/platform/files.dart';

import 'workspace_test.dart' show FakeEngine;

class _Files implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) async => PickedFile(
    'resources.abcpack',
    await File(Platform.environment['ABC_PRIVATE_PACK']!).readAsBytes(),
  );
  @override
  Future<bool> save(String name, Uint8List bytes) async => true;
}

void main() {
  test(
    'verified original presets clone into independent editable named schemes',
    () async {
      final app = Workspace(engine: FakeEngine(), files: _Files());
      await app.dispatch('import', {'kind': 'resources'});
      expect(app.view.error, isEmpty);
      final presets = WorldRulePresets.fromCatalog(
        app.view.resources!.catalog,
        expectedVersion: '1.4.5.8',
      );
      expect(presets.presets, isNotEmpty);
      final source = presets.presets.first;
      final originalRules = source.editableCopy().encode();
      for (var i = 0; i < 2; i++) {
        await app.dispatch('worldPresetClone', {'id': source.id});
        expect(app.view.error, isEmpty);
        expect(app.view.worldRuleScheme!.biomeMode, isNull);
        expect(app.view.worldRuleScheme!.rules.length, source.rules.length);
      }
      expect(app.view.worldRuleSchemes!.schemes.length, 3);
      expect(
        app.view.worldRuleSchemes!.schemes.map((s) => s.name).toSet().length,
        3,
      );
      await app.dispatch('worldRulesSave', {
        'scheme': app.view.worldRuleScheme!
            .copyWith(rules: [source.rules.first])
            .toJson(),
      });
      expect(app.view.error, isEmpty);
      expect(app.view.worldRuleScheme!.rules.length, 1);
      expect(source.editableCopy().encode(), originalRules);
      await app.dispatch('worldPresetClone', {'id': 'missing'});
      expect(app.view.error, isNotEmpty);
      expect(app.view.worldRuleScheme!.rules.length, 1);
      await app.close();
      app.dispose();
    },
    skip: Platform.environment['ABC_PRIVATE_PACK'] == null
        ? 'Requires private local pack with original presets'
        : false,
  );
}
