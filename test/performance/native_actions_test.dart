// Opt in: ABC_PERF_REPORT=build/performance/native-actions.json plus native lib.
// Real personal fixtures are accepted only in local/soak tier and never copied.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/player_conversion.dart';
import 'package:terraforge/domain/world_rules.dart';
import 'package:terraforge/engine/circuit_backend.dart';
import 'package:terraforge/engine/circuit_rules_backend.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/player_projection_backend.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/platform/vault_native.dart';

import 'measurements.dart';
import 'native_counters.dart';
import '../../integration_test/support/profile_memory_native.dart' as vm_memory;
import '../resource_store_test.dart' as resource_fixtures;
import '../achievements_test.dart' as achievement_fixtures;

import 'package:terraforge/domain/achievements.dart';
import 'package:terraforge/domain/bestiary_tools.dart';
import 'package:terraforge/domain/world_rule_presets.dart';

class _Fixture {
  final String id, kind;
  final Uint8List bytes;
  _Fixture(this.id, this.kind, this.bytes);
}

class _Files implements FileGateway {
  PickedFile? next;
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => next;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = Uint8List.fromList(bytes);
    return true;
  }
}

/// Observe actual document ownership without replacing the native engine.
class _TrackedEngine implements TerraEngine, CreatablePlayerEngine {
  final TerraEngine engine;
  final Measurements bench;
  _TrackedEngine(this.engine, this.bench);
  String key(EngineDocument d) => '${d.kind}:${d.handle}';
  @override
  Future<EngineDocument> open(Uint8List bytes, {required String kind}) async {
    final doc = await engine.open(bytes, kind: kind);
    expect(bench.owners.add(key(doc)), isTrue);
    return doc;
  }

  @override
  Future<EngineDocument> createPlayer(String name) async {
    final doc = await (engine as CreatablePlayerEngine).createPlayer(name);
    expect(bench.owners.add(key(doc)), isTrue);
    return doc;
  }

  @override
  Future<void> close(EngineDocument doc) async {
    await engine.close(doc);
    expect(bench.owners.remove(key(doc)), isTrue);
  }

  @override
  Future<Map<String, dynamic>> inspect(EngineDocument doc) =>
      engine.inspect(doc);
  @override
  Future<void> mutate(
    EngineDocument doc,
    String operation,
    Map<String, dynamic> args,
  ) => engine.mutate(doc, operation, args);
  @override
  Future<Uint8List> save(EngineDocument doc) => engine.save(doc);
  @override
  Future<Uint8List?> preview(EngineDocument doc) => engine.preview(doc);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['ABC_PERF_REPORT'];
  test(
    'measured native operations preserve correctness and release every owner',
    () async {
      final bench = Measurements();
      bench.journal(output!);
      final counters = NativeAllocationCounters(
        Platform.environment['TERRAFORGE_ENGINE_LIBRARY']!,
      );
      bench.nativeMemory = counters.snapshot;
      final gcDiagnostic =
          Platform.environment['ABC_PERF_GC_DIAGNOSTICS'] == '1';
      (bench.report['methodology']
              as Map<String, Object?>)['gcDiagnosticEnabled'] =
          gcDiagnostic;
      (bench.report['toolchain']
              as Map<String, Object?>)['nativeBuildCompiler'] =
          counters.compiler ?? 'unknown';
      (bench.report['methodology'] as Map<String, Object?>)['nativeCounters'] = 'Optional ABC_PERF_COUNTERS ABI, read only after serialized engine calls finish. Native live includes persistent tx roots; excludes allocator headers, libc, QuickJS and Dart heap. Values saturate at UINT32_MAX. Peak is lifetime high-water, not live allocation.';
      expect(bench.cycles, greaterThanOrEqualTo(3));
      expect(bench.warmup, greaterThanOrEqualTo(1));
      final native = createTerraEngine(),
          engine = _TrackedEngine(native, bench);
      final region = native as RegionBackend;
      final tcw = native as WorldCircuitBackend;
      final rules = native as CircuitRulesBackend;
      final fixtures = [
        _Fixture(
          'synthetic-circuit',
          'wld',
          await File('assets/qa/synthetic-circuit.wld').readAsBytes(),
        ),
        _Fixture(
          'synthetic-objects',
          'wld',
          await File('assets/qa/synthetic-objects.wld').readAsBytes(),
        ),
      ];
      for (final spec in [
        ['ABC_PERF_WORLD', 'private-world-1', 'wld'],
        ['ABC_PERF_WORLD2', 'private-world-2', 'wld'],
        ['ABC_PERF_PLAYER', 'private-player-1', 'plr'],
      ]) {
        final file = Platform.environment[spec[0]];
        if (file != null) {
          fixtures.add(
            _Fixture(spec[1], spec[2], await File(file).readAsBytes()),
          );
        }
      }
      final scaled = Platform.environment['ABC_PERF_SYNTHETIC_WORLD'];
      if (scaled != null) {
        fixtures.add(
          _Fixture(
            'synthetic-scaled-world',
            'wld',
            await File(scaled).readAsBytes(),
          ),
        );
      }
      bench.fixture(
        'synthetic-canvas',
        'project',
        32 * 24 * 4,
        sha256: sha256.convert(Uint8List(32 * 24 * 4)).toString(),
      );
      bench.fixture(
        'synthetic-circuit-rules',
        'circuit',
        0,
        sha256: sha256.convert(Uint8List(0)).toString(),
      );
      bench.fixture(
        'synthetic-achievements',
        'achievements',
        achievement_fixtures.encrypt(achievement_fixtures.fixture()).length,
        sha256: sha256
            .convert(
              achievement_fixtures.encrypt(achievement_fixtures.fixture()),
            )
            .toString(),
      );
      final fresh = await engine.createPlayer('Benchmark synthetic');
      fixtures.add(
        _Fixture('synthetic-player-v326', 'plr', await engine.save(fresh)),
      );
      await engine.close(fresh);
      for (final f in fixtures) {
        bench.fixture(
          f.id,
          f.kind,
          f.bytes.length,
          private: f.id.startsWith('private-'),
          sha256: sha256.convert(f.bytes).toString(),
        );
      }
      final packPath = Platform.environment['ABC_PRIVATE_PACK'];
      final pack = packPath == null ? null : await File(packPath).readAsBytes();
      final syntheticPack = resource_fixtures.pack(
        resource_fixtures.catalogFiles(),
      );
      bench.fixture(
        'synthetic-resource-pack',
        'resources',
        syntheticPack.length,
        sha256: sha256.convert(syntheticPack).toString(),
      );
      if (pack != null) {
        bench.fixture(
          'private-resource-pack',
          'resources',
          pack.length,
          private: true,
          sha256: sha256.convert(pack).toString(),
        );
      }
      (bench.report['gaps'] as List<String>).addAll([
        'MAP format has a separate verified codec/performance report.',
        'Flutter test debug integration timing is not a profile/release frame rate result.',
        'Input fixtures are loaded before timing: OS file-picker interaction and source-disk reads are excluded. Native vault disk I/O is measured separately.',
        'Dart live heap requires explicit ABC_PERF_GC_DIAGNOSTICS=1 and an enabled VM service. Mobile memory pressure is unmeasured; RSS high-water is not a leak verdict.',
        if (!counters.available) 'Optional native allocator counters are absent; build with ABC_PERF_COUNTERS=ON to observe C live payload bytes.',
        if (pack == null) 'No verified resource pack supplied: catalog-backed best-prefix/unlock/conversion actions are not measured.',
        if (!fixtures.any((f) => f.id == 'private-player-1'))
          'Real PLR missing; generated synthetic v326 player only.',
        if (!fixtures.any((f) => f.id.startsWith('private-world'))) 'Modern bestiary source missing: public WLD fixtures are v139 and do not have writable bestiary sections.',
      ]);
      Future<T> measure<T>(
        String id,
        _Fixture f,
        Future<T> Function() action,
      ) => bench.measure(id, f.id, f.bytes.length, action);
      final temp = await Directory.systemTemp.createTemp('abc-performance-');
      final vault = NativeLocalVault(
        directory: () async => Directory('${temp.path}/vault'),
      );
      final rulesSource = File('assets/private/circuit_rules_native.js')
          .readAsBytesSync();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler('flutter/assets', (message) async {
        final name = utf8.decode(
          message!.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        );
        return name == 'assets/private/circuit_rules_native.js'
            ? ByteData.sublistView(rulesSource)
            : null;
      });

      Future<void> documentCycle(_Fixture f) async {
        EngineDocument? doc = await measure(
          '${f.kind}.open',
          f,
          () => engine.open(f.bytes, kind: f.kind),
        );
        if (counters.available) {
          expect(
            counters.snapshot()['nativeTotalLiveBytes'],
            greaterThan(0),
            reason: 'Test-only counters must observe the actual live owner',
          );
          if (f.kind == 'wld') {
            expect(counters.snapshot()['nativeWorldOpenCount'], 1);
          }
        }
        try {
          final before = await measure(
            '${f.kind}.inspect',
            f,
            () => engine.inspect(doc!),
          );
          final info = (bench.report['fixtures'] as List)
              .cast<Map<String, Object?>>()
              .firstWhere((x) => x['id'] == f.id);
          info.addAll(
            f.kind == 'wld'
                ? {
                    'formatVersion': before['format']['version'],
                    'width': before['header']['maxTilesX'],
                    'height': before['header']['maxTilesY'],
                  }
                : {'formatVersion': before['version']},
          );
          expect(
            await measure(
              '${f.kind}.untouched-export',
              f,
              () => engine.save(doc!),
            ),
            f.bytes,
          );
          if (f.kind == 'wld') {
            final png = await measure(
              'wld.preview',
              f,
              () => engine.preview(doc!),
            );
            expect(png!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
            await measure(
              'wld.header-edit',
              f,
              () => engine.mutate(doc!, 'header_patch', {
                'patch': {'worldName': 'Benchmark fixture'},
              }),
            );
            expect(
              (await engine.inspect(doc!))['header']['worldName'],
              'Benchmark fixture',
            );
            final chests = jsonDecode(jsonEncode(before['chests'])) as List;
            if (chests.isNotEmpty) {
              chests.first['name'] = 'Benchmark chest';
              await measure(
                'wld.chest-edit',
                f,
                () => engine.mutate(doc!, 'replace_chests', {'chests': chests}),
              );
              expect(
                (await engine.inspect(doc))['chests'][0]['name'],
                'Benchmark chest',
              );
            }
            if ((before['format']['version'] as num) >= 210) {
              final bestiary = jsonDecode(
                jsonEncode(before['bestiary']),
              ) as Map<String, dynamic>;
              bestiary['kills'] = [
                ...(bestiary['kills'] as List).where(
                  (x) => x['persistentNpcId'] != 'abc-benchmark',
                ),
                {'persistentNpcId': 'abc-benchmark', 'killCount': 7},
              ];
              await measure(
                'wld.bestiary-edit',
                f,
                () => engine.mutate(doc!, 'replace_bestiary', bestiary),
              );
              expect(
                ((await engine.inspect(doc))['bestiary']['kills'] as List).any(
                  (x) =>
                      x['persistentNpcId'] == 'abc-benchmark' &&
                      x['killCount'] == 7,
                ),
                isTrue,
              );
            }
          } else {
            await measure(
              'plr.attribute-edit',
              f,
              () => engine.mutate(doc!, 'player_patch', {
                'patch': {'statLife': 120, 'statLifeMax': 120},
              }),
            );
            final inventory =
                jsonDecode(jsonEncode(before['inventory'])) as List;
            inventory[0] = {
              ...inventory[0] as Map,
              'itemType': 8,
              'stack': 50,
              'prefix': 0,
            };
            await measure(
              'plr.inventory-edit',
              f,
              () => engine.mutate(doc!, 'player_patch', {
                'patch': {'inventory': inventory},
              }),
            );
            expect((await engine.inspect(doc!))['inventory'][0]['stack'], 50);
          }
          await measure(
            '${f.kind}.reject-mutation',
            f,
            () => expectLater(
              engine.mutate(doc!, 'unknown_operation', {}),
              throwsA(isA<EngineException>()),
            ),
          );
          final bytes = await measure(
            '${f.kind}.export',
            f,
            () => engine.save(doc!),
          );
          await measure('${f.kind}.close', f, () => engine.close(doc!));
          doc = null;
          doc = await measure(
            '${f.kind}.reopen',
            f,
            () => engine.open(bytes, kind: f.kind),
          );
          final checked = await engine.inspect(doc!);
          expect(
            f.kind == 'wld'
                ? checked['header']['worldName']
                : checked['statLife'],
            f.kind == 'wld' ? 'Benchmark fixture' : 120,
          );
        } finally {
          if (doc != null) {
            await measure('${f.kind}.close', f, () => engine.close(doc!));
          }
        }
      }

      Future<void> workspaceCycle(_Fixture f) async {
        final files = _Files()..next = PickedFile('fixture.wld', f.bytes);
        final app = Workspace(
          engine: engine,
          files: files,
          regionBackend: region,
          circuitBackend: native as CircuitBackend,
          worldCircuitBackend: tcw,
          playerProjectionBackend: native as PlayerProjectionBackend,
        );
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
          bool rejected = false,
        ]) async {
          await measure(
            'workspace.$id',
            id.startsWith('plr.') ? fixtures.last : f,
            () => app.dispatch(name, args),
          );
          expect(app.view.error.isNotEmpty, rejected, reason: 'workspace.$id');
        }

        try {
          await action('wld.import', 'import', {'kind': 'world'});
          await action('wld.header-edit', 'stageWorld', {
            'field': 'name',
            'value': 'Benchmark workspace',
          });
          expect(app.view.world['name'], 'Benchmark workspace');
          await action('wld.reject-edit', 'stageWorld', {
            'field': 'worldName',
            'value': 123,
          }, true);
          expect(app.view.world['name'], 'Benchmark workspace');
          await action('wld.undo', 'undo', {'canvas': 'world'});
          await action('wld.export', 'export', {'kind': 'world'});
          expect(files.output, f.bytes);
          await action('wld.redo', 'redo', {'canvas': 'world'});
          expect(app.view.world['name'], 'Benchmark workspace');
          await action('wld.undo', 'undo', {'canvas': 'world'});
          await action('wld.overlay', 'worldOverlay', {
            'x': 1,
            'y': 1,
            'width': 2,
            'height': 2,
          });
          expect(app.view.worldOverlay, isNotNull);
          await action('region.load', 'fusionRegion', {
            'x': 1,
            'y': 1,
            'width': 2,
            'height': 2,
          });
          expect(app.view.region!.recordCount, 4);
          await action('terrain.mapping', 'mappingSave', {
            'rules': [
              {'type': 'terrain', 'layer': 'block', 'source': '1', 'target': 0},
              {'type': 'terrain', 'layer': 'wall', 'source': '0', 'target': 3},
            ],
          });
          await action('terrain.preview', 'terrainPreview');
          await action('terrain.apply', 'terrainApply', {'confirmed': true});
          expect(app.view.region!.cellAt(0, 0)!['wall'], 3);
          await action('region.undo', 'undo', {'canvas': 'fusion'});
          await action('region.redo', 'redo', {'canvas': 'fusion'});
          await action('region.write', 'write', {
            'source': 'fusion',
            'x': 1,
            'y': 1,
            'mode': 'replace',
            'overwrite': true,
          });
          await action('wld.undo', 'undo', {'canvas': 'world'});
          final scheme = WorldRuleScheme(
            name: 'Benchmark rule',
            rules: [
              WorldTileRule(
                where: {'type': 1, 'wire_red': false},
                patch: {'wall': 2, 'wire_red': true},
                limit: 1,
              ),
            ],
          );
          await action('rules.preview', 'worldRulesPreview', {
            'scheme': scheme.toJson(),
          });
          await action('rules.apply', 'worldRulesApply', {
            'scheme': scheme.toJson(),
            'confirmed': true,
          });
          await action('wld.undo', 'undo', {'canvas': 'world'});
          await action('wld.export', 'export', {'kind': 'world'});
          expect(files.output, f.bytes);
          await action('tcw.open', 'worldCircuitOpen');
          await action('tcw.trigger', 'worldCircuitTrigger', {
            'x': 2,
            'y': 10,
            'mask': 1,
          });
          await action('tcw.tick', 'worldCircuitStep');
          await action('tcw.reset', 'worldCircuitReset');
          expect((app.view.result['worldCircuit'] as Map)['ticks'], 0);
          await action('tcw.viewport', 'worldCircuitViewport', {
            'x': 0,
            'y': 0,
            'width': 7,
            'height': 32,
          });
          await action('tcw.run-start', 'worldCircuitToggle');
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await action('tcw.run-stop', 'worldCircuitToggle');
          await action('tcw.save', 'worldCircuitSave');
          expect((app.view.result['worldCircuit'] as Map)['open'], false);
          await action('tcw.reopen', 'worldCircuitOpen');
          await action('tcw.close', 'worldCircuitClose', {'discard': true});
          await action('plr.new', 'newPlayer', {'name': 'Benchmark player'});
          await action('plr.attribute-edit', 'stagePlayer', {
            'field': 'statLife',
            'value': 120,
          });
          await action('plr.inventory-edit', 'stageInventory', {
            'slot': 0,
            'itemId': 8,
            'quantity': 50,
            'prefix': 0,
          });
          await action('plr.slot-edit', 'playerSlotEdit', {
            'group': 'inventory',
            'index': 0,
            'slot': {
              'itemType': 8,
              'stack': 25,
              'prefix': 0,
              'favorited': true,
            },
          });
          await action('plr.undo', 'undo', {'canvas': 'player'});
          await action('plr.redo', 'redo', {'canvas': 'player'});
          await action('plr.export', 'export', {'kind': 'player'});
          final reopened = await engine.open(files.output!, kind: 'plr');
          expect(
            (await engine.inspect(reopened))['inventory'][0]['favorited'],
            true,
          );
          await engine.close(reopened);
        } finally {
          await measure('workspace.close', f, app.close);
          app.dispose();
        }
      }

      Future<void> regionCycle() async {
        final f = fixtures[0], bytes = f.bytes;
        final records = await measure(
          'region.read',
          f,
          () => region.readRegion(bytes, 1, 2, 2, 3),
        );
        expect(records.length, 192);
        ByteData.sublistView(records).setUint32(16, 2, Endian.little);
        final candidate = await measure(
          'region.replace',
          f,
          () => region.replaceRegion(bytes, 1, 2, 2, 3, records),
        );
        expect(await region.readRegion(candidate, 1, 2, 2, 3), records);
        final stamped = await measure(
          'region.stamp',
          f,
          () => region.regionOperation(bytes, 'stamp_tiles', {
            'x': 2,
            'y': 4,
            'width': 2,
            'height': 3,
            'recordCount': 6,
            'recordSourceId': 2,
            'mode': 'overlay',
          }, records: records),
        );
        expect(await region.readRegion(stamped, 2, 4, 2, 3), records);
        final maps = Uint8List(24)
          ..[10] = 3
          ..[16] = 1
          ..[22] = 1;
        final painted = await measure(
          'pixel.write',
          f,
          () => region.writeIndexedPixels(
            bytes,
            2,
            3,
            2,
            2,
            maps,
            Uint16List.fromList([1, 0, 0, 1]),
          ),
        );
        expect(
          ByteData.sublistView(await region.readRegion(painted, 2, 3, 1, 1))
                  .getUint32(8, Endian.little) &
              65535,
          1,
        );
        expect(
          await measure(
            'pixel.match',
            f,
            () => region.matchColors(
              Uint32List.fromList([0xfe0000, 0x0000fe]),
              Uint32List.fromList([0xff0000, 0x0000ff]),
              Uint32List.fromList([0, 0]),
            ),
          ),
          [0, 1],
        );
        for (final mode in WorldRuleScheme.builtinModes) {
          final changed = await measure(
            'rules.biome-$mode',
            f,
            () => region.regionOperation(bytes, 'batch_update_tiles', {
              'biome_mode': mode,
            }),
          );
          expect(
            (await region.readRegion(changed, 0, 0, 7, 32)).length,
            224 * 32,
          );
        }
        await measure(
          'region.reject-recover',
          f,
          () => expectLater(
            region.replaceRegion(bytes, 1, 2, 2, 3, Uint8List(32)),
            throwsA(isA<EngineException>()),
          ),
        );
        final o = fixtures[1],
            companion = await measure(
              'region.objects',
              o,
              () => region.readRegionObjects(o.bytes, 1, 2, 8, 3),
            );
        expect(companion.length, greaterThan(32));
        final r = await region.readRegion(o.bytes, 1, 2, 8, 3);
        final pasted = await measure(
          'region.stamp-objects',
          o,
          () => region.regionOperation(
            o.bytes,
            'stamp_tiles',
            {
              'x': 1,
              'y': 10,
              'width': 8,
              'height': 3,
              'recordCount': 24,
              'recordSourceId': 2,
              'objectSourceId': 3,
              'objectCount': 3,
              'objectBytes': companion.length,
              'mode': 'overlay',
            },
            records: r,
            objects: companion,
          ),
        );
        expect(
          (await region.readRegionObjects(pasted, 1, 10, 8, 3)).sublist(32),
          companion.sublist(32),
        );
      }

      Future<void> tcwCycle() async {
        final f = fixtures[0];
        int? session;
        Future<WorldCircuitResult> command(WorldCircuitCommand c) =>
            tcw.commandWorldCircuit(session!, c);
        Future<int> frame() async =>
            ByteData.sublistView(
              (await command(WorldCircuitCommand.viewport(3, 10, 1, 1)))
                  .records,
            ).getUint32(12, Endian.little) &
            65535;
        try {
          session = (await measure(
            'tcw.open',
            f,
            () => tcw.openWorldCircuit(f.bytes),
          )).session;
          bench.owners.add('tcw:$session');
          expect(await measure('tcw.viewport', f, frame), 0);
          await measure(
            'tcw.trigger',
            f,
            () => command(WorldCircuitCommand.trigger(2, 10, mask: 1)),
          );
          await measure(
            'tcw.tick60',
            f,
            () => command(WorldCircuitCommand.ticks(60)),
          );
          expect(await frame(), 66);
          final saved = await measure(
            'tcw.export',
            f,
            () => command(WorldCircuitCommand.save()),
          );
          await measure('tcw.close', f, () => tcw.closeWorldCircuit(session!));
          bench.owners.remove('tcw:$session');
          session = null;
          session = (await measure(
            'tcw.reopen',
            f,
            () => tcw.openWorldCircuit(saved.world!),
          )).session;
          bench.owners.add('tcw:$session');
          expect(await frame(), 66);
        } finally {
          if (session != null) {
            await tcw.closeWorldCircuit(session);
            bench.owners.remove('tcw:$session');
          }
        }
        await measure(
          'tcw.reject-recover',
          f,
          () => expectLater(
            tcw.openWorldCircuit(Uint8List.fromList([1, 2, 3])),
            throwsA(isA<EngineException>()),
          ),
        );
      }

      Future<void> fragmentCycle() async {
        final source = await region.regionOperation(
          fixtures[0].bytes,
          'batch_update_tiles',
          {
            'rules': [
              {
                'where': <String, Object?>{},
                'patch': {'is_active': false},
              },
            ],
          },
        );
        final f = _Fixture('synthetic-wire-fragment', 'wld', source),
            files = _Files()..next = PickedFile('circuit.wld', source);
        if (!(bench.report['fixtures'] as List).any((x) => x['id'] == f.id)) {
          bench.fixture(
            f.id,
            f.kind,
            source.length,
            sha256: sha256.convert(source).toString(),
          );
        }
        final app = Workspace(
          engine: engine,
          files: files,
          worldCircuitBackend: tcw,
        );
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await measure('workspace.$id', f, () => app.dispatch(name, args));
          expect(app.view.error, isEmpty, reason: '$id: ${app.view.error}');
        }

        try {
          await action('fragments.import', 'import', {'kind': 'world'});
          await action('fragments.open', 'worldCircuitOpen');
          await action('fragments.list', 'worldCircuitFragments');
          final items =
              ((app.view.result['worldCircuit'] as Map)['fragments']
                      as Map)['items']
                  as List;
          expect(items, isNotEmpty);
          await action('fragments.extract', 'worldCircuitExtract', {
            'id': (items.first as Map)['id'],
          });
          expect(app.view.region!.recordCount, greaterThan(0));
          await action('fragments.close', 'worldCircuitClose');
          await action('fragments.export', 'export', {'kind': 'world'});
          expect(files.output, source);
        } finally {
          await app.close();
          app.dispose();
        }
      }

      Future<void> privateCatalogCycle() async {
        final modern = fixtures
            .where((f) => f.id == 'private-world-2')
            .firstOrNull;
        if (pack == null || modern == null) return;
        final f = modern,
            files = _Files()..next = PickedFile('resources.abcpack', pack);
        var measurementFixture = _Fixture(
          'private-resource-pack',
          'resources',
          pack,
        );
        final app = Workspace(
          engine: engine,
          files: files,
          regionBackend: region,
          worldCircuitBackend: tcw,
          playerProjectionBackend: native as PlayerProjectionBackend,
        );
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await measure(
            'workspace.$id',
            measurementFixture,
            () => app.dispatch(name, args),
          );
          expect(app.view.error, isEmpty, reason: '$id: ${app.view.error}');
        }

        try {
          await action('catalog.import', 'import', {'kind': 'resources'});
          measurementFixture = f;
          files.next = PickedFile('world.wld', f.bytes);
          await action('catalog.world-import', 'import', {'kind': 'world'});
          final raw = Map<String, Object?>.from(
            app.view.world['bestiary'] as Map,
          );
          await action('bestiary.patch', 'stageBestiary', {
            'patch': {
              'kills': [
                ...raw['kills'] as List,
                {'persistentNpcId': 'abc-benchmark-unknown', 'killCount': 7},
              ],
            },
          });
          final known = BestiaryTools.entries(
            Map<String, Object?>.from(app.view.world['bestiary'] as Map),
            app.view.resources!.catalog,
          ).firstWhere((x) => x.kind == 'kills' && x.editable);
          await action('bestiary.entry', 'bestiaryEntry', {
            'id': known.id,
            'kind': 'kills',
            'value': 17,
          });
          await action('bestiary.unlock', 'bestiaryUnlockKnown', {
            'confirmed': true,
          });
          expect(
            ((app.view.world['bestiary'] as Map)['kills'] as List).any(
              (x) =>
                  x['persistentNpcId'] == 'abc-benchmark-unknown' &&
                  x['killCount'] == 7,
            ),
            isTrue,
          );
          await action('chests.catalog-slot', 'stageChest', {
            'index': 0,
            'slot': 0,
            'itemId': 1,
            'quantity': 1,
            'prefix': 0,
          });
          await action('chests.best-prefix', 'chestBestPrefixes', {
            'index': 0,
            'confirmed': true,
          });
          final presets = WorldRulePresets.fromCatalog(
            app.view.resources!.catalog,
            expectedVersion: '1.4.5.8',
          );
          expect(presets.presets, isNotEmpty);
          await action('rules.preset-clone', 'worldPresetClone', {
            'id': presets.presets.first.id,
            'name': 'Benchmark copied preset',
          });
          await action('pixel.prepare-canvas', 'resize', {
            'canvas': 'pixel',
            'width': 2,
            'height': 2,
          });
          await action('pixel.prepare-paint', 'paint', {
            'canvas': 'pixel',
            'x': 0,
            'y': 0,
            'color': 0xff654321,
          });
          await action('pixel.match', 'pixelMatch', {'flags': 8});
          expect(app.view.mapping, isNotEmpty);
          await action('placement.region-load', 'fusionRegion', {
            'x': 100,
            'y': 20,
            'width': 6,
            'height': 6,
          });
          final before = app.view.region!.records;
          final intent = {
            'itemId': 1,
            'variantIndex': 0,
            'display': true,
            'x': 1,
            'y': 1,
          };
          await action('placement.stage', 'fusionPlace', intent);
          expect(app.view.region!.objectCount, 1);
          await action('placement.discard', 'fusionDiscardPlacement');
          expect(app.view.region!.records, before);
          await action('placement.restage', 'fusionPlace', intent);
          await action('placement.insert', 'fusionInsert', {'confirmed': true});
          expect(app.view.result['fusionPlacement'], isNull);
          await action('placement.undo', 'undo', {'canvas': 'world'});
          final player =
              fixtures.where((f) => f.id == 'private-player-1').firstOrNull ??
              fixtures.last;
          measurementFixture = player;
          files.next = PickedFile('player.plr', player.bytes);
          await action('catalog.player-import', 'import', {'kind': 'player'});
          await action('player.catalog-slot', 'playerSlotEdit', {
            'group': 'inventory',
            'index': 0,
            'slot': {'itemType': 1, 'stack': 1, 'prefix': 0, 'favorited': true},
          });
          await action('player.best-prefix', 'playerBestPrefixes', {
            'groups': ['inventory'],
            'confirmed': true,
          });
          await action('player.catalog-export', 'export', {'kind': 'player'});
          final checked = await engine.open(files.output!, kind: 'plr');
          try {
            expect(
              (await engine.inspect(checked))['inventory'][0]['favorited'],
              true,
            );
          } finally {
            await engine.close(checked);
          }
          final blank = await engine.open(fixtures.last.bytes, kind: 'plr');
          late Uint8List legacy;
          try {
            legacy = await (native as PlayerProjectionBackend).projectPlayer(
              PlayerConversion.prepare(
                await engine.inspect(blank),
                279,
              ).candidate,
            );
          } finally {
            await engine.close(blank);
          }
          measurementFixture = _Fixture(
            'synthetic-conversion-v279',
            'plr',
            legacy,
          );
          if (!(bench.report['fixtures'] as List).any(
            (x) => x['id'] == measurementFixture.id,
          )) {
            bench.fixture(
              measurementFixture.id,
              measurementFixture.kind,
              legacy.length,
              sha256: sha256.convert(legacy).toString(),
            );
          }
          files.next = PickedFile('legacy.plr', legacy);
          await action('conversion.import', 'import', {'kind': 'player'});
          await action('conversion.prepare', 'preparePlayerConversion', {
            'target': 326,
          });
          await action('conversion.cancel', 'cancelPlayerConversion');
          await action('conversion.reprepare', 'preparePlayerConversion', {
            'target': 326,
          });
          await action('conversion.apply', 'applyPlayerConversion', {
            'confirmed': true,
          });
          expect(app.view.player['version'], 326);
          await action('conversion.undo', 'undo', {'canvas': 'player'});
          expect(app.view.player['version'], 279);
        } finally {
          await app.close();
          app.dispose();
        }
      }

      Future<void> workspaceObjectsCycle() async {
        final f = fixtures[1],
            files = _Files()..next = PickedFile('objects.wld', f.bytes);
        final app = Workspace(
          engine: engine,
          files: files,
          regionBackend: region,
          circuitBackend: native as CircuitBackend,
        );
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
          bool rejected = false,
        ]) async {
          await measure('workspace.$id', f, () => app.dispatch(name, args));
          expect(
            app.view.error.isNotEmpty,
            rejected,
            reason: '$id: ${app.view.error}',
          );
        }

        try {
          await action('objects.import', 'import', {'kind': 'world'});
          await action('chests.rename', 'stageChest', {
            'index': 0,
            'name': 'Benchmark chest',
          });
          expect(
            (app.view.world['chests'] as List).first['name'],
            'Benchmark chest',
          );
          await action('chests.slot-decrease', 'stageChest', {
            'index': 0,
            'slot': 0,
            'itemId': 8,
            'quantity': 5,
          });
          expect(
            (app.view.world['chests'] as List).first['items'][0]['stack'],
            5,
          );
          await action('chests.organize', 'chestOrganize', {'index': 0});
          await action('chests.clear', 'chestClear', {
            'index': 0,
            'confirmed': true,
          });
          expect(
            ((app.view.world['chests'] as List).first['items'] as List).every(
              (x) => x == null,
            ),
            isTrue,
          );
          // Restore the original through actual undo, independent of whether
          // organize was a no-op for this one-item synthetic chest.
          while (app.view.result['worldCanUndo'] == true) {
            await action('chests.undo', 'undo', {'canvas': 'world'});
          }
          await action('objects.export', 'export', {'kind': 'world'});
          expect(files.output, f.bytes);
          await action('markers.add', 'addMarker', {'itemId': 8});
          await action('markers.toggle', 'markerToggle', {
            'kind': 'tile',
            'id': 55,
          });
          await action('markers.style', 'markerStyle', {
            'kind': 'tile',
            'id': 55,
            'color': '#00FFFF',
            'radius': 2,
            'lineWidth': 1,
          });
          await action('markers.render', 'markerRender');
          expect(app.view.result['markersVisible'], true);
          await action('markers.hide', 'markerVisibility', {'visible': false});
          expect(app.view.result['markersVisible'], false);
          await action('markers.show', 'markerVisibility', {'visible': true});
          expect(app.view.result['markersVisible'], true);
          await action('markers.export', 'export', {'kind': 'markers'});
          files.next = PickedFile('markers.json', files.output!);
          await action('markers.import', 'import', {'kind': 'markers'});
          await action('markers.remove', 'markerRemove', {
            'kind': 'tile',
            'id': 55,
          });
          await action('markers.clear', 'markerClear', {'confirmed': true});
          expect(app.view.markerProfile!.length, 0);
          await action('world.map-png-export', 'export', {'kind': 'mapPng'});
          expect(files.output!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          await action('region.object-load', 'fusionRegion', {
            'x': 1,
            'y': 2,
            'width': 8,
            'height': 3,
          });
          expect(app.view.region!.objectCount, 3);
          await action('region.select', 'regionSelect', {'x': 0, 'y': 0});
          await action('region.edit', 'regionEdit', {
            'patch': {'wall': 2},
          });
          expect(app.view.region!.cellAt(0, 0)!['wall'], 2);
          await action('region.brush', 'regionBrush', {
            'kind': 'wire',
            'mask': 1,
            'remove': false,
          });
          await action('region.stroke-start', 'strokeStart', {
            'canvas': 'fusion',
          });
          await action('region.paint', 'paint', {
            'canvas': 'fusion',
            'x': 0,
            'y': 0,
          });
          await action('region.stroke-end', 'strokeEnd', {'canvas': 'fusion'});
          await action('region.brush-clear', 'regionBrushClear');
          await action('region.project-export', 'export', {
            'kind': 'fusionProject',
          });
          files.next = PickedFile('region.json', files.output!);
          await action('region.project-import', 'import', {'kind': 'project'});
          expect(app.view.region!.objectCount, 3);
          await action('world.locate', 'locate', {'x': 1, 'y': 1});
          await action('world.validate', 'validate');
          await action('settings.change', 'settings', {
            'key': 'benchmark',
            'value': true,
          });
          expect(app.view.result['benchmark'], true);
          await action('error.dismiss', 'dismissError');
        } finally {
          await app.close();
          app.dispose();
        }
      }

      Future<void> workspaceCanvasCycle() async {
        final f = _Fixture(
              'synthetic-canvas',
              'project',
              Uint8List(32 * 24 * 4),
            ),
            files = _Files();
        final app = Workspace(
          engine: engine,
          files: files,
          circuitBackend: native as CircuitBackend,
          regionBackend: region,
        );
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await measure('workspace.$id', f, () => app.dispatch(name, args));
          expect(app.view.error, isEmpty, reason: '$id: ${app.view.error}');
        }

        try {
          for (final kind in ['pixel', 'fusion', 'circuit']) {
            await action('canvas.$kind.resize', 'resize', {
              'canvas': kind,
              'width': 32,
              'height': 24,
            });
            await action('canvas.$kind.stroke-start', 'strokeStart', {
              'canvas': kind,
            });
            for (var x = 1; x <= 8; x++) {
              await action('canvas.$kind.paint', 'paint', {
                'canvas': kind,
                'x': x,
                'y': 3,
                'color': 0xff123456,
                'material': 'stone',
                'wireColor': 0,
              });
            }
            await action('canvas.$kind.stroke-end', 'strokeEnd', {
              'canvas': kind,
            });
            await action('canvas.$kind.undo', 'undo', {'canvas': kind});
            await action('canvas.$kind.redo', 'redo', {'canvas': kind});
            await action('canvas.$kind.export', 'export', {
              'kind': '${kind}Project',
            });
            expect(files.output, isNotEmpty);
            files.next = PickedFile('project.json', files.output!);
            await action('canvas.$kind.import', 'import', {'kind': 'project'});
          }
          await action('legacy-circuit.select', 'circuitSelect', {
            'x': 1,
            'y': 3,
            'width': 8,
            'height': 1,
          });
          await action('legacy-circuit.copy', 'circuitCopy');
          await action('legacy-circuit.cut', 'circuitCut');
          await action('legacy-circuit.undo', 'undo', {'canvas': 'circuit'});
          await action('legacy-circuit.rotate', 'circuitRotate');
          await action('legacy-circuit.mirror', 'circuitMirror', {
            'axis': 'horizontal',
          });
          await action('legacy-circuit.paste', 'circuitPaste', {
            'x': 12,
            'y': 4,
          });
          await action(
            'legacy-circuit.network-preview',
            'circuitNetworkPreview',
            {'x': 1, 'y': 3, 'mask': 1},
          );
          await action('legacy-circuit.cancel', 'circuitCancelEdit');
          await action('legacy-circuit.route-preview', 'circuitRoutePreview', {
            'startX': 1,
            'startY': 15,
            'endX': 8,
            'endY': 15,
            'mask': 1,
          });
          await action('legacy-circuit.confirm', 'circuitConfirmEdit');
          await action('legacy-circuit.place', 'circuitPlace', {
            'x': 1,
            'y': 3,
            'element': 'switchInput',
          });
          await action('legacy-circuit.trigger', 'circuitTrigger', {
            'x': 1,
            'y': 3,
          });
          await action('legacy-circuit.tick', 'circuitStep');
          await action('legacy-circuit.run-start', 'circuitToggle');
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await action('legacy-circuit.run-stop', 'circuitToggle');
          await action('pixel.png-export', 'export', {'kind': 'pixelPng'});
          files.next = PickedFile('image.png', files.output!);
          await action('pixel.image-import', 'import', {'kind': 'image'});
          for (final kind in ['pixel', 'fusion', 'circuit']) {
            await action('canvas.$kind.clear', 'clear', {'canvas': kind});
            await action('canvas.$kind.undo-clear', 'undo', {'canvas': kind});
          }
          await action('schemes.create', 'schemeCreate', {
            'kind': 'mapping',
            'name': 'Benchmark scheme',
          });
          final original = app.view.mappingSchemes!.selectedId!;
          await action('schemes.clone', 'schemeClone', {
            'kind': 'mapping',
            'id': original,
            'name': 'Benchmark clone',
          });
          final copy = app.view.mappingSchemes!.selectedId!;
          await action('schemes.rename', 'schemeRename', {
            'kind': 'mapping',
            'id': copy,
            'name': 'Benchmark renamed',
          });
          await action('schemes.select', 'schemeSelect', {
            'kind': 'mapping',
            'id': original,
          });
          await action('schemes.default', 'schemeSetDefault', {
            'kind': 'mapping',
            'id': original,
          });
          await action('schemes.delete', 'schemeDelete', {
            'kind': 'mapping',
            'id': copy,
            'confirmed': true,
          });
          final scheme = WorldRuleScheme(
            name: 'Benchmark saved',
            rules: [
              WorldTileRule(where: {'type': 1}, patch: {'wall': 2}, limit: 1),
            ],
          );
          await action('rules.save', 'worldRulesSave', {
            'scheme': scheme.toJson(),
          });
          await action('rules.export', 'export', {'kind': 'worldRules'});
          files.next = PickedFile('rules.json', files.output!);
          await action('rules.import', 'import', {'kind': 'worldRules'});
          await action('mapping.export', 'export', {'kind': 'mapping'});
          files.next = PickedFile('mapping.json', files.output!);
          await action('mapping.import', 'import', {'kind': 'mapping'});
        } finally {
          await app.close();
          app.dispose();
        }
      }

      Future<void> workspaceVaultCycle() async {
        final directory = await Directory('${temp.path}/workspace-vault')
            .create();
        final local = NativeLocalVault(directory: () async => directory),
            f = fixtures[0],
            files = _Files()
              ..next = PickedFile('fixture.wld', fixtures[0].bytes);
        final app = Workspace(engine: engine, files: files, vault: local);
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await measure('workspace.$id', f, () => app.dispatch(name, args));
          expect(app.view.error, isEmpty, reason: '$id: ${app.view.error}');
        }

        try {
          await measure('workspace.vault.initialize', f, app.initialize);
          expect(app.view.error, isEmpty);
          await action('vault.import', 'import', {'kind': 'world'});
          final id = app.view.files.single.id;
          await action('vault.trash', 'trashFile', {'id': id});
          expect(app.view.world, isEmpty);
          final entry = (await local.list()).single;
          await action('vault.restore', 'restoreFile', {'id': entry.id});
          await action('vault.open', 'openFile', {'id': id});
          expect(app.view.world, isNotEmpty);
          await action('vault.export', 'export', {'kind': 'world'});
          expect(files.output, f.bytes);
        } finally {
          await app.close();
          app.dispose();
          await directory.delete(recursive: true);
        }
      }

      Future<void> achievementsCycle() async {
        final bytes = achievement_fixtures.encrypt(
          achievement_fixtures.fixture(),
        );
        final f = _Fixture('synthetic-achievements', 'achievements', bytes),
            files = _Files();
        final catalog = resource_fixtures.pack({
          'catalog/achievements.json': utf8.encode(
            jsonEncode([
              {
                'id': 'SYNTHETIC',
                'name': 'Switch',
                'conditions': [
                  {'id': 'switch', 'kind': 'boolean'},
                ],
              },
              {
                'id': 'COUNTER',
                'name': 'Count',
                'conditions': [
                  {'id': 'count', 'kind': 'int', 'max': 10},
                ],
              },
              {
                'id': 'FLOAT',
                'name': 'Distance',
                'conditions': [
                  {'id': 'distance', 'kind': 'float', 'max': 2.5},
                ],
              },
            ]),
          ),
        });
        final app = Workspace(engine: engine, files: files);
        Future<void> action(
          String id,
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await measure('workspace.$id', f, () => app.dispatch(name, args));
          expect(app.view.error, isEmpty, reason: '$id: ${app.view.error}');
        }

        try {
          files.next = PickedFile('synthetic.abcpack', catalog);
          await action('achievements.catalog-import', 'import', {
            'kind': 'resources',
          });
          files.next = PickedFile('achievements.dat', bytes);
          await action('achievements.import', 'import', {
            'kind': 'achievements',
          });
          await action('achievements.counter', 'achievementCondition', {
            'id': 'COUNTER',
            'conditionId': 'count',
            'value': 5,
          });
          await action('achievements.toggle', 'achievementToggle', {
            'id': 'SYNTHETIC',
            'completed': true,
          });
          await action('achievements.complete', 'achievementCompleteKnown', {
            'confirmed': true,
          });
          await action('achievements.export', 'export', {
            'kind': 'achievements',
          });
          expect(
            AchievementFile.open(files.output!).records
                .take(3)
                .every((r) => r.completed),
            isTrue,
          );
          await action('achievements.new', 'achievementNew', {
            'confirmed': true,
          });
          await action('achievements.export', 'export', {
            'kind': 'achievements',
          });
          expect(
            AchievementFile.open(files.output!).records
                .every((r) => !r.completed),
            isTrue,
          );
        } finally {
          await app.close();
          app.dispose();
        }
      }

      Future<void> largeWorldCycle(_Fixture f) async {
        final records = await measure(
          'region.read-large-world',
          f,
          () => region.readRegion(f.bytes, 0, 0, 32, 32),
        );
        expect(records.length, 32 * 32 * 32);
        final modified = Uint8List.fromList(records);
        final data = ByteData.sublistView(modified);
        final old = data.getUint32(16, Endian.little);
        data.setUint32(
          16,
          (old & 0xffff0000) | ((old & 65535) == 2 ? 3 : 2),
          Endian.little,
        );
        final candidate = await measure(
          'region.replace-large-world',
          f,
          () => region.replaceRegion(f.bytes, 0, 0, 32, 32, modified),
        );
        expect(await region.readRegion(candidate, 0, 0, 32, 32), modified);
        final ruled = await measure(
          'rules.batch-update-large-world',
          f,
          () => region.regionOperation(f.bytes, 'batch_update_tiles', {
            'rules': [
              {
                'where': {'type': 1, 'wire_red': false},
                'patch': {'wall': 2, 'wire_red': true},
                'limit': 1,
              },
            ],
          }),
        );
        expect(sha256.convert(ruled), isNot(sha256.convert(f.bytes)));
        int? session;
        Future<WorldCircuitResult> command(WorldCircuitCommand c) =>
            tcw.commandWorldCircuit(session!, c);
        try {
          final opened = await measure(
            'tcw.open-large-world',
            f,
            () => tcw.openWorldCircuit(f.bytes),
          );
          session = opened.session;
          bench.owners.add('tcw:$session');
          expect(opened.width, greaterThanOrEqualTo(32));
          expect(opened.height, greaterThanOrEqualTo(32));
          await measure(
            'tcw.viewport-large-world',
            f,
            () => command(WorldCircuitCommand.viewport(0, 0, 32, 32)),
          );
          await measure(
            'tcw.trigger-large-world',
            f,
            () => command(
              WorldCircuitCommand.trigger(0, 0, width: 32, height: 32, mask: 1),
            ),
          );
          final tick = await measure(
            'tcw.tick60-large-world',
            f,
            () => command(WorldCircuitCommand.ticks(60)),
          );
          expect(tick.ticks, 60);
          final saved = await measure(
            'tcw.export-large-world',
            f,
            () => command(WorldCircuitCommand.save()),
          );
          expect(saved.world, isNotEmpty);
          await measure(
            'tcw.close-large-world',
            f,
            () => tcw.closeWorldCircuit(session!),
          );
          bench.owners.remove('tcw:$session');
          session = null;
          session = (await measure(
            'tcw.reopen-large-world',
            f,
            () => tcw.openWorldCircuit(saved.world!),
          )).session;
          bench.owners.add('tcw:$session');
        } finally {
          if (session != null) {
            await tcw.closeWorldCircuit(session);
            bench.owners.remove('tcw:$session');
          }
        }
      }

      Future<void> demosCycle() async {
        final demos =
            ((await rules.invokeCircuitRules('capabilities', [])
                        as Map)['demos']
                    as List)
                .cast<String>();
        for (final demo in demos) {
          var f = _Fixture('source-demo-$demo', 'circuit', Uint8List(0));
          try {
            final loaded = await measure(
              'circuit.demo-load',
              f,
              () => rules.invokeCircuitRules('editor.demo', [demo]),
            ) as Map;
            bench.owners.add('rules:demo');
            f = _Fixture(
              f.id,
              f.kind,
              Uint8List.fromList(utf8.encode(loaded['document'] as String)),
            );
            for (final row in bench.rows.values) {
              if (row['id'] == 'circuit.demo-load' && row['fixture'] == f.id) {
                row['bytesPerOperation'] = f.bytes.length;
              }
            }
            final raw = jsonDecode(loaded['document'] as String) as Map;
            final world = raw['world'] as Map,
                wires = (raw['world'] as Map)['wires'] as List;
            final first = wires.isEmpty ? [0, 0] : wires.first as List;
            if (!(bench.report['fixtures'] as List).any(
              (x) => x['id'] == f.id,
            )) {
              (bench.report['fixtures'] as List).add(<String, Object?>{
                'id': f.id,
                'kind': f.kind,
                'provenance': 'attributed-source-demo',
                'bytes': f.bytes.length,
                'sha256': sha256.convert(f.bytes).toString(),
                'width': world['width'],
                'height': world['height'],
                'wireCells': wires.length,
                'tiles': (world['tiles'] as List).length,
              });
            }
            final trigger = await measure(
              'circuit.demo-trigger',
              f,
              () => rules.invokeCircuitRules('simulation.command', [
                {
                  'method': 'trigger',
                  'args': [
                    [
                      {'x': first[0], 'y': first[1]},
                    ],
                    15,
                  ],
                  'debug': true,
                },
              ]),
            ) as Map;
            expect(trigger['packet']['native']['fallback'], false);
            if (wires.isNotEmpty) {
              expect(
                trigger['packet']['native']['commandVisits'],
                greaterThan(0),
              );
            }
            final run = await measure(
              'circuit.demo-run60',
              f,
              () => rules.invokeCircuitRules('simulation.command', [
                {
                  'method': 'step',
                  'args': [60],
                  'debug': true,
                },
              ]),
            ) as Map;
            expect(run['packet']['tick'], 60);
            final reset = await measure(
              'circuit.demo-reset',
              f,
              () => rules.invokeCircuitRules('simulation.reset', []),
            ) as Map;
            expect(reset['document'], loaded['document']);
            final reopened = await measure(
              'circuit.demo-reopen',
              f,
              () =>
                  rules.invokeCircuitRules('editor.open', [loaded['document']]),
            ) as Map;
            expect(reopened['document'], loaded['document']);
          } finally {
            await measure(
              'circuit.demo-close',
              f,
              () => rules.invokeCircuitRules('editor.close', []),
            );
            bench.owners.remove('rules:demo');
          }
        }
      }

      Future<void> rulesCycle() async {
        final f = _Fixture('synthetic-circuit-rules', 'circuit', Uint8List(0));
        Future<dynamic> invoke(
          String id,
          String method, [
          List<Object?> args = const [],
        ]) => measure(
          'circuit.$id',
          f,
          () => rules.invokeCircuitRules(method, args),
        );
        Future<dynamic> edit(
          String id,
          String method, [
          List<Object?> args = const [],
        ]) => invoke(id, 'editor.command', [
          {'method': method, 'args': args},
        ]);
        expect(
          (await rules.invokeCircuitRules('capabilities', [])
              as Map)['sourceCommit'],
          '366ebc57751cadfb077f968f4d5069028b3bf9a6',
        );
        try {
          await invoke('load', 'editor.new', ['Benchmark']);
          bench.owners.add('rules:1');
          await edit('paint', 'paint', [
            {'x': 1, 'y': 3},
            {'x': 8, 'y': 3},
            {'tool': 'wire', 'mask': 15},
          ]);
          await edit('place', 'placeTile', [
            {'kind': 'switch', 'x': 1, 'y': 3},
          ]);
          await edit('place', 'placeTile', [
            {'kind': 'gemspark', 'x': 8, 'y': 3},
          ]);
          await edit('select', 'select', [
            {'x': 1, 'y': 3, 'width': 8, 'height': 1},
          ]);
          await edit('copy', 'copy');
          await edit('paste', 'paste', [
            {'x': 1, 'y': 8},
          ]);
          await edit('undo', 'undo');
          await edit('redo', 'redo');
          await edit('rotate', 'transformClipboard', ['rotate']);
          await edit('route', 'previewRoute', [
            {'x': 1, 'y': 12},
            {'x': 8, 'y': 12},
            1,
            'benchmark-route',
          ]);
          await edit('route-confirm', 'commitPreview', ['benchmark-route']);
          final saved = (await rules.invokeCircuitRules(
            'editor.snapshot',
            [],
          ) as Map)['document'];
          final triggered = await invoke('trigger', 'simulation.command', [
            {
              'method': 'interact',
              'args': [1, 3],
              'debug': true,
            },
          ]);
          expect(triggered['packet']['native']['fallback'], false);
          expect(
            triggered['packet']['native']['commandVisits'],
            greaterThan(0),
          );
          final tick = await invoke('tick', 'simulation.command', [
            {
              'method': 'step',
              'args': [1],
              'debug': true,
            },
          ]);
          expect(tick['packet']['tick'], 1);
          final run = await invoke('run60', 'simulation.command', [
            {
              'method': 'step',
              'args': [60],
              'debug': true,
            },
          ]);
          expect(run['packet']['tick'], 61);
          expect(
            (await invoke('reset', 'simulation.reset'))['document'],
            saved,
          );
          await invoke('reopen', 'editor.open', [saved]);
          expect(
            (await rules.invokeCircuitRules('editor.snapshot', [])
                as Map)['document'],
            saved,
          );
          await measure(
            'circuit.reject-command',
            f,
            () => expectLater(
              rules.invokeCircuitRules('simulation.command', [
                {
                  'method': 'step',
                  'args': [61],
                },
              ]),
              throwsA(isA<EngineException>()),
            ),
          );
        } finally {
          await invoke('close', 'editor.close');
          bench.owners.remove('rules:1');
        }
      }

      Future<void> vaultCycle() async {
        final f = fixtures[0];
        final entry = VaultEntry(
          id: 'benchmark-${bench.cycle + 1}',
          name: 'fixture.wld',
          kind: 'world',
          sha256: sha256.convert(f.bytes).toString(),
          size: f.bytes.length,
          modified: DateTime.utc(2026),
        );
        await measure('vault.put', f, () => vault.put(entry, f.bytes));
        expect(
          await measure('vault.read', f, () => vault.read(entry.id)),
          f.bytes,
        );
        expect(await measure('vault.list', f, vault.list), hasLength(1));
        await measure(
          'vault.reject-duplicate',
          f,
          () => expectLater(
            vault.put(entry, f.bytes),
            throwsA(isA<VaultException>()),
          ),
        );
        await measure('vault.remove', f, () => vault.remove(entry.id));
        expect(await vault.list(), isEmpty);
        await measure(
          'vault.reject-missing',
          f,
          () =>
              expectLater(vault.read(entry.id), throwsA(isA<VaultException>())),
        );
      }

      Future<void> resourcesCycle() async {
        final resourceBytes = pack ?? syntheticPack;
        final f = _Fixture(
              pack == null
                  ? 'synthetic-resource-pack'
                  : 'private-resource-pack',
              'resources',
              resourceBytes,
            ),
            files = _Files()
              ..next = PickedFile('resources.abcpack', resourceBytes);
        final app = Workspace(engine: engine, files: files);
        try {
          await measure(
            'resources.import',
            f,
            () => app.dispatch('import', {'kind': 'resources'}),
          );
          expect(app.view.error, isEmpty);
          expect(app.view.resources, isNotNull);
          await measure(
            'resources.clear-memory',
            f,
            () => app.dispatch('clearResourceMemory'),
          );
          expect(app.view.error, isEmpty);
          files.next = PickedFile(
            'invalid.abcpack',
            Uint8List.fromList([1, 2, 3]),
          );
          await measure(
            'resources.reject-invalid',
            f,
            () => app.dispatch('import', {'kind': 'resources'}),
          );
          expect(app.view.error, isNotEmpty);
          files.next = PickedFile('resources.abcpack', resourceBytes);
          await measure(
            'resources.reload',
            f,
            () => app.dispatch('import', {'kind': 'resources'}),
          );
          expect(app.view.error, isEmpty);
        } finally {
          await app.close();
          app.dispose();
        }
      }

      Future<void> projectionCycle() async {
        final f = fixtures.last, doc = await engine.open(f.bytes, kind: 'plr');
        try {
          final model = await engine.inspect(doc);
          for (final target in [38, 135, 218, 279, 326]) {
            final candidate = PlayerConversion.prepare(model, target).candidate;
            final bytes = await measure(
              'plr.project-$target',
              f,
              () =>
                  (native as PlayerProjectionBackend).projectPlayer(candidate),
            );
            final temporary = await engine.open(bytes, kind: 'plr');
            try {
              expect((await engine.inspect(temporary))['version'], target);
              expect(await engine.save(temporary), bytes);
            } finally {
              await engine.close(temporary);
            }
          }
          expect(await engine.save(doc), f.bytes);
        } finally {
          await engine.close(doc);
        }
      }

      var status = 'failed';
      try {
        bench.memory('baseline');
        await bench.write(output, 'running');
        for (
          bench.cycle = -1;
          bench.cycle < bench.warmup + bench.cycles;
          bench.cycle++
        ) {
          for (final f in bench.cycle.isOdd ? fixtures : fixtures.reversed) {
            await documentCycle(f);
          }
          await workspaceCycle(fixtures[0]);
          await workspaceObjectsCycle();
          await workspaceCanvasCycle();
          await workspaceVaultCycle();
          await achievementsCycle();
          await fragmentCycle();
          await privateCatalogCycle();
          await regionCycle();
          await tcwCycle();
          for (final f in fixtures.where(
            (f) =>
                f.kind == 'wld' &&
                (f.id.startsWith('private-') ||
                    f.id == 'synthetic-scaled-world'),
          )) {
            await largeWorldCycle(f);
          }
          await rulesCycle();
          await demosCycle();
          await projectionCycle();
          await vaultCycle();
          await resourcesCycle();
          expect(
            bench.owners,
            isEmpty,
            reason: 'All explicit owners must close after each complete action cycle',
          );
          if (counters.available) {
            final live = counters.snapshot();
            expect(
              live['nativeTotalLiveBytes'],
              0,
              reason: 'No native/persistent/bridge payload may remain after all owners close',
            );
            expect(live['nativeWorldOpenCount'], 0);
          }
          bench.memory('after-close');
          if (gcDiagnostic) {
            // Preserve the unforced sample above. GC is a separate diagnostic
            // after every owner has closed, outside all operation timings.
            final diagnostic = await vm_memory.memorySnapshot();
            if (diagnostic.remove('heapUnavailable') != null) {
              // A socket exception may contain a private VM-service auth URI.
              diagnostic['heapUnavailable'] =
                  'VM-service heap probe unavailable';
            }
            bench.memory(
              diagnostic['heapUsedBytes'] == null
                  ? 'after-close-gc-unavailable'
                  : 'after-close-gc',
              diagnostic,
            );
          }
          await bench.write(output, 'running');
        }
        status = 'passed';
      } finally {
        await vm_memory.closeMemoryProbe();
        await rules.invokeCircuitRules('dispose', []);
        messenger.setMockMessageHandler('flutter/assets', null);
        rootBundle.clear();
        await temp.delete(recursive: true);
        await bench.write(output, status);
      }
    },
    skip:
        output == null ||
            Platform.environment['TERRAFORGE_ENGINE_LIBRARY'] == null
        ? 'Opt-in performance suite requires ABC_PERF_REPORT and native engine'
        : false,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
