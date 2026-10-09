import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:terraforge/engine/world_circuit_backend.dart';

Future<({WorldCircuitSource world, WorldCircuitSource twld})>
computerInputs() async {
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

  final result = (
    world: await input('COMPUTERRARIA_WLD', 'computerraria.wld'),
    twld: await input('COMPUTERRARIA_TWLD', 'computerraria.twld'),
  );
  if (result.world.length != 405983441 ||
      result.twld.length != 427712 ||
      (await sha256.bind(File(result.twld.path!).openRead()).first)
              .toString() !=
          'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8') {
    throw StateError(
      'This profile accepts only the pinned public Computerraria pair.',
    );
  }
  // The production owner verifies the complete WLD SHA-256 before fixed-layout
  // controls become available; no complete world bytes enter the UI isolate.
  return result;
}
