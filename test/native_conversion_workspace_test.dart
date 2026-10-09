import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/player_conversion.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/player_projection_backend.dart';
import 'package:terraforge/engine/player_schema.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  PickedFile? next;
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => next;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = Uint8List.fromList(bytes);
    return true;
  }
}

void main() {
  final pack = Platform.environment['ABC_PRIVATE_PACK'];
  test(
    'profile-backed conversion requires current source and explicit confirmation; undo is exact',
    () async {
      final engine = createTerraEngine(),
          projection = engine as PlayerProjectionBackend;
      final legacy = await projection.projectPlayer(
        PlayerConversion.prepare(
          blankPlayer('Synthetic legacy'),
          279,
        ).candidate,
      );
      final files = _Files()..next = PickedFile('legacy.plr', legacy),
          app = Workspace(
            engine: engine,
            files: files,
            playerProjectionBackend: projection,
          );
      await app.dispatch('import', {'kind': 'player'});
      expect(app.view.error, isEmpty);
      expect(app.view.player['version'], 279);
      files.next = PickedFile(
        'resources.abcpack',
        await File(pack!).readAsBytes(),
      );
      await app.dispatch('import', {'kind': 'resources'});
      expect(app.view.error, isEmpty);
      await app.dispatch('preparePlayerConversion', {'target': 326});
      expect(app.view.error, isEmpty);
      expect((app.view.result['conversion'] as Map)['blocked'], false);
      await app.dispatch('applyPlayerConversion', {'confirmed': false});
      expect(app.view.error, isNotEmpty);
      expect(app.view.player['version'], 279);
      await app.dispatch('stagePlayer', {'field': 'name', 'value': 'Changed'});
      expect(app.view.error, isEmpty);
      await app.dispatch('applyPlayerConversion', {'confirmed': true});
      expect(app.view.error, contains('已变化'));
      expect(app.view.player['version'], 279);
      await app.dispatch('preparePlayerConversion', {'target': 326});
      await app.dispatch('applyPlayerConversion', {'confirmed': true});
      expect(app.view.error, isEmpty);
      expect(app.view.player['version'], 326);
      await app.dispatch('undo', {'canvas': 'player'});
      expect(app.view.player['version'], 279);
      await app.dispatch('undo', {'canvas': 'player'});
      await app.dispatch('export', {'kind': 'player'});
      expect(files.output, legacy);
      await app.close();
      app.dispose();
    },
    skip:
        pack == null ||
            Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Requires private profile pack and native engine'
        : false,
  );
}
