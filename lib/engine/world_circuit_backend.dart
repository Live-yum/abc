import 'dart:typed_data';

/// Real whole-world wiring VM. Sessions retain an immutable original; save
/// returns a candidate WLD for normal validation/adoption, never overwrites it.
abstract interface class WorldCircuitBackend {
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List world, {
    Uint8List? twld,
  });
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  );
  Future<void> closeWorldCircuit(int session);
}

class WorldCircuitCommand {
  final List<int> words;
  final List<int> records;
  WorldCircuitCommand._(List<int> words, [List<int> records = const []])
    : words = List.unmodifiable(words),
      records = List.unmodifiable(records) {
    validateWorldCircuitCommand(this.words, this.records);
  }
  factory WorldCircuitCommand.viewport(
    int x,
    int y,
    int width,
    int height, {
    int stride = 1,
    bool walls = false,
  }) => WorldCircuitCommand._([
    1,
    1,
    x,
    y,
    width,
    height,
    stride,
    0,
    0,
    0,
    0,
    0,
    walls ? 2 : 0,
    0,
    0,
    0,
  ]);
  factory WorldCircuitCommand.trigger(
    int x,
    int y, {
    int width = 1,
    int height = 1,
    int mask = 15,
    int pulses = 1,
    bool hitSwitch = true,
  }) => WorldCircuitCommand._([
    1,
    2,
    x,
    y,
    width,
    height,
    1,
    mask,
    pulses,
    0,
    0,
    0,
    hitSwitch ? 1 : 0,
    0,
    0,
    0,
  ]);
  factory WorldCircuitCommand.ticks(int count) => WorldCircuitCommand._([
    1,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    count,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
  factory WorldCircuitCommand.lamps(List<int> records, {bool write = false}) =>
      WorldCircuitCommand._([
        1,
        write ? 5 : 4,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        records.length ~/ 4,
        0,
        0,
        0,
        0,
        0,
      ], records);
  factory WorldCircuitCommand.save() =>
      WorldCircuitCommand._([1, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 5, 0, 0]);

  /// Geometry is a verified four-word record per occupied object cell. The
  /// engine retains the first set for this session; subsequent pages omit it.
  factory WorldCircuitCommand.fragments({
    int offset = 0,
    int count = 256,
    List<int> geometry = const [],
  }) => WorldCircuitCommand._([
    1,
    7,
    offset,
    0,
    0,
    0,
    1,
    0,
    count,
    0,
    geometry.length ~/ 4,
    0,
    0,
    0,
    0,
    0,
  ], geometry);

  factory WorldCircuitCommand.extract(
    int fragmentId, {
    int maxCells = 32768,
    bool withObjects = true,
    int maxObjectBytes = 4 * 1024 * 1024,
    int maxObjects = 32768,
  }) => WorldCircuitCommand._([
    1,
    8,
    0,
    0,
    withObjects ? maxObjectBytes : 0,
    withObjects ? maxObjects : 0,
    1,
    fragmentId,
    maxCells,
    0,
    0,
    0,
    withObjects ? 1 : 0,
    withObjects ? 6 : 0,
    0,
    0,
  ]);
  bool get mutates => words[1] == 2 || words[1] == 3 || words[1] == 5;
}

class WorldCircuitResult {
  final int session;
  final List<int> stats;
  final Uint8List records;
  final Uint8List? world;
  final Uint8List? twld;

  /// The terminal READY metadata, not a RESULT batch's page count.
  final int resultKind, resultCount, reserved;
  final Uint8List? objects;
  const WorldCircuitResult(
    this.session,
    this.stats,
    this.records, {
    this.world,
    this.twld,
    this.resultKind = 0,
    this.resultCount = 0,
    this.reserved = 0,
    this.objects,
  });
  factory WorldCircuitResult.fromMap(Map<dynamic, dynamic> map) =>
      WorldCircuitResult(
        map['session'] as int,
        (map['stats'] as List).cast<int>(),
        map['records'] as Uint8List,
        world: map['world'] as Uint8List?,
        twld: map['twld'] as Uint8List?,
        resultKind: map['resultKind'] as int? ?? 0,
        resultCount: map['resultCount'] as int? ?? 0,
        reserved: map['reserved'] as int? ?? 0,
        objects: map['objects'] as Uint8List?,
      );
  int get width => stats[2];
  int get height => stats[3];
  int get devices => stats[11];
  int get networks => stats[13];
  int get ticks => stats[18] + (stats[19] << 32);
}

/// Wire validation is shared by command construction and the isolate boundary.
void validateWorldCircuitCommand(List<int> words, List<int> records) {
  if (words.length != 16 ||
      words[0] != 1 ||
      words[1] < 1 ||
      words[1] > 8 ||
      words[9] != 0 ||
      words[14] != 0 ||
      words[15] != 0 ||
      words[10] * 4 != records.length ||
      records.length > 65536 * 4 ||
      [...words, ...records].any((v) => v < 0 || v > 0xffffffff)) {
    throw const FormatException('Invalid circuit command');
  }
  if (words[1] == 7 || words[1] == 8) {
    if (words[8] < 1 || words[8] > 32768) {
      throw const FormatException(
        'Circuit fragments are limited to 32768 records',
      );
    }
    if (words[1] == 7) {
      for (var i = 0; i < records.length; i += 4) {
        final shape = records[i + 2],
            width = (shape >> 16) & 255,
            height = shape >> 24;
        if (records[i] > 65535 ||
            width == 0 ||
            height == 0 ||
            (shape & 255) >= width ||
            ((shape >> 8) & 255) >= height ||
            records[i + 3] > 17) {
          throw const FormatException('Invalid circuit object geometry');
        }
      }
    } else if (records.isNotEmpty ||
        words[12] > 1 ||
        (words[12] == 1 &&
            (words[13] != 6 ||
                words[4] < 32 ||
                words[4] > 4 * 1024 * 1024 ||
                words[5] < 1 ||
                words[5] > 32768)) ||
        (words[12] == 0 && words[13] != 0)) {
      throw const FormatException('Invalid circuit companion extraction');
    }
  }
}

class WorldCircuitFragment {
  final int id, x, y, width, height, cells, wireCells, flags;
  const WorldCircuitFragment({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.cells,
    required this.wireCells,
    required this.flags,
  });
  bool get completeFootprint => (flags & 1) == 0;
  bool get requiresObjects => (flags & 2) != 0;
  bool get isModded => (flags & 4) != 0;
  bool get missingSupport => (flags & 8) != 0;
  bool get canStamp => completeFootprint && !isModded && !missingSupport;
}

class WorldCircuitFragmentPage {
  final int offset, total;
  final List<WorldCircuitFragment> fragments;
  WorldCircuitFragmentPage._(
    this.offset,
    this.total,
    List<WorldCircuitFragment> fragments,
  ) : fragments = List.unmodifiable(fragments);
  bool get hasMore => offset + fragments.length < total;
  factory WorldCircuitFragmentPage.fromResult(
    WorldCircuitResult result, {
    required int offset,
    required int count,
  }) {
    if (result.resultKind != 7 ||
        result.records.length % 32 != 0 ||
        result.records.length ~/ 32 > count ||
        count < 1 ||
        count > 32768 ||
        result.resultCount < 0 ||
        offset < 0 ||
        offset > 0xffffffff ||
        result.stats.length < 4 ||
        result.records.length ~/ 32 !=
            (offset >= result.resultCount
                ? 0
                : (result.resultCount - offset < count
                      ? result.resultCount - offset
                      : count)) ||
        (result.records.isNotEmpty &&
            offset + result.records.length ~/ 32 > result.resultCount)) {
      throw const FormatException('Invalid circuit fragment page');
    }
    final data = ByteData.sublistView(result.records), ids = <int>{};
    final fragments = <WorldCircuitFragment>[];
    for (var i = 0; i < result.records.length; i += 32) {
      int word(int n) => data.getUint32(i + n * 4, Endian.little);
      final fragment = WorldCircuitFragment(
        id: word(0),
        x: word(1),
        y: word(2),
        width: word(3),
        height: word(4),
        cells: word(5),
        wireCells: word(6),
        flags: word(7),
      );
      if (!ids.add(fragment.id) ||
          fragment.width == 0 ||
          fragment.height == 0 ||
          fragment.x + fragment.width > result.width ||
          fragment.y + fragment.height > result.height ||
          fragment.cells == 0 ||
          fragment.cells > fragment.width * fragment.height ||
          fragment.wireCells > fragment.cells ||
          fragment.flags > 15) {
        throw const FormatException('Invalid circuit fragment descriptor');
      }
      fragments.add(fragment);
    }
    return WorldCircuitFragmentPage._(offset, result.resultCount, fragments);
  }
}

/// One immutable extraction, independent of future commands and output sinks.
/// Records use local coordinates; the COB1 header retains its source origin.
class WorldCircuitExtraction {
  final WorldCircuitFragment fragment;
  final Uint8List _records;
  final Uint8List? _objects;
  WorldCircuitExtraction._(this.fragment, this._records, this._objects);
  Uint8List get records => Uint8List.fromList(_records);
  Uint8List? get objects =>
      _objects == null ? null : Uint8List.fromList(_objects);
  int get recordCount => _records.length ~/ 32;
  int get objectCount => _objects == null
      ? 0
      : ByteData.sublistView(_objects).getUint32(12, Endian.little);
  bool get canStamp =>
      fragment.canStamp && (!fragment.requiresObjects || objectCount > 0);

  factory WorldCircuitExtraction.fromResult(
    WorldCircuitResult result,
    WorldCircuitFragment fragment, {
    bool requireObjects = true,
  }) {
    if (result.resultKind != 8 ||
        result.resultCount < 1 ||
        result.resultCount > 32768 ||
        result.records.length != result.resultCount * 32 ||
        result.resultCount != fragment.cells ||
        (requireObjects && result.objects == null)) {
      throw const FormatException('Incomplete circuit extraction');
    }
    final records = Uint8List.fromList(result.records),
        data = ByteData.sublistView(records);
    var previousX = -1, previousY = -1;
    for (var at = 0; at < records.length; at += 32) {
      final x = data.getUint32(at, Endian.little),
          y = data.getUint32(at + 4, Endian.little),
          flags = data.getUint32(at + 8, Endian.little) >> 16,
          layers = data.getUint32(at + 20, Endian.little);
      if (x < fragment.x ||
          y < fragment.y ||
          x >= fragment.x + fragment.width ||
          y >= fragment.y + fragment.height ||
          x < previousX ||
          (x == previousX && y <= previousY) ||
          flags > 127 ||
          (layers >> 24) > 15 ||
          ((layers >> 8) & 255) > 4 ||
          ((layers >> 16) & 255) > 7 ||
          (((layers & 255) == 0) != (((layers >> 8) & 255) == 0)) ||
          data.getUint32(at + 24, Endian.little) != 0 ||
          data.getUint32(at + 28, Endian.little) != 0) {
        throw const FormatException('Invalid circuit extraction records');
      }
      previousX = x;
      previousY = y;
      data.setUint32(at, x - fragment.x, Endian.little);
      data.setUint32(at + 4, y - fragment.y, Endian.little);
    }
    final objects = result.objects == null
        ? null
        : Uint8List.fromList(result.objects!);
    if (objects != null) {
      validateWorldCircuitObjects(
        objects,
        originX: fragment.x,
        originY: fragment.y,
        width: fragment.width,
        height: fragment.height,
      );
      final count = ByteData.sublistView(objects).getUint32(12, Endian.little);
      if (fragment.requiresObjects && count == 0) {
        throw const FormatException('Missing section-backed circuit objects');
      }
    } else if (fragment.requiresObjects) {
      throw const FormatException(
        'Circuit fragment requires its object companion',
      );
    }
    return WorldCircuitExtraction._(fragment, records, objects);
  }
}

void validateWorldCircuitObjects(
  Uint8List bytes, {
  int? originX,
  int? originY,
  int? width,
  int? height,
  int maxBytes = 4 * 1024 * 1024,
  int maxObjects = 32768,
}) {
  if (bytes.length < 32 || bytes.length > maxBytes) {
    throw const FormatException('Invalid circuit object companion size');
  }
  final d = ByteData.sublistView(bytes);
  int word(int at) => d.getUint32(at, Endian.little);
  final count = word(12);
  if (word(0) != 0x31424f43 ||
      word(4) != 1 ||
      word(16) != bytes.length ||
      count > maxObjects ||
      word(28) != 0 ||
      (originX != null && word(20) != originX) ||
      (originY != null && word(24) != originY)) {
    throw const FormatException('Invalid circuit COB1 companion');
  }
  var at = 32;
  for (var i = 0; i < count; i++) {
    if (at + 32 > bytes.length) {
      throw const FormatException('Truncated circuit object');
    }
    final section = word(at), kind = word(at + 4), size = word(at + 20);
    if ((section != 2 && section != 3 && section != 5) ||
        (section != 5 && kind != 0) ||
        (section == 5 && kind > 10) ||
        word(at + 16) > 65535 ||
        word(at + 24) != 0 ||
        word(at + 28) != 0 ||
        (width != null && word(at + 8) >= width) ||
        (height != null && word(at + 12) >= height) ||
        at + 32 + size > bytes.length) {
      throw const FormatException('Invalid circuit object record');
    }
    at += 32 + size;
  }
  if (at != bytes.length) {
    throw const FormatException('Trailing circuit object data');
  }
}
