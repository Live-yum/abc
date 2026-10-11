// Explicit test-only external electrical stimulus for the public fixture.
// This is not NPC simulation and is never imported by production code.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

import '../../test/support/computerraria/layout.dart';

class ComputerrariaDynamicBackend
    implements WorldCircuitSourceBackend, WorldCircuitExternalOwnerBackend {
  ComputerrariaDynamicBackend(this.inner);

  final WorldCircuitSourceBackend inner;
  final events = <Map<String, Object?>>[];
  final frames = <Map<String, Object?>>[];
  WorldCircuitResult? latest;
  int? activeSession;
  bool opening = false;
  bool clockEnabled = false;
  int physicalPulses = 0;
  int mechanicalTicks = 0;
  int completedBatches = 0;
  int _armBatches = 0;
  int? _remainingBatches;
  Completer<void>? _budget;
  String phase = 'idle';

  @override
  bool get completesCircuitBatchFromExternalEvent =>
      inner is WorldCircuitExternalOwnerBackend &&
      (inner as WorldCircuitExternalOwnerBackend)
          .completesCircuitBatchFromExternalEvent;

  void _record(Map<String, Object?> event) {
    if (events.length >= 4096) {
      throw StateError('Bounded external-clock trace capacity exceeded');
    }
    events.add(event);
  }

  void arm(String nextPhase, {int? batches}) {
    if (clockEnabled || activeSession == null || opening) {
      throw StateError('External clock requires an idle open fixture');
    }
    if (batches != null && (batches < 1 || batches > 128)) {
      throw RangeError.range(batches, 1, 128);
    }
    phase = nextPhase;
    _armBatches = 0;
    _remainingBatches = batches;
    _budget = batches == null ? null : Completer<void>();
    clockEnabled = true;
    _record({
      'kind': 'external-clock-arm',
      'phase': phase,
      'atUs': Timeline.now,
      'pulseBatch': 128,
      'fixedBatches': batches,
      'clockSource': 'explicit-test-injected-wire-stimulus-not-NPC',
    });
  }

  Future<void> get budgetReached {
    final budget = _budget;
    if (budget == null) throw StateError('No fixed electrical trace armed');
    return budget.future;
  }

  void disarm(String reason) {
    clockEnabled = false;
    _record({
      'kind': 'external-clock-disarm',
      'reason': reason,
      'phase': phase,
      'atUs': Timeline.now,
      'completedPhysicalPulses': physicalPulses,
    });
  }

  Future<WorldCircuitResult> _wire(
    int id,
    WorldCircuitCommand command,
    String origin,
  ) async {
    final event = <String, Object?>{
      'kind': 'native-command',
      'origin': origin,
      'phase': phase,
      'session': id,
      'words': List<int>.from(command.words),
      'recordCount': command.records.length ~/ 4,
      'recordsJsonSha256': sha256
          .convert(utf8.encode(jsonEncode(command.records)))
          .toString(),
      'startUs': Timeline.now,
    };
    _record(event);
    try {
      final result = await inner.commandWorldCircuit(id, command);
      latest = result;
      event.addAll({
        'status': 'completed',
        'nativeTicks': result.ticks,
        'netPulses': result.netPulses,
        'gatesFired': result.gatesFired,
      });
      return result;
    } catch (error) {
      event.addAll({'status': 'failed', 'error': error.toString()});
      rethrow;
    } finally {
      event['endUs'] = Timeline.now;
    }
  }

  Future<bool> _beforeTick(int id, WorldCircuitCommand command) async {
    if (!clockEnabled || command.words[1] != 3) return false;
    if (command.words[8] != 6 || id != activeSession) {
      throw StateError('Fixture stimulus accepts production six-tick batches');
    }
    if (++_armBatches > 300) {
      disarm('bounded-clock-limit');
      throw StateError('External-clock run exceeded 300 accepted batches');
    }
    // The production session already owns this queue slot. Await the real
    // external wire stimulus, then forward the original ticks and pixel query.
    // No trigger replaces a tick, and no frame is synthesized.
    await _wire(id, ComputerrariaComputer.clock(128), 'test-external-clock');
    physicalPulses += 128;
    if (_remainingBatches != null) {
      _remainingBatches = _remainingBatches! - 1;
      if (_remainingBatches == 0) clockEnabled = false;
    }
    return true;
  }

  void _completed(
    WorldCircuitCommand command,
    bool injected,
    WorldCircuitResult? pixels,
  ) {
    if (command.words[1] == 3) mechanicalTicks += command.words[8];
    if (!injected) return;
    completedBatches++;
    if (pixels == null) {
      throw StateError('Accepted external clocks have no actual pixel result');
    }
    final rgba = ComputerrariaComputer.mono.decode(pixels);
    var lit = 0;
    for (var at = 0; at < rgba.length; at += 4) {
      if (rgba[at] == 255) lit++;
    }
    if (frames.length >= 512) {
      throw StateError('Bounded actual-pixel trace capacity exceeded');
    }
    frames.add({
      'phase': phase,
      'atUs': Timeline.now,
      'physicalPulses': physicalPulses,
      'mechanicalTicks': mechanicalTicks,
      'recordCount': pixels.records.length ~/ 16,
      'recordsSha256': sha256.convert(pixels.records).toString(),
      'rgbaSha256': sha256.convert(rgba).toString(),
      'litPixels': lit,
      'nativeTicks': pixels.ticks,
      'netPulses': pixels.netPulses,
      'gatesFired': pixels.gatesFired,
    });
    if (_remainingBatches == 0 && !(_budget?.isCompleted ?? true)) {
      _budget!.complete();
    }
  }

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource source, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    disarm('open');
    opening = true;
    final event = <String, Object?>{
      'kind': 'native-open',
      'sourceBytes': source.length,
      'startUs': Timeline.now,
    };
    _record(event);
    try {
      final result = await inner.openWorldCircuitSource(
        source,
        onProgress: onProgress,
      );
      latest = result;
      activeSession = result.session;
      event.addAll({
        'status': 'ready',
        'session': result.session,
        'sourceSha256': result.sourceSha256,
      });
      return result;
    } catch (error) {
      event.addAll({
        'status': 'failed-or-cancelled',
        'error': error.toString(),
      });
      rethrow;
    } finally {
      opening = false;
      event['endUs'] = Timeline.now;
    }
  }

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List world) =>
      throw StateError('This diagnostic requires explicit ranged WLD sources');

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int id,
    WorldCircuitCommand command,
  ) async {
    if (clockEnabled && command.words[1] == 3) {
      throw StateError(
        'Armed fixture ticks require the actual compound pixel path',
      );
    }
    final result = await _wire(id, command, 'production-or-readonly-probe');
    _completed(command, false, null);
    return result;
  }

  @override
  Future<WorldCircuitBatchResult> commandAndReadPixels(
    int id,
    WorldCircuitCommand command,
    WorldCircuitCommand pixels,
  ) async {
    final event = <String, Object?>{
      'kind': 'production-command-and-pixels',
      'phase': phase,
      'session': id,
      'words': List<int>.from(command.words),
      'pixelWords': List<int>.from(pixels.words),
      'externalClockInjectedBeforeOriginalCommand': false,
      'startUs': Timeline.now,
    };
    _record(event);
    try {
      final injected = await _beforeTick(id, command);
      event['externalClockInjectedBeforeOriginalCommand'] = injected;
      final WorldCircuitBatchResult frame;
      if (inner is WorldCircuitBatchBackend) {
        frame = await (inner as WorldCircuitBatchBackend).commandAndReadPixels(
          id,
          command,
          pixels,
        );
      } else {
        final result = await _wire(id, command, 'production-batch-command');
        final actualPixels = await _wire(id, pixels, 'production-batch-pixels');
        frame = WorldCircuitBatchResult(command: result, pixels: actualPixels);
      }
      latest = frame.command;
      if (frame.pixels == null || frame.readError != null) {
        throw StateError(frame.readError ?? 'Compound read has no pixels');
      }
      _completed(command, injected, frame.pixels);
      event['status'] = 'completed';
      return frame;
    } catch (error, stack) {
      disarm('failed-batch');
      event.addAll({'status': 'failed', 'error': error.toString()});
      if (!(_budget?.isCompleted ?? true)) _budget!.completeError(error, stack);
      rethrow;
    } finally {
      event['endUs'] = Timeline.now;
    }
  }

  @override
  Future<void> closeWorldCircuit(int id) async {
    disarm('close');
    await inner.closeWorldCircuit(id);
    activeSession = null;
    _record({'kind': 'native-close', 'session': id, 'atUs': Timeline.now});
  }

  @override
  Future<void> cancelWorldCircuitOperation() async {
    disarm('cancel');
    await inner.cancelWorldCircuitOperation();
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() =>
      inner.worldCircuitProgress();

  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) =>
      inner.releaseWorldCircuitSource(source);
}
