import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Public, deliberately strict subset of the batch_update_tiles contract.
/// Core still validates world-version, frame-important tiles and furniture.
class WorldRuleField {
  final String label;
  final int min, max;
  final bool boolean, where, patch;
  const WorldRuleField(
    this.label, {
    this.min = 0,
    this.max = 65535,
    this.boolean = false,
    this.where = true,
    this.patch = true,
  });
}

const worldRuleFields = <String, WorldRuleField>{
  'is_active': WorldRuleField('物块存在', boolean: true, patch: false),
  'has_wall': WorldRuleField('墙壁存在', boolean: true, patch: false),
  'type': WorldRuleField('物块 ID'),
  'wall': WorldRuleField('墙壁 ID'),
  'biome_region': WorldRuleField('环境区域', min: 1, max: 14, patch: false),
  'exclude_biome_region': WorldRuleField(
    '排除环境区域',
    min: 1,
    max: 14,
    patch: false,
  ),
  'terrain_theme': WorldRuleField('地形主题', min: 1, max: 3, where: false),
  'wall_theme': WorldRuleField('墙壁主题', min: 1, max: 3, where: false),
  'furniture_theme': WorldRuleField('家具主题', min: 1, max: 3, where: false),
  'platform_style': WorldRuleField('平台样式', max: 69),
  'frame_x': WorldRuleField('帧 X', max: 32767),
  'frame_y': WorldRuleField('帧 Y', max: 32767),
  'liquid_amount': WorldRuleField('液体量', max: 255),
  'liquid_type': WorldRuleField('液体类型', max: 4),
  'brick_style': WorldRuleField('半砖与斜坡', max: 5),
  'tile_color': WorldRuleField('物块油漆', max: 30),
  'wall_color': WorldRuleField('墙壁油漆', max: 30),
  'wire_red': WorldRuleField('红线', boolean: true),
  'wire_blue': WorldRuleField('蓝线', boolean: true),
  'wire_green': WorldRuleField('绿线', boolean: true),
  'wire_yellow': WorldRuleField('黄线', boolean: true),
  'actuator': WorldRuleField('制动器', boolean: true),
  'inactive': WorldRuleField('制动状态', boolean: true),
  'invisible_block': WorldRuleField('物块透明', boolean: true),
  'invisible_wall': WorldRuleField('墙壁透明', boolean: true),
  'fullbright_block': WorldRuleField('物块全亮', boolean: true),
  'fullbright_wall': WorldRuleField('墙壁全亮', boolean: true),
};

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$label 必须是对象');
  }
  return Map<String, Object?>.from(value);
}

void _keys(Map<String, Object?> value, Set<String> allowed, String label) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw FormatException('$label 包含未知字段');
  }
}

int _integer(Object? value, int min, int max, String label) {
  if (value is! int || value < min || value > max) {
    throw FormatException('$label 必须是 $min–$max 的整数');
  }
  return value;
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freeze(v))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

class WorldTileRule {
  final Map<String, Object?> where, patch;
  final int limit;
  WorldTileRule({
    Map<String, Object?> where = const {},
    required Map<String, Object?> patch,
    this.limit = 0,
  }) : where = _freeze(where) as Map<String, Object?>,
       patch = _freeze(patch) as Map<String, Object?> {
    validate();
  }
  factory WorldTileRule.fromJson(Object? json) {
    final map = _object(json, '规则');
    _keys(map, {'where', 'patch', 'limit'}, '规则');
    return WorldTileRule(
      where: _object(map['where'], 'where'),
      patch: _object(map['patch'], 'patch'),
      limit: map.containsKey('limit')
          ? _integer(map['limit'], 0, 2147483647, 'limit')
          : 0,
    );
  }
  Map<String, Object?> toJson() => {
    'where': where,
    'patch': patch,
    'limit': limit,
  };
  void validate() {
    _integer(limit, 0, 2147483647, 'limit');
    if (patch.isEmpty) throw const FormatException('替换属性不能为空');
    for (final pair in [('where', where), ('patch', patch)]) {
      final side = pair.$1, values = pair.$2;
      for (final entry in values.entries) {
        if (entry.key == 'material') {
          validateMaterial(entry.value);
          continue;
        }
        final field = worldRuleFields[entry.key];
        if (field == null || (side == 'where' ? !field.where : !field.patch)) {
          throw FormatException('$side 不支持字段 ${entry.key}');
        }
        if (field.boolean) {
          if (entry.value is! bool && entry.value != 0 && entry.value != 1) {
            throw FormatException('${entry.key} 必须是布尔值或整数 0/1');
          }
          if (entry.value is num && entry.value is! int) {
            throw const FormatException('布尔值必须是整数 0/1');
          }
        } else {
          _integer(entry.value, field.min, field.max, entry.key);
        }
      }
      if (values.containsKey('platform_style')) {
        if (values.containsKey('type') && values['type'] != 19) {
          throw const FormatException('平台样式只适用于物块 19');
        }
        if (values.containsKey('frame_y') &&
            (side == 'patch' ||
                values['frame_y'] != (values['platform_style'] as int) * 18)) {
          throw const FormatException('平台样式与帧 Y 冲突');
        }
      }
      if (values.containsKey('material') &&
          ['platform_style', 'frame_x', 'frame_y'].any(values.containsKey)) {
        throw const FormatException('材质布局不能与平台样式或原始帧同时使用');
      }
    }
    if (where.containsKey('material') && !where.containsKey('type')) {
      throw const FormatException('匹配材质需要物块 ID');
    }
    final source = where['material'] as Map<String, Object?>?;
    final target = patch['material'] as Map<String, Object?>?;
    if (target != null &&
        (source == null ||
            source['width'] != target['width'] ||
            source['height'] != target['height'] ||
            patch['is_active'] == false ||
            patch['is_active'] == 0)) {
      throw const FormatException('目标材质需要相同尺寸的匹配材质与活动物块');
    }
    if (source != null && (source['width'] != 1 || source['height'] != 1)) {
      final targetType = patch.containsKey('platform_style')
          ? 19
          : patch['type'];
      if (limit != 0 || (targetType != null && targetType != where['type'])) {
        throw const FormatException('多格材质不能限制数量或改变物块 ID');
      }
    }
  }

  static void validateMaterial(Object? value) {
    final m = _object(value, 'material');
    const required = {
      'frame_x',
      'frame_y',
      'width',
      'height',
      'coordinate_width',
      'padding',
      'coordinate_heights',
    };
    _keys(m, required, 'material');
    if (!required.every(m.containsKey)) {
      throw const FormatException('材质布局字段不完整');
    }
    final x = _integer(m['frame_x'], 0, 32767, 'frame_x');
    var y = _integer(m['frame_y'], 0, 32767, 'frame_y');
    final width = _integer(m['width'], 1, 32, 'width');
    final height = _integer(m['height'], 1, 32, 'height');
    final cw = _integer(m['coordinate_width'], 1, 32767, 'coordinate_width');
    final padding = _integer(m['padding'], 0, 32767, 'padding');
    final heights = m['coordinate_heights'];
    if (heights is! List ||
        heights.length != height ||
        cw + padding > 32767 ||
        x + (width - 1) * (cw + padding) > 32767) {
      throw const FormatException('材质布局超出边界');
    }
    for (final h in heights) {
      if (y > 32767) throw const FormatException('材质帧 Y 超出边界');
      y += _integer(h, 1, 32767, 'coordinate_heights') + padding;
    }
  }
}

class WorldRuleScheme {
  static const format = 'terraforge.world-rules';
  static const version = 1;
  static const maxJsonBytes = 256 * 1024;
  static const builtinModes = ['purify', 'corruption', 'crimson', 'hallow'];
  final String name;
  final String? biomeMode;
  final List<WorldTileRule> rules;
  WorldRuleScheme({
    required this.name,
    this.biomeMode,
    List<WorldTileRule> rules = const [],
  }) : rules = List.unmodifiable(rules) {
    validate();
  }
  bool get isBuiltin => biomeMode != null;
  bool get canPreview => isBuiltin || rules.isNotEmpty;
  factory WorldRuleScheme.fromJson(Object? json) {
    final map = _object(json, '方案');
    _keys(map, {'format', 'version', 'name', 'biome_mode', 'rules'}, '方案');
    if (map['format'] != format ||
        map['version'] is! int ||
        map['version'] != version ||
        map['name'] is! String ||
        map['rules'] is! List ||
        (map.containsKey('biome_mode') && map['biome_mode'] is! String)) {
      throw const FormatException('不支持的世界规则方案格式');
    }
    if (utf8.encode(jsonEncode(map)).length > maxJsonBytes) {
      throw const FormatException('规则方案超过 256 KiB');
    }
    return WorldRuleScheme(
      name: map['name'] as String,
      biomeMode: map['biome_mode'] as String?,
      rules: (map['rules'] as List).map(WorldTileRule.fromJson).toList(),
    );
  }
  factory WorldRuleScheme.decode(String source) {
    if (utf8.encode(source).length > maxJsonBytes) {
      throw const FormatException('规则方案超过 256 KiB');
    }
    return WorldRuleScheme.fromJson(jsonDecode(source));
  }
  void validate({bool requireRules = false}) {
    if (name.trim().isEmpty || name.length > 160) {
      throw const FormatException('方案名称必须为 1–160 个字符');
    }
    if (rules.length > 128) throw const FormatException('最多支持 128 条规则');
    if (biomeMode != null &&
        (!builtinModes.contains(biomeMode) || rules.isNotEmpty)) {
      throw const FormatException('内置模式不能混合自定义规则');
    }
    for (final rule in rules) {
      rule.validate();
    }
    if (requireRules && !canPreview) throw const FormatException('请至少添加一条规则');
  }

  WorldRuleScheme copyWith({String? name, List<WorldTileRule>? rules}) =>
      WorldRuleScheme(
        name: name ?? this.name,
        biomeMode: biomeMode,
        rules: rules ?? this.rules,
      );
  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'name': name,
    if (biomeMode != null) 'biome_mode': biomeMode,
    'rules': rules.map((r) => r.toJson()).toList(),
  };
  String encode() => jsonEncode(toJson());
  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(toJson())))).toString();
  Map<String, Object?> toEngineRequest() {
    validate(requireRules: true);
    return biomeMode == null
        ? {'rules': rules.map((r) => r.toJson()).toList()}
        : {'biome_mode': biomeMode};
  }
}
