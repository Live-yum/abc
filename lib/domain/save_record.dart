import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Originals are immutable. Only independently validated candidates may be exported.
class SaveRecord {
  final String id, name, kind;
  final Uint8List _original;
  Uint8List _current;
  late final String _originalDigest = sha256.convert(_original).toString();
  late String _currentDigest = _originalDigest;
  final List<Uint8List> _undo = [], _redo = [];
  static const maxHistoryBytes = 64 * 1024 * 1024;
  final int historyBudgetBytes;
  SaveRecord({
    required this.id,
    required this.name,
    required this.kind,
    required Uint8List bytes,
    this.historyBudgetBytes = maxHistoryBytes,
  }) : _original = Uint8List.fromList(bytes),
       _current = Uint8List.fromList(bytes) {
    if (historyBudgetBytes < 0 || historyBudgetBytes > maxHistoryBytes) {
      throw ArgumentError.value(historyBudgetBytes, 'historyBudgetBytes');
    }
  }
  Uint8List get original => Uint8List.fromList(_original);
  Uint8List get current => Uint8List.fromList(_current);
  String get originalHash => _originalDigest;
  String get currentHash => _currentDigest;
  bool get modified => _currentDigest != _originalDigest;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void commit(Uint8List validated) {
    final digest = sha256.convert(validated).toString();
    if (digest == _currentDigest) {
      return;
    }
    _undo.add(_current);
    _current = Uint8List.fromList(validated);
    _currentDigest = digest;
    _redo.clear();
    _trimHistory();
  }

  void _trimHistory() {
    var bytes = [..._undo, ..._redo].fold<int>(0, (n, p) => n + p.length);
    while (_undo.length + _redo.length > 20 || bytes > historyBudgetBytes) {
      final oldest = _undo.isNotEmpty ? _undo.removeAt(0) : _redo.removeAt(0);
      bytes -= oldest.length;
    }
  }

  void undo() {
    if (_undo.isEmpty) {
      return;
    }
    _redo.add(_current);
    _current = _undo.removeLast();
    _currentDigest = sha256.convert(_current).toString();
    _trimHistory();
  }

  void redo() {
    if (_redo.isEmpty) {
      return;
    }
    _undo.add(_current);
    _current = _redo.removeLast();
    _currentDigest = sha256.convert(_current).toString();
    _trimHistory();
  }

  /// Navigation and document activation are one transaction. A reverse undo is
  /// not sufficient for rollback because byte-budget pruning can remove redo.
  Future<void> navigateHistory({
    required bool forward,
    required Future<void> Function() verify,
  }) async {
    final before = _current;
    final digestBefore = _currentDigest;
    final undoBefore = List<Uint8List>.of(_undo);
    final redoBefore = List<Uint8List>.of(_redo);
    try {
      forward ? redo() : undo();
      await verify();
    } catch (_) {
      _current = before;
      _currentDigest = digestBefore;
      _undo
        ..clear()
        ..addAll(undoBefore);
      _redo
        ..clear()
        ..addAll(redoBefore);
      rethrow;
    }
  }

  String get exportName {
    final stem = name.replaceFirst(
      RegExp(r'\.(wld|plr)(\.bak)?$', caseSensitive: false),
      '',
    );
    return '${stem}_terraforge.$kind';
  }
}
