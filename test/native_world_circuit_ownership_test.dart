import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/native_world_circuit_bindings.dart';
import 'package:terraforge/engine/native_memory_ownership_diagnostics.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

void main() {
  final libraryPath = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  test(
    'failed output deletion retains its lease for a successful retry',
    () async {
      var deleteAttempts = 0;
      final api = NativeWorldCircuitBindings(
        DynamicLibrary.open(libraryPath!),
        deleteOutputDirectory: (directory) {
          if (++deleteAttempts == 1) {
            throw FileSystemException(
              'injected deletion failure',
              directory.path,
            );
          }
          directory.deleteSync(recursive: true);
        },
      );
      final source = File('assets/qa/synthetic-circuit.wld').absolute;
      final opened = await (api.dispatch('worldCircuitOpenSource', [
        {
          'path': source.path,
          'length': source.lengthSync(),
          'name': 'fixture.wld',
        },
      ]) as Future<Map<String, Object?>>);
      final session = opened['session'] as int;
      final save = WorldCircuitCommand.save();
      final saved = await (api.dispatch('worldCircuitCommand', [
        session,
        save.words,
        save.records,
      ]) as Future<Map<String, Object?>>);
      final output = saved['worldSource'] as Map;
      final file = File(output['path'] as String);
      final token = output['token'] as String;
      if (memoryOwnershipDiagnosticsEnabled) {
        final row = api.diagnosticOwnerSnapshot();
        expect(row['hostSessionCount'], 1);
        expect(row['hostWorldHandles'], 1);
        expect(row['hostCircuitHandles'], 1);
        expect(row['hostOutputLeases'], 1);
      }
      addTearDown(() {
        if (file.parent.existsSync()) file.parent.deleteSync(recursive: true);
      });
      api.dispatch('worldCircuitClose', [session]);
      if (memoryOwnershipDiagnosticsEnabled) {
        final row = api.diagnosticOwnerSnapshot();
        expect(row['hostSessionCount'], 0);
        expect(row['hostOpenFiles'], 0);
        expect(row['hostWorldHandles'], 0);
        expect(row['hostCircuitHandles'], 0);
        expect(row['hostOutputLeases'], 1);
      }
      expect(
        file.existsSync(),
        isTrue,
        reason: 'The output outlives its session.',
      );
      expect(
        () => api.dispatch('worldCircuitReleaseSource', [token]),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.existsSync(), isTrue);
      if (memoryOwnershipDiagnosticsEnabled) {
        expect(api.diagnosticOwnerSnapshot()['hostOutputLeases'], 1);
      }
      api.dispatch('worldCircuitReleaseSource', [token]);
      expect(file.existsSync(), isFalse);
      if (memoryOwnershipDiagnosticsEnabled) {
        expect(api.diagnosticOwnerSnapshot()['hostOutputLeases'], 0);
      }
      expect(deleteAttempts, 2);
      api.dispatch('worldCircuitReleaseSource', [token]);
      expect(
        deleteAttempts,
        2,
        reason: 'A released lease is not deleted twice.',
      );
    },
    skip: libraryPath == null,
  );
}
