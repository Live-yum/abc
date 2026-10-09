import 'dart:io';

import 'package:terraforge/engine/world_circuit_backend.dart';

Future<WorldCircuitSource> computerInput() async {
  Future<WorldCircuitSource> input(String key, String name) async {
    final path = Platform.environment[key];
    if (path == null || path.isEmpty) {
      throw StateError('Explicit $key is required.');
    }
    final file = File(path);
    return WorldCircuitSource.file(
      path: file.absolute.path,
      length: await file.length(),
      name: name,
    );
  }

  final result = await input('COMPUTERRARIA_WLD', 'computerraria.wld');
  if (result.length != 405983441) {
    throw StateError(
      'This profile accepts only the pinned public Computerraria WLD.',
    );
  }
  // The production owner verifies the complete WLD SHA-256 before fixed-layout
  // controls become available; no complete world bytes enter the UI isolate.
  return result;
}
