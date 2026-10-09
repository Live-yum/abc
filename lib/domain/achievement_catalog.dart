import 'dart:convert';

import 'achievements.dart';
import 'resource_catalog.dart';

class AchievementConditionDefinition {
  const AchievementConditionDefinition(this.id, this.kind, this.maximum);
  final String id, kind;
  final num? maximum;
  bool get editable =>
      kind == 'boolean' ||
      ((kind == 'int' || kind == 'float') && maximum != null);
  bool matches(String storedKind) => editable && kind == storedKind;
}

class AchievementDefinition {
  AchievementDefinition(
    this.id,
    this.name,
    this.description,
    this.category,
    Map<String, AchievementConditionDefinition> conditions,
  ) : conditions = Map.unmodifiable(conditions);
  final String id, name, description, category;
  final Map<String, AchievementConditionDefinition> conditions;
}

class AchievementCompletionResult {
  const AchievementCompletionResult(this.file, this.changed, this.skipped);
  final AchievementFile file;

  /// Counts of changed and skipped imported conditions, not achievements.
  final int changed, skipped;
}

/// Metadata is supplied by an independently imported, version-pinned resource
/// pack. Matching always requires exact achievement ID, condition ID and kind.
class AchievementCatalog {
  AchievementCatalog._(Map<String, AchievementDefinition> definitions)
    : definitions = Map.unmodifiable(definitions);
  final Map<String, AchievementDefinition> definitions;

  factory AchievementCatalog.fromResourceCatalog(ResourceCatalog catalog) {
    final rows = catalog.families['achievements'] ?? const <CatalogEntry>[];
    if (rows.length > 1000) {
      throw const FormatException('成就目录超过 1000 条');
    }
    var count = 0;
    final definitions = <String, AchievementDefinition>{};
    for (final row in rows) {
      final rawId = row.fields['id'];
      if (rawId is! String) {
        throw const FormatException('成就 ID 必须是字符串');
      }
      _checkId(rawId);
      if (definitions.containsKey(rawId)) {
        throw const FormatException('成就 ID 重复');
      }
      final conditions = row.fields['conditions'];
      if (conditions is! List ||
          conditions.isEmpty ||
          conditions.length > 1000) {
        throw const FormatException('成就条件为空或过大');
      }
      final typed = <String, AchievementConditionDefinition>{};
      for (final condition in conditions) {
        if (++count > 7000 ||
            condition is! Map ||
            condition['id'] is! String ||
            condition['kind'] is! String) {
          throw const FormatException('成就条件无效或过大');
        }
        final id = condition['id'] as String;
        _checkId(id);
        if (typed.containsKey(id)) {
          throw const FormatException('成就条件 ID 重复');
        }
        final kind = condition['kind'] as String;
        final max = condition['max'];
        num? maximum;
        if (max is num &&
            max.isFinite &&
            max > 0 &&
            ((kind == 'int' &&
                    max <= 2147483647 &&
                    max == max.truncateToDouble()) ||
                (kind == 'float' && max <= 3.4028234663852886e38))) {
          maximum = max;
        }
        typed[id] = AchievementConditionDefinition(id, kind, maximum);
      }
      definitions[rawId] = AchievementDefinition(
        rawId,
        row.name,
        _label(row.fields['description']),
        row.category,
        typed,
      );
    }
    return AchievementCatalog._(definitions);
  }

  AchievementFile createFile() {
    if (definitions.isEmpty ||
        definitions.values.any(
          (record) =>
              record.conditions.values.any((condition) => !condition.editable),
        )) {
      throw const FormatException('新建需要非空且所有条件均有效的成就目录');
    }
    return AchievementFile.blank({
      for (final record in definitions.values)
        record.id: {for (final c in record.conditions.values) c.id: c.kind},
    });
  }

  AchievementFile applyCondition(
    AchievementFile original,
    String id,
    String conditionId, {
    num? value,
    bool? completed,
  }) {
    if ((value == null) == (completed == null)) {
      throw ArgumentError('必须且只能指定进度或完成状态');
    }
    final record = original.records
        .where((record) => record.id == id)
        .firstOrNull;
    final condition = record?.conditions
        .where((c) => c.id == conditionId)
        .firstOrNull;
    if (condition == null) throw ArgumentError('未找到文件中的成就条件');
    final definition = definitions[id]?.conditions[conditionId];
    // Imported booleans remain safely editable without metadata. An explicit
    // conflicting definition cannot override the stored primitive encoding.
    if (definition == null
        ? condition.kind != 'boolean'
        : !definition.matches(condition.kind)) {
      throw StateError('此条件类型不匹配或缺少经过验证的计数上限，仅可读取');
    }
    final candidate = original.clone();
    if (value != null) {
      if (condition.kind == 'boolean') throw ArgumentError('普通条件没有计数值');
      candidate.setProgress(
        id,
        conditionId,
        value,
        maximum: definition!.maximum!,
      );
    } else {
      candidate.setConditionCompleted(
        id,
        conditionId,
        completed!,
        maximum: definition?.maximum,
      );
    }
    return candidate;
  }

  /// Only the known intersection is completed. Unsupported/missing metadata,
  /// unknown records, and unmatched conditions remain byte-for-byte untouched.
  AchievementCompletionResult completeKnown(AchievementFile original) {
    final candidate = original.clone();
    var changed = 0, skipped = 0;
    for (final record in original.records) {
      for (final condition in record.conditions) {
        final definition = definitions[record.id]?.conditions[condition.id];
        if (definition == null || !definition.matches(condition.kind)) {
          skipped++;
          continue;
        }
        final differs =
            !condition.completed ||
            (condition.kind != 'boolean' &&
                condition.value != definition.maximum);
        candidate.setConditionCompleted(
          record.id,
          condition.id,
          true,
          maximum: definition.maximum,
        );
        if (differs) changed++;
      }
    }
    return AchievementCompletionResult(candidate, changed, skipped);
  }
}

void _checkId(String id) {
  final bytes = utf8.encode(id);
  if (id.isEmpty ||
      id.contains('\u0000') ||
      bytes.length > 4096 ||
      utf8.decode(bytes) != id) {
    throw const FormatException('成就 ID 无效或过长');
  }
}

String _label(Object? value) {
  if (value is String) return value;
  if (value is Map) {
    for (final locale in ['zh-Hans', 'en-US']) {
      if (value[locale] is String) return value[locale] as String;
    }
  }
  return '';
}
