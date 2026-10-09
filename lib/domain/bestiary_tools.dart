import 'resource_catalog.dart';

class BestiaryEntry {
  const BestiaryEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.killCount,
    required this.sighted,
    required this.chatted,
    required this.searchText,
    this.fullUnlockCount,
  });
  final String id, name, kind, searchText;
  final int killCount;
  final bool sighted, chatted;
  final int? fullUnlockCount;
  bool get editable => kind.isNotEmpty;
  bool get unlocked =>
      kind == 'kills' ? killCount > 0 : killCount > 0 || sighted || chatted;
}

/// Pure edits of verified, locally imported metadata. No numeric NPC ID is ever
/// substituted for the persistent save ID. Unrecognized save fields survive.
abstract final class BestiaryTools {
  static const maxKillCount = 999999999;
  static const maxEntries = 50000;
  static const _sections = ['kills', 'sightings', 'chats'];

  static String _id(Object? row) {
    final id = row is String
        ? row
        : row is Map
        ? row['persistentNpcId']
        : null;
    if (id is! String || id.isEmpty || id.length > 1024) {
      throw const FormatException('图鉴持久 ID 无效');
    }
    return id;
  }

  static Map<String, List<Object?>> _sectionsOf(Map<String, Object?> data) {
    final result = <String, List<Object?>>{};
    for (final key in _sections) {
      final rows = data[key];
      if (rows is! List || rows.length > maxEntries) {
        throw const FormatException('世界不含支持的图鉴区段，或条目超过上限');
      }
      final seen = <String>{};
      for (final row in rows) {
        if (!seen.add(_id(row))) throw const FormatException('图鉴包含重复持久 ID');
        if (key == 'kills' &&
            (row is! Map ||
                row['killCount'] is! int ||
                (row['killCount'] as int) < 0 ||
                (row['killCount'] as int) > maxKillCount)) {
          throw const FormatException('击杀数量必须为 0–999,999,999 的整数');
        }
      }
      result[key] = List<Object?>.from(rows);
    }
    return result;
  }

  static List<Map> _ownRules(Object? raw, String id, [int depth = 0]) {
    if (raw is! Map || depth > 8) return [];
    if (raw['kind'] == 'highest-of-multiple' && raw['children'] is List) {
      return [
        for (final child in raw['children'] as List)
          ..._ownRules(child, id, depth + 1),
      ];
    }
    if (raw['persistentNpcId'] == id ||
        (raw['kind'] == 'gold-critter' &&
            raw['goldCritterPersistentId'] == id)) {
      return [raw];
    }
    return [];
  }

  static Map<
    String,
    ({CatalogEntry row, String kind, int? count, String search})
  >
  _metadata(ResourceCatalog? catalog) {
    final result =
        <
          String,
          ({CatalogEntry row, String kind, int? count, String search})
        >{};
    final rows = catalog?.families['bestiary'] ?? const <CatalogEntry>[];
    if (rows.length > maxEntries) throw const FormatException('图鉴目录超过上限');
    final numericIds = <String>{};
    for (final row in rows) {
      if (!numericIds.add(row.id)) throw const FormatException('图鉴目录 ID 重复');
      final rawId = row.fields['persistentNpcId'];
      if (rawId is! String || rawId.isEmpty || rawId.length > 1024) continue;
      final rules = _ownRules(row.fields['unlockRule'], rawId);
      final rule = rules.firstOrNull;
      if (rules.any(
        (r) =>
            r['kind'] != rule?['kind'] ||
            r['killCountNeededToFullyUnlock'] !=
                rule?['killCountNeededToFullyUnlock'],
      )) {
        throw const FormatException('图鉴持久 ID 对应的规则冲突');
      }
      var kind = '';
      int? count;
      switch (rule?['kind']) {
        case 'kills':
        case 'world-conditional-kills':
          final value = rule?['killCountNeededToFullyUnlock'];
          if (value is int && value > 0 && value <= maxKillCount) {
            kind = 'kills';
            count = value;
          }
        case 'chat':
          kind = 'chats';
        case 'sighting':
        case 'gold-critter':
          kind = 'sightings';
      }
      final prior = result[rawId];
      // Official variants can share one persistent tracker. Only identical
      // tracker/threshold bindings may coalesce; a collision cannot be edited.
      if (prior != null && (prior.kind != kind || prior.count != count)) {
        throw const FormatException('图鉴持久 ID 对应的规则冲突');
      }
      result[rawId] = (
        row: prior?.row ?? row,
        kind: kind,
        count: count,
        search: '${prior?.search ?? ''} ${row.searchText} $rawId',
      );
    }
    return result;
  }

  static List<BestiaryEntry> entries(
    Map<String, Object?> bestiary,
    ResourceCatalog? catalog,
  ) {
    final sections = _sectionsOf(bestiary), meta = _metadata(catalog);
    final kills = {
      for (final row in sections['kills']!)
        _id(row): (row as Map)['killCount'] as int,
    };
    final sights = sections['sightings']!.map(_id).toSet();
    final chats = sections['chats']!.map(_id).toSet();
    final ids = {...meta.keys, ...kills.keys, ...sights, ...chats};
    if (ids.length > maxEntries) throw const FormatException('图鉴条目超过上限');
    return [
      for (final id in ids)
        BestiaryEntry(
          id: id,
          name: meta[id]?.row.name ?? id,
          kind: meta[id]?.kind ?? '',
          fullUnlockCount: meta[id]?.count,
          searchText: (meta[id]?.search ?? id).toLowerCase(),
          killCount: kills[id] ?? 0,
          sighted: sights.contains(id),
          chatted: chats.contains(id),
        ),
    ];
  }

  static void _set(
    Map<String, List<Object?>> sections,
    String key,
    String id,
    Object value,
  ) {
    final rows = sections[key]!;
    final index = rows.indexWhere((r) => _id(r) == id);
    if (key == 'kills') {
      final old = index < 0
          ? <String, Object?>{}
          : Map<String, Object?>.from(rows[index] as Map);
      final next = {...old, 'persistentNpcId': id, 'killCount': value};
      if (index < 0) {
        rows.add(next);
      } else {
        rows[index] = next;
      }
    } else if (value == true && index < 0) {
      rows.add({'persistentNpcId': id});
    } else if (value == false && index >= 0) {
      rows.removeAt(index);
    }
    if (rows.length > maxEntries) throw const FormatException('图鉴条目超过上限');
  }

  static Map<String, Object?> editEntry(
    Map<String, Object?> bestiary, {
    required ResourceCatalog catalog,
    required String id,
    required String kind,
    required Object? value,
  }) {
    final known = entries(
      bestiary,
      catalog,
    ).where((e) => e.id == id && e.editable).firstOrNull;
    if (known == null || known.kind != kind) {
      throw const FormatException('条目缺少已验证的图鉴规则');
    }
    if (kind == 'kills'
        ? value is! int || value < 0 || value > maxKillCount
        : value is! bool) {
      throw const FormatException('击杀数量必须为 0–999,999,999 的整数，解锁状态必须为布尔值');
    }
    final sections = _sectionsOf(bestiary);
    if (kind == 'kills') {
      _set(sections, kind, id, value!);
    } else {
      _set(sections, 'sightings', id, value!);
      _set(sections, 'chats', id, value);
      if (value == false && known.killCount > 0) _set(sections, 'kills', id, 0);
    }
    return {...bestiary, ...sections};
  }

  static Map<String, Object?> unlockKnown(
    Map<String, Object?> bestiary, {
    required ResourceCatalog catalog,
    required bool confirmed,
  }) {
    if (!confirmed) throw StateError('请先确认一键解锁');
    final known = entries(bestiary, catalog).where((e) => e.editable).toList();
    if (known.isEmpty) throw StateError('没有可编辑的已知图鉴条目');
    final sections = _sectionsOf(bestiary);
    for (final row in known) {
      if (row.kind == 'kills' && row.killCount == 0) {
        _set(sections, 'kills', row.id, row.fullUnlockCount!);
      }
      // Match the existing viewer's unlock operation, while retaining original
      // positive counts and all original sight/chat records and extra fields.
      _set(sections, 'sightings', row.id, true);
      _set(sections, 'chats', row.id, true);
    }
    return {...bestiary, ...sections};
  }
}
