import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/prefix_rules.dart';
import 'package:terraforge/platform/resource_store.dart';

/// Opt-in validation only. Private metadata and reference outputs stay local.
void main() {
  final packPath = Platform.environment['ABC_PRIVATE_PACK'];
  test(
    'imported real prefix metadata fits scoring and preserves all tied originals',
    () {
      final catalog = ResourceStore.importPack(
        File(packPath!).readAsBytesSync(),
      ).catalog;
      final rules = PrefixRules(catalog);
      var eligibleItems = 0;
      final pools = <String>{};
      for (final row in catalog.families['items']!) {
        final id = row.numericId!;
        final eligible = rules.eligiblePrefixes(id, version: 326);
        final best = rules.bestPrefix(id, version: 326, current: 0);
        if (eligible.isEmpty) {
          expect(best, isNull, reason: 'item $id has no eligible prefix');
          continue;
        }
        eligibleItems++;
        if (row.fields['prefixPool'] is String) {
          pools.add(row.fields['prefixPool'] as String);
        }
        expect(best, isNotNull, reason: 'item $id');
        expect(best!.score.isFinite, isTrue);
        expect(best.score, greaterThan(0));
        expect(eligible, contains(best.id));
        for (final current in best.ties) {
          final retained = rules.bestPrefix(
            id,
            version: 326,
            current: current,
          )!;
          expect(
            retained.id,
            current,
            reason: 'item $id preserves tied prefix',
          );
          expect(retained.ties, contains(current));
        }
      }
      expect(eligibleItems, greaterThan(20));
      expect(pools.length, greaterThanOrEqualTo(3));
      // ignore: avoid_print
      print(
        'Verified $eligibleItems eligible items across ${pools.length} metadata pools.',
      );
      final referencePath = Platform.environment['ABC_PREFIX_REFERENCE'];
      if (referencePath != null) {
        final expected =
            jsonDecode(File(referencePath).readAsStringSync()) as List;
        final differences = <String>[];
        for (final result in expected.cast<Map>()) {
          final id = result['itemId'] as int,
              version = result['version'] as int;
          final actual = rules.bestPrefix(id, version: version, current: 0);
          if (actual?.id != result['id'] ||
              actual?.score != result['score'] ||
              jsonEncode(actual?.ties ?? []) != jsonEncode(result['ties']) ||
              jsonEncode(rules.eligiblePrefixes(id, version: version)) !=
                  jsonEncode(result['eligible'])) {
            differences.add('item $id, version $version');
          }
        }
        expect(
          differences,
          isEmpty,
          reason:
              'Reference comparison differences: ${differences.take(20).join(', ')}',
        );
        // ignore: avoid_print
        print(
          'Exact reference match for ${expected.length} item/version results.',
        );
      }
    },
    skip: packPath == null
        ? 'Set ABC_PRIVATE_PACK for private local metadata validation.'
        : false,
  );
}
