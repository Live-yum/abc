import 'dart:convert';
import 'dart:io';

import 'package:terraforge/platform/resource_store.dart';

/// Optional local-only QA. Prints counts and hashes, never catalog contents.
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_resource_pack.dart /private/local.abcpack',
    );
    exitCode = 2;
    return;
  }
  final clock = Stopwatch()..start();
  final store = ResourceStore.importPack(File(args.single).readAsBytesSync());
  var icons = 0;
  for (final rows in store.catalog.families.values) {
    for (final row in rows) {
      if (row.iconPath != null) {
        if (store.iconBytes(row) == null) {
          throw StateError('Missing indexed icon');
        }
        icons++;
      }
      if (store.catalog.byId(row.family, row.id) != row) {
        throw StateError('ID mismatch');
      }
    }
  }
  stdout.writeln(
    jsonEncode({
      'gameVersion': store.catalog.gameVersion,
      'sha256': store.packSha256,
      'families': store.catalog.families.map(
        (key, rows) => MapEntry(key, rows.length),
      ),
      'iconReferencesVerified': icons,
      if (store.catalog.families.containsKey('stable-rgb'))
        'stableRgbCandidatesVerified': store.catalog
            .stableColorCandidates(expectedVersion: store.catalog.gameVersion)
            .length,
      'elapsedMs': clock.elapsedMilliseconds,
    }),
  );
}
