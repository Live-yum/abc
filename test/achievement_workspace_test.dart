import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/achievements.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'achievements_test.dart' show encrypt, fixture;
import 'resource_store_test.dart' show pack;
import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  test('catalog counters, known completion, creation and immutable local originals', () async {
    final folder = await Directory.systemTemp.createTemp('abc-achievements');
    addTearDown(() => folder.delete(recursive: true));
    final local = NativeLocalVault(directory: () async => folder),
        files = FakeFiles();
    final app = Workspace(engine: FakeEngine(), files: files, vault: local);
    await app.initialize();
    files.next = PickedFile(
      'synthetic.abcpack',
      pack({
        'catalog/achievements.json': utf8.encode(
          jsonEncode([
            {
              'id': 'SYNTHETIC',
              'name': 'Switch',
              'conditions': [
                {'id': 'switch', 'kind': 'boolean'},
              ],
            },
            {
              'id': 'COUNTER',
              'name': 'Count',
              'conditions': [
                {'id': 'count', 'kind': 'int', 'max': 10},
              ],
            },
            {
              'id': 'FLOAT',
              'name': 'Distance',
              'conditions': [
                {'id': 'distance', 'kind': 'float', 'max': 2.5},
              ],
            },
          ]),
        ),
      }),
    );
    await app.dispatch('import', {'kind': 'resources'});
    expect(app.view.error, isEmpty);
    final original = encrypt(fixture());
    files.next = PickedFile('achievements.dat', original);
    await app.dispatch('import', {'kind': 'achievements'});
    expect(app.view.error, isEmpty);
    final originalEntry = (await local.list())
        .where((e) => e.kind == 'achievements')
        .single;
    await app.dispatch('achievementCondition', {
      'id': 'COUNTER',
      'conditionId': 'count',
      'value': 5,
    });
    expect(app.view.error, isEmpty);
    await app.dispatch('export', {'kind': 'achievements'});
    final beforeFailure = files.bytes;
    expect(
      AchievementFile.open(files.bytes!).records[1].conditions.single.value,
      5,
    );
    await app.dispatch('achievementCondition', {
      'id': 'COUNTER',
      'conditionId': 'count',
      'value': 11,
    });
    expect(app.view.error, isNotEmpty);
    await app.dispatch('export', {'kind': 'achievements'});
    expect(files.bytes, beforeFailure);
    await app.dispatch('achievementCompleteKnown');
    expect(app.view.error, contains('确认'));
    await app.dispatch('achievementCompleteKnown', {'confirmed': true});
    expect(app.view.error, isEmpty);
    await app.dispatch('export', {'kind': 'achievements'});
    final completed = AchievementFile.open(files.bytes!).records;
    expect(completed.take(3).every((r) => r.completed), isTrue);
    expect(completed.last.id, 'UNKNOWN');
    expect(completed.last.completed, isFalse);
    final beforeNew = files.bytes;
    await app.dispatch('achievementNew');
    expect(app.view.error, contains('确认'));
    await app.dispatch('export', {'kind': 'achievements'});
    expect(files.bytes, beforeNew);
    await app.dispatch('achievementNew', {'confirmed': true});
    expect(app.view.error, isEmpty);
    await app.dispatch('export', {'kind': 'achievements'});
    final created = AchievementFile.open(files.bytes!).records;
    expect(created, hasLength(3));
    expect(created.every((r) => !r.completed), isTrue);
    expect(await local.read(originalEntry.id), original);
    await app.close();
    app.dispose();
  });

  test('uncatalogued existing boolean remains editable without guessed numeric maxima', () async {
    final files = FakeFiles()
      ..next = PickedFile('achievements.dat', encrypt(fixture()));
    final app = Workspace(engine: FakeEngine(), files: files);
    await app.dispatch('import', {'kind': 'achievements'});
    await app.dispatch('achievementCondition', {
      'id': 'SYNTHETIC',
      'conditionId': 'switch',
      'completed': true,
    });
    expect(app.view.error, isEmpty);
    await app.dispatch('achievementCondition', {
      'id': 'COUNTER',
      'conditionId': 'count',
      'value': 3,
    });
    expect(app.view.error, isNotEmpty);
    await app.dispatch('export', {'kind': 'achievements'});
    final records = AchievementFile.open(files.bytes!).records;
    expect(records.first.completed, isTrue);
    expect(records[1].conditions.single.value, 2);
    await app.close();
    app.dispose();
  });
}
