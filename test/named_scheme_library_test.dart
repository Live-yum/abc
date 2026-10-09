import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/named_scheme_library.dart';
import 'package:terraforge/domain/world_rules.dart';

Map<String, Object?> mapping([Object? rules = const []]) => {
  'format': 'terraforge.mapping',
  'version': 1,
  'rules': rules,
};

void main() {
  test(
    'create, clone, rename and save preserve separate stable identities',
    () {
      final original = NamedSchemeLibrary(kind: NamedSchemeKind.mapping).create(
        name: 'Original',
        payload: mapping([
          {'source': '#112233', 'target': '1'},
        ]),
      );
      final originalId = original.selectedId!;
      final copy = original.clone(originalId);
      expect(copy.selected!.name, 'Original 副本');
      expect(copy.selectedId, isNot(originalId));
      expect(copy.defaultId, originalId);
      final renamed = copy.rename(copy.selectedId!, 'Changed');
      final saved = renamed.updateSelected(
        mapping([
          {'source': '445566', 'target': 2},
        ]),
      );
      expect(saved.selectedId, copy.selectedId);
      expect(saved.selected!.name, 'Changed');
      expect(
        (saved.schemeFor(originalId)!.payload['rules'] as List)
            .single['target'],
        1,
      );
      expect((saved.selected!.payload['rules'] as List).single['target'], 2);
      expect(original.schemes.length, 1);
      expect(original.selected!.name, 'Original');
    },
  );

  test('selection and default are independent and survive JSON roundtrip', () {
    final first = NamedSchemeLibrary(kind: NamedSchemeKind.mapping)
        .create(name: 'First');
    final second = first.create(name: 'Second');
    final changed = second
        .setDefault(second.selectedId!)
        .select(first.selectedId!);
    final restored = NamedSchemeLibrary.decode(changed.encode());
    expect(restored.encode(), changed.encode());
    expect(restored.selected!.name, 'First');
    expect(restored.defaultScheme!.name, 'Second');
    expect(restored.nextId, 3);
  });

  test('names are distinct ignoring case and boundary whitespace', () {
    final library = NamedSchemeLibrary(kind: NamedSchemeKind.mapping)
        .create(name: ' First ');
    expect(library.selected!.name, 'First');
    expect(() => library.create(name: 'FIRST'), throwsFormatException);
    expect(
      () => library.clone(library.selectedId!, name: ' first '),
      throwsFormatException,
    );
    final next = library.create(name: 'Second');
    expect(
      () => next.rename(next.selectedId!, ' first'),
      throwsFormatException,
    );
    expect(
      () => next.updateSelected(mapping(), name: 'First'),
      throwsFormatException,
    );
    expect(
      library.rename(library.selectedId!, 'FIRST').selected!.name,
      'FIRST',
    );
    expect(library.uniqueName('First'), 'First 2');
    expect(() => library.create(name: ' '), throwsFormatException);
    expect(() => library.create(name: 'x' * 161), throwsFormatException);
  });

  test(
    'confirmed delete falls back predictably and never reuses deleted IDs',
    () {
      final first = NamedSchemeLibrary(kind: NamedSchemeKind.mapping)
          .create(name: 'First');
      final second = first.create(name: 'Second');
      final third = second.create(name: 'Third').setDefault(second.selectedId!);
      final deletedId = third.selectedId!;
      expect(
        () => third.delete(deletedId, confirmed: false),
        throwsFormatException,
      );
      final deleted = third.delete(deletedId, confirmed: true);
      expect(deleted.selectedId, second.selectedId);
      expect(deleted.defaultId, second.selectedId);
      final next = deleted.create(name: 'Fourth');
      expect(next.selectedId, isNot(deletedId));
      final defaultDeleted = deleted.delete(
        second.selectedId!,
        confirmed: true,
      );
      expect(defaultDeleted.selectedId, first.selectedId);
      expect(defaultDeleted.defaultId, first.selectedId);
      final empty = defaultDeleted.delete(first.selectedId!, confirmed: true);
      expect(empty.schemes, isEmpty);
      expect(empty.selected, isNull);
      expect(empty.defaultScheme, isNull);
      expect(empty.create(name: 'New').selectedId, isNot(first.selectedId));
    },
  );

  test('payloads and input collections are deeply immutable snapshots', () {
    final rule = <String, Object?>{'source': '#112233', 'target': 1};
    final raw = <Map<String, Object?>>[rule];
    final library = NamedSchemeLibrary(kind: NamedSchemeKind.mapping)
        .create(name: 'One', payload: mapping(raw));
    rule['target'] = 2;
    raw.clear();
    final rules = library.selected!.payload['rules'] as List;
    expect((rules.single as Map)['target'], 1);
    expect(() => rules.clear(), throwsUnsupportedError);
    expect(() => (rules.single as Map)['target'] = 3, throwsUnsupportedError);
    expect(
      () => library.selected!.payload['rules'] = [],
      throwsUnsupportedError,
    );
    expect(() => library.schemes.clear(), throwsUnsupportedError);
    final world = NamedSchemeLibrary(kind: NamedSchemeKind.worldRules).create(
      name: 'World',
      payload: WorldRuleScheme(
        name: 'Input',
        rules: [
          WorldTileRule(patch: {'type': 1}),
        ],
      ).toJson(),
    );
    final worldRules = world.selected!.payload['rules'] as List;
    expect(
      () => (worldRules.single as Map)['patch']['type'] = 2,
      throwsUnsupportedError,
    );
    expect(() => worldRules.clear(), throwsUnsupportedError);
    expect(WorldRuleScheme.fromJson(world.selected!.payload).name, 'World');
  });

  test('world rename updates both names and retains rule semantics', () {
    final payload = WorldRuleScheme(
      name: 'World',
      rules: [
        WorldTileRule(where: {'type': 1}, patch: {'wall': 2}),
      ],
    );
    final library = NamedSchemeLibrary(kind: NamedSchemeKind.worldRules)
        .create(name: 'World', payload: payload.toJson());
    final renamed = library.rename(library.selectedId!, 'Renamed');
    final parsed = WorldRuleScheme.fromJson(renamed.selected!.payload);
    expect(parsed.name, 'Renamed');
    expect(parsed.rules.single.where, {'type': 1});
    expect(parsed.rules.single.patch, {'wall': 2});
    expect(
      NamedSchemeLibrary.decode(renamed.encode()).selected!.name,
      'Renamed',
    );
  });

  test('core builtins remain selectable and cannot be expanded or mutated', () {
    final builtin = NamedScheme(
      id: 'builtin:purify',
      name: '净化',
      kind: NamedSchemeKind.worldRules,
      payload: WorldRuleScheme(name: '净化', biomeMode: 'purify').toJson(),
      isBuiltin: true,
    );
    final library = NamedSchemeLibrary(
      kind: NamedSchemeKind.worldRules,
      schemes: [builtin],
      selectedId: builtin.id,
      defaultId: builtin.id,
    );
    expect(library.selected!.canClone, false);
    expect(() => library.clone(builtin.id), throwsFormatException);
    expect(() => library.rename(builtin.id, 'New'), throwsFormatException);
    expect(
      () => library.delete(builtin.id, confirmed: true),
      throwsFormatException,
    );
    expect(
      () => library.updateSelected(WorldRuleScheme(name: 'Draft').toJson()),
      throwsFormatException,
    );
    expect(
      library.create(name: 'Draft').select(builtin.id).defaultId,
      builtin.id,
    );
    expect(
      NamedSchemeLibrary.decode(library.encode()).selected!.isBuiltin,
      true,
    );
  });

  test('strict mapping boundary retains all valid stamp fields and order', () {
    final rules = validateMappingRules([
      {
        'source': '#ABCDEF',
        'target': '1',
        'wall': 2,
        'blockPaint': 30,
        'wallPaint': 0,
        'mode': 4,
        'version': '1.4.5.8',
      },
      {'type': 'terrain', 'source': 1, 'target': 65535, 'layer': 'wall'},
      {'type': 'terrain', 'source': '2', 'target': 3},
    ]);
    expect(rules.first, {
      'type': 'color',
      'source': '#ABCDEF',
      'target': 1,
      'wall': 2,
      'blockPaint': 30,
      'wallPaint': 0,
      'mode': 4,
      'version': '1.4.5.8',
    });
    expect(rules[1]['source'], '1');
    expect(rules[1]['layer'], 'wall');
    expect(rules.last['layer'], 'block');
  });

  test(
    'mapping import rejects malformed metadata and never drops unknown fields',
    () {
      for (final bad in [
        {'wall': -1},
        {'wall': 65536},
        {'wall': '1'},
        {'blockPaint': 31},
        {'wallPaint': -1},
        {'mode': 5},
        {'mode': 1.0},
        {'version': 326},
        {'version': ''},
        {'version': 'x' * 65},
        {'unknown': true},
        {'layer': 'wall'},
      ]) {
        expect(
          () => validateMappingRules([
            {'source': '#112233', 'target': 1, ...bad},
          ]),
          throwsFormatException,
          reason: '$bad',
        );
      }
      for (final bad in [
        {'source': '#11223', 'target': 1},
        {'source': '#112233', 'target': -1},
        {'type': 'terrain', 'source': '65536', 'target': 1},
        {'type': 'terrain', 'source': '1', 'target': 1, 'layer': 'liquid'},
      ]) {
        expect(() => validateMappingRules([bad]), throwsFormatException);
      }
      expect(
        () => validateMappingRules(
          List.filled(65536, {'source': '#112233', 'target': 1}),
        ),
        throwsFormatException,
      );
    },
  );

  test('malformed library references, kinds, fields and duplicate IDs fail atomically', () {
    final library = NamedSchemeLibrary(kind: NamedSchemeKind.mapping)
        .create(name: 'One');
    final original = library.encode();
    for (final patch in [
      {'selected_id': 'missing'},
      {'default_id': null},
      {'version': 1.0},
      {'kind': 'worldRules'},
      {'unknown': 1},
      {'next_id': 0},
      {
        'schemes': [library.selected!.toJson(), library.selected!.toJson()],
      },
    ]) {
      expect(
        () => NamedSchemeLibrary.fromJson({...library.toJson(), ...patch}),
        throwsFormatException,
        reason: '$patch',
      );
      expect(library.encode(), original);
    }
    expect(() => library.select('missing'), throwsFormatException);
    expect(() => library.setDefault('missing'), throwsFormatException);
    expect(
      () => library.create(
        name: 'Wrong',
        payload: WorldRuleScheme(name: 'Wrong').toJson(),
      ),
      throwsFormatException,
    );
  });

  test('world import uses existing predicate validation and rejects name disagreement', () {
    final library = NamedSchemeLibrary(kind: NamedSchemeKind.worldRules)
        .create(name: 'World');
    final entry = library.selected!.toJson();
    expect(
      () => NamedSchemeLibrary.fromJson({
        ...library.toJson(),
        'schemes': [
          {...entry, 'name': 'Other'},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => library.updateSelected({
        ...library.selected!.payload,
        'rules': [
          {
            'where': {'type': 1},
            'patch': {'unknown': 2},
          },
        ],
      }),
      throwsFormatException,
    );
    expect(
      () =>
          library.updateSelected({...library.selected!.payload, 'extra': true}),
      throwsFormatException,
    );
  });

  test(
    'bounded libraries reject excess count and oversized serialized input',
    () {
      final entries = List.generate(
        NamedSchemeLibrary.maxSchemes,
        (i) => NamedScheme(
          id: 'test:$i',
          name: 'Scheme $i',
          kind: NamedSchemeKind.mapping,
          payload: mapping(),
        ),
      );
      final full = NamedSchemeLibrary(
        kind: NamedSchemeKind.mapping,
        schemes: entries,
        selectedId: entries.first.id,
        defaultId: entries.first.id,
      );
      expect(() => full.create(name: 'Extra'), throwsFormatException);
      expect(full.schemes.length, NamedSchemeLibrary.maxSchemes);
      expect(
        () => NamedSchemeLibrary.decode(
          ' ' * (NamedSchemeLibrary.maxJsonBytes + 1),
        ),
        throwsFormatException,
      );
      expect(
        () => NamedSchemeLibrary.fromJson(
          jsonDecode(full.encode()) as Map<String, Object?>..['next_id'] = 1.0,
        ),
        throwsFormatException,
      );
    },
  );
}
