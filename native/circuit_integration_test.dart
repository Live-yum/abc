import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'circuit_edit_smoke.dart' as sandbox;
import 'world_circuit_fragments_smoke.dart' as fragments;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual native sandbox network, route and clipboard integration',
    () async {
      await sandbox.main();
    },
  );
  test('actual native world fragments and safe object stamping', () async {
    final fixture =
        Platform.environment['TERRAFORGE_FRAGMENT_FIXTURE'] ??
        'build/fragments.wld';
    expect(
      File(fixture).existsSync(),
      isTrue,
      reason: 'Generate native/generate_circuit_fragment_fixture.py first.',
    );
    final output = Platform.environment['TERRAFORGE_FRAGMENT_PROOF_DIR'];
    await fragments.main([fixture, ?output]);
  });
}
