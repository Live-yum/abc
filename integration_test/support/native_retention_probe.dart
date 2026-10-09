// Test-only glibc observer. Loading and one reusable 128-byte buffer happen
// before baseline. No VM-service call, forced collection or allocator tuning.
import 'dart:developer' show Timeline;
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

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

class NativeRetentionProbe {
  NativeRetentionProbe._(
    this._library,
    this._snapshot,
    this._buffer,
    this._journal,
  );

  // Keep the handle alive for the whole observation. No mid-run dlclose.
  final DynamicLibrary _library;
  final _SnapshotDart _snapshot;
  final Pointer<Uint64> _buffer;
  final RandomAccessFile? _journal;
  var _journalClosed = false;
  final _observations = <Map<String, Object?>>[];
  var _closed = false;
  var _sequence = 0;

  // Fixed maximum: retain every completed call even if its later OS ack fails.
  List<Map<String, Object?>> get observations =>
      List<Map<String, Object?>>.unmodifiable(_observations);

  static NativeRetentionProbe open(String path, {File? journal}) {
    if (!Platform.isLinux || !path.startsWith('/')) {
      throw StateError('Absolute CI helper path on Linux required');
    }
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('CI helper must be an ordinary existing file');
    }
    final library = DynamicLibrary.open(path);
    final initialize = library
        .lookupFunction<_InitializeNative, _InitializeDart>(
          'abc_retention_initialize_v1',
        );
    final snapshot = library.lookupFunction<_SnapshotNative, _SnapshotDart>(
      'abc_retention_snapshot_v1',
    );
    initialize();
    RandomAccessFile? output;
    if (journal != null) {
      if (!journal.isAbsolute ||
          FileSystemEntity.typeSync(journal.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw StateError('A new absolute allocator journal path is required');
      }
      output = journal.openSync(mode: FileMode.writeOnly);
    }
    try {
      final buffer = calloc<Uint64>(16);
      return NativeRetentionProbe._(library, snapshot, buffer, output);
    } catch (_) {
      output?.closeSync();
      rethrow;
    }
  }

  Map<String, Object?> sample() {
    if (_closed) throw StateError('Allocator observer is closed');
    if (_sequence >= 37) throw StateError('Allocator call budget exceeded');
    // Every first-use sample is preserved by the caller as initialization.
    final start = Timeline.now;
    final status = _snapshot(_buffer, 16);
    final end = Timeline.now;
    if (status < 0 || _buffer[0] != 1 || _buffer[1] != status) {
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
    final fields = <String, Object?>{};
    for (var i = 0; i < retentionMallinfoFields.length; i++) {
      fields[retentionMallinfoFields[i]] = status == 0 ? _buffer[6 + i] : null;
    }
    final result = <String, Object?>{
      'schema': 'abc.native-retention-mallinfo2.v1',
      'sequence': _sequence++,
      'status': status == 0 ? 'available' : 'unsupported',
      'reason': reason,
      'startUs': start,
      'endUs': end,
      'clockDomain': 'dart:developer.Timeline.now',
      'atomic': false,
      'sizeTBytes': _buffer[2],
      'mallinfo2StructBytes': _buffer[3] == 0 ? null : _buffer[3],
      'glibcVersion': _buffer[4] == 0 ? null : '${_buffer[4]}.${_buffer[5]}',
      'fields': fields,
    };
    _observations.add(result);
    // Preserve completed calls before a later OS request/ack can fail. This
    // serialization/write is observation work outside the recorded C call.
    _journal?.writeStringSync('${jsonEncode(result)}\n');
    _journal?.flushSync();
    return result;
  }

  void closeJournal() {
    if (_journalClosed) return;
    _journalClosed = true;
    _journal?.closeSync();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      closeJournal();
    } finally {
      calloc.free(_buffer);
    }
    // DynamicLibrary has no close API. Retaining the handle until process exit
    // also prevents measuring unload work in the final quiet window.
    assert(_library.providesSymbol('abc_retention_snapshot_v1'));
  }
}
