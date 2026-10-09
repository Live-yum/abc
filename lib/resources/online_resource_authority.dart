import 'dart:convert';
import 'dart:typed_data';

import 'online_resource_protocol.dart';
import 'online_resource_storage.dart';
import 'online_resource_transport.dart';

/// Durable approval high-water records are never removed by resource cleanup.
/// A valid revocation blocks this process even when writing its ledger fails.
class OnlineResourceAuthority {
  OnlineResourceAuthority(this.storage, String endpoint, {this.onChanged})
    : endpoint = normalizeResourceEndpoint(endpoint);
  final OnlineResourceStorage storage;
  final String endpoint;
  final void Function()? onChanged;
  OnlineApproval? current;
  String namespace = '';
  Map<String, String> _approved = {};
  final Set<String> _volatileRevoked = {};
  bool _failed = false;
  bool _storageFailed = false;
  Future<void>? _restoring;
  Future<void> _queue = Future.value();
  String get _root =>
      resourceDigest(utf8.encode('$endpoint|approval-state-v1'));
  String _namespace(String id) =>
      resourceDigest(utf8.encode('$endpoint|$id|stable|approval-state-v1'));

  Future<void> restore() => _restoring ??= _restore().catchError((
    Object failure,
    StackTrace trace,
  ) {
    // Retry I/O failures without resetting any observed high-water corruption
    // or revocation state. A bad ledger still remains fail-closed.
    _restoring = null;
    Error.throwWithStackTrace(failure, trace);
  });

  Future<void> _restore() async {
    String? id;
    var history = false;
    for (var slot = 0; slot < 2; slot++) {
      final raw = await storage.read('state', 'root-$_root-$slot');
      if (raw == null) continue;
      history = true;
      try {
        final value = jsonDecode(utf8.decode(raw));
        resourceRequire(
          value is Map && value['authorityId'] is String,
          '审批根记录损坏',
        );
        id ??= value['authorityId'] as String;
      } catch (_) {
        _failed = true;
      }
    }
    if (id == null) {
      if (history) _failed = true;
      return;
    }
    final record = await _load(_namespace(id));
    if (record == null) {
      _failed = true;
      return;
    }
    namespace = _namespace(id);
    current = record.$1;
    _approved = record.$2;
  }

  Future<(OnlineApproval, Map<String, String>)?> _load(String ns) async {
    final records = <(OnlineApproval, Map<String, String>)>[];
    for (var slot = 0; slot < 2; slot++) {
      final raw = await storage.read('state', 'authority-$ns-$slot');
      if (raw == null) continue;
      try {
        final value = jsonDecode(utf8.decode(raw));
        resourceRequire(
          value is Map && value['namespace'] == ns && value['approved'] is List,
          '审批高水记录损坏',
        );
        final state = OnlineApproval.parse(resourceJsonBytes(value['state']));
        final canonical = {
          'namespace': ns,
          'state': state.toJson(),
          'approved': value['approved'],
        };
        resourceRequire(
          value['recordSha256'] == resourceDigest(resourceJsonBytes(canonical)),
          '审批记录摘要无效',
        );
        final approved = <String, String>{};
        for (final item in value['approved'] as List) {
          resourceRequire(
            item is Map &&
                item['sha'] is String &&
                onlineHashPattern.hasMatch(item['sha']) &&
                item['gameVersion'] is String &&
                (item['gameVersion'] as String).isNotEmpty &&
                !state.revoked.contains(item['sha']) &&
                !approved.containsKey(item['sha']),
            '已审批版本记录无效',
          );
          approved[item['sha'] as String] = item['gameVersion'] as String;
        }
        resourceRequire(
          state.activeSha256 == null ||
              approved[state.activeSha256] == state.gameVersion,
          '审批活动版本记录缺失',
        );
        records.add((state, approved));
      } catch (_) {
        _failed = true;
      }
    }
    records.sort(
      (a, b) => compareApprovalSequence(b.$1.sequence, a.$1.sequence),
    );
    if (records.length > 1 &&
        records[0].$1.sequence == records[1].$1.sequence &&
        records[0].$1.stateSha256 != records[1].$1.stateSha256) {
      _failed = true;
    }
    return records.isEmpty ? null : records.first;
  }

  Future<void> accept(Uint8List bytes) {
    final snapshot = Uint8List.fromList(bytes);
    final result = _queue.then((_) => _accept(snapshot));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _accept(Uint8List bytes) async {
    await restore();
    final next = OnlineApproval.parse(bytes);
    final ns = _namespace(next.authorityId);
    final previous = ns == namespace && current != null
        ? (current!, _approved)
        : await _load(ns);
    if (_failed) throw StateError('审批高水记录缺失或损坏，线上资源不可用');
    if (previous != null) {
      final order = compareApprovalSequence(
        next.sequence,
        previous.$1.sequence,
      );
      resourceRequire(
        order >= 0 &&
            (order != 0 || next.stateSha256 == previous.$1.stateSha256),
        '拒绝重放或冲突的审批状态',
      );
      resourceRequire(
        previous.$1.revoked.every(next.revoked.contains),
        '审批状态丢失历史撤销记录',
      );
    }
    for (final sha in next.revoked) {
      _volatileRevoked.add('$ns:$sha');
    }
    final approved = <String, String>{
      for (final entry in (previous?.$2 ?? <String, String>{}).entries)
        if (!next.revoked.contains(entry.key)) entry.key: entry.value,
    };
    if (next.activeSha256 != null) {
      approved[next.activeSha256!] = next.gameVersion!;
    }
    namespace = ns;
    current = next;
    _approved = approved;
    final record = <String, Object?>{
      'namespace': ns,
      'state': next.toJson(),
      'approved': [
        for (final entry in approved.entries)
          {'sha': entry.key, 'gameVersion': entry.value},
      ],
    };
    record['recordSha256'] = resourceDigest(resourceJsonBytes(record));
    try {
      for (var slot = 0; slot < 2; slot++) {
        await storage.write(
          'state',
          'authority-$ns-$slot',
          resourceJsonBytes(record),
        );
      }
      for (var slot = 0; slot < 2; slot++) {
        await storage.write(
          'state',
          'root-$_root-$slot',
          resourceJsonBytes({'authorityId': next.authorityId}),
        );
      }
      _storageFailed = false;
    } catch (_) {
      _storageFailed = true;
      rethrow;
    } finally {
      onChanged?.call();
    }
  }

  void assertUsable(String sha, String ns, {String? gameVersion}) {
    if (_failed || _storageFailed) throw StateError('审批记录持久化失败或损坏，线上资源不可用');
    if (ns != namespace || current == null) throw StateError('资源后台权限域已改变');
    if (_volatileRevoked.contains('$ns:$sha') ||
        current!.revoked.contains(sha)) {
      throw StateError('此游戏资源版本已撤销');
    }
    if (!_approved.containsKey(sha) ||
        gameVersion != null && _approved[sha] != gameVersion) {
      throw StateError('当前后台未授权此缓存版本');
    }
  }
}
