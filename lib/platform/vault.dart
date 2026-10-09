import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'vault_native.dart'
    if (dart.library.js_interop) 'vault_web.dart'
    as platform;

const maxVaultBytes = 128 * 1024 * 1024;

class VaultException implements Exception {
  final String message;
  const VaultException(this.message);
  @override
  String toString() => 'VaultException: $message';
}

/// Metadata deliberately contains no filesystem source paths.
class VaultEntry {
  final String id;
  final String name;
  final String kind;
  final String sha256;
  final int size;
  final DateTime modified;

  const VaultEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.sha256,
    required this.size,
    required this.modified,
  });

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'sha256': sha256,
    'size': size,
    'modified': modified.toUtc().toIso8601String(),
  };

  factory VaultEntry.fromJson(Map<String, dynamic> json) {
    try {
      final entry = VaultEntry(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        sha256: json['sha256'] as String,
        size: json['size'] as int,
        modified: DateTime.parse(json['modified'] as String),
      );
      validateVaultEntry(entry);
      return entry;
    } catch (_) {
      throw const VaultException('本地存档记录损坏，未加载任何不可信数据。');
    }
  }
}

abstract class LocalVault {
  Future<List<VaultEntry>> list();
  Future<void> put(VaultEntry entry, Uint8List bytes);
  Future<Uint8List> read(String id);
  Future<void> remove(String id);
}

LocalVault createLocalVault() => platform.createPlatformVault();

void validateVaultId(String id) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$').hasMatch(id)) {
    throw const VaultException('本地存档标识无效。');
  }
}

void validateVaultEntry(VaultEntry entry) {
  validateVaultId(entry.id);
  if (entry.size < 0 ||
      entry.size > maxVaultBytes ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.sha256) ||
      entry.name.isEmpty ||
      entry.name.length > 255 ||
      entry.name.contains(RegExp(r'[/\\\x00-\x1f]')) ||
      entry.kind.isEmpty ||
      entry.kind.length > 64 ||
      entry.kind.contains(RegExp(r'[\x00-\x1f]'))) {
    throw const VaultException('本地存档信息无效（单个文件上限 128 MiB）。');
  }
}

void validateVaultBytes(VaultEntry entry, Uint8List bytes) {
  validateVaultEntry(entry);
  if (bytes.length > maxVaultBytes ||
      bytes.length != entry.size ||
      crypto.sha256.convert(bytes).toString() != entry.sha256) {
    throw const VaultException('存档大小或 SHA-256 校验失败，文件可能损坏。');
  }
}
