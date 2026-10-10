// A distinct full-application shell experiment, not the panel-only acceptance.
// Both arms use this identical harness and the pinned public WLD/Pong inputs.
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/native_engine.dart' as core;
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/engine/world_circuit_factory.dart' as circuit_factory;
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/terra_app.dart';

import 'support/computer_inputs_native.dart' as inputs;
import 'support/computer_profile_interaction.dart';

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
  testWidgets('full shell physical Pong steady rendering', (tester) async {
    if (!kProfileMode) fail('Only flutter drive --profile is accepted.');
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    expect(tester.view.physicalSize.width / tester.view.devicePixelRatio,
        greaterThanOrEqualTo(1000), reason: 'This arm is the desktop shell.');
    final source = await inputs.computerInput();
    final engine = core.createTerraEngine();
    final backend = circuit_factory.createWorldCircuitBackend(engine)!;
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
      if (!recording) return;
      for (final frame in batch) {
        if (frames.length < 20000) {
          frames.add(frame);
        } else {
          droppedFrames++;
        }
      }
    }

    Map<String, Object?> state() => Map<String, Object?>.from(
      workspace.view.result['worldCircuit'] as Map,
    );
    Future<void> dispatch(String action, [Map<String, Object?> args = const {}]) async {
      var complete = false;
      Object? failure;
      final pending = workspace.dispatch(action, args).then<void>(
        (_) { complete = true; },
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
      if (failure != null) throw failure!;
      if (workspace.view.error.isNotEmpty) fail(workspace.view.error);
      if (state()['error'] != null) fail('${state()['error']}');
      await tester.pump();
    }

    final report = <String, Object?>{
      'schema': 1,
      'scenario': 'full-terraforge-shell-physical-pong',
      'status': 'failed',
      'sourceBaseCommit': const String.fromEnvironment('PERF_COMMIT'),
      'diagnosticHead': const String.fromEnvironment('SHELL_DIAGNOSTIC_HEAD'),
      'armSourceManifestSha256': const String.fromEnvironment('SHELL_SOURCE_MANIFEST_SHA256'),
      'arm': const String.fromEnvironment('SHELL_PROFILE_ARM'),
      'buildMode': 'profile',
      'inputFormat': 'wld-only',
      'worldSha256': ComputerrariaComputer.sourceSha256,
      'worldBytes': source.length,
      'windowSeconds': 30,
      'mode': 'optimized',
      'frameSource': 'SchedulerBinding FrameTiming; no forced pumps in steady window',
      'limits': [
        'Linux profile renderer only, not mobile or macOS hardware acceptance.',
        'No OS, heap, allocation-profile, screenshot or full-state polling in steady window.',
        'Scalar full-view getter count has identical overhead in both arms.',
        'Key timestamps record injected framework events, not input-to-raster latency.',
        'Timed output differs with executed pulse count; fixed-pulse checkpoint is compared separately.',
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
      expect(state()['computerVerified'], isTrue);
      expect(state()['keyboardVerified'], isTrue);
      await dispatch('worldCircuitOptimization', {'enabled': true});
      await dispatch('worldCircuitLoadPong');
      stage = 'fixed-pulse-checkpoint';
      for (var i = 0; i < 40; i++) {
        await dispatch('worldCircuitStep', {'pulses': 128});
      }
      final fixed = state();
      final fixedPixels = (fixed['displayFrames'] as Map)[ComputerrariaComputer.mono.name] as Uint8List;
      expect(fixed['physicalPulses'], 5120);
      expect(fixedPixels.where((v) => v != 0).length, greaterThan(3072));
      report['fixedCheckpoint'] = {
        'pulses': fixed['physicalPulses'],
        'pixelSha256': sha256.convert(fixedPixels).toString(),
        'pixelBytes': fixedPixels.length,
      };
      final monitor = findComputerProfileMonitor('黑白显示器，显示实际物理像素状态');
      await focusComputerProfileMonitor(tester, monitor);
      stage = 'warmup';
      await dispatch('worldCircuitToggle');
      // fullyLive lets production timers and actual framework scheduling run.
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await dispatch('worldCircuitPause');
      expect(state()['running'], isFalse);
      await focusComputerProfileMonitor(tester, monitor);
      await dispatch('worldCircuitToggle');
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      final before = state();
      expect(before['running'], isTrue);
      final readsBefore = workspace.fullViewReads;
      final start = Timeline.now;
      final keys = <Map<String, Object?>>[];
      SchedulerBinding.instance.addTimingsCallback(receive);
      recording = true;
      stage = 'steady';
      // No pump/view/snapshot/hash call in this window. Real key dispatches are
      // included in its frame costs and remain identical between both arms.
      await tester.runAsync(() async {
        Future<void> until(int offsetUs) async {
          final remainingUs = start + offsetUs - Timeline.now;
          if (remainingUs > 0) {
            await Future<void>.delayed(Duration(microseconds: remainingUs));
          }
        }
        await until(10000000);
        keys.add({'event': 'up-down', 'atUs': Timeline.now});
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.arrowUp,
          physicalKey: PhysicalKeyboardKey.arrowUp,
        );
        await until(10250000);
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.arrowUp,
          physicalKey: PhysicalKeyboardKey.arrowUp,
        );
        keys.add({'event': 'up-up', 'atUs': Timeline.now});
        await until(20000000);
        keys.add({'event': 'down-down', 'atUs': Timeline.now});
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.arrowDown,
          physicalKey: PhysicalKeyboardKey.arrowDown,
        );
        await until(20250000);
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.arrowDown,
          physicalKey: PhysicalKeyboardKey.arrowDown,
        );
        keys.add({'event': 'down-up', 'atUs': Timeline.now});
        await until(30000000);
      });
      final end = Timeline.now;
      final readDelta = workspace.fullViewReads - readsBefore;
      expect(keys.map((key) => key['event']),
          ['up-down', 'up-up', 'down-down', 'down-up'],
          reason: 'Missing bounded framework key sequence.');
      expect(end - start, greaterThanOrEqualTo(30000000),
          reason: 'Steady window did not finish its bounded schedule.');
      stage = 'drain';
      await dispatch('worldCircuitPause');
      // Timings batches can arrive late; filtering uses frame timestamps.
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      recording = false;
      SchedulerBinding.instance.removeTimingsCallback(receive);
      final after = state();
      expect(after['running'], isFalse);
      expect(after['physicalPulses'] as int, greaterThan(before['physicalPulses'] as int));
      expect(after['displayedFrames'] as int, greaterThan(before['displayedFrames'] as int));
      expect(droppedFrames, 0);
      final selected = frames.where((frame) {
        final at = frame.timestampInMicroseconds(FramePhase.vsyncStart);
        return at >= start && at < end;
      }).toList();
      expect(selected, isNotEmpty, reason: 'No observed frames cannot pass as smooth.');
      expect(selected.map((f) => f.frameNumber).toSet().length, selected.length,
          reason: 'Duplicate engine frame identifiers invalidate the sample.');
      final rate = tester.view.display.refreshRate;
      report.addAll({
        'status': 'success',
        'window': {'startUs': start, 'endUs': end, 'fullViewReads': readDelta},
        'progress': {
          'pulsesBefore': before['physicalPulses'],
          'pulsesAfter': after['physicalPulses'],
          'displayReadsBefore': before['displayedFrames'],
          'displayReadsAfter': after['displayedFrames'],
        },
        'viewport': {
          'physicalWidth': tester.view.physicalSize.width,
          'physicalHeight': tester.view.physicalSize.height,
          'devicePixelRatio': tester.view.devicePixelRatio,
        },
        'refreshRateHz': rate.isFinite && rate > 0 ? rate : null,
        'refreshCalibration': rate.isFinite && rate > 0 ? 'observed' : 'unavailable',
        'keys': keys,
        'droppedFrames': droppedFrames,
        'windowFrameCount': selected.length,
        'lastWindowVsyncGapUs': end - selected.last.timestampInMicroseconds(FramePhase.vsyncStart),
        'frames': [for (final f in frames) {
          'frameNumber': f.frameNumber,
          'vsyncStartUs': f.timestampInMicroseconds(FramePhase.vsyncStart),
          'inWindow': f.timestampInMicroseconds(FramePhase.vsyncStart) >= start &&
              f.timestampInMicroseconds(FramePhase.vsyncStart) < end,
          'buildUs': f.buildDuration.inMicroseconds,
          'rasterUs': f.rasterDuration.inMicroseconds,
          'totalSpanUs': f.totalSpan.inMicroseconds,
        }],
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
        await workspace.dispatch('worldCircuitReleaseKeys');
        await workspace.dispatch('worldCircuitClose', {'discard': true});
        report['cleanup'] = 'closed';
      } catch (error, stack) {
        report['status'] = 'failed';
        report['cleanup'] = 'failed';
        report['cleanupFailure'] = error.toString();
        report['cleanupStack'] = stack.toString();
        if (!failedBeforeCleanup) rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        workspace.dispose();
        binding.reportData = report;
      }
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
