import 'dart:convert';
import 'dart:typed_data';

import 'chest_tools.dart';
import 'region_document.dart';
import 'resource_catalog.dart';

// WLD 326 companion sections own these fixed complete footprints.
const _objectSizes = <int, (int, int)>{
  21: (2, 2),
  88: (3, 2),
  467: (2, 2),
  55: (2, 2),
  85: (2, 2),
  425: (2, 2),
  573: (2, 2),
  378: (2, 3),
  395: (2, 2),
  423: (1, 1),
  470: (2, 3),
  471: (3, 3),
  475: (3, 4),
  520: (1, 1),
  597: (3, 4),
  698: (1, 2),
  723: (1, 1),
  724: (1, 1),
};
const _containers = {21, 88, 467};
const _signs = {55, 85, 425, 573};
const _entityTiles = [378, 395, 423, 470, 471, 475, 520, 597, 698, 723, 724];

/// One exact release row. Alternate/random indices are identifiers, not inferred
/// directions; asymmetric row heights must never be flattened into an 18px grid.
class FusionPlacementGeometry {
  final String id;
  final int tile, style, width, height, frameX, frameY;
  final int coordinateWidth, coordinatePadding, alternate, random;
  final List<int> coordinateHeights;
  FusionPlacementGeometry._({
    required this.id,
    required this.tile,
    required this.style,
    required this.width,
    required this.height,
    required this.frameX,
    required this.frameY,
    required this.coordinateWidth,
    required this.coordinatePadding,
    required this.alternate,
    required this.random,
    required this.coordinateHeights,
  });

  factory FusionPlacementGeometry.fromEntry(CatalogEntry row) {
    final f = row.fields;
    int integer(String key, int min, int max, {int? fallback}) {
      final value = f[key] ?? fallback;
      if (value is! int || value < min || value > max) {
        throw FormatException('物件占格 ${row.id} 的 $key 无效');
      }
      return value;
    }

    final width = integer('width', 1, 32), height = integer('height', 1, 32);
    final raw = f['coordinateHeights'];
    if (raw is! List ||
        raw.length != height ||
        raw.any((v) => v is! int || v < 1 || v > 64)) {
      throw FormatException('物件占格 ${row.id} 的逐行高度无效');
    }
    final result = FusionPlacementGeometry._(
      id: row.id,
      tile: integer('tile', 0, 65535),
      style: integer('style', 0, 32767),
      width: width,
      height: height,
      frameX: integer('frameX', -32768, 32767),
      frameY: integer('frameY', -32768, 32767),
      coordinateWidth: integer('coordinateWidth', 1, 64),
      coordinatePadding: integer('coordinatePadding', 0, 16),
      alternate: integer('alternate', 0, 32767, fallback: 0),
      random: integer('random', 0, 32767, fallback: 0),
      coordinateHeights: List<int>.unmodifiable(raw.cast<int>()),
    );
    if (result.frameAt(width - 1, height - 1).$1 > 32767 ||
        result.frameAt(width - 1, height - 1).$2 > 32767) {
      throw FormatException('物件占格 ${row.id} 的完整帧范围溢出');
    }
    return result;
  }

  (int, int) frameAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('物件局部坐标越界');
    }
    var rowY = frameY;
    for (var i = 0; i < y; i++) {
      rowY += coordinateHeights[i] + coordinatePadding;
    }
    return (frameX + x * (coordinateWidth + coordinatePadding), rowY);
  }

  String get label => '变体 $alternate · 随机样式 $random · $width × $height';
}

class FusionPlacementBrush {
  final int itemId, variantIndex;
  final String label, gameVersion;
  final bool display, logicOn;
  final String name, text;
  final FusionPlacementGeometry geometry;
  const FusionPlacementBrush._({
    required this.itemId,
    required this.variantIndex,
    required this.label,
    required this.gameVersion,
    required this.display,
    required this.name,
    required this.text,
    required this.logicOn,
    required this.geometry,
  });
  int get tileType => geometry.tile;
  int get width => geometry.width;
  int get height => geometry.height;
  bool get requiresObjects => _objectSizes.containsKey(tileType);
  bool get isContainer => _containers.contains(tileType);
  bool get isSign => _signs.contains(tileType);
  bool get isLogicSensor => tileType == 423;
  Map<String, Object?> intent(int x, int y) => {
    'itemId': itemId,
    'variantIndex': variantIndex,
    'display': display,
    'x': x,
    'y': y,
    if (isContainer) 'name': name,
    if (isSign) 'text': text,
    if (isLogicSensor) 'logicOn': logicOn,
  };
}

/// New placement is admitted only from the locally imported, version-pinned
/// catalog. No game tables, Item images or guessed rotations are embedded here.
class FusionPlacementCatalog {
  final ResourceCatalog catalog;
  final Map<String, List<FusionPlacementGeometry>> _placements = {};
  late final List<CatalogEntry> entries = List.unmodifiable(
    catalog.families['items'] ?? const <CatalogEntry>[],
  );
  FusionPlacementCatalog(this.catalog) {
    if (catalog.gameVersion != '1.4.5.8') {
      throw const FormatException('新增物件需要已核验的 1.4.5.8 本地资源包');
    }
    final rows = catalog.families['tile-object-data'];
    if (rows == null || rows.isEmpty || rows.length > 20000) {
      throw const FormatException('请导入包含 tile-object-data 的本地资源包');
    }
    for (final entry in rows) {
      final row = FusionPlacementGeometry.fromEntry(entry);
      (_placements['${row.tile}:${row.style}'] ??= []).add(row);
    }
    for (final rows in _placements.values) {
      rows.sort((a, b) {
        final alternate = a.alternate.compareTo(b.alternate);
        return alternate != 0 ? alternate : a.random.compareTo(b.random);
      });
    }
  }

  List<CatalogEntry> search({String query = '', bool display = false}) {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty);
    return entries
        .where((item) {
          final tile = item.fields['createTile'];
          if (!display && (tile is! int || tile < 0)) return false;
          final text = '${item.searchText} tile:$tile';
          return terms.every(text.contains);
        })
        .toList(growable: false);
  }

  String? unavailableReason(int itemId, {bool display = false}) {
    final item = catalog.byId('items', itemId);
    if (item == null || itemId < 1 || itemId > 32767) return '请选择目录中的原版物品';
    final tile = display ? 395 : item.fields['createTile'];
    final style = display ? 0 : item.fields['placeStyle'] ?? 0;
    if (tile is! int || tile < 0 || style is! int || style < 0) {
      return '此物品没有可放置的家具记录，可使用展示框';
    }
    final rows = _placements['$tile:$style'] ?? const [];
    if (rows.isEmpty) return '缺少已核验的原版占格，不能新增';
    if (tile == 423 && style > 6) return '逻辑感应器的原版样式须为 0–6';
    if (rows.every((row) => _geometryError(row) != null)) {
      return '附加记录与原版完整占格不匹配，不能新增';
    }
    return null;
  }

  List<FusionPlacementGeometry> variants(int itemId, {bool display = false}) {
    if (unavailableReason(itemId, display: display) != null) return const [];
    final item = catalog.byId('items', itemId)!;
    return List.unmodifiable(
      _placements['${display ? 395 : item.fields['createTile']}:${display ? 0 : item.fields['placeStyle'] ?? 0}']!,
    );
  }

  FusionPlacementBrush brush(
    int itemId, {
    int variantIndex = 0,
    bool display = false,
    String name = '',
    String text = '',
    bool logicOn = false,
  }) {
    final error = unavailableReason(itemId, display: display);
    if (error != null) throw StateError(error);
    final shapes = variants(itemId, display: display);
    if (variantIndex < 0 || variantIndex >= shapes.length) {
      throw RangeError('物件变体不存在');
    }
    final shape = shapes[variantIndex];
    final geometryError = _geometryError(shape);
    if (geometryError != null) throw FormatException(geometryError);
    if (name.isNotEmpty && !_containers.contains(shape.tile) ||
        text.isNotEmpty && !_signs.contains(shape.tile) ||
        logicOn && shape.tile != 423) {
      throw ArgumentError('附加选项与所选物件类型不匹配');
    }
    if (_containers.contains(shape.tile)) ChestTools.rename(const {}, name);
    // The protocol also uses bounded UTF-8 byte lengths.
    _encodeObjectText(name, 16384);
    _encodeObjectText(text, 1024 * 1024);
    return FusionPlacementBrush._(
      itemId: itemId,
      variantIndex: variantIndex,
      label: catalog.byId('items', itemId)!.name,
      gameVersion: catalog.gameVersion,
      display: display,
      name: name,
      text: text,
      logicOn: logicOn,
      geometry: shape,
    );
  }
}

/// Preview and stage one new object. Existing foreground and existing object
/// footprints are always rejected. This plan never means replacement/transfer.
class FusionPlacementPlan {
  final AdvancedRegionDocument _document;
  final FusionPlacementBrush brush;
  final int x, y, worldVersion, expectedRevision;
  final List<String> blockers;
  FusionPlacementPlan._(
    this._document,
    this.brush,
    this.x,
    this.y,
    this.worldVersion,
    this.expectedRevision,
    this.blockers,
  );
  int get width => brush.width;
  int get height => brush.height;
  bool get canPlace => blockers.isEmpty;

  factory FusionPlacementPlan.preview({
    required AdvancedRegionDocument document,
    required FusionPlacementBrush brush,
    required int x,
    required int y,
    required int worldVersion,
  }) {
    final blockers = <String>[];
    if (document.strokeOpen) blockers.add('请先结束当前笔画');
    if (document.contentBytes > document.historyBudgetBytes) {
      blockers.add('区域与附加记录超过撤销预算，请读取更小选区');
    }
    if (worldVersion < 1 || worldVersion > 326) blockers.add('目标世界版本未核验');
    if (brush.requiresObjects && worldVersion != 326) {
      blockers.add('新增物件附加记录仅支持 WLD 326');
    }
    if (x < 0 ||
        y < 0 ||
        x + brush.width > document.width ||
        y + brush.height > document.height) {
      blockers.add('请将整个物件放在读取区域内');
    } else {
      var missing = false, occupied = false;
      for (var dx = 0; dx < brush.width; dx++) {
        for (var dy = 0; dy < brush.height; dy++) {
          final cell = document.cellAt(x + dx, y + dy);
          missing |= cell == null;
          occupied |= cell?['active'] == 1;
        }
      }
      if (missing) blockers.add('稀疏区域缺少完整占格，不能推测目标图层');
      if (occupied) blockers.add('目标已有物块或家具，请选择完整空白占格');
    }
    if (brush.requiresObjects &&
        (document.sourceX + x + brush.width > 65536 ||
            document.sourceY + y + brush.height > 65536)) {
      blockers.add('物件锚点超出世界附加记录范围');
    }
    final objects = document.objects;
    if (objects != null) {
      try {
        final bundle = _ObjectBundle.read(objects, document);
        if (brush.requiresObjects && bundle.version != 326) {
          blockers.add('原区域附加记录版本不匹配');
        }
        if (bundle.objects.any(
          (o) =>
              x < o.x + o.width &&
              o.x < x + brush.width &&
              y < o.y + o.height &&
              o.y < y + brush.height,
        )) {
          blockers.add('目标与原有物件附加记录重叠');
        }
      } on FormatException catch (e) {
        blockers.add(e.message);
      }
    }
    return FusionPlacementPlan._(
      document,
      brush,
      x,
      y,
      worldVersion,
      document.revision,
      List.unmodifiable(blockers),
    );
  }

  void _checkFresh() {
    if (!canPlace) throw StateError(blockers.join('；'));
    if (_document.revision != expectedRevision || _document.strokeOpen) {
      throw StateError('区域已改变，请重新预览物件放置');
    }
  }

  /// Narrow overlay with local (0,0) origin. Only this fragment is suitable for
  /// inserting the staged object into its existing source world.
  AdvancedRegionDocument get fragment {
    _checkFresh();
    final records = Uint8List(width * height * 32);
    final destination = ByteData.sublistView(records);
    final source = _document.records;
    for (var dx = 0; dx < width; dx++) {
      for (var dy = 0; dy < height; dy++) {
        final at = (dx * height + dy) * 32;
        final old = _document.indexAt(x + dx, y + dy) * 32;
        records.setRange(at, at + 32, source, old);
        destination.setUint32(at, dx, Endian.little);
        destination.setUint32(at + 4, dy, Endian.little);
        final flags = destination.getUint32(at + 8, Endian.little) >> 16;
        destination.setUint32(
          at + 8,
          brush.tileType | (((flags & 82) | 1) << 16),
          Endian.little,
        );
        final frame = brush.geometry.frameAt(dx, dy);
        destination.setInt16(at + 12, frame.$1, Endian.little);
        destination.setInt16(at + 14, frame.$2, Endian.little);
        final wall = destination.getUint32(at + 16, Endian.little);
        destination.setUint32(at + 16, wall & 0xff00ffff, Endian.little);
        final layers = destination.getUint32(at + 20, Endian.little);
        destination.setUint32(at + 20, layers & 0xff00ffff, Endian.little);
      }
    }
    return AdvancedRegionDocument(
      width: width,
      height: height,
      records: records,
      sourceX: _document.sourceX + x,
      sourceY: _document.sourceY + y,
      objects: brush.requiresObjects
          ? _newObjectBundle(
              brush,
              0,
              0,
              _document.sourceX + x,
              _document.sourceY + y,
            )
          : null,
    );
  }

  /// Tiles and COB1 payload enter history together. Caller must retain the
  /// fragment before apply(), as later requests require a new preview.
  void apply(AdvancedRegionDocument document) {
    if (!identical(document, _document)) throw StateError('放置预览属于另一个区域');
    _checkFresh();
    final patch = fragment;
    final records = document.records, source = patch.records;
    for (var dx = 0; dx < width; dx++) {
      for (var dy = 0; dy < height; dy++) {
        final at = document.indexAt(x + dx, y + dy) * 32;
        final start = (dx * height + dy) * 32;
        records.setRange(at + 8, at + 32, source, start + 8);
      }
    }
    var objects = document.objects;
    if (brush.requiresObjects) {
      final added = _newObjectBundle(
        brush,
        x,
        y,
        document.sourceX,
        document.sourceY,
      );
      if (objects == null) {
        objects = added;
      } else {
        final merged = Uint8List(objects.length + added.length - 32)
          ..setAll(0, objects)
          ..setAll(objects.length, added.sublist(32));
        final view = ByteData.sublistView(merged);
        view.setUint32(12, document.objectCount + 1, Endian.little);
        view.setUint32(16, merged.length, Endian.little);
        if (merged.length > 4 * 1024 * 1024 || document.objectCount >= 32768) {
          throw StateError('新增物件超过附加记录预算');
        }
        objects = merged;
      }
    }
    document.replaceContent(records, objects: objects);
  }
}

String? _geometryError(FusionPlacementGeometry shape) {
  final size = _objectSizes[shape.tile];
  if (size == null) return null;
  if (shape.width != size.$1 ||
      shape.height != size.$2 ||
      shape.frameX < 0 ||
      shape.frameY < 0 ||
      shape.frameX % (shape.width * 18) != 0 ||
      shape.frameY % (shape.height * 18) != 0 ||
      shape.tile != 423 && shape.tile != 724 && shape.frameY != 0 ||
      shape.tile == 423 && shape.frameY != shape.style * 18 ||
      shape.coordinateWidth + shape.coordinatePadding != 18 ||
      shape.coordinateHeights
          .take(shape.height - 1)
          .any((height) => height + shape.coordinatePadding != 18)) {
    return '物件附加记录必须对应完整的原版占格与帧坐标';
  }
  return null;
}

Uint8List _encodeObjectText(String value, int maxBytes) {
  if (value.length > maxBytes) throw ArgumentError('物件文字超过字节预算');
  final bytes = utf8.encode(value);
  if (bytes.length > maxBytes) throw ArgumentError('物件文字超过字节预算');
  final prefix = <int>[];
  var length = bytes.length;
  do {
    final part = length & 127;
    length >>= 7;
    prefix.add(part | (length == 0 ? 0 : 128));
  } while (length != 0);
  return Uint8List.fromList([...prefix, ...bytes]);
}

Uint8List _newObjectPayload(FusionPlacementBrush brush) {
  if (brush.isContainer) {
    final name = _encodeObjectText(brush.name, 16384);
    // New containers always have the original default 40 empty inventory slots.
    final result = Uint8List(name.length + 4 + 40 * 2)..setAll(0, name);
    ByteData.sublistView(result).setUint32(name.length, 40, Endian.little);
    return result;
  }
  if (brush.isSign) return _encodeObjectText(brush.text, 1024 * 1024);
  final kind = _entityTiles.indexOf(brush.tileType);
  switch (kind) {
    case 0: // Unbound training dummy NPC index.
      return Uint8List.fromList([255, 255]);
    case 1:
    case 4:
    case 6:
    case 8:
      final item = ByteData(5);
      if (brush.display) {
        item.setInt16(0, brush.itemId, Endian.little);
        item.setInt16(3, 1, Endian.little);
      }
      return item.buffer.asUint8List();
    case 2:
      return Uint8List.fromList([
        brush.geometry.style + 1,
        brush.logicOn ? 1 : 0,
      ]);
    case 3: // WLD326 equipment, dyes, visibility and extra equipment masks.
      return Uint8List(4);
    case 5:
      return Uint8List(1);
    case 7:
      return Uint8List(0);
    case 9:
    case 10:
      // These two anchor entities explicitly identify the selected placed item;
      // this is not the contents of an ordinary display/equipment container.
      return (ByteData(
        2,
      )..setInt16(0, brush.itemId, Endian.little)).buffer.asUint8List();
    default:
      throw StateError('尚未支持此物件附加记录');
  }
}

Uint8List _newObjectBundle(
  FusionPlacementBrush brush,
  int x,
  int y,
  int originX,
  int originY,
) {
  final payload = _newObjectPayload(brush);
  final data = ByteData(64 + payload.length);
  final section = brush.isContainer
      ? 2
      : brush.isSign
      ? 3
      : 5;
  final words = [
    0x31424f43,
    1,
    326,
    1,
    data.lengthInBytes,
    originX,
    originY,
    0,
    section,
    section == 5 ? _entityTiles.indexOf(brush.tileType) : 0,
    x,
    y,
    brush.tileType,
    payload.length,
    0,
    0,
  ];
  for (var i = 0; i < words.length; i++) {
    data.setUint32(i * 4, words[i], Endian.little);
  }
  return data.buffer.asUint8List()..setAll(64, payload);
}

/// Validated display-frame contents for a renderer. Coordinates are region-local;
/// the item icon must still come from the user's matching local resource pack.
class FusionDisplayItem {
  final int x, y, itemId, prefix, stack;
  const FusionDisplayItem._(
    this.x,
    this.y,
    this.itemId,
    this.prefix,
    this.stack,
  );
  int get width => 2;
  int get height => 2;

  static List<FusionDisplayItem> readAll(AdvancedRegionDocument document) {
    final bytes = document.objects;
    if (bytes == null) return const [];
    final bundle = _ObjectBundle.read(bytes, document);
    final result = <FusionDisplayItem>[];
    for (final object in bundle.objects) {
      if (object.tileType != 395) continue;
      if (object.payload.length != 5) {
        throw const FormatException('展示框物品记录长度无效');
      }
      final payload = ByteData.sublistView(object.payload);
      final itemId = payload.getInt16(0, Endian.little),
          prefix = payload.getUint8(2),
          stack = payload.getInt16(3, Endian.little);
      if (itemId < 0 || stack < 0 || (itemId == 0) != (stack == 0)) {
        throw const FormatException('展示框物品编号或数量无效');
      }
      final root = document.cellAt(object.x, object.y);
      if (root == null ||
          root['frameX']! < 0 ||
          root['frameY']! < 0 ||
          root['frameX']! % 36 != 0 ||
          root['frameY']! % 36 != 0) {
        throw const FormatException('展示框缺少完整原版占格');
      }
      for (var dx = 0; dx < 2; dx++) {
        for (var dy = 0; dy < 2; dy++) {
          final cell = document.cellAt(object.x + dx, object.y + dy);
          if (cell == null ||
              cell['active'] != 1 ||
              cell['block'] != 395 ||
              cell['frameX'] != root['frameX']! + dx * 18 ||
              cell['frameY'] != root['frameY']! + dy * 18) {
            throw const FormatException('展示框缺少完整原版占格');
          }
        }
      }
      if (itemId != 0) {
        result.add(
          FusionDisplayItem._(object.x, object.y, itemId, prefix, stack),
        );
      }
    }
    return List.unmodifiable(result);
  }
}

// Parses the complete companion payload before admitting an append. Existing
// populated inventories/equipment are retained byte for byte after validation.
void _validateObjectPayload(int section, int kind, Uint8List payload) {
  final data = ByteData.sublistView(payload);
  var at = 0;
  Never bad() => throw const FormatException('物件附加记录内容无效或被截断');
  void take(int count) {
    if (count < 0 || count > payload.length - at) bad();
    at += count;
  }

  int byte() {
    take(1);
    return payload[at - 1];
  }

  int short() {
    take(2);
    return data.getInt16(at - 2, Endian.little);
  }

  void text() {
    var count = 0, shift = 0;
    while (true) {
      final part = byte();
      if (shift >= 28 && part > 7) bad();
      count |= (part & 127) << shift;
      if (part < 128) break;
      shift += 7;
    }
    if (count > 1024 * 1024) bad();
    take(count);
    try {
      utf8.decode(Uint8List.sublistView(payload, at - count, at));
    } on FormatException {
      bad();
    }
  }

  void item() {
    final id = short();
    byte();
    final stack = short();
    if (id < 0 || stack < 0 || (id == 0) != (stack == 0)) bad();
  }

  int bits(int flags) {
    var count = 0;
    while (flags != 0) {
      count += flags & 1;
      flags >>= 1;
    }
    return count;
  }

  if (section == 2) {
    text();
    take(4);
    final slots = data.getUint32(at - 4, Endian.little);
    if (slots > (payload.length - at) ~/ 2) bad();
    for (var slot = 0; slot < slots; slot++) {
      final stack = short();
      if (stack < 0) bad();
      if (stack != 0) take(5); // Saved inventory item IDs are int32.
    }
  } else if (section == 3) {
    text();
  } else {
    switch (kind) {
      case 0:
        short();
        break;
      case 1:
      case 4:
      case 6:
      case 8:
        item();
        break;
      case 2:
        if (byte() > 7 || byte() > 1) bad();
        break;
      case 3:
        final equipment = byte(), dyes = byte();
        byte();
        final extra = byte();
        if (extra & ~7 != 0) bad();
        final count = bits(equipment) + bits(dyes) + bits(extra);
        for (var i = 0; i < count; i++) {
          item();
        }
        break;
      case 5:
        final flags = byte();
        if (flags & ~15 != 0) bad();
        for (var i = 0; i < bits(flags); i++) {
          item();
        }
        break;
      case 7:
        break;
      case 9:
      case 10:
        if (short() <= 0) bad();
        break;
      default:
        bad();
    }
  }
  if (at != payload.length) bad();
}

class _ObjectBounds {
  final int x, y, width, height, tileType;
  final Uint8List payload;
  const _ObjectBounds(
    this.x,
    this.y,
    this.width,
    this.height,
    this.tileType,
    this.payload,
  );
}

class _ObjectBundle {
  final int version;
  final List<_ObjectBounds> objects;
  const _ObjectBundle(this.version, this.objects);
  factory _ObjectBundle.read(Uint8List bytes, AdvancedRegionDocument document) {
    Never bad() => throw const FormatException('区域物件附加记录不完整或不匹配');
    if (bytes.length < 32 || bytes.length > 4 * 1024 * 1024) bad();
    final d = ByteData.sublistView(bytes);
    int word(int at) => d.getUint32(at, Endian.little);
    final version = word(8), count = word(12);
    if (word(0) != 0x31424f43 ||
        word(4) != 1 ||
        version < 1 ||
        version > 326 ||
        count > 32768 ||
        word(16) != bytes.length ||
        word(20) != document.sourceX ||
        word(24) != document.sourceY ||
        word(28) != 0 ||
        count > 0 && version != 326) {
      bad();
    }
    final objects = <_ObjectBounds>[], anchors = <String>{};
    var at = 32;
    for (var i = 0; i < count; i++) {
      if (at + 32 > bytes.length) bad();
      final section = word(at),
          entity = word(at + 4),
          x = word(at + 8),
          y = word(at + 12),
          tile = word(at + 16),
          size = word(at + 20);
      final valid =
          section == 2 && {21, 88, 467}.contains(tile) && entity == 0 ||
          section == 3 && {55, 85, 425, 573}.contains(tile) && entity == 0 ||
          section == 5 &&
              entity < _entityTiles.length &&
              _entityTiles[entity] == tile;
      if (!valid ||
          word(at + 24) != 0 ||
          word(at + 28) != 0 ||
          size == 0 && !(section == 5 && entity == 7) ||
          size > bytes.length - at - 32 ||
          !anchors.add('$x:$y')) {
        bad();
      }
      final shape = _objectSizes[tile]!;
      if (x + shape.$1 > document.width || y + shape.$2 > document.height) {
        bad();
      }
      final payload = Uint8List.sublistView(bytes, at + 32, at + 32 + size);
      _validateObjectPayload(section, entity, payload);
      objects.add(_ObjectBounds(x, y, shape.$1, shape.$2, tile, payload));
      at += 32 + size;
    }
    if (at != bytes.length) bad();
    return _ObjectBundle(version, objects);
  }
}
