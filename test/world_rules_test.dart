import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/world_rules.dart';

void main() {
  WorldTileRule rule({
    Map<String, Object?> where = const {},
    Map<String, Object?> patch = const {'type': 1},
    int limit = 0,
  }) => WorldTileRule(where: where, patch: patch, limit: limit);
  test('unknown and malformed predicates fail closed', () {
    for (final value in [null, true, '1', 1.0, -1, 65536]) {
      expect(() => rule(where: {'type': value}), throwsFormatException);
    }
    expect(() => rule(where: {'typo': 1}), throwsFormatException);
    expect(() => rule(patch: {'typo': 1}), throwsFormatException);
    expect(
      () => WorldTileRule.fromJson({
        'where': null,
        'patch': {'type': 1},
      }),
      throwsFormatException,
    );
    expect(
      () => WorldTileRule.fromJson({
        'where': {},
        'patch': {'type': 1},
        'typo': true,
      }),
      throwsFormatException,
    );
    expect(() => rule(patch: {}), throwsFormatException);
    expect(() => rule(where: {'terrain_theme': 1}), throwsFormatException);
    expect(() => rule(patch: {'has_wall': true}), throwsFormatException);
  });
  test('field bounds and boolean types', () {
    for (final e in worldRuleFields.entries) {
      final side = e.value.where;
      for (final bad
          in e.value.boolean
              ? [null, 'true', 2, -1, 1.0]
              : [
                  null,
                  true,
                  '${e.value.min}',
                  e.value.min - 1,
                  e.value.max + 1,
                ]) {
        expect(
          () => side ? rule(where: {e.key: bad}) : rule(patch: {e.key: bad}),
          throwsFormatException,
          reason: '${e.key}=$bad',
        );
      }
    }
    expect(
      rule(where: {'wire_red': true}, patch: {'wire_red': 0}).patch['wire_red'],
      0,
    );
    expect(() => rule(limit: -1), throwsFormatException);
    expect(() => rule(limit: 2147483648), throwsFormatException);
  });
  test('platform conflicts', () {
    expect(
      () => rule(where: {'type': 1, 'platform_style': 0}),
      throwsFormatException,
    );
    expect(
      () => rule(where: {'platform_style': 2, 'frame_y': 18}),
      throwsFormatException,
    );
    expect(
      () => rule(patch: {'platform_style': 2, 'frame_y': 36}),
      throwsFormatException,
    );
    expect(
      rule(where: {'platform_style': 2, 'frame_y': 36}),
      isA<WorldTileRule>(),
    );
  });
  test('material validates nested layout and cross-rule constraints', () {
    final material = <String, Object?>{
      'frame_x': 0,
      'frame_y': 0,
      'width': 2,
      'height': 2,
      'coordinate_width': 16,
      'padding': 2,
      'coordinate_heights': [16, 16],
    };
    expect(
      rule(
        where: {'type': 21, 'material': material},
        patch: {'material': material},
      ),
      isA<WorldTileRule>(),
    );
    expect(() => rule(where: {'material': material}), throwsFormatException);
    expect(() => rule(patch: {'material': material}), throwsFormatException);
    expect(
      () => rule(where: {'type': 21, 'material': material}, limit: 1),
      throwsFormatException,
    );
    expect(
      () =>
          rule(where: {'type': 21, 'material': material}, patch: {'type': 22}),
      throwsFormatException,
    );
    expect(
      () => rule(
        where: {
          'type': 21,
          'material': {...material, 'unknown': 0},
        },
      ),
      throwsFormatException,
    );
    expect(
      () => rule(
        where: {
          'type': 21,
          'material': {
            ...material,
            'coordinate_heights': [16],
          },
        },
      ),
      throwsFormatException,
    );
    expect(
      () => rule(
        where: {
          'type': 21,
          'material': {...material, 'frame_x': 32767},
        },
      ),
      throwsFormatException,
    );
  });
  test('ordered rules, exact builtin request and draft handling', () {
    final scheme = WorldRuleScheme(
      name: 'A',
      rules: [
        rule(limit: 3),
        rule(patch: {'wall': 2}),
      ],
    );
    expect(scheme.toEngineRequest(), {
      'rules': [
        {
          'where': {},
          'patch': {'type': 1},
          'limit': 3,
        },
        {
          'where': {},
          'patch': {'wall': 2},
          'limit': 0,
        },
      ],
    });
    for (final mode in WorldRuleScheme.builtinModes) {
      expect(WorldRuleScheme(name: mode, biomeMode: mode).toEngineRequest(), {
        'biome_mode': mode,
      });
    }
    expect(
      () => WorldRuleScheme(name: 'A', biomeMode: 'purify', rules: [rule()]),
      throwsFormatException,
    );
    expect(
      () => WorldRuleScheme(name: 'A', biomeMode: 'bad'),
      throwsFormatException,
    );
    final empty = WorldRuleScheme(name: 'Draft');
    expect(empty.canPreview, false);
    expect(() => empty.toEngineRequest(), throwsFormatException);
    expect(
      () =>
          WorldRuleScheme(name: 'A', rules: List.generate(129, (_) => rule())),
      throwsFormatException,
    );
  });
  test('strict versioned import, bounded UTF8 and canonical fingerprint', () {
    final a = WorldRuleScheme(
      name: 'A',
      rules: [
        rule(where: {'type': 1, 'wall': 2}),
      ],
    );
    final b = WorldRuleScheme(
      name: 'A',
      rules: [
        rule(where: {'wall': 2, 'type': 1}),
      ],
    );
    expect(a.fingerprint, b.fingerprint);
    expect(WorldRuleScheme.decode(a.encode()).fingerprint, a.fingerprint);
    for (final extra in [
      {'version': 2},
      {'version': 1.0},
      {'unknown': true},
      {'biome_mode': null},
    ]) {
      expect(
        () => WorldRuleScheme.fromJson({...a.toJson(), ...extra}),
        throwsFormatException,
      );
    }
    expect(
      () => WorldRuleScheme.decode(
        '${' ' * WorldRuleScheme.maxJsonBytes}${jsonEncode(a.toJson())}',
      ),
      throwsFormatException,
    );
    expect(() => a.rules.add(rule()), throwsUnsupportedError);
    expect(() => a.rules.first.where['type'] = 99, throwsUnsupportedError);
    final source = {'type': 1};
    final r = rule(where: source);
    source['type'] = 2;
    expect(r.where['type'], 1);
  });
}
