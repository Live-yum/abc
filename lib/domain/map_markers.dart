import 'dart:convert';

/// Native entity matching fields. Omitted fields use the engine's defaults.
/// Frame coordinates come from a verified catalog or an explicit user entry.
class MapMarkerSelector {
  final int locate, frameX, frameY, frameXMod, frameYMod;
  MapMarkerSelector({
    this.locate = 0,
    this.frameX = -1,
    this.frameY = -1,
    int frameXMod = 0,
    int frameYMod = 0,
  }) : frameXMod = frameX < 0 ? 0 : frameXMod,
       frameYMod = frameY < 0 ? 0 : frameYMod {
    if (locate < 0 ||
        locate > 2 ||
        frameX < -1 ||
        frameX > 32767 ||
        frameY < -1 ||
        frameY > 32767 ||
        frameXMod < 0 ||
        frameXMod > 32767 ||
        frameYMod < 0 ||
        frameYMod > 32767) {
      throw const FormatException('实体定位模式须为 0–2，帧坐标 -1–32767，取模 0–32767');
    }
    if (locate == 0 && (frameX >= 0 || frameY >= 0)) {
      throw const FormatException('帧筛选需要逐点或连通区域定位模式');
    }
  }
  bool get isDefault => locate == 0;
  String get key => '$locate:$frameX:$frameY:$frameXMod:$frameYMod';
  Map<String, Object?> toJson() => {
    if (locate != 0) 'locate': locate,
    if (frameX != -1) 'frame_x': frameX,
    if (frameY != -1) 'frame_y': frameY,
    if (frameXMod != 0) 'frame_x_mod': frameXMod,
    if (frameYMod != 0) 'frame_y_mod': frameYMod,
  };
  factory MapMarkerSelector.fromJson(Object? value) {
    const keys = {'locate', 'frame_x', 'frame_y', 'frame_x_mod', 'frame_y_mod'};
    if (value is! Map ||
        value.keys.any((key) => !keys.contains(key)) ||
        value.values.any((value) => value is! int)) {
      throw const FormatException('无效的实体定位字段');
    }
    return MapMarkerSelector(
      locate: value['locate'] as int? ?? 0,
      frameX: value['frame_x'] as int? ?? -1,
      frameY: value['frame_y'] as int? ?? -1,
      frameXMod: value['frame_x_mod'] as int? ?? 0,
      frameYMod: value['frame_y_mod'] as int? ?? 0,
    );
  }
}

/// One search criterion; positions are resolved by the world engine, never guessed.
class MapMarker {
  final String kind;
  final int id;
  final String color;
  final int radius, lineWidth;
  final MapMarkerSelector? selector;
  MapMarker({
    required this.kind,
    required this.id,
    String color = '#FF3B30',
    this.radius = 30,
    this.lineWidth = 3,
    MapMarkerSelector? selector,
  }) : color = color.toUpperCase(),
       selector = selector?.isDefault == true ? null : selector {
    if (kind != 'item' && kind != 'tile') {
      throw const FormatException('标记类型必须是 item 或 tile');
    }
    if (id < (kind == 'item' ? 1 : 0) ||
        id > (kind == 'item' ? 2147483647 : 65535)) {
      throw const FormatException('标记 ID 超出范围');
    }
    if (kind != 'tile' && selector != null) {
      throw const FormatException('实体定位字段仅可用于方块标记');
    }
    if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color) ||
        radius < 1 ||
        radius > 60 ||
        lineWidth < 1 ||
        lineWidth > 15) {
      throw const FormatException('颜色须为 #RRGGBB，半径 1–60，线宽 1–15');
    }
  }
  String get key => '$kind:$id${selector == null ? '' : ':${selector!.key}'}';
  Map<String, Object?> get identity => {
    'kind': kind,
    'id': id,
    if (selector != null) 'selector': selector!.toJson(),
  };
  Map<String, Object?> toJson() => {
    ...identity,
    'color': color,
    'radius': radius,
    'lineWidth': lineWidth,
  };
  factory MapMarker.fromJson(Object? value) {
    const required = {'kind', 'id', 'color', 'radius', 'lineWidth'};
    if (value is! Map ||
        !value.keys.toSet().containsAll(required) ||
        value.keys.any((key) => !{...required, 'selector'}.contains(key)) ||
        value['kind'] is! String ||
        value['id'] is! int ||
        value['color'] is! String ||
        value['radius'] is! int ||
        value['lineWidth'] is! int) {
      throw const FormatException('无效的标记字段');
    }
    return MapMarker(
      kind: value['kind'] as String,
      id: value['id'] as int,
      color: value['color'] as String,
      radius: value['radius'] as int,
      lineWidth: value['lineWidth'] as int,
      selector: value.containsKey('selector')
          ? MapMarkerSelector.fromJson(value['selector'])
          : null,
    );
  }
}

/// Versioned local preferences, independent from world contents and catalog version.
class MapMarkerProfile {
  static const maxMarkers = 256;
  static const maxJsonBytes = 32768;
  final List<MapMarker> markers;
  MapMarkerProfile([Iterable<MapMarker> markers = const []])
    : markers = List.unmodifiable(markers) {
    if (this.markers.length > maxMarkers) {
      throw const FormatException('物品与实体合计最多 256 个标记');
    }
    if (this.markers.map((m) => m.key).toSet().length != this.markers.length) {
      throw const FormatException('标记重复');
    }
    final clustered = this.markers.where((m) => m.selector?.locate == 2);
    if (clustered.map((m) => m.id).toSet().length != clustered.length) {
      throw const FormatException('同一方块 ID 只能设置一个连通区域标记');
    }
    if (utf8.encode(encode()).length > maxJsonBytes) {
      throw const FormatException('标记配置超过 32 KiB');
    }
  }
  bool get isEmpty => markers.isEmpty;
  int get length => markers.length;
  bool contains(String kind, int id, {MapMarkerSelector? selector}) {
    final key = MapMarker(kind: kind, id: id, selector: selector).key;
    return markers.any((m) => m.key == key);
  }

  MapMarkerProfile toggle(String kind, int id, {MapMarkerSelector? selector}) {
    final marker = MapMarker(kind: kind, id: id, selector: selector);
    return contains(kind, id, selector: selector)
        ? remove(kind, id, selector: selector)
        : MapMarkerProfile([...markers, marker]);
  }

  MapMarkerProfile remove(String kind, int id, {MapMarkerSelector? selector}) {
    final key = MapMarker(kind: kind, id: id, selector: selector).key;
    return MapMarkerProfile(markers.where((m) => m.key != key));
  }

  MapMarkerProfile style(
    String kind,
    int id, {
    required String color,
    required int radius,
    required int lineWidth,
    MapMarkerSelector? selector,
  }) {
    final updated = MapMarker(
      kind: kind,
      id: id,
      selector: selector,
      color: color,
      radius: radius,
      lineWidth: lineWidth,
    );
    if (!contains(kind, id, selector: selector)) {
      throw const FormatException('标记不存在');
    }
    return MapMarkerProfile(
      markers.map((m) => m.key == updated.key ? updated : m),
    );
  }

  MapMarkerProfile clear() => MapMarkerProfile();
  Map<String, Object?> toJson() => {
    'version': 1,
    'markers': markers.map((m) => m.toJson()).toList(growable: false),
  };
  String encode() => jsonEncode(toJson());
  factory MapMarkerProfile.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['markers'] is! List) {
      throw const FormatException('无效的标记配置版本或字段');
    }
    final list = value['markers'] as List;
    if (list.length > maxMarkers) throw const FormatException('标记超过 256 个');
    final result = MapMarkerProfile(list.map(MapMarker.fromJson));
    if (utf8.encode(result.encode()).length > maxJsonBytes) {
      throw const FormatException('标记配置超过 32 KiB');
    }
    return result;
  }
  factory MapMarkerProfile.decode(String source) {
    if (source.length > maxJsonBytes ||
        utf8.encode(source).length > maxJsonBytes) {
      throw const FormatException('标记配置超过 32 KiB');
    }
    return MapMarkerProfile.fromJson(jsonDecode(source));
  }
  Map<String, Object?> toEngineRequest({int maxWidth = 1920}) {
    if (isEmpty) throw const FormatException('请先选择标记');
    if (maxWidth < 1 || maxWidth > 16384) throw const FormatException('预览宽度无效');
    List<Map<String, Object?>> rows(String kind, String key) => [
      for (final m in markers.where((m) => m.kind == kind))
        {
          key: m.id,
          if (m.selector != null) ...m.selector!.toJson(),
          'color': m.color,
          'radius': m.radius,
          'line_width': m.lineWidth,
        },
    ];
    return {
      'max_w': maxWidth,
      'tile_markers': rows('tile', 'tile_type'),
      'chest_markers': rows('item', 'item_id'),
    };
  }
}
