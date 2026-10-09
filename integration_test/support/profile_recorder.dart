import 'dart:developer';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/scheduler.dart';

/// Delayed engine timing batches are assigned by their monotonic timestamps,
/// not by callback arrival (a batch can arrive a second after an operation).
class ProfileRecorder {
  ProfileRecorder({
    required this.frameBudgetUs,
    required this.profile,
    this.currentRss,
  });
  final double frameBudgetUs;
  final bool profile;
  final int? Function()? currentRss;
  final frames = <FrameTiming>[];
  final windows = <Map<String, Object?>>[];
  final dispatches = <Map<String, Object?>>[];
  String? activeScope;

  void start() => SchedulerBinding.instance.addTimingsCallback(_receive);
  void _receive(List<FrameTiming> batch) => frames.addAll(batch);
  void stop() => SchedulerBinding.instance.removeTimingsCallback(_receive);

  Map<String, Object?> clockDiagnostics() => {
    'firstWindowUs': windows.isEmpty ? null : windows.first['startUs'],
    'lastWindowUs': windows.isEmpty ? null : windows.last['endUs'],
    'firstFrameVsyncUs': frames.isEmpty
        ? null
        : frames.first.timestampInMicroseconds(FramePhase.vsyncStart),
    'lastFrameVsyncUs': frames.isEmpty
        ? null
        : frames.last.timestampInMicroseconds(FramePhase.vsyncStart),
    'totalReceivedFrames': frames.length,
  };

  Future<void> measure(
    String id,
    int cycle,
    bool warmup,
    Future<void> Function() action, {
    String interaction = 'controller dispatch with production UI rendered',
  }) async {
    final rssBefore = currentRss?.call();
    final start = Timeline.now;
    final previousScope = activeScope;
    activeScope = id;
    final task = TimelineTask()..start(id, arguments: {'cycle': cycle});
    var success = false;
    try {
      await action();
      success = true;
    } finally {
      final end = Timeline.now;
      activeScope = previousScope;
      task.finish();
      windows.add({
        'id': id,
        'cycle': cycle,
        'warmup': warmup,
        'startUs': start,
        'endUs': end,
        'rssBeforeBytes': rssBefore,
        'rssAfterBytes': currentRss?.call(),
        'interaction': interaction,
        'success': success,
      });
    }
  }

  List<Map<String, Object?>> results() {
    final groups = <String, List<Map<String, Object?>>>{};
    for (final window in windows) {
      groups.putIfAbsent(window['id']! as String, () => []).add(window);
    }
    return [
      for (final entry in groups.entries) _summarize(entry.key, entry.value),
    ];
  }

  List<Map<String, Object?>> controllerResults() {
    final groups = <String, List<Map<String, Object?>>>{};
    for (final sample in dispatches) {
      final key = '${sample['action']}:${jsonEncode(sample['variant'])}';
      groups.putIfAbsent(key, () => []).add(sample);
    }
    return [
      for (final entry in groups.entries)
        (() {
          final first = entry.value.first;
          final measured = entry.value
              .where((s) => s['warmup'] == false)
              .toList();
          final durations = [
            for (final sample in measured) sample['durationMs']! as double,
          ];
          final variant = first['variant']! as Map<String, String>;
          return <String, Object?>{
            'id':
                'dispatch.${first['action']}${variant.entries.map((v) => '.${v.key}-${v.value}').join()}',
            'action': first['action'],
            'variant': variant,
            'unit': 'ms',
            'sampleCount': measured.length,
            'warmupSampleCount': entry.value.length - measured.length,
            'medianMs': percentile(durations, .5),
            'p95Ms': percentile(durations, .95),
            'maxMs': durations.isEmpty ? null : durations.reduce(math.max),
            'samples': measured,
          };
        })(),
    ];
  }

  Map<String, Object?> _summarize(
    String id,
    List<Map<String, Object?>> samples,
  ) {
    final measured = samples.where((s) => s['warmup'] == false).toList();
    final timedFrames = <FrameTiming>[];
    final perIteration = <Map<String, Object?>>[];
    for (final sample in measured) {
      final matched = frames.where((frame) {
        final timestamp = frame.timestampInMicroseconds(FramePhase.vsyncStart);
        return timestamp >= (sample['startUs']! as int) &&
            timestamp < (sample['endUs']! as int);
      }).toList();
      timedFrames.addAll(matched);
      perIteration.add({
        'cycle': sample['cycle'],
        'success': sample['success'],
        'rssBeforeBytes': sample['rssBeforeBytes'],
        'rssAfterBytes': sample['rssAfterBytes'],
        'latencyMs':
            ((sample['endUs']! as int) - (sample['startUs']! as int)) / 1000,
        'uiUs': [for (final f in matched) f.buildDuration.inMicroseconds],
        'rasterUs': [for (final f in matched) f.rasterDuration.inMicroseconds],
        'totalSpanUs': [for (final f in matched) f.totalSpan.inMicroseconds],
      });
    }
    final ui = [for (final f in timedFrames) f.buildDuration.inMicroseconds];
    final raster = [
      for (final f in timedFrames) f.rasterDuration.inMicroseconds,
    ];
    final latency = [for (final s in perIteration) s['latencyMs']! as double];
    return {
      'id': id,
      'fixture': 'public-synthetic',
      'phase': 'warm',
      'iterations': measured.length,
      'warmup': samples.length - measured.length,
      'interaction': samples.first['interaction'],
      'unit': 'ms',
      'samplesMs': latency,
      'warmupSamplesMs': [
        for (final sample in samples.where((s) => s['warmup'] == true))
          ((sample['endUs']! as int) - (sample['startUs']! as int)) / 1000,
      ],
      'medianMs': percentile(latency, .5),
      'p95Ms': percentile(latency, .95),
      'maxMs': latency.isEmpty ? null : latency.reduce(math.max),
      'frameCount': timedFrames.length,
      'ui': stats(ui),
      'raster': stats(raster),
      'overBudgetFrames': timedFrames
          .where(
            (f) =>
                f.buildDuration.inMicroseconds > frameBudgetUs ||
                f.rasterDuration.inMicroseconds > frameBudgetUs,
          )
          .length,
      'frameBudgetUs': frameBudgetUs,
      'samples': perIteration,
      'status': measured.every((s) => s['success'] == true)
          ? (profile &&
                    (timedFrames.isEmpty ||
                        perIteration.any((s) => (s['uiUs']! as List).isEmpty))
                ? 'missing-frames'
                : 'passed')
          : 'failed',
    };
  }
}

Map<String, Object?> stats(List<int> values) => {
  'medianUs': percentile(values, .5),
  'p95Us': percentile(values, .95),
  'maxUs': values.isEmpty ? null : values.reduce(math.max),
};

double? percentile(List<num> values, double fraction) {
  if (values.isEmpty) return null;
  final sorted = values.map((v) => v.toDouble()).toList()..sort();
  final position = (sorted.length - 1) * fraction;
  final low = position.floor(), high = position.ceil();
  return sorted[low] + (sorted[high] - sorted[low]) * (position - low);
}
