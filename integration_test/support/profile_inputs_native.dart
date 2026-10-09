import 'dart:convert';
import 'dart:io';

import 'package:terraforge/platform/files.dart';

/// Native developer harness only. No discovery, uploads or production picker
/// bypass: an operator must explicitly provide this manifest to the test process.
Future<List<({String kind, PickedFile file})>> localInputs() async {
  final path = Platform.environment['TERRA_PERF_LOCAL_INPUTS'];
  if (path == null || path.isEmpty) return [];
  if (Platform.environment['GITHUB_ACTIONS'] == 'true') {
    throw StateError('Personal local inputs are disabled in public CI.');
  }
  final decoded = jsonDecode(await File(path).readAsString());
  if (decoded is! List) {
    throw const FormatException('Expected local input array');
  }
  final result = <({String kind, PickedFile file})>[];
  for (final row in decoded) {
    if (row is! Map ||
        !const ['world', 'player', 'map'].contains(row['kind']) ||
        row['path'] is! String) {
      throw const FormatException(
        'Each local input needs kind world/player/map and path',
      );
    }
    final kind = row['kind'] as String, file = File(row['path'] as String);
    final limit = (kind == 'player' ? 32 : 128) * 1024 * 1024;
    if (await file.length() > limit) {
      throw const FormatException(
        'Local input exceeds production import limit',
      );
    }
    final extension = switch (kind) {
      'world' => 'wld',
      'player' => 'plr',
      _ => 'map',
    };
    result.add((
      kind: kind,
      file: PickedFile(
        'local-${result.length}.$extension',
        await file.readAsBytes(),
      ),
    ));
  }
  return result;
}
