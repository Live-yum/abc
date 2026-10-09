import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/achievement_catalog.dart';
import 'package:terraforge/domain/achievements.dart';
import 'package:terraforge/domain/resource_catalog.dart';

import 'achievements_test.dart' as fixture;

ResourceCatalog resources(List<Map<String, Object?>> rows) => ResourceCatalog(
  gameVersion: 'synthetic',
  provenance: const {},
  families: {
    'achievements': rows.map((r) => CatalogEntry('achievements', r)).toList(),
  },
);
Map<String, Object?> row(String id, List<Map<String, Object?>> conditions) => {
  'id': id,
  'name': '名称 $id',
  'description': '描述',
  'category': 'Explorer',
  'conditions': conditions,
};
AchievementCatalog catalog() => AchievementCatalog.fromResourceCatalog(
  resources([
    row('SYNTHETIC', [
      {'id': 'switch', 'kind': 'boolean'},
    ]),
    row('COUNTER', [
      {'id': 'count', 'kind': 'int', 'max': 10},
    ]),
    row('FLOAT', [
      {'id': 'distance', 'kind': 'float', 'max': 2.5},
    ]),
  ]),
);
void main() {
  test(
    'creation uses catalog IDs, initially locked and valid BSON roundtrip',
    () {
      final file = catalog().createFile();
      expect(file.records.map((r) => r.id), ['SYNTHETIC', 'COUNTER', 'FLOAT']);
      expect(file.records.every((r) => !r.completed), true);
      expect(file.records[1].conditions.single.value, 0);
      expect(file.records[2].conditions.single.kind, 'float');
      expect(AchievementFile.open(file.exportBytes()).records.length, 3);
      expect(file.exportBytes().length % 16, 0);
    },
  );
  test('single edit clones preserves original and reset baseline', () {
    final file = catalog().createFile();
    final before = file.exportBytes();
    final candidate = catalog().applyCondition(
      file,
      'COUNTER',
      'count',
      value: 5,
    );
    expect(file.exportBytes(), before);
    expect(candidate.records[1].conditions.single.value, 5);
    final second = catalog().applyCondition(
      candidate,
      'FLOAT',
      'distance',
      completed: true,
    );
    expect(second.records[2].conditions.single.value, 2.5);
    second.reset();
    expect(second.exportBytes(), before);
  });
  test(
    'bulk exact intersection preserves all unknown BSON and reports counts',
    () {
      final original = fixture.encrypt(fixture.fixture());
      final file = AchievementFile.open(original);
      final result = catalog().completeKnown(file);
      expect(result.changed, 3);
      expect(result.skipped, 1);
      expect(file.exportBytes(), original);
      final expected = AchievementFile.open(original)
        ..setConditionCompleted('SYNTHETIC', 'switch', true)
        ..setProgress('COUNTER', 'count', 10, maximum: 10)
        ..setProgress('FLOAT', 'distance', 2.5, maximum: 2.5);
      expect(result.file.exportBytes(), expected.exportBytes());
      expect(catalog().completeKnown(result.file).changed, 0);
    },
  );
  test(
    'mixed conditions and unknown conditions remain supported atomically',
    () {
      final raw = fixture.encrypt(
        fixture.doc([
          fixture.record('MIXED', [
            fixture.condition('flag'),
            fixture.condition('count', type: 16, payload: fixture.i32(3)),
            fixture.condition('unknown'),
          ]),
        ]),
      );
      final definitions = AchievementCatalog.fromResourceCatalog(
        resources([
          row('MIXED', [
            {'id': 'flag', 'kind': 'boolean'},
            {'id': 'count', 'kind': 'int', 'max': 7},
          ]),
        ]),
      );
      final file = AchievementFile.open(raw);
      final result = definitions.completeKnown(file);
      expect(result.changed, 2);
      expect(result.skipped, 1);
      expect(result.file.records.single.conditions.last.completed, false);
      expect(result.file.records.single.conditions[1].value, 7);
      expect(file.exportBytes(), raw);
    },
  );
  test('missing, invalid maximum and kind mismatch are readonly', () {
    for (final max in [
      null,
      0,
      -1,
      1.5,
      2147483648,
      double.nan,
      double.infinity,
    ]) {
      final definitions = AchievementCatalog.fromResourceCatalog(
        resources([
          row('COUNTER', [
            {'id': 'count', 'kind': 'int', 'max': max},
          ]),
        ]),
      );
      final file = AchievementFile.open(fixture.encrypt(fixture.fixture()));
      expect(
        () => definitions.applyCondition(
          file,
          'COUNTER',
          'count',
          completed: true,
        ),
        throwsStateError,
      );
      expect(() => definitions.createFile(), throwsFormatException);
      expect(definitions.completeKnown(file).changed, 0);
      expect(file.dirty, false);
    }
    final mismatch = AchievementCatalog.fromResourceCatalog(
      resources([
        row('SYNTHETIC', [
          {'id': 'switch', 'kind': 'int', 'max': 10},
        ]),
      ]),
    );
    final file = AchievementFile.open(fixture.encrypt(fixture.fixture()));
    expect(
      () =>
          mismatch.applyCondition(file, 'SYNTHETIC', 'switch', completed: true),
      throwsStateError,
    );
  });
  test('out of range and nonfinite edits fail without changing original', () {
    final file = catalog().createFile();
    final bytes = file.exportBytes();
    for (final value in [-1, 11, 1.5, double.nan, double.infinity]) {
      expect(
        () => catalog().applyCondition(file, 'COUNTER', 'count', value: value),
        throwsArgumentError,
      );
      expect(file.exportBytes(), bytes);
    }
    expect(
      () => catalog().applyCondition(file, 'FLOAT', 'distance', value: 3),
      throwsArgumentError,
    );
    expect(
      () => catalog().applyCondition(
        file,
        'COUNTER',
        'count',
        value: 2,
        completed: true,
      ),
      throwsArgumentError,
    );
    expect(
      () => catalog().applyCondition(file, 'COUNTER', 'count'),
      throwsArgumentError,
    );
  });
  test('empty, duplicate, malformed and oversized catalogs cannot create', () {
    expect(
      () => AchievementCatalog.fromResourceCatalog(resources([])).createFile(),
      throwsFormatException,
    );
    for (final entries in [
      [row('X', [])],
      [
        row('X', [
          {'id': 'x', 'kind': 'boolean'},
          {'id': 'x', 'kind': 'boolean'},
        ]),
      ],
      [
        row('X', [
          {'id': 'x', 'kind': 'boolean'},
        ]),
        row('X', [
          {'id': 'y', 'kind': 'boolean'},
        ]),
      ],
      [
        row('bad\u0000', [
          {'id': 'x', 'kind': 'boolean'},
        ]),
      ],
      [
        row('x' * 4097, [
          {'id': 'x', 'kind': 'boolean'},
        ]),
      ],
    ]) {
      expect(
        () => AchievementCatalog.fromResourceCatalog(resources(entries)),
        throwsFormatException,
      );
    }
    final big = AchievementCatalog.fromResourceCatalog(
      resources([
        for (var i = 0; i < 600; i++)
          row('id$i${'x' * 4000}', [
            {'id': 'x', 'kind': 'boolean'},
          ]),
      ]),
    );
    expect(() => big.createFile(), throwsFormatException);
    expect(
      () => AchievementFile.blank({
        'X': {'bad': 'unknown'},
      }),
      throwsFormatException,
    );
  });
  test(
    'float maximum is bounded; opaque ciphertext is retained when skipped',
    () {
      final definitions = AchievementCatalog.fromResourceCatalog(
        resources([
          row('FLOAT', [
            {'id': 'distance', 'kind': 'float', 'max': 1e39},
          ]),
        ]),
      );
      final bytes = fixture.encrypt(fixture.fixture());
      final result = definitions.completeKnown(AchievementFile.open(bytes));
      expect(result.file.exportBytes(), bytes);
      expect(result.skipped, 4);
      expect(result.changed, 0);
      expect(result.file.exportBytes(), isA<Uint8List>());
    },
  );
}
