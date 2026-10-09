import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/player_tools.dart';

Map<String, Object?> item(
  int id,
  int n, {
  int prefix = 0,
  bool favorite = false,
}) => {'itemType': id, 'stack': n, 'prefix': prefix, 'favorited': favorite};
PlayerItemRules? rules(int id) => id == 1 || id == 2
    ? const PlayerItemRules(maxStack: 99, allowedPrefixes: {0, 2})
    : null;
void main() {
  test(
    'organize protects hotbar, money/ammo, favorites and unknown metadata',
    () {
      final values = List.generate(58, (_) => item(0, 0));
      values[0] = item(2, 10);
      values[10] = item(2, 5);
      values[11] = item(1, 50);
      values[12] = item(1, 55);
      values[13] = item(1, 20, favorite: true);
      values[14] = item(9000, 3);
      values[15] = {...item(1, 3), 'future': 7};
      values[50] = item(71, 10);
      values[54] = item(2, 30);
      final p = <String, Object?>{'version': 279, 'inventory': values};
      final snapshot = jsonEncode(p);
      final result = PlayerTools.organize(p, 'inventory', rules);
      expect(jsonEncode(p), snapshot);
      for (final i in [0, 13, 14, 15, 50, 54]) {
        expect(result[i], values[i]);
      }
      expect(result[10], item(1, 99));
      expect(result[11], item(1, 6));
      expect(result[12], item(2, 5));
    },
  );
  test(
    'different prefixes never combine and unsupported groups fail closed',
    () {
      final p = <String, Object?>{
        'version': 279,
        'safe': [item(1, 50), item(1, 55, prefix: 2)],
      };
      expect(PlayerTools.organize(p, 'safe', rules).map((s) => s['stack']), [
        50,
        55,
      ]);
      expect(
        () => PlayerTools.organize({...p, 'version': 37}, 'safe', rules),
        throwsFormatException,
      );
      expect(
        () => PlayerTools.organize(p, 'armor', rules),
        throwsFormatException,
      );
    },
  );
  test('editing requires reliable stack limit and prefix compatibility', () {
    expect(
      () => PlayerTools.editSlot(item(1, 2), itemId: 1, quantity: 3, prefix: 0),
      throwsFormatException,
    );
    expect(
      PlayerTools.editSlot(
        item(1, 2),
        itemId: 1,
        quantity: 1,
        prefix: 0,
      )['stack'],
      1,
    );
    expect(
      () => PlayerTools.editSlot(
        item(1, 2),
        itemId: 1,
        quantity: 100,
        prefix: 0,
        rules: rules(1),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.editSlot(
        item(1, 2),
        itemId: 1,
        quantity: 2,
        prefix: 3,
        rules: rules(1),
      ),
      throwsFormatException,
    );
    expect(
      PlayerTools.editSlot(
        item(1, 2),
        itemId: 1,
        quantity: 2,
        prefix: 2,
        rules: rules(1),
      )['prefix'],
      2,
    );
    expect(
      PlayerTools.editSlot(
        {...item(1, 2), 'extra': 'keep'},
        itemId: 0,
        quantity: 0,
        prefix: 0,
      )['extra'],
      'keep',
    );
  });
  test('ammo refill is immutable, metadata-gated and quantity-conserving', () {
    final values = List.generate(58, (_) => item(0, 0));
    values[0] = item(1, 50);
    values[10] = item(1, 50);
    values[11] = item(1, 50, favorite: true);
    values[54] = item(1, 60);
    final p = <String, Object?>{'version': 279, 'inventory': values};
    final result = PlayerTools.refillAmmo(
      p,
      (_) => const PlayerItemRules(maxStack: 99, canAmmo: true),
    );
    expect(result[54]['stack'], 99);
    expect(result[10]['stack'], 11);
    expect(result[0]['stack'], 50);
    expect(result[11]['stack'], 50);
    expect(values[54]['stack'], 60);
    expect(PlayerTools.refillAmmo(p, (_) => null), values);
  });
  test('equipment uses real arrays and absolute group indices', () {
    final p = <String, Object?>{
      'armor': List.generate(20, (_) => item(0, 0)),
      'dyes': List.generate(10, (_) => item(0, 0)),
      'loadouts': [
        {
          'armor': [item(0, 0)],
        },
      ],
    };
    final layout = PlayerTools.equipmentLayout(p);
    expect(layout.length, 30);
    expect(layout[10].label, '时装 头部');
    expect(layout[10].index, 10);
    expect(PlayerTools.equipmentLayout(p, loadout: 0).length, 1);
    expect(PlayerTools.equipmentLayout(p, loadout: 1), isEmpty);
  });
  test('buff capacities follow version and actual length; editing preserves metadata', () {
    final p = <String, Object?>{
      'version': 73,
      'buffs': List.generate(44, (_) => {'buffType': 0, 'buffTime': 0}),
    };
    expect(PlayerTools.buffCapacity(p), 10);
    expect(PlayerTools.buffCapacity({...p, 'version': 74}), 22);
    expect(PlayerTools.buffCapacity({...p, 'version': 252}), 44);
    expect(PlayerTools.buffCapacity({...p, 'version': 10}), 0);
    expect(
      () => PlayerTools.editBuff(p, 10, 1, 1, knownIds: {1}),
      throwsFormatException,
    );
    expect(() => PlayerTools.editBuff(p, 0, 99, 1), throwsFormatException);
    expect(
      () => PlayerTools.editBuff(p, 0, 1, double.infinity, knownIds: {1}),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.editBuff(p, 0, 1, 0.0001, knownIds: {1}),
      throwsFormatException,
    );
    expect(
      PlayerTools.editBuff(p, 0, 1, 1.5, knownIds: {1})[0]['buffTime'],
      90,
    );
    expect((p['buffs'] as List)[0]['buffTime'], 0);
  });
  test('research uses known max, collapses selected duplicates, preserves unknown records', () {
    final p = <String, Object?>{
      'version': 218,
      'creativeItemSacrifices': [
        {'persistentId': 'A', 'amount': 2},
        {'persistentId': 'A', 'amount': 4},
        {'persistentId': 'Future', 'amount': 12, 'extra': true},
      ],
    };
    const r = PlayerItemRules(persistentId: 'A', researchRequired: 10);
    final result = PlayerTools.research(p, r, 10);
    expect(result.length, 2);
    expect(result.first['extra'], true);
    expect(result.last['amount'], 10);
    expect(() => PlayerTools.research(p, r, 11), throwsFormatException);
    expect(
      () => PlayerTools.research(p, const PlayerItemRules(), 0),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.research({...p, 'version': 217}, r, 1),
      throwsFormatException,
    );
    expect(PlayerTools.research(p, r, 0).length, 1);
  });
  test('Journey preserves unknown powers and rejects wrong schema/ranges', () {
    final p = <String, Object?>{
      'version': 218,
      'creativePowers': {
        'godmodeEnabled': false,
        'spawnRateSlider': 0.5,
        'future': 17,
      },
    };
    expect(PlayerTools.power(p, 'godmodeEnabled', true)['future'], 17);
    expect(PlayerTools.slot(p['creativePowers'])['godmodeEnabled'], false);
    expect(
      () => PlayerTools.power(p, 'spawnRateSlider', 1.1),
      throwsFormatException,
    );
    expect(() => PlayerTools.power(p, 'future', true), throwsFormatException);
    expect(
      () => PlayerTools.power(p, 'farPlacementEnabled', true),
      throwsFormatException,
    );
  });
}
