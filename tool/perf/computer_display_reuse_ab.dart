import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

import '../../test/support/computer_display_frames.dart';

const _count = 256, _trials = 6;
const _region = ComputerrariaComputer.mono;

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

bool _sameBytes(Uint8List first, Uint8List second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}

int _phase(String workload, int index) => switch (workload) {
  'stable' => 0,
  'half-changing' => 1 - (index ~/ 2 % 2),
  'all-changing' => 1 - (index % 2),
  'all-changing-late' => 1 - (index % 2),
  _ => throw ArgumentError(workload),
};

List<WorldCircuitResult> _sequence(String workload, int count) {
  // Input records are immutable during decoding. Share the few source patterns
  // so fixture preparation does not retain a separate 48 KiB input per poll.
  final sources = [
    for (var phase = 0; phase < 2; phase++)
      for (final reversed in [false, true])
        workload == 'all-changing-late'
            ? _lateChangeFrame(phase)
            : displayFrame(_region, phase: phase, reversed: reversed),
  ];
  return [
    for (var i = 0; i < count; i++)
      sources[_phase(workload, i) * 2 + (i.isOdd ? 1 : 0)],
  ];
}

WorldCircuitResult _lateChangeFrame(int phase) {
  final response = displayFrame(_region);
  // The sole changed pixel is the final record, after all preceding comparisons.
  ByteData.sublistView(response.records).setInt16(
    response.records.length - 4,
    phase == 1 ? 0 : 18,
    Endian.little,
  );
  return response;
}

Map<String, Object?> _run(
  List<WorldCircuitResult> responses, {
  required bool reuse,
  bool countAllocations = false,
}) {
  // Seed both implementations equally. The measured interval starts with a
  // valid published frame, so the three change proportions are exact.
  var previous = referenceDisplayDecode(_region, displayFrame(_region));
  var allocations = 0, bytes = 0, checksum = 0, published = 0;
  Uint8List allocate(int length) {
    allocations++;
    bytes += length;
    return Uint8List(length);
  }

  final watch = Stopwatch()..start();
  for (var i = 0; i < responses.length; i++) {
    final response = responses[i];
    final next = reuse
        ? _region.decode(
            response,
            previous: previous,
            previousRegion: _region,
            allocateRgba: countAllocations ? allocate : null,
          )
        : referenceDisplayDecode(
            _region,
            response,
            allocateRgba: countAllocations ? allocate : null,
          );
    final unchanged = reuse
        ? identical(previous, next)
        : _sameBytes(previous, next);
    if (!unchanged) {
      previous = next;
      published++;
    }
    checksum = (checksum + previous[(i * 97) % previous.length]) & 0x7fffffff;
  }
  watch.stop();
  return {
    if (!countAllocations) 'elapsedUs': watch.elapsedMicroseconds,
    if (countAllocations) 'rgbaAllocations': allocations,
    if (countAllocations) 'rgbaAllocatedBytes': bytes,
    'publishedChanges': published,
    'checksum': checksum,
  };
}

void main() {
  final reports = <Map<String, Object?>>[];
  for (final workload in const [
    'stable',
    'half-changing',
    'all-changing',
    'all-changing-late',
  ]) {
    final responses = _sequence(workload, _count);
    var previous = referenceDisplayDecode(_region, displayFrame(_region));
    final digests = <String>[];
    // Validation and hashing are outside the timed region, but every frame is
    // compared byte-for-byte before its digest enters the report.
    for (var index = 0; index < responses.length; index++) {
      final response = responses[index];
      final expected = referenceDisplayDecode(_region, response);
      final original = Uint8List.fromList(previous);
      final actual = _region.decode(
        response,
        previous: previous,
        previousRegion: _region,
      );
      _check(_sameBytes(actual, expected), '$workload frame $index differs');
      _check(_sameBytes(previous, original), '$workload changed old pixels');
      final digest = sha256.convert(actual).toString();
      _check(
        digest == sha256.convert(expected).toString(),
        '$workload frame $index pixel hash differs',
      );
      digests.add(digest);
      previous = actual;
    }
    final warm = responses.take(32).toList();
    _run(warm, reuse: false);
    _run(warm, reuse: true);
    final trials = <Map<String, Object?>>[];
    final expectedChanges = switch (workload) {
      'stable' => 0,
      'half-changing' => _count ~/ 2,
      _ => _count,
    };
    final baselineCounts = _run(responses, reuse: false, countAllocations: true);
    final candidateCounts = _run(responses, reuse: true, countAllocations: true);
    _check(baselineCounts['rgbaAllocations'] == _count, 'Baseline allocations');
    _check(
      candidateCounts['rgbaAllocations'] == expectedChanges,
      'Candidate allocation count for $workload',
    );
    final frameBytes = _region.width * _region.height * 4;
    _check(
      baselineCounts['rgbaAllocatedBytes'] == _count * frameBytes &&
          candidateCounts['rgbaAllocatedBytes'] == expectedChanges * frameBytes,
      'RGBA allocation byte count for $workload',
    );
    for (var trial = 0; trial < _trials; trial++) {
      late final Map<String, Object?> baseline, candidate;
      if (trial.isEven) {
        baseline = _run(responses, reuse: false);
        candidate = _run(responses, reuse: true);
      } else {
        candidate = _run(responses, reuse: true);
        baseline = _run(responses, reuse: false);
      }
      _check(
        baseline['publishedChanges'] == expectedChanges &&
            candidate['publishedChanges'] == expectedChanges,
        'Changed frame count for $workload',
      );
      _check(candidate['checksum'] == baseline['checksum'], 'Timed checksum');
      trials.add({
        'trial': trial,
        'order': trial.isEven ? 'baseline-candidate' : 'candidate-baseline',
        'baseline': baseline,
        'candidate': candidate,
      });
    }
    reports.add({
      'workload': workload,
      'changedFrames': expectedChanges,
      'frames': _count,
      'inputRecordsPerFrame': _region.width * _region.height,
      'rgbaBytesPerFrame': _region.width * _region.height * 4,
      'allocationCheck': {'baseline': baselineCounts, 'candidate': candidateCounts},
      'pixelSha256': digests,
      'trials': trials,
    });
  }
  stdout.writeln(jsonEncode({
    'schema': 1,
    'runtime': Platform.version,
    'os': Platform.operatingSystem,
    'fixture': 'synthetic 64x48 stripes, plus a one-pixel late-change case',
    'scope': 'decoder and frame comparison; no native, UI or RSS claim',
    'timingIncludesChangedFrameCopy': true,
    'allocationCountersOutsideTimingTrials': true,
    'allocationScope': 'RGBA buffers only; excludes unchanged seen buffers',
    'warmupFramesPerVariant': 32,
    'seedFrameOutsideTiming': true,
    'reports': reports,
  }));
}
