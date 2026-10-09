import 'dart:convert';

import 'resource_catalog.dart';
import 'world_rules.dart';

/// Literal source rules supplied by a private, version-pinned resource pack.
/// A related native mode is a label only; it does not imply equal behavior.
class WorldRulePreset {
  final String id, name, badge, description;
  final String? builtinMode;
  final List<WorldTileRule> rules;
  const WorldRulePreset._({
    required this.id,
    required this.name,
    required this.badge,
    required this.description,
    required this.builtinMode,
    required this.rules,
  });

  String get sourceLabel => '本地资源包 · 原方案规则';

  /// Native biome mode is deliberately absent, so this is fully editable.
  WorldRuleScheme editableCopy({String? name}) => WorldRuleScheme(
    name:
        name ??
        '${this.name.length > 157 ? this.name.substring(0, 157) : this.name} 副本',
    rules: rules.map((rule) => WorldTileRule.fromJson(rule.toJson())).toList(),
  );
}

class WorldRulePresets {
  static const family = 'world-rule-presets';
  final List<WorldRulePreset> presets;
  WorldRulePresets._(List<WorldRulePreset> presets)
    : presets = List.unmodifiable(presets);

  factory WorldRulePresets.fromCatalog(
    ResourceCatalog catalog, {
    required String expectedVersion,
  }) {
    final rows = catalog.families[family];
    if (rows == null || rows.isEmpty) return WorldRulePresets._([]);
    if (catalog.gameVersion != expectedVersion) {
      throw const FormatException('原方案规则与游戏版本不匹配');
    }
    final provenance = catalog.provenance['worldRulePresets'];
    final objects = catalog.provenance['sourceObjects'];
    if (provenance is! Map ||
        provenance.keys.toSet().difference({
          'schema',
          'gameVersion',
          'inputSha256',
          'sourceFiles',
        }).isNotEmpty ||
        provenance['schema'] is! int ||
        provenance['schema'] != 1 ||
        provenance['gameVersion'] != expectedVersion ||
        !_digest(provenance['inputSha256']) ||
        objects is! Map ||
        objects['local-world-rule-presets.json'] != provenance['inputSha256']) {
      throw const FormatException('原方案规则缺少已校验的来源信息');
    }
    final sources = provenance['sourceFiles'];
    if (sources is! Map || sources.isEmpty || sources.length > 16) {
      throw const FormatException('原方案规则缺少固定来源文件');
    }
    for (final source in sources.entries) {
      if (!_sourcePath(source.key) ||
          !_digest(source.value) ||
          objects[source.key] != source.value) {
        throw const FormatException('原方案规则来源文件校验不匹配');
      }
    }
    if (rows.length > 128) {
      throw const FormatException('原方案规则目录超过 128 个方案');
    }
    final result = <WorldRulePreset>[];
    final ids = <String>{}, modes = <String>{};
    for (final row in rows) {
      final value = row.fields;
      const required = {'id', 'name', 'badge', 'description', 'rules'};
      if (row.family != family ||
          !value.keys.toSet().containsAll(required) ||
          value.keys.any(
            (key) => !{...required, 'builtinMode'}.contains(key),
          ) ||
          value['id'] is! String ||
          !RegExp(r'^[a-z][a-z0-9-]{0,127}$').hasMatch(row.id) ||
          !ids.add(row.id) ||
          !_label(value['name'], 160) ||
          !_label(value['badge'], 80) ||
          !_label(value['description'], 2000)) {
        throw const FormatException('原方案规则目录条目无效或重复');
      }
      final mode = value['builtinMode'];
      if (value.containsKey('builtinMode') &&
          (mode is! String ||
              !WorldRuleScheme.builtinModes.contains(mode) ||
              !modes.add(mode))) {
        throw const FormatException('原方案规则的相关内置模式无效或重复');
      }
      final rules = value['rules'];
      if (rules is! List ||
          rules.isEmpty ||
          rules.length > 128 ||
          utf8.encode(jsonEncode(value)).length >
              WorldRuleScheme.maxJsonBytes) {
        throw const FormatException('原方案规则必须为 1–128 条且不超过 256 KiB');
      }
      result.add(
        WorldRulePreset._(
          id: row.id,
          name: value['name'] as String,
          badge: value['badge'] as String,
          description: value['description'] as String,
          builtinMode: mode as String?,
          rules: List.unmodifiable(rules.map(WorldTileRule.fromJson)),
        ),
      );
    }
    return WorldRulePresets._(result);
  }

  WorldRulePreset? byId(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  static bool _digest(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  static bool _label(Object? value, int maximum) =>
      value is String && value.trim().isNotEmpty && value.length <= maximum;

  static bool _sourcePath(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 512 &&
      !value.contains(RegExp(r'[:\\]')) &&
      value
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');
}
