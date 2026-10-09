import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';

class _Files implements FileGateway {
  final Uint8List source;
  Uint8List? exported;
  _Files(this.source);
  @override
  Future<PickedFile?> pick(String kind) async =>
      PickedFile('circuit-synthetic.wld', Uint8List.fromList(source));
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    exported = Uint8List.fromList(bytes);
    return true;
  }
}

void main() {
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  final fixture = Platform.environment['TERRAFORGE_CIRCUIT_FIXTURE'];
  test(
    'real Workspace circuit transaction closes owners, validates save, restores undo',
    () async {
      final original = File(fixture!).readAsBytesSync(),
          files = _Files(File(fixture).readAsBytesSync());
      final engine = createTerraEngine();
      final workspace = Workspace(
        engine: engine,
        files: files,
        worldCircuitBackend: engine as WorldCircuitBackend,
      );
      Map<String, dynamic> state() => Map<String, dynamic>.from(
        workspace.view.result['worldCircuit'] as Map,
      );
      Future<void> action(
        String name, [
        Map<String, Object?> args = const {},
      ]) async {
        await workspace.dispatch(name, args);
        expect(workspace.view.error, isEmpty, reason: name);
      }

      int frame() {
        final bytes = state()['records'] as Uint8List;
        final data = ByteData.sublistView(bytes);
        for (var i = 0; i + 16 <= bytes.length; i += 16) {
          if (data.getUint32(i, Endian.little) == 3 &&
              data.getUint32(i + 4, Endian.little) == 10) {
            return data.getInt16(i + 12, Endian.little);
          }
        }
        throw StateError('Torch missing from real viewport');
      }

      try {
        await action('import', {'kind': 'world'});
        expect(workspace.view.world, isNotEmpty);
        await action('worldCircuitOpen');
        expect(state()['open'], true);
        expect(state()['devices'], 2);
        expect(frame(), 0);
        await action('worldCircuitTrigger', {'x': 2, 'y': 10, 'mask': 1});
        expect(state()['dirty'], true);
        expect(frame(), 0);
        for (var tick = 0; tick < 59; tick++) {
          await action('worldCircuitStep');
        }
        expect(frame(), 0);
        await action('worldCircuitStep');
        expect(frame(), 66);
        expect(state()['ticks'], 60);
        await action('worldCircuitSave');
        expect(state()['open'], false);
        expect(files.exported, isNotEmpty);
        expect(files.exported, isNot(original));
        expect(File(fixture).readAsBytesSync(), original);
        expect(workspace.view.world, isNotEmpty);
        // Recompile the committed candidate through the actual singleton engine.
        await action('worldCircuitOpen');
        expect(frame(), 66);
        await action('worldCircuitClose', {'discard': true});
        expect(workspace.view.world, isNotEmpty);
        await action('undo', {'canvas': 'world'});
        await action('export', {'kind': 'world'});
        expect(files.exported, original);
        await action('worldCircuitOpen');
        expect(frame(), 0);
        await action('worldCircuitTrigger', {'x': 2, 'y': 10, 'mask': 1});
        await action('worldCircuitToggle');
        final deadline = Stopwatch()..start();
        while ((state()['ticks'] as int) < 60 &&
            deadline.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        await action('worldCircuitToggle');
        expect(state()['running'], false);
        expect(state()['ticks'], greaterThanOrEqualTo(60));
        expect(
          frame(),
          66,
          reason: 'Run must refresh actual viewport without a manual query',
        );
        await action('worldCircuitClose', {'discard': true});
      } finally {
        await workspace.close();
        workspace.dispose();
      }
    },
    skip: library == null || fixture == null
        ? 'Requires native engine and generated timer/torch WLD.'
        : false,
  );
}
