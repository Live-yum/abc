import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/domain/world_rule_presets.dart';
import 'package:terraforge/domain/world_rules.dart';

Map<String, Object?> _row() => {
  'id': 'synthetic-preset',
  'name': 'Synthetic source',
  'badge': 'Synthetic',
  'description': 'Only synthetic rules are included in this test.',
  'builtinMode': 'purify',
  'rules': [
    {
      'where': {'is_active': 1, 'exclude_biome_region': 3},
      'patch': {'terrain_theme': 1},
      'limit': 7,
    },
    {
      'where': {'has_wall': true, 'biome_region': 2},
      'patch': {'invisible_wall': 1},
    },
  ],
};

Map<String, Object?> _provenance() => {
  'worldRulePresets': {
    'schema': 1,
    'gameVersion': 'synthetic-1',
    'inputSha256': 'a' * 64,
    'sourceFiles': {'synthetic/rules.mjs': 'b' * 64},
  },
  'sourceObjects': {
    'local-world-rule-presets.json': 'a' * 64,
    'synthetic/rules.mjs': 'b' * 64,
  },
};

ResourceCatalog _catalog({
  List<Map<String, Object?>>? rows,
  Map<String, Object?>? provenance,
}) => ResourceCatalog(
  gameVersion: 'synthetic-1',
  provenance: provenance ?? _provenance(),
  families: {
    WorldRulePresets.family: [
      for (final row in rows ?? [_row()])
        CatalogEntry(WorldRulePresets.family, row),
    ],
  },
);

WorldRulePresets _read(ResourceCatalog catalog) =>
    WorldRulePresets.fromCatalog(catalog, expectedVersion: 'synthetic-1');

void main() {
  test(
    'source rules clone as editable, ordered, independent custom schemes',
    () {
      final catalog = _catalog();
      final presets = _read(catalog);
      final preset = presets.byId('synthetic-preset')!;
      final copy = preset.editableCopy(name: 'My editable copy');
      expect(copy.name, 'My editable copy');
      expect(copy.isBuiltin, isFalse);
      expect(copy.toEngineRequest().containsKey('biome_mode'), isFalse);
      expect(preset.builtinMode, 'purify');
      expect(copy.rules.first.where, {
        'is_active': 1,
        'exclude_biome_region': 3,
      });
      expect(copy.rules.first.patch, {'terrain_theme': 1});
      expect(copy.rules.first.limit, 7);
      expect(copy.rules.last.where, {'has_wall': true, 'biome_region': 2});
      expect(copy.rules.last.patch, {'invisible_wall': 1});
      expect(copy.rules.last.limit, 0);
      expect(identical(copy.rules.first, preset.rules.first), isFalse);
      final edited = copy.copyWith(
        rules: [
          WorldTileRule(patch: {'wall': 42}),
        ],
      );
      expect(edited.rules, hasLength(1));
      expect(preset.rules, hasLength(2));
      expect(preset.editableCopy().name, 'Synthetic source 副本');
      expect(() => preset.rules.clear(), throwsUnsupportedError);
      expect(
        () => preset.rules.first.where['type'] = 8,
        throwsUnsupportedError,
      );
      expect(() => presets.presets.clear(), throwsUnsupportedError);
      expect(presets.byId('missing'), isNull);
    },
  );

  test('optional family keeps core fallback available', () {
    final missing = ResourceCatalog(
      gameVersion: 'synthetic-1',
      provenance: {},
      families: {},
    );
    expect(_read(missing).presets, isEmpty);
    expect(_read(_catalog(rows: [], provenance: {})).presets, isEmpty);
  });

  test('present family requires matching version and bound provenance', () {
    expect(
      () => WorldRulePresets.fromCatalog(_catalog(), expectedVersion: 'wrong'),
      throwsFormatException,
    );
    expect(() => _read(_catalog(provenance: {})), throwsFormatException);
    for (final key in ['inputSha256', 'gameVersion', 'schema', 'sourceFiles']) {
      final provenance = _provenance();
      (provenance['worldRulePresets'] as Map).remove(key);
      expect(
        () => _read(_catalog(provenance: provenance)),
        throwsFormatException,
      );
    }
    for (final key in [
      'local-world-rule-presets.json',
      'synthetic/rules.mjs',
    ]) {
      final provenance = _provenance();
      (provenance['sourceObjects'] as Map)[key] = 'c' * 64;
      expect(
        () => _read(_catalog(provenance: provenance)),
        throwsFormatException,
      );
    }
    final unsafe = _provenance();
    (unsafe['worldRulePresets'] as Map)['sourceFiles'] = {
      '../secret': 'b' * 64,
    };
    (unsafe['sourceObjects'] as Map)['../secret'] = 'b' * 64;
    expect(() => _read(_catalog(provenance: unsafe)), throwsFormatException);
  });

  test('reject invalid duplicate entries, fields, modes and overflow', () {
    final cases = <List<Map<String, Object?>>>[
      [_row(), _row()],
      [
        _row(),
        {..._row(), 'id': 'different-id'},
      ],
      [
        {..._row(), 'id': '../unsafe'},
      ],
      [
        {..._row(), 'name': ' '},
      ],
      [
        {..._row(), 'builtinMode': null},
      ],
      [
        {..._row(), 'builtinMode': 'unknown'},
      ],
      [
        {..._row(), 'unknown': 1},
      ],
      [
        {..._row(), 'rules': []},
      ],
      [
        {
          ..._row(),
          'rules': List.filled(129, {
            'where': {},
            'patch': {'wall': 42},
          }),
        },
      ],
    ];
    for (final rule in [
      {
        'where': {'type': 1.0},
        'patch': {'wall': 42},
      },
      {
        'where': {'type': true},
        'patch': {'wall': 42},
      },
      {
        'where': {'terrain_theme': 1},
        'patch': {'wall': 42},
      },
      {
        'where': {},
        'patch': {'is_active': 1},
      },
      {'where': {}, 'patch': {}},
      {
        'where': {},
        'patch': {'terrain_theme': 4},
      },
      {
        'where': {},
        'patch': {'wall': 42},
        'limit': -1,
      },
    ]) {
      cases.add([
        {
          ..._row(),
          'rules': [rule],
        },
      ]);
    }
    for (final rows in cases) {
      expect(() => _read(_catalog(rows: rows)), throwsFormatException);
    }
    final maximum = _read(
      _catalog(
        rows: [
          {
            ..._row(),
            'rules': List.filled(128, {
              'where': {},
              'patch': {'wall': 42},
            }),
          },
        ],
      ),
    );
    expect(maximum.presets.single.editableCopy().rules, hasLength(128));
    final longName = _read(
      _catalog(
        rows: [
          {..._row(), 'name': 'a' * 160},
        ],
      ),
    );
    expect(longName.presets.single.editableCopy().name, hasLength(160));
  });
}
