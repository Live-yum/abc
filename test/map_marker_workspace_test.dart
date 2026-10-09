import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  test(
    'A-B-A marker preference restores latest choice and hides internal pointer',
    () async {
      final directory = await Directory.systemTemp.createTemp('abc-markers');
      addTearDown(() => directory.delete(recursive: true));
      final local = NativeLocalVault(directory: () async => directory);
      final app = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        vault: local,
      );
      await app.initialize();
      await app.dispatch('markerToggle', {'kind': 'item', 'id': 8});
      await app.dispatch('markerToggle', {'kind': 'tile', 'id': 21});
      await app.dispatch('markerToggle', {'kind': 'tile', 'id': 21});
      expect(app.view.error, isEmpty);
      expect(app.view.markerProfile!.length, 1);
      expect(
        app.view.files.any((e) => e.kind.contains('preferences')),
        isFalse,
      );
      await app.dispatch('markerClear');
      expect(app.view.error, contains('确认'));
      expect(app.view.markerProfile!.length, 1);
      await app.close();
      app.dispose();
      final restored = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        vault: local,
      );
      await restored.initialize();
      expect(restored.view.error, isEmpty);
      expect(restored.view.markerProfile!.markers.single.id, 8);
      await restored.dispatch('markerStyle', {
        'kind': 'item',
        'id': 8,
        'color': '#00FFAA',
        'radius': 4,
        'lineWidth': 2,
      });
      expect(restored.view.error, isEmpty);
      expect(restored.view.markerProfile!.markers.single.color, '#00FFAA');
      await restored.dispatch('markerClear', {'confirmed': true});
      expect(restored.view.markerProfile!.isEmpty, isTrue);
      await restored.close();
      restored.dispose();
    },
  );
}
