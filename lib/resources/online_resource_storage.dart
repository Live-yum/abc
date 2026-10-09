import 'dart:typed_data';

import 'online_resource_storage_native.dart'
    if (dart.library.js_interop) 'online_resource_storage_web.dart'
    as platform;

// Storage semantics adapted from the viewer's infrastructure/assets/platform-store.mjs.
// Only the storage protocol is reproduced here; no game resources are bundled.
const onlineResourceValueLimit = 256 * 1024 * 1024;
const onlineResourceStateLimit = 2 * 1024 * 1024;
const onlineResourceKinds = <String>{
  'objects',
  'images',
  'releases',
  'packs',
  'state',
};
final _digest = RegExp(r'^[a-f0-9]{64}$');
final _state = RegExp(
  r'^(?:(?:authority|root)-[a-f0-9]{64}-[01]|(?:staging|installed)-[a-f0-9]{64}-[a-f0-9]{64}|(?:active|backup)-[a-f0-9]{64})$',
);

class OnlineResourceEntry {
  const OnlineResourceEntry({
    required this.kind,
    required this.id,
    required this.bytes,
  });

  final String kind;
  final String id;
  final int bytes;
}

abstract interface class OnlineResourceStorage {
  Future<Uint8List?> read(String kind, String id);
  Future<void> write(String kind, String id, Uint8List bytes);
  Future<void> remove(String kind, String id);
  Future<List<OnlineResourceEntry>> list();

  /// Replaces active state and retains its predecessor in backup state.
  /// A failed commit must leave the previous active value intact.
  Future<void> commitActive(String namespace, Uint8List bytes);
}

OnlineResourceStorage createOnlineResourceStorage() =>
    platform.createOnlineResourceStorage();

void validateOnlineResourceKey(String kind, String id) {
  if (!onlineResourceKinds.contains(kind) ||
      (kind == 'state' ? _state : _digest).firstMatch(id)?.group(0) != id) {
    throw ArgumentError('Invalid online resource storage key');
  }
}

void validateOnlineResourceSize(String kind, int size) {
  final limit = kind == 'state'
      ? onlineResourceStateLimit
      : onlineResourceValueLimit;
  if (size < 0 || size > limit) {
    throw ArgumentError('Online resource exceeds the storage size limit');
  }
}

String onlineResourceFileName(String kind, String id) {
  validateOnlineResourceKey(kind, id);
  final suffix = switch (kind) {
    'images' => '.png',
    'releases' || 'state' => '.json',
    'packs' => '.abcpack',
    _ => '',
  };
  return '$kind/$id$suffix';
}

OnlineResourceEntry? onlineResourceEntry(String name, int bytes) {
  final parts = name.split('/');
  if (parts.length != 2) return null;
  final kind = parts[0];
  final suffix = switch (kind) {
    'images' => '.png',
    'releases' || 'state' => '.json',
    'packs' => '.abcpack',
    _ => '',
  };
  if (!parts[1].endsWith(suffix)) return null;
  final id = parts[1].substring(0, parts[1].length - suffix.length);
  try {
    if (onlineResourceFileName(kind, id) != name) return null;
  } on ArgumentError {
    return null;
  }
  validateOnlineResourceSize(kind, bytes);
  return OnlineResourceEntry(kind: kind, id: id, bytes: bytes);
}

/// Volatile implementation for synthetic fixtures and tests only.
class MemoryOnlineResourceStorage implements OnlineResourceStorage {
  final Map<String, Uint8List> _files = {};

  @override
  Future<Uint8List?> read(String kind, String id) async {
    final value = _files[onlineResourceFileName(kind, id)];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String kind, String id, Uint8List bytes) async {
    final key = onlineResourceFileName(kind, id);
    validateOnlineResourceSize(kind, bytes.length);
    _files[key] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> remove(String kind, String id) async {
    _files.remove(onlineResourceFileName(kind, id));
  }

  @override
  Future<List<OnlineResourceEntry>> list() async => List.unmodifiable(
    _files.entries.map(
      (entry) => onlineResourceEntry(entry.key, entry.value.length)!,
    ),
  );

  @override
  Future<void> commitActive(String namespace, Uint8List bytes) async {
    final active = onlineResourceFileName('state', 'active-$namespace');
    final backup = onlineResourceFileName('state', 'backup-$namespace');
    validateOnlineResourceSize('state', bytes.length);
    final next = Uint8List.fromList(bytes);
    final previous = _files[active];
    if (previous != null) _files[backup] = Uint8List.fromList(previous);
    _files[active] = next;
  }
}
