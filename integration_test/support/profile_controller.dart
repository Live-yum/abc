import 'dart:developer';

import 'package:terraforge/ui/terra_contract.dart';

import 'profile_recorder.dart';

/// Test-only proxy around the actual production controller. It does not alter
/// scheduling, arguments, errors or state; all production UI dispatches use it.
class ProfiledTerraController extends TerraController {
  ProfiledTerraController(
    this.delegate,
    this.recorder,
    this.cycle,
    this.warmup,
  ) {
    delegate.addListener(notifyListeners);
  }
  final TerraController delegate;
  final ProfileRecorder recorder;
  final int cycle;
  final bool warmup;

  @override
  TerraViewState get view => delegate.view;

  @override
  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    final scope = recorder.activeScope;
    final variants = <String, String>{};
    const safe = {
      'kind': {
        'world',
        'player',
        'save',
        'project',
        'image',
        'resources',
        'achievements',
        'worldRules',
        'markers',
        'mapping',
        'pixelProject',
        'fusionProject',
        'circuitProject',
        'pixelPng',
        'mapPng',
      },
      'canvas': {'world', 'player', 'pixel', 'fusion', 'circuit', 'map'},
      'method': {
        'select',
        'copy',
        'cut',
        'paste',
        'undo',
        'redo',
        'paint',
        'placeTile',
        'updateTile',
        'transformClipboard',
        'applyActuators',
        'markSaved',
        'interact',
        'step',
        'trigger',
        'advanceTime',
        'advanceBoundary',
      },
    };
    for (final entry in safe.entries) {
      final value = args[entry.key];
      if (value is String && entry.value.contains(value)) {
        variants[entry.key] = value;
      }
    }
    // Safe harness taxonomy distinguishes import-project workflows without
    // inspecting or logging a selected filename, document contents or values.
    final family = scope?.split('.').elementAtOrNull(1);
    if (const {
      'wld',
      'plr',
      'pixel',
      'region',
      'circuit',
      'tcw',
      'rules',
      'map',
      'resources',
      'local',
    }.contains(family)) {
      variants['scopeFamily'] = family!;
    }
    final started = Timeline.now;
    var threw = false;
    try {
      await delegate.dispatch(action, args);
    } catch (_) {
      threw = true;
      rethrow;
    } finally {
      final elapsed = Timeline.now - started;
      recorder.dispatches.add({
        'action': action,
        'variant': variants,
        'cycle': cycle,
        'warmup': warmup,
        'macroScope': scope,
        'durationMs': elapsed / 1000,
        // Returned futures can expose a rejection in view state. Its associated
        // workflow checks that result without another full snapshot here.
        'completion': threw ? 'threw' : 'returned',
      });
    }
  }

  @override
  void dispose() {
    delegate.removeListener(notifyListeners);
    super.dispose();
  }
}
