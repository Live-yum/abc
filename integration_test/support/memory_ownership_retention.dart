// Test-only libc observation. All 52 fixed wire slots are allocated before the
// first sample. Capture does not encode JSON, allocate a result map or write IO.
import 'dart:developer' show Timeline;
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _InitializeNative = Int32 Function();
typedef _InitializeDart = int Function();
typedef _SnapshotNative = Int32 Function(Pointer<Uint64>, Size);
typedef _SnapshotDart = int Function(Pointer<Uint64>, int);

const retentionMallinfoFields = <String>[
  'arena',
  'ordblks',
  'smblks',
  'hblks',
  'hblkhd',
  'usmblks',
  'fsmblks',
  'uordblks',
  'fordblks',
  'keepcost',
];

class OwnershipRetentionProbe {
  OwnershipRetentionProbe._(
    this._library,
    this._snapshot,
    this._buffer,
    this._initializationStartUs,
    this._initializationEndUs,
    this._initializationStatusCode,
  );
  static const callBudget = 52;
  final DynamicLibrary _library;
  final _SnapshotDart _snapshot;
  final Pointer<Uint64> _buffer;
  final int _initializationStartUs, _initializationEndUs;
  final int _initializationStatusCode;
  final _starts = Int64List(callBudget), _ends = Int64List(callBudget);
  final _statuses = Int32List(callBudget);
  int _count = 0;
  bool _closed = false;
  int get captureCount => _count;
  int captureStartUs(int index) => _starts[index];

  Map<String, Object?> get initialization => {
    'startUs': _initializationStartUs,
    'endUs': _initializationEndUs,
    'statusCode': _initializationStatusCode,
    'status': _initializationStatusCode == 0
        ? 'available'
        : (_initializationStatusCode >= 1 && _initializationStatusCode <= 4
              ? 'unsupported'
              : 'failed'),
    'reason': switch (_initializationStatusCode) {
      0 => null,
      1 => 'unsupported-build-headers',
      2 => 'runtime-mallinfo2-unavailable',
      3 => 'allocator-symbols-interposed',
      4 => 'libc-symbol-identity-unverified',
      _ => 'unknown-initialization-status',
    },
    'clockDomain': 'dart:developer.Timeline.now',
  };

  Map<String, Object?> rawCapture(int index) {
    if (_closed || index < 0 || index >= _count) {
      throw StateError('Unknown allocator observation');
    }
    return {
      'sequence': index,
      'startUs': _starts[index],
      'endUs': _ends[index],
      'statusCode': _statuses[index],
      'rawWords': (_buffer + index * 16)
          .asTypedList(16)
          .map((word) => BigInt.from(word).toUnsigned(64).toString())
          .toList(growable: false),
      'rawWordEncoding': 'unsigned-decimal-string',
    };
  }

  static OwnershipRetentionProbe open(String path) {
    if (!Platform.isLinux ||
        !path.startsWith('/') ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw StateError('Existing absolute Linux diagnostic helper required');
    }
    final library = DynamicLibrary.open(path);
    final initialize = library
        .lookupFunction<_InitializeNative, _InitializeDart>(
          'abc_retention_initialize_v1',
        );
    final snapshot = library.lookupFunction<_SnapshotNative, _SnapshotDart>(
      'abc_retention_snapshot_v1',
    );
    final initializationStart = Timeline.now;
    final initializationStatus = initialize();
    final initializationEnd = Timeline.now;
    return OwnershipRetentionProbe._(
      library,
      snapshot,
      calloc<Uint64>(callBudget * 16),
      initializationStart,
      initializationEnd,
      initializationStatus,
    );
  }

  int capture() {
    if (_closed || _count >= callBudget) {
      throw StateError('Allocator diagnostic call budget or lifetime exceeded');
    }
    final index = _count++;
    _starts[index] = Timeline.now;
    _statuses[index] = _snapshot(_buffer + index * 16, 16);
    _ends[index] = Timeline.now;
    return index;
  }

  Map<String, Object?> describe(int index) {
    if (_closed || index < 0 || index >= _count) {
      throw StateError('Unknown allocator observation');
    }
    final words = (_buffer + index * 16).asTypedList(16);
    final status = _statuses[index];
    if (status < 0 || words[0] != 1 || words[1] != status) {
      throw StateError('Allocator helper wire ABI mismatch');
    }
    final reason = switch (status) {
      0 => null,
      1 => 'unsupported-build-headers',
      2 => 'runtime-mallinfo2-unavailable',
      3 => 'allocator-symbols-interposed',
      4 => 'libc-symbol-identity-unverified',
      _ => throw StateError('Unknown allocator helper status'),
    };
    return {
      'schema': 'abc.native-retention-mallinfo2.v1',
      'sequence': index,
      'status': status == 0 ? 'available' : 'unsupported',
      'reason': reason,
      'startUs': _starts[index],
      'endUs': _ends[index],
      'clockDomain': 'dart:developer.Timeline.now',
      'atomic': false,
      'sizeTBytes': words[2],
      'mallinfo2StructBytes': words[3] == 0 ? null : words[3],
      'glibcVersion': words[4] == 0 ? null : '${words[4]}.${words[5]}',
      'fields': {
        for (var i = 0; i < retentionMallinfoFields.length; i++)
          retentionMallinfoFields[i]: status == 0 ? words[6 + i] : null,
      },
      'observerWireBufferBytes': callBudget * 128,
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    calloc.free(_buffer);
    // Retain the helper DSO until process exit; never perform a mid-run unload.
    assert(_library.providesSymbol('abc_retention_snapshot_v1'));
  }
}
