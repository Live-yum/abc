import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/native_memory_ownership_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  test('owner snapshot preserves lazy worker and existing FIFO generation', () async {
    if (!memoryOwnershipDiagnosticsEnabled) {
      expect(core.diagnosticOwnerSnapshot, throwsStateError);
      return;
    }
    final baseline = await core.diagnosticOwnerSnapshot();
    expect(baseline['status'], 'worker-not-started');
    expect(baseline['workerGeneration'], isNull);
    expect(baseline['owner'], isNull);
    final engine = core.createTerraEngine();
    final bytes = await File('assets/qa/synthetic-circuit.wld').readAsBytes();
    for (var cycle = 0; cycle < 2; cycle++) {
      expect(core.createTerraEngine(), same(engine));
      final document = await engine.open(bytes, kind: 'wld');
      var closed = false;
      try {
        final opened = await core.diagnosticOwnerSnapshot();
        expect(opened['workerGeneration'], 1);
        final owner = opened['owner'] as Map;
        expect(owner['ordinaryDocumentHandles'], 1);
        expect(owner['worldCircuitBindingInitialized'], isFalse);
        expect(owner['host'], isNull);
        expect((owner['native'] as Map)['status'], 'available');
        expect(((owner['native'] as Map)['values'] as Map)
            ['nativeWorldOpenCount'], 1);
        // Issue close first, without awaiting its Future. The diagnostic must
        // follow it on the same existing owner queue rather than bypass it.
        final closing = engine.close(document);
        final pendingSnapshot = core.diagnosticOwnerSnapshot();
        await closing;
        closed = true;
        final after = await pendingSnapshot;
        expect(after['workerGeneration'], 1);
        expect(after['productionPendingAfter'], 0);
        final afterOwner = after['owner'] as Map;
        expect(afterOwner['ordinaryDocumentHandles'], 0);
        expect(afterOwner['worldCircuitBindingInitialized'], isFalse);
        expect(afterOwner['host'], isNull);
        expect(((afterOwner['native'] as Map)['values'] as Map)
            ['nativeWorldOpenCount'], 0);
      } finally {
        if (!closed) await engine.close(document);
      }
    }
  }, skip: !Platform.isLinux || library == null);
}
