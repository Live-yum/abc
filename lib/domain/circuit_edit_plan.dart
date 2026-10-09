import 'dart:math' as math;

import '../engine/circuit_backend.dart';
import 'circuit_document.dart';

enum CircuitClipboardTransform {
  rotateClockwise,
  mirrorHorizontal,
  mirrorVertical,
}

enum CircuitEditKind { removeNetwork, route }

class CircuitSelection {
  final int x, y, width, height;
  const CircuitSelection(this.x, this.y, this.width, this.height);
  bool contains(int px, int py) =>
      px >= x && py >= y && px < x + width && py < y + height;
  Map<String, Object> toJson() =>
      Map.unmodifiable({'x': x, 'y': y, 'width': width, 'height': height});
}

/// An immutable clipboard of the sandbox's current single-cell components.
/// Cell values include the initial device state and timer interval.
class CircuitClipboard {
  final int width, height;
  final Map<int, CircuitCell> cells;
  CircuitClipboard._(this.width, this.height, Map<int, CircuitCell> cells)
    : cells = Map.unmodifiable(cells);

  CircuitClipboard transformed(CircuitClipboardTransform operation) {
    final rotating = operation == CircuitClipboardTransform.rotateClockwise;
    final nextWidth = rotating ? height : width;
    final nextHeight = rotating ? width : height;
    final result = <int, CircuitCell>{};
    for (final entry in cells.entries) {
      // Keep this exhaustive when adding components. Multi-cell or directional
      // devices need a real footprint/orientation transform before inclusion.
      switch (entry.value.element) {
        case CircuitElement.none:
        case CircuitElement.switchInput:
        case CircuitElement.lamp:
        case CircuitElement.timer:
        case CircuitElement.andGate:
        case CircuitElement.orGate:
        case CircuitElement.xorGate:
          break;
      }
      final x = entry.key % width, y = entry.key ~/ width;
      final (nx, ny) = switch (operation) {
        CircuitClipboardTransform.rotateClockwise => (height - 1 - y, x),
        CircuitClipboardTransform.mirrorHorizontal => (width - 1 - x, y),
        CircuitClipboardTransform.mirrorVertical => (x, height - 1 - y),
      };
      result[ny * nextWidth + nx] = entry.value;
    }
    return CircuitClipboard._(nextWidth, nextHeight, result);
  }
}

class CircuitEditPlan {
  final CircuitEditKind kind;
  final int revision, mask;
  final Map<int, int> wireMasks;
  final Map<int, CircuitCell> _changes;
  CircuitEditPlan._(
    this.kind,
    this.revision,
    this.mask,
    Map<int, int> wireMasks,
    Map<int, CircuitCell> changes,
  ) : wireMasks = Map.unmodifiable(wireMasks),
      _changes = Map.unmodifiable(changes);

  Map<String, Object> snapshot({required int currentRevision}) =>
      Map.unmodifiable({
        'kind': kind.name,
        'revision': revision,
        'stale': revision != currentRevision,
        'mask': mask,
        'count': wireMasks.length,
        'indices': List<int>.unmodifiable(wireMasks.keys),
        'masks': List<Map<String, int>>.unmodifiable([
          for (final e in wireMasks.entries)
            Map<String, int>.unmodifiable({'at': e.key, 'mask': e.value}),
        ]),
        'colourCounts': List<int>.unmodifiable([
          for (var colour = 0; colour < 4; colour++)
            wireMasks.values.where((bits) => bits & (1 << colour) != 0).length,
        ]),
      });
}

/// Host edit planning uses actual core traversal for every selected colour.
/// The A* search only chooses new wire positions; it never substitutes a Dart
/// flood fill for native/WASM connectivity. No model or history changes during
/// previews, and a cancelled, superseded or stale preview cannot be committed.
class CircuitEditSession {
  final CircuitDocument document;
  final CircuitBackend backend;
  CircuitSelection? _selection;
  CircuitClipboard? _clipboard;
  CircuitEditPlan? _preview;
  int _generation = 0;
  bool _busy = false;
  static const maxRouteVisits = 60000;
  static const maxRouteLength = 8192;
  static const maxTraversalHits = 256 * 256 * 4 * 2;

  CircuitEditSession(this.document, this.backend);
  CircuitSelection? get selection => _selection;
  CircuitClipboard? get clipboard => _clipboard;
  CircuitEditPlan? get preview => _preview;
  bool get busy => _busy;

  Map<String, Object?> snapshot() => Map.unmodifiable({
    'width': document.width,
    'height': document.height,
    'revision': document.revision,
    'busy': busy,
    'selection': _selection?.toJson(),
    'clipboard': _clipboard == null
        ? null
        : Map<String, int>.unmodifiable({
            'width': _clipboard!.width,
            'height': _clipboard!.height,
            'count': _clipboard!.cells.length,
          }),
    'preview': _preview?.snapshot(currentRevision: document.revision),
  });

  CircuitSelection selectRect(int x, int y, int width, int height) {
    _checkRect(x, y, width, height);
    cancelPreview();
    return _selection = CircuitSelection(x, y, width, height);
  }

  void _checkRect(int x, int y, int width, int height) {
    if (width < 1 ||
        height < 1 ||
        !document.contains(x, y) ||
        !document.contains(x + width - 1, y + height - 1)) {
      throw RangeError('选区或粘贴区域超出电路画布');
    }
  }

  CircuitClipboard _captureSelection() {
    final r = _selection;
    if (r == null) throw StateError('请先选择电路区域');
    final cells = <int, CircuitCell>{};
    for (final entry in document.cells.entries) {
      final x = entry.key % document.width, y = entry.key ~/ document.width;
      if (r.contains(x, y)) cells[(y - r.y) * r.width + x - r.x] = entry.value;
    }
    return CircuitClipboard._(r.width, r.height, cells);
  }

  CircuitClipboard copySelection() {
    final clip = _captureSelection();
    cancelPreview();
    return _clipboard = clip;
  }

  bool cutSelection() {
    final clip = _captureSelection(), r = _selection!;
    final changes = <int, CircuitCell>{
      for (final key in clip.cells.keys)
        (r.y + key ~/ r.width) * document.width + r.x + key % r.width:
            const CircuitCell(),
    };
    final changed = document.applyCells(
      changes,
      expectedRevision: document.revision,
    );
    _clipboard = clip;
    cancelPreview();
    return changed;
  }

  CircuitClipboard transformClipboard(CircuitClipboardTransform operation) {
    final clip = _clipboard;
    if (clip == null) throw StateError('请先复制选区');
    final transformed = clip.transformed(operation);
    cancelPreview();
    return _clipboard = transformed;
  }

  /// Paste replaces the full clipboard rectangle, including its empty cells.
  /// It never crops a footprint at the canvas edge or merges hidden settings.
  bool pasteClipboard(int x, int y) {
    final clip = _clipboard;
    if (clip == null) throw StateError('剪贴板为空');
    _checkRect(x, y, clip.width, clip.height);
    final changes = <int, CircuitCell>{};
    for (var cy = 0; cy < clip.height; cy++) {
      for (var cx = 0; cx < clip.width; cx++) {
        changes[(y + cy) * document.width + x + cx] =
            clip.cells[cy * clip.width + cx] ?? const CircuitCell();
      }
    }
    final changed = document.applyCells(
      changes,
      expectedRevision: document.revision,
    );
    _selection = CircuitSelection(x, y, clip.width, clip.height);
    cancelPreview();
    return changed;
  }

  void cancelPreview() {
    _generation++;
    _busy = false;
    _preview = null;
  }

  bool confirmPreview() {
    if (_busy) throw StateError('预览尚未完成');
    final plan = _preview;
    if (plan == null) throw StateError('没有待确认的电路预览');
    cancelPreview();
    return document.applyCells(plan._changes, expectedRevision: plan.revision);
  }

  void _checkSeed(int x, int y, int mask) {
    if (!document.contains(x, y)) throw RangeError('电路端点越界');
    if (mask < 1 || mask > 15) throw RangeError('请至少选择一种原版线色');
  }

  Future<CircuitEditPlan?> previewNetwork(int x, int y, int mask) {
    _checkSeed(x, y, mask);
    return _plan((cells, revision, generation) async {
      final network = await _trace(cells, [(x, y)], mask, revision, generation);
      if (network.isEmpty) throw StateError('此坐标没有所选颜色的电线');
      return CircuitEditPlan._(
        CircuitEditKind.removeNetwork,
        revision,
        mask,
        network,
        {
          for (final e in network.entries)
            e.key: cells[e.key]!.copyWith(
              wires: cells[e.key]!.wires & ~e.value,
            ),
        },
      );
    });
  }

  Future<CircuitEditPlan?> previewRoute(
    int startX,
    int startY,
    int endX,
    int endY,
    int mask, {
    int margin = 64,
    int visitLimit = maxRouteVisits,
  }) {
    _checkSeed(startX, startY, mask);
    _checkSeed(endX, endY, mask);
    if (margin < 0 ||
        margin > 256 ||
        visitLimit < 1 ||
        visitLimit > maxRouteVisits) {
      throw RangeError('自动布线搜索预算无效');
    }
    return _plan((cells, revision, generation) async {
      final allowed = await _trace(
        cells,
        [(startX, startY), (endX, endY)],
        mask,
        revision,
        generation,
      );
      final path = await _findPath(
        cells,
        allowed,
        startX,
        startY,
        endX,
        endY,
        mask,
        margin,
        visitLimit,
        revision,
        generation,
      );
      return CircuitEditPlan._(
        CircuitEditKind.route,
        revision,
        mask,
        {for (final key in path) key: mask},
        {
          for (final key in path)
            key: (cells[key] ?? const CircuitCell()).copyWith(
              wires: (cells[key]?.wires ?? 0) | mask,
            ),
        },
      );
    });
  }

  Future<CircuitEditPlan?> _plan(
    Future<CircuitEditPlan> Function(Map<int, CircuitCell>, int, int) build,
  ) async {
    cancelPreview();
    final generation = _generation, revision = document.revision;
    final cells = document.cells;
    _busy = true;
    try {
      final plan = await build(cells, revision, generation);
      _checkCurrent(revision, generation);
      return _preview = plan;
    } on _CancelledPreview {
      return null;
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  void _checkCurrent(int revision, int generation) {
    if (generation != _generation) throw const _CancelledPreview();
    if (revision != document.revision) throw StateError('电路已改变，请重新预览');
  }

  Future<Map<int, int>> _trace(
    Map<int, CircuitCell> cells,
    List<(int, int)> seeds,
    int mask,
    int revision,
    int generation,
  ) async {
    final network = <int, int>{};
    final packed = <int>[
      for (final e in cells.entries.where((e) => e.value.wires != 0)) ...[
        e.key % document.width,
        e.key ~/ document.width,
        e.value.wires,
        e.value.element == CircuitElement.none ? 0 : 1,
      ],
    ];
    var totalHits = 0;
    for (var colour = 0; colour < 4; colour++) {
      final bit = 1 << colour;
      if (mask & bit == 0) continue;
      for (final (x, y) in seeds) {
        _checkCurrent(revision, generation);
        final seed = y * document.width + x;
        if ((cells[seed]?.wires ?? 0) & bit == 0 ||
            (network[seed] ?? 0) & bit != 0) {
          continue;
        }
        final hits = await backend.propagate(
          document.width,
          document.height,
          packed,
          x,
          y,
          colour,
        );
        _checkCurrent(revision, generation);
        totalHits += hits.length;
        if (hits.length > cells.length || totalHits > maxTraversalHits) {
          throw StateError('网络追踪超过安全预算');
        }
        if (!hits.contains(seed)) throw StateError('引擎追踪缺少起始电线');
        for (final key in hits) {
          if (key < 0 ||
              key >= document.width * document.height ||
              (cells[key]?.wires ?? 0) & bit == 0) {
            throw StateError('引擎返回了无效的网络电线');
          }
          network[key] = (network[key] ?? 0) | bit;
        }
      }
    }
    return network;
  }

  Future<List<int>> _findPath(
    Map<int, CircuitCell> cells,
    Map<int, int> allowed,
    int sx,
    int sy,
    int ex,
    int ey,
    int mask,
    int margin,
    int visitLimit,
    int revision,
    int generation,
  ) async {
    final width = document.width;
    final start = sy * width + sx, end = ey * width + ex;
    final x0 = math.max(0, math.min(sx, ex) - margin);
    final y0 = math.max(0, math.min(sy, ey) - margin);
    final x1 = math.min(width - 1, math.max(sx, ex) + margin);
    final y1 = math.min(document.height - 1, math.max(sy, ey) + margin);
    bool unrelated(int key) =>
        (cells[key]?.wires ?? 0) & mask & ~(allowed[key] ?? 0) != 0;
    bool safe(int x, int y) {
      final key = y * width + x;
      if (key != start &&
          key != end &&
          cells[key]?.element != null &&
          cells[key]!.element != CircuitElement.none &&
          !allowed.containsKey(key)) {
        return false;
      }
      if (unrelated(key)) return false;
      // Even endpoints must not create a new short into an adjacent network.
      for (final (dx, dy) in _directions) {
        if (document.contains(x + dx, y + dy) &&
            unrelated((y + dy) * width + x + dx)) {
          return false;
        }
      }
      return true;
    }

    if (!safe(sx, sy) || !safe(ex, ey)) {
      throw StateError('端点紧邻无关的同色网络；请调整端点');
    }
    int distance(int x, int y) => ((ex - x).abs() + (ey - y).abs()) * 100;
    final heap = _RouteHeap();
    final best = <int, int>{start * 5: 0};
    heap.add(_RouteNode(start, -1, 0, distance(sx, sy), null));
    var visits = 0;
    while (heap.isNotEmpty) {
      if (++visits > visitLimit) throw StateError('自动布线搜索达到上限，请缩短距离或分段布线');
      if (visits % 1024 == 0) {
        await Future<void>.delayed(Duration.zero);
        _checkCurrent(revision, generation);
      }
      final node = heap.removeFirst();
      if ((best[node.key * 5 + node.direction + 1] ?? node.cost) < node.cost) {
        continue;
      }
      if (node.key == end) {
        final path = <int>[];
        for (_RouteNode? p = node; p != null; p = p.parent) {
          if (path.length >= maxRouteLength) {
            throw StateError('自动布线路径超过 8192 格，请分段布线');
          }
          path.add(p.key);
        }
        return path.reversed.toList();
      }
      final px = node.key % width, py = node.key ~/ width;
      for (var direction = 0; direction < _directions.length; direction++) {
        final (dx, dy) = _directions[direction];
        final x = px + dx, y = py + dy;
        if (x < x0 || x > x1 || y < y0 || y > y1 || !safe(x, y)) continue;
        final key = y * width + x;
        final cost =
            node.cost +
            100 +
            (node.direction >= 0 && node.direction != direction ? 15 : 0);
        final state = key * 5 + direction + 1;
        if (cost >= (best[state] ?? 0x3fffffff)) continue;
        best[state] = cost;
        heap.add(_RouteNode(key, direction, cost, cost + distance(x, y), node));
      }
    }
    throw StateError('没有找到不会短接其他网络的路径，请调整端点或手工布线');
  }
}

const _directions = [(0, 1), (0, -1), (1, 0), (-1, 0)];

class _CancelledPreview implements Exception {
  const _CancelledPreview();
}

class _RouteNode {
  final int key, direction, cost, estimate;
  final _RouteNode? parent;
  int order = 0;
  _RouteNode(this.key, this.direction, this.cost, this.estimate, this.parent);
}

class _RouteHeap {
  final List<_RouteNode> _items = [];
  int _serial = 0;
  bool get isNotEmpty => _items.isNotEmpty;
  bool _less(_RouteNode a, _RouteNode b) =>
      a.estimate < b.estimate || a.estimate == b.estimate && a.order < b.order;
  void add(_RouteNode value) {
    value.order = _serial++;
    var index = _items.length;
    _items.add(value);
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (!_less(value, _items[parent])) break;
      _items[index] = _items[parent];
      index = parent;
    }
    _items[index] = value;
  }

  _RouteNode removeFirst() {
    final result = _items.first, last = _items.removeLast();
    if (_items.isEmpty) return result;
    var index = 0;
    while (index * 2 + 1 < _items.length) {
      var child = index * 2 + 1;
      if (child + 1 < _items.length &&
          _less(_items[child + 1], _items[child])) {
        child++;
      }
      if (!_less(_items[child], last)) break;
      _items[index] = _items[child];
      index = child;
    }
    _items[index] = last;
    return result;
  }
}
