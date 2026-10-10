// Opt-in pinned public upstream world, downloaded and hash-verified by CI.
// Not included by lib/main.dart; personal input discovery is never performed.
import 'dart:developer' show Timeline;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart'
    if (dart.library.js_interop) 'package:terraforge/engine/web_engine.dart'
    as core;
import 'package:terraforge/engine/world_circuit_factory.dart'
    if (dart.library.js_interop) 'package:terraforge/engine/world_circuit_factory_web.dart'
    as circuit_factory;
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import 'support/computer_inputs_native.dart'
    if (dart.library.js_interop) 'support/computer_inputs_web.dart'
    as inputs;
import 'support/profile_memory_native.dart'
    if (dart.library.js_interop) 'support/profile_memory_web.dart'
    as memory;
import 'support/profile_recorder.dart';
import 'support/profile_controller.dart';
import 'support/profile_os_memory_native.dart'
    if (dart.library.js_interop) 'support/profile_os_memory_web.dart'
    as os_memory;
import 'support/computer_profile_storage.dart';
import 'support/generic_circuit_profile.dart';

class _SourceFiles implements WorldCircuitFileGateway {
  final WorldCircuitSource world;
  final ComputerProfileStorage storage;
  WorldCircuitSource? savedWorld;
  bool useSavedWorld = false;
  _SourceFiles(this.world, this.storage);
  @override
  Future<WorldCircuitSource?> pick() async =>
      useSavedWorld ? savedWorld! : world;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    final retained = await storage.retain(source, name);
    savedWorld = retained;
    return true;
  }
}

class _ObservedBackend
    implements WorldCircuitSourceBackend, WorldCircuitExternalOwnerBackend {
  _ObservedBackend(this.inner, this.events);
  final WorldCircuitSourceBackend inner;
  final List<Map<String, Object?>> events;
  WorldCircuitResult? latest;
  int? session;
  int nativeTicks = 0;
  @override
  bool get completesCircuitBatchFromExternalEvent =>
      inner is WorldCircuitExternalOwnerBackend &&
      (inner as WorldCircuitExternalOwnerBackend)
          .completesCircuitBatchFromExternalEvent;

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource source, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    final event = <String, Object?>{
      'kind': 'native-open',
      'startUs': Timeline.now,
      'sourceBytes': source.length,
    };
    events.add(event);
    try {
      latest = await inner.openWorldCircuitSource(
        source,
        onProgress: onProgress,
      );
      session = latest!.session;
      event.addAll({
        'outcome': 'ready',
        'session': session,
        'circuitAbi': latest!.stats[0],
        'sourceSha256': latest!.sourceSha256,
      });
      return latest!;
    } catch (error) {
      event.addAll({
        'outcome': 'failed-or-cancelled',
        'error': error.toString(),
      });
      rethrow;
    } finally {
      event['endUs'] = Timeline.now;
    }
  }

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List world) =>
      throw StateError('Only WLD source handles are permitted');

  void _observeTick(WorldCircuitCommand command) {
    if (command.words[1] == 3) {
      nativeTicks += command.words[8];
    }
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int id,
    WorldCircuitCommand command,
  ) async {
    latest = await inner.commandWorldCircuit(id, command);
    _observeTick(command);
    return latest!;
  }

  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int id, WorldCircuitCommand command, WorldCircuitCommand pixels,
  ) async {
    if (inner is WorldCircuitBatchBackend) {
      final frame = await (inner as WorldCircuitBatchBackend)
          .commandAndReadPixels(id, command, pixels);
      latest = frame.command;
      _observeTick(command);
      return frame;
    }
    final result = await commandWorldCircuit(id, command);
    return WorldCircuitBatchResult(command: result,
        pixels: await commandWorldCircuit(id, pixels));
  }

  @override
  Future<void> closeWorldCircuit(int id) async {
    final start = Timeline.now;
    await inner.closeWorldCircuit(id);
    session = null;
    // Intentionally retain the last wrapper result for the first checkpoint.
    events.add({
      'kind': 'native-close',
      'session': id,
      'startUs': start,
      'endUs': Timeline.now,
      'outcome': 'acknowledged',
    });
  }

  @override
  Future<void> cancelWorldCircuitOperation() =>
      inner.cancelWorldCircuitOperation();
  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() =>
      inner.worldCircuitProgress();
  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) =>
      inner.releaseWorldCircuitSource(source);
}

class _NoSmallFiles implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) => throw StateError('Use explicit WLD source handles');
  @override
  Future<bool> save(String name, Uint8List bytes) => throw StateError('Use streamed WLD outputs');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('generic full WLD controls, sparse display and lifecycle profile', (tester) async {
    if (!kProfileMode) {
      fail('Use flutter drive --profile');
    }
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final source = await inputs.computerInput();
    const cycles = int.fromEnvironment('COMPUTERRARIA_PROFILE_CYCLES', defaultValue: 2);
    const seconds = int.fromEnvironment('COMPUTERRARIA_PROFILE_SECONDS', defaultValue: 30);
    if (cycles < 1 || cycles > 8 || seconds < 30 || seconds > 60) {
      fail('Invalid bounded profile duration');
    }
    final observedRefreshRate = tester.view.display.refreshRate;
    final hasRefreshRate = observedRefreshRate.isFinite && observedRefreshRate > 0;
    final refreshRate = hasRefreshRate ? observedRefreshRate : 60.0;
    final recorder = ProfileRecorder(frameBudgetUs: 1000000 / refreshRate,
        profile: true, currentRss: memory.currentRss);
    final observations = <Map<String, Object?>>[], snapshots = <Map<String, Object?>>[];
    var status = 'failed', stage = 'mount';
    String? failure, failureStack;
    os_memory.OsLoadingMemoryProbe? osProbe;
    Map<String, Object?>? loadingMemory;
    var priorCancelledLoad = false, completeLoads = 0, loadAttempts = 0;
    recorder.start();
    try {
      osProbe = await os_memory.OsLoadingMemoryProbe.start();
      snapshots.add({'phase': 'baseline', ...await memory.memorySnapshot()});
      for (var cycle = 0; cycle < cycles; cycle++) {
        for (final optimized in [false, true]) {
          final mode = optimized ? 'optimized' : 'standard';
          final engine = core.createTerraEngine();
          final backend = _ObservedBackend(circuit_factory.createWorldCircuitBackend(engine)! as WorldCircuitSourceBackend, []);
          final storage = await createComputerProfileStorage();
          final sourceFiles = _SourceFiles(source, storage);
          Workspace createWorkspace() => Workspace(engine: engine, files: _NoSmallFiles(),
              vault: storage.vault, worldCircuitBackend: backend, worldCircuitFiles: sourceFiles);
          var workspace = createWorkspace();
          var controller = ProfiledTerraController(workspace, recorder, cycle, false, profileMode: mode);
          Map state() => workspace.worldCircuitView;
          void check() {
            expect(workspace.view.error, isEmpty);
            expect(state()['error'], isNull);
          }
          Future<void> action(String action, [Map<String, Object?> args = const {}]) async {
            await controller.dispatch(action, args);
            await tester.pump();
            check();
          }
          Future<void> measure(String id, Future<void> Function() operation) {
            stage = 'circuit.$id.$mode';
            return recorder.measure(stage, cycle, false, operation,
                interaction: 'actual production controller dispatch and rendered generic WLD panel');
          }
          Future<void> mount() => tester.pumpWidget(MaterialApp(theme: terraTheme(),
              home: Scaffold(body: ListenableBuilder(listenable: workspace.worldCircuitUpdates,
                  builder: (context, child) => SingleChildScrollView(child: WorldCircuitPanel(
                      state: Map<String, Object?>.from(state()), dispatch: controller.dispatch,
                      hostStages: workspace.hostStages))))));
          Future<void> closeWorkspace() async {
            await workspace.close();
            await tester.pumpWidget(const SizedBox());
            controller.dispose();
            workspace.dispose();
          }
          Future<void> observeLoad(String kind, Future<void> Function() operation, {bool cancelled = false}) async {
            await osProbe!.begin({
              'kind': kind, 'cycle': cycle, 'mode': mode, 'hostLoadAttempt': loadAttempts++,
              'sessionSource': sourceFiles.useSavedWorld ? 'exported-reimport-session-source' : 'pinned-public-original-source',
              'priorCancelledLoad': priorCancelledLoad,
              'hostLoadContext': cancelled ? 'cancelled-load-attempt' : completeLoads == 0 ? 'fresh-host-first-complete-load' : 'repeat-in-same-host',
              'cacheState': 'uncontrolled',
            });
            var outcome = 'failed';
            final evidence = <String, Object?>{};
            try {
              await operation();
              if (cancelled) {
                outcome = 'cancelled'; priorCancelledLoad = true;
              } else {
                expect(state()['open'], isTrue);
                expect(backend.latest!.stats[0], 2);
                expect(state()['width'], greaterThan(0));
                expect(state()['height'], greaterThan(0));
                evidence.addAll({'completeWldVerified': true, 'genericViewportInitialized': true,
                  'worldWidth': state()['width'], 'worldHeight': state()['height']});
                outcome = 'ready'; completeLoads++;
              }
            } finally { await osProbe!.end(outcome, evidence); }
          }
          var disposed = false;
          try {
            await mount();
            await measure('choose-world', () => action('worldCircuitChooseWorld'));
            if (cycle == 0 && !optimized) {
              await observeLoad('cancelled-import', () => measure('cancel-import', () async {
                final pending = controller.dispatch('worldCircuitImport');
                final deadline = Stopwatch()..start();
                while (state()['importing'] != true || backend.events.isEmpty) {
                  if (deadline.elapsed > const Duration(seconds: 10)) {
                    fail('Import never became cancellable');
                  }
                  await tester.pump(const Duration(milliseconds: 16));
                }
                await controller.dispatch('worldCircuitCancel');
                await pending;
                await tester.pump();
                expect(state()['open'], isFalse);
                check();
              }), cancelled: true);
            }
            await observeLoad('initial-import', () => measure('import', () => action('worldCircuitImport')));
            // Identity is a property of this explicit public test input only.
            expect(backend.events.last['sourceSha256'], publicCircuitFixtureSha256);
            final selection = GenericCircuitSelection.fromState(state());
            Future<void> selectDisplay() async {
              await action('worldCircuitViewport', selection.displayRegion);
              await action('worldCircuitReadDisplay', selection.displayRegion);
            }
            await measure('select-display', selectDisplay);
            final originalPixels = sha256.convert(state()['displayFrame'] as Uint8List).toString();
            final originalTicks = state()['ticks'] as int;
            if (optimized) {
              await measure('enable-optimization', () => action('worldCircuitOptimization', {'enabled': true}));
            }
            await measure('trigger', () => action('worldCircuitTrigger', selection.trigger));
            final tickBefore = state()['ticks'] as int;
            final nativeBefore = backend.nativeTicks;
            await measure('single-tick', () => action('worldCircuitStep'));
            final tickAfter = state()['ticks'] as int;
            expect(tickAfter - tickBefore, 1);
            expect(backend.nativeTicks - nativeBefore, 1);
            final steadyBefore = state()['ticks'] as int;
            final steadyNativeBefore = backend.nativeTicks;
            final steadyStartedUs = Timeline.now;
            await measure('run-pause', () async {
              await action('worldCircuitToggle');
              expect(state()['running'], isTrue);
              await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: seconds)));
              await action('worldCircuitPause');
              expect(state()['running'], isFalse);
            });
            final steadyWindowMs = (Timeline.now - steadyStartedUs) / 1000;
            final steadyDelta = (state()['ticks'] as int) - steadyBefore;
            expect(steadyDelta, greaterThan(0));
            expect(backend.nativeTicks - steadyNativeBefore, steadyDelta);
            expect(state()['optimizationEnabled'], optimized);
            final pausedPixelSha = sha256.convert(state()['displayFrame'] as Uint8List).toString();
            final row = <String, Object?>{
              'cycle': cycle, 'mode': mode, 'optimizationEnabled': state()['optimizationEnabled'],
              'nativeOptimizationEnabled': backend.latest!.circuitOptimizationEnabled,
              'nativeWireHeadPixelRulesEnabled': backend.latest!.wireHeadPixelRulesEnabled,
              'worldWidth': state()['width'], 'worldHeight': state()['height'],
              'displayRegion': selection.displayRegion, 'trigger': selection.trigger,
              'tickBefore': tickBefore, 'tickAfter': tickAfter, 'singleTickDelta': 1,
              'steadyTickDelta': steadyDelta, 'steadyWindowMs': steadyWindowMs, 'nativeSteadyTickDelta': backend.nativeTicks - steadyNativeBefore,
              'pausedPixelSha256': pausedPixelSha,
              'hostStages': workspace.hostStages.snapshot(),
            };
            snapshots.add({'phase': 'paused-after-steady-run', 'cycle': cycle, 'mode': mode, ...await memory.memorySnapshot()});
            await measure('save', () => action('worldCircuitSave'));
            expect(sourceFiles.savedWorld?.sha256, isNotNull);
            row['savedWldSha256'] = sourceFiles.savedWorld!.sha256;
            // Reset while the session still owns the original source. A later
            // exported-source session would correctly reset to its own export.
            await observeLoad('reset-original', () => measure('reset-original', () => action('worldCircuitReset')));
            expect(state()['ticks'], originalTicks);
            await selectDisplay();
            expect(sha256.convert(state()['displayFrame'] as Uint8List).toString(), originalPixels);
            row['resetRestoredOriginal'] = true;
            await measure('close-exported', () => action('worldCircuitClose', {'discard': true}));
            expect(backend.session, isNull);
            await osProbe!.closePoint({'cycle': cycle, 'mode': mode, 'phase': 'after-export-close'});
            await closeWorkspace(); disposed = true;
            sourceFiles.useSavedWorld = true;
            workspace = createWorkspace();
            controller = ProfiledTerraController(workspace, recorder, cycle, false, profileMode: mode);
            disposed = false;
            await mount();
            await measure('reselect-exported-world', () => action('worldCircuitChooseWorld'));
            final beforeReopen = backend.nativeTicks;
            await observeLoad('saved-reimport', () => measure('reimport', () => action('worldCircuitImport')));
            expect(backend.events.last['sourceSha256'], sourceFiles.savedWorld!.sha256);
            expect(backend.nativeTicks, beforeReopen);
            await selectDisplay();
            expect(sha256.convert(state()['displayFrame'] as Uint8List).toString(), pausedPixelSha);
            row['reopenPreservedSelectedPixels'] = true;
            await measure('close', () => action('worldCircuitClose', {'discard': true}));
            expect(state()['open'], isFalse); expect(backend.session, isNull);
            row['closed'] = true; observations.add(row);
            await osProbe!.closePoint({'cycle': cycle, 'mode': mode, 'phase': 'after-final-close'});
            await closeWorkspace(); disposed = true;
            snapshots.add({'phase': 'after-close', 'cycle': cycle, 'mode': mode, ...await memory.memorySnapshot()});
          } finally {
            if (!disposed) {
              await closeWorkspace();
            }
            await storage.close();
          }
        }
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      for (final row in recorder.results().where((row) => (row['id'] as String).startsWith('circuit.run-pause.'))) {
        expect(row['frameCount'], greaterThan(0));
      }
      if (!kIsWeb) {
        expect(snapshots.every((row) => row['heapUsedBytes'] != null), isTrue);
      }
      loadingMemory = await osProbe.finish();
      if (!kIsWeb) {
        expect(loadingMemory['status'], 'observed');
        expect((loadingMemory['windows'] as List).length, cycles * 6 + 1);
        expect((loadingMemory['closeSamples'] as List).length, cycles * 4);
      }
      status = 'passed';
    } catch (error, stack) {
      failure = error.toString(); failureStack = stack.toString(); rethrow;
    } finally {
      recorder.stop();
      loadingMemory ??= await osProbe?.finish();
      final report = <String, dynamic>{
        'schema': 'abc.generic-world-profile.v1', 'workloadId': genericCircuitWorkloadId,
        'inputFormat': 'wld-only', 'circuitAbi': 2, 'status': status, 'buildMode': 'profile',
        'dispatcherCoverageSchema': 1, 'loadingOperationCoverage': 'generic-initial-reimport-reset-v1',
        'cycles': cycles, 'steadySecondsPerMode': seconds, 'modes': ['standard', 'optimized'],
        'excludedWarmupCycles': 0, 'lastStage': stage, 'failure': failure, 'failureStack': failureStack,
        'viewport': {'physicalWidth': tester.view.physicalSize.width, 'physicalHeight': tester.view.physicalSize.height,
          'devicePixelRatio': tester.view.devicePixelRatio},
        'displayRefreshRateHz': observedRefreshRate, 'frameBudgetUs': 1000000 / refreshRate,
        'frameBudgetSource': hasRefreshRate ? 'observed-display-refresh-rate' : 'explicit-60hz-fallback',
        'toolchain': {'flutterRevisionPin': '5fc346839b5d0eef006ed8404392afb4dfae428d',
          'sourceRevision': const String.fromEnvironment('PERF_COMMIT', defaultValue: 'not-supplied')},
        'fixture': {'id': 'public-wld-stress-input', 'wldSha256': publicCircuitFixtureSha256, 'wldBytes': source.length},
        'runtime': {...memory.runtimeMetadata(), 'flutterVersion': const String.fromEnvironment('PERF_FLUTTER_VERSION'),
          'commit': const String.fromEnvironment('PERF_COMMIT'), 'checkedOutHead': const String.fromEnvironment('PERF_CHECKED_OUT_HEAD'),
          'workingTreeDirty': const bool.fromEnvironment('PERF_WORKTREE_DIRTY', defaultValue: true),
          'renderer': const String.fromEnvironment('PERF_RENDERER', defaultValue: 'unspecified'),
          'runner': const String.fromEnvironment('PERF_RUNNER', defaultValue: 'unspecified'), ...memory.runtimeOverrides()},
        'methodology': 'Every lifecycle retained, cache uncontrolled. Ordinary direct wire pulse, one tick, timed generic run/pause and user-selected sparse ROI. No ROM or CPU-specific app action. Different workload from historical physical computer profiles.',
        'operations': recorder.results(), 'controllerOperations': recorder.controllerResults(),
        'observations': observations, 'inputLatencies': <Object?>[], 'memory': snapshots,
        'loadingOsMemory': loadingMemory, 'clockDiagnostics': recorder.clockDiagnostics(),
        'limits': ['Panel runtime rebuilds listen to worldCircuitUpdates and read worldCircuitView; full workspace reads occur only in explicit error checks and lifecycle observation. Controller completion timing is not physical-input-to-raster latency.',
          'Explicit source gateway excludes operating system file picker latency.',
          'Unknown refresh rate remains unavailable; nominal 60 Hz only labels frame-time reference.',
          'Linux or browser profile data does not establish target-device smoothness or long-term memory stability.'],
      };
      binding.reportData = report;
      await memory.writeStandaloneReport(report);
      await memory.closeMemoryProbe();
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
