import 'dart:convert';

import 'prefix_rules.dart';
import 'resource_catalog.dart';

/// Optional, verified game metadata. Null values never imply permission.
class PlayerItemRules {
  const PlayerItemRules({
    this.maxStack,
    this.allowedPrefixes,
    this.persistentId,
    this.researchRequired,
    this.canAmmo = false,
  });
  factory PlayerItemRules.fromMetadata(Map<String, Object?> fields) {
    final gameplay = fields['gameplay'];
    final prefixes = fields['eligiblePrefixes'];
    return PlayerItemRules(
      maxStack: fields['maxStack'] is int ? fields['maxStack'] as int : null,
      allowedPrefixes: prefixes is List
          ? prefixes.whereType<int>().toSet()
          : null,
      persistentId: fields['persistentId'] is String
          ? fields['persistentId'] as String
          : null,
      researchRequired: fields['research'] is int
          ? fields['research'] as int
          : null,
      canAmmo:
          gameplay is Map &&
          gameplay['ammo'] is num &&
          (gameplay['ammo'] as num) > 0 &&
          gameplay['notAmmo'] != true,
    );
  }
  final int? maxStack, researchRequired;
  final Set<int>? allowedPrefixes;
  final String? persistentId;
  final bool canAmmo;
}

typedef PlayerRulesLookup = PlayerItemRules? Function(int id);

class EquipmentSlot {
  const EquipmentSlot(this.group, this.index, this.label, {this.loadout});
  final String group, label;
  final int index;
  final int? loadout;
}

class PlayerPrefixResult {
  const PlayerPrefixResult(this.player, this.changedItems, this.changedGroups);
  final Map<String, Object?> player;
  final int changedItems;
  final Set<String> changedGroups;
}

/// Schema-aware operations return new JSON values and never alter the input.
abstract final class PlayerTools {
  static const stores = [
    'inventory',
    'piggyBank',
    'safe',
    'defendersForge',
    'voidVault',
  ];
  static const equipment = ['armor', 'dyes', 'miscEquips', 'miscDyes'];
  static const fieldVersions = <String, int>{
    'hairDye': 82,
    'skinVariant': 107,
    'extraAccessory': 125,
    'creativeItemSacrifices': 218,
    'creativePowers': 218,
    'ateArtisanBread': 256,
    'unlockedBiomeTorches': 259,
    'usedAegisCrystal': 260,
    'usedAegisFruit': 260,
    'usedArcaneCrystal': 260,
    'usedGalaxyPearl': 260,
    'usedGummyWorm': 260,
    'usedAmbrosia': 260,
    'voiceVariant': 280,
    'unlockedSuperCart': 280,
    'voicePitchOffset': 281,
    'team': 283,
  };
  static int number(Object? value, [int fallback = 0]) =>
      value is num ? value.toInt() : fallback;
  static bool supports(Map<String, Object?> player, String field) =>
      player.containsKey(field) &&
      number(player['version']) >= (fieldVersions[field] ?? 1);
  static Map<String, Object?> slot(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
  static List<Map<String, Object?>> slots(Object? value) =>
      value is List ? value.map(slot).toList() : [];
  static bool empty(Map<String, Object?> s) =>
      number(s['itemType']) == 0 || number(s['stack']) == 0;
  static Map<String, Object?> emptySlot() => {
    'itemType': 0,
    'stack': 0,
    'prefix': 0,
    'favorited': false,
  };

  /// A local clipboard snapshot, never a reference into the active document.
  /// One slot is bounded so opaque metadata cannot turn an intent into a save.
  static Map<String, Object?> copySlot(Map<String, Object?> source) {
    final encoded = jsonEncode(source);
    if (utf8.encode(encoded).length > 65536) {
      throw const FormatException('物品附加资料过大，不能复制。');
    }
    final result = Map<String, Object?>.from(jsonDecode(encoded) as Map);
    final id = result['itemType'],
        count = result['stack'],
        prefix = result['prefix'];
    if (id is! int ||
        id < 0 ||
        id > 2147483647 ||
        count is! int ||
        count < 0 ||
        count > 9999 ||
        prefix is! int ||
        prefix < 0 ||
        prefix > 255 ||
        (id > 0 && count == 0) ||
        (result.containsKey('favorited') && result['favorited'] is! bool)) {
      throw const FormatException('物品 ID、数量、前缀或收藏格式无效。');
    }
    return result;
  }

  /// Validation is against the destination, so copying does not manufacture
  /// permission to add quantities or retain an unsupported source prefix.
  static Map<String, Object?> pasteSlot(
    Map<String, Object?> original,
    Map<String, Object?> clipboard, {
    required int version,
    ResourceCatalog? catalog,
    PlayerRulesLookup? lookup,
  }) {
    if (version < 38) throw const FormatException('此版本使用旧物品格式，不能编辑格子。');
    final copied = copySlot(clipboard);
    final id = copied['itemType'] as int;
    final fields = catalog?.byId('items', id)?.fields;
    var itemRules = fields == null
        ? lookup?.call(id)
        : PlayerItemRules.fromMetadata(fields);
    final maxStack = itemRules?.maxStack;
    itemRules = PlayerItemRules(
      maxStack: maxStack != null && maxStack >= 1 && maxStack <= 9999
          ? maxStack
          : null,
      allowedPrefixes: catalog != null
          ? PrefixRules(catalog).eligiblePrefixes(id, version: version).toSet()
          : itemRules?.allowedPrefixes,
    );
    final prefix = copied['prefix'] as int;
    final unchangedPrefix =
        number(original['itemType']) == id &&
        number(original['prefix']) == prefix;
    if (version < 315 && prefix >= 85 && !unchangedPrefix) {
      throw const FormatException('此版本不支持所选前缀。');
    }
    final validated = editSlot(
      original,
      itemId: id,
      quantity: copied['stack'] as int,
      prefix: prefix,
      rules: itemRules,
      favorited: original.containsKey('favorited')
          ? copied['favorited'] as bool? ?? original['favorited'] as bool?
          : null,
    );
    final result = {...original, ...copied, ...validated};
    // Do not invent a favorite field in schemas that do not expose one.
    if (!original.containsKey('favorited')) result.remove('favorited');
    return copySlot(result);
  }

  static Map<String, Object?> _slotSource(
    Map<String, Object?> player,
    String group,
    int? loadout,
  ) {
    if (player['version'] is! int ||
        number(player['version']) < 38 ||
        ![...stores, ...equipment].contains(group)) {
      throw const FormatException('此版本或物品栏不支持格子编辑。');
    }
    var source = player;
    if (loadout != null) {
      final layouts = player['loadouts'];
      if (!const ['armor', 'dyes'].contains(group) ||
          layouts is! List ||
          loadout < 0 ||
          loadout >= layouts.length ||
          layouts[loadout] is! Map) {
        throw const FormatException('装备套装或物品栏越界。');
      }
      source = slot(layouts[loadout]);
    }
    if (source[group] is! List || (source[group] as List).length > 1999) {
      throw const FormatException('物品栏格式无效。');
    }
    return source;
  }

  static Map<String, Object?> _replaceGroups(
    Map<String, Object?> player,
    Map<String, Object?> updates,
    int? loadout,
  ) {
    if (loadout == null) return {...player, ...updates};
    final layouts = List<Object?>.from(player['loadouts'] as List);
    layouts[loadout] = {...slot(layouts[loadout]), ...updates};
    return {...player, 'loadouts': layouts};
  }

  static Map<String, Object?> replaceSlot(
    Map<String, Object?> player,
    String group,
    int index,
    Map<String, Object?> draft, {
    int? loadout,
    ResourceCatalog? catalog,
    PlayerRulesLookup? lookup,
  }) {
    final source = _slotSource(player, group, loadout);
    final values = List<Object?>.from(source[group] as List);
    if (index < 0 || index >= values.length || values[index] is! Map) {
      throw const FormatException('物品槽位越界或格式无效。');
    }
    values[index] = pasteSlot(
      slot(values[index]),
      draft,
      version: number(player['version']),
      catalog: catalog,
      lookup: lookup,
    );
    return _replaceGroups(player, {group: values}, loadout);
  }

  /// Only prefix fields change. Unsupported and tied-best items stay untouched.
  static PlayerPrefixResult bestPrefixes(
    Map<String, Object?> player, {
    required Iterable<String> groups,
    required PrefixRules rules,
    int? loadout,
  }) {
    final selected = groups.toSet();
    if (selected.isEmpty ||
        selected.length > stores.length + equipment.length) {
      throw const FormatException('请选择有效的物品栏。');
    }
    final updates = <String, Object?>{};
    var changedItems = 0;
    final version = number(player['version']);
    final candidates = <(int, int), PrefixCandidate?>{};
    for (final group in selected) {
      final source = _slotSource(player, group, loadout);
      final values = List<Object?>.from(source[group] as List);
      var changed = false;
      for (var i = 0; i < values.length; i++) {
        final value = values[i];
        if (value is! Map ||
            value['itemType'] is! int ||
            value['stack'] is! int ||
            value['prefix'] is! int ||
            (value['itemType'] as int) <= 0 ||
            (value['stack'] as int) <= 0 ||
            (value['stack'] as int) > 9999 ||
            (value['prefix'] as int) < 0 ||
            (value['prefix'] as int) > 255) {
          continue;
        }
        final key = (value['itemType'] as int, value['prefix'] as int);
        if (!candidates.containsKey(key)) {
          candidates[key] = rules.bestPrefix(
            key.$1,
            version: version,
            current: key.$2,
          );
        }
        final best = candidates[key];
        if (best == null || best.id == key.$2) continue;
        values[i] = {...slot(value), 'prefix': best.id};
        changedItems++;
        changed = true;
      }
      if (changed) updates[group] = values;
    }
    return PlayerPrefixResult(
      _replaceGroups(player, updates, loadout),
      changedItems,
      Set.unmodifiable(
        updates.isEmpty
            ? <String>[]
            : loadout == null
            ? updates.keys
            : ['loadouts'],
      ),
    );
  }

  static Map<String, Object?> editSlot(
    Map<String, Object?> original, {
    required int itemId,
    required int quantity,
    required int prefix,
    PlayerItemRules? rules,
    bool? favorited,
  }) {
    if (itemId < 0 || itemId > 2147483647 || prefix < 0 || prefix > 255) {
      throw const FormatException('物品 ID 或前缀超出存档范围。');
    }
    if (itemId == 0) return {...original, ...emptySlot()};
    if (quantity < 1 ||
        quantity > 9999 ||
        (rules?.maxStack != null && quantity > rules!.maxStack!)) {
      throw const FormatException('物品数量超过此物品的已知上限。');
    }
    final unchanged =
        number(original['itemType']) == itemId &&
        number(original['prefix']) == prefix;
    if (prefix != 0 &&
        !unchanged &&
        !(rules?.allowedPrefixes?.contains(prefix) ?? false)) {
      throw const FormatException('缺少此物品与前缀兼容的可靠资料。');
    }
    if (rules?.maxStack == null &&
        (itemId != number(original['itemType']) ||
            quantity > number(original['stack']))) {
      throw const FormatException('缺少此物品的堆叠上限资料，不能增加数量。');
    }
    return {
      ...original,
      'itemType': itemId,
      'stack': quantity,
      'prefix': prefix,
      'favorited': ?favorited,
    };
  }

  static String _signature(Map<String, Object?> s) {
    final keys = s.keys.where((k) => k != 'stack').toList()..sort();
    return jsonEncode({for (final k in keys) k: s[k]});
  }

  static Map<String, int> _tally(List<Map<String, Object?>> values) {
    final result = <String, int>{};
    for (final s in values) {
      if (!empty(s)) {
        result.update(
          _signature(s),
          (n) => n + number(s['stack']),
          ifAbsent: () => number(s['stack']),
        );
      }
    }
    return result;
  }

  static bool _plain(Map<String, Object?> s) => s.keys.every(
    (k) => const {'itemType', 'stack', 'prefix', 'favorited'}.contains(k),
  );

  /// Deterministic ID order; preserves hotbar, coin/ammo lanes, favorites and
  /// unknown metadata. This is deliberately not presented as the game's order.
  static List<Map<String, Object?>> organize(
    Map<String, Object?> player,
    String group,
    PlayerRulesLookup lookup,
  ) {
    if (!stores.contains(group) ||
        player[group] is! List ||
        number(player['version']) < 38) {
      throw const FormatException('此版本或栏位不支持整理。');
    }
    final values = slots(player[group]);
    final before = _tally(values);
    final eligible = <int>[];
    for (var i = 0; i < values.length; i++) {
      final s = values[i];
      if (group == 'inventory' && (i < 10 || i >= 50)) continue;
      if (s['favorited'] == true || !_plain(s)) continue;
      if (!empty(s) && lookup(number(s['itemType']))?.maxStack == null) {
        continue;
      }
      eligible.add(i);
    }
    for (var a = 0; a < eligible.length; a++) {
      final target = values[eligible[a]];
      if (empty(target)) continue;
      final max = lookup(number(target['itemType']))!.maxStack!;
      for (
        var b = a + 1;
        b < eligible.length && number(target['stack']) < max;
        b++
      ) {
        final source = values[eligible[b]];
        if (empty(source) || _signature(source) != _signature(target)) continue;
        final space = max - number(target['stack']);
        final count = number(source['stack']) < space
            ? number(source['stack'])
            : space;
        target['stack'] = number(target['stack']) + count;
        source['stack'] = number(source['stack']) - count;
        if (empty(source)) values[eligible[b]] = emptySlot();
      }
    }
    final sorted =
        eligible.map((i) => values[i]).where((s) => !empty(s)).toList()
          ..sort((a, b) {
            final id = number(a['itemType']).compareTo(number(b['itemType']));
            if (id != 0) return id;
            final prefix = number(a['prefix']).compareTo(number(b['prefix']));
            return prefix != 0
                ? prefix
                : number(b['stack']).compareTo(number(a['stack']));
          });
    for (var i = 0; i < eligible.length; i++) {
      values[eligible[i]] = i < sorted.length ? sorted[i] : emptySlot();
    }
    final after = _tally(values);
    if (before.length != after.length ||
        before.entries.any((e) => after[e.key] != e.value)) {
      throw const FormatException('物品守恒校验失败，已取消整理。');
    }
    return values;
  }

  /// Refills occupied ammunition slots only. Never moves favorites, hotbar,
  /// coins, unknown items or extended slots, and never guesses ammo eligibility.
  static List<Map<String, Object?>> refillAmmo(
    Map<String, Object?> player,
    PlayerRulesLookup lookup,
  ) {
    if (number(player['version']) < 38 || player['inventory'] is! List) {
      throw const FormatException('此版本不支持弹药补充。');
    }
    final values = slots(player['inventory']);
    final before = _tally(values);
    for (var i = 54; i < 58 && i < values.length; i++) {
      final target = values[i];
      final metadata = lookup(number(target['itemType']));
      if (empty(target) ||
          target['favorited'] == true ||
          !_plain(target) ||
          metadata?.canAmmo != true ||
          metadata?.maxStack == null) {
        continue;
      }
      final max = metadata!.maxStack!;
      for (
        var j = 10;
        j < 50 && j < values.length && number(target['stack']) < max;
        j++
      ) {
        final source = values[j];
        if (empty(source) ||
            source['favorited'] == true ||
            !_plain(source) ||
            _signature(source) != _signature(target)) {
          continue;
        }
        final capacity = max - number(target['stack']);
        final amount = number(source['stack']) < capacity
            ? number(source['stack'])
            : capacity;
        target['stack'] = number(target['stack']) + amount;
        source['stack'] = number(source['stack']) - amount;
        if (empty(source)) values[j] = emptySlot();
      }
    }
    final after = _tally(values);
    if (before.length != after.length ||
        before.entries.any((e) => after[e.key] != e.value)) {
      throw const FormatException('弹药数量校验失败，已取消。');
    }
    return values;
  }

  static List<EquipmentSlot> equipmentLayout(
    Map<String, Object?> player, {
    int? loadout,
  }) {
    var source = player;
    if (loadout != null) {
      final values = player['loadouts'];
      if (values is! List || loadout < 0 || loadout >= values.length) return [];
      source = slot(values[loadout]);
    }
    final result = <EquipmentSlot>[];
    for (final group in equipment) {
      if (loadout != null && group.startsWith('misc')) continue;
      final values = source[group];
      if (values is! List) continue;
      for (var i = 0; i < values.length; i++) {
        String label;
        if (group.startsWith('misc')) {
          label = i < 5
              ? const ['宠物', '照明宠物', '矿车', '坐骑', '钩爪'][i]
              : '工具 ${i + 1}';
          if (group == 'miscDyes') label += '染料';
        } else {
          final n = group == 'armor' && i >= 10 ? i - 10 : i;
          label = n < 3 ? const ['头部', '上身', '腿部'][n] : '饰品 ${n - 2}';
          if (group == 'armor' && i >= 10) label = '时装 $label';
          if (group == 'dyes') label = '$label 染料';
        }
        result.add(EquipmentSlot(group, i, label, loadout: loadout));
      }
    }
    return result;
  }

  static int buffCapacity(Map<String, Object?> player) {
    final version = number(player['version']);
    final capacity = version < 11
        ? 0
        : version < 74
        ? 10
        : version < 252
        ? 22
        : 44;
    final count = player['buffs'] is List
        ? (player['buffs'] as List).length
        : 0;
    return count < capacity ? count : capacity;
  }

  static List<Map<String, Object?>> editBuff(
    Map<String, Object?> player,
    int index,
    int id,
    double seconds, {
    Set<int> knownIds = const {},
  }) {
    if (index < 0 || index >= buffCapacity(player)) {
      throw const FormatException('状态槽位超出此版本范围。');
    }
    final result = slots(player['buffs']);
    if (id < 0 ||
        id > 2147483647 ||
        (id != 0 &&
            id != number(result[index]['buffType']) &&
            !knownIds.contains(id))) {
      throw const FormatException('没有此状态的可靠资料。');
    }
    if (!seconds.isFinite || seconds < 0 || seconds > 2147483647 / 60) {
      throw const FormatException('状态时长超出范围。');
    }
    final ticks = (seconds * 60).round();
    if (id > 0 && ticks < 1) throw const FormatException('非空状态至少需要一帧。');
    result[index] = {
      ...result[index],
      'buffType': id,
      'buffTime': id == 0 ? 0 : ticks,
    };
    return result;
  }

  static List<Map<String, Object?>> research(
    Map<String, Object?> player,
    PlayerItemRules rules,
    int amount,
  ) {
    if (!supports(player, 'creativeItemSacrifices') ||
        player['creativeItemSacrifices'] is! List) {
      throw const FormatException('此版本不支持研究。');
    }
    if (rules.persistentId == null ||
        rules.persistentId!.isEmpty ||
        rules.researchRequired == null ||
        rules.researchRequired! < 1) {
      throw const FormatException('缺少此物品的可靠研究资料。');
    }
    if (amount < 0 || amount > rules.researchRequired!) {
      throw const FormatException('研究数量超出已知上限。');
    }
    return [
      ...slots(player['creativeItemSacrifices'])
          .where((r) => r['persistentId'] != rules.persistentId),
      if (amount > 0) {'persistentId': rules.persistentId, 'amount': amount},
    ];
  }

  static Map<String, Object?> power(
    Map<String, Object?> player,
    String field,
    Object value,
  ) {
    if (!supports(player, 'creativePowers') ||
        player['creativePowers'] is! Map) {
      throw const FormatException('此版本不支持旅行能力。');
    }
    final powers = slot(player['creativePowers']);
    if (!powers.containsKey(field)) throw const FormatException('此存档没有此旅行能力。');
    if (field == 'spawnRateSlider') {
      if (value is! num || !value.isFinite || value < 0 || value > 1) {
        throw const FormatException('刷怪设置须在 0–1 之间。');
      }
    } else if (!const {
          'godmodeEnabled',
          'farPlacementEnabled',
        }.contains(field) ||
        value is! bool) {
      throw const FormatException('旅行能力类型无效。');
    }
    return {...powers, field: value};
  }
}
