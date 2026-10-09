import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/world_rule_presets.dart';
import 'package:terraforge/platform/resource_store.dart';

void main() {
  final packPath = Platform.environment['ABC_PRIVATE_PACK'];
  test(
    'private source presets all survive pack import and editable copy',
    () async {
      final store = ResourceStore.importPack(
        await File(packPath!).readAsBytes(),
      );
      final catalog = WorldRulePresets.fromCatalog(
        store.catalog,
        expectedVersion: store.catalog.gameVersion,
      );
      expect(catalog.presets, isNotEmpty);
      for (final preset in catalog.presets) {
        final copy = preset.editableCopy();
        copy.validate(requireRules: true);
        expect(copy.isBuiltin, isFalse, reason: preset.id);
        expect(copy.rules.length, inInclusiveRange(1, 128), reason: preset.id);
        expect(
          copy.toEngineRequest()['rules'],
          preset.rules.map((rule) => rule.toJson()).toList(),
          reason: preset.id,
        );
      }
    },
    skip: packPath == null
        ? 'Set ABC_PRIVATE_PACK to a locally built pack with world-rule-presets.'
        : false,
  );
}
