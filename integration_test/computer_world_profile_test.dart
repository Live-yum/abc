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
import 'support/profile_controller.dart';
import 'support/profile_os_memory_native.dart'
    if (dart.library.js_interop) 'support/profile_os_memory_web.dart'
    as os_memory;
import 'support/computer_profile_storage.dart';
import 'support/computer_profile_interaction.dart';

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

class _NoSmallFiles implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) async {
    if (kind == 'computerProgram') {
      // Four-byte RV32I JAL x0, 0, authored here. Full WLD remains handle-only.
      return PickedFile(
        'synthetic-loop.bin',
        Uint8List.fromList([0x6f, 0, 0, 0]),
      );
    }
    throw StateError('Full worlds must never enter byte picker');
  }

  @override
  Future<bool> save(String name, Uint8List bytes) =>
      throw UnsupportedError('No export requested');
}

class _ObservedBackend
    implements WorldCircuitSourceBackend, WorldCircuitExternalOwnerBackend {
  @override
  bool get completesComputerBatchFromExternalEvent =>
      inner is WorldCircuitExternalOwnerBackend &&
      (inner as WorldCircuitExternalOwnerBackend)
          .completesComputerBatchFromExternalEvent;
  final WorldCircuitSourceBackend inner;
  int? id;
  WorldCircuitResult? latest;
  int clocks = 0;
  final inputEvents = <Map<String, Object?>>[];
  final inputCompletedUs = <int>[];
  List<int>? _cpuProbePoints;
  int get cpuProbeCount => (_cpuProbePoints?.length ?? 0) ~/ 4;
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
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    final result = await inner.openWorldCircuitSource(
      source,
      onProgress: onProgress,
    );
    id = result.session;
    _cpuProbePoints = null;
    latest = result;
    return result;
  }

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List source) =>
      throw StateError('Actual-world profile requires source handles');
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
    // Passive lamp reads only: never reset buses or execute RAM-read programs.
    // The Pong stack changes while the initial RAM prefix may remain constant.
    for (final address in [
      for (var at = 0x100000; at < 0x100040; at += 4) at,
      for (var at = 0x15bc00; at < 0x15c000; at += 4) at,
    ]) {
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

  Future<String> cpuSignature() async {
    if (_cpuProbePoints == null) {
      final view = await inner.commandWorldCircuit(
        id!,
        WorldCircuitCommand.viewport(3150, 130, 300, 200),
      );
      final data = ByteData.sublistView(view.records);
      final points = <int>[];
      expect(view.records.length % 16, 0);
      for (var at = 0; at < view.records.length; at += 16) {
        final tile = data.getUint32(at + 8, Endian.little) & 65535;
        final frameX = data.getUint32(at + 12, Endian.little) & 65535;
        if (tile == 419 && frameX != 36) {
          points.addAll([
            data.getUint32(at, Endian.little),
            data.getUint32(at + 4, Endian.little),
            0,
            0,
          ]);
        }
      }
      expect(points, isNotEmpty, reason: 'Actual CPU lamp probes required');
      _cpuProbePoints = points;
    }
    final result = await inner.commandWorldCircuit(
      id!,
      WorldCircuitCommand.lamps(_cpuProbePoints!),
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
    final source = await inputs.computerInput();
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
    os_memory.OsLoadingMemoryProbe? osProbe;
    Map<String, Object?>? loadingMemory;
    int? observedCircuitAbi;
    var priorCancelledLoad = false, completeLoads = 0, loadAttempts = 0;
    recorder.start();
    try {
      osProbe = await os_memory.OsLoadingMemoryProbe.start();
      snapshots.add({'phase': 'baseline', ...await memory.memorySnapshot()});
      for (var cycle = 0; cycle < cycles; cycle++) {
        for (final optimized in [false, true]) {
          final mode = optimized ? 'optimized' : 'standard';
          final pixelRule = optimized
              ? 'wirehead-color-pair-wave'
              : 'game-tripwire-crossing';
          final displayCompatibility = {
            'status': optimized ? 'supported' : 'unsupported-under-game-rules',
            'expectedBehavior': optimized
                ? 'moving-pong'
                : 'recorded-without-pong-display-claim',
          };
          final engine = core.createTerraEngine();
          final backend = _ObservedBackend(
            circuit_factory.createWorldCircuitBackend(engine)!
                as WorldCircuitSourceBackend,
          );
          final storage = await createComputerProfileStorage();
          final sourceFiles = _SourceFiles(source, storage);
          Workspace createWorkspace() => Workspace(
            engine: engine,
            files: _NoSmallFiles(),
            vault: storage.vault,
            worldCircuitBackend: backend,
            worldCircuitFiles: sourceFiles,
          );
          var workspace = createWorkspace();
          var controller = ProfiledTerraController(
            workspace,
            recorder,
            cycle,
            false,
            profileMode: mode,
          );
          Map state() => workspace.view.result['worldCircuit'] as Map;
          int litPixels(Uint8List rgba) {
            expect(rgba.length, 64 * 48 * 4);
            var lit = 0;
            for (var at = 0; at < rgba.length; at += 4) {
              if (rgba[at] != 0 || rgba[at + 1] != 0 || rgba[at + 2] != 0) {
                lit++;
              }
            }
            return lit;
          }

          Map<String, Object?> readyMetadata() {
            final actual = backend.latest!;
            expect(actual.circuitOptimizationEnabled, optimized);
            expect(actual.circuitOptimizationSupported, isTrue);
            expect(actual.wireHeadPixelRulesEnabled, optimized);
            return {
              'flags': actual.reserved,
              'optimizationEnabled': actual.circuitOptimizationEnabled,
              'topologyEligible': actual.circuitOptimizationSupported,
              'wireHeadPixelRulesEnabled': actual.wireHeadPixelRulesEnabled,
            };
          }

          Map<String, Object?> paddleLatencyApplicability(String direction) {
            final movesPaddle =
                direction == 'up' ||
                direction == 'down' ||
                direction == 'touch-hold-down';
            return {
              'paddleStateLatencyStatus': optimized && movesPaddle
                  ? 'observed'
                  : 'notApplicable',
              if (!optimized || !movesPaddle)
                'paddleStateLatencyReason': movesPaddle
                    ? 'game-tripwire-display-not-supported'
                    : 'pong-ignores-direction',
            };
          }

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
                  : 'pointer tap on production WorldCircuitPanel; actual full WLD and wiring VM',
            );
          }

          Future<void> observeLoad(
            String kind,
            Future<void> Function() operation, {
            bool cancelled = false,
          }) async {
            await osProbe!.begin({
              'kind': kind,
              'cycle': cycle,
              'mode': mode,
              'hostLoadAttempt': loadAttempts++,
              'sessionSource': sourceFiles.useSavedWorld
                  ? 'exported-reimport-session-source'
                  : 'pinned-public-original-source',
              'priorCancelledLoad': priorCancelledLoad,
              'hostLoadContext': cancelled
                  ? 'cancelled-load-attempt'
                  : completeLoads == 0
                  ? 'fresh-host-first-complete-load'
                  : 'repeat-in-same-host',
              'cacheState': 'uncontrolled',
            });
            var outcome = 'failed';
            final evidence = <String, Object?>{};
            try {
              await operation();
              if (cancelled) {
                outcome = 'cancelled';
                priorCancelledLoad = true;
              } else {
                final actualAbi = backend.latest!.stats[0];
                expect(actualAbi, 2, reason: 'Actual WLD-only circuit ABI');
                observedCircuitAbi ??= actualAbi;
                expect(actualAbi, observedCircuitAbi);
                expect(state()['computerVerified'], isTrue);
                expect(state()['keyboardVerified'], isTrue);
                final frames = state()['displayFrames'] as Map;
                final mono =
                    frames[ComputerrariaComputer.mono.name] as Uint8List;
                expect(mono.length, 64 * 48 * 4);
                evidence.addAll({
                  'completeWldVerified': true,
                  'monoRgbaBytes': mono.length,
                  'monoDisplayInitialized': true,
                  'restoredFromExport': state()['restoredFromExport'] == true,
                });
                outcome = 'ready';
                completeLoads++;
              }
            } finally {
              await osProbe!.end(outcome, evidence);
            }
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
                        dispatch: controller.dispatch,
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
            await measure('computer.choose-world', () async {
              await tap('选择完整 WLD');
            });
            if (cycle == 0 && !optimized) {
              await observeLoad(
                'cancelled-import',
                () => measure('computer.cancel-import', () async {
                  await tap('导入完整电路', wait: false);
                  await waitFor(() => state()['importing'] == true);
                  await tap('取消当前加载');
                  expect(state()['open'], isFalse);
                }),
                cancelled: true,
              );
            }
            await observeLoad(
              'initial-import',
              () => measure('computer.import', () => tap('导入完整电路')),
            );
            expect(state()['computerVerified'], isTrue);
            expect(state()['programName'], isNull);
            expect(state()['keyboardVerified'], isTrue);
            expect(state()['optimizationEnabled'], isFalse);
            if (optimized) {
              await measure('computer.enable-optimization', () => tap('电路优化'));
              expect(state()['optimizationEnabled'], isTrue);
            }
            await measure('computer.load-pong', () => tap('载入 Pong 程序'));
            final baselineRam = await backend.memorySignature();
            final baselineCpu = await backend.cpuSignature();
            final baselineFrames = Map.of(state()['displayFrames'] as Map);
            await measure('computer.load-program', () => tap('加载 RV32I 程序'));
            expect(state()['programName'], 'synthetic-loop.bin');
            expect(state()['programIncomplete'], isFalse);
            expect(state()['canRunComputer'], isTrue);
            final romPoints = <int>[];
            for (var bit = 0; bit < 32; bit++) {
              final (x, y) = ComputerrariaComputer.romLamp(0, bit);
              romPoints.addAll([x, y, 0, 0]);
            }
            final rom = await backend.commandWorldCircuit(
              backend.id!,
              WorldCircuitCommand.lamps(romPoints),
            );
            expect(rom.records.length, 32 * 16);
            final romData = ByteData.sublistView(rom.records);
            for (var bit = 0; bit < 32; bit++) {
              expect(
                romData.getUint32(bit * 16 + 8, Endian.little),
                (0x6f >> bit) & 1,
                reason: 'Picked synthetic program must reach actual ROM lamps.',
              );
            }
            await measure(
              'computer.restore-pong-after-program',
              () => tap('载入 Pong 程序'),
            );
            expect(state()['canRunComputer'], isTrue);
            expect(state()['running'], isFalse);
            expect(state()['physicalPulses'], 0);
            expect(
              await backend.memorySignature(),
              baselineRam,
              reason: 'Extra program test must not alter the existing Pong RAM baseline.',
            );
            expect(
              await backend.cpuSignature(),
              baselineCpu,
              reason: 'Production loadProgram resets must restore the original Pong CPU baseline.',
            );
            expect(state()['displayFrames'], baselineFrames);
            final framesBeforeRefresh = Map.of(state()['displayFrames'] as Map);
            final pulsesBeforeRefresh = state()['physicalPulses'];
            final pollsBeforeRefresh = state()['displayedFrames'] as int;
            await measure('computer.refresh-display', () => tap('读取显示器'));
            expect(state()['displayFrames'], framesBeforeRefresh);
            expect(
              (state()['displayFrames']
                  as Map)[ComputerrariaComputer.mono.name],
              hasLength(64 * 48 * 4),
            );
            expect(state()['physicalPulses'], pulsesBeforeRefresh);
            expect(state()['displayedFrames'], greaterThan(pollsBeforeRefresh));
            final selectedReadyMetadata = readyMetadata();
            backend.clocks = 0;
            backend.inputEvents.clear();
            backend.inputCompletedUs.clear();
            final trace = <Map<String, Object?>>[];
            await measure('computer.same-program-input-trace', () async {
              for (var batch = 0; batch < 40; batch++) {
                if (batch == 8 || batch == 20) {
                  await controller.dispatch('worldCircuitInput', {
                    'direction': batch == 8 ? 'up' : 'down',
                    'pressed': true,
                  });
                }
                if (batch == 12 || batch == 26) {
                  await controller.dispatch('worldCircuitInput', {
                    'direction': batch == 12 ? 'up' : 'down',
                    'pressed': false,
                  });
                }
                await controller.dispatch('worldCircuitStep', {'pulses': 128});
                await tester.pump();
                if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
                if (batch % 4 == 3) {
                  final frames = state()['displayFrames'] as Map;
                  final mono = frames['黑白显示器'] as Uint8List;
                  trace.add({
                    'pulses': (batch + 1) * 128,
                    'mono': sha256.convert(mono).toString(),
                    'monoLitPixels': litPixels(mono),
                    'cpuProbe': await backend.cpuSignature(),
                    'ram': await backend.memorySignature(),
                  });
                }
              }
            });
            final inputEvents = List<Map<String, Object?>>.from(
              backend.inputEvents,
            );
            expect(backend.clocks, 5120);
            final distinctCpuStates = trace
                .map((row) => row['cpuProbe'])
                .toSet()
                .length;
            final distinctRamStates = trace
                .map((row) => row['ram'])
                .toSet()
                .length;
            expect(
              distinctCpuStates > 1 || distinctRamStates > 1,
              isTrue,
              reason: 'Passive CPU/RAM samples must show actual execution',
            );
            if (optimized) {
              expect(
                trace.map((row) => row['mono']).toSet().length,
                greaterThan(1),
              );
              expect(
                trace.any((row) => (row['monoLitPixels']! as int) > 0),
                isTrue,
              );
            }
            List<Map<String, Object?>> cpuRamTrace(
              List<Map<String, Object?>> rows,
            ) => [
              for (final row in rows)
                {
                  'pulses': row['pulses'],
                  'cpuProbe': row['cpuProbe'],
                  'ram': row['ram'],
                },
            ];
            if (optimized) {
              expect(
                cpuRamTrace(trace),
                cpuRamTrace(standardTraces[cycle]!),
                reason: 'Both modes retain identical passive CPU/RAM states for the same physical inputs; pixel rules differ.',
              );
              expect(inputEvents, standardInputs[cycle]);
            } else {
              standardTraces[cycle] = trace;
              standardInputs[cycle] = inputEvents;
            }
            final savedFrames = Map.of(state()['displayFrames'] as Map);
            final savedRam = await backend.memorySignature();
            final savedCpu = await backend.cpuSignature();
            final savedProgram = state()['programName'];
            final savedPulses = state()['physicalPulses'];
            await measure('computer.export-world', () async {
              await tap('保存模拟结果', wait: false);
              await tester.pump(const Duration(milliseconds: 250));
              await tap('继续');
              expect(state()['dirty'], isFalse);
              expect(sourceFiles.savedWorld?.sha256, isNotNull);
            });
            await measure('computer.close-exported', () => tap('关闭'));
            await workspace.close();
            await tester.pumpWidget(const SizedBox());
            controller.dispose();
            workspace.dispose();
            await osProbe.closePoint({
              'phase': 'after-export-close',
              'cycle': cycle,
              'mode': mode,
            });
            sourceFiles.useSavedWorld = true;
            workspace = createWorkspace();
            controller = ProfiledTerraController(
              workspace,
              recorder,
              cycle,
              false,
              profileMode: mode,
            );
            await mount();
            await measure('computer.reselect-exported-world', () async {
              await tap('选择完整 WLD');
            });
            final clocksBeforeReopen = backend.clocks;
            await observeLoad(
              'exported-reimport',
              () => measure('computer.reimport-resume', () => tap('导入完整电路')),
            );
            expect(state()['restoredFromExport'], isTrue);
            expect(state()['canRunComputer'], isTrue);
            expect(state()['programName'], savedProgram);
            expect(state()['physicalPulses'], savedPulses);
            expect(state()['displayFrames'], savedFrames);
            expect(await backend.memorySignature(), savedRam);
            expect(await backend.cpuSignature(), savedCpu);
            expect(
              backend.clocks,
              clocksBeforeReopen,
              reason: 'Reimport must not reset or clock the saved CPU.',
            );
            expect(state()['optimizationEnabled'], isFalse);
            if (optimized) await tap('电路优化');
            readyMetadata();
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

            Future<void> inputWait(
              String phase,
              bool Function() condition,
            ) async {
              final watch = Stopwatch()..start();
              final initialClock = backend.clocks;
              while (!condition()) {
                if (watch.elapsed > const Duration(seconds: 5)) {
                  fail(
                    'Input timeout: phase=$phase clockCount=${backend.clocks} '
                    'clockDelta=${backend.clocks - initialClock} '
                    'centerNow=${paddleCenter()} elapsed=${watch.elapsed}.',
                  );
                }
                await tester.pump(const Duration(milliseconds: 16));
                if (state()['error'] != null) fail(state()['error'].toString());
              }
            }

            Future<void> releaseProof(int x, int releasedUs) async {
              final releaseClock = backend.clocks;
              await inputWait(
                'sensor-$x.release-first-batch',
                () => backend.clocks >= releaseClock + 128,
              );
              final afterDrain = backend.inputEvents.length;
              await inputWait(
                'sensor-$x.release-second-batch',
                () => backend.clocks >= releaseClock + 256,
              );
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
                final eventStart = backend.inputEvents.length;
                int eventIndex() => backend.inputEvents.indexWhere(
                  (event) => event['x'] == key.$4,
                  eventStart,
                );
                final input = await observeComputerProfileHeldInput(
                  input: 'keyboard-${key.$1}',
                  press: () async {
                    await tester.sendKeyDownEvent(key.$2, physicalKey: key.$3);
                  },
                  release: () async {
                    await tester.sendKeyUpEvent(key.$2, physicalKey: key.$3);
                    await tester.pump();
                  },
                  pump: () => tester.pump(const Duration(milliseconds: 16)),
                  nowUs: () => Timeline.now,
                  physicalClocks: () => backend.clocks,
                  sensorIndex: eventIndex,
                  sensorAcknowledgedUs: (index) =>
                      backend.inputCompletedUs[index],
                  paddleCenter: paddleCenter,
                  expectPaddleChange:
                      optimized && (key.$1 == 'up' || key.$1 == 'down'),
                  error: () => state()['error']?.toString(),
                );
                expect(
                  (state()['heldKeys'] as Iterable).contains(key.$1),
                  isFalse,
                );
                await releaseProof(key.$4, input.releasedUs);
                inputLatencies.add({
                  'cycle': cycle,
                  'mode': mode,
                  'input': key.$1,
                  'interaction':
                      'Flutter key down/up on focused production monitor',
                  ...input.latencies,
                  ...paddleLatencyApplicability(key.$1),
                  'acceptedAtClock':
                      backend.inputEvents[input.sensorIndex]['atClock'],
                  'releaseToVerifiedNoMorePulsesMs':
                      (Timeline.now - input.releasedUs) / 1000,
                });
              });
            }
            await measure('computer.touch-hold-down', () async {
              final button = find.bySemanticsLabel('计算机向下');
              await revealComputerProfileTarget(tester, button);
              final start = backend.inputEvents.length;
              late TestGesture gesture;
              int eventIndex() => backend.inputEvents.indexWhere(
                (event) => event['x'] == 6517,
                start,
              );
              final input = await observeComputerProfileHeldInput(
                input: 'touch-hold-down',
                press: () async {
                  gesture = await tester.startGesture(tester.getCenter(button));
                },
                release: () async {
                  await gesture.up();
                  await tester.pump();
                },
                pump: () => tester.pump(const Duration(milliseconds: 16)),
                nowUs: () => Timeline.now,
                physicalClocks: () => backend.clocks,
                sensorIndex: eventIndex,
                sensorAcknowledgedUs: (index) =>
                    backend.inputCompletedUs[index],
                paddleCenter: paddleCenter,
                expectPaddleChange: optimized,
                error: () => state()['error']?.toString(),
              );
              expect(
                (state()['heldKeys'] as Iterable).contains('down'),
                isFalse,
              );
              await releaseProof(6517, input.releasedUs);
              inputLatencies.add({
                'cycle': cycle,
                'mode': mode,
                'input': 'touch-hold-down',
                'interaction':
                    'pointer down/up on production direction control',
                ...input.latencies,
                ...paddleLatencyApplicability('touch-hold-down'),
                'acceptedAtClock':
                    backend.inputEvents[input.sensorIndex]['atClock'],
                'releaseToVerifiedNoMorePulsesMs':
                    (Timeline.now - input.releasedUs) / 1000,
              });
            });
            await tap('暂停');
            final before = Uint8List.fromList(
              (state()['displayFrames'] as Map)['黑白显示器'] as Uint8List,
            );
            await measure('computer.run-physical-program', () async {
              await tap('运行物理时钟', wait: false);
              await revealComputerProfileTarget(
                tester,
                findComputerProfileMonitor('黑白显示器，显示实际物理像素状态'),
              );
              final watch = Stopwatch()..start();
              final clocksBefore = backend.clocks,
                  pollsBefore = state()['displayedFrames'] as int;
              var observedChanges = 0;
              var allDarkSamples = litPixels(before) == 0;
              Uint8List previous = before;
              while (watch.elapsed < const Duration(seconds: seconds)) {
                await tester.pump(const Duration(milliseconds: 16));
                if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
                if (state()['error'] != null) fail(state()['error'].toString());
                final next =
                    (state()['displayFrames'] as Map)['黑白显示器'] as Uint8List;
                if (litPixels(next) != 0) allDarkSamples = false;
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
              if (optimized) {
                expect(
                  observedChanges,
                  greaterThan(1),
                  reason:
                      'WireHead rules must produce actual changing Pong pixels',
                );
                expect(allDarkSamples, isFalse);
              }
              observations.add({
                'cycle': cycle,
                'mode': mode,
                'pixelRule': pixelRule,
                'displayCompatibility': displayCompatibility,
                'readyMetadata': selectedReadyMetadata,
                'cpuRamLiveness': {
                  'measurement': 'passive-lamp-queries-no-reset-bus',
                  'cpuProbeCount': backend.cpuProbeCount,
                  'ramProbeBytes': 1088,
                  'distinctCpuStates': distinctCpuStates,
                  'distinctRamStates': distinctRamStates,
                },
                'deterministicTrace': trace,
                'inputEventsAtPhysicalClock': inputEvents,
                'observedDisplayChanges': observedChanges,
                'allDarkSamples': allDarkSamples,
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
            await observeLoad(
              'reset-original',
              () => measure('computer.reset-original', () async {
                await tap('重置', wait: false);
                await tester.pump(const Duration(milliseconds: 250));
                await tap('继续');
              }),
            );
            expect(state()['programName'], savedProgram);
            expect(state()['canRunComputer'], isTrue);
            expect(state()['physicalPulses'], savedPulses);
            await measure('computer.close', () => tap('关闭'));
            expect(state()['open'], isFalse);
          } finally {
            await workspace.close();
            await tester.pumpWidget(const SizedBox());
            controller.dispose();
            workspace.dispose();
            await storage.close();
            await osProbe.closePoint({
              'phase': 'after-cycle-close',
              'cycle': cycle,
              'mode': mode,
            });
          }
          snapshots.add({
            'phase': 'after-close',
            'cycle': cycle,
            'mode': mode,
            'harnessRetainedControllerSamples': recorder.dispatches.length,
            'harnessRetainedFrameCount': recorder.frames.length,
            'harnessRetainedOperationWindows': recorder.windows.length,
            ...await memory.memorySnapshot(),
          });
        }
      }
      await tester.pump(const Duration(seconds: 1));
      final steady = recorder.results().where(
        (row) =>
            (row['id'] as String).startsWith('computer.run-physical-program.'),
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
      loadingMemory = await osProbe.finish();
      if (!kIsWeb) {
        expect(
          loadingMemory['status'],
          'observed',
          reason: 'Loading OS samples must be present and complete.',
        );
        expect((loadingMemory['windows'] as List).length, cycles * 6 + 1);
        expect((loadingMemory['closeSamples'] as List).length, cycles * 4);
      }
      status = 'passed';
    } catch (e, stack) {
      failure = e.toString();
      failureStack = stack.toString();
      rethrow;
    } finally {
      recorder.stop();
      loadingMemory ??= await osProbe?.finish();
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
        'schema': 2,
        'inputFormat': 'wld-only',
        'circuitAbi': observedCircuitAbi,
        'status': status,
        'buildMode': 'profile',
        'dispatcherCoverageSchema': 1,
        'loadingOperationCoverage': 'initial-reimport-reset-v1',
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
          'wldBytes': source.length,
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
        'methodology': 'Every lifecycle is retained with no excluded warmup. First and repeat cycles are identified; filesystem/cache state is uncontrolled. Each cycle runs standard game TripWire rules then optimized WireHead pixel pairing. Fixed pulse/input checkpoints compare passive CPU/RAM across modes, while display expectations are mode-specific. Steady throughput uses equal wall-time windows.',
        'operations': rows,
        'controllerOperations': recorder.controllerResults(),
        'observations': observations,
        'inputLatencies': inputLatencies,
        'memory': snapshots,
        'loadingOsMemory': loadingMemory,
        'limits': [
          'Controller samples and additional program/read-display workflows are retained in process memory; older reports without this instrumentation are not same-workload latency or memory baselines. New operation IDs are unpaired until independently measured baseline runs exist.',
          'System file chooser latency excluded; picker returns explicit source handles.',
          'No target-device claim follows from Linux or browser profiling.',
          'Input uses independently calibrated physical sensors and sticky read-clear semantics.',
          'Input latency starts at framework-injected real key/pointer events and ends at the actual sensor-command completion. OS device latency and raster presentation latency are not claimed.',
          'The standard game-rule mode must execute the CPU; its actual monitor pixels are recorded without a Pong display compatibility claim, and decoded paddle latency is explicitly not applicable. Only WireHead mode must demonstrate displayed Pong motion.',
        ],
      };
      binding.reportData = report;
      await memory.writeStandaloneReport(report);
      await memory.closeMemoryProbe();
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
