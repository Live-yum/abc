import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/bestiary_tools.dart';
import 'package:terraforge/domain/resource_catalog.dart';
import 'package:terraforge/platform/resource_store.dart';

CatalogEntry bestiaryRow(
  int id,
  String persistent, {
  String kind = 'kills',
  Object? threshold = 50,
  Object? rule,
}) => CatalogEntry('bestiary', {
  'id': id,
  'persistentNpcId': persistent,
  'name': 'Creature $id',
  'unlockRule':
      rule ??
      {
        'kind': kind,
        'persistentNpcId': persistent,
        'killCountNeededToFullyUnlock': threshold,
      },
});
ResourceCatalog bestiaryCatalog(List<CatalogEntry> rows) => ResourceCatalog(
  gameVersion: '1.4.5.6',
  provenance: {},
  families: {'bestiary': rows},
);
Map<String, Object?> emptyBestiary() => {
  'kills': <Object?>[],
  'sightings': <Object?>[],
  'chats': <Object?>[],
};

void main() {
  test('coalesces matching persistent aliases and keeps both searchable', () {
    final catalog = bestiaryCatalog([
      bestiaryRow(1, 'Nymph2'),
      bestiaryRow(2, 'Nymph2'),
    ]);
    final rows = BestiaryTools.entries(emptyBestiary(), catalog);
    expect(rows, hasLength(1));
    expect(rows.single.fullUnlockCount, 50);
    expect(rows.single.searchText, contains('creature 2'));
  });
  test(
    'rejects conflicting aliases, numeric IDs, and nested ambiguous rules',
    () {
      for (final rows in [
        [bestiaryRow(1, 'A'), bestiaryRow(2, 'A', threshold: 100)],
        [bestiaryRow(1, 'A'), bestiaryRow(1, 'B')],
        [
          bestiaryRow(
            1,
            'A',
            rule: {
              'kind': 'highest-of-multiple',
              'children': [
                {
                  'kind': 'kills',
                  'persistentNpcId': 'A',
                  'killCountNeededToFullyUnlock': 50,
                },
                {'kind': 'chat', 'persistentNpcId': 'A'},
              ],
            },
          ),
        ],
      ]) {
        expect(
          () => BestiaryTools.entries(emptyBestiary(), bestiaryCatalog(rows)),
          throwsFormatException,
        );
      }
    },
  );
  test('uses only own nested rules, world thresholds, and gold IDs', () {
    final rows = BestiaryTools.entries(
      emptyBestiary(),
      bestiaryCatalog([
        bestiaryRow(1, 'A', kind: 'world-conditional-kills', threshold: 17),
        bestiaryRow(
          2,
          'B',
          rule: {
            'kind': 'highest-of-multiple',
            'children': [
              {
                'kind': 'kills',
                'persistentNpcId': 'Elsewhere',
                'killCountNeededToFullyUnlock': 999,
              },
              {'kind': 'sighting', 'persistentNpcId': 'B'},
            ],
          },
        ),
        bestiaryRow(
          3,
          'Gold',
          rule: {'kind': 'gold-critter', 'goldCritterPersistentId': 'Gold'},
        ),
      ]),
    );
    expect(rows.map((r) => r.kind), ['kills', 'sightings', 'sightings']);
    expect(rows.first.fullUnlockCount, 17);
  });
  test(
    'missing, mismatched, invalid thresholds never invent editable rules',
    () {
      final catalog = bestiaryCatalog([
        for (var i = 0; i < 4; i++)
          bestiaryRow(i, 'Bad$i', threshold: [null, 0, 1.5, 1000000000][i]),
        bestiaryRow(
          5,
          'Mismatch',
          rule: {'kind': 'chat', 'persistentNpcId': 'Other'},
        ),
      ]);
      expect(
        BestiaryTools.entries(
          emptyBestiary(),
          catalog,
        ).every((r) => !r.editable),
        isTrue,
      );
      expect(
        () => BestiaryTools.unlockKnown(
          emptyBestiary(),
          catalog: catalog,
          confirmed: true,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'kill count bounds are strict and failures leave original untouched',
    () {
      final save = emptyBestiary();
      final catalog = bestiaryCatalog([bestiaryRow(1, 'A')]);
      for (final invalid in [-1, 1000000000, 2.0, '50', true, null]) {
        expect(
          () => BestiaryTools.editEntry(
            save,
            catalog: catalog,
            id: 'A',
            kind: 'kills',
            value: invalid,
          ),
          throwsFormatException,
        );
        expect(save, emptyBestiary());
      }
      for (final count in [0, 999999999]) {
        final changed = BestiaryTools.editEntry(
          save,
          catalog: catalog,
          id: 'A',
          kind: 'kills',
          value: count,
        );
        expect((changed['kills'] as List).single, {
          'persistentNpcId': 'A',
          'killCount': count,
        });
      }
      expect(save, emptyBestiary());
    },
  );
  test(
    'partial catalog preserves unknown records and extra fields exactly',
    () {
      final save = <String, Object?>{
        'kills': [
          {'persistentNpcId': 'A', 'killCount': 9, 'extra': 'keep'},
          {'persistentNpcId': 'Unknown', 'killCount': 27},
        ],
        'sightings': [
          'Unknown',
          {'persistentNpcId': 'A', 'extra': 2},
        ],
        'chats': [
          {'persistentNpcId': 'Unknown', 'extra': 3},
        ],
        'future': {'a': 1},
      };
      final before = jsonEncode(save);
      final catalog = bestiaryCatalog([bestiaryRow(1, 'A')]);
      final changed = BestiaryTools.editEntry(
        save,
        catalog: catalog,
        id: 'A',
        kind: 'kills',
        value: 0,
      );
      expect((changed['kills'] as List).first, {
        'persistentNpcId': 'A',
        'killCount': 0,
        'extra': 'keep',
      });
      expect((changed['kills'] as List).last, (save['kills'] as List).last);
      expect(changed['sightings'], save['sightings']);
      expect(changed['chats'], save['chats']);
      expect(changed['future'], save['future']);
      expect(BestiaryTools.entries(changed, catalog).first.unlocked, isFalse);
      expect(
        () => BestiaryTools.editEntry(
          save,
          catalog: catalog,
          id: 'Unknown',
          kind: 'kills',
          value: 5,
        ),
        throwsFormatException,
      );
      expect(jsonEncode(save), before);
    },
  );
  test('boolean tracks unlock together and relock clears positive count', () {
    for (final kind in ['chat', 'sighting']) {
      final catalog = bestiaryCatalog([bestiaryRow(1, 'A', kind: kind)]);
      final save = emptyBestiary()
        ..['kills'] = [
          {'persistentNpcId': 'A', 'killCount': 2},
        ];
      final track = kind == 'chat' ? 'chats' : 'sightings';
      final on = BestiaryTools.editEntry(
        save,
        catalog: catalog,
        id: 'A',
        kind: track,
        value: true,
      );
      expect(on['sightings'], [
        {'persistentNpcId': 'A'},
      ]);
      expect(on['chats'], [
        {'persistentNpcId': 'A'},
      ]);
      final off = BestiaryTools.editEntry(
        on,
        catalog: catalog,
        id: 'A',
        kind: track,
        value: false,
      );
      expect(off['sightings'], isEmpty);
      expect(off['chats'], isEmpty);
      expect(BestiaryTools.entries(off, catalog).single.unlocked, isFalse);
      expect(
        () => BestiaryTools.editEntry(
          save,
          catalog: catalog,
          id: 'A',
          kind: track,
          value: 1,
        ),
        throwsFormatException,
      );
    }
  });
  test('malformed or duplicate save data aborts bulk atomically', () {
    final catalog = bestiaryCatalog([bestiaryRow(1, 'A')]);
    for (final malformed in [
      emptyBestiary()
        ..['chats'] = [
          'A',
          {'persistentNpcId': 'A'},
        ],
      emptyBestiary()
        ..['kills'] = [
          {'persistentNpcId': 'A', 'killCount': -1},
        ],
      emptyBestiary()..['sightings'] = [null],
      emptyBestiary()..remove('chats'),
    ]) {
      final before = jsonEncode(malformed);
      expect(
        () => BestiaryTools.unlockKnown(
          malformed,
          catalog: catalog,
          confirmed: true,
        ),
        throwsFormatException,
      );
      expect(jsonEncode(malformed), before);
    }
  });
  test(
    'bulk requires confirmation and preserves positives and unknown IDs',
    () {
      final save = emptyBestiary()
        ..['kills'] = [
          {'persistentNpcId': 'Positive', 'killCount': 1},
          {'persistentNpcId': 'Zero', 'killCount': 0},
          {'persistentNpcId': 'Unknown', 'killCount': 15},
        ];
      final catalog = bestiaryCatalog([
        bestiaryRow(1, 'Positive'),
        bestiaryRow(2, 'Zero', threshold: 17),
      ]);
      expect(
        () =>
            BestiaryTools.unlockKnown(save, catalog: catalog, confirmed: false),
        throwsStateError,
      );
      final changed = BestiaryTools.unlockKnown(
        save,
        catalog: catalog,
        confirmed: true,
      );
      expect((changed['kills'] as List).map((r) => (r as Map)['killCount']), [
        1,
        17,
        15,
      ]);
      expect(changed['sightings'], [
        {'persistentNpcId': 'Positive'},
        {'persistentNpcId': 'Zero'},
      ]);
      expect((save['kills'] as List)[1], {
        'persistentNpcId': 'Zero',
        'killCount': 0,
      });
    },
  );
  final packPath = Platform.environment['ABC_PRIVATE_PACK'];
  test(
    'real imported metadata coalesces all legitimate aliases without guessed rules',
    () {
      final catalog = ResourceStore.importPack(
        File(packPath!).readAsBytesSync(),
      ).catalog;
      final sourceRows = catalog.families['bestiary']!;
      final entries = BestiaryTools.entries(emptyBestiary(), catalog);
      expect(sourceRows, hasLength(546));
      expect(entries, hasLength(536));
      // Twelve minions use a different boss's tracker, so they stay read-only.
      expect(entries.where((r) => r.editable), hasLength(524));
      expect(entries.where((r) => !r.editable), hasLength(12));
      final unlocked = BestiaryTools.unlockKnown(
        emptyBestiary(),
        catalog: catalog,
        confirmed: true,
      );
      expect(
        BestiaryTools.entries(
          unlocked,
          catalog,
        ).where((r) => r.editable).every((r) => r.unlocked),
        isTrue,
      );
      expect((unlocked['sightings'] as List), hasLength(524));
    },
    skip: packPath == null
        ? 'Set ABC_PRIVATE_PACK for private local metadata validation.'
        : false,
  );
}
