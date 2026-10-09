import 'resource_catalog.dart';

/// Preview-only conversion planning. Binary projection belongs to the genuine
/// codec, using a temporary document, never a patch to the open player handle.
/// No historical gameplay caps are inferred from the current resource catalog.
abstract final class PlayerConversion {
  static const minimumTarget = 38;
  static const maximumTarget = 326;

  static PlayerConversionPlan prepare(
    Map<String, Object?> source,
    int targetVersion, {
    ResourceCatalog? catalog,
  }) {
    final sourceVersion = source['version'];
    if (sourceVersion is! int ||
        sourceVersion < minimumTarget ||
        sourceVersion > maximumTarget ||
        targetVersion < minimumTarget ||
        targetVersion > maximumTarget) {
      throw const FormatException('版本转换仅支持 38–326；旧名称物品与未来版本不能安全转换。');
    }
    final original = _snapshot(source) as Map<String, Object?>;
    final candidate = Map<String, Object?>.from(original);
    if (sourceVersion != targetVersion) {
      candidate['version'] = targetVersion;
      final builderCount = switch (targetVersion) {
        < 164 => 0,
        < 167 => 8,
        < 197 => 10,
        < 230 => 11,
        _ => 12,
      };
      // The codec uses twelve default model slots when the disk has none.
      final modelCount = builderCount == 0 ? 12 : builderCount;
      final builders = original['builderAccStatus'];
      if (builders is! List || builders.any((value) => value is! int)) {
        throw const FormatException('建造辅助状态缺失或无效。');
      }
      candidate['builderAccStatus'] = List<Object?>.generate(
        modelCount,
        (i) => i < builders.length ? builders[i] : 0,
      );
      // Keep unknown layout metadata until the codec explicitly projects it out.
      final layout = original['tailLayout'];
      candidate['tailLayout'] = <String, Object?>{
        if (layout is Map) ...Map<String, Object?>.from(layout),
        'builderAccStatusCount': builderCount,
        'includesDeathMetadata': targetVersion >= 200,
      }..remove('omitVoiceVariant');
      if (targetVersion >= 135 && candidate['metadata'] == null) {
        candidate['metadata'] = {
          'magicAndType': '244154697780061554',
          'revision': 0,
          'favoriteFlags': 0,
        };
      }
      if (targetVersion < 218 && candidate['difficulty'] == 3) {
        candidate['difficulty'] = 0;
      }
      final profile = PlayerConversionProfile.fromCatalog(
        catalog,
        targetVersion,
      );
      if (profile != null) {
        for (final field in profile.ranges.keys) {
          final value = candidate[field];
          final rule = profile.ranges[field]!;
          if (value is int) {
            if (rule.behavior == 'clamp') {
              candidate[field] = value.clamp(rule.minimum, rule.maximum);
            } else if (rule.behavior == 'resetAbove' && value > rule.maximum) {
              candidate[field] = rule.fallback;
            }
          }
        }
      }
    }
    return PlayerConversionPlan._(
      original,
      _snapshot(candidate) as Map<String, Object?>,
      sourceVersion,
      targetVersion,
    );
  }
}

class PlayerConversionPlan {
  PlayerConversionPlan._(
    this.source,
    this.candidate,
    this.sourceVersion,
    this.targetVersion,
  );
  final Map<String, Object?> source, candidate;
  final int sourceVersion, targetVersion;

  /// Call only with JSON decoded from the candidate's newly encoded binary.
  /// In-memory JSON from open_json is insufficient: unsupported slots and flags
  /// still exist in that model until it passes through the binary codec.
  PlayerConversionPreview reviewProjection(
    Map<String, Object?> decoded, {
    ResourceCatalog? catalog,
  }) {
    if (decoded['version'] != targetVersion) {
      throw const FormatException('引擎投影的目标版本不匹配。');
    }
    final projected = _snapshot(decoded) as Map<String, Object?>;
    final changes = <PlayerConversionChange>[];
    void compare(
      Object? before,
      Object? after,
      String path, {
      bool beforeExists = true,
      bool afterExists = true,
    }) {
      if (path == '/version') return;
      if (beforeExists && afterExists && _same(before, after)) return;
      // Each item is one reviewable record, including unknown slot metadata.
      if ((before is Map && before.containsKey('itemType')) ||
          (after is Map && after.containsKey('itemType'))) {
        changes.add(
          PlayerConversionChange._(
            path,
            before,
            after,
            beforeExists,
            afterExists,
          ),
        );
        return;
      }
      if (before is Map && after is Map) {
        for (final key in {...before.keys, ...after.keys}) {
          compare(
            before[key],
            after[key],
            '$path/${_escape(key as String)}',
            beforeExists: before.containsKey(key),
            afterExists: after.containsKey(key),
          );
        }
      } else if (before is List && after is List) {
        final length = before.length > after.length
            ? before.length
            : after.length;
        for (var i = 0; i < length; i++) {
          compare(
            i < before.length ? before[i] : null,
            i < after.length ? after[i] : null,
            '$path/$i',
            beforeExists: i < before.length,
            afterExists: i < after.length,
          );
        }
      } else {
        changes.add(
          PlayerConversionChange._(
            path,
            before,
            after,
            beforeExists,
            afterExists,
          ),
        );
      }
    }

    compare(source, projected, '');
    final blockers = <String>[];
    if (targetVersion != sourceVersion) {
      if (targetVersion != 326 || catalog?.gameVersion != '1.4.5.8') {
        blockers.add('缺少目标版本的物品、前缀、状态、堆叠上限与研究名称资料。');
      } else {
        _checkCurrentCatalog(projected, catalog!, blockers);
      }
      final profile = PlayerConversionProfile.fromCatalog(
        catalog,
        targetVersion,
      );
      if (profile == null) {
        blockers.add('缺少目标版本的发型、服装与声音 ID 兼容资料。');
      } else {
        for (final entry in profile.ranges.entries) {
          final value = projected[entry.key];
          if (value is! int ||
              value < entry.value.minimum ||
              value > entry.value.maximum) {
            blockers.add('/${entry.key}：超出目标版本已验证的范围。');
          }
        }
      }
      if (blockers.isNotEmpty) {
        blockers.add('二进制布局验证不能证明游戏兼容；当前禁止转换导出。');
      }
    }
    return PlayerConversionPreview._(
      projected,
      List.unmodifiable(changes),
      List.unmodifiable(blockers),
    );
  }
}

/// Optional private resource metadata derived from a pinned game loader.
/// Render asset counts cannot stand in for this profile. No proprietary source
/// or extracted profile is bundled with the application.
class PlayerConversionProfile {
  PlayerConversionProfile._(this.ranges);
  final Map<String, PlayerConversionRange> ranges;
  static PlayerConversionProfile? fromCatalog(
    ResourceCatalog? catalog,
    int version,
  ) {
    if (version != 326 || catalog?.gameVersion != '1.4.5.8') return null;
    final row = catalog?.byId('player-conversion-profiles', version)?.fields;
    if (row == null ||
        row['gameVersion'] != catalog!.gameVersion ||
        row['schema'] != 1 ||
        row['sourceCommit'] is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(row['sourceCommit'] as String) ||
        row['sourceFiles'] is! List ||
        (row['sourceFiles'] as List).isEmpty ||
        row['ranges'] is! Map) {
      return null;
    }
    final ranges = <String, PlayerConversionRange>{};
    for (final key in ['hair', 'skinVariant', 'voiceVariant']) {
      final data = (row['ranges'] as Map)[key];
      if (data is! Map) return null;
      final min = data['minimum'], max = data['maximum'];
      final fallback = data['fallback'], behavior = data['behavior'];
      if (min is! int ||
          max is! int ||
          min < 0 ||
          max < min ||
          max > 2147483647 ||
          !['clamp', 'resetAbove'].contains(behavior) ||
          fallback is! int ||
          fallback < min ||
          fallback > max) {
        return null;
      }
      ranges[key] = PlayerConversionRange._(
        min,
        max,
        fallback,
        behavior as String,
      );
    }
    return PlayerConversionProfile._(Map.unmodifiable(ranges));
  }
}

class PlayerConversionRange {
  PlayerConversionRange._(
    this.minimum,
    this.maximum,
    this.fallback,
    this.behavior,
  );
  final int minimum, maximum, fallback;
  final String behavior;
}

void _checkCurrentCatalog(
  Map<String, Object?> document,
  ResourceCatalog catalog,
  List<String> blockers,
) {
  void check(Object? value, String path) {
    if (value is Map) {
      if (value.containsKey('itemType') && value['itemType'] != 0) {
        final id = value['itemType'];
        final item = catalog.byId('items', '$id');
        final stack = value['stack'];
        final limit = item?.fields['maxStack'];
        if (id is! int || item == null) {
          blockers.add('$path：物品 ID 不在目标版本目录中。');
        } else {
          if (stack is! int || limit is! int || stack < 1 || stack > limit) {
            blockers.add('$path：数量超限或缺少可靠堆叠上限。');
          }
          final prefix = value['prefix'];
          final allowed = item.fields['eligiblePrefixes'];
          if (prefix is! int ||
              (prefix != 0 &&
                  (catalog.byId('prefixes', prefix) == null ||
                      allowed is! List ||
                      !allowed.contains(prefix)))) {
            blockers.add('$path：前缀与物品的兼容性未通过验证。');
          }
        }
      }
      if (value.containsKey('buffType') &&
          value['buffType'] != 0 &&
          (value['buffType'] is! int ||
              catalog.byId('buffs', '${value['buffType']}') == null)) {
        blockers.add('$path：状态 ID 不在目标版本目录中。');
      }
      for (final entry in value.entries) {
        check(entry.value, '$path/${_escape(entry.key as String)}');
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        check(value[i], '$path/$i');
      }
    }
  }

  check(document, '');
  final hairDye = document['hairDye'];
  final hairDyes = catalog.families['dye-shaders'] ?? <CatalogEntry>[];
  if (hairDye is! int ||
      (hairDye != 0 &&
          !hairDyes.any(
            (row) =>
                row.fields['kind'] == 'hair' &&
                row.fields['shaderId'] == hairDye,
          ))) {
    blockers.add('/hairDye：染发 ID 不在目标版本目录中。');
  }
  final research = document['creativeItemSacrifices'];
  if (research is List && research.isNotEmpty) {
    final known = {
      for (final item in catalog.families['research'] ?? <CatalogEntry>[])
        if (item.fields['persistentId'] is String) item.fields['persistentId'],
    };
    for (var i = 0; i < research.length; i++) {
      final record = research[i];
      if (record is! Map || !known.contains(record['persistentId'])) {
        blockers.add('/creativeItemSacrifices/$i：研究名称缺少目标物品映射。');
      }
    }
  }
}

class PlayerConversionPreview {
  PlayerConversionPreview._(this.projected, this.changes, this.blockers);
  final Map<String, Object?> projected;
  final List<PlayerConversionChange> changes;
  final List<String> blockers;
  bool get requiresLossConfirmation => changes.isNotEmpty;
  bool get gameplayCompatibilityBlocked => blockers.isNotEmpty;
  // Deliberately no export/commit API. A UI confirmation and a transactional
  // engine operation must be implemented before using a preview to export.
}

class PlayerConversionChange {
  PlayerConversionChange._(
    this.path,
    this.before,
    this.after,
    this.beforeExists,
    this.afterExists,
  );
  final String path;
  final Object? before, after;
  final bool beforeExists, afterExists;
  bool get removed => beforeExists && !afterExists;
}

String _escape(String key) => key.replaceAll('~', '~0').replaceAll('/', '~1');

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => _same(a[i], b[i]));
  }
  return a == b;
}

Object? _snapshot(Object? value, [int depth = 0]) {
  if (depth > 64) throw const FormatException('角色数据嵌套过深。');
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _snapshot(entry.value, depth + 1),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => _snapshot(item, depth + 1)),
    );
  }
  if (value == null ||
      value is String ||
      value is bool ||
      value is int ||
      (value is double && value.isFinite)) {
    return value;
  }
  throw const FormatException('角色数据包含非 JSON 值。');
}
