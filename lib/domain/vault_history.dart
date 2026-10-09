import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../platform/vault.dart';

class VaultHistorySnapshot {
  final List<VaultEntry> active;
  final List<VaultEntry> trashed;

  VaultHistorySnapshot(Iterable<VaultEntry> entries)
    : active = List.unmodifiable(
        entries.where((e) => !VaultHistory.isTrashed(e)),
      ),
      trashed = List.unmodifiable(entries.where(VaultHistory.isTrashed));
}

/// Copy, verify, then remove only the app-owned immutable vault record.
/// Deterministic destinations make interrupted operations safely retryable.
class VaultHistory {
  final LocalVault vault;
  static final _gates = Expando<_VaultGate>();
  VaultHistory(this.vault);

  static bool isTrashed(VaultEntry entry) => entry.kind.startsWith('trash:');

  Future<VaultHistorySnapshot> load() async =>
      VaultHistorySnapshot(await vault.list());

  Future<VaultEntry> trash(VaultEntry entry) => _run(() async {
    validateVaultEntry(entry);
    if (isTrashed(entry) || entry.kind.length > 58) {
      throw const VaultException('此存档类型无法安全移入回收站。');
    }
    final id = entry.id.length <= 93
        ? 't1_${entry.id}'
        : 'th1_${crypto.sha256.convert(utf8.encode(entry.id))}';
    return _move(entry, _copy(entry, id: id, kind: 'trash:${entry.kind}'));
  });

  Future<VaultEntry> restore(VaultEntry entry) => _run(() async {
    validateVaultEntry(entry);
    if (!isTrashed(entry)) {
      throw const VaultException('此存档不在回收站。');
    }
    final kind = entry.kind.substring(6);
    late String id;
    if (entry.id.startsWith('t1_')) {
      id = entry.id.substring(3);
    } else if (RegExp(r'^th1_[a-f0-9]{64}$').hasMatch(entry.id)) {
      // Long original IDs cannot fit alongside the namespace. Prefer an
      // identical original still present after an interrupted trash operation.
      id = 'r1_${entry.id.substring(4)}';
      for (final candidate in await vault.list()) {
        if (!isTrashed(candidate) &&
            crypto.sha256.convert(utf8.encode(candidate.id)).toString() ==
                entry.id.substring(4) &&
            _same(candidate, _copy(entry, id: candidate.id, kind: kind))) {
          id = candidate.id;
          break;
        }
      }
    } else {
      throw const VaultException('回收站存档标识无效，未修改任何文件。');
    }
    final target = _copy(entry, id: id, kind: kind);
    validateVaultEntry(target);
    return _move(entry, target);
  });

  Future<VaultEntry> _move(VaultEntry source, VaultEntry target) async {
    final entries = await vault.list();
    final originals = entries.where((e) => e.id == source.id).toList();
    final destinations = entries.where((e) => e.id == target.id).toList();
    if (originals.length > 1 || destinations.length > 1) {
      throw const VaultException('本地存档标识冲突，未移除任何存档。');
    }
    if (originals.isNotEmpty && !_same(originals.single, source)) {
      throw const VaultException('存档信息已变化，请刷新后重试。');
    }
    if (destinations.isNotEmpty && !_same(destinations.single, target)) {
      throw const VaultException('目标存档标识冲突，未覆盖或移除任何存档。');
    }
    if (originals.isEmpty && destinations.isEmpty) {
      throw const VaultException('存档不存在，请刷新后重试。');
    }
    Uint8List? bytes;
    if (originals.isNotEmpty) {
      bytes = await vault.read(source.id);
      validateVaultBytes(source, bytes);
    }
    if (destinations.isEmpty) {
      await vault.put(target, bytes!);
    }
    // An existing destination is never trusted on metadata alone.
    validateVaultBytes(target, await vault.read(target.id));
    if (originals.isNotEmpty) {
      await vault.remove(source.id);
    }
    final remaining = await vault.list();
    if (remaining.any((e) => e.id == source.id) ||
        !remaining.any((e) => _same(e, target))) {
      throw const VaultException('移动尚未完成；已保留可恢复副本，请刷新后重试。');
    }
    validateVaultBytes(target, await vault.read(target.id));
    return target;
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final gate = _gates[vault] ??= _VaultGate();
    final result = gate.tail.then((_) => action());
    gate.tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static VaultEntry _copy(
    VaultEntry e, {
    required String id,
    required String kind,
  }) => VaultEntry(
    id: id,
    name: e.name,
    kind: kind,
    sha256: e.sha256,
    size: e.size,
    modified: e.modified,
  );

  static bool _same(VaultEntry a, VaultEntry b) =>
      a.id == b.id &&
      a.name == b.name &&
      a.kind == b.kind &&
      a.sha256 == b.sha256 &&
      a.size == b.size &&
      a.modified.isAtSameMomentAs(b.modified);
}

class _VaultGate {
  Future<void> tail = Future<void>.value();
}
