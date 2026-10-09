import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/chest_tools.dart';
import 'package:terraforge/domain/prefix_rules.dart';

import 'prefix_rules_test.dart' show prefixFixture;

Map<String, Object?> item(
  int id,
  int stack, {
  int prefix = 0,
  bool? favorite,
}) => {
  'itemType': id,
  'stack': stack,
  'prefix': prefix,
  'favorited': ?favorite,
};

class CountingPrefixRules extends PrefixRules {
  CountingPrefixRules() : super(prefixFixture());
  final calls = <(int, int), int>{};
  @override
  PrefixCandidate? bestPrefix(
    int itemId, {
    required int version,
    required int current,
  }) {
    final key = (itemId, current);
    calls.update(key, (count) => count + 1, ifAbsent: () => 1);
    return super.bestPrefix(itemId, version: version, current: current);
  }
}

void main() {
  test(
    'bulk cache reuses matching recommendations including null per call',
    () {
      final rules = CountingPrefixRules();
      final chests = <Map<String, Object?>>[
        {
          'items': [item(10, 1), item(10, 1), item(999, 1)],
        },
        {
          'items': [item(10, 1), item(10, 1, prefix: 3), item(999, 1)],
        },
      ];
      ChestTools.bestPrefixes(chests, rules: rules, version: 326);
      expect(rules.calls, {(10, 0): 1, (10, 3): 1, (999, 0): 1});
      ChestTools.bestPrefixes(chests, rules: rules, version: 326);
      expect(rules.calls, {(10, 0): 2, (10, 3): 2, (999, 0): 2});
    },
  );

  test(
    'rename and clear preserve coordinates, extra fields and slot count',
    () {
      final chest = <String, Object?>{
        'x': 12,
        'name': 'old',
        'custom': {'keep': true},
        'items': [item(10, 3), null],
      };
      final snapshot = jsonEncode(chest);
      expect(ChestTools.rename(chest, '新箱子')['name'], '新箱子');
      expect(() => ChestTools.rename(chest, 'a' * 21), throwsFormatException);
      expect(
        () => ChestTools.rename(chest, 'bad\nname'),
        throwsFormatException,
      );
      final clear = ChestTools.clear(chest);
      expect(clear['items'], [null, null]);
      expect(clear['custom'], chest['custom']);
      expect(clear['x'], 12);
      expect(jsonEncode(chest), snapshot);
    },
  );
  test('edit preserves extra item fields and rejects bounds and unsupported growth', () {
    final chest = <String, Object?>{
      'items': [
        {...item(10, 4), 'unknown': 'retained'},
        null,
      ],
    };
    final edited = ChestTools.editSlot(
      chest,
      0,
      itemId: 10,
      quantity: 2,
      prefix: 0,
    );
    expect((edited['items'] as List)[0], {
      ...item(10, 2),
      'unknown': 'retained',
    });
    expect((chest['items'] as List)[0], {
      ...item(10, 4),
      'unknown': 'retained',
    });
    expect(
      () => ChestTools.editSlot(chest, 0, itemId: 10, quantity: 5, prefix: 0),
      throwsFormatException,
    );
    expect(
      () => ChestTools.editSlot(
        chest,
        2,
        itemId: 10,
        quantity: 1,
        prefix: 0,
        catalog: prefixFixture(),
      ),
      throwsFormatException,
    );
    expect(
      () => ChestTools.editSlot(chest, 0, itemId: 10, quantity: 1, prefix: 256),
      throwsFormatException,
    );
    expect(
      () => ChestTools.editSlot(
        chest,
        0,
        itemId: 10,
        quantity: 100,
        prefix: 0,
        catalog: prefixFixture(),
      ),
      throwsFormatException,
    );
    expect(
      () => ChestTools.editSlot(
        chest,
        0,
        itemId: 10,
        quantity: 3,
        prefix: 8,
        catalog: prefixFixture(),
      ),
      throwsFormatException,
    );
    final added = ChestTools.editSlot(
      chest,
      1,
      itemId: 10,
      quantity: 99,
      prefix: 1,
      catalog: prefixFixture(),
    );
    expect((added['items'] as List)[1], item(10, 99, prefix: 1));
  });
  test('sort only does not merge; unknown and favorites are immovable', () {
    final locked = {...item(7, 8), 'extension': 42};
    final favorite = item(8, 1, favorite: true);
    final chest = <String, Object?>{
      'items': [
        null,
        locked,
        item(10, 5),
        favorite,
        item(2, 2),
        item(10, 4),
        null,
      ],
    };
    final snapshot = jsonEncode(chest);
    final sorted = ChestTools.organize(chest)['items'] as List;
    expect(sorted, [
      item(2, 2),
      locked,
      item(10, 5),
      favorite,
      item(10, 4),
      null,
      null,
    ]);
    expect(jsonEncode(chest), snapshot);
  });
  test('verified merge preserves total, maxStack and nullable fixed slots', () {
    final chest = <String, Object?>{
      'items': [item(10, 70), null, item(10, 60), item(10, 2, prefix: 1), null],
    };
    final snapshot = jsonEncode(chest);
    final sorted =
        ChestTools.organize(chest, catalog: prefixFixture())['items'] as List;
    expect(sorted, [
      item(10, 99),
      item(10, 31),
      item(10, 2, prefix: 1),
      null,
      null,
    ]);
    expect(jsonEncode(chest), snapshot);
    expect(
      sorted.whereType<Map>().fold<int>(
        0,
        (n, item) => n + (item['stack'] as int),
      ),
      132,
    );
  });
  test('declared capacity protects extended slots without truncation', () {
    final chest = <String, Object?>{
      'maxItems': 1,
      'items': [null, item(10, 5)],
    };
    expect(
      ChestTools.organize(chest, catalog: prefixFixture())['items'],
      chest['items'],
    );
    expect(
      () => ChestTools.editSlot(chest, 1, itemId: 0, quantity: 0, prefix: 0),
      throwsFormatException,
    );
    expect(
      ChestTools.bestPrefixes(
        [chest],
        rules: PrefixRules(prefixFixture()),
        version: 326,
      ).changedItems,
      0,
    );
  });
  test(
    'positive item with zero quantity is invalid, not an implicit clear',
    () {
      final chest = <String, Object?>{
        'items': [item(10, 5)],
      };
      expect(
        () => ChestTools.editSlot(chest, 0, itemId: 10, quantity: 0, prefix: 0),
        throwsFormatException,
      );
      expect((chest['items'] as List).single, item(10, 5));
    },
  );
  test(
    'bulk best prefixes keeps tied originals and counts changed slots/chests',
    () {
      final chests = <Map<String, Object?>>[
        {
          'x': 1,
          'items': [
            null,
            {...item(10, 1, prefix: 1), 'extra': 'kept'},
            item(10, 2, prefix: 3),
          ],
        },
        {
          'x': 2,
          'items': [item(10, 4, prefix: 2), item(999, 1)],
        },
      ];
      final snapshot = jsonEncode(chests);
      final result = ChestTools.bestPrefixes(
        chests,
        rules: PrefixRules(prefixFixture()),
        version: 326,
      );
      expect(result.changedItems, 1);
      expect(result.changedChests, 1);
      expect((result.chests[0]['items'] as List)[1], {
        ...item(10, 1, prefix: 2),
        'extra': 'kept',
      });
      expect((result.chests[0]['items'] as List)[2], item(10, 2, prefix: 3));
      expect(jsonEncode(chests), snapshot);
      final again = ChestTools.bestPrefixes(
        result.chests,
        rules: PrefixRules(prefixFixture()),
        version: 326,
      );
      expect(again.changedItems, 0);
      expect(again.changedChests, 0);
    },
  );
}
