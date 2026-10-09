import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/prefix_rules.dart';
import 'package:terraforge/domain/resource_catalog.dart';

ResourceCatalog prefixFixture({
  Map<String, Object?> gameplay = const {
    'damage': 20,
    'useAnimation': 20,
    'mana': 20,
    'knockBack': 3,
  },
  List<Map<String, Object?>>? prefixes,
  List<int> eligible = const [1, 2, 3],
  String? pool,
}) => ResourceCatalog(
  gameVersion: '1.4.5.8',
  provenance: {},
  families: {
    'items': [
      CatalogEntry('items', {
        'id': 10,
        'gameplay': gameplay,
        'eligiblePrefixes': eligible,
        'prefixPool': pool,
        'maxStack': 99,
      }),
    ],
    'prefixes':
        (prefixes ??
                [
                  {
                    'id': 1,
                    'stats': {'dmg': 1.1},
                    'pools': <String>[],
                  },
                  {
                    'id': 2,
                    'stats': {'dmg': 1.2},
                    'pools': <String>[],
                  },
                  {
                    'id': 3,
                    'stats': {'dmg': 1.2},
                    'pools': <String>[],
                  },
                ])
            .map((p) => CatalogEntry('prefixes', p))
            .toList(),
  },
);
void main() {
  test('metadata maximum, ties preserve existing, unknown closed', () {
    final rules = PrefixRules(prefixFixture());
    final best = rules.bestPrefix(10, version: 326, current: 3)!;
    expect(best.id, 3);
    expect(best.ties, [2, 3]);
    expect(best.score, PrefixRules.float32(1.2));
    expect(rules.bestPrefix(10, version: 326, current: 0)!.id, 2);
    expect(rules.bestPrefix(12, version: 326, current: 0), isNull);
    expect(rules.bestPrefix(10, version: 0, current: 0), isNull);
  });
  test(
    'native float32 products and midpoint-to-even reject unchanged stats',
    () {
      expect([.5, 1.5, 2.5, -.5, -1.5, -2.5].map(PrefixRules.roundEven), [
        0,
        2,
        2,
        0,
        -2,
        -2,
      ]);
      final rules = PrefixRules(
        prefixFixture(
          gameplay: {'damage': 2, 'useAnimation': 2, 'mana': 2, 'knockBack': 1},
          prefixes: [
            {
              'id': 1,
              'stats': {'dmg': 1.25},
              'pools': <String>[],
            },
            {
              'id': 2,
              'stats': {'dmg': .75},
              'pools': <String>[],
            },
            {
              'id': 3,
              'stats': {'dmg': 1.25000001},
              'pools': <String>[],
            },
          ],
        ),
      );
      expect(rules.eligiblePrefixes(10, version: 326), isEmpty);
    },
  );
  test('raw non-unit multiplier rounded to float32 unity is ineligible', () {
    final rules = PrefixRules(
      prefixFixture(
        prefixes: [
          {
            'id': 1,
            'stats': {'dmg': 1.00000001},
            'pools': <String>[],
          },
        ],
      ),
    );
    expect(rules.eligiblePrefixes(10, version: 326), isEmpty);
  });
  test('negative effects can be eligible but score lower', () {
    final rules = PrefixRules(
      prefixFixture(
        prefixes: [
          {
            'id': 1,
            'stats': {'dmg': .9, 'spd': 1.1, 'mcst': 1.1, 'crt': -2},
            'pools': <String>[],
          },
          {
            'id': 2,
            'stats': {'dmg': 1.1, 'spd': .9, 'mcst': .9, 'crt': 2},
            'pools': <String>[],
          },
        ],
      ),
    );
    expect(rules.prefixScore(10, 1), lessThan(1));
    expect(rules.prefixScore(10, 2), greaterThan(1));
    expect(rules.bestPrefix(10, version: 326, current: 1)!.id, 2);
  });
  test('zero knockback and missing or nonfinite metadata fail closed', () {
    final rules = PrefixRules(
      prefixFixture(
        gameplay: {'knockBack': 0},
        prefixes: [
          {
            'id': 1,
            'stats': {'kb': 1.1},
            'pools': <String>[],
          },
          {
            'id': 2,
            'stats': {'dmg': 1.1},
            'pools': <String>[],
          },
          {
            'id': 3,
            'stats': {'size': double.nan},
            'pools': <String>[],
          },
        ],
      ),
    );
    expect(rules.eligiblePrefixes(10, version: 326), isEmpty);
    final accessory = PrefixRules(
      prefixFixture(
        prefixes: [
          {
            'id': 1,
            'stats': {},
            'pools': ['PrefixesForAccessories'],
          },
          {
            'id': 2,
            'stats': {},
            'pools': ['PrefixesForAccessories'],
            'valueMultiplier': 1.44,
          },
        ],
      ),
    );
    expect(accessory.eligiblePrefixes(10, version: 326), [2]);
  });
  test(
    'legacy summon pool uses imported magic membership and version cutoff',
    () {
      final rules = PrefixRules(
        prefixFixture(
          pool: 'PrefixesForSummons',
          eligible: [90],
          prefixes: [
            {
              'id': 1,
              'stats': {},
              'pools': ['PrefixesForMagic'],
            },
            {
              'id': 90,
              'stats': {},
              'pools': ['PrefixesForMagic', 'PrefixesForSummons'],
            },
          ],
        ),
      );
      expect(rules.eligiblePrefixes(10, version: 314), [1]);
      expect(rules.eligiblePrefixes(10, version: 315), [90]);
    },
  );
}
