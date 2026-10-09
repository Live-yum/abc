import 'dart:convert';
import 'dart:typed_data';

/// Original all-layer editor model. Native validation remains authoritative.
/// Structural object edits are rejected by the core, never silently flattened.
/// Tile records and companion records form one atomic history state.
class AdvancedRegionDocument {
  static const maxHistoryBytes = 32 * 1024 * 1024;
  final int width, height;
  final int historyBudgetBytes;
  final int sourceX, sourceY;
  Uint8List _records;
  Uint8List? _objects;
  final List<_RegionSnapshot> _undo = [], _redo = [];
  int _historyBytes = 0;
  int _revision = 0;
  int get revision => _revision;
  _RegionSnapshot? _strokeBefore;
  bool _strokeOpen = false;
  bool get strokeOpen => _strokeOpen;
  Uint8List? get objects =>
      _objects == null ? null : Uint8List.fromList(_objects!);
  AdvancedRegionDocument({
    required this.width,
    required this.height,
    required Uint8List records,
    Uint8List? objects,
    this.historyBudgetBytes = maxHistoryBytes,
    this.sourceX = 0,
    this.sourceY = 0,
  }) : _records = Uint8List.fromList(records),
       _objects = objects == null ? null : Uint8List.fromList(objects) {
    if (historyBudgetBytes < 0 ||
        historyBudgetBytes > maxHistoryBytes ||
        width < 1 ||
        height < 1 ||
        width > 16384 ||
        height > 16384 ||
        records.isEmpty ||
        records.length % 32 != 0 ||
        records.length > 32 * 1024 * 1024 ||
        sourceX < 0 ||
        sourceY < 0) {
      throw const FormatException('Invalid bounded region');
    }
    final data = ByteData.sublistView(_records);
    int px = -1, py = -1;
    for (var i = 0; i < recordCount; i++) {
      final x = data.getUint32(i * 32, Endian.little),
          y = data.getUint32(i * 32 + 4, Endian.little);
      if (x >= width ||
          y >= height ||
          x < px ||
          (x == px && y <= py) ||
          data.getUint32(i * 32 + 24, Endian.little) != 0 ||
          data.getUint32(i * 32 + 28, Endian.little) != 0) {
        throw const FormatException(
          'Invalid region record order or reserved fields',
        );
      }
      px = x;
      py = y;
      final tile = cellAtIndex(i);
      if (tile['flags']! > 127 ||
          tile['wires']! > 15 ||
          tile['liquidType']! > 4 ||
          tile['slope']! > 7 ||
          ((tile['liquid']! == 0) != (tile['liquidType']! == 0))) {
        throw const FormatException('Invalid tile layers');
      }
    }
    if (objects != null) {
      if (objects.length < 32 || objects.length > 4 * 1024 * 1024) {
        throw const FormatException('Invalid object companion size');
      }
      final d = ByteData.sublistView(objects);
      if (d.getUint32(0, Endian.little) != 0x31424f43 ||
          d.getUint32(4, Endian.little) != 1 ||
          d.getUint32(16, Endian.little) != objects.length ||
          d.getUint32(12, Endian.little) > 32768) {
        throw const FormatException('Invalid COB1 companion');
      }
    }
  }
  Uint8List get records => Uint8List.fromList(_records);
  int get recordCount => _records.length ~/ 32;
  int get contentBytes => _records.length + (_objects?.length ?? 0);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get historyBytes => _historyBytes;
  int get objectCount => _objects == null
      ? 0
      : ByteData.sublistView(_objects!).getUint32(12, Endian.little);
  Map<String, int> cellAtIndex(int index) {
    if (index < 0 || index >= recordCount) {
      throw RangeError.index(index, _records);
    }
    final d = ByteData.sublistView(_records), at = index * 32;
    final type = d.getUint32(at + 8, Endian.little),
        frames = d.getUint32(at + 12, Endian.little),
        wall = d.getUint32(at + 16, Endian.little),
        liquid = d.getUint32(at + 20, Endian.little);
    final flags = type >> 16;
    return {
      'x': d.getUint32(at, Endian.little),
      'y': d.getUint32(at + 4, Endian.little),
      'block': type & 65535,
      'flags': flags,
      'active': flags & 1,
      'actuator': (flags >> 1) & 1,
      'inactive': (flags >> 2) & 1,
      'invisibleBlock': (flags >> 3) & 1,
      'invisibleWall': (flags >> 4) & 1,
      'fullbrightBlock': (flags >> 5) & 1,
      'fullbrightWall': (flags >> 6) & 1,
      'frameX': (frames & 65535).toSigned(16),
      'frameY': (frames >> 16).toSigned(16),
      'wall': wall & 65535,
      'blockPaint': (wall >> 16) & 255,
      'wallPaint': wall >> 24,
      'liquid': liquid & 255,
      'liquidType': (liquid >> 8) & 255,
      'slope': (liquid >> 16) & 255,
      'wires': liquid >> 24,
    };
  }

  int indexAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return -1;
    if (recordCount == width * height) return x * height + y;
    final d = ByteData.sublistView(_records), key = x * height + y;
    var low = 0, high = recordCount - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final value =
          d.getUint32(mid * 32, Endian.little) * height +
          d.getUint32(mid * 32 + 4, Endian.little);
      if (value == key) return mid;
      if (value < key) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  void beginStroke() {
    if (_strokeOpen) return;
    _strokeOpen = true;
    _strokeBefore = null;
  }

  void endStroke() {
    if (!_strokeOpen) return;
    _strokeOpen = false;
    final before = _strokeBefore;
    _strokeBefore = null;
    if (before == null) return;
    _historyBytes -= _redo.fold<int>(0, (n, b) => n + b.byteLength);
    _redo.clear();
    _undo.add(before);
    _historyBytes += before.byteLength;
    _pruneHistory();
  }

  void cancelStroke() {
    if (!_strokeOpen) return;
    _strokeOpen = false;
    if (_strokeBefore != null) {
      _restore(_strokeBefore!);
      _revision++;
    }
    _strokeBefore = null;
  }

  Map<String, int>? cellAt(int x, int y) {
    final i = indexAt(x, y);
    return i < 0 ? null : cellAtIndex(i);
  }

  void setCell(int x, int y, Map<String, int> patch) {
    final i = indexAt(x, y);
    if (i < 0) {
      throw const FormatException('Cell is absent from sparse fragment');
    }
    setCellAtIndex(i, patch);
  }

  void setCellAtIndex(int index, Map<String, int> patch) {
    final cell = cellAtIndex(index);
    const limits = {
      'block': 65535,
      'wall': 65535,
      'blockPaint': 31,
      'wallPaint': 31,
      'liquid': 255,
      'liquidType': 4,
      'slope': 7,
      'wires': 15,
      'active': 1,
      'actuator': 1,
      'inactive': 1,
      'invisibleBlock': 1,
      'invisibleWall': 1,
      'fullbrightBlock': 1,
      'fullbrightWall': 1,
    };
    for (final e in patch.entries) {
      final max = limits[e.key];
      if (max == null || e.value < 0 || e.value > max) {
        throw ArgumentError('Unsupported or out-of-range tile field: ${e.key}');
      }
      cell[e.key] = e.value;
    }
    if (cell['liquid'] == 0) {
      cell['liquidType'] = 0;
    } else if (cell['liquidType'] == 0) {
      cell['liquidType'] = 1;
    }
    if (cell['active'] == 0) {
      cell['block'] = 0;
      cell['blockPaint'] = 0;
      cell['slope'] = 0;
    }
    final at = index * 32;
    final next = ByteData(32);
    next.buffer.asUint8List().setAll(0, _records.sublist(at, at + 32));
    final d = next;

    final flags =
        cell['active']! |
        (cell['actuator']! << 1) |
        (cell['inactive']! << 2) |
        (cell['invisibleBlock']! << 3) |
        (cell['invisibleWall']! << 4) |
        (cell['fullbrightBlock']! << 5) |
        (cell['fullbrightWall']! << 6);
    d.setUint32(8, cell['block']! | (flags << 16), Endian.little);
    d.setUint32(
      16,
      cell['wall']! | (cell['blockPaint']! << 16) | (cell['wallPaint']! << 24),
      Endian.little,
    );
    d.setUint32(
      20,
      cell['liquid']! |
          (cell['liquidType']! << 8) |
          (cell['slope']! << 16) |
          (cell['wires']! << 24),
      Endian.little,
    );
    final bytes = next.buffer.asUint8List();
    var changed = false;
    for (var i = 0; i < 32; i++) {
      if (bytes[i] != _records[at + i]) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    final implicit = !_strokeOpen;
    if (implicit) beginStroke();
    try {
      _remember();
    } catch (_) {
      if (implicit) cancelStroke();
      rethrow;
    }
    _records.setRange(at, at + 32, bytes);
    _revision++;
    if (implicit) endStroke();
  }

  /// Replaces a validated tile/companion candidate in one undoable operation.
  /// Coordinates and record count remain fixed. World writes still need core
  /// validation; new objects must be inserted using their narrow overlay.
  void replaceContent(Uint8List records, {Uint8List? objects}) {
    if (_strokeOpen) {
      throw StateError('Finish the active stroke before replacing records');
    }
    if (records.length != _records.length) {
      throw const FormatException('Replacement must retain all region records');
    }
    if (contentBytes > historyBudgetBytes) {
      throw StateError('Region and object history exceeds the memory budget');
    }
    final candidate = AdvancedRegionDocument(
      width: width,
      height: height,
      sourceX: sourceX,
      sourceY: sourceY,
      records: records,
      objects: objects,
    );
    for (var i = 0; i < records.length; i += 32) {
      for (var k = 0; k < 8; k++) {
        if (records[i + k] != _records[i + k]) {
          throw const FormatException(
            'Replacement must retain region coordinates',
          );
        }
      }
    }
    if (_sameBytes(_records, records) && _sameBytes(_objects, objects)) return;
    // Admit the snapshot before changing either half of the document.
    final before = _snapshot();
    if (before.byteLength > historyBudgetBytes) {
      throw StateError('Region and object history exceeds the memory budget');
    }
    beginStroke();
    _strokeBefore = before;
    _records = candidate._records;
    _objects = candidate._objects;
    _revision++;
    endStroke();
  }

  /// Retains the companion while replacing ordinary layer records.
  void replaceRecords(Uint8List records) =>
      replaceContent(records, objects: _objects);

  _RegionSnapshot _snapshot() => _RegionSnapshot(
    Uint8List.fromList(_records),
    _objects == null ? null : Uint8List.fromList(_objects!),
  );

  void _remember() {
    if (_strokeBefore != null) return;
    if (contentBytes > historyBudgetBytes) {
      throw StateError('Region and object history exceeds the memory budget');
    }
    final before = _snapshot();
    if (before.byteLength > historyBudgetBytes) {
      throw StateError('Region and object history exceeds the memory budget');
    }
    _strokeBefore = before;
  }

  void _restore(_RegionSnapshot state) {
    _records = state.records;
    _objects = state.objects;
  }

  void undo() {
    endStroke();
    if (!canUndo) return;
    final current = _RegionSnapshot(_records, _objects);
    final before = _undo.removeLast();
    _redo.add(current);
    _historyBytes += current.byteLength - before.byteLength;
    _restore(before);
    _pruneHistory();
    _revision++;
  }

  void redo() {
    endStroke();
    if (!canRedo) return;
    final current = _RegionSnapshot(_records, _objects);
    final after = _redo.removeLast();
    _undo.add(current);
    _historyBytes += current.byteLength - after.byteLength;
    _restore(after);
    _pruneHistory();
    _revision++;
  }

  void _pruneHistory() {
    while (_historyBytes > historyBudgetBytes && _undo.isNotEmpty) {
      _historyBytes -= _undo.removeAt(0).byteLength;
    }
    while (_historyBytes > historyBudgetBytes && _redo.isNotEmpty) {
      _historyBytes -= _redo.removeAt(0).byteLength;
    }
  }

  Map<String, dynamic> stampRequest(int x, int y) => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'recordCount': recordCount,
    'recordSourceId': 2,
    'mode': 'overlay',
    if (objectCount > 0) ...{
      'objectSourceId': 3,
      'objectBytes': _objects!.length,
      'objectCount': objectCount,
    },
  };
  String encode() => jsonEncode({
    'format': 'abc-region',
    'version': 1,
    'width': width,
    'height': height,
    'sourceX': sourceX,
    'sourceY': sourceY,
    'records': base64Encode(_records),
    if (_objects != null) 'objects': base64Encode(_objects!),
  });
  factory AdvancedRegionDocument.decode(String text) {
    if (text.length > 50 * 1024 * 1024) {
      throw const FormatException('Region document exceeds budget');
    }
    final map = jsonDecode(text) as Map<String, dynamic>;
    if (map['format'] != 'abc-region' || map['version'] != 1) {
      throw const FormatException('Unsupported region document');
    }
    return AdvancedRegionDocument(
      width: map['width'] as int,
      height: map['height'] as int,
      sourceX: map['sourceX'] as int? ?? 0,
      sourceY: map['sourceY'] as int? ?? 0,
      records: base64Decode(map['records'] as String),
      objects: map['objects'] == null
          ? null
          : base64Decode(map['objects'] as String),
    );
  }
}

class _RegionSnapshot {
  final Uint8List records;
  final Uint8List? objects;
  const _RegionSnapshot(this.records, this.objects);
  int get byteLength => records.length + (objects?.length ?? 0);
}

bool _sameBytes(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
