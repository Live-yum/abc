// Developer-only target: never imported by lib/main.dart.
// Synthetic file inputs intentionally replace OS pickers. This does not profile
// a real user's files, a system chooser/share sheet, disk, or network latency.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:crypto/crypto.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/world_rules.dart';
import 'package:terraforge/engine/native_engine.dart'
    if (dart.library.js_interop) 'package:terraforge/engine/web_engine.dart'
    as core;
import 'package:terraforge/engine/circuit_backend.dart';
import 'package:terraforge/engine/player_projection_backend.dart';
import 'package:terraforge/engine/region_backend.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/resources/online_resource_service.dart';
import 'package:terraforge/resources/online_resource_transport.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/terra_painters.dart';
import 'package:terraforge/ui/region_texture_canvas.dart';
import 'package:terraforge/ui/world_map_view.dart';
import 'package:terraforge/ui/online_resources_panel.dart';
import 'package:terraforge/ui/terraria_map_panel.dart';

import '../test/support/online_resource_fixture.dart';
import '../tool/perf/map_fixture.dart';
import 'support/profile_memory_native.dart'
    if (dart.library.js_interop) 'support/profile_memory_web.dart'
    as memory;
import 'support/profile_recorder.dart';
import 'support/profile_controller.dart';
import 'support/profile_inputs_native.dart'
    if (dart.library.js_interop) 'support/profile_inputs_web.dart'
    as inputs;

const _iterations = int.fromEnvironment('PERF_ITERATIONS', defaultValue: 8);
const _warmup = int.fromEnvironment('PERF_WARMUP', defaultValue: 2);
const _debugSmoke = bool.fromEnvironment('PERF_ALLOW_DEBUG_SMOKE');

class _Files implements FileGateway {
  PickedFile? input;
  PickedFile? output;
  bool cancelSave = false;
  @override
  Future<PickedFile?> pick(String kind) async => input;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    if (cancelSave) return false;
    output = PickedFile(name, Uint8List.fromList(bytes));
    return true;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (kProfileMode) {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  }
  testWidgets('repeated real-engine workspace UI performance', (tester) async {
    final runStarted = DateTime.now().toUtc();
    if (!kProfileMode && !_debugSmoke) {
      fail(
        'Run with flutter drive --profile. Debug runs are not performance evidence.',
      );
    }
    if (kProfileMode && _debugSmoke) {
      fail(
        'Debug-smoke viewport overrides cannot be used for profile acceptance.',
      );
    }
    if (_iterations < 1 || _warmup < 0) fail('Invalid repetition settings.');
    if (_debugSmoke) {
      tester.view.physicalSize = Size(
        const int.fromEnvironment(
          'PERF_SMOKE_WIDTH',
          defaultValue: 1440,
        ).toDouble(),
        const int.fromEnvironment(
          'PERF_SMOKE_HEIGHT',
          defaultValue: 1000,
        ).toDouble(),
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    WidgetController.hitTestWarningShouldBeFatal = true;
    final refresh = tester.view.display.refreshRate;
    final recorder = ProfileRecorder(
      frameBudgetUs: 1000000 / (refresh > 0 ? refresh : 60),
      profile: kProfileMode,
      currentRss: memory.currentRss,
    );
    final snapshots = <Map<String, Object?>>[];
    final resourcePhases = <Map<String, Object?>>[];
    final resourceManifestSha = OnlineFixture().sha;
    final resourceUpdateSha = OnlineFixture('Next synthetic').sha;
    final localInputs = await inputs.localInputs();
    final fixtures = <String, Uint8List>{};
    for (final name in ['synthetic-objects.wld', 'synthetic-circuit.wld']) {
      final data = await rootBundle.load('assets/qa/$name');
      fixtures[name] = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    for (final chunked in [false, true]) {
      fixtures['synthetic-${chunked ? 'chunked' : 'legacy'}.map'] =
          syntheticMap(chunked: chunked, width: 512, height: 256);
    }
    var status = 'failed';
    recorder.start();
    try {
      Future<void> cycles() async {
        for (var cycle = 0; cycle < _warmup + _iterations; cycle++) {
          await _runCycle(
            tester,
            recorder,
            fixtures,
            localInputs,
            resourcePhases,
            cycle,
          );
          // Drop cycle-owned objects before collecting between-cycle memory.
          snapshots.add({
            'cycle': cycle,
            'warmup': cycle < _warmup,
            'phase': 'after-close',
            'harnessRetainedFrameCount': recorder.frames.length,
            'harnessRetainedOperationWindows': recorder.windows.length,
            'harnessRetainedControllerSamples': recorder.dispatches.length,
            ...await memory.memorySnapshot(),
          });
        }
      }

      if (kProfileMode && const bool.fromEnvironment('PERF_TRACE_TIMELINE')) {
        await binding.traceAction(
          cycles,
          reportKey: 'timeline',
          streams: ['Dart', 'Embedder', 'GC'],
        );
      } else {
        await cycles();
      }
      status = kProfileMode ? 'passed' : 'debug-smoke-only';
    } finally {
      // Flutter can deliver frame timing batches up to a second late.
      if (kProfileMode) await Future<void>.delayed(const Duration(seconds: 2));
      recorder.stop();
      final operations = recorder.results();
      final missingFrames = operations
          .where((o) => o['status'] == 'missing-frames')
          .toList();
      final missingHeap =
          !kIsWeb && snapshots.any((row) => row['heapUsedBytes'] == null);
      binding.reportData = {
        ...?binding.reportData,
        'schema': 'abc.performance.v1',
        'suite': 'flutter-ui',
        'runId': 'ui-${runStarted.microsecondsSinceEpoch}',
        'startedAt': runStarted.toIso8601String(),
        'status':
            status == 'passed' && (missingFrames.isNotEmpty || missingHeap)
            ? 'incomplete-metrics'
            : status,
        'runtime': {
          ...memory.runtimeMetadata(),
          'flutterVersion': const String.fromEnvironment(
            'PERF_FLUTTER_VERSION',
          ),
          'commit': const String.fromEnvironment('PERF_COMMIT'),
          'checkedOutHead': const String.fromEnvironment(
            'PERF_CHECKED_OUT_HEAD',
          ),
          'workingTreeDirty': const bool.fromEnvironment(
            'PERF_WORKTREE_DIRTY',
            defaultValue: true,
          ),
          'runner': const String.fromEnvironment(
            'PERF_RUNNER',
            defaultValue: 'unspecified',
          ),
          'renderer': const String.fromEnvironment(
            'PERF_RENDERER',
            defaultValue: 'unspecified',
          ),
          'physicalWidth': tester.view.physicalSize.width,
          'physicalHeight': tester.view.physicalSize.height,
          'devicePixelRatio': tester.view.devicePixelRatio,
          'refreshRateHz': refresh,
          'frameBudgetSource': refresh > 0
              ? 'display refresh rate'
              : '60Hz fallback; verify device',
          ...memory.runtimeOverrides(),
        },
        'tracing': const bool.fromEnvironment('PERF_TRACE_TIMELINE'),
        'buildMode': kProfileMode ? 'profile' : 'debug-smoke-not-performance',
        'tier': localInputs.isEmpty
            ? 'synthetic-small-ui'
            : 'synthetic-plus-local-ui',
        'iterations': _iterations,
        'warmup': _warmup,
        'fixtures': [
          for (final fixture in fixtures.entries)
            {
              'id': fixture.key,
              'kind': fixture.key.endsWith('.map') ? 'map' : 'wld',
              'bytes': fixture.value.length,
              'sha256': sha256.convert(fixture.value).toString(),
              'provenance': 'repository hand-encoded synthetic fixture',
            },
          {
            'id': 'generated-player',
            'kind': 'plr',
            'provenance': 'native createPlayer synthetic output',
            'generatorConfigSha256': sha256
                .convert(utf8.encode('createPlayer:Synthetic profile'))
                .toString(),
          },
          {
            'id': 'resources',
            'kind': 'manifest',
            'provenance': 'in-memory synthetic transport',
            'manifestSha256': resourceManifestSha,
            'updateManifestSha256': resourceUpdateSha,
          },
          for (final input in localInputs)
            {
              'id': input.file.name,
              'kind': input.kind,
              'bytes': input.file.bytes.length,
              'sha256': sha256.convert(input.file.bytes).toString(),
              'provenance': 'operator-configured native local file; path and original filename omitted',
            },
        ],
        'operations': operations,
        'controllerOperations': recorder.controllerResults(),
        'controllerSemantics': 'Exact awaited production TerraController dispatch latency, excluding frame settling and fixture bookkeeping. Safe variants and associated UI macro scope are recorded; private argument values and filenames are omitted. Completion returned does not mean accepted: the associated UI workflow separately asserts success or expected rejection.',
        'frameClockDiagnostics': recorder.clockDiagnostics(),
        'memory': snapshots,
        'resourcePhases': resourcePhases,
        'resourcePhaseSemantics': 'Actual installer phase transitions against an in-memory synthetic transport/storage. Downloading includes synthetic fetch plus integrity/decompression work; verifying includes normalization/activation. These are not real network or disk measurements.',
        'frameSemantics': 'Actual engine FrameTiming build/raster durations. overBudgetFrames counts UI or raster work over the display budget, not inferred FPS or compositor drops. latency includes deliberate UI pumping and gesture pacing.',
        'memorySemantics': 'Process RSS and all Dart isolate heaps after requested GC between complete workspace lifecycles. RSS includes native engines, renderer and cache retention. Native heap is not Dart heap. Raw benchmark measurements remain resident and their counts are recorded; compare matching harness runs. A completed run or a positive slope alone does not prove absence/presence of a leak.',
        'gaps': [
          'Only the reported device, renderer and viewport were measured; no Android/iOS/macOS/Web claims from Linux.',
          'Tiny public synthetic fixtures do not establish large real-world WLD/PLR/MAP performance.',
          'Native OS file chooser, share sheet, disk and external network are replaced by bounded synthetic gateways.',
          'Synthetic legacy/chunked MAP formats are measured separately from WLD previews; private MAP and texture-heavy licensed resource packs need separately authorized fixtures.',
          'Frame/retained-memory regressions require matching repeated baseline runs; missing baseline is inconclusive.',
          if (!kProfileMode) 'Debug smoke checks workflows only; all timings are non-acceptance data.',
        ],
      };
      await memory.writeStandaloneReport(binding.reportData!);
      await memory.closeMemoryProbe();
      if (status == 'passed') {
        expect(
          missingFrames,
          isEmpty,
          reason:
              'Every measured UI operation must produce actual engine timings.',
        );
        expect(
          missingHeap,
          isFalse,
          reason: 'Native profile acceptance requires VM heap samples.',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}

Future<void> _runCycle(
  WidgetTester tester,
  ProfileRecorder recorder,
  Map<String, Uint8List> fixtures,
  List<({String kind, PickedFile file})> localInputs,
  List<Map<String, Object?>> resourcePhases,
  int cycle,
) async {
  final files = _Files();
  final fixture = OnlineFixture();
  final transport = FixtureResourceTransport(fixture);
  final resources = OnlineResourceService(
    transport: transport,
    storage: FaultResourceStorage(),
  );
  var lastPhase = resources.phase, phaseStarted = Timeline.now;
  void recordPhase() {
    final next = resources.phase;
    if (next == lastPhase) return;
    final now = Timeline.now;
    if (const ['checking', 'downloading', 'verifying'].contains(lastPhase)) {
      resourcePhases.add({
        'cycle': cycle,
        'warmup': cycle < _warmup,
        'phase': lastPhase,
        'durationMs': (now - phaseStarted) / 1000,
        'nextPhase': next,
      });
    }
    lastPhase = next;
    phaseStarted = now;
  }

  resources.addListener(recordPhase);
  final engine = core.createTerraEngine();
  final workspace = Workspace(
    engine: engine,
    files: files,
    circuitBackend: engine as CircuitBackend,
    worldCircuitBackend: engine as WorldCircuitBackend,
    regionBackend: engine as RegionBackend,
    playerProjectionBackend: engine as PlayerProjectionBackend,
    onlineResources: resources,
  );
  final controller = ProfiledTerraController(
    workspace,
    recorder,
    cycle,
    cycle < _warmup,
  );
  final run = _Scenario(
    tester,
    workspace,
    controller,
    files,
    recorder,
    cycle,
    cycle < _warmup,
    fixtures,
    fixture,
    transport,
    resources,
  );
  try {
    await run.measure('ui.workspace.mount', () async {
      await tester.pumpWidget(TerraForgeApp(controller: controller));
      await workspace.initialize();
      await run.settle();
    }, interaction: 'mount production TerraForgeApp');
    await run.navigation();
    await run.world();
    await run.mapFiles();
    await run.player();
    await run.pixelAndRegion();
    await run.sandboxCircuit();
    await run.worldCircuit();
    await run.rulesCircuit();
    await run.resourcePaths();
    await run.failAndCancel();
    await run.localFileInputs(localInputs);
  } finally {
    await run.measure('ui.workspace.close', () async {
      await workspace.close();
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      workspace.dispose();
      resources.removeListener(recordPhase);
      resources.dispose();
      files.input = null;
      files.output = null;
      await tester.pump();
    }, interaction: 'close real owners and unmount all production widgets');
  }
}

class _Scenario {
  _Scenario(
    this.tester,
    this.app,
    this.controller,
    this.files,
    this.recorder,
    this.cycle,
    this.warmup,
    this.fixtures,
    this.resourceFixture,
    this.transport,
    this.resources,
  );
  final WidgetTester tester;
  final Workspace app;
  final TerraController controller;
  final _Files files;
  final ProfileRecorder recorder;
  final int cycle;
  final bool warmup;
  final Map<String, Uint8List> fixtures;
  final OnlineFixture resourceFixture;
  final FixtureResourceTransport transport;
  final OnlineResourceService resources;

  Future<void> measure(
    String id,
    Future<void> Function() action, {
    String interaction = 'controller dispatch with production UI rendered',
  }) async {
    if (_debugSmoke) debugPrint('Workflow smoke: $id');
    await recorder.measure(id, cycle, warmup, action, interaction: interaction);
  }

  Future<void> settle() async {
    await tester.pump();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );
    expect(tester.takeException(), isNull);
  }

  Future<void> tap(Finder finder) async {
    expect(finder, findsWidgets);
    await tester.ensureVisible(finder.first);
    await settle();
    await tester.tap(finder.first);
    await settle();
  }

  Future<void> go(String title) async {
    if (find.byType(NavigationBar).evaluate().isNotEmpty) {
      await tap(find.text('更多'));
      await tap(
        find.descendant(of: find.byType(Drawer), matching: find.text(title)),
      );
    } else {
      await tap(find.text(title));
    }
  }

  Future<void> action(
    String id,
    String action, [
    Map<String, Object?> args = const {},
    bool failure = false,
  ]) => measure(id, () async {
    await controller.dispatch(action, args);
    final rules = app.view.result['rulesCircuit'];
    final error = action.startsWith('rules') && rules is Map
        ? rules['error']?.toString() ?? ''
        : app.view.error;
    expect(error, failure ? isNotEmpty : isEmpty, reason: '$id: $error');
    await settle();
  });

  Future<void> load(String fixture, String id) async {
    files.input = PickedFile(fixture, fixtures[fixture]!);
    await action(id, 'import', {'kind': 'world'});
    expect(app.view.worldPreview, isNotNull);
  }

  Future<void> navigation() async {
    for (final title in [
      '世界档案',
      '存档中心',
      '像素工坊',
      '角色实验室',
      '电路实验室',
      '融合画布',
      '世界生成',
      '写入工作流',
      '图鉴与成就',
      '映射方案',
      '设置与资源',
      '工作台',
    ]) {
      await measure(
        'ui.navigation.$title',
        () => go(title),
        interaction: 'pointer tap production navigation',
      );
    }
  }

  Future<void> world() async {
    await go('世界档案');
    await load('synthetic-objects.wld', 'ui.wld.import');
    final originalId = app.view.files.first.id;
    await action('ui.wld.reopen', 'openFile', {'id': originalId});
    await measure('ui.wld.pan-zoom', () async {
      final view = find.descendant(
        of: find.byType(WorldMapView),
        matching: find.byType(InteractiveViewer),
      );
      await panZoom(view);
    }, interaction: 'touch pan plus two-pointer pinch production WorldMapView');
    await measure('ui.wld.overlay-controls', () async {
      await tap(find.byKey(const ValueKey('world-map-load-overlay')));
      expect(app.view.error, isEmpty);
      expect(app.view.worldOverlay, isNotNull);
      for (var bit = 0; bit < 4; bit++) {
        await tap(find.byKey(ValueKey('world-map-wire-$bit')));
      }
      await tap(find.byKey(const ValueKey('world-map-liquids')));
    }, interaction: 'pointer taps overlay load and filters');
    await action('ui.wld.header-edit', 'stageWorld', {
      'field': 'name',
      'value': 'Profile $cycle',
    });
    await action('ui.wld.undo', 'undo', {'canvas': 'world'});
    await action('ui.wld.redo', 'redo', {'canvas': 'world'});
    await tap(find.text('宝箱编辑'));
    await action('ui.chest.rename', 'stageChest', {
      'index': 0,
      'name': 'Benchmark',
    });
    await action('ui.chest.slot-edit', 'stageChest', {
      'index': 0,
      'slot': 0,
      'itemId': 8,
      'quantity': 8,
    });
    await action('ui.chest.organize', 'chestOrganize', {'index': 0});
    await action('ui.chest.clear', 'chestClear', {
      'index': 0,
      'confirmed': true,
    });
    await action('ui.chest.undo', 'undo', {'canvas': 'world'});
    await action('ui.wld.export', 'export', {'kind': 'world'});
    expect(files.output!.bytes, isNotEmpty);
    files.input = files.output;
    await action('ui.wld.export-reopen', 'import', {'kind': 'world'});
    await tap(find.text('地图与基本信息'));
    await go('映射方案');
    await tap(find.text('整图规则'));
    final scheme = WorldRuleScheme(
      name: 'Profile',
      rules: [
        WorldTileRule(where: {'type': 1}, patch: {'wall': 2}, limit: 1),
      ],
    ).toJson();
    await action('ui.world-rules.save', 'worldRulesSave', {'scheme': scheme});
    await action('ui.world-rules.preview', 'worldRulesPreview', {
      'scheme': scheme,
    });
    expect(app.view.worldRulePreviewPng, isNotNull);
    await action('ui.world-rules.apply', 'worldRulesApply', {
      'scheme': scheme,
      'confirmed': true,
    });
    await action('ui.world-rules.undo', 'undo', {'canvas': 'world'});
  }

  Future<void> player() async {
    await go('角色实验室');
    await action('ui.plr.create', 'newPlayer', {'name': 'Synthetic profile'});
    await action('ui.plr.inventory-edit', 'stageInventory', {
      'slot': 0,
      'itemId': 8,
      'quantity': 50,
      'prefix': 0,
    });
    for (final title in [
      '角色属性',
      '装备与外观',
      '背包与物品',
      '增益 / 减益',
      '旅行能力',
      '物品研究',
      '完整编辑器',
    ]) {
      await measure(
        'ui.plr.tab.$title',
        () => tap(find.text(title)),
        interaction: 'pointer tap player tab',
      );
    }
    await action('ui.plr.header-edit', 'stagePlayer', {
      'field': 'name',
      'value': 'Edited profile',
    });
    await action('ui.plr.undo', 'undo', {'canvas': 'player'});
    await action('ui.plr.redo', 'redo', {'canvas': 'player'});
    await action('ui.plr.export', 'export', {'kind': 'player'});
    files.input = files.output;
    await action('ui.plr.export-reopen', 'import', {'kind': 'player'});
    expect(app.view.player['name'], 'Edited profile');
  }

  Future<void> mapFiles() async {
    await go('世界档案');
    await tap(find.text('MAP 探索存档'));
    for (final variant in ['legacy', 'chunked']) {
      final id = 'ui.map.$variant';
      final source = fixtures['synthetic-$variant.map']!;
      files.input = PickedFile('synthetic-$variant.map', source);
      await action('$id.import', 'importMap');
      expect(app.view.map!.width, 512);
      expect(app.view.mapRaster, isNotNull);
      await measure(
        '$id.pan-zoom',
        () => panZoom(
          find.descendant(
            of: find.byType(TerrariaMapPanel),
            matching: find.byType(InteractiveViewer),
          ),
        ),
        interaction: 'pan/pinch actual decoded MAP raster',
      );
      await action('$id.edit', 'editMapRect', {
        'x': 3,
        'y': 4,
        'width': 40,
        'height': 20,
        'light': 255,
        'color': 5,
      });
      expect(app.view.map!.canUndo, isTrue);
      await action('$id.undo', 'undoMap');
      expect(app.view.map!.isModified, isFalse);
      await action('$id.redo', 'redoMap');
      expect(app.view.map!.isModified, isTrue);
      await action('$id.export', 'exportMap');
      expect(files.output!.bytes, isNotEmpty);
      files.input = files.output;
      await action('$id.export-reopen', 'importMap');
      expect(app.view.map!.width, 512);
      final token = app.view.map!.token;
      files.input = PickedFile('corrupt.map', Uint8List.fromList([1, 2, 3]));
      await action('$id.failed-import', 'importMap', {}, true);
      expect(app.view.map!.token, token);
      await action('$id.close', 'closeMap');
      expect(app.view.map, isNull);
    }
    files.input = null;
    await action('ui.map.picker-cancel', 'importMap');
    expect(app.view.map, isNull);
    await action('ui.map.generate-from-wld', 'generateMapFromWorld');
    expect(app.view.map, isNotNull);
    await action('ui.map.generated-export', 'exportMap');
    await action('ui.map.generated-close', 'closeMap');
    await tap(find.text('地图与基本信息'));
  }

  Future<void> pixelAndRegion() async {
    await go('像素工坊');
    await action('ui.pixel.resize', 'resize', {
      'canvas': 'pixel',
      'width': 256,
      'height': 144,
    });
    await measure('ui.pixel.draw', () async {
      await tester.ensureVisible(find.byType(GridCanvas));
      await tester.timedDrag(
        find.byType(GridCanvas),
        const Offset(180, 30),
        const Duration(milliseconds: 350),
      );
      await settle();
    }, interaction: 'continuous pointer stroke production canvas');
    expect(
      app.view.canvases['pixel']!.colors.any((color) => color != 0),
      isTrue,
    );
    await action('ui.pixel.undo', 'undo', {'canvas': 'pixel'});
    await action('ui.pixel.redo', 'redo', {'canvas': 'pixel'});
    await action('ui.pixel.export-png', 'export', {'kind': 'pixelPng'});
    await action('ui.pixel.export-project', 'export', {'kind': 'pixelProject'});
    files.input = files.output;
    await action('ui.pixel.reopen', 'import', {'kind': 'project'});
    await load('synthetic-objects.wld', 'ui.region.load-world');
    await go('融合画布');
    await action('ui.region.load', 'fusionRegion', {
      'x': 1,
      'y': 2,
      'width': 8,
      'height': 3,
    });
    expect(app.view.region!.objectCount, 3);
    await measure('ui.region.pan-zoom', () async {
      await tap(find.text('检查/平移'));
      final canvas = find.descendant(
        of: find.byType(RegionTextureCanvas),
        matching: find.byType(InteractiveViewer),
      );
      await panZoom(canvas);
    }, interaction: 'touch pan and pinch production layered region canvas');
    await action('ui.region.select', 'regionSelect', {'x': 0, 'y': 0});
    await action('ui.region.edit', 'regionEdit', {
      'patch': {'wall': 2},
    });
    await action('ui.region.undo', 'undo', {'canvas': 'fusion'});
    await action('ui.region.redo', 'redo', {'canvas': 'fusion'});
    await action('ui.region.export', 'export', {'kind': 'fusionProject'});
    files.input = files.output;
    await action('ui.region.reopen', 'import', {'kind': 'project'});
    expect(app.view.region!.objectCount, 3);
  }

  Future<void> sandboxCircuit() async {
    await go('电路实验室');
    await tap(find.text('电路沙盒'));
    await action('ui.circuit.resize', 'resize', {
      'canvas': 'circuit',
      'width': 64,
      'height': 40,
    });
    await action('ui.circuit.place', 'circuitPlace', {
      'x': 2,
      'y': 3,
      'element': 'switchInput',
    });
    await action('ui.circuit.wire', 'paint', {
      'canvas': 'circuit',
      'x': 2,
      'y': 3,
      'wireColor': 0,
    });
    await action('ui.circuit.select', 'circuitSelect', {
      'x': 1,
      'y': 2,
      'width': 4,
      'height': 3,
    });
    await action('ui.circuit.copy', 'circuitCopy');
    await action('ui.circuit.rotate', 'circuitRotate');
    await action('ui.circuit.paste', 'circuitPaste', {'x': 10, 'y': 5});
    await action('ui.circuit.route-preview', 'circuitRoutePreview', {
      'startX': 20,
      'startY': 20,
      'endX': 30,
      'endY': 25,
      'mask': 1,
    });
    await action('ui.circuit.route-commit', 'circuitConfirmEdit');
    await action('ui.circuit.trigger', 'circuitTrigger', {'x': 2, 'y': 3});
    await action('ui.circuit.tick', 'circuitStep');
    await measure('ui.circuit.run-pause', () async {
      await controller.dispatch('circuitToggle');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await controller.dispatch('circuitToggle');
      await settle();
      expect(app.view.circuitTick, greaterThan(0));
      expect(app.view.error, isEmpty);
    });
    await action('ui.circuit.undo', 'undo', {'canvas': 'circuit'});
    await action('ui.circuit.redo', 'redo', {'canvas': 'circuit'});
    await action('ui.circuit.export', 'export', {'kind': 'circuitProject'});
    files.input = files.output;
    await action('ui.circuit.reopen', 'import', {'kind': 'project'});
    await action('ui.circuit.clear', 'clear', {'canvas': 'circuit'});
  }

  Future<void> worldCircuit() async {
    await load('synthetic-circuit.wld', 'ui.tcw.load-world');
    await tap(find.text('世界电路'));
    await action('ui.tcw.open', 'worldCircuitOpen');
    await action('ui.tcw.viewport', 'worldCircuitViewport', {
      'x': 0,
      'y': 0,
      'width': 7,
      'height': 32,
    });
    await action('ui.tcw.trigger', 'worldCircuitTrigger', {
      'x': 2,
      'y': 10,
      'mask': 1,
    });
    await action('ui.tcw.tick', 'worldCircuitStep');
    await measure('ui.tcw.run-pause', () async {
      await controller.dispatch('worldCircuitToggle');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await controller.dispatch('worldCircuitToggle');
      await settle();
      expect((app.view.result['worldCircuit'] as Map)['ticks'], greaterThan(1));
    });
    await action('ui.tcw.reset', 'worldCircuitReset');
    await action('ui.tcw.fragments', 'worldCircuitFragments');
    await action('ui.tcw.export', 'worldCircuitSave');
    await action('ui.tcw.reopen', 'worldCircuitOpen');
    await action('ui.tcw.close', 'worldCircuitClose', {'discard': true});
  }

  Future<void> rulesCircuit() async {
    await tap(find.text('完整电路工坊'));
    await action('ui.rules.open', 'rulesOpen');
    await action('ui.rules.new', 'rulesNew', {'title': 'Synthetic profile'});
    Future<void> edit(String method, [List<Object?> args = const []]) => action(
      'ui.rules.$method',
      'rulesEdit',
      {'method': method, 'args': args},
    );
    await edit('paint', [
      {'x': 1, 'y': 3},
      {'x': 8, 'y': 3},
      {'tool': 'wire', 'mask': 1},
    ]);
    await edit('placeTile', [
      {'kind': 'switch', 'x': 1, 'y': 3},
    ]);
    await action('ui.rules.place-lamp', 'rulesEdit', {
      'method': 'placeTile',
      'args': [
        {'kind': 'gemspark', 'x': 8, 'y': 3},
      ],
    });
    await edit('select', [
      {'x': 1, 'y': 3, 'width': 8, 'height': 1},
    ]);
    await edit('copy');
    await edit('paste', [
      {'x': 1, 'y': 8},
    ]);
    await edit('undo');
    await edit('redo');
    await action('ui.rules.route-preview', 'rulesPreviewRoute', {
      'startX': 1,
      'startY': 16,
      'endX': 10,
      'endY': 16,
      'mask': 1,
    });
    final state = app.view.result['rulesCircuit'] as Map;
    final preview = (state['snapshot'] as Map)['preview'] as Map;
    await action('ui.rules.route-commit', 'rulesCommitPreview', {
      'token': preview['token'],
    });
    await action('ui.rules.route-preview-to-cancel', 'rulesPreviewRoute', {
      'startX': 1,
      'startY': 20,
      'endX': 10,
      'endY': 20,
      'mask': 2,
    });
    await action('ui.rules.route-cancel', 'rulesCancelPreview');
    await action('ui.rules.network-preview', 'rulesPreviewNetwork', {
      'x': 1,
      'y': 3,
      'mask': 1,
    });
    final networkState = app.view.result['rulesCircuit'] as Map;
    final networkPreview = (networkState['snapshot'] as Map)['preview'] as Map;
    await action('ui.rules.network-commit', 'rulesCommitPreview', {
      'token': networkPreview['token'],
    });
    await action('ui.rules.demo', 'rulesDemo', {'name': 'hello'});
    await action('ui.rules.debug', 'rulesDebug', {'enabled': true});
    await measure('ui.rules.pan-zoom', () async {
      final stage = find.byKey(const ValueKey('authoritative-circuit-stage'));
      await tester.ensureVisible(stage);
      await settle();
      final center = tester.getCenter(stage);
      for (var i = 0; i < 12; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: Offset(0, i < 6 ? -20 : 20),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pinch(stage);
      await settle();
    }, interaction: 'mouse wheel and two-pointer pinch production schematic');
    await action('ui.rules.trigger', 'rulesSimulate', {
      'method': 'interact',
      'args': [18, 8],
    });
    await action('ui.rules.tick60', 'rulesSimulate', {
      'method': 'step',
      'args': [60],
    });
    await measure('ui.rules.run-pause', () async {
      await controller.dispatch('rulesToggleRun');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await controller.dispatch('rulesPause');
      await settle();
      expect(
        (app.view.result['rulesCircuit'] as Map)['error']?.toString() ?? '',
        isEmpty,
      );
    });
    await action('ui.rules.reset', 'rulesReset');
    await action('ui.rules.export', 'rulesExport');
    files.input = files.output;
    await action('ui.rules.reopen', 'rulesImport');
    await action('ui.rules.recover', 'rulesRecover');
    await action('ui.rules.close', 'rulesClose');
  }

  Future<void> resourcePaths() async {
    await go('图鉴与成就');
    await tap(find.text('线上资源'));
    await measure('ui.resources.check-version', () async {
      await resources.checkForUpdate();
      await settle();
      expect(resources.available, isNotNull);
    });
    await measure('ui.resources.cancel', () async {
      final reached = Completer<void>();
      transport.beforeFetch = (path, token) async {
        if (path == resourceFixture.itemPath) {
          if (!reached.isCompleted) reached.complete();
          await token.signal;
          token.check();
        }
      };
      final install = resources.install();
      final cancelled = expectLater(
        install,
        throwsA(isA<OnlineResourceCancelled>()),
      );
      await reached.future.timeout(const Duration(seconds: 10));
      resources.cancel();
      await cancelled;
      await settle();
      expect(resources.phase, 'paused');
      transport.beforeFetch = null;
    });
    await measure('ui.resources.corrupt-failure', () async {
      transport.corruptPath = resourceFixture.itemPath;
      await expectLater(resources.install(), throwsFormatException);
      await settle();
      expect(resources.activeStore, isNull);
      expect(find.byKey(const Key('online-resource-error')), findsOneWidget);
      transport.corruptPath = null;
    });
    await measure('ui.resources.retry-install', () async {
      await resources.install();
      await controller.dispatch('activateOnlineResources');
      await settle();
      expect(resources.activeStore, isNotNull);
      expect(app.view.resources, isNotNull);
    });
    await measure('ui.resources.atomic-failure', () async {
      final next = OnlineFixture('Next synthetic');
      transport.add(next);
      transport.approvalBytes = next.approval(sequence: '2');
      final previous = resources.activeStore!.packSha256;
      final storage = resources.storage as FaultResourceStorage;
      storage.failCommit = true;
      await expectLater(resources.install(), throwsStateError);
      storage.failCommit = false;
      await settle();
      expect(resources.activeStore!.packSha256, previous);
    });
    await measure('ui.resources.atomic-retry', () async {
      await resources.install();
      await controller.dispatch('activateOnlineResources');
      await settle();
      expect(
        resources.activeStore!.catalog.byId('items', 17)!.name,
        'Next synthetic',
      );
    });
    await measure(
      'ui.resources.offline-restore',
      () async {
        transport.offline = true;
        final restored = OnlineResourceService(
          transport: transport,
          storage: resources.storage,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: OnlineResourcesPanel(
                  service: restored,
                  onActivate: (_, assertUsable) => assertUsable(),
                ),
              ),
            ),
          );
          await restored.initialize();
          await settle();
          expect(
            restored.activeStore!.packSha256,
            resources.activeStore!.packSha256,
          );
          expect(find.textContaining('已启用 Terraria'), findsOneWidget);
        } finally {
          await tester.pumpWidget(TerraForgeApp(controller: controller));
          restored.dispose();
          transport.offline = false;
          await settle();
        }
      },
      interaction: 'production resource panel cold restore with explicitly offline synthetic transport',
    );
    await action('ui.resources.release-cache', 'clearResourceMemory');
  }

  Future<void> localFileInputs(
    List<({String kind, PickedFile file})> configured,
  ) async {
    for (var index = 0; index < configured.length; index++) {
      final input = configured[index];
      final id = 'ui.local.${input.kind}.$index';
      await go(input.kind != 'player' ? '世界档案' : '角色实验室');
      if (input.kind == 'map') {
        await tap(find.text('MAP 探索存档'));
        files.input = input.file;
        await action('$id.import', 'importMap');
        expect(app.view.mapRaster, isNotNull);
        await measure(
          '$id.pan-zoom',
          () => panZoom(
            find.descendant(
              of: find.byType(TerrariaMapPanel),
              matching: find.byType(InteractiveViewer),
            ),
          ),
          interaction: 'pan/pinch explicitly configured local MAP raster',
        );
        await action('$id.export', 'exportMap');
        files.input = files.output;
        await action('$id.export-reopen', 'importMap');
        await action('$id.close', 'closeMap');
        continue;
      }
      if (input.kind == 'world') await tap(find.text('地图与基本信息'));
      files.input = input.file;
      await action('$id.import', 'import', {'kind': input.kind});
      if (input.kind == 'world') {
        expect(app.view.worldPreview, isNotNull);
        await measure(
          '$id.pan-zoom',
          () => panZoom(
            find.descendant(
              of: find.byType(WorldMapView),
              matching: find.byType(InteractiveViewer),
            ),
          ),
          interaction: 'pan/pinch explicitly configured local WLD preview',
        );
        await action('$id.overlay', 'worldOverlay', {
          'x': 0,
          'y': 0,
          'width': ((app.view.world['maxTilesX'] as num?)?.toInt() ?? 1).clamp(
            1,
            64,
          ),
          'height': ((app.view.world['maxTilesY'] as num?)?.toInt() ?? 1).clamp(
            1,
            64,
          ),
        });
      } else {
        expect(app.view.player, isNotEmpty);
        await measure('$id.tabs', () async {
          for (final title in ['角色属性', '装备与外观', '背包与物品']) {
            await tap(find.text(title));
          }
        }, interaction: 'pointer navigation explicitly configured local PLR');
      }
      await action('$id.export', 'export', {'kind': input.kind});
      files.input = files.output;
      await action('$id.export-reopen', 'import', {'kind': input.kind});
    }
  }

  Future<void> failAndCancel() async {
    await go('工作台');
    await measure('ui.import-dialog.cancel', () async {
      await tap(find.text('导入存档'));
      await tap(find.text('取消'));
    }, interaction: 'pointer open/dismiss production import dialog');
    files.input = null;
    final count = app.view.files.length;
    await action('ui.picker.cancel', 'import', {'kind': 'world'});
    expect(app.view.files.length, count);
    files.input = PickedFile('corrupt.wld', Uint8List.fromList([0, 1, 2]));
    await action('ui.wld.failed-import', 'import', {'kind': 'world'}, true);
    await action('ui.error.dismiss', 'dismissError');
    files.cancelSave = true;
    await action('ui.export.cancel', 'export', {'kind': 'player'});
    files.cancelSave = false;
  }

  Future<void> panZoom(Finder finder) async {
    expect(finder, findsOneWidget);
    await tester.ensureVisible(finder);
    await settle();
    await pinch(finder);
    await tester.timedDrag(
      finder,
      const Offset(75, 40),
      const Duration(milliseconds: 300),
    );
    await settle();
  }

  Future<void> pinch(Finder finder) async {
    final center = tester.getCenter(finder);
    final a = await tester.startGesture(
      center - const Offset(25, 0),
      pointer: 1,
    );
    final b = await tester.startGesture(
      center + const Offset(25, 0),
      pointer: 2,
    );
    for (var i = 1; i <= 12; i++) {
      await a.moveTo(center - Offset(25 + i * 3, 0));
      await b.moveTo(center + Offset(25 + i * 3, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
  }
}
