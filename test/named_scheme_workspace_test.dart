import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  test('named mappings preserve edits, clone identity, default and deletion confirmation across restart', () async {
    final dir = await Directory.systemTemp.createTemp('abc-scheme-library');
    addTearDown(() => dir.delete(recursive: true));
    final vault = NativeLocalVault(directory: () async => dir);
    Workspace make() =>
        Workspace(engine: FakeEngine(), files: FakeFiles(), vault: vault);
    final app = make();
    await app.initialize();
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'color', 'source': '#123456', 'target': 1},
      ],
    });
    expect(app.view.error, isEmpty);
    final original = app.view.mappingSchemes!.selectedId!;
    await app.dispatch('schemeClone', {
      'kind': 'mapping',
      'id': original,
      'name': '副本',
    });
    expect(app.view.error, isEmpty);
    final copy = app.view.mappingSchemes!.selectedId!;
    expect(copy, isNot(original));
    await app.dispatch('mappingSave', {
      'rules': [
        {'type': 'color', 'source': '#ABCDEF', 'target': 2},
      ],
    });
    await app.dispatch('schemeSetDefault', {'kind': 'mapping', 'id': original});
    await app.dispatch('schemeDelete', {'kind': 'mapping', 'id': copy});
    expect(app.view.error, isNotEmpty);
    expect(app.view.mappingSchemes!.schemes.length, 2);
    await app.close();
    app.dispose();
    final restored = make();
    await restored.initialize();
    expect(restored.view.error, isEmpty);
    expect(restored.view.mappingSchemes!.selectedId, original);
    expect(restored.view.mapping.single['target'], 1);
    await restored.dispatch('schemeSelect', {'kind': 'mapping', 'id': copy});
    expect(restored.view.mapping.single['target'], 2);
    await restored.dispatch('schemeRename', {
      'kind': 'mapping',
      'id': copy,
      'name': '新名称',
    });
    expect(restored.view.mappingSchemes!.selected!.name, '新名称');
    await restored.dispatch('schemeDelete', {
      'kind': 'mapping',
      'id': copy,
      'confirmed': true,
    });
    expect(restored.view.error, isEmpty);
    expect(restored.view.mappingSchemes!.schemes.length, 1);
    expect(
      restored.view.files.where((e) => e.kind.contains('preferences')),
      isEmpty,
    );
    await restored.close();
    restored.dispose();
  });
}
