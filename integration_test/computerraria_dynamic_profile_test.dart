// Opt-in public fixture diagnostic. No production ROM UI or NPC emulation.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_factory.dart' as circuit;
import 'package:terraforge/engine/world_circuit_session.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import '../test/support/computerraria/fixture_driver.dart';
import '../test/support/computerraria/layout.dart';
import 'support/computer_inputs_native.dart' as inputs;
import 'support/computer_profile_storage.dart';
import 'support/computerraria_dynamic_backend.dart';
import 'support/profile_controller.dart';
import 'support/profile_recorder.dart';

const _programSha =
    'd2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d';
const _region = <String, Object?>{
  'x': 6485,
  'y': 800,
  'width': 64,
  'height': 48,
};

Future<String> _fileHash(WorldCircuitSource source) async {
  final path = source.path;
  if (path == null) throw StateError('Native source path required');
  return (await sha256.bind(File(path).openRead()).first).toString();
}

class _NoSmallFiles implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) =>
      throw StateError('Use explicit ranged WLD sources');
  @override
  Future<bool> save(String name, Uint8List bytes) =>
      throw StateError('Use source-backed WLD output');
}

class _SourceFiles implements WorldCircuitFileGateway {
  _SourceFiles(this.input, this.storage);
  final WorldCircuitSource input;
  final ComputerProfileStorage storage;
  WorldCircuitSource? saved;
  @override
  Future<WorldCircuitSource?> pick() async => input;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    // This owned temporary copy never names the original or a user destination.
    // It does not stand in for production overwrite-confirmation coverage.
    saved = await storage.retain(source, name);
    return true;
  }
}

Future<WorldCircuitSource> _prepare(
  WorldCircuitSource original,
  Uint8List program,
  ComputerProfileStorage storage,
  Map<String, Object?> report,
) async {
  final engine = core.createTerraEngine();
  final backend = ComputerrariaDynamicBackend(
    circuit.createWorldCircuitBackend(engine)! as WorldCircuitSourceBackend,
  );
  final session = WorldCircuitSession.fromSource(backend, original);
  WorldCircuitSource? leased;
  report['commands'] = backend.events;
  final started = Timeline.now;
  try {
    await session.open();
    expect(session.result!.sourceSha256, ComputerrariaComputer.sourceSha256);
    final driver = ComputerrariaFixtureDriver(session.command);
    expect(await driver.verifyFixture(session.result!), isTrue);
    await driver.loadProgram('pong.bin', program);
    expect(driver.programIncomplete, isFalse);
    final exported = await session.command(WorldCircuitCommand.save());
    final outputSource =
        exported.worldSource ??
        (throw StateError('Derived preparation did not export a WLD'));
    leased = outputSource;
    final retained = await storage.retain(
      outputSource,
      'public-derived-pong.wld',
    );
    final digest = await _fileHash(retained);
    expect(digest, outputSource.sha256);
    expect(digest, isNot(ComputerrariaComputer.sourceSha256));
    report.addAll({
      'status': 'passed',
      'originalSha256': ComputerrariaComputer.sourceSha256,
      'originalBytes': original.length,
      'derivedSha256': digest,
      'derivedBytes': retained.length,
      'programSha256': sha256.convert(program).toString(),
      'programBytes': program.length,
      'gameplayWarmupPulses': 0,
      'resetClockPulses': backend.events
          .where((e) => e['kind'] == 'native-command')
          .map((e) => e['words']! as List<int>)
          .where((w) => w[1] == 2 && w[2] == 3194 && w[3] == 153)
          .fold<int>(0, (sum, w) => sum + w[8]),
      'inputKind': 'derived-public-world-with-physical-ROM-lamp-writes',
      'preparationMs': (Timeline.now - started) / 1000,
      'provenance': driver.savedProvenance(digest).toJson(),
    });
    return WorldCircuitSource.file(
      path: retained.path!,
      length: retained.length,
      name: 'public-derived-pong.wld',
      sha256: digest,
    );
  } catch (error) {
    report.addAll({'status': 'failed', 'failure': error.toString()});
    rethrow;
  } finally {
    try {
      await session.close();
    } finally {
      if (leased != null) await backend.releaseWorldCircuitSource(leased);
      session.dispose();
    }
  }
}

List<int> _passiveRamPoints() {
  final points = <int>[];
  final addresses = [
    for (var n = 0; n < 16; n++) 0x100000 + n * 4,
    for (var n = 0; n < 256; n++) 0x15bc00 + n * 4,
  ];
  for (final address in addresses) {
    for (var bit = 0; bit < 32; bit++) {
      final (x, y) = ComputerrariaComputer.ramLamp(address, bit);
      points.addAll([x, y, 0, 0]);
    }
  }
  return points;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('public derived WLD, real clock and visible PixelBox lifecycle', (
    tester,
  ) async {
    if (!kProfileMode || !Platform.isLinux) {
      fail('This bounded diagnostic requires actual Linux Flutter profile');
    }
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final outputPath =
        Platform.environment['TERRA_UI_PROFILE_OUTPUT'] ??
        (throw StateError('Explicit profile output path required'));
    final standalonePath =
        Platform.environment['TERRA_UI_PROFILE_STANDALONE_OUTPUT'] ??
        (throw StateError('Explicit standalone output path required'));
    final pongPath =
        Platform.environment['COMPUTERRARIA_PONG'] ??
        (throw StateError('Explicit public Pong path required'));
    final observedHz = tester.view.display.refreshRate;
    final knownHz = observedHz.isFinite && observedHz > 0;
    final recorder = ProfileRecorder(
      frameBudgetUs: 1000000 / (knownHz ? observedHz : 60),
      profile: true,
    );
    final modeResults = <Map<String, Object?>>[];
    final preparation = <String, Object?>{'status': 'pending'};
    final report = <String, dynamic>{
      'schema': 'abc.computerraria-dynamic-ui.v1',
      'workloadId': 'public-derived-computerraria-external-clock-v1',
      'status': 'failed',
      'inputFormat': 'wld-only',
      'circuitAbi': 2,
      'buildMode': 'profile',
      'runtime': {
        'commit': const String.fromEnvironment('PERF_COMMIT'),
        'checkedOutHead': const String.fromEnvironment('PERF_CHECKED_OUT_HEAD'),
        'workingTreeDirty': const bool.fromEnvironment(
          'PERF_WORKTREE_DIRTY',
          defaultValue: true,
        ),
        'flutterVersion': const String.fromEnvironment('PERF_FLUTTER_VERSION'),
        'dartVersion': Platform.version,
        'osVersion': Platform.operatingSystemVersion,
        'processors': Platform.numberOfProcessors,
        'platform': 'linux',
        'renderer': const String.fromEnvironment('PERF_RENDERER'),
        'runner': const String.fromEnvironment('PERF_RUNNER'),
        'hostPid': pid,
      },
      'displayRefreshRateHz': observedHz,
      'frameBudgetSource': knownHz
          ? 'observed-display-refresh-rate'
          : 'explicit-60hz-fallback',
      'frameBudgetUs': recorder.frameBudgetUs,
      'preparation': preparation,
      'modes': ['standard', 'optimized'],
      'modeResults': modeResults,
      'originalAutomaticNpcClockSupported': false,
      'productionRomUiAdded': false,
      'physicalInputLatencyMeasured': false,
      'deviceFpsClaim': false,
      'limits': [
        'A test-only external clock stimulates real compiled wires; production '
            'ticks and panel remain unchanged. NPC motion/collisions are absent.',
        'Prepared WLD contains physically written program lamps. Original and '
            'derived import timings are different workloads.',
        'OFF is an expected-dark fixed electrical-trace compatibility case; '
            'only ON receives a 15-second dynamic-display observation.',
        'Native screen changes, production decoded images, engine frames and '
            'physical display presentation are separate observations.',
        'Unknown refresh and llvmpipe cannot establish target-device smoothness.',
        'No OS picker, destination overwrite protection, sustained memory '
            'plateau or private-world compatibility is measured.',
        'PNG screenshots are outside the timed window. Actual RawImage probes '
            'read decoded pixels at most every 250ms during the ON window.',
        'Timed observations include full production view reads, RGBA hashing, '
            'native record decoding and trace bookkeeping. These are not '
            'observer-free product frame measurements.',
      ],
    };
    ComputerProfileStorage? storage;
    Workspace? workspace;
    ProfiledTerraController? controller;
    ComputerrariaDynamicBackend? backend;
    VoidCallback? observer;
    Future<void> Function()? finishVisibleProbe;
    WorldCircuitSource? originalForCleanup;
    String? originalHashBefore;
    var stage = 'public-source-verification';
    recorder.start();
    try {
      final original = await inputs.computerInput();
      originalForCleanup = original;
      originalHashBefore = await _fileHash(original);
      report['originalSourceSha256Before'] = originalHashBefore;
      expect(originalHashBefore, ComputerrariaComputer.sourceSha256);
      final program = await File(pongPath).readAsBytes();
      expect(program.length, 2288);
      expect(sha256.convert(program).toString(), _programSha);
      final ownedStorage = await createComputerProfileStorage();
      storage = ownedStorage;
      stage = 'prepare-derived-public-world';
      final prepared = await _prepare(
        original,
        program,
        ownedStorage,
        preparation,
      );
      final ramPoints = _passiveRamPoints();
      for (final optimized in [false, true]) {
        final mode = optimized ? 'optimized' : 'standard';
        final row = <String, Object?>{
          'mode': mode,
          'status': 'failed',
          'actualPixelCount': 0,
          'fixedTraceExpectedDark': !optimized,
          'sourceKind': 'derived-public-program-preloaded',
          'sourceSha256': prepared.sha256,
          'runStimulus': 'test-external-clock128-before-original-ticks6',
        };
        modeResults.add(row);
        final allBackendEvents = <List<Map<String, Object?>>>[];
        row['sessionCommandTraces'] = allBackendEvents;
        final allNativeFrames = <List<Map<String, Object?>>>[];
        row['sessionActualPixelTraces'] = allNativeFrames;
        final uiChanges = <Map<String, Object?>>[];
        row['uiStateChanges'] = uiChanges;
        var collectUi = false;
        String? lastUiHash;
        var observerCalls = 0;
        var observerTotalUs = 0;
        Map<String, Object?> state() => workspace!.worldCircuitView;
        void check() {
          expect(workspace!.view.error, isEmpty);
          expect(state()['error'], isNull);
        }

        Future<void> action(
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          await controller!.dispatch(name, args);
          await tester.pump();
          check();
        }

        Future<void> measure(String name, Future<void> Function() body) async {
          stage = '$mode.$name';
          await recorder.measure(
            'dynamic.$name.$mode',
            0,
            false,
            body,
            interaction:
                'production Workspace and WorldCircuitPanel with '
                'explicit test external electrical stimulus',
          );
        }

        Future<void> disposeWorkspace() async {
          collectUi = false;
          if (observer != null && workspace != null) {
            workspace!.worldCircuitChanges.removeListener(observer!);
            observer = null;
          }
          await workspace?.close();
          await tester.pumpWidget(const SizedBox());
          controller?.dispose();
          workspace?.dispose();
          controller = null;
          workspace = null;
        }

        Future<_SourceFiles> mount(WorldCircuitSource source) async {
          final engine = core.createTerraEngine();
          backend = ComputerrariaDynamicBackend(
            circuit.createWorldCircuitBackend(engine)!
                as WorldCircuitSourceBackend,
          );
          expect(backend, isA<WorldCircuitBatchBackend>());
          allBackendEvents.add(backend!.events);
          allNativeFrames.add(backend!.frames);
          final files = _SourceFiles(source, storage!);
          workspace = Workspace(
            engine: engine,
            files: _NoSmallFiles(),
            vault: storage.vault,
            worldCircuitBackend: backend,
            worldCircuitFiles: files,
          );
          controller = ProfiledTerraController(
            workspace!,
            recorder,
            0,
            false,
            profileMode: mode,
          );
          observer = () {
            if (!collectUi) return;
            final began = Timeline.now;
            observerCalls++;
            try {
              final current = state();
              final rgba = current['displayFrame'];
              if (rgba is! Uint8List || current['displayPixelCount'] != 3072) {
                return;
              }
              final digest = sha256.convert(rgba).toString();
              if (digest == lastUiHash) return;
              if (uiChanges.length >= 512) {
                throw StateError('Bounded production UI state trace exceeded');
              }
              lastUiHash = digest;
              uiChanges.add({
                'phase': backend!.phase,
                'atUs': Timeline.now,
                'rgbaSha256': digest,
                'physicalPulses': backend!.physicalPulses,
                'ticks': current['ticks'],
              });
            } finally {
              observerTotalUs += Timeline.now - began;
              row['observerCalls'] = observerCalls;
              row['observerTotalUs'] = observerTotalUs;
            }
          };
          workspace!.worldCircuitChanges.addListener(observer!);
          await tester.pumpWidget(
            MaterialApp(
              theme: terraTheme(),
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: workspace!.worldCircuitChanges,
                  builder: (context, child) => SingleChildScrollView(
                    child: WorldCircuitPanel(
                      state: Map<String, Object?>.from(state()),
                      dispatch: controller!.dispatch,
                      hostStages: workspace!.hostStages,
                    ),
                  ),
                ),
              ),
            ),
          );
          return files;
        }

        Future<void> selectMonitor() async {
          await action('worldCircuitViewport', _region);
          await action('worldCircuitReadDisplay', _region);
          expect(state()['displayPixelCount'], 3072);
          expect(state()['displayFrame'], hasLength(12288));
          row['actualPixelCount'] = 3072;
        }

        String screenHash() =>
            sha256.convert(state()['displayFrame'] as Uint8List).toString();
        Future<String> ramHash() async {
          expect(state()['running'], isFalse);
          final result = await backend!.commandWorldCircuit(
            backend!.activeSession!,
            WorldCircuitCommand.lamps(ramPoints),
          );
          expect(result.records.length, ramPoints.length * 4);
          return sha256.convert(result.records).toString();
        }

        Future<void> stableAfterStop(
          String boundary, {
          bool requireDisarmed = true,
        }) async {
          final pulses = backend!.physicalPulses;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)),
          );
          await tester.pump();
          expect(
            backend!.physicalPulses,
            pulses,
            reason: '$boundary must stop future injected pulses',
          );
          if (requireDisarmed) expect(backend!.clockEnabled, isFalse);
        }

        Future<List<Map<String, Object?>>> fixedTrace(String label) async {
          final start = backend!.frames.length;
          final before = backend!.physicalPulses;
          backend!.arm(label, batches: 12);
          collectUi = true;
          lastUiHash = null;
          await measure(label, () async {
            await action('worldCircuitToggle');
            await tester.runAsync(
              () => backend!.budgetReached.timeout(const Duration(seconds: 90)),
            );
            backend!.disarm('fixed-budget-complete');
            await action('worldCircuitPause');
          });
          collectUi = false;
          expect(backend!.physicalPulses - before, 1536);
          expect(state()['running'], isFalse);
          await stableAfterStop(label);
          final frames = backend!.frames.sublist(start);
          expect(frames.length, 12);
          expect(frames.every((f) => f['recordCount'] == 3072), isTrue);
          expect(
            backend!.events
                .where(
                  (e) =>
                      e['kind'] == 'production-command-and-pixels' &&
                      e['phase'] == label &&
                      e['externalClockInjectedBeforeOriginalCommand'] == true &&
                      e['status'] == 'completed',
                )
                .length,
            12,
          );
          return frames;
        }

        Future<Map<String, Object?>> capture(String label) async {
          final monitor = find.byType(ComputerDisplay);
          expect(monitor, findsOneWidget);
          await tester.ensureVisible(monitor);
          await tester.pump();
          final desired = screenHash();
          ui.Image? image;
          String? imageHash;
          for (var n = 0; n < 120; n++) {
            await tester.pump(const Duration(milliseconds: 16));
            final raw = tester.widget<RawImage>(
              find.descendant(of: monitor, matching: find.byType(RawImage)),
            );
            image = raw.image;
            if (image == null) continue;
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            if (bytes == null) continue;
            imageHash = sha256.convert(bytes.buffer.asUint8List()).toString();
            if (imageHash == desired) break;
          }
          expect(
            imageHash,
            desired,
            reason: 'Actual production decoded image must match native pixels',
          );
          final rect = tester.getRect(monitor);
          final size = tester.view.physicalSize / tester.view.devicePixelRatio;
          expect(rect.width, greaterThan(0));
          expect(rect.height, greaterThan(0));
          expect(rect.top, greaterThanOrEqualTo(-1));
          expect(rect.left, greaterThanOrEqualTo(-1));
          expect(rect.bottom, lessThanOrEqualTo(size.height + 1));
          expect(rect.right, lessThanOrEqualTo(size.width + 1));
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.descendant(
              of: monitor,
              matching: find.byType(RepaintBoundary),
            ),
          );
          final rendered = await boundary.toImage(pixelRatio: 1);
          try {
            final png = await rendered.toByteData(
              format: ui.ImageByteFormat.png,
            );
            expect(png, isNotNull);
            final file = File(
              '${File(outputPath).parent.path}/screenshots/$mode-$label.png',
            );
            await file.parent.create(recursive: true);
            final bytes = png!.buffer.asUint8List();
            await file.writeAsBytes(bytes);
            return {
              'label': label,
              'path': 'screenshots/$mode-$label.png',
              'rgbaSha256': desired,
              'decodedImageSha256': imageHash,
              'pngSha256': sha256.convert(bytes).toString(),
              'left': rect.left,
              'top': rect.top,
              'width': rect.width,
              'height': rect.height,
              'captureOutsideTimedSteadyWindow': true,
            };
          } finally {
            rendered.dispose();
          }
        }

        var files = await mount(prepared);
        await action('worldCircuitChooseWorld');
        if (!optimized) {
          await measure('cancel-derived-import', () async {
            final pending = controller!.dispatch('worldCircuitImport');
            final deadline = Stopwatch()..start();
            while (state()['importing'] != true || !backend!.opening) {
              if (deadline.elapsed > const Duration(seconds: 10)) {
                fail('Derived import never became cancellable');
              }
              await tester.pump(const Duration(milliseconds: 16));
            }
            await controller!.dispatch('worldCircuitCancel');
            await pending;
            await tester.pump();
            check();
            expect(state()['open'], isFalse);
            expect(backend!.activeSession, isNull);
            expect(backend!.physicalPulses, 0);
          });
          row['cancelImportWithoutClockPassed'] = true;
        }
        await measure('import-derived', () => action('worldCircuitImport'));
        expect(backend!.latest!.sourceSha256, prepared.sha256);
        await selectMonitor();
        final preparedPixels = screenHash();
        final initialRam = await ramHash();
        if (optimized) {
          await action('worldCircuitOptimization', {'enabled': true});
        }
        expect(state()['optimizationEnabled'], optimized);
        expect(state()['wireHeadPixelRulesEnabled'], optimized);
        final captures = <Map<String, Object?>>[];
        row['screenshots'] = captures;
        captures.add(await capture('prepared'));
        final fixed = await fixedTrace('fixed-1536-clock');
        row['fixedTrace'] = fixed;
        expect(
          await ramHash(),
          isNot(initialRam),
          reason: 'Equal halted CPUs cannot satisfy physical liveness',
        );
        final fixedDistinct = fixed.map((f) => f['rgbaSha256']).toSet().length;
        row['fixedDistinctFrames'] = fixedDistinct;
        if (optimized) {
          expect(fixedDistinct, greaterThanOrEqualTo(3));
          expect(
            fixed
                .where(
                  (f) =>
                      (f['litPixels']! as int) > 0 &&
                      (f['litPixels']! as int) < 3072,
                )
                .map((f) => f['rgbaSha256'])
                .toSet()
                .length,
            greaterThanOrEqualTo(3),
          );
        } else {
          expect(
            fixed.every((f) => f['litPixels'] == 0),
            isTrue,
            reason: 'OFF bounded trace retains explicit dark compatibility',
          );
          row['fixedTraceExpectedDark'] = true;
        }
        captures.add(await capture('fixed-trace'));
        if (optimized) {
          final nativeStart = backend!.frames.length;
          final uiStart = uiChanges.length;
          final beforeDynamicPixels = screenHash();
          final visible = <Map<String, Object?>>[];
          row['visibleImageSamples'] = visible;
          row['dynamicWorkloadKind'] =
              'observed-dynamic-with-bounded-image-readback';
          var observingVisible = true;
          var probeBusy = false;
          var lastProbeUs = 0;
          var probeWallUs = 0;
          Object? probeFailure;
          Future<void>? pendingProbe;
          void probeVisible(Duration _) {
            if (!observingVisible) return;
            binding.addPostFrameCallback(probeVisible);
            final now = Timeline.now;
            if (probeBusy ||
                now - lastProbeUs < 250000 ||
                state()['running'] != true) {
              return;
            }
            try {
              final monitor = find.byType(ComputerDisplay);
              final raw = tester.widget<RawImage>(
                find.descendant(of: monitor, matching: find.byType(RawImage)),
              );
              if (raw.image == null) return;
              final rect = tester.getRect(monitor);
              final viewport =
                  tester.view.physicalSize / tester.view.devicePixelRatio;
              if (rect.width <= 0 ||
                  rect.height <= 0 ||
                  rect.left < -1 ||
                  rect.top < -1 ||
                  rect.right > viewport.width + 1 ||
                  rect.bottom > viewport.height + 1) {
                throw StateError(
                  'Running production monitor is outside the viewport',
                );
              }
              // Own a clone across the asynchronous read; production may
              // dispose its previous image when the next frame is decoded.
              final image = raw.image!.clone();
              probeBusy = true;
              lastProbeUs = now;
              final sample = <String, Object?>{
                'atUs': now,
                'status': 'pending',
              };
              visible.add(sample);
              pendingProbe = (() async {
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.rawRgba,
                  );
                  if (bytes == null || bytes.lengthInBytes != 12288) {
                    throw StateError(
                      'Running production RawImage has no actual monitor pixels',
                    );
                  }
                  if (visible.length > 64) {
                    throw StateError(
                      'Bounded visible-image probe capacity exceeded',
                    );
                  }
                  sample.addAll({
                    'status': 'completed',
                    'rgbaSha256': sha256
                        .convert(bytes.buffer.asUint8List())
                        .toString(),
                    'width': image.width,
                    'height': image.height,
                    'monitorFullyVisible': true,
                    'source': 'actual-production-RawImage-clone-readback',
                  });
                } catch (error) {
                  sample.addAll({
                    'status': 'failed',
                    'error': error.toString(),
                  });
                  probeFailure = error;
                  observingVisible = false;
                } finally {
                  final elapsed = Timeline.now - now;
                  sample['readbackWallUs'] = elapsed;
                  probeWallUs += elapsed;
                  row['visibleProbeWallUs'] = probeWallUs;
                  row['visibleProbeCount'] = visible.length;
                  row['visibleProbeMinimumIntervalUs'] = 250000;
                  image.dispose();
                  probeBusy = false;
                }
              })();
            } catch (error) {
              probeFailure = error;
              observingVisible = false;
            }
          }

          finishVisibleProbe = () async {
            observingVisible = false;
            await pendingProbe;
            if (probeFailure != null) {
              throw StateError('Visible probe failed: $probeFailure');
            }
          };
          binding.addPostFrameCallback(probeVisible);
          backend!.arm('timed-dynamic-15s');
          collectUi = true;
          lastUiHash = null;
          await measure('timed-dynamic-15s', () async {
            await action('worldCircuitToggle');
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(seconds: 15)),
            );
            observingVisible = false;
            await action('worldCircuitPause');
            await finishVisibleProbe!();
          });
          finishVisibleProbe = null;
          collectUi = false;
          expect(backend!.clockEnabled, isTrue);
          await stableAfterStop('timed-pause', requireDisarmed: false);
          row['pauseStoppedClockWhileArmed'] = true;
          backend!.disarm('verified-production-pause');
          final nativeFrames = backend!.frames.sublist(nativeStart);
          final nativeChanges =
              nativeFrames.map((f) => f['rgbaSha256']).toSet().length - 1;
          final widgetChanges =
              uiChanges
                  .sublist(uiStart)
                  .map((f) => f['rgbaSha256'])
                  .toSet()
                  .length -
              1;
          row['dynamicFrames'] = nativeFrames;
          final nativeHashes = nativeFrames.map((f) => f['rgbaSha256']).toSet();
          final visibleHashes = visible.map((f) => f['rgbaSha256']).toSet();
          expect(
            visibleHashes.difference({...nativeHashes, beforeDynamicPixels}),
            isEmpty,
            reason: 'Every actual decoded image must belong to this electrical trace',
          );
          final matchedVisible = visibleHashes.intersection(nativeHashes);
          expect(
            matchedVisible.length,
            greaterThanOrEqualTo(3),
            reason: 'Running RawImage must display three distinct actual native frames',
          );
          row['visibleDistinctMatchedNativeFrames'] = matchedVisible.length;
          row['dynamicChangedFrames'] = math.min(
            math.min(nativeChanges, widgetChanges),
            matchedVisible.length - 1,
          );
          row['dynamicHostStages'] = workspace!.hostStages.snapshot();
          expect(row['dynamicChangedFrames'], greaterThanOrEqualTo(2));
          captures.add(await capture('dynamic-paused'));
        } else {
          row['dynamicChangedFrames'] = 0;
          row['dynamicDisplayCoverage'] =
              'unsupported-expected-dark-fixed-trace';
        }
        final savedPixels = screenHash();
        final savedRam = await ramHash();
        await measure('save-changed-derived', () => action('worldCircuitSave'));
        final saved =
            files.saved ??
            (throw StateError('Production save did not retain a changed WLD'));
        final savedHash = await _fileHash(saved);
        expect(savedHash, saved.sha256);
        expect(savedHash, isNot(prepared.sha256));
        row.addAll({
          'savedChangedDerived': true,
          'savedSha256': savedHash,
          'savedBytes': saved.length,
          'preSaveRgbaSha256': savedPixels,
          'preSaveRamSha256': savedRam,
        });
        final liveContinuation = await fixedTrace('live-saved-continuation');
        final liveFinalRam = await ramHash();
        expect(liveFinalRam, isNot(savedRam));
        row['liveContinuation'] = liveContinuation;
        await measure(
          'reset-prepared-source',
          () => action('worldCircuitReset'),
        );
        await selectMonitor();
        expect(screenHash(), preparedPixels);
        expect(state()['optimizationEnabled'], isFalse);
        expect(
          backend!.physicalPulses,
          1536 * 2 +
              (optimized ? (row['dynamicFrames']! as List).length * 128 : 0),
        );
        row['resetRestoredPreparedPixels'] = true;
        await measure(
          'close-before-reopen',
          () => action('worldCircuitClose', {'discard': true}),
        );
        await stableAfterStop('close-before-reopen');
        await disposeWorkspace();

        files = await mount(saved);
        await action('worldCircuitChooseWorld');
        await measure(
          'reopen-changed-derived',
          () => action('worldCircuitImport'),
        );
        expect(backend!.latest!.sourceSha256, savedHash);
        await selectMonitor();
        expect(backend!.physicalPulses, 0);
        expect(
          backend!.events.where((e) {
            final words = e['words'];
            return words is List<int> && [2, 3, 5].contains(words[1]);
          }),
          isEmpty,
          reason: 'Reopen cannot inject ROM, reset or clock commands',
        );
        expect(screenHash(), savedPixels);
        expect(await ramHash(), savedRam);
        row['reopenPreservedPixels'] = true;
        row['reopenPreservedRam'] = true;
        row['reopenHadNoImplicitMutations'] = true;
        captures.add(await capture('reopened'));
        if (optimized) {
          await action('worldCircuitOptimization', {'enabled': true});
        }
        final reopenedContinuation = await fixedTrace('reopened-continuation');
        expect(
          reopenedContinuation.map((f) => f['recordsSha256']).toList(),
          liveContinuation.map((f) => f['recordsSha256']).toList(),
          reason: 'Exact fixed electrical continuation must survive WLD export',
        );
        expect(await ramHash(), liveFinalRam);
        row['reopenedContinuation'] = reopenedContinuation;
        row['continuationMatched'] = true;
        // Close must stop the scheduled run and disarm through backend close.
        backend!.arm('close-boundary');
        final closePulsesBefore = backend!.physicalPulses;
        await action('worldCircuitToggle');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        expect(state()['running'], isTrue);
        expect(backend!.clockEnabled, isTrue);
        row['closeBeganWhileClockArmed'] = true;
        await measure(
          'close-running',
          () => action('worldCircuitClose', {'discard': true}),
        );
        expect(backend!.activeSession, isNull);
        expect(backend!.physicalPulses, greaterThan(closePulsesBefore));
        row['closePhysicalPulsesBeforeRun'] = closePulsesBefore;
        row['closePhysicalPulsesAfterAck'] = backend!.physicalPulses;
        await stableAfterStop('final-close');
        row['closeBoundaryPassed'] = true;
        row['status'] = 'passed';
        await disposeWorkspace();
      }
      stage = 'original-source-preservation';
      final originalHashAfter = await _fileHash(original);
      report['originalSourceSha256After'] = originalHashAfter;
      expect(originalHashAfter, originalHashBefore);
      report['originalSourceHashPreserved'] = true;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      final operations = recorder.results();
      expect(operations.every((o) => o['status'] == 'passed'), isTrue);
      report['status'] = 'passed';
    } catch (error, stack) {
      report['failure'] = error.toString();
      report['failureStack'] = stack.toString();
      rethrow;
    } finally {
      backend?.disarm('test-finally');
      try {
        await finishVisibleProbe?.call();
      } catch (error) {
        report['visibleProbeCleanupFailure'] = error.toString();
        report['status'] = 'failed';
      }
      try {
        if (observer != null && workspace != null) {
          workspace!.worldCircuitChanges.removeListener(observer!);
        }
        await workspace?.close();
        await tester.pumpWidget(const SizedBox());
        controller?.dispose();
        workspace?.dispose();
        await storage?.close();
      } catch (error) {
        report['cleanupFailure'] = error.toString();
        report['status'] = 'failed';
      }
      if (originalForCleanup != null && originalHashBefore != null) {
        try {
          final finalHash = await _fileHash(originalForCleanup);
          report['originalSourceSha256AfterCleanup'] = finalHash;
          report['originalSourceHashPreserved'] =
              finalHash == originalHashBefore;
          if (finalHash != originalHashBefore) report['status'] = 'failed';
        } catch (error) {
          report['sourcePreservationCheckFailure'] = error.toString();
          report['originalSourceHashPreserved'] = false;
          report['status'] = 'failed';
        }
      }
      recorder.stop();
      report['lastStage'] = stage;
      report['operations'] = [
        for (final operation in recorder.results())
          {
            ...operation,
            'fixture': 'public-derived-computerraria-pong',
            'phase': 'cache-uncontrolled',
            'sharedRecorderOriginalFixtureLabel': operation['fixture'],
          },
      ];
      report['controllerOperations'] = recorder.controllerResults();
      report['clockDiagnostics'] = recorder.clockDiagnostics();
      binding.reportData = report;
      final file = File(standalonePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 18)));
}
