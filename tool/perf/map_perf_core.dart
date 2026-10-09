import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:terraforge/domain/terraria_map.dart';

class MapPerfFixture {
  final String id, provenance;
  final Uint8List bytes;
  const MapPerfFixture(this.id, this.provenance, this.bytes);
}

Map<String, Object?> benchmarkMaps(
  List<MapPerfFixture> fixtures, {
  int iterations = 10,
  required String runtime,
  required String buildMode,
  String tier = 'local',
  Map<String, Object?> Function()? memorySnapshot,
}) {
  if (iterations < 2 || iterations > 100) {
    throw ArgumentError('iterations must be 2–100');
  }
  final operations = <Map<String, Object?>>[],
      memory = <Map<String, Object?>>[];
  for (final fixture in fixtures) {
    final samples = <String, List<double>>{};
    T measure<T>(String id, T Function() fn) {
      final watch = Stopwatch()..start();
      final result = fn();
      watch.stop();
      (samples[id] ??= []).add(watch.elapsedMicroseconds / 1000);
      return result;
    }

    for (var cycle = 0; cycle < iterations; cycle++) {
      memory.add({
        'fixture': fixture.id,
        'cycle': cycle,
        'phase': 'baseline',
        'rssBytes': null,
        'heapUsedBytes': null,
        'heapCapacityBytes': null,
        'wasmCapacityBytes': null,
        ...?memorySnapshot?.call(),
        'ownedHandles': 0,
        'ownedBytes': 0,
      });
      TerrariaMapSession? map, reopened;
      try {
        map = measure(
          'map.open_decode',
          () => TerrariaMapSession.decode(fixture.bytes),
        );
        final current = map!;
        final w = current.width < 64 ? current.width : 64,
            h = current.height < 64 ? current.height : 64;
        measure('map.decode_region', () => current.readRegion(0, 0, w, h));
        measure(
          'map.render_exploration',
          () => current.renderExplorationRgba(maxWidth: 960),
        );
        final unchanged = measure('map.export_unchanged', current.exportBytes);
        _equal(unchanged, fixture.bytes, 'Unchanged MAP differs');
        final cell = current.cellAt(0, 0),
            light = cell.light == 177 ? 178 : 177;
        measure(
          'map.edit_rect',
          () => current.editRect(0, 0, w, h, light: light, color: 12),
        );
        measure('map.undo', current.undo);
        if (current.isModified) {
          throw StateError('MAP undo lost source identity');
        }
        measure('map.redo', current.redo);
        final edited = measure('map.export_changed', current.exportBytes);
        reopened = measure(
          'map.reopen',
          () => TerrariaMapSession.decode(edited),
        );
        final reread = reopened!;
        final after = reread.cellAt(0, 0);
        if (after.light != light ||
            after.color != 12 ||
            after.option != cell.option) {
          throw StateError('MAP edit/export/read-back mismatch');
        }
        // Full region validation checks every changed cell, outside timed work.
        _equal(
          current.readRegion(0, 0, w, h),
          reread.readRegion(0, 0, w, h),
          'MAP edited region mismatch',
        );
        final otherX = current.width - 1, otherY = current.height - 1;
        final expected = current.cellAt(otherX, otherY),
            actual = reread.cellAt(otherX, otherY);
        if (expected.option != actual.option ||
            expected.light != actual.light ||
            expected.color != actual.color) {
          throw StateError('MAP out-of-region content changed');
        }
        memory.add({
          'fixture': fixture.id,
          'cycle': cycle,
          'phase': 'loaded',
          'rssBytes': null,
          'heapUsedBytes': null,
          'heapCapacityBytes': null,
          'wasmCapacityBytes': null,
          ...?memorySnapshot?.call(),
          'ownedHandles': 2,
          'ownedBytes': current.ownedBytes + reread.ownedBytes,
        });
        measure('map.close', () {
          current.close();
          reread.close();
        });
        if (current.ownedBytes != 0 || reread.ownedBytes != 0) {
          throw StateError('MAP close retained owned buffers');
        }
      } finally {
        map?.close();
        reopened?.close();
      }
      memory.add({
        'fixture': fixture.id,
        'cycle': cycle,
        'phase': 'after-close',
        'rssBytes': null,
        'heapUsedBytes': null,
        'heapCapacityBytes': null,
        'wasmCapacityBytes': null,
        ...?memorySnapshot?.call(),
        'ownedHandles': 0,
        'ownedBytes': 0,
      });
    }
    for (final entry in samples.entries) {
      for (final phase in ['cold', 'warm']) {
        final values = phase == 'cold'
            ? entry.value.take(1).toList()
            : entry.value.skip(1).toList();
        final sorted = [...values]..sort(), n = values.length;
        final median = n.isOdd
            ? sorted[n ~/ 2]
            : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
        operations.add({
          'id': entry.key,
          'fixture': fixture.id,
          'phase': phase,
          'iterations': n,
          'warmup': 0,
          'unit': 'ms',
          'samplesMs': values,
          'medianMs': median,
          'p95Ms': sorted[(n * .95).ceil() - 1],
          'maxMs': sorted.last,
          'throughputPerSecond': median == 0 ? null : 1000 / median,
          'bytesPerOperation': fixture.bytes.length,
        });
      }
    }
  }
  return {
    'schema': 'abc.performance.v1',
    'suite': 'map-actions',
    'runtime': runtime,
    'buildMode': buildMode,
    'tier': tier,
    'methodology': {
      'cold': 'First invocation per fixture; OS caches are not flushed.',
      'warmupCycles': 0,
      'measuredCycles': iterations - 1,
      'totalCycles': iterations,
    },
    'workload': 'binary-map',
    'fixtures': [
      for (final f in fixtures)
        {
          'id': f.id,
          'kind': 'map',
          'provenance': f.provenance,
          'bytes': f.bytes.length,
          'sha256': sha256.convert(f.bytes).toString(),
        },
    ],
    'operations': operations,
    'memory': memory,
    'status': 'passed',
    'performanceBudgetsEvaluated': false,
    'gaps': [
      'Cold is the first invocation for each fixture in this process; OS file cache is not flushed.',
      'MAP open_decode fully inflates and decodes all cells; region reads copy decoded data.',
      'Exploration raster measures binary MAP light rendering, not WLD PNG or game palette fidelity.',
      'Owned bytes excludes Dart object/allocator overhead; zero after close does not prove GC/RSS reclamation.',
      'No mobile/macOS device responsiveness, browser frame pacing or navigation latency measured here.',
    ],
  };
}

void _equal(List<int> a, List<int> b, String message) {
  if (a.length != b.length) throw StateError(message);
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) throw StateError(message);
  }
}
