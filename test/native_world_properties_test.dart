import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  final Uint8List source;
  Uint8List? output;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('properties.wld', source);
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  test(
    'real world progression/time/weather edits persist; unsupported normalized field is rejected',
    () async {
      final original = await File('assets/qa/synthetic-circuit.wld')
          .readAsBytes();
      final files = _Files(original);
      final workspace = Workspace(engine: createTerraEngine(), files: files);
      await workspace.dispatch('import', {'kind': 'world'});
      for (final entry in <String, Object>{
        'downedEyeOfCthulhu': true,
        'bloodMoon': true,
        'time': 123.5,
        'maxRain': 0.5,
      }.entries) {
        await workspace.dispatch('stageWorld', {
          'field': entry.key,
          'value': entry.value,
        });
        expect(workspace.view.error, isEmpty, reason: entry.key);
        expect(workspace.view.world[entry.key], entry.value);
      }
      await workspace.dispatch('export', {'kind': 'world'});
      final changed = files.output;
      expect(changed, isNot(original));
      await workspace.dispatch('stageWorld', {
        'field': 'unlockedPrincessSpawn',
        'value': true,
      });
      expect(
        workspace.view.error,
        isNotEmpty,
        reason: 'Normalized future field is not writable in v139',
      );
      await workspace.dispatch('export', {'kind': 'world'});
      expect(files.output, changed);
      for (var i = 0; i < 4; i++) {
        await workspace.dispatch('undo', {'canvas': 'world'});
      }
      await workspace.dispatch('export', {'kind': 'world'});
      expect(files.output, original);
      await workspace.close();
      workspace.dispose();
    },
    skip: Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires native engine'
        : false,
  );
}
