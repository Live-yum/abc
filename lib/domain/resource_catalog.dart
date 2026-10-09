// Deep immutable snapshots prevent edits to verified metadata through nested maps.
Object? _freeze(Object? value, [int depth = 0]) {
  if (depth > 64) throw const FormatException('资源目录嵌套过深');
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freeze(entry.value, depth + 1),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map((v) => _freeze(v, depth + 1)));
  }
  return value;
}

/// A local, version-pinned row. Numeric and compound source IDs are never remapped.
class CatalogEntry {
  final String family;
  final String id;
  final Map<String, Object?> fields;
  late final String searchText =
      '$id $name ${fields['internalName'] ?? ''} ${fields['persistentId'] ?? ''} ${fields['name'] ?? ''}'
          .toLowerCase();
  CatalogEntry(this.family, Map<String, Object?> values)
    : fields = _freeze(values) as Map<String, Object?>,
      id = '${values['id']}';
  int? get numericId => int.tryParse(id);
  String get name {
    final value = fields['name'];
    if (value is Map) {
      for (final locale in ['zh-Hans', 'en-US']) {
        final label = value[locale];
        if (label is String && label.isNotEmpty) return label;
      }
    }
    if (value is String && value.isNotEmpty) return value;
    return '${fields['internalName'] ?? id}';
  }

  String? get iconPath => fields['icon'] as String?;
  String get category {
    final explicit = fields['category'] ?? fields['npcType'];
    if (explicit != null) return '$explicit';
    if (family == 'buffs') {
      final flags = fields['mainFlags'];
      return flags is Map && flags['debuff'] == true ? '减益' : '增益';
    }
    if (family == 'items' || family == 'research') {
      final gameplay = fields['gameplay'];
      final stats = gameplay is Map ? gameplay : const <String, Object?>{};
      num number(Object? value) => value is num ? value : 0;
      if (number(stats['pick']) > 0 ||
          number(stats['axe']) > 0 ||
          number(stats['hammer']) > 0) {
        return '工具';
      }
      if (number(stats['ammo']) > 0) return '弹药';
      if (number(stats['damage']) > 0) return '武器';
      if (stats['accessory'] == true) return '配饰';
      if ([
        fields['headSlot'],
        fields['bodySlot'],
        fields['legSlot'],
      ].any((v) => v is num && v >= 0)) {
        return '装备';
      }
      if (fields['createTile'] is num && (fields['createTile'] as num) >= 0) {
        return '方块与家具';
      }
      if (number(fields['createWall']) > 0) return '墙';
      if (stats['consumable'] == true) return '消耗品';
      return '其他';
    }
    return '';
  }
}

class ResourceCatalog {
  final String gameVersion;
  final Map<String, Object?> provenance;
  final Map<String, List<CatalogEntry>> families;
  late final Map<String, Map<String, CatalogEntry>> _indexes = {
    for (final family in families.entries)
      family.key: {for (final row in family.value) row.id: row},
  };
  ResourceCatalog({
    required this.gameVersion,
    required Map<String, Object?> provenance,
    required Map<String, List<CatalogEntry>> families,
  }) : provenance = _freeze(provenance) as Map<String, Object?>,
       families = Map.unmodifiable({
         for (final e in families.entries)
           e.key: List<CatalogEntry>.unmodifiable(e.value),
       });
  CatalogEntry? byId(String family, Object id) => _indexes[family]?['$id'];
  List<CatalogEntry> search(
    String family, {
    String query = '',
    String? category,
  }) {
    final terms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty);
    return (families[family] ?? const <CatalogEntry>[])
        .where(
          (row) =>
              (category == null ||
                  category.isEmpty ||
                  row.category == category) &&
              terms.every(row.searchText.contains),
        )
        .toList(growable: false);
  }

  /// Source-ordered candidates for the verified native match_colors operation.
  /// Input flags bit 0 = painted, bit 1 = wall. IDs are actual game IDs.
  /// Ordinary tile colors are intentionally never treated as stable candidates.
  List<Map<String, Object>> stableColorCandidates({String? expectedVersion}) {
    if (expectedVersion != null && expectedVersion != gameVersion) {
      throw StateError('稳定颜色资源版本不匹配：$gameVersion / $expectedVersion');
    }
    final rows = families['stable-rgb'];
    if (rows == null || rows.isEmpty) {
      throw StateError('请导入包含 stable-rgb 的本地资源包');
    }
    if (rows.length > 65535) {
      throw const FormatException('稳定颜色候选超过原生接口上限');
    }
    final result = <Map<String, Object>>[];
    for (var ordinal = 0; ordinal < rows.length; ordinal++) {
      final row = rows[ordinal];
      final data = row.fields;
      final kind = data['kind'], type = data['type'];
      final variant = data['variant'], paint = data['paint'];
      final color = data['rgb'];
      if (row.id != '$ordinal' ||
          data['stable'] != 1 ||
          kind is! int ||
          kind < 0 ||
          kind > 1 ||
          type is! int ||
          type < 0 ||
          type > 65535 ||
          variant != 0 ||
          paint is! int ||
          paint < 0 ||
          paint > 30 ||
          color is! List ||
          color.length != 3 ||
          color.any((v) => v is! int || v < 0 || v > 255)) {
        throw FormatException('稳定颜色候选 $ordinal 无效或包含不支持的变体');
      }
      if (byId(kind == 0 ? 'tiles' : 'walls', '$type:$variant') == null ||
          (paint != 0 && byId('paints', paint) == null)) {
        throw FormatException('稳定颜色候选 $ordinal 缺少同版本材料来源');
      }
      result.add(
        Map<String, Object>.unmodifiable({
          'id': ordinal,
          'rgb':
              ((color[0] as int) << 16) |
              ((color[1] as int) << 8) |
              (color[2] as int),
          'flags': (paint != 0 ? 1 : 0) | (kind == 1 ? 2 : 0),
          'blockID': kind == 0 ? type : 0,
          'wallID': kind == 1 ? type : 0,
          'blockPaint': kind == 0 ? paint : 0,
          'wallPaint': kind == 1 ? paint : 0,
          'variant': variant as int,
          'version': gameVersion,
        }),
      );
    }
    return List<Map<String, Object>>.unmodifiable(result);
  }

  Set<String> categories(String family) => {
    for (final row in families[family] ?? const <CatalogEntry>[])
      if (row.category.isNotEmpty) row.category,
  };
  int get length => families.values.fold(0, (sum, rows) => sum + rows.length);
}
