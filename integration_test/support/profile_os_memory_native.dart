// Test-only Linux process observations. Never enumerates other processes.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';

Map<String, int> parseProcMemory(String text, Iterable<String> fields) {
  final result = <String, int>{};
  for (final field in fields) {
    final matches = RegExp(
      '^$field:[ \\t]+([0-9]+)[ \\t]+kB[ \\t]*\$',
      multiLine: true,
    ).allMatches(text).toList();
    if (matches.length != 1) {
      throw FormatException('Expected one $field in proc memory data');
    }
    result[field] = int.parse(matches.single.group(1)!) * 1024;
  }
  return result;
}

class _Intervals {
  int? previous, minimum, maximum;
  int count = 0, total = 0;
  final buckets = <String, int>{};
  void add(int time) {
    final before = previous;
    previous = time;
    if (before == null) return;
    final gap = time - before;
    if (gap < 0) throw StateError('Memory sample clock moved backwards');
    count++;
    total += gap;
    minimum = minimum == null || gap < minimum! ? gap : minimum;
    maximum = maximum == null || gap > maximum! ? gap : maximum;
    final upper = [
      10000,
      20000,
      50000,
      100000,
      250000,
      1000000,
    ].where((bound) => gap <= bound);
    final bucket = upper.isEmpty ? '>1000000' : '<=${upper.first}';
    buckets[bucket] = (buckets[bucket] ?? 0) + 1;
  }

  Map<String, Object?> report() => {
    'count': count,
    'min': minimum,
    'max': maximum,
    'mean': count == 0 ? null : total / count,
    'nonOverlappingBuckets': buckets,
  };
}

/// Retains boundary/maximum samples and interval distributions, not an
/// unbounded per-tick series whose allocations would distort later cycles.
class OsMemoryWindow {
  OsMemoryWindow(this.metadata);
  final Map<String, Object?> metadata;
  final _statusIntervals = _Intervals(), _smapsIntervals = _Intervals();
  final _maxima = <String, int>{}, _maximumTimes = <String, int>{};
  Map<String, Object?>? _baseline, _last;
  int statusSamples = 0, smapsSamples = 0, periodicStatusSamples = 0;
  bool _ended = false;

  void add(Map<String, Object?> sample, {bool periodic = false}) {
    if (_ended) throw StateError('Loading window is already closed');
    final time = sample['timeUs']! as int;
    _baseline ??= sample;
    _last = sample;
    statusSamples++;
    if (periodic) periodicStatusSamples++;
    _statusIntervals.add(time);
    if (sample['smapsRssBytes'] != null) {
      smapsSamples++;
      _smapsIntervals.add(sample['smapsTimeUs']! as int);
    }
    for (final key in ['rssBytes', 'smapsRssBytes', 'pssBytes', 'ussBytes']) {
      final value = sample[key] as int?;
      if (value != null &&
          (!_maxima.containsKey(key) || value > _maxima[key]!)) {
        _maxima[key] = value;
        _maximumTimes[key] = key == 'rssBytes'
            ? time
            : sample['smapsTimeUs']! as int;
      }
    }
  }

  Map<String, Object?> end(String outcome, Map<String, Object?> evidence) {
    if (_ended) throw StateError('Loading window is already closed');
    _ended = true;
    final baseline = _baseline, terminal = _last;
    return {
      ...metadata,
      'outcome': outcome,
      'baseline': baseline,
      'ready': outcome == 'ready' ? terminal : null,
      'terminal': terminal,
      'readyEvidence': evidence,
      'durationUs': baseline == null || terminal == null
          ? null
          : (terminal['timeUs']! as int) - (baseline['timeUs']! as int),
      'sampleMax': {
        for (final key in ['rssBytes', 'smapsRssBytes', 'pssBytes', 'ussBytes'])
          key: _maxima[key],
      },
      'sampleMaxAtUs': _maximumTimes,
      // VmHWM is lifetime-cumulative and is never a per-window maximum.
      'processVmHwmAtBaselineBytes': baseline?['processVmHwmBytes'],
      'processVmHwmAtEndBytes': terminal?['processVmHwmBytes'],
      'statusSampleCount': statusSamples,
      'periodicStatusSampleCount': periodicStatusSamples,
      'smapsSampleCount': smapsSamples,
      'statusIntervalUs': _statusIntervals.report(),
      'smapsIntervalUs': _smapsIntervals.report(),
    };
  }
}

class OsLoadingMemoryProbe {
  OsLoadingMemoryProbe._(this._isolate, this._commands);
  final Isolate _isolate;
  final SendPort _commands;
  Future<Map<String, Object?>>? _finished;

  static Future<OsLoadingMemoryProbe> start() async {
    if (!Platform.isLinux) throw UnsupportedError('Linux proc memory required');
    final ready = ReceivePort();
    try {
      final isolate = await Isolate.spawn(_observe, [pid, ready.sendPort]);
      try {
        return OsLoadingMemoryProbe._(
          isolate,
          await ready.first.timeout(const Duration(seconds: 5)) as SendPort,
        );
      } catch (_) {
        isolate.kill(priority: Isolate.immediate);
        rethrow;
      }
    } finally {
      ready.close();
    }
  }

  Future<Map<String, Object?>> _request(
    String command, [
    Map<String, Object?> data = const {},
  ]) async {
    final reply = ReceivePort();
    try {
      _commands.send([command, data, reply.sendPort]);
      final result = Map<String, Object?>.from(
        await reply.first.timeout(const Duration(seconds: 5)) as Map,
      );
      if (result['error'] case final String error) throw StateError(error);
      return result;
    } finally {
      reply.close();
    }
  }

  Future<void> begin(Map<String, Object?> metadata) async {
    await _request('begin', metadata);
  }

  Future<void> end(
    String outcome, [
    Map<String, Object?> evidence = const {},
  ]) async {
    await _request('end', {'outcome': outcome, 'evidence': evidence});
  }

  Future<void> closePoint(Map<String, Object?> metadata) async {
    await _request('close-point', metadata);
  }

  Future<Map<String, Object?>> finish() => _finished ??= () async {
    try {
      return await _request('finish');
    } catch (error) {
      // Preserve a failed test's standalone report even if the observation
      // isolate itself failed; missing evidence must never become a pass.
      return <String, Object?>{
        'schema': 'abc.profile-loading-os-memory.v1',
        'status': 'incomplete',
        'hostPid': pid,
        'errors': ['Unable to finish OS memory sampler: $error'],
        'windows': <Object>[],
        'closeSamples': <Object>[],
      };
    } finally {
      _isolate.kill(priority: Isolate.immediate);
    }
  }();
}

void _observe(List<Object> arguments) {
  final hostPid = arguments[0] as int;
  final commands = ReceivePort();
  (arguments[1] as SendPort).send(commands.sendPort);
  final windows = <Map<String, Object?>>[], closes = <Map<String, Object?>>[];
  final errors = <String>[];
  OsMemoryWindow? active;
  Timer? timer;
  int? startedUs, lastSmapsUs;
  String? statusUnavailable, smapsUnavailable;

  Map<String, Object?>? sample({bool forceSmaps = false}) {
    if (statusUnavailable != null) return null;
    try {
      if (pid != hostPid) throw StateError('Sampler changed host process');
      final time = Timeline.now;
      final status = parseProcMemory(
        File('/proc/$hostPid/status').readAsStringSync(),
        ['VmRSS', 'VmHWM'],
      );
      if (status.values.any((value) => value <= 0)) {
        throw StateError('Non-positive host process RSS/HWM');
      }
      final row = <String, Object?>{
        'timeUs': time,
        'rssBytes': status['VmRSS'],
        'processVmHwmBytes': status['VmHWM'],
        'smapsRssBytes': null,
        'pssBytes': null,
        'ussBytes': null,
        'smapsTimeUs': null,
      };
      if (smapsUnavailable == null &&
          (forceSmaps ||
              lastSmapsUs == null ||
              time - lastSmapsUs! >= 100000)) {
        try {
          final smapsTime = Timeline.now;
          final smaps = parseProcMemory(
            File('/proc/$hostPid/smaps_rollup').readAsStringSync(),
            ['Rss', 'Pss', 'Private_Clean', 'Private_Dirty', 'Private_Hugetlb'],
          );
          lastSmapsUs = smapsTime;
          row.addAll({
            'smapsTimeUs': smapsTime,
            'smapsRssBytes': smaps['Rss'],
            'pssBytes': smaps['Pss'],
            'ussBytes':
                smaps['Private_Clean']! +
                smaps['Private_Dirty']! +
                smaps['Private_Hugetlb']!,
          });
        } catch (error) {
          // Preserve unavailability, including denied access; do not retry it.
          smapsUnavailable = error.toString();
        }
      }
      row['smapsUnavailable'] = smapsUnavailable;
      return row;
    } catch (error) {
      statusUnavailable = error.toString();
      errors.add(statusUnavailable!);
      timer?.cancel();
      return null;
    }
  }

  void tick({bool boundary = false}) {
    final row = sample(forceSmaps: boundary);
    if (row != null) active?.add(row, periodic: !boundary);
  }

  commands.listen((dynamic message) {
    final command = message[0] as String;
    final data = Map<String, Object?>.from(message[1] as Map);
    final reply = message[2] as SendPort;
    try {
      switch (command) {
        case 'begin':
          if (active != null) throw StateError('Overlapping loading windows');
          active = OsMemoryWindow(data);
          startedUs = Timeline.now;
          lastSmapsUs = null;
          tick(boundary: true);
          timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
            if (Timeline.now - startedUs! > 12 * 60 * 1000000) {
              errors.add('Loading sampler exceeded twelve-minute window');
              timer?.cancel();
              return;
            }
            tick();
          });
        case 'end':
          if (active == null) throw StateError('No active loading window');
          timer?.cancel();
          tick(boundary: true);
          windows.add(
            active!.end(
              data['outcome']! as String,
              Map<String, Object?>.from(data['evidence']! as Map),
            ),
          );
          active = null;
        case 'close-point':
          if (active != null) throw StateError('Close overlaps loading window');
          closes.add({...data, 'sample': sample(forceSmaps: true)});
        case 'finish':
          timer?.cancel();
          if (active != null) {
            tick(boundary: true);
            windows.add(active!.end('aborted', const {}));
            errors.add('Loading window remained active at probe shutdown');
            active = null;
          }
          reply.send({
            'schema': 'abc.profile-loading-os-memory.v1',
            'status':
                errors.isEmpty &&
                    windows.isNotEmpty &&
                    windows.every(
                      (row) =>
                          (row['statusSampleCount']! as int) >= 2 &&
                          (row['outcome'] != 'ready' ||
                              (row['periodicStatusSampleCount']! as int) > 0),
                    )
                ? 'observed'
                : 'incomplete',
            'hostPid': hostPid,
            'scope':
                'single-flutter-application-process-including-sampler-isolate',
            'clock': 'dart-Timeline.now-monotonic-microseconds',
            'statusTargetIntervalUs': 10000,
            'smapsTargetIntervalUs': 100000,
            'samplingActiveOnlyDuringLoad': true,
            'pssUssAvailability':
                windows.any((row) => (row['smapsSampleCount']! as int) > 0)
                ? smapsUnavailable == null
                      ? 'available'
                      : 'partial'
                : 'unavailable',
            'smapsUnavailable': smapsUnavailable,
            'errors': errors,
            'windows': windows,
            'closeSamples': closes,
            'limits': [
              'RSS includes shared resident pages; it is not exclusive memory.',
              'The sampler isolate and its bounded bookkeeping are included in this host RSS.',
              'Sample maxima may miss sub-interval peaks; VmHWM is cumulative since process start, never reset per load.',
              'status and smaps are sequential reads and can disagree; each source is retained separately.',
              'Compiler, flutter drive, Xvfb and other processes are excluded.',
              'Fresh host process does not imply cold filesystem caches.',
            ],
          });
          commands.close();
          return;
        default:
          throw StateError('Unknown memory probe command');
      }
      reply.send(<String, Object?>{});
    } catch (error) {
      errors.add(error.toString());
      reply.send({'error': error.toString()});
    }
  });
}
