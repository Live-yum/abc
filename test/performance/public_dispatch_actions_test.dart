// Opt in with ABC_DISPATCH_PERF_REPORT and TERRAFORGE_ENGINE_LIBRARY.
// Public 16x32 synthetic WLD, generated PLR and invented catalog contracts only.
// Times the real Workspace dispatcher. No Flutter frames or live HTTP claimed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/cloud/cloud.dart';
import 'package:terraforge/domain/player_conversion.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/player_projection_backend.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/vault_native.dart';

import '../cloud_reference_contract_test.dart'
    show ReferenceService, account, envelope, saveJson, recommendationJson;
import 'measurements.dart';
import 'native_counters.dart';
import 'public_catalog_fixture.dart';
import '../../integration_test/support/profile_memory_native.dart' as vm_memory;

class _Files implements FileGateway {
  PickedFile? input;
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => input;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    output = Uint8List.fromList(bytes);
    return true;
  }
}

class _TrackedEngine implements TerraEngine, CreatablePlayerEngine {
  _TrackedEngine(this.inner, this.bench);
  final TerraEngine inner;
  final Measurements bench;
  String key(EngineDocument doc) => '${doc.kind}:${doc.handle}';
  @override
  Future<EngineDocument> open(Uint8List bytes, {required String kind}) async {
    final doc = await inner.open(bytes, kind: kind);
    expect(bench.owners.add(key(doc)), isTrue);
    return doc;
  }

  @override
  Future<EngineDocument> createPlayer(String name) async {
    final doc = await (inner as CreatablePlayerEngine).createPlayer(name);
    expect(bench.owners.add(key(doc)), isTrue);
    return doc;
  }

  @override
  Future<void> close(EngineDocument doc) async {
    await inner.close(doc);
    expect(bench.owners.remove(key(doc)), isTrue);
  }

  @override
  Future<Map<String, dynamic>> inspect(EngineDocument doc) =>
      inner.inspect(doc);
  @override
  Future<void> mutate(
    EngineDocument doc,
    String operation,
    Map<String, dynamic> args,
  ) => inner.mutate(doc, operation, args);
  @override
  Future<Uint8List> save(EngineDocument doc) => inner.save(doc);
  @override
  Future<Uint8List?> preview(EngineDocument doc) => inner.preview(doc);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['ABC_DISPATCH_PERF_REPORT'];
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  test(
    'public missing dispatcher actions verify mutations and close owners',
    () async {
      final bench = Measurements()..journal(output!);
      bench.report['suite'] = 'public-dispatch-actions';
      (bench.report['methodology'] as Map)['timing'] = 'Exact awaited production Workspace.dispatch calls; assertions and fixture setup are outside timings. Native codecs are real. Cloud HTTP/auth are injected local synthetic adapters; no network/login latency or Flutter frames.';
      (bench.report['gaps'] as List<String>).addAll([
        'No live cloud session, provider authentication, server or network measured.',
        'No profile-mode UI/raster frames measured in this controller-only suite.',
        'Synthetic catalog validates controller/codec contracts; it does not establish authentic complete game catalog compatibility.',
        'generate is an unsupported production service; openSynthetic is a disabled QA-only production entry.',
        'Per-process RSS is not live Dart heap or proof of no leaks; compare independent same-workload runs.',
      ]);
      final counters = NativeAllocationCounters(library!);
      bench.nativeMemory = counters.snapshot;
      final gcDiagnostic =
          Platform.environment['ABC_PERF_GC_DIAGNOSTICS'] == '1';
      (bench.report['methodology'] as Map)['gcDiagnosticEnabled'] =
          gcDiagnostic;
      expect(bench.cycles, greaterThanOrEqualTo(3));
      expect(bench.warmup, greaterThanOrEqualTo(1));
      final native = createTerraEngine(),
          engine = _TrackedEngine(native, bench);
      final projection = native as PlayerProjectionBackend;
      final world = await File('assets/qa/synthetic-modern.wld').readAsBytes();
      final catalog = publicPerformanceCatalog();
      final blank = await engine.createPlayer('Public synthetic');
      late Uint8List player, legacy;
      try {
        player = await engine.save(blank);
        legacy = await projection.projectPlayer(
          PlayerConversion.prepare(await engine.inspect(blank), 279).candidate,
        );
      } finally {
        await engine.close(blank);
      }
      final fixtureBytes = {
        'public-modern-world': world,
        'public-catalog': catalog,
        'public-player-v326': player,
        'public-player-v279': legacy,
      };
      for (final entry in fixtureBytes.entries) {
        bench.fixture(
          entry.key,
          entry.key.contains('world')
              ? 'wld'
              : entry.key.contains('catalog')
              ? 'resources'
              : 'plr',
          entry.value.length,
          sha256: sha256.convert(entry.value).toString(),
        );
      }
      final root = await Directory.systemTemp.createTemp(
        'abc-public-dispatch-',
      );
      var status = 'failed';
      try {
        for (
          bench.cycle = -1;
          bench.cycle < bench.warmup + bench.cycles;
          bench.cycle++
        ) {
          final files = _Files(), service = ReferenceService();
          service.bytes = world;
          service.handler = (request) async {
            switch (request.url.path) {
              case '/viewer/cloud-saves/get':
              case '/viewer/cloud-saves/upload':
                return envelope({...saveJson(), 'fileSize': world.length});
              case '/viewer/recommendations/get':
                return envelope({
                  ...recommendationJson(),
                  'fileSize': world.length,
                });
              case '/viewer/recommendations/download-ticket':
                final response = service.response(request);
                final body = jsonDecode(response.body) as Map;
                (body['data'] as Map)['fileSize'] = world.length;
                return http.Response(jsonEncode(body), 200);
              default:
                return service.response(request);
            }
          };
          final cloud = CloudBackend(
            api: service.api,
            session: account('public-synthetic'),
            operationStore: service.operations,
          );
          var app = Workspace(
            engine: engine,
            files: files,
            regionBackend: native as RegionBackend,
            playerProjectionBackend: projection,
            cloud: cloud,
            vault: NativeLocalVault(
              directory: () async => Directory('${root.path}/${bench.cycle}'),
            ),
          );
          bench.memory('before-cycle');
          Future<void> action(
            String id,
            String name, [
            Map<String, Object?> args = const {},
            String fixture = 'public-modern-world',
          ]) async {
            await bench.measure(
              'workspace.$id',
              fixture,
              fixtureBytes[fixture]!.length,
              () => app.dispatch(name, args),
            );
            expect(app.view.error, isEmpty, reason: '$name: ${app.view.error}');
            final phase = bench.cycle == -1 ? 'cold' : 'warm';
            final row = bench.rows['workspace.$id/$fixture/$phase'];
            if (row != null)
              row.addAll({
                'controller': 'Workspace',
                'action': name,
                'dispatchEvidence': 'awaited-production-dispatch',
                'completion': 'returned-and-state-asserted',
                'variant': {
                  'scenario': id,
                  'transport': name.startsWith('cloud')
                      ? 'in-process-synthetic-http'
                      : 'real-native-codec',
                },
              });
          }

          Future<Map<String, dynamic>> readback(String kind) async {
            // The C runtime has one world owner. Verify detached exported bytes
            // after closing app handles, then restore the same record/history.
            final id = app.view.files
                .firstWhere(
                  (file) => file.kind == kind && file.name == files.input!.name,
                )
                .id;
            await app.close();
            final doc = await engine.open(files.output!, kind: kind);
            try {
              return await engine.inspect(doc);
            } finally {
              await engine.close(doc);
              await app.dispatch('openFile', {'id': id});
              expect(app.view.error, isEmpty);
            }
          }

          try {
            files.input = PickedFile('public.abcpack', catalog);
            await action('catalog.import', 'import', {
              'kind': 'resources',
            }, 'public-catalog');
            files.input = PickedFile('public.wld', world);
            await action('catalog.world-import', 'import', {'kind': 'world'});
            expect(app.view.world['version'], 326);
            await action('bestiary.patch', 'stageBestiary', {
              'patch': {
                'kills': [
                  {'persistentNpcId': 'SyntheticUnknown', 'killCount': 7},
                ],
              },
            });
            await action('bestiary.entry', 'bestiaryEntry', {
              'id': 'SyntheticCreature',
              'kind': 'kills',
              'value': 17,
            });
            expect(
              ((app.view.world['bestiary'] as Map)['kills'] as List).any(
                (x) =>
                    x['persistentNpcId'] == 'SyntheticCreature' &&
                    x['killCount'] == 17,
              ),
              isTrue,
            );
            await action('bestiary.unlock', 'bestiaryUnlockKnown', {
              'confirmed': true,
            });
            await action('chests.catalog-slot', 'stageChest', {
              'index': 0,
              'slot': 0,
              'itemId': 10,
              'quantity': 1,
              'prefix': 0,
            });
            await action('chests.best-prefix', 'chestBestPrefixes', {
              'index': 0,
              'confirmed': true,
            });
            await action('public.world-export', 'export', {'kind': 'world'});
            final edited = await readback('wld');
            expect(edited['chests'][0]['items'][0]['prefix'], 2);
            final kills = edited['bestiary']['kills'] as List;
            expect(
              kills.any(
                (x) =>
                    x['persistentNpcId'] == 'SyntheticCreature' &&
                    x['killCount'] == 50,
              ),
              isTrue,
            );
            expect(
              kills.any(
                (x) =>
                    x['persistentNpcId'] == 'SyntheticUnknown' &&
                    x['killCount'] == 7,
              ),
              isTrue,
            );
            await action('rules.preset-clone', 'worldPresetClone', {
              'id': 'synthetic-preset',
            });
            expect(app.view.worldRuleScheme!.rules.single.limit, 7);
            expect(app.view.worldRuleScheme!.isBuiltin, isFalse);
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
            expect(app.view.mapping.single['target'], 0);
            await action('placement.region-load', 'fusionRegion', {
              'x': 8,
              'y': 16,
              'width': 6,
              'height': 6,
            });
            final before = app.view.region!.encode();
            final intent = {
              'itemId': 1000,
              'variantIndex': 0,
              'display': true,
              'x': 1,
              'y': 1,
            };
            await action('placement.stage', 'fusionPlace', intent);
            expect(app.view.region!.objectCount, 1);
            await action('placement.discard', 'fusionDiscardPlacement');
            expect(app.view.region!.encode(), before);
            await action('placement.restage', 'fusionPlace', intent);
            await action('placement.insert', 'fusionInsert', {
              'confirmed': true,
            });
            expect(app.view.result['fusionPlacement'], isNull);
            await action('public.placement-readback', 'fusionRegion', {
              'x': 9,
              'y': 17,
              'width': 2,
              'height': 2,
            });
            expect(app.view.region!.objectCount, 1);
            expect(app.view.region!.cellAt(0, 0)!['block'], 395);
            await action('placement.undo', 'undo', {'canvas': 'world'});
            files.input = PickedFile('public.plr', player);
            await action('catalog.player-import', 'import', {
              'kind': 'player',
            }, 'public-player-v326');
            await action('player.catalog-slot', 'playerSlotEdit', {
              'group': 'inventory',
              'index': 0,
              'slot': {
                'itemType': 10,
                'stack': 1,
                'prefix': 0,
                'favorited': true,
              },
            }, 'public-player-v326');
            await action('player.best-prefix', 'playerBestPrefixes', {
              'groups': ['inventory'],
              'confirmed': true,
            }, 'public-player-v326');
            await action('player.catalog-export', 'export', {
              'kind': 'player',
            }, 'public-player-v326');
            final checkedPlayer = await readback('plr');
            expect(checkedPlayer['inventory'][0]['prefix'], 2);
            expect(checkedPlayer['inventory'][0]['favorited'], true);
            files.input = PickedFile('legacy.plr', legacy);
            await action('conversion.import', 'import', {
              'kind': 'player',
            }, 'public-player-v279');
            await action('conversion.prepare', 'preparePlayerConversion', {
              'target': 326,
            }, 'public-player-v279');
            expect((app.view.result['conversion'] as Map)['blocked'], isFalse);
            await action(
              'conversion.cancel',
              'cancelPlayerConversion',
              {},
              'public-player-v279',
            );
            expect(app.view.result['conversion'], isNull);
            expect(app.view.player['version'], 279);
            await action('conversion.reprepare', 'preparePlayerConversion', {
              'target': 326,
            }, 'public-player-v279');
            await action('conversion.apply', 'applyPlayerConversion', {
              'confirmed': true,
            }, 'public-player-v279');
            expect(app.view.player['version'], 326);
            await action('public.conversion-export', 'export', {
              'kind': 'player',
            }, 'public-player-v279');
            expect((await readback('plr'))['version'], 326);
            await action('conversion.undo', 'undo', {
              'canvas': 'player',
            }, 'public-player-v279');
            expect(app.view.player['version'], 279);
            // Cloud adoption starts in a genuinely empty synthetic vault;
            // the earlier local import must not turn the first download into
            // an already-cached adoption branch.
            await app.close();
            app.dispose();
            final cloudVault = NativeLocalVault(
              directory: () async =>
                  Directory('${root.path}/${bench.cycle}-cloud'),
            );
            app = Workspace(
              engine: engine,
              files: files,
              cloud: cloud,
              vault: cloudVault,
            );
            expect(await cloudVault.list(), isEmpty);
            files.input = PickedFile('public.wld', world);
            await action('cloud.prepare', 'cloudPrepareUpload');
            expect(app.view.result['pendingCloudUpload'], isNotNull);
            await action('cloud.discard', 'cloudDiscardUpload');
            expect(app.view.result['pendingCloudUpload'], isNull);
            await action('cloud.reprepare', 'cloudPrepareUpload');
            await action('cloud.upload', 'cloudUploadPrepared');
            expect(app.view.result['pendingCloudUpload'], isNull);
            final save = CloudSave.fromJson({
              ...saveJson(),
              'fileSize': world.length,
            });
            await action('cloud.download', 'cloudDownload', {'save': save});
            expect(files.output, world);
            final downloaded = await cloudVault.list();
            expect(downloaded, hasLength(1));
            expect(await cloudVault.read(downloaded.single.id), world);
            await action(
              'cloud.recommendation-download',
              'cloudRecommendationDownload',
              {
                'item': CloudRecommendation.fromJson({
                  ...recommendationJson(),
                  'fileSize': world.length,
                }),
              },
            );
            expect(app.view.files.any((file) => file.kind == 'wld'), isTrue);
            expect(await cloudVault.read(downloaded.single.id), world);
            expect(cloud.pendingReceiptCount, 0);
          } finally {
            await app.close();
            app.dispose();
            cloud.dispose();
            expect(bench.owners, isEmpty);
            if (counters.available) {
              expect(counters.snapshot()['nativeTotalLiveBytes'], 0);
              expect(counters.snapshot()['nativeWorldOpenCount'], 0);
            }
            bench.memory('after-close');
            if (gcDiagnostic) {
              final diagnostic = await vm_memory.memorySnapshot();
              if (diagnostic.remove('heapUnavailable') != null) {
                diagnostic['heapUnavailable'] =
                    'VM-service heap probe unavailable';
              }
              bench.memory('after-close-gc', diagnostic);
            }
          }
          await bench.write(output!, 'running');
        }
        status = 'passed';
      } finally {
        await bench.write(output!, status);
        await vm_memory.closeMemoryProbe();
        await root.delete(recursive: true);
      }
    },
    skip: output == null || library == null
        ? 'Set report destination and release native library; public fixtures only.'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
