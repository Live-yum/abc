import 'dart:collection';

/// Bounded, transactional raster with one undo entry per pointer stroke.
class CanvasDocument {
  int width, height;
  List<int> _pixels;
  final List<List<int>> _undo = [], _redo = [];
  List<int>? _stroke;
  static const maxPixels = 1048576;
  static const maxHistoryBytes = 32 * 1024 * 1024;
  final int historyBudgetBytes;
  CanvasDocument(
    this.width,
    this.height, {
    int color = 0,
    this.historyBudgetBytes = maxHistoryBytes,
  }) : _pixels = List.filled(_validate(width, height), color) {
    if (historyBudgetBytes < 0 || historyBudgetBytes > maxHistoryBytes) {
      throw ArgumentError.value(historyBudgetBytes, 'historyBudgetBytes');
    }
  }
  static int _validate(int w, int h) {
    if (w < 1 || h < 1 || w > 4096 || h > 4096 || w * h > maxPixels) {
      throw ArgumentError('画布尺寸须为 1–4096，且总像素不超过 1,048,576。');
    }
    return w * h;
  }

  List<int> get pixels => UnmodifiableListView(_pixels);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void beginStroke() {
    _stroke ??= List.of(_pixels);
  }

  void endStroke() {
    final before = _stroke;
    _stroke = null;
    if (before != null && !_equal(before, _pixels)) {
      _undo.add(before);
      _redo.clear();
      _trimHistory();
    }
  }

  // Budget native int-list storage conservatively at eight bytes per pixel.
  // Current pixels and the one in-progress stroke are separate working state.
  void _trimHistory() {
    var bytes = [..._undo, ..._redo].fold<int>(0, (n, p) => n + p.length * 8);
    while (_undo.length + _redo.length > 50 || bytes > historyBudgetBytes) {
      final oldest = _undo.isNotEmpty ? _undo.removeAt(0) : _redo.removeAt(0);
      bytes -= oldest.length * 8;
    }
  }

  static bool _equal(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void paint(int x, int y, int color, {bool fill = false}) {
    if (x < 0 || y < 0 || x >= width || y >= height) {
      return;
    }
    final own = _stroke == null;
    beginStroke();
    final at = y * width + x;
    if (fill) {
      final old = _pixels[at];
      if (old != color) {
        final queue = <int>[at];
        _pixels[at] = color;
        for (var i = 0; i < queue.length; i++) {
          final p = queue[i], px = p % width;
          for (final n in [
            if (px > 0) p - 1,
            if (px + 1 < width) p + 1,
            if (p >= width) p - width,
            if (p + width < _pixels.length) p + width,
          ]) {
            if (_pixels[n] == old) {
              _pixels[n] = color;
              queue.add(n);
            }
          }
        }
      }
    } else {
      _pixels[at] = color;
    }
    if (own) {
      endStroke();
    }
  }

  void clear() {
    beginStroke();
    _pixels = List.filled(width * height, 0);
    endStroke();
  }

  void undo() {
    endStroke();
    if (_undo.isEmpty) {
      return;
    }
    _redo.add(_pixels);
    _pixels = _undo.removeLast();
  }

  void redo() {
    endStroke();
    if (_redo.isEmpty) {
      return;
    }
    _undo.add(_pixels);
    _pixels = _redo.removeLast();
  }

  void replace(int w, int h, List<int> pixels) {
    final length = _validate(w, h);
    if (pixels.length != length) {
      throw const FormatException('画布像素数量不匹配。');
    }
    width = w;
    height = h;
    _pixels = List.of(pixels);
    _undo.clear();
    _redo.clear();
    _stroke = null;
  }

  Map<String, Object> toJson() => {
    'format': 'terraforge.canvas',
    'version': 1,
    'width': width,
    'height': height,
    'pixels': _pixels,
  };
  factory CanvasDocument.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'terraforge.canvas' || json['version'] != 1) {
      throw const FormatException('不支持的工程格式。');
    }
    final result = CanvasDocument(json['width'] as int, json['height'] as int);
    result.replace(
      result.width,
      result.height,
      (json['pixels'] as List).map((e) {
        if (e is! int || e < 0 || e > 0xffffffff) {
          throw const FormatException('像素数据无效。');
        }
        return e;
      }).toList(),
    );
    return result;
  }
}
