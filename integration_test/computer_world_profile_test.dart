// Opt-in pinned public upstream world, downloaded and hash-verified by CI.
// Not included by lib/main.dart; personal input discovery is never performed.
import 'dart:developer' show Timeline;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'support/computer_profile_storage.dart';
import 'support/computer_profile_interaction.dart';

class _SourceFiles implements WorldCircuitFileGateway {
  final WorldCircuitSource world, twld;
  final ComputerProfileStorage storage;
  WorldCircuitSource? savedWorld, savedTwld;
  bool useSavedPair = false;
  _SourceFiles(this.world, this.twld, this.storage);
  @override
  Future<WorldCircuitSource?> pick({required bool companion}) async =>
      useSavedPair
      ? companion
            ? savedTwld!
            : savedWorld!
      : companion
      ? twld
      : world;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    final retained = await storage.retain(source, name);
    if (name.endsWith('.twld')) {
      savedTwld = retained;
    } else {
      savedWorld = retained;
    }
    return true;
  }
}

class _NoSmallFiles implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) =>
      throw StateError('Full worlds must never enter byte picker');
  @override
  Future<bool> save(String name, Uint8List bytes) =>
      throw UnsupportedError('No export requested');
}

class _ObservedBackend
    implements WorldCircuitSourceBackend, WorldCircuitComputerBackend {
  final WorldCircuitSourceBackend inner;
  int? id;
  WorldCircuitResult? latest;
  int clocks = 0;
  final inputEvents = <Map<String, Object?>>[];
  final inputCompletedUs = <int>[];
  _ObservedBackend(this.inner);
  @override
  Future<WorldCircuitComputerFrame> clockAndReadDisplay(
    int session,
    WorldCircuitCommand clock,
    WorldCircuitCommand pixels,
  ) async {
    final backend = inner;
    if (backend is WorldCircuitComputerBackend) {
      final frame = await (backend as WorldCircuitComputerBackend)
          .clockAndReadDisplay(session, clock, pixels);
      clocks += clock.words[8];
      latest = frame.clock;
      return frame;
    }
    final clockResult = await commandWorldCircuit(session, clock);
    try {
      return WorldCircuitComputerFrame(
        clock: clockResult,
        display: await commandWorldCircuit(session, pixels),
      );
    } catch (error) {
      return WorldCircuitComputerFrame(
        clock: clockResult,
        displayError: error.toString(),
      );
    }
  }

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource source, {
    WorldCircuitSource? twld,
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    final result = await inner.openWorldCircuitSource(
      source,
      twld: twld,
      onProgress: onProgress,
    );
    id = result.session;
    latest = result;
    return result;
  }

  @override
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List source, {
    Uint8List? twld,
  }) => throw StateError('Actual-world profile requires source handles');
  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    final result = await inner.commandWorldCircuit(session, command);
    latest = result;
    if (command.words[1] == 2) {
      if (command.words[2] == 3194 && command.words[3] == 153) {
        clocks += command.words[8];
      } else if (const [6516, 6517, 6519, 6520].contains(command.words[2])) {
        inputEvents.add({
          'atClock': clocks,
          'x': command.words[2],
          'y': command.words[3],
          'mask': command.words[7],
        });
        inputCompletedUs.add(Timeline.now);
      }
    }
    return result;
  }

  @override
  Future<void> closeWorldCircuit(int session) async {
    await inner.closeWorldCircuit(session);
    id = null;
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
  Future<String> memorySignature() async {
    final records = <int>[];
    for (var address = 0x100000; address < 0x100040; address += 4) {
      for (var bit = 0; bit < 32; bit++) {
        final (x, y) = ComputerrariaComputer.ramLamp(address, bit);
        records.addAll([x, y, 0, 0]);
      }
    }
    final result = await inner.commandWorldCircuit(
      id!,
      WorldCircuitCommand.lamps(records),
    );
    return sha256.convert(result.records).toString();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual whole-world import, physical Pong and displayed frames', (
    tester,
  ) async {
    if (!kProfileMode) {
      fail('Use flutter drive --profile; debug timing is not accepted.');
    }
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final sources = await inputs.computerInputs();
    const cycles = int.fromEnvironment(
      'COMPUTERRARIA_PROFILE_CYCLES',
      defaultValue: 2,
    );
    const seconds = int.fromEnvironment(
      'COMPUTERRARIA_PROFILE_SECONDS',
      defaultValue: 30,
    );
    if (cycles < 1 || cycles > 8 || seconds < 30 || seconds > 60) {
      fail('Invalid explicit computer profile bounds.');
    }
    final observedRefreshRate = tester.view.display.refreshRate;
    final hasRefreshRate =
        observedRefreshRate.isFinite && observedRefreshRate > 0;
    final refreshRate = hasRefreshRate ? observedRefreshRate : 60.0;
    final recorder = ProfileRecorder(
      frameBudgetUs: 1000000 / refreshRate,
      profile: true,
      currentRss: memory.currentRss,
    );
    final observations = <Map<String, Object?>>[],
        snapshots = <Map<String, Object?>>[],
        inputLatencies = <Map<String, Object?>>[];
    final standardTraces = <int, List<Map<String, Object?>>>{};
    final standardInputs = <int, List<Map<String, Object?>>>{};
    var status = 'failed';
    String? failure, failureStack;
    var stage = 'mount';
    recorder.start();
    try {
      snapshots.add({'phase': 'baseline', ...await memory.memorySnapshot()});
      for (var cycle = 0; cycle < cycles; cycle++) {
        for (final optimized in [false, true]) {
          final mode = optimized ? 'optimized' : 'standard';
          final engine = core.createTerraEngine();
          final backend = _ObservedBackend(
            circuit_factory.createWorldCircuitBackend(engine)!
                as WorldCircuitSourceBackend,
          );
          final storage = await createComputerProfileStorage();
          final sourceFiles = _SourceFiles(
            sources.world,
            sources.twld,
            storage,
          );
          Workspace createWorkspace() => Workspace(
            engine: engine,
            files: _NoSmallFiles(),
            vault: storage.vault,
            worldCircuitBackend: backend,
            worldCircuitFiles: sourceFiles,
          );
          var workspace = createWorkspace();
          Map state() => workspace.view.result['worldCircuit'] as Map;
          Future<void> waitFor(bool Function() condition) async {
            final timeout = Stopwatch()..start();
            while (!condition()) {
              if (timeout.elapsed > const Duration(minutes: 12)) {
                fail('Timed out waiting for the actual circuit operation.');
              }
              await tester.pump(const Duration(milliseconds: 16));
              if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
              if (state()['error'] != null) fail(state()['error'].toString());
            }
          }

          Future<void> tap(String label, {bool wait = true}) async {
            final button = find.text(label);
            await revealComputerProfileTarget(tester, button);
            await tester.tap(button);
            await tester.pump();
            if (wait) {
              await waitFor(
                () => !workspace.view.busy && state()['busy'] != true,
              );
            }
            await tester.pump();
            if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
          }

          Future<void> measure(String id, Future<void> Function() operation) {
            stage = '$id.$mode';
            return recorder.measure(
              '$id.$mode',
              cycle,
              false,
              operation,
              interaction: id.contains('same-program-input-trace')
                  ? 'controller dispatch with production panel rendered; fixed physical clock/input trace'
                  : id.contains('keyboard-')
                  ? 'framework key down/up on focused production monitor'
                  : id.contains('touch-')
                  ? 'pointer down/up on production direction control'
                  : 'pointer tap on production WorldCircuitPanel; actual full WLD/TWLD and wiring VM',
            );
          }

          Future<void> mount() => tester.pumpWidget(
            MaterialApp(
              theme: terraTheme(),
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: workspace,
                  builder: (context, child) => SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: WorldCircuitPanel(
                        state: Map<String, Object?>.from(state()),
                        dispatch: workspace.dispatch,
                        hostStages: workspace.hostStages,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          try {
            await mount();
            await measure('computer.choose-pair', () async {
              await tap('选择完整 WLD');
              await tap('选择配套 TWLD');
            });
            if (cycle == 0 && !optimized) {
              await measure('computer.cancel-import', () async {
                await tap('导入完整电路', wait: false);
                await waitFor(() => state()['importing'] == true);
                await tap('取消当前加载');
                expect(state()['open'], isFalse);
              });
            }
            await measure('computer.import', () => tap('导入完整电路'));
            expect(state()['computerVerified'], isTrue);
            expect(state()['programName'], isNull);
            expect(state()['keyboardVerified'], isTrue);
            expect(state()['optimizationEnabled'], isFalse);
            if (optimized) {
              await measure('computer.enable-optimization', () => tap('电路优化'));
              expect(state()['optimizationEnabled'], isTrue);
            }
            await measure('computer.load-pong', () => tap('载入 Pong 程序'));
            expect(state()['canRunComputer'], isTrue);
            backend.clocks = 0;
            backend.inputEvents.clear();
            backend.inputCompletedUs.clear();
            final trace = <Map<String, Object?>>[];
            await measure('computer.same-program-input-trace', () async {
              for (var batch = 0; batch < 40; batch++) {
                if (batch == 8 || batch == 20) {
                  await workspace.dispatch('worldCircuitInput', {
                    'direction': batch == 8 ? 'up' : 'down',
                    'pressed': true,
                  });
                }
                if (batch == 12 || batch == 26) {
                  await workspace.dispatch('worldCircuitInput', {
                    'direction': batch == 12 ? 'up' : 'down',
                    'pressed': false,
                  });
                }
                await workspace.dispatch('worldCircuitStep', {'pulses': 128});
                await tester.pump();
                if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
                if (batch % 4 == 3) {
                  final frames = state()['displayFrames'] as Map;
                  trace.add({
                    'pulses': (batch + 1) * 128,
                    'mono': sha256
                        .convert(frames['黑白显示器'] as Uint8List)
                        .toString(),
                    'color': sha256
                        .convert(frames['彩色显示器'] as Uint8List)
                        .toString(),
                    'ram': await backend.memorySignature(),
                  });
                }
              }
            });
            final inputEvents = List<Map<String, Object?>>.from(
              backend.inputEvents,
            );
            expect(backend.clocks, 5120);
            if (optimized) {
              expect(
                trace,
                standardTraces[cycle],
                reason: 'Both modes must retain identical actual pixels and physical RAM signatures for the same inputs.',
              );
              expect(inputEvents, standardInputs[cycle]);
            } else {
              standardTraces[cycle] = trace;
              standardInputs[cycle] = inputEvents;
            }
            final savedFrames = Map.of(state()['displayFrames'] as Map);
            final savedRam = await backend.memorySignature();
            final savedProgram = state()['programName'];
            final savedPulses = state()['physicalPulses'];
            await measure('computer.export-pair', () async {
              await tap('保存模拟结果', wait: false);
              await tester.pump(const Duration(milliseconds: 250));
              await tap('继续');
              expect(state()['dirty'], isFalse);
              expect(sourceFiles.savedWorld?.sha256, isNotNull);
              expect(sourceFiles.savedTwld?.sha256, isNotNull);
            });
            await measure('computer.close-exported', () => tap('关闭'));
            await workspace.close();
            await tester.pumpWidget(const SizedBox());
            workspace.dispose();
            sourceFiles.useSavedPair = true;
            workspace = createWorkspace();
            await mount();
            await measure('computer.reselect-exported-pair', () async {
              await tap('选择完整 WLD');
              await tap('选择配套 TWLD');
            });
            final clocksBeforeReopen = backend.clocks;
            await measure('computer.reimport-resume', () => tap('导入完整电路'));
            expect(state()['restoredFromExport'], isTrue);
            expect(state()['canRunComputer'], isTrue);
            expect(state()['programName'], savedProgram);
            expect(state()['physicalPulses'], savedPulses);
            expect(state()['displayFrames'], savedFrames);
            expect(await backend.memorySignature(), savedRam);
            expect(
              backend.clocks,
              clocksBeforeReopen,
              reason: 'Reimport must not reset or clock the saved CPU.',
            );
            expect(state()['optimizationEnabled'], isFalse);
            if (optimized) await tap('电路优化');
            await measure('computer.idle-mode-roundtrip', () async {
              final frames = Map.of(state()['displayFrames'] as Map);
              final ram = await backend.memorySignature();
              await tap('电路优化');
              expect(state()['displayFrames'], frames);
              expect(await backend.memorySignature(), ram);
              await tap('电路优化');
              expect(state()['displayFrames'], frames);
              expect(await backend.memorySignature(), ram);
              expect(state()['programName'], isNotNull);
            });
            await tap('运行物理时钟', wait: false);
            final screen = findComputerProfileMonitor('黑白显示器，显示实际物理像素状态');
            await focusComputerProfileMonitor(tester, screen);
            Future<void> inputWait(bool Function() condition) async {
              final watch = Stopwatch()..start();
              while (!condition()) {
                if (watch.elapsed > const Duration(seconds: 5)) {
                  fail(
                    'No acknowledged physical sensor/input release within five seconds.',
                  );
                }
                await tester.pump(const Duration(milliseconds: 16));
                if (state()['error'] != null) fail(state()['error'].toString());
              }
            }

            double paddleCenter() {
              final rgba =
                  (state()['displayFrames'] as Map)['黑白显示器'] as Uint8List;
              var rows = 0, sum = 0;
              for (var y = 0; y < 48; y++) {
                if (rgba[y * 64 * 4] != 0) {
                  rows++;
                  sum += y;
                }
              }
              return rows == 0 ? -1 : sum / rows;
            }

            Future<void> releaseProof(int x, int releasedUs) async {
              final releaseClock = backend.clocks;
              await inputWait(() => backend.clocks >= releaseClock + 128);
              final afterDrain = backend.inputEvents.length;
              await inputWait(() => backend.clocks >= releaseClock + 256);
              expect(
                backend.inputEvents.skip(afterDrain).where((e) => e['x'] == x),
                isEmpty,
                reason: 'Release must stop new sensor pulses after the accepted batch drains.',
              );
            }

            for (final key in [
              (
                'up',
                LogicalKeyboardKey.arrowUp,
                PhysicalKeyboardKey.arrowUp,
                6516,
              ),
              (
                'down',
                LogicalKeyboardKey.arrowDown,
                PhysicalKeyboardKey.arrowDown,
                6517,
              ),
              (
                'left',
                LogicalKeyboardKey.arrowLeft,
                PhysicalKeyboardKey.arrowLeft,
                6519,
              ),
              (
                'right',
                LogicalKeyboardKey.arrowRight,
                PhysicalKeyboardKey.arrowRight,
                6520,
              ),
            ]) {
              await measure('computer.keyboard-${key.$1}', () async {
                final eventStart = backend.inputEvents.length,
                    centerBefore = paddleCenter();
                final startUs = Timeline.now;
                await tester.sendKeyDownEvent(key.$2, physicalKey: key.$3);
                int eventIndex() => backend.inputEvents.indexWhere(
                  (event) => event['x'] == key.$4,
                  eventStart,
                );
                await inputWait(() => eventIndex() >= 0);
                final event = eventIndex(),
                    acknowledgedUs = backend.inputCompletedUs[event];
                final releaseUs = Timeline.now;
                await tester.sendKeyUpEvent(key.$2, physicalKey: key.$3);
                await tester.pump();
                expect(
                  (state()['heldKeys'] as Iterable).contains(key.$1),
                  isFalse,
                );
                await releaseProof(key.$4, releaseUs);
                if (key.$1 == 'up' || key.$1 == 'down') {
                  await inputWait(() => paddleCenter() != centerBefore);
                }
                inputLatencies.add({
                  'cycle': cycle,
                  'mode': mode,
                  'input': key.$1,
                  'interaction':
                      'Flutter key down/up on focused production monitor',
                  'pressToPhysicalSensorMs': (acknowledgedUs - startUs) / 1000,
                  'acceptedAtClock': backend.inputEvents[event]['atClock'],
                  'releaseToVerifiedNoMorePulsesMs':
                      (Timeline.now - releaseUs) / 1000,
                  'paddleCenterBefore': centerBefore,
                  'paddleCenterObservedAfter': paddleCenter(),
                  'visualLatencyClaim': false,
                });
              });
            }
            await measure('computer.touch-hold-down', () async {
              final button = find.bySemanticsLabel('计算机向下');
              await revealComputerProfileTarget(tester, button);
              final start = backend.inputEvents.length, startUs = Timeline.now;
              final gesture = await tester.startGesture(
                tester.getCenter(button),
              );
              int eventIndex() => backend.inputEvents.indexWhere(
                (event) => event['x'] == 6517,
                start,
              );
              try {
                await inputWait(() => eventIndex() >= 0);
              } finally {
                await gesture.up();
              }
              final index = eventIndex(), releaseUs = Timeline.now;
              await releaseProof(6517, releaseUs);
              inputLatencies.add({
                'cycle': cycle,
                'mode': mode,
                'input': 'touch-hold-down',
                'interaction':
                    'pointer down/up on production direction control',
                'pressToPhysicalSensorMs':
                    (backend.inputCompletedUs[index] - startUs) / 1000,
                'acceptedAtClock': backend.inputEvents[index]['atClock'],
                'releaseToVerifiedNoMorePulsesMs':
                    (Timeline.now - releaseUs) / 1000,
                'visualLatencyClaim': false,
              });
            });
            await tap('暂停');
            final before = Uint8List.fromList(
              (state()['displayFrames'] as Map)['黑白显示器'] as Uint8List,
            );
            await measure('computer.run-displayed-pong', () async {
              await tap('运行物理时钟', wait: false);
              await revealComputerProfileTarget(
                tester,
                findComputerProfileMonitor('黑白显示器，显示实际物理像素状态'),
              );
              final watch = Stopwatch()..start();
              final clocksBefore = backend.clocks,
                  pollsBefore = state()['displayedFrames'] as int;
              var observedChanges = 0;
              Uint8List previous = before;
              while (watch.elapsed < const Duration(seconds: seconds)) {
                await tester.pump(const Duration(milliseconds: 16));
                if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
                if (state()['error'] != null) fail(state()['error'].toString());
                final next =
                    (state()['displayFrames'] as Map)['黑白显示器'] as Uint8List;
                if (!listEquals(previous, next)) {
                  observedChanges++;
                  previous = next;
                }
              }
              await tap('暂停');
              watch.stop();
              final stopped = state()['physicalPulses'];
              await tester.pump(const Duration(milliseconds: 120));
              expect(state()['physicalPulses'], stopped);
              expect(
                observedChanges,
                greaterThan(1),
                reason:
                    'Actual circuit display must visibly change beyond boot.',
              );
              observations.add({
                'cycle': cycle,
                'mode': mode,
                'deterministicTrace': trace,
                'inputEventsAtPhysicalClock': inputEvents,
                'observedDisplayChanges': observedChanges,
                'physicalPulses': stopped,
                'nativeActiveBytes': backend.latest?.activeBytes,
                'nativePeakBytes': backend.latest?.peakBytes,
                'hostStages': workspace.hostStages.snapshot(),
                'steadyWindowMs': watch.elapsedMicroseconds / 1000,
                'steadyPhysicalPulses': backend.clocks - clocksBefore,
                'clockHz':
                    (backend.clocks - clocksBefore) *
                    1000000 /
                    watch.elapsedMicroseconds,
                'displayPollHz':
                    ((state()['displayedFrames'] as int) - pollsBefore) *
                    1000000 /
                    watch.elapsedMicroseconds,
              });
            });
            snapshots.add({
              'phase': 'paused-after-steady-run',
              'cycle': cycle,
              'mode': mode,
              ...await memory.memorySnapshot(),
            });
            await measure(
              'computer.single-physical-clock',
              () => tap('单个时钟脉冲'),
            );
            await measure('computer.reset-original', () async {
              await tap('重置', wait: false);
              await tester.pump(const Duration(milliseconds: 250));
              await tap('继续');
            });
            expect(state()['programName'], savedProgram);
            expect(state()['canRunComputer'], isTrue);
            expect(state()['physicalPulses'], savedPulses);
            await measure('computer.close', () => tap('关闭'));
            expect(state()['open'], isFalse);
          } finally {
            await workspace.close();
            await tester.pumpWidget(const SizedBox());
            workspace.dispose();
            await storage.close();
          }
          snapshots.add({
            'phase': 'after-close',
            'cycle': cycle,
            'mode': mode,
            ...await memory.memorySnapshot(),
          });
        }
      }
      await tester.pump(const Duration(seconds: 1));
      final steady = recorder.results().where(
        (row) =>
            (row['id'] as String).startsWith('computer.run-displayed-pong.'),
      );
      expect(steady.length, 2);
      for (final row in steady) {
        expect(
          row['frameCount'],
          greaterThan(0),
          reason:
              'Actual UI/raster engine timings are required for both modes.',
        );
      }
      if (!kIsWeb) {
        expect(
          snapshots.every((row) => row['heapUsedBytes'] != null),
          isTrue,
          reason: 'Native profile acceptance requires actual VM heap samples.',
        );
      }
      status = 'passed';
    } catch (e, stack) {
      failure = e.toString();
      failureStack = stack.toString();
      rethrow;
    } finally {
      recorder.stop();
      final rows = recorder
          .results()
          .map(
            (row) => {
              ...row,
              'fixture': 'public-upstream-computerraria',
              'phase': 'full-lifecycle-no-excluded-warmup',
              'samples': (row['samples'] as List)
                  .map(
                    (sample) => {
                      ...sample as Map,
                      'lifecyclePhase': (sample['cycle'] as int) == 0
                          ? 'first-recorded-cycle'
                          : 'repeat-cycle',
                      'cacheState': 'uncontrolled',
                    },
                  )
                  .toList(),
            },
          )
          .toList();
      final report = <String, dynamic>{
        'schema': 1,
        'status': status,
        'buildMode': 'profile',
        'cycles': cycles,
        'steadySecondsPerMode': seconds,
        'modes': const ['standard', 'optimized'],
        'clockBatchPulses': 128,
        'traceTotalPulses': 5120,
        'excludedWarmupCycles': 0,
        'lastStage': stage,
        'failure': failure,
        'failureStack': failureStack,
        'viewport': {
          'physicalWidth': tester.view.physicalSize.width,
          'physicalHeight': tester.view.physicalSize.height,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'displayRefreshRateHz': observedRefreshRate,
        'frameBudgetUs': 1000000 / refreshRate,
        'frameBudgetSource': hasRefreshRate
            ? 'observed-display-refresh-rate'
            : 'explicit-60hz-fallback',
        'toolchain': {
          'flutterRevisionPin': '5fc346839b5d0eef006ed8404392afb4dfae428d',
          'sourceRevision': const String.fromEnvironment(
            'PERF_COMMIT',
            defaultValue: 'not-supplied',
          ),
        },
        'fixture': {
          'id': 'public-upstream-computerraria@0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8',
          'wldSha256': ComputerrariaComputer.sourceSha256,
          'twldSha256': 'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8',
          'wldBytes': sources.world.length,
          'twldBytes': sources.twld.length,
          'identity':
              'SHA-256 plus physical anchors verified by production session',
        },
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
          'renderer': const String.fromEnvironment(
            'PERF_RENDERER',
            defaultValue: 'unspecified',
          ),
          'runner': const String.fromEnvironment(
            'PERF_RUNNER',
            defaultValue: 'unspecified',
          ),
          ...memory.runtimeOverrides(),
        },
        'methodology': 'Every lifecycle is retained with no excluded warmup. First and repeat cycles are identified; filesystem/cache state is uncontrolled. Each cycle runs standard then optimized. Correctness uses fixed pulse/input checkpoints; steady throughput uses equal wall-time windows.',
        'operations': rows,
        'observations': observations,
        'inputLatencies': inputLatencies,
        'memory': snapshots,
        'limits': [
          'System file chooser latency excluded; picker returns explicit source handles.',
          'No target-device claim follows from Linux or browser profiling.',
          'Input uses independently calibrated physical sensors and sticky read-clear semantics.',
          'Input latency starts at framework-injected real key/pointer events and ends at the actual sensor-command completion. OS device latency and raster presentation latency are not claimed.',
        ],
      };
      binding.reportData = report;
      await memory.writeStandaloneReport(report);
      await memory.closeMemoryProbe();
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
