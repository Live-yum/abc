import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'vault.dart';

LocalVault createPlatformVault() => NativeLocalVault();

/// A record is committed by atomically renaming its complete journal directory.
/// Incomplete journals remain recoverable on disk and are never listed as saves.
class NativeLocalVault implements LocalVault {
  final Future<Directory> Function() _directory;
  static Future<void> _queue = Future<void>.value();

  NativeLocalVault({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/terraforge-vault-v1');
  }

  Future<T> _run<T>(Future<T> Function(Directory root) action) {
    final result = _queue.then((_) async {
      RandomAccessFile? lock;
      try {
        final root = await _directory();
        await root.create(recursive: true);
        lock = await File('${root.path}/.lock').open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
        return await action(root);
      } on VaultException {
        rethrow;
      } on FileSystemException {
        throw const VaultException('无法访问本地存档库。请检查存储权限和剩余空间。');
      } finally {
        await lock?.close();
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Directory _record(Directory root, String id) =>
      Directory('${root.path}/$id.record');

  Future<(VaultEntry, Uint8List)> _load(Directory dir, String id) async {
    if (await FileSystemEntity.type(dir.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const VaultException('本地存档不存在或记录无效。');
    }
    final meta = File('${dir.path}/entry.json');
    final data = File('${dir.path}/data.bin');
    for (final file in [meta, data]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const VaultException('本地存档记录不完整。');
      }
    }
    if (await meta.length() > 16384) {
      throw const VaultException('本地存档记录损坏。');
    }
    late VaultEntry entry;
    try {
      entry = VaultEntry.fromJson(
        jsonDecode(await meta.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const VaultException('本地存档记录损坏。');
    }
    if (entry.id != id || await data.length() != entry.size) {
      throw const VaultException('本地存档记录与文件不匹配。');
    }
    final bytes = await data.readAsBytes();
    validateVaultBytes(entry, bytes);
    return (entry, bytes);
  }

  Future<void> _recover(Directory root) async {
    await for (final entity in root.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is! Directory || !name.startsWith('.pending-')) {
        continue;
      }
      final id = name.substring('.pending-'.length);
      try {
        validateVaultId(id);
        if (await _record(root, id).exists()) {
          continue;
        }
        await _load(entity, id);
      } on VaultException {
        continue;
      } on FileSystemException {
        continue;
      }
      await entity.rename(_record(root, id).path);
    }
  }

  @override
  Future<List<VaultEntry>> list() => _run((root) async {
    await _recover(root);
    final entries = <VaultEntry>[];
    await for (final entity in root.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!name.endsWith('.record')) {
        continue;
      }
      final id = name.substring(0, name.length - '.record'.length);
      validateVaultId(id);
      entries.add((await _load(Directory(entity.path), id)).$1);
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  });

  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) {
    // Capture caller-owned buffers before any asynchronous operation.
    validateVaultBytes(entry, bytes);
    final snapshot = Uint8List.fromList(bytes);
    return _run((root) async {
      await _recover(root);
      final record = _record(root, entry.id);
      final journal = Directory('${root.path}/.pending-${entry.id}');
      if (await FileSystemEntity.type(record.path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(journal.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw const VaultException('此存档版本已存在，请使用新的版本标识。');
      }
      await journal.create();
      await File('${journal.path}/data.bin')
          .writeAsBytes(snapshot, flush: true);
      await File('${journal.path}/entry.json')
          .writeAsString(jsonEncode(entry.toJson()), flush: true);
      await _load(journal, entry.id);
      await journal.rename(record.path);
      // Never report success without checking the committed bytes.
      await _load(record, entry.id);
    });
  }

  @override
  Future<Uint8List> read(String id) {
    validateVaultId(id);
    return _run((root) async {
      await _recover(root);
      return (await _load(_record(root, id), id)).$2;
    });
  }

  @override
  Future<void> remove(String id) {
    validateVaultId(id);
    return _run((root) async {
      await _recover(root);
      final record = _record(root, id);
      // Delete any interrupted duplicate before the committed version so a
      // later recovery cannot resurrect an explicitly removed version.
      final journal = Directory('${root.path}/.pending-$id');
      final journalType = await FileSystemEntity.type(
        journal.path,
        followLinks: false,
      );
      if (journalType == FileSystemEntityType.directory) {
        await journal.delete(recursive: true);
      } else if (journalType != FileSystemEntityType.notFound) {
        throw const VaultException('本地存档日志无效，无法安全删除。');
      }
      if (await FileSystemEntity.type(record.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return;
      }
      final deleted =
          '${root.path}/.deleted-$id-${DateTime.now().microsecondsSinceEpoch}';
      final tombstone = await record.rename(deleted);
      await tombstone.delete(recursive: true);
    });
  }
}
