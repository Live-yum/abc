import 'dart:collection';

import 'world_stamp.dart';

/// Editable sparse block/wall layer project; never stores entity payloads.
class FusionDocument {
  static const historyBudgetBytes = 32 * 1024 * 1024;
  // Conservative 64-bit estimate: reference slot plus immutable cell object.
  static const _bytesPerHistoryCell = 48;
  int width, height;
  List<StampCell?> _cells;
  final List<List<StampCell?>> _undo = [], _redo = [];
  List<StampCell?>? _stroke;
  FusionDocument(this.width, this.height)
    : _cells = List.filled(_size(width, height), null);
  static int _size(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 4096 ||
        width * height > WorldStamp.maxCells) {
      throw ArgumentError(
        'Fusion dimensions must be 1–4096 and at most 1,048,576 cells',
      );
    }
    return width * height;
  }

  List<StampCell?> get cells => UnmodifiableListView(_cells);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void beginStroke() {
    _stroke ??= List.of(_cells);
  }

  void endStroke() {
    final before = _stroke;
    _stroke = null;
    if (before == null) return;
    var changed = false;
    for (var i = 0; i < before.length; i++) {
      if (!_same(before[i], _cells[i])) {
        changed = true;
        break;
      }
    }
    if (changed) {
      _undo.add(before);
      while (_undo.length > 50 ||
          _undo.length * (64 + _cells.length * _bytesPerHistoryCell) >
              historyBudgetBytes) {
        _undo.removeAt(0);
      }
      _redo.clear();
    }
  }

  void paint(int x, int y, StampCell? cell) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final own = _stroke == null;
    beginStroke();
    _cells[y * width + x] = cell;
    if (own) endStroke();
  }

  void clear() {
    beginStroke();
    _cells = List.filled(width * height, null);
    endStroke();
  }

  void undo() {
    endStroke();
    if (_undo.isNotEmpty) {
      _redo.add(_cells);
      _cells = _undo.removeLast();
    }
  }

  void redo() {
    endStroke();
    if (_redo.isNotEmpty) {
      _undo.add(_cells);
      _cells = _redo.removeLast();
    }
  }

  void replace(int w, int h, List<StampCell?> cells) {
    if (cells.length != _size(w, h)) {
      throw const FormatException('Fusion cell count mismatch');
    }
    width = w;
    height = h;
    _cells = List.of(cells);
    _undo.clear();
    _redo.clear();
    _stroke = null;
  }

  static bool _same(StampCell? a, StampCell? b) =>
      identical(a, b) ||
      a != null &&
          b != null &&
          a.block == b.block &&
          a.wall == b.wall &&
          a.blockPaint == b.blockPaint &&
          a.wallPaint == b.wallPaint;
  Map<String, Object?> toJson() => {
    'format': 'terraforge.fusion',
    'version': 1,
    'width': width,
    'height': height,
    'cells': _cells
        .map(
          (cell) => cell == null
              ? null
              : {
                  'block': cell.block,
                  'wall': cell.wall,
                  'blockPaint': cell.blockPaint,
                  'wallPaint': cell.wallPaint,
                },
        )
        .toList(),
  };
  factory FusionDocument.fromJson(Map<String, dynamic> json) {
    if (json.keys.any(
          (key) =>
              !['format', 'version', 'width', 'height', 'cells'].contains(key),
        ) ||
        json['format'] != 'terraforge.fusion' ||
        json['version'] != 1 ||
        json['width'] is! int ||
        json['height'] is! int ||
        json['cells'] is! List) {
      throw const FormatException('Unsupported fusion project');
    }
    final result = FusionDocument(json['width'] as int, json['height'] as int);
    final raw = json['cells'] as List;
    if (raw.length != result.width * result.height) {
      throw const FormatException('Fusion cell count mismatch');
    }
    result.replace(
      result.width,
      result.height,
      raw.map<StampCell?>((value) {
        if (value == null) return null;
        if (value is! Map ||
            value.keys.any(
              (k) => !['block', 'wall', 'blockPaint', 'wallPaint'].contains(k),
            )) {
          throw const FormatException('Unsupported fusion cell fields');
        }
        final block = value['block'],
            wall = value['wall'],
            bp = value['blockPaint'] ?? 0,
            wp = value['wallPaint'] ?? 0;
        if (block != null &&
                (block is! int || ![-1, 0, 1, 2, 30].contains(block)) ||
            wall != null && (wall is! int || wall < 0 || wall > 4) ||
            bp is! int ||
            bp < 0 ||
            bp > 30 ||
            wp is! int ||
            wp < 0 ||
            wp > 30 ||
            (block == null || block == -1) && bp != 0 ||
            (wall == null || wall == 0) && wp != 0) {
          throw const FormatException('Unsupported fusion material or paint');
        }
        return StampCell(
          block: block as int?,
          wall: wall as int?,
          blockPaint: bp,
          wallPaint: wp,
        );
      }).toList(),
    );
    return result;
  }
}
