import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'online_resource_storage.dart';

OnlineResourceStorage createOnlineResourceStorage() =>
    NativeOnlineResourceStorage();

/// Application-private storage, with one queue and OS file lock per directory.
/// Data is flushed before atomic rename; the active file is never unlinked first.
class NativeOnlineResourceStorage implements OnlineResourceStorage {
  NativeOnlineResourceStorage({Directory? directory})
    : _injectedDirectory = directory;

  static final Map<String, Future<void>> _queues = {};
  static int _sequence = 0;
  static final RegExp _ownedTemp = RegExp(
    r'^\.(?:write|active)-[0-9]+-[0-9]+-[0-9]+$',
  );
  final Directory? _injectedDirectory;
  Future<Directory>? _directory;

  Future<Directory> _root() => _directory ??= () async {
    var directory = _injectedDirectory;
    if (directory == null) {
      // The OS-provided app support path can contain platform aliases (for
      // example Android user-data or macOS /var). Resolve that trusted base
      // once, then reject links inside our own resource directory as usual.
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      final base = await support.resolveSymbolicLinks();
      directory = Directory(
        '$base${Platform.pathSeparator}terraforge-online-resources-v1',
      );
    }
    return Directory(directory.absolute.uri.normalizePath().toFilePath());
  }();

  Future<T> _locked<T>(Future<T> Function(Directory root) action) async {
    final root = await _root();
    final previous = _queues[root.path] ?? Future<void>.value();
    final released = Completer<void>();
    final tail = released.future;
    _queues[root.path] = tail;
    await previous;
    RandomAccessFile? lock;
    var locked = false;
    try {
      await _ensureDirectory(root);
      final lockFile = File(
        '${root.path}${Platform.pathSeparator}.resource-lock',
      );
      await _checkFile(lockFile, allowMissing: true);
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.blockingExclusive);
      locked = true;
      await _checkFile(lockFile);
      for (final kind in onlineResourceKinds) {
        await _ensureDirectory(
          Directory('${root.path}${Platform.pathSeparator}$kind'),
        );
      }
      await _recoverTemps(root);
      return await action(root);
    } finally {
      try {
        if (locked) await lock!.unlock();
      } finally {
        try {
          await lock?.close();
        } finally {
          released.complete();
          if (identical(_queues[root.path], tail)) _queues.remove(root.path);
        }
      }
    }
  }

  // Inspect every ancestor without following links before creating anything.
  Future<void> _ensureDirectory(Directory directory) async {
    final parent = directory.parent;
    if (parent.path != directory.path) await _ensureDirectory(parent);
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create();
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Resource directory is not a real directory',
        directory.path,
      );
    }
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Resource directory changed during access',
        directory.path,
      );
    }
  }

  Future<bool> _checkFile(File file, {bool allowMissing = false}) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (allowMissing && type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Resource path is not a regular file',
        file.path,
      );
    }
    return true;
  }

  File _file(Directory root, String kind, String id) => File(
    '${root.path}${Platform.pathSeparator}${onlineResourceFileName(kind, id).replaceAll('/', Platform.pathSeparator)}',
  );

  Future<void> _recoverTemps(Directory root) async {
    final state = Directory('${root.path}${Platform.pathSeparator}state');
    await for (final entry in state.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (!_ownedTemp.hasMatch(name)) continue;
      final file = File(entry.path);
      await _checkFile(file);
      await file.delete();
    }
  }

  Future<File> _stage(Directory root, Uint8List bytes, String prefix) async {
    File temporary;
    do {
      temporary = File(
        '${root.path}${Platform.pathSeparator}state${Platform.pathSeparator}.$prefix-$pid-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      );
    } while (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await _checkFile(temporary);
      return temporary;
    } catch (_) {
      await _removeOwnTemp(temporary);
      rethrow;
    }
  }

  Future<void> _removeOwnTemp(File temporary) async {
    // Never recurse, follow a symlink, or delete someone else's temporary name.
    final name = temporary.uri.pathSegments.last;
    if (!_ownedTemp.hasMatch(name)) return;
    try {
      if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await temporary.delete();
      }
    } on FileSystemException {
      // A failed cleanup is recovered under the directory lock on next access.
    }
  }

  Future<void> _atomicWrite(
    Directory root,
    File target,
    Uint8List bytes,
  ) async {
    await _checkFile(target, allowMissing: true);
    final temporary = await _stage(root, bytes, 'write');
    try {
      await _checkFile(target, allowMissing: true);
      await temporary.rename(target.path);
    } finally {
      await _removeOwnTemp(temporary);
    }
  }

  Future<Uint8List?> _read(Directory root, String kind, String id) async {
    final file = _file(root, kind, id);
    if (!await _checkFile(file, allowMissing: true)) return null;
    final handle = await file.open();
    try {
      final length = await handle.length();
      validateOnlineResourceSize(kind, length);
      final bytes = Uint8List(length);
      var offset = 0;
      while (offset < length) {
        final count = await handle.readInto(bytes, offset, length);
        if (count == 0) {
          throw FileSystemException('Resource file was truncated', file.path);
        }
        offset += count;
      }
      if ((await handle.read(1)).isNotEmpty) {
        throw FileSystemException(
          'Resource file changed during access',
          file.path,
        );
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<Uint8List?> read(String kind, String id) async {
    validateOnlineResourceKey(kind, id);
    return _locked((root) => _read(root, kind, id));
  }

  @override
  Future<void> write(String kind, String id, Uint8List bytes) async {
    validateOnlineResourceKey(kind, id);
    validateOnlineResourceSize(kind, bytes.length);
    final snapshot = Uint8List.fromList(bytes);
    await _locked(
      (root) => _atomicWrite(root, _file(root, kind, id), snapshot),
    );
  }

  @override
  Future<void> remove(String kind, String id) async {
    validateOnlineResourceKey(kind, id);
    await _locked((root) async {
      final file = _file(root, kind, id);
      if (await _checkFile(file, allowMissing: true)) await file.delete();
    });
  }

  @override
  Future<List<OnlineResourceEntry>> list() => _locked((root) async {
    final entries = <OnlineResourceEntry>[];
    for (final kind in onlineResourceKinds) {
      final directory = Directory('${root.path}${Platform.pathSeparator}$kind');
      await for (final entity in directory.list(followLinks: false)) {
        final name = entity.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        if (onlineResourceEntry('$kind/$name', 0) == null) continue;
        final file = File(entity.path);
        await _checkFile(file);
        final length = await file.length();
        entries.add(onlineResourceEntry('$kind/$name', length)!);
      }
    }
    return List.unmodifiable(entries);
  });

  @override
  Future<void> commitActive(String namespace, Uint8List bytes) async {
    validateOnlineResourceKey('state', 'active-$namespace');
    validateOnlineResourceSize('state', bytes.length);
    final snapshot = Uint8List.fromList(bytes);
    await _locked((root) async {
      final active = _file(root, 'state', 'active-$namespace');
      final backup = _file(root, 'state', 'backup-$namespace');
      await _checkFile(active, allowMissing: true);
      final next = await _stage(root, snapshot, 'active');
      try {
        final previous = await _read(root, 'state', 'active-$namespace');
        if (previous != null) await _atomicWrite(root, backup, previous);
        await _checkFile(active, allowMissing: true);
        await next.rename(active.path);
      } finally {
        await _removeOwnTemp(next);
      }
    });
  }
}
