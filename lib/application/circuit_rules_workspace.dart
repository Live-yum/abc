import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../engine/circuit_rules_backend.dart';
import '../engine/engine.dart';
import '../platform/files.dart';

/// UI lifecycle and file ownership only. Circuit behavior stays in the pinned
/// domain library hosted by the native isolate or Web computation worker.
class CircuitRulesWorkspace extends ChangeNotifier {
  CircuitRulesWorkspace({
    required this.backend,
    required this.files,
    required this.persist,
    this.canSchedule,
  });
  final CircuitRulesBackend? backend;
  final FileGateway files;
  final Future<void> Function(String, String, Uint8List) persist;
  final bool Function()? canSchedule;
  static const maxDocumentBytes = 8 * 1024 * 1024;
  bool busy = false, ready = false;
  bool _debug = false;
  // A replacement runtime cannot know whether its imported recovery copy was
  // exported by the user. Retain that warning until an explicit saved export.
  bool _needsExportAfterRecovery = false;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String error = '', status = '';
  Map<String, Object?>? _capabilities, _catalog, _snapshot, _document;
  int _epoch = 0;
  Timer? _timer;
  Completer<void>? _idle;
  bool _closing = false;
  Future<void>? _closeFuture;
  bool get running => _timer != null;
  Map<String, Object?> get state => Map.unmodifiable({
    'ready': ready,
    'debug': _debug,
    'busy': busy || _closing,
    'running': running,
    'error': error,
    'status': status,
    'capabilities': _capabilities,
    'catalog': _catalog,
    'snapshot': _snapshot,
    'document': _document,
  });
  Future<Object?> _invoke(String method, List<Object?> args) {
    final host = backend;
    if (host == null) throw const EngineException('当前平台未加载完整电路规则宿主。');
    return host.invokeCircuitRules(method, args);
  }

  Map<String, Object?> _map(Object? value, String label) {
    if (value is! Map || value.keys.any((k) => k is! String)) {
      throw FormatException('$label 格式无效');
    }
    return Map<String, Object?>.from(value);
  }

  Object? _freeze(Object? value, [int depth = 0]) {
    if (depth > 64) throw const FormatException('电路数据嵌套过深');
    if (value is Map) {
      return Map<String, Object?>.unmodifiable({
        for (final e in value.entries)
          e.key as String: _freeze(e.value, depth + 1),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map((v) => _freeze(v, depth + 1)),
      );
    }
    return value;
  }

  Future<bool> _ensureReady(int epoch) async {
    if (ready) return true;
    final capabilities = _map(await _invoke('capabilities', []), '电路能力');
    if (epoch != _epoch) return false;
    if (capabilities['available'] != true || capabilities['apiVersion'] != 1) {
      throw const FormatException('电路规则接口版本不支持');
    }
    final catalog = _map(await _invoke('catalog', []), '电路目录');
    if (epoch != _epoch) return false;
    if (catalog['palette'] is! List ||
        (catalog['palette'] as List).length > 10000 ||
        catalog['definitions'] is! Map ||
        catalog['demos'] is! List) {
      throw const FormatException('电路目录超出范围或格式无效');
    }
    _capabilities = _freeze(capabilities) as Map<String, Object?>;
    _catalog = _freeze(catalog) as Map<String, Object?>;
    ready = true;
    return true;
  }

  void _accept(
    Object? value,
    int epoch, {
    bool replaceOwner = false,
    bool preserveExportWarning = false,
    bool exported = false,
  }) {
    if (epoch != _epoch) return;
    final snapshot = _map(value, '电路状态'), text = snapshot['document'];
    if (snapshot['id'] is! int ||
        snapshot['generation'] is! int ||
        snapshot['revision'] is! int ||
        text is! String ||
        utf8.encode(text).length > maxDocumentBytes) {
      throw const FormatException('电路状态或文档大小无效');
    }
    final document = _map(jsonDecode(text), '电路文档');
    if (document['format'] != 'viewer-terralogic' ||
        document['version'] != 1 ||
        document['world'] is! Map) {
      throw const FormatException('不是完整电路 schema 1 文档');
    }
    final target = _catalog?['target'];
    if (target is Map &&
        (document['target'] != target['game'] ||
            document['source'] != target['source'])) {
      throw const FormatException('电路文档与规则来源不匹配');
    }
    if (!replaceOwner &&
        _snapshot?['id'] == snapshot['id'] &&
        (snapshot['generation'] as int) < (_snapshot!['generation'] as int)) {
      throw const FormatException('已忽略过期的电路状态');
    }
    final needsExport = exported
        ? false
        : replaceOwner
        ? (preserveExportWarning && (_snapshot?['dirty'] == true))
        : _needsExportAfterRecovery;
    final nextSnapshot = _freeze({
      ...snapshot,
      'dirty': snapshot['dirty'] == true || needsExport,
    }) as Map<String, Object?>;
    final nextDocument = _freeze(document) as Map<String, Object?>;
    _needsExportAfterRecovery = needsExport;
    _snapshot = nextSnapshot;
    _document = nextDocument;
  }

  String _filename() {
    final title = '${_document?['title'] ?? '完整电路'}'
        .replaceAll(RegExp(r'[\\/\x00-\x1f<>:"|?*]'), '_')
        .trim();
    return '${title.isEmpty ? '完整电路' : title}.terralogic.json';
  }

  Future<void> _persistCurrent() async {
    final text = _snapshot?['document'];
    if (text is String) {
      await persist(
        _filename(),
        'rulesCircuit',
        Uint8List.fromList(utf8.encode(text)),
      );
    }
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> loadDocument(
    Uint8List bytes, {
    required String name,
    bool persistInput = true,
  }) async {
    if (bytes.length > maxDocumentBytes) {
      throw const FormatException('完整电路文件超过 8 MiB');
    }
    if (_closing) await _closeFuture;
    if (busy) await _idle?.future;
    pause();
    final epoch = ++_epoch;
    final idle = Completer<void>();
    _idle = idle;
    busy = true;
    error = '';
    _notify();
    try {
      if (!await _ensureReady(epoch)) return;
      _accept(
        await _invoke('editor.open', [utf8.decode(bytes)]),
        epoch,
        replaceOwner: true,
      );
      if (epoch == _epoch) {
        if (persistInput) await persist(name, 'rulesCircuit', bytes);
        status = '完整电路项目已载入。';
      }
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      busy = false;
      idle.complete();
      _idle = null;
      _notify();
    }
  }

  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    if (action == 'rulesPause') {
      pause();
      _notify();
      return;
    }
    if (action == 'rulesDebug') {
      if (args['enabled'] is! bool) {
        error = '轨迹记录开关无效。';
        _notify();
        return;
      }
      _debug = args['enabled'] as bool;
      _notify();
      return;
    }
    if (action == 'rulesToggleRun' && running) {
      pause();
      _notify();
      return;
    }
    if (action == 'rulesClose') {
      await close();
      return;
    }
    if (busy || _closing) return;
    if (action != 'rulesSimulate') pause();
    final idle = Completer<void>();
    _idle = idle;
    busy = true;
    error = '';
    _notify();
    final epoch = _epoch;
    try {
      if (action == 'rulesRecover') {
        final text = _snapshot?['document'];
        await _invoke('host.reset', []);
        ready = false;
        if (!await _ensureReady(epoch)) return;
        _accept(
          await _invoke(
            text is String ? 'editor.open' : 'editor.new',
            text is String ? [text] : [],
          ),
          epoch,
          replaceOwner: true,
          preserveExportWarning: true,
        );
        status = '当前副本已重新载入，模拟会话与内存撤销历史重新开始。';
        return;
      }
      if (action != 'rulesExport' && !await _ensureReady(epoch)) return;
      switch (action) {
        case 'rulesOpen':
          if (_snapshot == null) {
            _accept(await _invoke('editor.new', []), epoch, replaceOwner: true);
          }
        case 'rulesNew':
          _accept(
            await _invoke('editor.new', [args['title'] ?? '未命名电路']),
            epoch,
            replaceOwner: true,
          );
          await _persistCurrent();
        case 'rulesDemo':
          _accept(
            await _invoke('editor.demo', [args['name']]),
            epoch,
            replaceOwner: true,
          );
          await _persistCurrent();
        case 'rulesEdit':
          final before = _snapshot?['document'];
          _accept(
            await _invoke('editor.command', [
              {'method': args['method'], 'args': args['args'] ?? []},
            ]),
            epoch,
          );
          if (_snapshot?['document'] != before) await _persistCurrent();
        case 'rulesSimulate':
          _accept(
            await _invoke('simulation.command', [
              {
                'method': args['method'],
                'args': args['args'] ?? [],
                'debug': _debug,
              },
            ]),
            epoch,
          );
        case 'rulesReset':
          _accept(await _invoke('simulation.reset', []), epoch);
        case 'rulesImport':
          final picked = await files.pick('project');
          if (picked != null) {
            if (picked.bytes.length > maxDocumentBytes) {
              throw const FormatException('完整电路文件超过 8 MiB');
            }
            _accept(
              await _invoke('editor.open', [utf8.decode(picked.bytes)]),
              epoch,
              replaceOwner: true,
            );
            if (epoch == _epoch) {
              await persist(picked.name, 'rulesCircuit', picked.bytes);
            }
          }
        case 'rulesExport':
          final text = _snapshot?['document'];
          if (text is! String) throw const EngineException('请先创建或导入完整电路。');
          final bytes = Uint8List.fromList(utf8.encode(text));
          if (await files.save(_filename(), bytes)) {
            await _persistCurrent();
            if (ready) {
              _accept(
                await _invoke('editor.command', [
                  {'method': 'markSaved', 'args': []},
                ]),
                epoch,
                exported: true,
              );
            } else if (epoch == _epoch && _snapshot != null) {
              _needsExportAfterRecovery = false;
              _snapshot = Map<String, Object?>.unmodifiable({
                ..._snapshot!,
                'dirty': false,
              });
            }
            status = '电路文件已交给系统，请确认保存位置。';
          } else {
            status = '已取消系统保存。';
          }
        case 'rulesToggleRun':
          if (_snapshot == null) throw const EngineException('请先创建或导入完整电路。');
          _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
            if (busy || !(canSchedule?.call() ?? true)) return;
            unawaited(
              dispatch('rulesSimulate', {
                'method': 'step',
                'args': [6],
              }),
            );
          });
        default:
          throw const EngineException('未知完整电路操作。');
      }
    } catch (e) {
      pause();
      error = '$e';
    } finally {
      busy = false;
      idle.complete();
      _idle = null;
      _notify();
    }
  }

  Future<void> close() {
    final pending = _closeFuture;
    if (pending != null) return pending;
    final complete = Completer<void>();
    _closeFuture = complete.future;
    unawaited(
      _closeAndRelease()
          .then((_) => complete.complete(), onError: complete.completeError)
          .whenComplete(() => _closeFuture = null),
    );
    return complete.future;
  }

  Future<void> _closeAndRelease() async {
    _closing = true;
    pause();
    ++_epoch;
    _notify();
    try {
      if (busy) await _idle?.future;
      if (ready) await _invoke('editor.close', []);
    } catch (e) {
      error = '$e';
    } finally {
      _snapshot = null;
      _document = null;
      _needsExportAfterRecovery = false;
      _closing = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    if (busy || _snapshot != null) unawaited(close());
    super.dispose();
  }
}
