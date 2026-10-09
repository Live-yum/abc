import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:terraforge/engine/map_backend.dart';

import 'map_metadata.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    throw ArgumentError('INPUT_MAP OUTPUT_JSON [ITERATIONS]');
  }
  final source = await File(args[0]).readAsBytes(),
      original = sha256.convert(await File(args[0]).readAsBytes()).toString();
  final iterations = args.length > 2 ? int.parse(args[2]) : 10;
  final backend = createMapBackend(),
      samples = <String, List<double>>{},
      memory = <Map<String, Object?>>[];
  final timerGaps = <double>[];
  final clock = Stopwatch()..start();
  var last = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final now = clock.elapsedMicroseconds;
    timerGaps.add((now - last) / 1000);
    last = now;
  });
  Future<T> measure<T>(String id, Future<T> Function() operation) async {
    final watch = Stopwatch()..start(), result = await operation();
    watch.stop();
    (samples[id] ??= []).add(watch.elapsedMicroseconds / 1000);
    return result;
  }

  try {
    for (var cycle = 0; cycle < iterations; cycle++) {
      memory.add({
        'cycle': cycle,
        'phase': 'baseline',
        'rssBytes': ProcessInfo.currentRss,
        'heapUsedBytes': null,
        'heapCapacityBytes': null,
        'wasmCapacityBytes': null,
        'ownedHandles': 0,
      });
      final info = await measure(
        'map.isolate_open_decode',
        () => backend.open(source),
      );
      await measure('map.isolate_render', backend.render);
      await measure(
        'map.isolate_edit',
        () => backend.editRect(0, 0, 64, 64, light: 177, color: 12),
      );
      await measure('map.isolate_undo', backend.undo);
      await measure('map.isolate_redo', backend.redo);
      final edited = await measure(
        'map.isolate_export_verified',
        backend.exportVerified,
      );
      await measure('map.isolate_reopen', () => backend.open(edited));
      await measure('map.isolate_close', backend.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      memory.add({
        'cycle': cycle,
        'phase': 'after-close',
        'rssBytes': ProcessInfo.currentRss,
        'heapUsedBytes': null,
        'heapCapacityBytes': null,
        'wasmCapacityBytes': null,
        'ownedHandles': 0,
        'previousOwnedBytes': info.ownedBytes,
      });
    }
    if (sha256.convert(await File(args[0]).readAsBytes()).toString() !=
            original ||
        sha256.convert(source).toString() != original) {
      throw StateError('MAP source changed');
    }
    final operations = <Map<String, Object?>>[];
    for (final entry in samples.entries) {
      for (final phase in ['cold', 'warm']) {
        final values = phase == 'cold'
            ? entry.value.take(1).toList()
            : entry.value.skip(1).toList();
        if (values.isEmpty) continue;
        final sorted = [...values]..sort(), n = values.length;
        final median = n.isOdd
            ? sorted[n ~/ 2]
            : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
        operations.add({
          'id': entry.key,
          'fixture': 'local-map-1',
          'phase': phase,
          'iterations': n,
          'warmup': 0,
          'unit': 'ms',
          'samplesMs': values,
          'medianMs': median,
          'p95Ms': sorted[(n * .95).ceil() - 1],
          'maxMs': sorted.last,
          'throughputPerSecond': median == 0 ? null : 1000 / median,
          'bytesPerOperation': source.length,
        });
      }
    }
    final gaps = [...timerGaps]..sort();
    final report = {
      'schema': 'abc.performance.v1',
      'suite': 'native-map-owner',
      'runtime': Platform.operatingSystem,
      'buildMode': const String.fromEnvironment(
        'ABC_MAP_BUILD_MODE',
        defaultValue: 'jit',
      ),
      'tier': Platform.environment['ABC_PERF_TIER'] ?? 'local',
      'methodology': {
        'cold': 'First invocation; OS caches are not flushed.',
        'warmupCycles': 0,
        'measuredCycles': iterations - 1,
        'totalCycles': iterations,
      },
      'executionBoundary': 'actual-isolate',
      ...mapReportMetadata(),
      'fixtures': [
        {
          'id': 'local-map-1',
          'kind': 'map',
          'provenance':
              Platform.environment['ABC_MAP_PROVENANCE'] ??
              'engine-generated-from-authorized-world',
          'bytes': source.length,
          'sha256': original,
        },
      ],
      'operations': operations,
      'memory': memory,
      'status': 'passed',
      'sourcePreserved': true,
      'performanceBudgetsEvaluated': false,
      'mainIsolateTimer': {
        'count': gaps.length,
        'p95GapMs': gaps[(gaps.length * .95).ceil() - 1],
        'maxGapMs': gaps.last,
      },
      'gaps': [
        'Timer progress is not Flutter frame timing.',
        'RSS includes Dart VM and caller compressed input; no heap-used API measured.',
        'Close terminates the isolate; 50ms later RSS samples do not prove complete GC reclamation.',
        'Input bytes read before operations; no OS cache flush.',
      ],
    };
    await File(
      args[1],
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln(
      jsonEncode({
        'status': 'passed',
        'mainIsolateTimer': report['mainIsolateTimer'],
      }),
    );
  } finally {
    timer.cancel();
    await backend.dispose();
  }
}
