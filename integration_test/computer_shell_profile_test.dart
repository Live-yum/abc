// A distinct full-application shell experiment, not the panel-only acceptance.
// Both arms use this identical harness and the explicit public WLD input.
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'support/generic_circuit_profile.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_factory.dart'
    as circuit_factory;
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/terra_app.dart';

import 'support/computer_inputs_native.dart' as inputs;
import 'package:terraforge/ui/computer_display.dart';

class _Files implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) =>
      throw UnsupportedError('Only the pinned large-world gateway is used.');
  @override
  Future<bool> save(String name, Uint8List bytes) =>
      throw UnsupportedError('This bounded shell scenario does not export.');
}

class _WorldFiles implements WorldCircuitFileGateway {
  _WorldFiles(this.source);
  final WorldCircuitSource source;
  @override
  Future<WorldCircuitSource?> pick() async => source;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) => throw UnsupportedError('This bounded shell scenario does not export.');
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

class _Workspace extends Workspace {
  _Workspace({
    required super.engine,
    required super.files,
    required super.worldCircuitFiles,
    required super.worldCircuitBackend,
  });
  int fullViewReads = 0;
  @override
  TerraViewState get view {
    fullViewReads++;
    return super.view;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('full shell generic WLD steady rendering', (tester) async {
    if (!kProfileMode) {
      fail('Only flutter drive --profile is accepted.');
    }
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    expect(
      tester.view.physicalSize.width / tester.view.devicePixelRatio,
      greaterThanOrEqualTo(1000),
      reason: 'This arm is the desktop shell.',
    );
    final source = await inputs.computerInput();
    final engine = core.createTerraEngine();
    final backend = _ObservedBackend(circuit_factory.createWorldCircuitBackend(engine)! as WorldCircuitSourceBackend, []);
    final workspace = _Workspace(
      engine: engine,
      files: _Files(),
      worldCircuitFiles: _WorldFiles(source),
      worldCircuitBackend: backend,
    );
    final frames = <FrameTiming>[];
    var recording = false;
    var droppedFrames = 0;
    void receive(List<FrameTiming> batch) {
      if (!recording) {
        return;
      }
      for (final frame in batch) {
        if (frames.length < 20000) {
          frames.add(frame);
        } else {
          droppedFrames++;
        }
      }
    }

    Map<String, Object?> state() =>
        Map<String, Object?>.from(workspace.view.result['worldCircuit'] as Map);
    Future<void> dispatch(
      String action, [
      Map<String, Object?> args = const {},
    ]) async {
      var complete = false;
      Object? failure;
      final pending = workspace
          .dispatch(action, args)
          .then<void>(
            (_) {
              complete = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = error;
              complete = true;
            },
          );
      final deadline = Stopwatch()..start();
      while (!complete) {
        if (deadline.elapsed > const Duration(minutes: 6)) {
          fail('Bounded shell action timed out: $action');
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pending;
      if (failure != null) {
        throw failure!;
      }
      if (workspace.view.error.isNotEmpty) {
        fail(workspace.view.error);
      }
      if (state()['error'] != null) {
        fail('${state()['error']}');
      }
      await tester.pump();
    }

    final report = <String, Object?>{
      'schema': 'abc.generic-shell-profile.v1',
      'workloadId': genericCircuitWorkloadId,
      'scenario': 'full-terraforge-shell-generic-circuit',
      'status': 'failed',
      'sourceBaseCommit': const String.fromEnvironment('PERF_COMMIT'),
      'diagnosticHead': const String.fromEnvironment('SHELL_DIAGNOSTIC_HEAD'),
      'armSourceManifestSha256': const String.fromEnvironment(
        'SHELL_SOURCE_MANIFEST_SHA256',
      ),
      'arm': const String.fromEnvironment('SHELL_PROFILE_ARM'),
      'buildMode': 'profile',
      'inputFormat': 'wld-only',
      'worldSha256': publicCircuitFixtureSha256,
      'worldBytes': source.length,
      'windowSeconds': 30,
      'mode': 'optimized',
      'frameSource':
          'SchedulerBinding FrameTiming; no forced pumps in steady window',
      'limits': [
        'Linux profile renderer only, not mobile or macOS hardware acceptance.',
        'No OS, heap, allocation-profile, screenshot or full-state polling in steady window.',
        'Scalar full-view getter count has identical overhead in both arms.',
        'Trigger timestamps record real production dispatcher completion, not physical-input-to-raster latency.',
        'Timed output differs with tick count; a fixed generic tick checkpoint is recorded separately. This workload is not the historical CPU program experiment.',
        'Frame callbacks are drained for two seconds; complete delivery of every trailing engine frame is not assumed.',
      ],
    };
    var stage = 'mount';
    try {
      await tester.pumpWidget(TerraForgeApp(controller: workspace));
      await tester.pump();
      final circuit = find.text('电路实验室').first;
      await tester.ensureVisible(circuit);
      await tester.tap(circuit);
      await tester.pump();
      await tester.tap(find.text('世界电路'));
      await tester.pump();
      stage = 'load';
      await dispatch('worldCircuitChooseWorld');
      await dispatch('worldCircuitImport');
      expect(state()['open'], isTrue);
      expect(backend.events.last['sourceSha256'], publicCircuitFixtureSha256);
      final selection = GenericCircuitSelection.fromState(state());
      await dispatch('worldCircuitViewport', selection.displayRegion);
      await dispatch('worldCircuitReadDisplay', selection.displayRegion);
      await dispatch('worldCircuitOptimization', {'enabled': true});
      await dispatch('worldCircuitTrigger', selection.trigger);
      stage = 'fixed-tick-checkpoint';
      final ticksBefore = state()['ticks'] as int;
      for (var i = 0; i < 32; i++) {
        await dispatch('worldCircuitStep');
      }
      final fixed = state();
      final fixedPixels = fixed['displayFrame'] as Uint8List;
      expect((fixed['ticks'] as int) - ticksBefore, 32);
      expect(fixedPixels.length, selection.displayRegion['width']! * selection.displayRegion['height']! * 4);
      report['fixedCheckpoint'] = {
        'ticks': 32, 'displayRegion': selection.displayRegion,
        'trigger': selection.trigger, 'pixelSha256': sha256.convert(fixedPixels).toString(),
        'pixelBytes': fixedPixels.length,
      };
      final monitor = find.byType(ComputerDisplay);
      expect(monitor, findsOneWidget);
      await tester.ensureVisible(monitor);
      await tester.pump();
      stage = 'warmup';
      await dispatch('worldCircuitToggle');
      // fullyLive lets production timers and actual framework scheduling run.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await dispatch('worldCircuitPause');
      expect(state()['running'], isFalse);
      await dispatch('worldCircuitToggle');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      final before = state();
      expect(before['running'], isTrue);
      final readsBefore = workspace.fullViewReads;
      final start = Timeline.now;
      final interactions = <Map<String, Object?>>[];
      SchedulerBinding.instance.addTimingsCallback(receive);
      recording = true;
      stage = 'steady';
      // Four real generic input operations. Direct triggering pauses the app;
      // resuming is part of this workload and its measured frame costs.
      await tester.runAsync(() async {
        for (final offsetUs in [5000000, 10000000, 15000000, 20000000]) {
          final remainingUs = start + offsetUs - Timeline.now;
          if (remainingUs > 0) {
            await Future<void>.delayed(Duration(microseconds: remainingUs));
          }
          final eventStart = Timeline.now;
          await workspace.dispatch('worldCircuitTrigger', selection.trigger);
          await workspace.dispatch('worldCircuitToggle');
          interactions.add({'event': 'direct-trigger-and-resume', 'startUs': eventStart, 'endUs': Timeline.now});
        }
        final remainingUs = start + 30000000 - Timeline.now;
        if (remainingUs > 0) {
          await Future<void>.delayed(Duration(microseconds: remainingUs));
        }
      });
      final end = Timeline.now;
      final readDelta = workspace.fullViewReads - readsBefore;
      expect(interactions, hasLength(4));
      expect(workspace.view.error, isEmpty);
      expect(state()['error'], isNull);
      expect(end - start, greaterThanOrEqualTo(30000000));
      stage = 'drain';
      await dispatch('worldCircuitPause');
      // Timings batches can arrive late; filtering uses frame timestamps.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      recording = false;
      SchedulerBinding.instance.removeTimingsCallback(receive);
      final after = state();
      expect(after['running'], isFalse);
      expect(
        after['ticks'] as int,
        greaterThan(before['ticks'] as int),
      );
      expect(droppedFrames, 0);
      final selected = frames.where((frame) {
        final at = frame.timestampInMicroseconds(FramePhase.vsyncStart);
        return at >= start && at < end;
      }).toList();
      expect(
        selected,
        isNotEmpty,
        reason: 'No observed frames cannot pass as smooth.',
      );
      expect(
        selected.map((f) => f.frameNumber).toSet().length,
        selected.length,
        reason: 'Duplicate engine frame identifiers invalidate the sample.',
      );
      final rate = tester.view.display.refreshRate;
      report.addAll({
        'status': 'success',
        'window': {'startUs': start, 'endUs': end, 'fullViewReads': readDelta},
        'progress': {
          'ticksBefore': before['ticks'],
          'ticksAfter': after['ticks'],
          'displayRegion': selection.displayRegion,
        },
        'viewport': {
          'physicalWidth': tester.view.physicalSize.width,
          'physicalHeight': tester.view.physicalSize.height,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'refreshRateHz': rate.isFinite && rate > 0 ? rate : null,
        'refreshCalibration': rate.isFinite && rate > 0
            ? 'observed'
            : 'unavailable',
        'interactions': interactions,
        'hostStages': workspace.hostStages.snapshot(),
        'droppedFrames': droppedFrames,
        'windowFrameCount': selected.length,
        'lastWindowVsyncGapUs':
            end - selected.last.timestampInMicroseconds(FramePhase.vsyncStart),
        'frames': [
          for (final f in frames)
            {
              'frameNumber': f.frameNumber,
              'vsyncStartUs': f.timestampInMicroseconds(FramePhase.vsyncStart),
              'inWindow':
                  f.timestampInMicroseconds(FramePhase.vsyncStart) >= start &&
                  f.timestampInMicroseconds(FramePhase.vsyncStart) < end,
              'buildUs': f.buildDuration.inMicroseconds,
              'rasterUs': f.rasterDuration.inMicroseconds,
              'totalSpanUs': f.totalSpan.inMicroseconds,
            },
        ],
      });
      stage = 'close';
      await dispatch('worldCircuitClose', {'discard': true});
      expect(state()['open'], isFalse);
      report['closed'] = true;
    } catch (error, stack) {
      report['status'] = 'failed';
      report['failure'] = error.toString();
      report['failureStack'] = stack.toString();
      rethrow;
    } finally {
      recording = false;
      SchedulerBinding.instance.removeTimingsCallback(receive);
      report['lastStage'] = stage;
      final failedBeforeCleanup = report['status'] != 'success';
      try {
        await workspace.dispatch('worldCircuitClose', {'discard': true});
        report['cleanup'] = 'closed';
      } catch (error, stack) {
        report['status'] = 'failed';
        report['cleanup'] = 'failed';
        report['cleanupFailure'] = error.toString();
        report['cleanupStack'] = stack.toString();
        if (!failedBeforeCleanup) {
          rethrow;
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        workspace.dispose();
        binding.reportData = report;
      }
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
