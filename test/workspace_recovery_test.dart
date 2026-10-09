import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  test('app recycle closes selected document, hides active record and restores verified version', () async {
    final directory = await Directory.systemTemp.createTemp(
      'terra-recycle-test',
    );
    try {
      final local = NativeLocalVault(directory: () async => directory),
          files = FakeFiles()
            ..next = PickedFile(
              'sample.wld',
              await File('assets/qa/synthetic-circuit.wld').readAsBytes(),
            );
      final app = Workspace(engine: FakeEngine(), files: files, vault: local);
      await app.initialize();
      await app.dispatch('import', {'kind': 'world'});
      expect(app.view.error, isEmpty);
      final id = app.view.files.single.id;
      await app.dispatch('trashFile', {'id': id});
      expect(app.view.error, isEmpty);
      expect(app.view.files, isEmpty);
      expect(app.view.world, isEmpty);
      final entries = await local.list();
      expect(entries.single.kind, 'trash:wld');
      await app.dispatch('restoreFile', {'id': entries.single.id});
      expect(app.view.error, isEmpty);
      expect(app.view.files.single.id, id);
      await app.dispatch('openFile', {'id': id});
      expect(app.view.error, isEmpty);
      expect(app.view.world, isNotEmpty);
      await app.close();
      app.dispose();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
