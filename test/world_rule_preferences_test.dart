import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/world_rules.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  test('latest A-B-A whole-world scheme survives startup without overwriting old versions', () async {
    final dir = await Directory.systemTemp.createTemp('abc-world-rules');
    addTearDown(() => dir.delete(recursive: true));
    final vault = NativeLocalVault(directory: () async => dir);
    final app = Workspace(
      engine: FakeEngine(),
      files: FakeFiles(),
      vault: vault,
    );
    await app.initialize();
    final a = WorldRuleScheme(name: 'A', biomeMode: 'purify'),
        b = WorldRuleScheme(name: 'B', biomeMode: 'corruption');
    for (final scheme in [a, b, a]) {
      await app.dispatch('worldRulesSave', {'scheme': scheme.toJson()});
      expect(app.view.error, isEmpty);
    }
    expect(app.view.files.any((e) => e.kind.contains('preferences')), isFalse);
    await app.close();
    app.dispose();
    final restored = Workspace(
      engine: FakeEngine(),
      files: FakeFiles(),
      vault: vault,
    );
    await restored.initialize();
    expect(restored.view.error, isEmpty);
    expect(restored.view.worldRuleScheme!.fingerprint, a.fingerprint);
    await restored.close();
    restored.dispose();
  });
}
