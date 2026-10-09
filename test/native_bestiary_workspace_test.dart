import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/bestiary_tools.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  PickedFile? next;
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => next;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = bytes;
    return true;
  }
}

void main() {
  test(
    'real bestiary edit and known bulk preserve unknown records and positive counts',
    () async {
      final files = _Files()
        ..next = PickedFile(
          'resources.abcpack',
          await File(Platform.environment['ABC_PRIVATE_PACK']!).readAsBytes(),
        );
      final app = Workspace(engine: createTerraEngine(), files: files);
      await app.dispatch('import', {'kind': 'resources'});
      expect(app.view.error, isEmpty);
      final original = await File(Platform.environment['ABC_PRIVATE_WORLD326']!)
          .readAsBytes();
      files.next = PickedFile('world.wld', original);
      await app.dispatch('import', {'kind': 'world'});
      expect(app.view.error, isEmpty);
      Map<String, Object?> current() =>
          Map<String, Object?>.from(app.view.world['bestiary'] as Map);
      final raw = current();
      final chats = raw['chats'];
      await app.dispatch('stageBestiary', {
        'patch': {
          'kills': [
            ...raw['kills'] as List,
            {'persistentNpcId': 'abc-unmapped', 'killCount': 7},
          ],
        },
      });
      expect(
        app.view.error,
        isEmpty,
        reason: 'Partial advanced patch must retain all three core sections',
      );
      expect(current()['chats'], chats);
      final known = BestiaryTools.entries(
        current(),
        app.view.resources!.catalog,
      ).firstWhere((e) => e.kind == 'kills' && e.editable);
      final count = known.killCount == 17 ? 19 : 17;
      await app.dispatch('bestiaryEntry', {
        'id': known.id,
        'kind': 'kills',
        'value': count,
      });
      expect(app.view.error, isEmpty);
      await app.dispatch('bestiaryUnlockKnown');
      expect(app.view.error, contains('确认'));
      await app.dispatch('bestiaryUnlockKnown', {'confirmed': true});
      expect(app.view.error, isEmpty);
      final kills = (current()['kills'] as List).cast<Map>();
      expect(
        kills.firstWhere((e) => e['persistentNpcId'] == known.id)['killCount'],
        count,
      );
      expect(
        kills.firstWhere(
          (e) => e['persistentNpcId'] == 'abc-unmapped',
        )['killCount'],
        7,
      );
      for (var i = 0; i < 3; i++) {
        await app.dispatch('undo', {'canvas': 'world'});
      }
      await app.dispatch('export', {'kind': 'world'});
      expect(files.output, original);
      await app.close();
      app.dispose();
    },
    skip:
        Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null ||
            Platform.environment['ABC_PRIVATE_PACK'] == null ||
            Platform.environment['ABC_PRIVATE_WORLD326'] == null
        ? 'Requires native engine and external verified fixture/catalog'
        : false,
  );
}
