// Opt-in bounded attribution experiment, not a latency/FPS acceptance baseline.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_factory.dart'
    as circuit_factory;
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import 'support/computer_inputs_native.dart' as inputs;
import 'support/computer_memory_journal.dart';
import 'support/computer_profile_storage.dart';
import 'support/profile_controller.dart';
import 'support/profile_memory_native.dart' as memory;
import 'support/profile_recorder.dart';

class _SourceFiles implements WorldCircuitFileGateway {
  _SourceFiles(this.original, this.storage);
  final WorldCircuitSource original;
  final ComputerProfileStorage storage;
  WorldCircuitSource? saved;
  bool reopenSaved = false;
  @override
  Future<WorldCircuitSource?> pick() async => reopenSaved ? saved! : original;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    saved = await storage.retain(source, name);
    return true;
  }
}

class _NoByteFiles implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) => throw StateError('No byte inputs');
  @override
  Future<bool> save(String name, Uint8List bytes) =>
      throw StateError('Only streamed WLD output is permitted');
}

class _ObservedBackend
    implements WorldCircuitSourceBackend, WorldCircuitExternalOwnerBackend {
  _ObservedBackend(this.inner, this.events);
  final WorldCircuitSourceBackend inner;
  final List<Map<String, Object?>> events;
  WorldCircuitResult? latest;
  int? session;
  int physicalClocks = 0;
  @override
  bool get completesComputerBatchFromExternalEvent =>
      inner is WorldCircuitExternalOwnerBackend &&
      (inner as WorldCircuitExternalOwnerBackend)
          .completesComputerBatchFromExternalEvent;

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

  void _observeClock(WorldCircuitCommand command) {
    if (command.words[1] == 2 &&
        command.words[2] == 3194 &&
        command.words[3] == 153) {
      physicalClocks += command.words[8];
    }
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int id,
    WorldCircuitCommand command,
  ) async {
    latest = await inner.commandWorldCircuit(id, command);
    _observeClock(command);
    return latest!;
  }

  @override
  Future<WorldCircuitComputerFrame> clockAndReadDisplay(
    int id,
    WorldCircuitCommand clock,
    WorldCircuitCommand pixels,
  ) async {
    if (inner is WorldCircuitComputerBackend) {
      final frame = await (inner as WorldCircuitComputerBackend)
          .clockAndReadDisplay(id, clock, pixels);
      latest = frame.clock;
      _observeClock(clock);
      return frame;
    }
    final clockResult = await commandWorldCircuit(id, clock);
    return WorldCircuitComputerFrame(
      clock: clockResult,
      display: await commandWorldCircuit(id, pixels),
    );
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

Future<void> _quiet(
  WidgetTester tester,
  ComputerMemoryJournal journal,
  int cycle,
) async {
  journal.boundary('drain-start', cycle);
  // Three explicit framework frame barriers, then 1.2 seconds of real quiet.
  // This bounds late timing collection; it cannot force an engine timing flush
  // or prove that the compositor has physically freed every resource.
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  journal.boundary('drain-end', cycle);
}

// ignore: library_private_types_in_public_api
Future<_ObservedBackend> runComputerMemoryDiagnosticCycle({
  required WidgetTester tester,
  required int cycle,
  required WorldCircuitSource source,
  required ComputerMemoryJournal journal,
  required ComputerMemoryOsJournal os,
  required Map<String, Object?> evidence,
}) async {
  final optimized = cycle.isOdd;
  final mode = optimized ? 'optimized' : 'standard';
  final scenario = (cycle ~/ 2).isEven ? 'reset-original' : 'save-reopen';
  final engine = core.createTerraEngine();
  final events = <Map<String, Object?>>[];
  final backend = _ObservedBackend(
    circuit_factory.createWorldCircuitBackend(engine)!
        as WorldCircuitSourceBackend,
    events,
  );
  final storage = await createComputerProfileStorage();
  final files = _SourceFiles(source, storage);
  Workspace newWorkspace() => Workspace(
    engine: engine,
    files: _NoByteFiles(),
    vault: storage.vault,
    worldCircuitBackend: backend,
    worldCircuitFiles: files,
  );
  var workspace = newWorkspace();
  var controller = ProfiledTerraController(
    workspace,
    journal.recorder,
    cycle,
    false,
    profileMode: mode,
  );
  Map state() => workspace.view.result['worldCircuit'] as Map;
  void check() {
    expect(workspace.view.error, isEmpty);
    expect(state()['error'], isNull);
  }

  Future<void> mount() => tester.pumpWidget(
    MaterialApp(
      theme: terraTheme(),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: workspace,
          builder: (context, child) => SingleChildScrollView(
            child: WorldCircuitPanel(
              state: Map<String, Object?>.from(state()),
              dispatch: controller.dispatch,
              hostStages: workspace.hostStages,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> action(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    await journal.recorder.measure(
      '$action.$mode',
      cycle,
      false,
      () async {
        await controller.dispatch(action, args);
        await tester.pump();
        check();
      },
      interaction:
          'production controller and rendered panel, fixed bounded diagnostic',
    );
  }

  Future<void> load(String kind, String operation) async {
    journal.boundary('$kind-start', cycle);
    await os.request('point', 'cycle-$cycle.$kind-start');
    await action(operation);
    expect(state()['computerVerified'], isTrue);
    expect(state()['keyboardVerified'], isTrue);
    expect(backend.latest!.stats[0], 2);
    expect(
      (state()['displayFrames'] as Map)[ComputerrariaComputer.mono.name],
      hasLength(64 * 48 * 4),
    );
    journal.boundary('$kind-ready', cycle);
    await os.request('point', 'cycle-$cycle.$kind-ready');
  }

  Future<void> closeWorkspace() async {
    await workspace.close();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    workspace.dispose();
  }

  evidence.addAll({
    'cycle': cycle,
    'mode': mode,
    'scenario': scenario,
    'events': events,
    'status': 'started',
  });
  var disposed = false;
  try {
    await mount();
    await action('worldCircuitChooseWorld');
    if (cycle == 0) {
      journal.boundary('cancelled-import-start', cycle);
      await os.request('point', 'cycle-0.cancelled-import-start');
      final pending = controller.dispatch('worldCircuitImport');
      final watch = Stopwatch()..start();
      while (state()['importing'] != true || events.isEmpty) {
        if (watch.elapsed > const Duration(seconds: 10)) {
          fail('Import never entered cancellable state');
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      evidence['cancelRequestedAfterNativeOpenStarted'] = true;
      await controller.dispatch('worldCircuitCancel');
      await pending;
      await tester.pump();
      check();
      expect(state()['open'], isFalse);
      evidence['cancelledImportObserved'] = true;
      evidence['cancelledImportNativeOutcome'] = events.first['outcome'];
      journal.boundary('cancelled-import-end', cycle);
      await os.request('point', 'cycle-0.cancelled-import-end');
      await action('worldCircuitChooseWorld');
    }
    await load('initial-import', 'worldCircuitImport');
    expect(state()['programName'], isNull);
    expect(state()['optimizationEnabled'], isFalse);
    if (optimized) await action('worldCircuitOptimization', {'enabled': true});
    await action('worldCircuitLoadPong');
    expect(state()['programName'], 'Pong (upstream RV32I).bin');
    expect(state()['canRunComputer'], isTrue);
    final clocksBefore = backend.physicalClocks;
    final pulsesBefore = state()['physicalPulses'] as int;
    final distinctMonoStates = <String>{};
    var maximumLitPixels = 0;
    for (var batch = 0; batch < 32; batch++) {
      await action('worldCircuitStep', {'pulses': 128});
      final frame =
          (state()['displayFrames'] as Map)[ComputerrariaComputer.mono.name]
              as Uint8List;
      expect(frame.length, 64 * 48 * 4);
      var lit = 0;
      for (var at = 0; at < frame.length; at += 4) {
        if (frame[at] != 0 || frame[at + 1] != 0 || frame[at + 2] != 0) lit++;
      }
      if (lit > maximumLitPixels) maximumLitPixels = lit;
      final digest = sha256.convert(frame).toString();
      distinctMonoStates.add(digest);
      journal.recorder.viewportSnapshots.add({
        'cycle': cycle,
        'mode': mode,
        'batch': batch,
        'physicalPulses': (batch + 1) * 128,
        'nativeClockDelta': backend.physicalClocks - clocksBefore,
        'modelPhysicalPulseDelta':
            (state()['physicalPulses'] as int) - pulsesBefore,
        'monoSha256': digest,
        'monoLitPixels': lit,
      });
    }
    await action('worldCircuitPause');
    expect(state()['running'], isFalse);
    expect(backend.physicalClocks - clocksBefore, 4096);
    expect((state()['physicalPulses'] as int) - pulsesBefore, 4096);
    expect(state()['optimizationEnabled'], optimized);
    expect(backend.latest!.circuitOptimizationEnabled, optimized);
    expect(backend.latest!.wireHeadPixelRulesEnabled, optimized);
    if (optimized) {
      expect(distinctMonoStates.length, greaterThan(1));
      expect(maximumLitPixels, greaterThan(0));
    }
    evidence['physicalPulseDelta'] = 4096;
    evidence['pulseBatchCount'] = 32;
    evidence['pulseBatchSize'] = 128;
    evidence['distinctMonoStates'] = distinctMonoStates.length;
    evidence['maximumLitPixels'] = maximumLitPixels;
    evidence['nativeClockDelta'] = backend.physicalClocks - clocksBefore;
    evidence['modelPhysicalPulseDelta'] =
        (state()['physicalPulses'] as int) - pulsesBefore;
    evidence['programName'] = state()['programName'];
    evidence['optimizationEnabledDuringPulse'] = optimized;
    evidence['nativeOptimizationEnabledDuringPulse'] =
        backend.latest!.circuitOptimizationEnabled;
    evidence['nativeWireHeadPixelRulesDuringPulse'] =
        backend.latest!.wireHeadPixelRulesEnabled;
    final mono =
        (state()['displayFrames'] as Map)[ComputerrariaComputer.mono.name]
            as Uint8List;
    final displayDigest = sha256.convert(mono).toString();
    evidence['pausedMonoSha256'] = displayDigest;
    if (scenario == 'reset-original') {
      await load('reset-original', 'worldCircuitReset');
      expect(state()['programName'], isNull);
      expect(state()['physicalPulses'], 0);
      expect(state()['canRunComputer'], isFalse);
      evidence['resetRestoredOriginal'] = true;
    } else {
      final savedPulses = state()['physicalPulses'];
      await action('worldCircuitSave');
      expect(files.saved?.sha256, isNotNull);
      evidence['savedWldSha256'] = files.saved!.sha256;
      await action('worldCircuitClose', {'discard': true});
      await closeWorkspace();
      disposed = true;
      journal.boundary('export-close', cycle);
      await os.request('point', 'cycle-$cycle.export-close');
      files.reopenSaved = true;
      workspace = newWorkspace();
      controller = ProfiledTerraController(
        workspace,
        journal.recorder,
        cycle,
        false,
        profileMode: mode,
      );
      disposed = false;
      await mount();
      await action('worldCircuitChooseWorld');
      final beforeReopen = backend.physicalClocks;
      await load('saved-reopen', 'worldCircuitImport');
      expect(state()['restoredFromExport'], isTrue);
      expect(state()['programName'], evidence['programName']);
      expect(state()['physicalPulses'], savedPulses);
      expect(backend.physicalClocks, beforeReopen);
      expect(
        sha256
            .convert(
              (state()['displayFrames'] as Map)[ComputerrariaComputer.mono.name]
                  as Uint8List,
            )
            .toString(),
        displayDigest,
      );
      evidence['reopenPreservedPausedState'] = true;
    }
    await action('worldCircuitClose', {'discard': true});
    expect(state()['open'], isFalse);
    expect(backend.session, isNull);
    evidence['status'] = 'completed';
  } finally {
    if (!disposed) await closeWorkspace();
    await storage.close();
    journal.boundary('cycle-disposed', cycle);
  }
  return backend;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('eight bounded WLD memory attribution cycles', (tester) async {
    if (!kProfileMode || !Platform.isLinux) {
      fail('Requires real Linux Flutter profile');
    }
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final source = await inputs.computerInput();
    final path = Platform.environment['ABC_MEMORY_RAW_DIRECTORY'];
    if (path == null || path.isEmpty) {
      fail('Explicit new raw directory required');
    }
    final directory = Directory(path);
    if (directory.existsSync()) {
      fail('Raw directory must be new; no mixed attempts');
    }
    await directory.create(recursive: true);
    final recorder = ProfileRecorder(
      frameBudgetUs: 1000000 / 60,
      profile: true,
      currentRss: memory.currentRss,
    );
    final journal = ComputerMemoryJournal(directory, recorder)..start();
    ComputerMemoryOsJournal? os;
    final cycles = <Map<String, Object?>>[], points = <Map<String, Object?>>[];
    Map<String, Object?>? osResult;
    String? failure, failureStack;
    var status = 'failed';
    try {
      os = await ComputerMemoryOsJournal.start(directory);
      points.add(
        await computerMemoryPoint(
          phase: 'baseline',
          cycle: -1,
          journal: journal,
          os: os,
          wrapperLatestRetained: false,
        ),
      );
      for (var cycle = 0; cycle < 8; cycle++) {
        journal.boundary('cycle-start', cycle);
        final evidence = <String, Object?>{};
        cycles.add(evidence);
        final backend = await runComputerMemoryDiagnosticCycle(
          tester: tester,
          cycle: cycle,
          source: source,
          journal: journal,
          os: os,
          evidence: evidence,
        );
        await _quiet(tester, journal, cycle);
        journal.boundary('retained-point', cycle);
        points.add(
          await computerMemoryPoint(
            phase: 'after-close-retained',
            cycle: cycle,
            journal: journal,
            os: os,
            wrapperLatestRetained: backend.latest != null,
          ),
        );
        await journal.flush('cycle-$cycle.release-prefix');
        backend.latest = null;
        journal.boundary('released-prefix', cycle);
        await _quiet(tester, journal, cycle);
        // Capture a fixed second tail prefix. Any callbacks arriving during its
        // hash verification remain live and are counted in the next checkpoint.
        await journal.flush('cycle-$cycle.late-tail');
        journal.boundary('released-point', cycle);
        points.add(
          await computerMemoryPoint(
            phase: 'after-close-released',
            cycle: cycle,
            journal: journal,
            os: os,
            wrapperLatestRetained: false,
          ),
        );
        await os.request('rotate', 'cycle-$cycle.end');
        journal.boundary('cycle-end', cycle);
      }
      await _quiet(tester, journal, 8);
      expect(
        points.every((point) => (point['vm'] as Map)['heapUsedBytes'] != null),
        isTrue,
      );
      status = 'observed';
    } catch (error, stack) {
      failure = error.toString();
      failureStack = stack.toString();
    } finally {
      journal.stop();
      try {
        await journal.flush('final-received-tail');
        osResult = await os?.finish();
        if (osResult != null) {
          if (osResult['error'] != null) {
            status = 'failed';
            failure = '$failure; OS sampler: ${osResult['error']}';
          }
          final files = osResult['files'] as List;
          for (var i = 0; i < files.length; i++) {
            final row = Map<String, Object?>.from(files[i] as Map);
            files[i] = {
              ...row,
              ...await describeRawFile(
                File('${directory.path}/${row['file']}'),
              ),
            };
          }
        }
      } catch (error) {
        status = 'failed';
        failure = '$failure; finalization: $error';
      }
      final report = <String, dynamic>{
        'schema': 'abc.computer-memory-diagnostic.v1',
        'status': status,
        'hostPid': pid,
        'buildMode': 'profile',
        'inputFormat': 'wld-only',
        'circuitAbi': 2,
        'plannedCycles': 8,
        'completedCycles': cycles
            .where((row) => row['status'] == 'completed')
            .length,
        'physicalPulsesPerCycle': 4096,
        'excludedWarmupCycles': 0,
        'fixture': {
          'sourceRevision': '0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8',
          'wldBytes': source.length,
          'wldSha256': ComputerrariaComputer.sourceSha256,
          'pongSha256': 'd2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d',
        },
        'runtime': {
          ...memory.runtimeMetadata(),
          'commit': const String.fromEnvironment('PERF_COMMIT'),
          'checkedOutHead': const String.fromEnvironment(
            'PERF_CHECKED_OUT_HEAD',
          ),
          'workingTreeDirty': const bool.fromEnvironment(
            'PERF_WORKTREE_DIRTY',
            defaultValue: true,
          ),
          'flutterVersion': const String.fromEnvironment(
            'PERF_FLUTTER_VERSION',
          ),
          'flutterRevisionPin': '5fc346839b5d0eef006ed8404392afb4dfae428d',
          'renderer': const String.fromEnvironment('PERF_RENDERER'),
          ...memory.runtimeOverrides(),
        },
        'cycles': cycles,
        'memoryPoints': points,
        'raw': {
          'directory': directory.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last,
          'frameChunks': journal.chunks,
          'os': osResult,
          'boundaries': journal.boundaries,
          'finalCounts': journal.retainedCounts(),
          'recordingStoppedUs': journal.stoppedUs,
        },
        'drainPolicy': {
          'frameBarriers': 3,
          'barrierDelayMs': 16,
          'quietMs': 1200,
          'tailPrefixFlushesPerCycle': 2,
          'capture': 'all-callbacks-received-until-recordingStoppedUs',
        },
        'failure': failure,
        'failureStack': failureStack,
        'limits': [
          'Eight logical cycles, alternating OFF/ON four each; reset and saved reopen each add a native open. No excluded first/cancelled lifecycle.',
          'New harness only; never splice into old performance or memory baselines. No device FPS claim.',
          'OS and VM reads bracket requested GC but are not atomic. RSS/PSS/USS and VM heap are overlapping views, not additive buckets.',
          'Retained/released differences also include elapsed drain, GC and sampler work; they do not uniquely identify native allocation ownership.',
          'All received FrameTiming fields are saved; the fixed tail deadline cannot guarantee receipt of timings still buffered by the engine.',
          'Prefix-only release retains newly arrived callbacks, including prior-cycle frames; timestamp attribution is recomputed offline.',
          'Removing recorded objects does not promise that list backing capacity or allocator pages are returned to the OS.',
          'Raw sampler, VM service, native FFI worker and small cycle/chunk summaries remain in process. Native worker persistence is intentional.',
          'abc_perf counters are not requested or fabricated; native libc, allocator and graphics retention remain unattributed.',
          'No absolute MB threshold or proof of leak freedom; eight cycles only support a bounded-window trend observation.',
        ],
      };
      // A VM-service failure can contain its ephemeral auth path. It is not
      // part of the diagnostic evidence and must never reach an artifact.
      final publicReport = Map<String, dynamic>.from(
        jsonDecode(
          jsonEncode(report).replaceAll(
            RegExp(
              r'''(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?[^\s<>"']*''',
            ),
            '[redacted-local-service-url]',
          ),
        ) as Map,
      );
      binding.reportData = publicReport;
      await memory.writeStandaloneReport(publicReport);
      await memory.closeMemoryProbe();
    }
    expect(status, 'observed', reason: failure);
  }, timeout: const Timeout(Duration(minutes: 40)));
}
