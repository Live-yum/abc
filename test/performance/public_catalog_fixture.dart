import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../prefix_rules_test.dart' show prefixFixture;
import '../resource_store_test.dart' show pack;
import '../support/fusion_placement_fixture.dart' show placementCatalog;

/// Invented protocol metadata only. Version tags exercise production guards;
/// these tiny rows do not assert complete or authentic Terraria game data.
Uint8List publicPerformanceCatalog() {
  final placement = placementCatalog(), prefixes = prefixFixture();
  final preset = <String, Object?>{
    'id': 'synthetic-preset',
    'name': 'Synthetic source',
    'badge': 'Synthetic',
    'description': 'Repository-authored test rules; no game asset input.',
    'rules': [
      {
        'where': <String, Object?>{},
        'patch': {'wall': 1},
        'limit': 7,
      },
    ],
  };
  final families = <String, Object?>{
    'items': [
      ...placement.families['items']!.map((row) => row.fields),
      ...prefixes.families['items']!.map((row) => row.fields),
    ],
    'prefixes': prefixes.families['prefixes']!
        .map((row) => row.fields)
        .toList(),
    'tile-object-data': placement.families['tile-object-data']!
        .map((row) => row.fields)
        .toList(),
    'tiles': [
      {'id': '0:0', 'type': 0, 'variant': 0},
    ],
    'stable-rgb': [
      {
        'id': 0,
        'kind': 0,
        'type': 0,
        'variant': 0,
        'paint': 0,
        'rgb': [101, 67, 33],
        'stable': 1,
      },
    ],
    'bestiary': [
      {
        'id': 1,
        'persistentNpcId': 'SyntheticCreature',
        'name': 'Synthetic creature',
        'unlockRule': {
          'kind': 'kills',
          'persistentNpcId': 'SyntheticCreature',
          'killCountNeededToFullyUnlock': 50,
        },
      },
      {
        'id': 2,
        'persistentNpcId': 'SyntheticLockedCreature',
        'name': 'Synthetic locked creature',
        'unlockRule': {
          'kind': 'kills',
          'persistentNpcId': 'SyntheticLockedCreature',
          'killCountNeededToFullyUnlock': 50,
        },
      },
    ],
    'world-rule-presets': [preset],
    'player-conversion-profiles': [
      {
        'id': 326,
        'schema': 1,
        'gameVersion': '1.4.5.8',
        'sourceCommit': '0000000000000000000000000000000000000000',
        'sourceFiles': ['Synthetic test contract, not actual game data'],
        'ranges': {
          for (final field in ['hair', 'skinVariant', 'voiceVariant'])
            field: {
              'minimum': 0,
              'maximum': 7,
              'fallback': 0,
              'behavior': 'clamp',
            },
        },
      },
    ],
  };
  final files = <String, List<int>>{
    for (final entry in families.entries)
      'catalog/${entry.key}.json': utf8.encode(jsonEncode(entry.value)),
  };
  final presetHash = sha256
      .convert(files['catalog/world-rule-presets.json']!)
      .toString();
  final sourceHash = sha256.convert(utf8.encode(jsonEncode(preset))).toString();
  return pack(
    files,
    alter: (header) {
      header['gameVersion'] = '1.4.5.8';
      header['provenance'] = {
        'source': 'repository-authored-synthetic-protocol-metadata',
        'worldRulePresets': {
          'schema': 1,
          'gameVersion': '1.4.5.8',
          'inputSha256': presetHash,
          'sourceFiles': {'synthetic/rules.json': sourceHash},
        },
        'sourceObjects': {
          'local-world-rule-presets.json': presetHash,
          'synthetic/rules.json': sourceHash,
        },
      };
    },
  );
}
