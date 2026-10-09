import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/player_conversion.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/engine/player_schema.dart';

void main() {
  ResourceCatalog syntheticProfile({String version = '1.4.5.8'}) =>
      ResourceCatalog(
        gameVersion: version,
        provenance: {},
        families: {
          'player-conversion-profiles': [
            CatalogEntry('player-conversion-profiles', {
              'id': 326,
              'schema': 1,
              'gameVersion': '1.4.5.8',
              'sourceCommit': '0000000000000000000000000000000000000000',
              'sourceFiles': ['Synthetic test contract, not actual game data'],
              'ranges': {
                'hair': {
                  'minimum': 0,
                  'maximum': 7,
                  'fallback': 0,
                  'behavior': 'resetAbove',
                },
                'skinVariant': {
                  'minimum': 0,
                  'maximum': 2,
                  'fallback': 0,
                  'behavior': 'clamp',
                },
                'voiceVariant': {
                  'minimum': 1,
                  'maximum': 3,
                  'fallback': 1,
                  'behavior': 'clamp',
                },
              },
            }),
          ],
        },
      );

  test('sourced style normalization becomes explicit reviewable loss', () {
    final source = blankPlayer('Synthetic')
      ..['version'] = 279
      ..['hair'] = 9
      ..['skinVariant'] = 4
      ..['voiceVariant'] = 0;
    final catalog = syntheticProfile();
    final plan = PlayerConversion.prepare(source, 326, catalog: catalog);
    expect(plan.candidate['hair'], 0);
    expect(plan.candidate['skinVariant'], 2);
    expect(plan.candidate['voiceVariant'], 1);
    expect(source['hair'], 9);
    final preview = plan.reviewProjection(plan.candidate, catalog: catalog);
    expect(preview.blockers, isEmpty);
    expect(
      preview.changes.map((c) => c.path),
      containsAll(['/hair', '/skinVariant', '/voiceVariant']),
    );
    expect(preview.requiresLossConfirmation, isTrue);
  });

  test(
    'negative hairstyle is blocked, mismatched profiles never normalize',
    () {
      final source = blankPlayer('Synthetic')
        ..['version'] = 279
        ..['hair'] = -1;
      final catalog = syntheticProfile();
      final plan = PlayerConversion.prepare(source, 326, catalog: catalog);
      expect(plan.candidate['hair'], -1);
      expect(
        plan
            .reviewProjection(plan.candidate, catalog: catalog)
            .gameplayCompatibilityBlocked,
        isTrue,
      );
      final mismatched = syntheticProfile(version: 'old');
      source['hair'] = 99999;
      final unchanged = PlayerConversion.prepare(
        source,
        326,
        catalog: mismatched,
      );
      expect(unchanged.candidate['hair'], 99999);
      expect(
        unchanged
            .reviewProjection(unchanged.candidate, catalog: mismatched)
            .gameplayCompatibilityBlocked,
        isTrue,
      );
    },
  );
  test('target planning preserves source and unknown data immutably', () {
    final source = blankPlayer('Synthetic')
      ..['difficulty'] = 3
      ..['custom'] = {
        'nested': [1, '9007199254740993'],
      };
    final plan = PlayerConversion.prepare(source, 135);
    expect(source['version'], 326);
    expect(source['difficulty'], 3);
    expect(plan.candidate['difficulty'], 0);
    expect(plan.candidate['custom'], source['custom']);
    ((source['custom'] as Map)['nested'] as List).clear();
    expect((plan.source['custom'] as Map)['nested'], [1, '9007199254740993']);
    expect(() => plan.candidate['version'] = 326, throwsUnsupportedError);
    expect(
      () => (plan.candidate['inventory'] as List).clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'audited tail boundaries prepare codec model, not guessed slot losses',
    () {
      for (final (version, count, death) in [
        (38, 0, false),
        (135, 0, false),
        (164, 8, false),
        (167, 10, false),
        (197, 11, false),
        (200, 11, true),
        (218, 11, true),
        (230, 12, true),
        (279, 12, true),
      ]) {
        final next = PlayerConversion.prepare(
          blankPlayer('Synthetic'),
          version,
        ).candidate;
        expect((next['tailLayout'] as Map)['builderAccStatusCount'], count);
        expect((next['tailLayout'] as Map)['includesDeathMetadata'], death);
        expect(
          (next['builderAccStatus'] as List).length,
          count == 0 ? 12 : count,
        );
        expect((next['inventory'] as List).length, 58);
      }
    },
  );

  test('old-name, future, invalid targets are rejected', () {
    for (final version in [0, 1, 37, 327, 2147483647]) {
      expect(
        () => PlayerConversion.prepare(blankPlayer('Synthetic'), version),
        throwsFormatException,
      );
      expect(
        () => PlayerConversion.prepare(
          blankPlayer('Synthetic')..['version'] = version,
          326,
        ),
        throwsFormatException,
      );
    }
  });

  test('codec projection exposes flags, slots and unknown field drops', () {
    final source = blankPlayer('Synthetic')
      ..['unlockedSuperCart'] = true
      ..['a/b~c'] = null;
    (source['inventory'] as List)[50] = {
      'itemType': 8,
      'stack': 2,
      'prefix': 0,
      'favorited': true,
      'unknownSlotMetadata': 17,
    };
    final plan = PlayerConversion.prepare(source, 38);
    final projected = {...plan.candidate}
      ..remove('a/b~c')
      ..['unlockedSuperCart'] = false;
    projected['inventory'] = [
      for (var i = 0; i < 58; i++)
        i == 50
            ? {'itemType': 0, 'stack': 0, 'prefix': 0, 'favorited': false}
            : (plan.candidate['inventory'] as List)[i],
    ];
    final preview = plan.reviewProjection(projected);
    expect(preview.requiresLossConfirmation, isTrue);
    expect(preview.gameplayCompatibilityBlocked, isTrue);
    expect(
      preview.changes.where((c) => c.path == '/inventory/50'),
      hasLength(1),
    );
    expect(preview.changes.any((c) => c.path == '/unlockedSuperCart'), isTrue);
    final removed = preview.changes.singleWhere((c) => c.path == '/a~1b~0c');
    expect(removed.removed, isTrue);
    expect(removed.beforeExists, isTrue);
    expect(removed.before, isNull);
    expect(source['unlockedSuperCart'], isTrue);
  });

  test('projection version mismatch is never accepted', () {
    final plan = PlayerConversion.prepare(blankPlayer('Synthetic'), 135);
    expect(
      () => plan.reviewProjection(blankPlayer('Synthetic')),
      throwsFormatException,
    );
  });

  test(
    'same-version identity has no invented changes or compatibility gate',
    () {
      final source = blankPlayer('Synthetic');
      final preview = PlayerConversion.prepare(
        source,
        326,
      ).reviewProjection(source);
      expect(preview.changes, isEmpty);
      expect(preview.blockers, isEmpty);
      expect(preview.requiresLossConfirmation, isFalse);
    },
  );

  test('upgrade checks current catalog but cannot infer style IDs', () {
    final source = blankPlayer('Synthetic')..['version'] = 279;
    (source['inventory'] as List)[0] = {
      'itemType': 8,
      'stack': 999,
      'prefix': 7,
      'favorited': false,
    };
    (source['buffs'] as List)[0] = {'buffType': 99999, 'buffTime': 10};
    final plan = PlayerConversion.prepare(source, 326);
    final catalog = ResourceCatalog(
      gameVersion: '1.4.5.8',
      provenance: {},
      families: {
        'items': [
          CatalogEntry('items', {
            'id': 8,
            'maxStack': 99,
            'eligiblePrefixes': [1],
          }),
        ],
        'prefixes': [
          CatalogEntry('prefixes', {'id': 1}),
        ],
        'buffs': [],
      },
    );
    final result = plan.reviewProjection(plan.candidate, catalog: catalog);
    expect(result.blockers.any((b) => b.contains('数量超限')), isTrue);
    expect(result.blockers.any((b) => b.contains('前缀与物品')), isTrue);
    expect(result.blockers.any((b) => b.contains('状态 ID')), isTrue);
    expect(result.blockers.any((b) => b.contains('发型、服装与声音')), isTrue);
    expect(result.gameplayCompatibilityBlocked, isTrue);
    expect(
      (plan.candidate['inventory'] as List)[0],
      (source['inventory'] as List)[0],
    );
  });

  test('current catalog cannot authorize a historical target', () {
    final plan = PlayerConversion.prepare(blankPlayer('Synthetic'), 279);
    final result = plan.reviewProjection(
      plan.candidate,
      catalog: ResourceCatalog(
        gameVersion: '1.4.5.8',
        provenance: {},
        families: {},
      ),
    );
    expect(result.blockers.any((b) => b.contains('目标版本的物品')), isTrue);
  });
}
