// Bounded, scalar-only observers for the dedicated ownership diagnostic.
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

Map<String, Object?> createProbeOnlyCycleEvidence(int cycle) => {
  'cycle': cycle,
  'mode': cycle.isOdd ? 'optimized' : 'standard',
  'scenario': 'no-world-no-edit',
  'status': 'running',
  'productOperations': 0,
};

void completeProbeOnlyCycleEvidence(Map<String, Object?> evidence) {
  evidence['status'] = 'completed';
}

int completedOwnershipCycles(Iterable<Map<String, Object?>> cycles) =>
    cycles.where((row) => row['status'] == 'completed').length;

Map<String, Object?> validateOwnershipReady(
  Object? value, {
  required String arm,
  required int hostPid,
  required String sourceCommit,
  required String baseProductCommit,
  required int readyReceivedUs,
}) {
  if (value is! Map ||
      value.length != 6 ||
      value['schema'] != 'abc.memory-ownership-ready.v1' ||
      value['arm'] != arm ||
      value['hostPid'] is! int ||
      value['hostPid'] != hostPid ||
      value['sourceCommit'] != sourceCommit ||
      value['baseProductCommit'] != baseProductCommit ||
      !RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceCommit) ||
      value['buildSha256'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['buildSha256'] as String)) {
    throw StateError('Ownership startup identity does not match');
  }
  return {
    'schema': value['schema'],
    'arm': arm,
    'hostPid': hostPid,
    'sourceCommit': sourceCommit,
    'baseProductCommit': baseProductCommit,
    'buildSha256': value['buildSha256'],
    'readyReceivedUs': readyReceivedUs,
  };
}

Future<Map<String, Object?>> waitForOwnershipReady(
  File file, {
  required String arm,
  required int hostPid,
  required String sourceCommit,
  required String baseProductCommit,
}) async {
  final deadline = Timeline.now + 60000000;
  while (Timeline.now < deadline) {
    if (file.existsSync()) {
      if (file.lengthSync() > 4096) {
        throw StateError('Ownership startup identity exceeds fixed size');
      }
      final value = jsonDecode(file.readAsStringSync());
      final received = Timeline.now;
      if (received >= deadline) {
        throw StateError(
          'Ownership startup identity timed out after 60 seconds',
        );
      }
      return validateOwnershipReady(
        value,
        arm: arm,
        hostPid: hostPid,
        sourceCommit: sourceCommit,
        baseProductCommit: baseProductCommit,
        readyReceivedUs: received,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('Ownership startup identity timed out after 60 seconds');
}

String? ownershipGaugeFailure(
  Map<String, Object?> row, {
  required bool probeOnly,
}) {
  final images = row['images'], fd = row['fd'], worker = row['worker'];
  if (images is! Map ||
      fd is! Map ||
      images['callbacksIntact'] != true ||
      images['everReplaced'] != false ||
      images['priorCallbackFailures'] != 0 ||
      fd['status'] != 'observed') {
    return 'Ownership observer incomplete; no further sampling';
  }
  if (worker is! Map) return 'Required worker observation unavailable';
  if (probeOnly || row['cycle'] == -1) {
    return worker['status'] == 'worker-not-started'
        ? null
        : 'Idle baseline unexpectedly initialized worker';
  }
  if (worker['status'] != 'acknowledged') {
    return 'Required product worker acknowledgement unavailable';
  }
  final owner = worker['owner'];
  final native = owner is Map ? owner['native'] : null;
  if (native is! Map || native['status'] != 'available') {
    return 'Required native owner symbols unavailable';
  }
  return null;
}

// Receipts measure encoding, UTF8, write and flush. They never mutate or retain
// a gauge row and are appended only after that row's write attempt finishes.
class OwnershipGaugeWriter {
  OwnershipGaugeWriter({
    required void Function(List<int>) write,
    required void Function() flush,
  }) : this._(write, flush);

  OwnershipGaugeWriter._(this._write, this._flush);

  final void Function(List<int>) _write;
  final void Function() _flush;
  final receipts = <Map<String, Object?>>[];

  void write(Map<String, Object?> row) {
    if (receipts.length >= 52) {
      throw StateError('Ownership gauge write budget exceeded');
    }
    final started = Timeline.now;
    int? bytes;
    var status = 'failed';
    try {
      final encoded = utf8.encode('${jsonEncode(row)}\n');
      _write(encoded);
      _flush();
      bytes = encoded.length;
      status = 'written';
    } finally {
      final ended = Timeline.now;
      receipts.add({
        'id': row['id'],
        'sequence': row['sequence'],
        'startUs': started,
        'endUs': ended,
        'bytes': bytes,
        'status': status,
      });
    }
  }
}

class ImageOwnershipObserver {
  ui.ImageEventCallback? _previousCreate, _previousDispose;
  late final ui.ImageEventCallback _create, _dispose;
  int created = 0, disposed = 0, peakBalance = 0, priorFailures = 0;
  int? installedUs, stoppedUs;
  bool _active = false, _everReplaced = false;

  void install() {
    if (_active || installedUs != null) {
      throw StateError('Image ownership observer can only be installed once');
    }
    _previousCreate = ui.Image.onCreate;
    _previousDispose = ui.Image.onDispose;
    _create = (image) {
      created++;
      final balance = created - disposed;
      if (balance > peakBalance) peakBalance = balance;
      try {
        _previousCreate?.call(image);
      } catch (_) {
        priorFailures++;
        rethrow;
      }
    };
    _dispose = (image) {
      disposed++;
      try {
        _previousDispose?.call(image);
      } catch (_) {
        priorFailures++;
        rethrow;
      }
    };
    installedUs = Timeline.now;
    ui.Image.onCreate = _create;
    ui.Image.onDispose = _dispose;
    _active = true;
  }

  Map<String, Object?> snapshot() {
    if (installedUs == null) throw StateError('Image observer not installed');
    final intact =
        _active &&
        identical(ui.Image.onCreate, _create) &&
        identical(ui.Image.onDispose, _dispose);
    if (_active && !intact) _everReplaced = true;
    return {
      'installedUs': installedUs,
      'stoppedUs': stoppedUs,
      'createdHandles': created,
      'disposedHandles': disposed,
      'observedHandleBalance': created - disposed,
      'peakObservedHandleBalance': peakBalance,
      'active': _active,
      'callbacksIntact': intact,
      'everReplaced': _everReplaced,
      'priorCallbackFailures': priorFailures,
      'preInstallationHandlesUnknown': true,
    };
  }

  Map<String, Object?> close() {
    final before = snapshot();
    if (_active) {
      if (identical(ui.Image.onCreate, _create)) {
        ui.Image.onCreate = _previousCreate;
      } else {
        _everReplaced = true;
      }
      if (identical(ui.Image.onDispose, _dispose)) {
        ui.Image.onDispose = _previousDispose;
      } else {
        _everReplaced = true;
      }
      _active = false;
      stoppedUs = Timeline.now;
    }
    return {
      ...before,
      'stoppedUs': stoppedUs,
      'active': false,
      'restorationComplete': !_everReplaced,
      'everReplaced': _everReplaced,
    };
  }
}

Map<String, Object?> imageCacheSnapshot() {
  final cache = PaintingBinding.instance.imageCache;
  return {
    'currentSize': cache.currentSize,
    'currentSizeBytes': cache.currentSizeBytes,
    'liveImageCount': cache.liveImageCount,
    'pendingImageCount': cache.pendingImageCount,
  };
}

Map<String, Object?> wrapperResultSnapshot(WorldCircuitResult? result) => {
  'present': result != null,
  'recordsLength': result?.records.length ?? 0,
  'worldLength': result?.world?.length ?? 0,
  'objectsLength': result?.objects?.length ?? 0,
  'statsLength': result?.stats.length ?? 0,
  'worldSourcePresent': result?.worldSource != null,
  'sourceTokenPresent': result?.worldSource?.token != null,
};

const ownFdCategoryNames = <String>[
  'socket',
  'pipe',
  'anonymous-inode',
  'path-like',
  'other',
];

String classifyOwnFdTarget(String target) {
  if (target.startsWith('socket:[')) return 'socket';
  if (target.startsWith('pipe:[')) return 'pipe';
  if (target.startsWith('anon_inode:')) return 'anonymous-inode';
  if (target.startsWith('/')) return 'path-like';
  return 'other';
}

class OwnFdObserver {
  OwnFdObserver({
    List<String> Function()? listNumericCandidates,
    String Function(String)? resolveTarget,
    bool Function()? supported,
  }) : _list = listNumericCandidates ?? _listOwn,
       _resolve = resolveTarget ?? _resolveOwn,
       _supported = supported ?? (() => Platform.isLinux);

  final List<String> Function() _list;
  final String Function(String) _resolve;
  final bool Function() _supported;
  bool _stopped = false;
  static const maximumEntries = 4096;
  static final _numericName = RegExp(r'^[0-9]+$');

  static List<String> _listOwn() =>
      Directory('/proc/$pid/fd')
          .listSync(followLinks: false)
          .map((entry) => entry.uri.pathSegments.last)
          .toList(growable: false);
  static String _resolveOwn(String name) =>
      Link('/proc/$pid/fd/$name').targetSync();

  Map<String, Object?> sample() {
    final started = Timeline.now;
    final common = <String, Object?>{
      'startUs': started,
      'hostPid': pid,
      'atomic': false,
      'probeDescriptorMayBeIncluded': true,
      'maximumEntries': maximumEntries,
      'fdEntriesEnumerated': null,
      'categories': null,
      'vanished': null,
      'unreadable': null,
      'ignoredNonnumeric': null,
      'enumerationEndUs': null,
      'classificationStartUs': null,
    };
    if (_stopped || !_supported()) {
      return {
        ...common,
        'status': _stopped ? 'stopped-after-incomplete' : 'unsupported',
        'errorKind': _stopped ? 'prior-incomplete' : 'platform',
        'errorCode': null,
        'endUs': Timeline.now,
      };
    }
    late final List<String> names;
    try {
      names = _list();
    } on FileSystemException catch (error) {
      _stopped = true;
      return {
        ...common,
        'status': 'incomplete',
        'errorKind': 'enumeration-failed',
        'errorCode': error.osError?.errorCode,
        'endUs': Timeline.now,
      };
    }
    common['enumerationEndUs'] = Timeline.now;
    var numeric = 0, ignored = 0;
    for (final name in names) {
      if (_numericName.hasMatch(name)) {
        numeric++;
      } else {
        ignored++;
      }
    }
    common['fdEntriesEnumerated'] = numeric;
    common['ignoredNonnumeric'] = ignored;
    if (numeric > maximumEntries || names.length > maximumEntries) {
      _stopped = true;
      return {
        ...common,
        'status': 'incomplete',
        'errorKind': 'enumeration-ceiling-exceeded',
        'errorCode': null,
        'endUs': Timeline.now,
      };
    }
    final categories = {for (final name in ownFdCategoryNames) name: 0};
    var vanished = 0, unreadable = 0;
    int? firstErrorCode;
    common['classificationStartUs'] = Timeline.now;
    for (final name in names) {
      if (!_numericName.hasMatch(name)) continue;
      try {
        final category = classifyOwnFdTarget(_resolve(name));
        categories[category] = categories[category]! + 1;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (code == 2) {
          vanished++;
        } else {
          unreadable++;
          firstErrorCode ??= code;
        }
      }
    }
    // Raw link targets and numeric descriptor names never leave this function.
    if (unreadable != 0) _stopped = true;
    return {
      ...common,
      'status': unreadable == 0 ? 'observed' : 'incomplete',
      'errorKind': unreadable == 0 ? null : 'classification-failed',
      'errorCode': firstErrorCode,
      'categories': categories,
      'vanished': vanished,
      'unreadable': unreadable,
      'endUs': Timeline.now,
    };
  }
}
