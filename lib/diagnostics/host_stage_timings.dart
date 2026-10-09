import 'package:flutter/foundation.dart';

/// Bounded host wall-time observations, never Flutter FrameTiming or FPS.
/// Recording does not notify listeners, schedule work, or retain payloads.
class HostStageTimings {
  static const capacity = 128;
  static const maxStages = 64;
  final Map<String, _StageSamples> _stages = {};
  int generation = 0;

  void reset() {
    _stages.clear();
    generation++;
  }

  void record(String stage, int microseconds) {
    if (microseconds < 0 ||
        (!_stages.containsKey(stage) && _stages.length >= maxStages)) {
      return;
    }
    (_stages[stage] ??= _StageSamples()).add(microseconds);
  }

  T measure<T>(String stage, T Function() action) {
    final watch = Stopwatch()..start();
    try {
      return action();
    } finally {
      record(stage, watch.elapsedMicroseconds);
    }
  }

  void recordBridge(String command, Map<String, num> values) {
    for (final field in const [
      'coreStepUs',
      'yieldWaitUs',
      'resultCopyUs',
      'commandWallUs',
      'rpcWallUs',
      'rpcQueueUs',
    ]) {
      final value = values[field];
      if (value != null && value.isFinite && value >= 0) {
        record('$command.$field', value.round());
      }
    }
  }

  Map<String, Object?> snapshot() => {
    'schema': 1,
    'host': kIsWeb
        ? 'flutter-web-main-and-dedicated-worker'
        : 'flutter-native-host',
    'unit': 'microseconds',
    'clock': 'Dart Stopwatch; worker performance.now converted to microseconds',
    'scope': 'since latest physical run start; most recent 128 calls per stage',
    'generation': generation,
    'capacityPerStage': capacity,
    'maxStages': maxStages,
    'isFlutterFrameTiming': false,
    'stagesOverlap': true,
    'stages': {
      for (final entry in _stages.entries) entry.key: entry.value.snapshot(),
    },
  };
}

class _StageSamples {
  final List<int> _samples = List.filled(HostStageTimings.capacity, 0);
  int count = 0, totalUs = 0, maxUs = 0;
  void add(int value) {
    _samples[count % _samples.length] = value;
    count++;
    totalUs += value;
    if (value > maxUs) maxUs = value;
  }

  Map<String, Object?> snapshot() {
    final length = count < _samples.length ? count : _samples.length;
    final values = _samples.take(length).toList()..sort();
    return {
      'count': count,
      'totalUs': totalUs,
      'maxUs': maxUs,
      'recentCount': length,
      'recentMeanUs': values.isEmpty
          ? 0
          : values.reduce((a, b) => a + b) / length,
      'recentP95Us': values.isEmpty ? 0 : values[(length * .95).ceil() - 1],
      'recentMaxUs': values.isEmpty ? 0 : values.last,
    };
  }
}
