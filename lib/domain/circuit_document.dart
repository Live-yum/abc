import '../engine/circuit_backend.dart';

enum CircuitElement { none, switchInput, lamp, timer, andGate, orGate, xorGate }

class CircuitCell {
  final int wires;
  final CircuitElement element;
  final bool initialOn;
  final int interval;
  const CircuitCell({
    this.wires = 0,
    this.element = CircuitElement.none,
    this.initialOn = false,
    this.interval = 60,
  });
  CircuitCell copyWith({
    int? wires,
    CircuitElement? element,
    bool? initialOn,
    int? interval,
  }) => CircuitCell(
    wires: wires ?? this.wires,
    element: element ?? this.element,
    initialOn: initialOn ?? this.initialOn,
    interval: interval ?? this.interval,
  );
  bool get isGate => element.index >= CircuitElement.andGate.index;
  Map<String, Object> toJson(int index) => {
    'at': index,
    'wires': wires,
    'element': element.name,
    'on': initialOn,
    'interval': interval,
  };
  @override
  bool operator ==(Object other) =>
      other is CircuitCell &&
      wires == other.wires &&
      element == other.element &&
      initialOn == other.initialOn &&
      interval == other.interval;
  @override
  int get hashCode => Object.hash(wires, element, initialOn, interval);
}

/// Original bounded component sandbox format; this is not a WLD save codec.
class CircuitDocument {
  final int width, height;
  Map<int, CircuitCell> _cells = {};
  final List<Map<int, CircuitCell>> _undo = [], _redo = [];
  Map<int, CircuitCell>? _stroke;
  int revision = 0;
  static const maxHistoryBytes = 32 * 1024 * 1024;
  final int historyBudgetBytes;
  CircuitDocument({
    this.width = 32,
    this.height = 24,
    this.historyBudgetBytes = maxHistoryBytes,
  }) {
    if (historyBudgetBytes < 0 || historyBudgetBytes > maxHistoryBytes) {
      throw ArgumentError.value(historyBudgetBytes, 'historyBudgetBytes');
    }
    if (width < 1 || height < 1 || width > 256 || height > 256) {
      throw const FormatException('电路尺寸须为 1–256');
    }
  }
  Map<int, CircuitCell> get cells => Map.unmodifiable(_cells);
  CircuitCell cell(int x, int y) => contains(x, y)
      ? _cells[y * width + x] ?? const CircuitCell()
      : const CircuitCell();
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool contains(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;
  void beginStroke() {
    _stroke ??= Map.of(_cells);
  }

  void endStroke() {
    final before = _stroke;
    _stroke = null;
    if (before == null || _equal(before, _cells)) return;
    _undo.add(before);
    _redo.clear();
    _trimHistory();
  }

  // Conservative accounting for a sparse map entry, cell and map overhead.
  static int _historySize(Map<int, CircuitCell> cells) =>
      64 + cells.length * 128;
  void _trimHistory() {
    var bytes = [
      ..._undo,
      ..._redo,
    ].fold<int>(0, (n, p) => n + _historySize(p));
    while (_undo.length + _redo.length > 50 || bytes > historyBudgetBytes) {
      final oldest = _undo.isNotEmpty ? _undo.removeAt(0) : _redo.removeAt(0);
      bytes -= _historySize(oldest);
    }
  }

  static bool _equal(Map<int, CircuitCell> a, Map<int, CircuitCell> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Commit a validated sparse edit as exactly one history entry. Plan callers
  /// must provide the revision they previewed; stale plans never partly apply.
  bool applyCells(
    Map<int, CircuitCell> changes, {
    required int expectedRevision,
  }) {
    if (revision != expectedRevision) throw StateError('电路已改变，请重新预览');
    if (_stroke != null) throw StateError('请先完成当前笔画');
    for (final entry in changes.entries) {
      if (entry.key < 0 ||
          entry.key >= width * height ||
          entry.value.wires < 0 ||
          entry.value.wires > 15 ||
          entry.value.interval < 1 ||
          entry.value.interval > 3600) {
        throw const FormatException('电路编辑包含无效坐标或设置');
      }
    }
    final next = Map<int, CircuitCell>.of(_cells);
    for (final entry in changes.entries) {
      if (entry.value.wires == 0 &&
          entry.value.element == CircuitElement.none) {
        next.remove(entry.key);
      } else {
        next[entry.key] = entry.value;
      }
    }
    if (_equal(_cells, next)) return false;
    _undo.add(_cells);
    _cells = next;
    _redo.clear();
    _trimHistory();
    revision++;
    return true;
  }

  void _edit(int x, int y, CircuitCell value) {
    if (!contains(x, y)) return;
    if (cell(x, y) == value) return;
    final own = _stroke == null;
    beginStroke();
    final key = y * width + x;
    if (value.wires == 0 && value.element == CircuitElement.none) {
      _cells.remove(key);
    } else {
      _cells[key] = value;
    }
    revision++;
    if (own) endStroke();
  }

  void paintWire(int x, int y, int colour, {bool erase = false}) {
    if (colour < 0 || colour > 3) throw ArgumentError.value(colour);
    final old = cell(x, y);
    _edit(
      x,
      y,
      old.copyWith(
        wires: erase ? old.wires & ~(1 << colour) : old.wires | (1 << colour),
      ),
    );
  }

  void placeElement(
    int x,
    int y,
    CircuitElement element, {
    bool initialOn = false,
    int interval = 60,
  }) {
    if (interval < 1 || interval > 3600) throw ArgumentError.value(interval);
    _edit(
      x,
      y,
      cell(
        x,
        y,
      ).copyWith(element: element, initialOn: initialOn, interval: interval),
    );
  }

  void erase(int x, int y) => _edit(x, y, const CircuitCell());
  void clear() {
    beginStroke();
    _cells = {};
    revision++;
    endStroke();
  }

  void undo() {
    endStroke();
    if (_undo.isEmpty) return;
    _redo.add(Map.of(_cells));
    _cells = _undo.removeLast();
    _trimHistory();
    revision++;
  }

  void redo() {
    endStroke();
    if (_redo.isEmpty) return;
    _undo.add(Map.of(_cells));
    _cells = _redo.removeLast();
    _trimHistory();
    revision++;
  }

  List<int> get nativeCells {
    final entries = _cells.entries.where((e) => e.value.wires != 0).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final e in entries) ...[
        e.key % width,
        e.key ~/ width,
        e.value.wires,
        e.value.element == CircuitElement.none ? 0 : 1,
      ],
    ];
  }

  Map<String, Object> toJson() => {
    'format': 'terraforge.circuit',
    'version': 1,
    'width': width,
    'height': height,
    'cells': [for (final e in _cells.entries) e.value.toJson(e.key)],
  };
  factory CircuitDocument.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'terraforge.circuit' ||
        json['version'] != 1 ||
        json['width'] is! int ||
        json['height'] is! int ||
        json['cells'] is! List) {
      throw const FormatException('不支持的电路工程格式');
    }
    final doc = CircuitDocument(
      width: json['width'] as int,
      height: json['height'] as int,
    );
    final cells = json['cells'] as List;
    if (cells.length > doc.width * doc.height) {
      throw const FormatException('电路数量超限');
    }
    for (final raw in cells) {
      if (raw is! Map ||
          raw['at'] is! int ||
          raw['wires'] is! int ||
          raw['element'] is! String ||
          raw['on'] is! bool ||
          raw['interval'] is! int) {
        throw const FormatException('电路元件记录无效');
      }
      // This version represents one-cell components only. Do not silently
      // import a future footprint and then rotate/copy just its anchor.
      if ((raw.containsKey('width') && raw['width'] != 1) ||
          (raw.containsKey('height') && raw['height'] != 1) ||
          (raw.containsKey('footprintWidth') && raw['footprintWidth'] != 1) ||
          (raw.containsKey('footprintHeight') && raw['footprintHeight'] != 1)) {
        throw const FormatException('当前电路格式不支持多格元件');
      }
      final at = raw['at'] as int,
          wires = raw['wires'] as int,
          interval = raw['interval'] as int;
      final types = CircuitElement.values.where(
        (e) => e.name == raw['element'],
      );
      if (at < 0 ||
          at >= doc.width * doc.height ||
          doc._cells.containsKey(at) ||
          wires < 0 ||
          wires > 15 ||
          interval < 1 ||
          interval > 3600 ||
          types.isEmpty) {
        throw const FormatException('电路坐标、线路或元件无效');
      }
      doc._cells[at] = CircuitCell(
        wires: wires,
        element: types.single,
        initialOn: raw['on'] as bool,
        interval: interval,
      );
    }
    return doc;
  }
}

/// Actual native/WASM traversal drives this explicitly limited host device set.
/// Gates read a contiguous vertical stack of lamps immediately above them.
/// XOR follows Terraria's exactly-one-input rule. This does not claim full
/// Terraria device/world compatibility (faulty lamps, actuators, pixels, etc.).
class CircuitSimulator {
  final CircuitDocument document;
  final CircuitBackend backend;
  final Map<int, bool> _states = {};
  final Map<int, int> _timerAge = {};
  final Set<int> _trace = {}, _smoke = {};
  int tick = 0, _revision = -1;
  bool busy = false;
  CircuitSimulator(this.document, this.backend);
  Map<int, bool> get states => Map.unmodifiable(_states);
  Set<int> get trace => Set.unmodifiable(_trace);
  Set<int> get smoke => Set.unmodifiable(_smoke);
  bool isOn(int x, int y) =>
      _states[y * document.width + x] ?? document.cell(x, y).initialOn;
  void reset() {
    if (busy) throw StateError('电路正在执行');
    _reset();
  }

  void _reset() {
    _states
      ..clear()
      ..addEntries(
        document._cells.entries.map((e) => MapEntry(e.key, e.value.initialOn)),
      );
    _timerAge.clear();
    _trace.clear();
    _smoke.clear();
    tick = 0;
    _revision = document.revision;
    for (final e in document._cells.entries.where((e) => e.value.isGate)) {
      _states[e.key] = _gateValue(e.key, e.value);
    }
  }

  bool _gateValue(int key, CircuitCell gate) {
    var total = 0, on = 0;
    for (var p = key - document.width; p >= 0; p -= document.width) {
      if (document._cells[p]?.element != CircuitElement.lamp) break;
      total++;
      if (_states[p] ?? false) on++;
    }
    if (total == 0) return false;
    return switch (gate.element) {
      CircuitElement.andGate => on == total,
      CircuitElement.orGate => on > 0,
      CircuitElement.xorGate => on == 1,
      _ => false,
    };
  }

  Future<void> _atomic(Future<void> Function() action) async {
    if (busy) throw StateError('电路正在执行');
    if (_revision != document.revision) _reset();
    final before = Map<int, bool>.of(_states),
        ages = Map<int, int>.of(_timerAge);
    final trace = Set<int>.of(_trace),
        smoke = Set<int>.of(_smoke),
        oldTick = tick;
    busy = true;
    _trace.clear();
    _smoke.clear();
    try {
      await action();
      if (_revision != document.revision) throw StateError('执行期间电路已改变，请重试');
    } catch (_) {
      _states
        ..clear()
        ..addAll(before);
      _timerAge
        ..clear()
        ..addAll(ages);
      _trace
        ..clear()
        ..addAll(trace);
      _smoke
        ..clear()
        ..addAll(smoke);
      tick = oldTick;
      rethrow;
    } finally {
      busy = false;
    }
  }

  Future<void> trigger(int x, int y) => _atomic(() async {
    if (!document.contains(x, y)) throw RangeError('触发坐标越界');
    final key = y * document.width + x, device = document.cell(x, y);
    if (device.element == CircuitElement.timer) {
      _states[key] = !(_states[key] ?? false);
      _timerAge[key] = 0;
    } else {
      await _pulse(key);
    }
  });

  /// Exactly one 60 Hz mechanical tick. The UI may schedule ticks but cannot
  /// synthesize device state; a failed native call rolls back the complete tick.
  Future<void> step() => _atomic(() async {
    tick++;
    for (final e in document._cells.entries) {
      if (e.value.element != CircuitElement.timer ||
          !(_states[e.key] ?? false)) {
        continue;
      }
      final age = (_timerAge[e.key] ?? 0) + 1;
      _timerAge[e.key] = age % e.value.interval;
      if (age >= e.value.interval) await _pulse(e.key);
    }
  });
  Future<void> _pulse(int source) async {
    final queue = <List<int>>[
          [source],
        ],
        fired = <int>{};
    var pulses = 0;
    final cells = document.nativeCells;
    for (var wave = 0; wave < queue.length; wave++) {
      for (final seed in queue[wave]) {
        if (++pulses > 1024) throw StateError('电路门传播超过安全预算');
        final sx = seed % document.width, sy = seed ~/ document.width;
        for (var colour = 0; colour < 4; colour++) {
          if ((document.cell(sx, sy).wires & (1 << colour)) == 0) continue;
          final hits = (await backend.propagate(
            document.width,
            document.height,
            cells,
            sx,
            sy,
            colour,
          )).toSet();
          if (_revision != document.revision) throw StateError('执行期间电路已改变');
          _trace.addAll(hits);
          for (final key in hits) {
            if (key < 0 || key >= document.width * document.height) {
              throw StateError('引擎返回无效坐标');
            }
            if (key == seed) continue;
            final element = document._cells[key]?.element;
            if (element == CircuitElement.lamp ||
                element == CircuitElement.timer) {
              _states[key] = !(_states[key] ?? false);
              if (element == CircuitElement.timer) _timerAge[key] = 0;
            }
          }
        }
      }
      // Evaluate only after the entire output wave has completed.
      final next = <int>[];
      for (final e in document._cells.entries.where((e) => e.value.isGate)) {
        final value = _gateValue(e.key, e.value);
        if (value == _states[e.key]) continue;
        _states[e.key] = value;
        if (!fired.add(e.key)) {
          _smoke.add(e.key);
          continue;
        }
        next.add(e.key);
      }
      if (next.isNotEmpty) queue.add(next);
    }
  }
}
