import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/player_tools.dart';
import 'package:terraforge/domain/prefix_rules.dart';

import 'support/player_action_fixtures.dart';

void main() {
  test(
    'clipboard and paste are detached and retain unknown and favorite values',
    () {
      final source = {
        ...slot(10, count: 3, favorite: true),
        'sourceExtra': {
          'values': [4],
        },
      };
      final target = {
        ...slot(0),
        'targetExtra': {
          'values': [7],
        },
      };
      final clipboard = PlayerTools.copySlot(source);
      ((source['sourceExtra'] as Map)['values'] as List).add(5);
      final pasted = PlayerTools.pasteSlot(
        target,
        clipboard,
        version: 326,
        catalog: playerActionCatalog(),
      );
      expect(pasted['sourceExtra'], {
        'values': [4],
      });
      expect(pasted['targetExtra'], {
        'values': [7],
      });
      expect(pasted['favorited'], true);
      ((pasted['sourceExtra'] as Map)['values'] as List).add(6);
      ((pasted['targetExtra'] as Map)['values'] as List).add(8);
      expect(clipboard['sourceExtra'], {
        'values': [4],
      });
      expect(target['targetExtra'], {
        'values': [7],
      });
      expect(source['stack'], 3);
      expect(target['itemType'], 0);
    },
  );

  test('copy rejects malformed or excessive clipboard fields', () {
    for (final bad in [
      {...slot(10), 'itemType': '10'},
      {...slot(10), 'stack': 0},
      {...slot(10), 'prefix': 256},
      {...slot(10), 'favorited': 1},
      {...slot(10), 'stack': 10000},
      {...slot(10), 'extra': List.filled(70000, 'a').join()},
    ]) {
      expect(() => PlayerTools.copySlot(bad), throwsFormatException);
    }
  });

  test('paste checks destination metadata and versions, not copied source permission', () {
    final target = slot(0), copied = slot(10, count: 3, prefix: 1);
    final before = jsonEncode([target, copied]);
    expect(
      () => PlayerTools.pasteSlot(target, copied, version: 326),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.pasteSlot(
        target,
        copied,
        version: 326,
        catalog: playerActionCatalog(maxStack: 2),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.pasteSlot(
        target,
        copied,
        version: 326,
        catalog: playerActionCatalog(maxStack: 0),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.pasteSlot(
        target,
        copied,
        version: 326,
        catalog: playerActionCatalog(eligible: [2, 3]),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.pasteSlot(
        target,
        slot(10, prefix: 90),
        version: 314,
        catalog: playerActionCatalog(),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.pasteSlot(
        target,
        copied,
        version: 37,
        catalog: playerActionCatalog(),
      ),
      throwsFormatException,
    );
    expect(jsonEncode([target, copied]), before);
    final retained = PlayerTools.pasteSlot(
      slot(999, count: 4, prefix: 99),
      slot(999, count: 2, prefix: 99),
      version: 314,
    );
    expect(retained['stack'], 2);
    expect(retained['prefix'], 99);
  });

  test(
    'replace bounds real slot paths and returns a single immutable change',
    () {
      final p = <String, Object?>{
        'version': 326,
        'inventory': [slot(0)],
        'armor': [slot(10, prefix: 1)],
        'loadouts': [
          {
            'armor': [slot(0)],
            'future': 9,
          },
        ],
        'future': {'value': 3},
      };
      final before = jsonEncode(p);
      final changed = PlayerTools.replaceSlot(
        p,
        'armor',
        0,
        slot(10, prefix: 2),
        loadout: 0,
        catalog: playerActionCatalog(),
      );
      expect(
        ((changed['loadouts'] as List).single['armor'] as List)
            .single['prefix'],
        2,
      );
      expect((changed['armor'] as List).single['prefix'], 1);
      expect((changed['loadouts'] as List).single['future'], 9);
      for (final attempt in <void Function()>[
        () => PlayerTools.replaceSlot(p, 'unknown', 0, slot(0)),
        () => PlayerTools.replaceSlot(p, 'safe', 0, slot(0)),
        () => PlayerTools.replaceSlot(p, 'inventory', -1, slot(0)),
        () => PlayerTools.replaceSlot(p, 'inventory', 1, slot(0)),
        () => PlayerTools.replaceSlot(p, 'inventory', 0, slot(0), loadout: 0),
        () => PlayerTools.replaceSlot(p, 'armor', 0, slot(0), loadout: 1),
      ]) {
        expect(attempt, throwsFormatException);
      }
      expect(jsonEncode(p), before);
    },
  );

  test('best prefixes retain tied current, unsupported and opaque fields in selected stores', () {
    final p = <String, Object?>{
      'version': 314,
      'inventory': [
        slot(10, prefix: 1, favorite: true),
        slot(10, prefix: 3),
        slot(999, prefix: 44),
        {
          ...slot(10),
          'future': {'data': 7},
        },
        slot(0),
      ],
      'safe': [slot(10, prefix: 1)],
    };
    final before = jsonEncode(p);
    final result = PlayerTools.bestPrefixes(
      p,
      groups: ['inventory'],
      rules: PrefixRules(playerActionCatalog()),
    );
    final items = result.player['inventory'] as List;
    expect(items.map((item) => item['prefix']), [2, 3, 44, 2, 0]);
    expect(items.first['favorited'], true);
    expect(items[3]['future'], {'data': 7});
    expect((result.player['safe'] as List).single['prefix'], 1);
    expect(result.changedItems, 2);
    expect(result.changedGroups, {'inventory'});
    expect(jsonEncode(p), before);
    final all = PlayerTools.bestPrefixes(
      p,
      groups: ['inventory', 'safe'],
      rules: PrefixRules(playerActionCatalog()),
    );
    expect(all.changedItems, 3);
    expect(all.changedGroups, {'inventory', 'safe'});
  });

  test('loadout bulk patches top-level loadouts and rejects invalid scopes atomically', () {
    final p = <String, Object?>{
      'version': 326,
      'armor': [slot(10)],
      'loadouts': [
        {
          'armor': [slot(10)],
          'dyes': [slot(999)],
          'future': 4,
        },
      ],
    };
    final before = jsonEncode(p);
    final result = PlayerTools.bestPrefixes(
      p,
      groups: ['armor', 'dyes'],
      loadout: 0,
      rules: PrefixRules(playerActionCatalog()),
    );
    expect(result.changedItems, 1);
    expect(result.changedGroups, {'loadouts'});
    expect((result.player['armor'] as List).single['prefix'], 0);
    expect((result.player['loadouts'] as List).single['future'], 4);
    expect(
      () => PlayerTools.bestPrefixes(
        p,
        groups: ['armor', 'inventory'],
        loadout: 0,
        rules: PrefixRules(playerActionCatalog()),
      ),
      throwsFormatException,
    );
    expect(
      () => PlayerTools.bestPrefixes(
        {...p, 'version': 37},
        groups: ['armor'],
        rules: PrefixRules(playerActionCatalog()),
      ),
      throwsFormatException,
    );
    expect(jsonEncode(p), before);
  });
}
