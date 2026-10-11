// Opt-in diagnostic overlay. Never loads an engine or changes resource owners.
import 'dart:ffi';
import 'dart:developer' show Timeline;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const memoryOwnershipDiagnosticsEnabled = bool.fromEnvironment(
  'ABC_MEMORY_OWNERSHIP',
);

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();
typedef _SnapshotNative = Int32 Function(Pointer<Uint64>, Size);
typedef _SnapshotDart = int Function(Pointer<Uint64>, int);

const nativeOwnerFields = <String>[
  'nativeTotalLiveBytes',
  'nativeLiveBytes',
  'nativeBridgeLiveBytes',
  'nativeAllocatorPeakBytes',
  'nativeWorldOpenCount',
  'nativeStreamTaskPresent',
  'nativeCheckpointActive',
  'nativeCircuitSessionCount',
  'nativeCircuitVmCount',
];

Map<String, Object?> parseNativeOwnerWords(Uint64List words) {
  if (words.length != 16 ||
      words[0] != 1 ||
      words[1] != 16 ||
      words[11] > 15 ||
      words.skip(12).any((value) => value != 0)) {
    throw StateError('Native owner diagnostic wire ABI mismatch');
  }
  final mask = words[11];
  for (var i = 0; i < 4; i++) {
    if (((mask >> i) & 1) != (words[i + 2] == 0xffffffff ? 1 : 0)) {
      throw StateError('Native owner censor metadata mismatch');
    }
  }
  return {
    'status': 'available',
    'abiVersion': 1,
    'wordCount': 16,
    'censoredMask': mask,
    'values': {
      for (var i = 0; i < nativeOwnerFields.length; i++)
        nativeOwnerFields[i]: words[i + 2],
    },
    'observerBufferBytes': 128,
    'rawWords': words.toList(growable: false),
  };
}

class NativeOwnerDiagnostics {
  NativeOwnerDiagnostics._(this._snapshot, this._buffer);
  final _SnapshotDart _snapshot;
  // One fixed diagnostic buffer retained with the intentionally persistent owner.
  final Pointer<Uint64> _buffer;

  static NativeOwnerDiagnostics? fromLoadedLibrary(DynamicLibrary library) {
    if (!memoryOwnershipDiagnosticsEnabled) return null;
    const names = [
      'abc_owner_diagnostics_abi_version',
      'abc_owner_diagnostics_snapshot_v1',
    ];
    if (!names.every(library.providesSymbol)) return null;
    final version = library.lookupFunction<_VersionNative, _VersionDart>(
      names[0],
    );
    if (version() != 1) {
      throw StateError('Native owner diagnostic ABI unsupported');
    }
    final snapshot = library.lookupFunction<_SnapshotNative, _SnapshotDart>(
      names[1],
    );
    return NativeOwnerDiagnostics._(snapshot, calloc<Uint64>(16));
  }

  Map<String, Object?> snapshot() {
    final started = Timeline.now;
    final status = _snapshot(_buffer, 16);
    final ended = Timeline.now;
    if (status != 0) {
      throw StateError('Native owner diagnostic snapshot failed');
    }
    return {
      ...parseNativeOwnerWords(_buffer.asTypedList(16)),
      'startUs': started,
      'endUs': ended,
    };
  }
}
