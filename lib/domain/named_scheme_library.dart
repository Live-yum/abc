import 'dart:convert';

import 'world_rules.dart';

enum NamedSchemeKind { mapping, worldRules }

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$label 必须是对象');
  }
  return Map<String, Object?>.from(value);
}

void _keys(Map<String, Object?> map, Set<String> allowed, String label) {
  if (map.keys.any((key) => !allowed.contains(key))) {
    throw FormatException('$label 包含未知字段');
  }
}

int _integer(Object? value, int min, int max, String label) {
  if (value is! int || value < min || value > max) {
    throw FormatException('$label 必须为 $min–$max 的整数');
  }
  return value;
}

String _name(Object? value) {
  if (value is! String || value.trim().isEmpty || value.length > 160) {
    throw const FormatException('方案名称必须为 1–160 个字符');
  }
  return value.trim();
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    throw const FormatException('方案 ID 无效');
  }
  return value;
}

void _budget(Object? value, int max, String label) {
  if (utf8.encode(jsonEncode(value)).length > max) {
    throw FormatException('$label 超出大小限制');
  }
}

/// The existing mapping v1 normalization, with validation of every retained
/// optional stamp field. No resource palette or private game table is required.
List<Map<String, Object?>> validateMappingRules(Object? raw) {
  if (raw is! List || raw.length > 65535) {
    throw const FormatException('映射规则必须为数组，最多 65,535 条');
  }
  return List<Map<String, Object?>>.unmodifiable(
    raw.map((item) {
      final rule = _object(item, '映射规则');
      _keys(rule, {
        'type',
        'source',
        'target',
        'layer',
        'wall',
        'blockPaint',
        'wallPaint',
        'mode',
        'version',
      }, '映射规则');
      final type = '${rule['type'] ?? 'color'}';
      final source = '${rule['source']}';
      final target = int.tryParse('${rule['target']}');
      if (!{'color', 'terrain'}.contains(type) ||
          target == null ||
          target < 0 ||
          target > 65535 ||
          (type == 'color' &&
              !RegExp(r'^#?[a-fA-F0-9]{6}$').hasMatch(source)) ||
          (type == 'terrain' &&
              (int.tryParse(source) == null ||
                  int.parse(source) < 0 ||
                  int.parse(source) > 65535))) {
        throw const FormatException('颜色使用 #RRGGBB；环境源/目标使用有效物块 ID');
      }
      final layer = rule['layer'] ?? 'block';
      if (!{'block', 'wall'}.contains(layer)) {
        throw const FormatException('映射规则图层必须是 block 或 wall');
      }
      if (type == 'color' && rule.containsKey('layer')) {
        throw const FormatException('颜色规则不支持 layer，请使用目标物块与墙壁字段');
      }
      for (final field in {
        'wall': 65535,
        'blockPaint': 30,
        'wallPaint': 30,
        'mode': 4,
      }.entries) {
        if (rule.containsKey(field.key)) {
          _integer(rule[field.key], 0, field.value, field.key);
        }
      }
      if (rule.containsKey('version')) {
        final version = rule['version'];
        if (version is! String ||
            version.trim().isEmpty ||
            version.length > 64) {
          throw const FormatException('映射资源版本必须为 1–64 个字符');
        }
      }
      return Map<String, Object?>.unmodifiable({
        'type': type,
        if (type == 'terrain') 'layer': layer,
        'source': source,
        'target': target,
        for (final key in [
          'wall',
          'blockPaint',
          'wallPaint',
          'mode',
          'version',
        ])
          if (rule.containsKey(key)) key: rule[key],
      });
    }),
  );
}

/// A stable identity surrounding one existing, independently exportable format.
/// A core biome reference is never represented as expanded custom rules.
class NamedScheme {
  static const maxMappingJsonBytes = 8 * 1024 * 1024;
  final String id, name;
  final NamedSchemeKind kind;
  final bool isBuiltin;
  final Map<String, Object?> payload;

  NamedScheme({
    required String id,
    required String name,
    required this.kind,
    required Object payload,
    this.isBuiltin = false,
  }) : id = _id(id),
       name = _name(name),
       payload = _validatedPayload(kind, payload, _name(name));

  bool get isCorePreset =>
      kind == NamedSchemeKind.worldRules && payload.containsKey('biome_mode');
  bool get canClone => !isCorePreset;

  static Map<String, Object?> _validatedPayload(
    NamedSchemeKind kind,
    Object source,
    String name,
  ) {
    final map = _object(source, '方案内容');
    if (kind == NamedSchemeKind.worldRules) {
      final scheme = WorldRuleScheme.fromJson(map).copyWith(name: name);
      _budget(scheme.toJson(), WorldRuleScheme.maxJsonBytes, '世界规则方案');
      return Map<String, Object?>.unmodifiable({
        ...scheme.toJson(),
        'rules': List<Map<String, Object?>>.unmodifiable(
          scheme.rules.map(
            (rule) => Map<String, Object?>.unmodifiable(rule.toJson()),
          ),
        ),
      });
    }
    _keys(map, {'format', 'version', 'rules'}, '像素映射方案');
    if (map['format'] != 'terraforge.mapping' ||
        map['version'] is! int ||
        map['version'] != 1) {
      throw const FormatException('不支持的像素映射方案格式');
    }
    final payload = <String, Object?>{
      'format': 'terraforge.mapping',
      'version': 1,
      'rules': validateMappingRules(map['rules']),
    };
    _budget(payload, maxMappingJsonBytes, '像素映射方案');
    return Map<String, Object?>.unmodifiable(payload);
  }

  factory NamedScheme.fromJson(
    Object? source, {
    required NamedSchemeKind kind,
  }) {
    final map = _object(source, '命名方案');
    _keys(map, {'id', 'name', 'builtin', 'payload'}, '命名方案');
    if (map['builtin'] is! bool || map['payload'] == null) {
      throw const FormatException('命名方案字段不完整');
    }
    final name = _name(map['name']);
    final payload = _object(map['payload'], '方案内容');
    if (kind == NamedSchemeKind.worldRules && payload['name'] != name) {
      throw const FormatException('世界规则名称与方案名称不一致');
    }
    return NamedScheme(
      id: _id(map['id']),
      name: name,
      kind: kind,
      isBuiltin: map['builtin'] as bool,
      payload: payload,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'builtin': isBuiltin,
    'payload': payload,
  };
}

/// Bounded immutable collection. Selection and the next-start default are
/// independent; deleting either deterministically falls back to a surviving ID.
class NamedSchemeLibrary {
  static const format = 'terraforge.scheme-library';
  static const version = 1;
  static const maxSchemes = 64;
  static const maxJsonBytes = 16 * 1024 * 1024;
  final NamedSchemeKind kind;
  final List<NamedScheme> schemes;
  final String? selectedId, defaultId;
  final int nextId;

  NamedSchemeLibrary({
    required this.kind,
    List<NamedScheme> schemes = const [],
    this.selectedId,
    this.defaultId,
    this.nextId = 1,
  }) : schemes = List.unmodifiable(schemes) {
    if (schemes.length > maxSchemes) {
      throw const FormatException('每个方案库最多支持 64 个方案');
    }
    _integer(nextId, 1, 2147483647, 'next_id');
    final ids = <String>{}, names = <String>{};
    for (final scheme in schemes) {
      if (scheme.kind != kind ||
          !ids.add(scheme.id) ||
          !names.add(scheme.name.toLowerCase())) {
        throw const FormatException('方案类型不符，或 ID／名称重复');
      }
    }
    if ((schemes.isNotEmpty && (selectedId == null || defaultId == null)) ||
        (selectedId != null && !ids.contains(selectedId)) ||
        (defaultId != null && !ids.contains(defaultId))) {
      throw const FormatException('选中或默认方案不存在');
    }
    _budget(toJson(), maxJsonBytes, '方案库');
  }

  NamedScheme? schemeFor(String id) {
    for (final scheme in schemes) {
      if (scheme.id == id) return scheme;
    }
    return null;
  }

  NamedScheme? get selected =>
      selectedId == null ? null : schemeFor(selectedId!);
  NamedScheme? get defaultScheme =>
      defaultId == null ? null : schemeFor(defaultId!);

  NamedScheme _require(String id) =>
      schemeFor(id) ?? (throw const FormatException('方案不存在'));

  String uniqueName(String base) {
    final name = _name(base),
        names = schemes.map((s) => s.name.toLowerCase()).toSet();
    if (!names.contains(name.toLowerCase())) return name;
    for (var suffix = 2; ; suffix++) {
      final ending = ' $suffix';
      final candidate =
          '${name.substring(0, name.length.clamp(0, 160 - ending.length))}$ending';
      if (!names.contains(candidate.toLowerCase())) return candidate;
    }
  }

  void _distinct(String name, [String? exceptId]) {
    if (schemes.any(
      (s) => s.id != exceptId && s.name.toLowerCase() == name.toLowerCase(),
    )) {
      throw const FormatException('方案名称已存在，请使用其他名称');
    }
  }

  NamedSchemeLibrary create({required String name, Object? payload}) {
    name = _name(name);
    _distinct(name);
    var serial = nextId;
    while (schemeFor('local:${kind.name}:$serial') != null) {
      serial++;
    }
    if (serial >= 2147483647) throw const FormatException('方案 ID 已耗尽');
    final scheme = NamedScheme(
      id: 'local:${kind.name}:$serial',
      name: name,
      kind: kind,
      payload:
          payload ??
          (kind == NamedSchemeKind.mapping
              ? {
                  'format': 'terraforge.mapping',
                  'version': 1,
                  'rules': <Object?>[],
                }
              : WorldRuleScheme(name: name).toJson()),
    );
    return NamedSchemeLibrary(
      kind: kind,
      schemes: [...schemes, scheme],
      selectedId: scheme.id,
      defaultId: defaultId ?? scheme.id,
      nextId: serial + 1,
    );
  }

  NamedSchemeLibrary clone(String id, {String? name}) {
    final source = _require(id);
    if (!source.canClone) {
      throw const FormatException('核心内置方案尚未提供规则展开，不能克隆为可编辑方案');
    }
    return create(
      name:
          name ??
          uniqueName(
            '${source.name.substring(0, source.name.length.clamp(0, 157))} 副本',
          ),
      payload: source.payload,
    );
  }

  NamedSchemeLibrary _replace(NamedScheme scheme) => NamedSchemeLibrary(
    kind: kind,
    schemes: [for (final item in schemes) item.id == scheme.id ? scheme : item],
    selectedId: selectedId,
    defaultId: defaultId,
    nextId: nextId,
  );

  NamedSchemeLibrary rename(String id, String name) {
    final source = _require(id);
    if (source.isBuiltin) throw const FormatException('内置方案不能重命名');
    name = _name(name);
    _distinct(name, id);
    return _replace(
      NamedScheme(id: id, name: name, kind: kind, payload: source.payload),
    );
  }

  NamedSchemeLibrary updateSelected(Object payload, {String? name}) {
    final source = selected;
    if (source == null) throw const FormatException('请先新建或选择方案');
    if (source.isBuiltin) throw const FormatException('内置方案为只读，请新建自定义方案');
    final nextName = _name(name ?? source.name);
    _distinct(nextName, source.id);
    return _replace(
      NamedScheme(id: source.id, name: nextName, kind: kind, payload: payload),
    );
  }

  NamedSchemeLibrary select(String id) {
    _require(id);
    return NamedSchemeLibrary(
      kind: kind,
      schemes: schemes,
      selectedId: id,
      defaultId: defaultId,
      nextId: nextId,
    );
  }

  NamedSchemeLibrary setDefault(String id) {
    _require(id);
    return NamedSchemeLibrary(
      kind: kind,
      schemes: schemes,
      selectedId: selectedId,
      defaultId: id,
      nextId: nextId,
    );
  }

  NamedSchemeLibrary delete(String id, {required bool confirmed}) {
    final source = _require(id);
    if (!confirmed) throw const FormatException('删除方案需要确认');
    if (source.isBuiltin) throw const FormatException('内置方案不能删除');
    final remaining = schemes.where((s) => s.id != id).toList();
    final fallback = remaining.isEmpty ? null : remaining.first.id;
    final nextDefault = defaultId == id ? fallback : defaultId;
    return NamedSchemeLibrary(
      kind: kind,
      schemes: remaining,
      selectedId: selectedId == id ? nextDefault : selectedId,
      defaultId: nextDefault,
      nextId: nextId,
    );
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'kind': kind.name,
    'selected_id': selectedId,
    'default_id': defaultId,
    'next_id': nextId,
    'schemes': schemes.map((s) => s.toJson()).toList(),
  };
  String encode() => jsonEncode(toJson());

  factory NamedSchemeLibrary.fromJson(Object? source) {
    final map = _object(source, '方案库');
    _keys(map, {
      'format',
      'version',
      'kind',
      'selected_id',
      'default_id',
      'next_id',
      'schemes',
    }, '方案库');
    if (map['format'] != format ||
        map['version'] is! int ||
        map['version'] != version ||
        map['schemes'] is! List ||
        (map['schemes'] as List).length > maxSchemes ||
        !NamedSchemeKind.values.any((kind) => kind.name == map['kind'])) {
      throw const FormatException('不支持的方案库格式或方案数量超限');
    }
    _budget(map, maxJsonBytes, '方案库');
    final kind = NamedSchemeKind.values.firstWhere(
      (kind) => kind.name == map['kind'],
    );
    return NamedSchemeLibrary(
      kind: kind,
      schemes: (map['schemes'] as List)
          .map((s) => NamedScheme.fromJson(s, kind: kind))
          .toList(),
      selectedId: map['selected_id'] == null ? null : _id(map['selected_id']),
      defaultId: map['default_id'] == null ? null : _id(map['default_id']),
      nextId: _integer(map['next_id'], 1, 2147483647, 'next_id'),
    );
  }

  factory NamedSchemeLibrary.decode(String source) {
    if (utf8.encode(source).length > maxJsonBytes) {
      throw const FormatException('方案库超过 16 MiB');
    }
    return NamedSchemeLibrary.fromJson(jsonDecode(source));
  }
}
