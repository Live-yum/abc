// Test-only, bounded diagnostics. All received raw records are durable before
// their in-memory prefixes are released; late batches remain for the next file.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/scheduler.dart';

import 'profile_memory_native.dart' as memory;
import 'profile_os_memory_native.dart' show parseProcMemory;
import 'profile_recorder.dart';

Future<Map<String, Object?>> describeRawFile(File file) async => {
  'file': file.uri.pathSegments.last,
  'bytes': await file.length(),
  'sha256': (await sha256.bind(file.openRead()).first).toString(),
};

class ComputerMemoryJournal {
  ComputerMemoryJournal(this.directory, this.recorder);
  final Directory directory;
  final ProfileRecorder recorder;
  final chunks = <Map<String, Object?>>[];
  final boundaries = <Map<String, Object?>>[];
  final _receipts = <Map<String, Object?>>[];
  final _persistedRecords = <String, int>{
    'window': 0,
    'dispatch': 0,
    'viewportSnapshot': 0,
    'failureDiagnostic': 0,
  };
  Map<String, List<Map<String, Object?>>> get _collections => {
    'window': recorder.windows,
    'dispatch': recorder.dispatches,
    'viewportSnapshot': recorder.viewportSnapshots,
    'failureDiagnostic': recorder.failureDiagnostics,
  };
  int receivedFrames = 0, receivedBatches = 0, persistedFrames = 0;
  int? stoppedUs;

  void start() => SchedulerBinding.instance.addTimingsCallback(_receive);

  void _receive(List<FrameTiming> frames) {
    final at = Timeline.now, batch = receivedBatches++;
    for (final frame in frames) {
      recorder.frames.add(frame);
      _receipts.add({
        'sequence': receivedFrames++,
        'batch': batch,
        'receivedUs': at,
      });
    }
  }

  void stop() {
    SchedulerBinding.instance.removeTimingsCallback(_receive);
    stoppedUs = Timeline.now;
  }

  void boundary(String phase, int cycle) => boundaries.add({
    'phase': phase,
    'cycle': cycle,
    'timeUs': Timeline.now,
    'receivedFrames': receivedFrames,
    'receivedBatches': receivedBatches,
  });

  Map<String, Object?> retainedCounts() => {
    'frames': recorder.frames.length,
    'frameReceipts': _receipts.length,
    'windows': recorder.windows.length,
    'dispatches': recorder.dispatches.length,
    'viewportSnapshots': recorder.viewportSnapshots.length,
    'failureDiagnostics': recorder.failureDiagnostics.length,
    'receivedFrames': receivedFrames,
    'persistedFrames': persistedFrames,
    'receivedBatches': receivedBatches,
    'chunkDescriptors': chunks.length,
    'boundaryDescriptors': boundaries.length,
    'receivedRecords': {
      for (final entry in _collections.entries)
        entry.key: _persistedRecords[entry.key]! + entry.value.length,
    },
    'persistedRecords': Map<String, int>.of(_persistedRecords),
  };

  /// Counts are frozen before the first await. A callback while writing or
  /// hashing only appends; removeRange releases precisely the verified prefix.
  Future<void> flush(String reason) async {
    final started = Timeline.now;
    final frameCount = recorder.frames.length;
    if (frameCount != _receipts.length) {
      throw StateError('Frame receipt accounting mismatch');
    }
    final collections = _collections;
    final counts = {for (final e in collections.entries) e.key: e.value.length};
    final file = File('${directory.path}/frames-${chunks.length}.jsonl');
    if (file.existsSync()) throw StateError('Raw chunk already exists');
    final output = file.openSync(mode: FileMode.write);
    final digestSink = _DigestSink();
    final hashing = sha256.startChunkedConversion(digestSink);
    var writeBytes = 0;
    void write(Map<String, Object?> row) {
      final bytes = utf8.encode('${jsonEncode(row)}\n');
      output.writeFromSync(bytes);
      hashing.add(bytes);
      writeBytes += bytes.length;
    }

    try {
      write({
        'type': 'chunk',
        'schema': 'abc.memory-raw.v1',
        'hostPid': pid,
        'reason': reason,
        'startedUs': started,
        'firstSequence': persistedFrames,
        'frameCount': frameCount,
        'recordCounts': counts,
      });
      for (var i = 0; i < frameCount; i++) {
        final frame = recorder.frames[i];
        write({
          'type': 'frame',
          ..._receipts[i],
          'frameNumber': frame.frameNumber,
          'timestampsUs': {
            for (final phase in FramePhase.values)
              phase.name: frame.timestampInMicroseconds(phase),
          },
          'layerCacheCount': frame.layerCacheCount,
          'layerCacheBytes': frame.layerCacheBytes,
          'pictureCacheCount': frame.pictureCacheCount,
          'pictureCacheBytes': frame.pictureCacheBytes,
        });
      }
      for (final entry in collections.entries) {
        for (var i = 0; i < counts[entry.key]!; i++) {
          write({'type': entry.key, 'data': entry.value[i]});
        }
      }
      output.flushSync();
    } finally {
      output.closeSync();
      hashing.close();
    }
    final description = await describeRawFile(file);
    if (description['sha256'] != digestSink.value.toString() ||
        description['bytes'] != writeBytes) {
      throw StateError('Raw chunk reread hash mismatch; retaining memory');
    }
    chunks.add({
      ...description,
      'reason': reason,
      'firstSequence': persistedFrames,
      'frameCount': frameCount,
      'recordCounts': counts,
      'writeStartedUs': started,
      'verifiedUs': Timeline.now,
      'hashVerifiedBeforeRelease': true,
      'writeSha256': digestSink.value.toString(),
      'readSha256': description['sha256'],
      'writeBytes': writeBytes,
      'readBytes': description['bytes'],
    });
    recorder.frames.removeRange(0, frameCount);
    _receipts.removeRange(0, frameCount);
    for (final entry in collections.entries) {
      entry.value.removeRange(0, counts[entry.key]!);
      _persistedRecords[entry.key] =
          _persistedRecords[entry.key]! + counts[entry.key]!;
    }
    persistedFrames += frameCount;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// A persistent, same-process sampler writes every successful tick directly to
/// disk, without accumulating a second unbounded Dart list. It measures its own
/// overhead too. No other process is inspected.
class ComputerMemoryOsJournal {
  ComputerMemoryOsJournal._(this._isolate, this._commands);
  final Isolate _isolate;
  final SendPort _commands;

  static Future<ComputerMemoryOsJournal> start(Directory root) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_sampleOs, [
      pid,
      root.path,
      ready.sendPort,
    ]);
    try {
      return ComputerMemoryOsJournal._(
        isolate,
        await ready.first.timeout(const Duration(seconds: 10)) as SendPort,
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<Map<String, Object?>> request(String command, String phase) async {
    final reply = ReceivePort();
    try {
      _commands.send([command, phase, reply.sendPort]);
      final result = Map<String, Object?>.from(
        await reply.first.timeout(const Duration(seconds: 15)) as Map,
      );
      if (command != 'finish') {
        if (result['error'] case final String error) throw StateError(error);
      }
      return result;
    } finally {
      reply.close();
    }
  }

  Future<Map<String, Object?>> finish() async {
    try {
      return await request('finish', 'recording-stopped');
    } finally {
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

void _sampleOs(List<Object> arguments) {
  final hostPid = arguments[0] as int;
  final root = arguments[1] as String;
  final commands = ReceivePort();
  (arguments[2] as SendPort).send(commands.sendPort);
  final files = <Map<String, Object?>>[];
  RandomAccessFile? output;
  File? file;
  var sequence = 0, fileRows = 0;
  int? lastSmapsUs;
  String? failure;

  void openFile() {
    file = File('$root/os-${files.length}.jsonl');
    if (file!.existsSync()) throw StateError('OS raw chunk already exists');
    output = file!.openSync(mode: FileMode.write);
    fileRows = 0;
  }

  void closeFile() {
    output?.flushSync();
    output?.closeSync();
    output = null;
    if (file != null) {
      files.add({'file': file!.uri.pathSegments.last, 'sampleCount': fileRows});
      file = null;
    }
  }

  Map<String, Object?> sample(String phase, {bool boundary = false}) {
    if (failure != null) throw StateError(failure!);
    if (pid != hostPid) throw StateError('Sampler process mismatch');
    final started = Timeline.now;
    final status = parseProcMemory(
      File('/proc/$hostPid/status').readAsStringSync(),
      ['VmRSS', 'VmHWM'],
    );
    final row = <String, Object?>{
      'type': 'os',
      'sequence': sequence++,
      'phase': phase,
      'timeUs': started,
      'statusEndUs': Timeline.now,
      'rssBytes': status['VmRSS'],
      'processVmHwmBytes': status['VmHWM'],
      'smapsTimeUs': null,
      'smapsEndUs': null,
      'smapsRssBytes': null,
      'pssBytes': null,
      'ussBytes': null,
    };
    if (boundary || lastSmapsUs == null || started - lastSmapsUs! >= 100000) {
      final at = Timeline.now;
      final smaps = parseProcMemory(
        File('/proc/$hostPid/smaps_rollup').readAsStringSync(),
        ['Rss', 'Pss', 'Private_Clean', 'Private_Dirty', 'Private_Hugetlb'],
      );
      lastSmapsUs = at;
      row.addAll({
        'smapsTimeUs': at,
        'smapsEndUs': Timeline.now,
        'smapsRssBytes': smaps['Rss'],
        'pssBytes': smaps['Pss'],
        'ussBytes':
            smaps['Private_Clean']! +
            smaps['Private_Dirty']! +
            smaps['Private_Hugetlb']!,
      });
    }
    if (output == null) openFile();
    output!.writeStringSync('${jsonEncode(row)}\n');
    fileRows++;
    return row;
  }

  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    if (failure != null) return;
    try {
      sample('periodic');
    } catch (error) {
      failure = error.toString();
    }
  });
  commands.listen((dynamic message) {
    final command = message[0] as String, phase = message[1] as String;
    final reply = message[2] as SendPort;
    try {
      switch (command) {
        case 'point':
          reply.send(sample(phase, boundary: true));
        case 'rotate':
          sample(phase, boundary: true);
          closeFile();
          reply.send(<String, Object?>{});
        case 'finish':
          timer.cancel();
          if (failure == null) sample(phase, boundary: true);
          closeFile();
          reply.send({
            'hostPid': hostPid,
            'sampleCount': sequence,
            'files': files,
            'error': failure,
          });
          commands.close();
        default:
          throw StateError('Unknown OS journal command');
      }
    } catch (error) {
      failure = error.toString();
      reply.send({'error': failure});
    }
  });
}

Future<Map<String, Object?>> computerMemoryPoint({
  required String phase,
  required int cycle,
  required ComputerMemoryJournal journal,
  required ComputerMemoryOsJournal os,
  required bool wrapperLatestRetained,
}) async {
  final started = Timeline.now;
  final before = await os.request('point', '$phase.before-gc');
  final vmStarted = Timeline.now;
  final vm = await memory.memorySnapshot();
  final vmEnded = Timeline.now;
  final after = await os.request('point', '$phase.after-gc');
  return {
    'phase': phase,
    'cycle': cycle,
    'startUs': started,
    'endUs': Timeline.now,
    'vmStartUs': vmStarted,
    'vmEndUs': vmEnded,
    'osBefore': before,
    'osAfter': after,
    'vm': vm,
    'recorder': journal.retainedCounts(),
    'wrapperLatestRetained': wrapperLatestRetained,
    'nativeCounters': {
      'status': 'not-exposed-by-counter-disabled-native-library',
      'values': null,
    },
    'atomic': false,
  };
}
