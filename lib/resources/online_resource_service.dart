import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/resource_store.dart';
import 'online_resource_authority.dart';
import 'online_resource_normalizer.dart';
import 'online_resource_protocol.dart';
import 'online_resource_storage.dart';
import 'online_resource_transport.dart';

/// A durable, digest-pinned installer. All network I/O follows explicit methods;
/// initialization uses verified local state only. No credentials are involved.
class OnlineResourceService extends ChangeNotifier {
  OnlineResourceService({
    required this.transport,
    OnlineResourceStorage? storage,
    DateTime Function()? now,
  }) : storage = storage ?? createOnlineResourceStorage(),
       _now = now ?? DateTime.now {
    authority = OnlineResourceAuthority(
      this.storage,
      transport.authorityEndpoint,
      onChanged: _authorityChanged,
    );
  }
  static const maxCacheBytes = 512 * 1024 * 1024;
  static const maxRecoverableBytes = 32 * 1024 * 1024;
  static const recoveryTtl = Duration(days: 7);
  static final Set<String> _runningEndpoints = {};
  final OnlineResourceTransport transport;
  final OnlineResourceStorage storage;
  final DateTime Function() _now;
  late final OnlineResourceAuthority authority;
  OnlineManifest? available;
  ResourceStore? _active;
  String? _activeSha, _activeNamespace;
  Future<void>? _initializing;
  OnlineResourceCancellation? _cancellation;
  bool _disposed = false;
  String phase = 'idle';
  String? error;
  int completedObjects = 0, totalObjects = 0, verifiedBytes = 0;
  bool get busy => _cancellation != null;
  String? get activeManifestSha256 => _activeSha;
  ResourceStore? get activeStore {
    if (_active == null) return null;
    try {
      assertActiveUsable();
      return _active;
    } catch (_) {
      return null;
    }
  }

  void assertActiveUsable() {
    if (_disposed ||
        _active == null ||
        _activeSha == null ||
        _activeNamespace == null) {
      throw StateError('没有已验证的线上资源');
    }
    authority.assertUsable(
      _activeSha!,
      _activeNamespace!,
      gameVersion: _active!.catalog.gameVersion,
    );
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _authorityChanged() {
    if (_active != null) {
      try {
        assertActiveUsable();
      } catch (failure) {
        error = '$failure';
      }
    }
    _emit();
  }

  void cancel() => _cancellation?.cancel();

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      await authority.restore();
      if (authority.namespace.isEmpty) return;
      await _recoverStaging();
      for (final kind in ['active', 'backup']) {
        try {
          final pointer = await _readState('$kind-${authority.namespace}');
          if (pointer == null) continue;
          final sha = pointer['manifestSha256'];
          resourceRequire(
            sha is String && onlineHashPattern.hasMatch(sha),
            '活动资源记录无效',
          );
          final store = await _restoreInstalled(sha as String);
          if (_disposed) return;
          _active = store;
          _activeSha = sha;
          _activeNamespace = authority.namespace;
          phase = 'ready';
          error = null;
          // Reading a valid backup never overwrites an uncertain active record.
          // The next successful installation performs the atomic replacement.
          break;
        } catch (failure) {
          error = '$failure';
        }
      }
    } catch (failure) {
      error = '$failure';
      phase = 'error';
    } finally {
      if (_disposed) _releaseViews();
      _emit();
    }
  }

  Future<void> checkForUpdate() => _operation((cancel) async {
    phase = 'checking';
    _emit();
    available = await _check(cancel);
    phase = 'checked';
  });

  Future<OnlineManifest> _check(OnlineResourceCancellation cancel) async {
    cancel.check();
    await authority.accept(await transport.approval(cancel));
    cancel.check();
    final sha = authority.current?.activeSha256;
    if (sha == null) throw StateError('后台当前没有已审批的资源版本');
    final ns = authority.namespace;
    authority.assertUsable(sha, ns);
    final bytes = await transport.fetch(
      'releases/$sha.json',
      sha,
      onlineManifestMaxBytes,
      cancel,
    );
    cancel.check();
    final manifest = OnlineManifest.parse(bytes, sha);
    authority.assertUsable(sha, ns, gameVersion: manifest.gameVersion);
    await _write('releases', sha, bytes);
    return manifest;
  }

  Future<void> _operation(
    Future<void> Function(OnlineResourceCancellation) run,
  ) async {
    if (_disposed) throw StateError('资源服务已关闭');
    if (busy || _runningEndpoints.isNotEmpty) {
      throw StateError('已有资源任务正在运行');
    }
    _runningEndpoints.add(transport.authorityEndpoint);
    final cancel = _cancellation = OnlineResourceCancellation();
    error = null;
    try {
      await initialize();
      cancel.check();
      await run(cancel);
    } catch (failure) {
      error = '$failure';
      phase = failure is OnlineResourceCancelled ? 'paused' : 'error';
      rethrow;
    } finally {
      _cancellation = null;
      _runningEndpoints.remove(transport.authorityEndpoint);
      if (_disposed) _releaseViews();
      _emit();
    }
  }

  Future<void> install() => _operation((cancel) async {
    await _recoverStaging();
    await _collectInactive(cancel);
    phase = 'checking';
    _emit();
    final manifest = available = await _check(cancel);
    final ns = authority.namespace, sha = manifest.sha256;
    final key = 'staging-$sha-$ns';
    final previous = await _readState(key);
    final created = _now().millisecondsSinceEpoch;
    final record = <String, Object?>{
      'manifestSha256': sha,
      'namespace': ns,
      'createdAt': previous?['resumable'] == true
          ? previous!['createdAt']
          : created,
      'lastProgressAt': created,
      'state': 'WRITING',
      'resumable': true,
      'completedObjects': 0,
      'verifiedBytes': 0,
    };
    completedObjects = 0;
    verifiedBytes = 0;
    totalObjects = manifest.objects
        .where((r) => r.mediaType != 'application/zip')
        .length;
    void guard() {
      cancel.check();
      authority.assertUsable(sha, ns, gameVersion: manifest.gameVersion);
    }

    Future<void> checkpoint(String state) async {
      record.addAll({
        'state': state,
        'lastProgressAt': _now().millisecondsSinceEpoch,
        'completedObjects': completedObjects,
        'verifiedBytes': verifiedBytes,
      });
      await storage.write('state', key, resourceJsonBytes(record));
    }

    try {
      await checkpoint('WRITING');
      phase = 'downloading';
      _emit();
      // Delivery ZIPs are optional transport accelerators. Fetching the signed
      // individual members keeps the public HTTP contract and avoids extraction.
      for (final ref in manifest.objects.where(
        (r) => r.mediaType != 'application/zip',
      )) {
        guard();
        final decoded = await _object(ref, manifest, ns, cancel: cancel);
        ref.validateDecoded(decoded);
        completedObjects++;
        verifiedBytes += ref.bytes;
        await checkpoint('WRITING');
        _emit();
        await Future<void>.delayed(Duration.zero);
      }
      phase = 'verifying';
      await checkpoint('VERIFYING');
      _emit();
      final pack = await normalizeOnlineResources(
        manifest: manifest,
        authorityEndpoint: transport.authorityEndpoint,
        authorityId: authority.current!.authorityId,
        readObject: (ref) => _object(ref, manifest, ns),
        readImage: (texture) => _image(texture, manifest, ns, cancel: cancel),
        check: guard,
      );
      guard();
      final digest = resourceDigest(pack);
      await _write('packs', digest, pack);
      final persisted = await storage.read('packs', digest);
      resourceRequire(
        persisted != null && resourceDigest(persisted) == digest,
        '本地资源包写入后校验失败',
      );
      final store = ResourceStore.importPack(persisted!);
      // Re-check approval immediately before activation. A newly observed
      // revocation invalidates both cached bytes and already-held consumers.
      await authority.accept(await transport.approval(cancel));
      guard();
      final installed = resourceJsonBytes({
        'manifestSha256': sha,
        'namespace': ns,
        'packSha256': digest,
        'normalization': 'ABCPACK1-public-v1',
      });
      await storage.write('state', 'installed-$sha-$ns', installed);
      guard();
      await storage.commitActive(ns, installed);
      // commitActive is the cancellation linearization point. A cancellation
      // after it completes cannot undo an already-committed installation.
      authority.assertUsable(sha, ns, gameVersion: manifest.gameVersion);
      if (!_disposed) {
        _active = store;
        _activeSha = sha;
        _activeNamespace = ns;
      }
      phase = 'ready';
      error = null;
      _emit();
      try {
        await storage.remove('state', key);
      } catch (_) {
        error = '资源已启用，暂存记录待下次清理';
      }
    } catch (failure) {
      try {
        await checkpoint(
          failure is OnlineResourceCancelled ? 'PAUSED' : 'FAILED',
        );
      } catch (_) {}
      rethrow;
    }
  });

  Future<Uint8List> _object(
    OnlineObjectRef ref,
    OnlineManifest manifest,
    String ns, {
    OnlineResourceCancellation? cancel,
  }) async {
    authority.assertUsable(
      manifest.sha256,
      ns,
      gameVersion: manifest.gameVersion,
    );
    cancel?.check();
    var wire = await storage.read('objects', ref.sha256);
    if (wire != null &&
        (wire.length != ref.bytes || resourceDigest(wire) != ref.sha256)) {
      wire = null;
    }
    if (wire == null) {
      if (cancel == null) throw StateError('离线资源对象缺失或损坏');
      wire = await transport.fetch(
        ref.path,
        manifest.sha256,
        ref.bytes,
        cancel,
      );
      final decoded = ref.decode(wire);
      ref.validateDecoded(decoded);
      cancel.check();
      authority.assertUsable(manifest.sha256, ns);
      await _write('objects', ref.sha256, wire);
      wire = await storage.read('objects', ref.sha256);
      resourceRequire(wire != null, '资源对象写入失败');
    }
    cancel?.check();
    authority.assertUsable(manifest.sha256, ns);
    final decoded = ref.decode(wire!);
    ref.validateDecoded(decoded);
    return decoded;
  }

  Future<Uint8List> _image(
    OnlineTexture texture,
    OnlineManifest manifest,
    String ns, {
    OnlineResourceCancellation? cancel,
  }) async {
    authority.assertUsable(manifest.sha256, ns);
    cancel?.check();
    var bytes = await storage.read('images', texture.object.sha256);
    if (bytes != null) {
      try {
        texture.verify(bytes);
      } catch (_) {
        bytes = null;
      }
    }
    if (bytes == null) {
      if (cancel == null) throw StateError('离线图标缺失或损坏');
      bytes = await transport.fetch(
        texture.object.path,
        manifest.sha256,
        texture.object.bytes,
        cancel,
      );
      texture.verify(bytes);
      cancel.check();
      authority.assertUsable(manifest.sha256, ns);
      await _write('images', texture.object.sha256, bytes);
      bytes = await storage.read('images', texture.object.sha256);
      resourceRequire(bytes != null, '图标写入失败');
    }
    texture.verify(bytes!);
    cancel?.check();
    authority.assertUsable(manifest.sha256, ns);
    return bytes;
  }

  Future<ResourceStore> _restoreInstalled(String sha) async {
    final ns = authority.namespace;
    authority.assertUsable(sha, ns);
    final record = await _readState('installed-$sha-$ns');
    final packSha = record?['packSha256'];
    resourceRequire(
      record?['manifestSha256'] == sha &&
          record?['namespace'] == ns &&
          record?['normalization'] == 'ABCPACK1-public-v1' &&
          packSha is String &&
          onlineHashPattern.hasMatch(packSha),
      '已安装资源记录无效',
    );
    final manifestBytes = await storage.read('releases', sha);
    resourceRequire(manifestBytes != null, '本地资源清单缺失');
    final manifest = OnlineManifest.parse(manifestBytes!, sha);
    authority.assertUsable(sha, ns, gameVersion: manifest.gameVersion);
    final normalized = await normalizeOnlineResources(
      manifest: manifest,
      authorityEndpoint: transport.authorityEndpoint,
      authorityId: authority.current!.authorityId,
      readObject: (ref) => _object(ref, manifest, ns),
      readImage: (texture) => _image(texture, manifest, ns),
      check: () => authority.assertUsable(sha, ns),
    );
    resourceRequire(resourceDigest(normalized) == packSha, '缓存资源与已审批来源不匹配');
    final pack = await storage.read('packs', packSha as String);
    resourceRequire(
      pack != null && resourceDigest(pack) == packSha,
      '缓存资源包缺失或损坏',
    );
    return ResourceStore.importPack(pack!);
  }

  Future<Map<String, dynamic>?> _readState(String id) async {
    final bytes = await storage.read('state', id);
    if (bytes == null) return null;
    final value = jsonDecode(utf8.decode(bytes));
    resourceRequire(value is Map<String, dynamic>, '资源状态记录无效');
    return value as Map<String, dynamic>;
  }

  Future<void> _write(String kind, String id, Uint8List bytes) async {
    final entries = await storage.list();
    final usage = entries.fold<int>(
      0,
      (n, e) => n + (e.kind == kind && e.id == id ? 0 : e.bytes),
    );
    resourceRequire(
      usage + bytes.length <= maxCacheBytes,
      '资源缓存达到 512 MiB 上限，原资源版本已保留',
    );
    await storage.write(kind, id, bytes);
  }

  Future<void> _recoverStaging() async {
    final entries = await storage.list();
    final now = _now().millisecondsSinceEpoch;
    var retained = 0, count = 0;
    final records = <(OnlineResourceEntry, Map<String, dynamic>)>[];
    for (final entry in entries.where(
      (e) =>
          e.kind == 'state' &&
          e.id.startsWith('staging-') &&
          e.id.endsWith('-${authority.namespace}'),
    )) {
      try {
        final record = await _readState(entry.id);
        if (record != null) records.add((entry, record));
      } catch (_) {
        /* Corrupt checkpoints are never trusted for resumption. */
      }
    }
    int progress(Map<String, dynamic> record) =>
        record['lastProgressAt'] is int ? record['lastProgressAt'] as int : 0;
    records.sort((a, b) => progress(b.$2).compareTo(progress(a.$2)));
    for (final (entry, record) in records) {
      final updated = record['lastProgressAt'], created = record['createdAt'];
      var bytes = 0;
      var validClosure = false;
      try {
        final keys = await _closure('${record['manifestSha256']}');
        bytes = entries
            .where((e) => keys.contains('${e.kind}/${e.id}'))
            .fold<int>(0, (n, e) => n + e.bytes);
        validClosure = true;
      } catch (_) {
        /* An incomplete or corrupt manifest cannot protect cache. */
      }
      var usable =
          updated is int &&
          created is int &&
          created <= updated &&
          updated <= now &&
          now - updated < recoveryTtl.inMilliseconds &&
          validClosure &&
          entry.id ==
              'staging-${record['manifestSha256']}-${authority.namespace}' &&
          record['namespace'] == authority.namespace &&
          [
            'WRITING',
            'VERIFYING',
            'PAUSED',
            'FAILED',
          ].contains(record['state']) &&
          count < 2 &&
          retained + bytes <= maxRecoverableBytes;
      try {
        authority.assertUsable(
          '${record['manifestSha256']}',
          authority.namespace,
        );
      } catch (_) {
        usable = false;
      }
      record['state'] = usable ? 'PAUSED' : 'ABANDONED';
      record['resumable'] = usable;
      if (usable) {
        count++;
        retained += bytes;
      }
      await storage.write('state', entry.id, resourceJsonBytes(record));
    }
  }

  /// Explicit cleanup keeps every active/backup closure and recoverable install
  /// across all authority namespaces. It never deletes approval high-water data.
  Future<void> clearInactiveCache() => _operation((cancel) async {
    await _recoverStaging();
    await _collectInactive(cancel);
    phase = activeStore == null ? 'idle' : 'ready';
  });

  Future<Set<String>> _closure(String sha) async {
    resourceRequire(onlineHashPattern.hasMatch(sha), '缓存资源清单摘要无效');
    final raw = await storage.read('releases', sha);
    resourceRequire(raw != null, '缓存资源清单缺失');
    final manifest = OnlineManifest.parse(raw!, sha);
    final keys = <String>{
      'releases/$sha',
      for (final ref in manifest.objects) 'objects/${ref.sha256}',
    };
    final textures = await storage.read('objects', manifest.textures.sha256);
    if (textures != null) {
      final catalog = manifest.parseTextures(
        parseResourceJson(manifest.textures.decode(textures)),
      );
      keys.addAll(catalog.values.map((v) => 'images/${v.object.sha256}'));
    }
    return keys;
  }

  Future<void> _collectInactive(OnlineResourceCancellation cancel) async {
    final entries = await storage.list();
    final keep = <String>{};
    // Plan all preservation before deleting anything. An unreadable active or
    // backup record aborts cleanup rather than risking the prior installation.
    for (final entry in entries.where((e) => e.kind == 'state')) {
      final pointer =
          entry.id.startsWith('active-') || entry.id.startsWith('backup-');
      final staging = entry.id.startsWith('staging-');
      if (!pointer && !staging) continue;
      cancel.check();
      Map<String, dynamic>? record;
      try {
        record = await _readState(entry.id);
      } catch (_) {
        if (pointer) rethrow;
        continue;
      }
      if (record == null) continue;
      if (staging && record['resumable'] != true) continue;
      final sha = record['manifestSha256'];
      final ns = record['namespace'];
      resourceRequire(
        sha is String && ns is String && onlineHashPattern.hasMatch(ns),
        '缓存安装标识无效',
      );
      resourceRequire(
        entry.id ==
            (pointer
                ? '${entry.id.startsWith('active-') ? 'active' : 'backup'}-$ns'
                : 'staging-$sha-$ns'),
        '缓存状态与存储权限域不一致',
      );
      keep.addAll(await _closure(sha as String));
      keep.add('state/${entry.id}');
      keep.add('state/installed-$sha-$ns');
      final installed = pointer
          ? record
          : await _readState('installed-$sha-$ns');
      final pack = installed?['packSha256'];
      resourceRequire(!pointer || pack is String, '活动资源包摘要缺失');
      if (pack != null) {
        resourceRequire(
          pack is String && onlineHashPattern.hasMatch(pack),
          '缓存包摘要无效',
        );
        keep.add('packs/$pack');
      }
    }
    for (final entry in entries) {
      cancel.check();
      if (entry.kind == 'state' &&
          !entry.id.startsWith('installed-') &&
          !entry.id.startsWith('staging-')) {
        continue;
      }
      if (!keep.contains('${entry.kind}/${entry.id}')) {
        await storage.remove(entry.kind, entry.id);
      }
    }
  }

  void _releaseViews() {
    _active = null;
    _activeSha = null;
    _activeNamespace = null;
    available = null;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    _releaseViews();
    super.dispose();
  }
}
