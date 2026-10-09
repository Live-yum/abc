import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../integration_test/support/profile_memory_native.dart'
    as profile_memory;
import 'performance/native_counters.dart';

class _Files implements FileGateway {
  _Files(this.bytes);
  final Uint8List bytes;
  @override
  Future<PickedFile?> pick(String kind) async => PickedFile('owner.wld', bytes);
  @override
  Future<bool> save(String name, Uint8List bytes) async => true;
}

class _CircuitFiles implements WorldCircuitFileGateway {
  _CircuitFiles(this.file);
  final File file;
  final outputPaths = <String>[];
  bool acceptSave = true;
  @override
  Future<WorldCircuitSource?> pick() async {
    return WorldCircuitSource.file(
      path: file.absolute.path,
      length: await file.length(),
      name: 'owner.wld',
    );
  }

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    expect(source.token, isNotNull);
    expect(protectedSources.single.path, file.absolute.path);
    expect(await File(source.path!).length(), greaterThan(0));
    outputPaths.add(source.path!);
    return acceptSave;
  }
}

Set<String> _scratchDirectories() => Directory.systemTemp
    .listSync()
    .whereType<Directory>()
    .where(
      (entry) => entry.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last
          .startsWith('abc-circuit-'),
    )
    .map((entry) => entry.path)
    .toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  test(
    'native shared owner remains bounded across Workspace lifecycles',
    () async {
      final info = await developer.Service.getInfo();
      final uri = info.serverUri;
      expect(
        uri,
        isNotNull,
        reason: 'Run with flutter test --enable-vmservice',
      );
      final service = await vmServiceConnectUri(
        uri!.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
      );
      addTearDown(service.dispose);
      final counters = NativeAllocationCounters(library!);
      expect(
        counters.available,
        true,
        reason: 'Build with ABC_PERF_COUNTERS=ON',
      );
      Future<Map<String, Object?>> snapshot() async {
        final vm = await service.getVM();
        final owners = <Map<String, Object?>>[];
        final representatives = <String, String>{};
        for (final ref in vm.isolates ?? <IsolateRef>[]) {
          final isolate = await service.getIsolate(ref.id!);
          owners.add({
            'id': isolate.id,
            'name': isolate.name,
            'ports': isolate.livePorts,
            'isolateGroupId': isolate.isolateGroupId,
          });
          representatives.putIfAbsent(isolate.isolateGroupId!, () => ref.id!);
        }
        final measured = await profile_memory.memorySnapshot(service: service);
        expect(measured['heapUnavailable'], isNull);
        expect(measured['sampledIsolates'], owners.length);
        expect(
          measured['sampledIsolateGroups'],
          representatives.length,
          reason: 'The production profile helper samples each shared heap once',
        );
        expect(
          measured['heapMeasurementMethod'],
          profile_memory.heapMeasurementMethod,
        );
        expect(measured['gc'], 'requested-all-isolate-groups');
        owners.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        return {
          'owners': owners,
          'isolateCount': owners.length,
          ...measured,
          'livePorts': owners.fold<int>(
            0,
            (sum, row) => sum + (row['ports'] as int),
          ),
          ...counters.snapshot(),
        };
      }

      final before = await snapshot();
      final scratchBefore = _scratchDirectories();
      final engine = createTerraEngine();
      final input = File('assets/qa/synthetic-circuit.wld');
      final original = await input.readAsBytes();
      final measurements = <Map<String, Object?>>[];
      List<Object?>? warmOwners;
      Map<String, Object?>? warmNative;
      for (var cycle = 0; cycle < 8; cycle++) {
        expect(createTerraEngine(), same(engine));
        final files = _CircuitFiles(input);
        final workspace = Workspace(
          engine: engine,
          files: _Files(original),
          worldCircuitBackend: engine as WorldCircuitBackend,
          worldCircuitFiles: files,
        );
        Future<void> action(
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await workspace.dispatch(name, args);
          expect(workspace.view.error, isEmpty, reason: name);
        }

        try {
          await action('import', {'kind': 'world'});
          expect(workspace.view.world, isNotEmpty);
          await action('newPlayer', {'name': 'Owner $cycle'});
          await workspace.close();
          // close() releases documents but the controller and shared engine can
          // reopen. It is not a process-owner shutdown operation.
          await action('import', {'kind': 'world'});
          await action('rulesOpen');
          expect(
            (workspace.view.result['rulesCircuit'] as Map)['error'],
            isEmpty,
          );
          await action('worldCircuitChooseWorld');
          await action('worldCircuitImport');
          expect((workspace.view.result['worldCircuit'] as Map)['open'], true);
          await action('worldCircuitTrigger', {'x': 2, 'y': 10, 'mask': 1});
          await action('worldCircuitStep');
          await action('worldCircuitSave');
          files.acceptSave = false;
          await action('worldCircuitSave');
          await action('worldCircuitReset');
          // Both accepted and cancelled exports must release their native leases.
          expect(files.outputPaths.length, 2);
          for (final path in files.outputPaths) {
            expect(
              File(path).existsSync(),
              false,
              reason: 'Released output lease',
            );
          }
        } finally {
          await workspace.close();
          await workspace.close();
          workspace.dispose();
        }
        expect(await input.readAsBytes(), original);
        expect(
          _scratchDirectories(),
          scratchBefore,
          reason: 'No retained session/output directories',
        );
        final current = await snapshot();
        expect(
          current['isolateCount'],
          (before['isolateCount'] as int) + 1,
          reason: 'Exactly one process-owned NativeEngine worker',
        );
        expect(
          (current['owners'] as List<Map<String, Object?>>).where(
            (row) => row['name'] == '_engineWorker',
          ),
          hasLength(1),
        );
        final ownerIdentity = (current['owners'] as List<Map<String, Object?>>)
            .map(
              (row) => {
                'id': row['id'],
                'name': row['name'],
                'ports': row['ports'],
              },
            )
            .toList();
        final liveNative = <String, Object?>{
          for (final key in [
            'nativeTotalLiveBytes',
            'nativeLiveBytes',
            'nativeBridgeLiveBytes',
            'nativeWorldOpenCount',
          ])
            key: current[key],
        };
        warmOwners ??= ownerIdentity;
        warmNative ??= liveNative;
        expect(
          ownerIdentity,
          warmOwners,
          reason: 'No per-workspace worker or port growth',
        );
        expect(
          liveNative,
          warmNative,
          reason: 'No per-workspace retained native allocation growth',
        );
        expect(current['nativeWorldOpenCount'], 0);
        measurements.add({'cycle': cycle, ...current});
        // Raw machine-readable evidence in the opt-in test runner log.
        // ignore: avoid_print
        print('NATIVE_OWNER_LIFECYCLE ${jsonEncode(measurements.last)}');
      }
      final output = Platform.environment['TERRAFORGE_LIFECYCLE_OUTPUT'];
      if (output != null) {
        await File(output).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schema': 2,
            'description': 'Real NativeEngine shared owner and Workspace lifecycle regression',
            'semantics': 'One process-owned engine isolate is intentionally retained and reused. Isolate IDs/live ports, native counters and filesystem leases establish ownership; GC heap is counted once per isolate group. Heap and RSS are observations, not stand-alone leak claims.',
            'cycles': measurements.length,
            'before': before,
            'measurements': measurements,
          }),
        );
      }
    },
    skip:
        library == null ||
            Platform.environment['TERRAFORGE_LIFECYCLE_VM'] != 'true'
        ? 'Requires counter-enabled native engine and TERRAFORGE_LIFECYCLE_VM=true with --enable-vmservice'
        : false,
  );
}
