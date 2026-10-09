import 'dart:convert';

import 'player_tools.dart';
import 'prefix_rules.dart';
import 'resource_catalog.dart';

class ChestPrefixResult {
  const ChestPrefixResult(this.chests, this.changedItems, this.changedChests);
  final List<Map<String, Object?>> chests;
  final int changedItems, changedChests;
}

/// Pure chest transformations. Slot count and all unrecognized fields survive.
abstract final class ChestTools {
  static const maxNameLength = 20;
  static List<Object?> _items(Map<String, Object?> chest) {
    final items = chest['items'];
    if (items is! List || items.length > 1999) {
      throw const FormatException('宝箱卡槽格式无效。');
    }
    return List<Object?>.from(items);
  }

  static int _capacity(Map<String, Object?> chest, int length) {
    final declared = chest['maxItems'];
    if (declared == null) return length;
    if (declared is! int || declared < 0 || declared > 1999) {
      throw const FormatException('宝箱容量无效。');
    }
    return declared < length ? declared : length;
  }

  static Map<String, Object?> rename(Map<String, Object?> chest, String name) {
    if (name.length > maxNameLength ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('宝箱名称最多 20 个字符，不能包含控制字符。');
    }
    return {...chest, 'name': name};
  }

  static Map<String, Object?> editSlot(
    Map<String, Object?> chest,
    int index, {
    required int itemId,
    required int quantity,
    required int prefix,
    ResourceCatalog? catalog,
  }) {
    final items = _items(chest);
    if (index < 0 || index >= _capacity(chest, items.length)) {
      throw const FormatException('卡槽越界。');
    }
    if (itemId < 0 ||
        itemId > 2147483647 ||
        prefix < 0 ||
        prefix > 255 ||
        quantity < 0 ||
        quantity > 9999) {
      throw const FormatException('物品、数量或前缀超出范围。');
    }
    if (itemId == 0) {
      items[index] = null;
    } else {
      if (items[index] != null && items[index] is! Map) {
        throw const FormatException('卡槽格式无效。');
      }
      final fields = catalog?.byId('items', itemId)?.fields;
      items[index] = PlayerTools.editSlot(
        PlayerTools.slot(items[index]),
        itemId: itemId,
        quantity: quantity,
        prefix: prefix,
        rules: fields == null ? null : PlayerItemRules.fromMetadata(fields),
      );
    }
    return {...chest, 'items': items};
  }

  static Map<String, Object?> clear(Map<String, Object?> chest) => {
    ...chest,
    'items': List<Object?>.filled(_items(chest).length, null),
  };

  static bool _movable(Object? item) {
    if (item == null) return true;
    if (item is! Map ||
        item['favorited'] == true ||
        item.keys.any(
          (key) =>
              !const {'itemType', 'stack', 'prefix', 'favorited'}.contains(key),
        )) {
      return false;
    }
    return item['itemType'] is int &&
        (item['itemType'] as int) > 0 &&
        item['stack'] is int &&
        (item['stack'] as int) > 0 &&
        item['prefix'] is int &&
        (item['prefix'] as int) >= 0 &&
        (item['prefix'] as int) <= 255 &&
        (!item.containsKey('favorited') || item['favorited'] is bool);
  }

  static String _signature(Map item) {
    final keys = item.keys.cast<String>().where((k) => k != 'stack').toList()
      ..sort();
    return jsonEncode({for (final key in keys) key: item[key]});
  }

  static Map<String, int> _totals(Iterable<Map<String, Object?>> items) {
    final totals = <String, int>{};
    for (final item in items) {
      totals.update(
        _signature(item),
        (n) => n + (item['stack'] as int),
        ifAbsent: () => item['stack'] as int,
      );
    }
    return totals;
  }

  /// Original deterministic ID/prefix order, not the game's inventory order.
  /// Without verified maxStack metadata this only sorts, never merges.
  static Map<String, Object?> organize(
    Map<String, Object?> chest, {
    ResourceCatalog? catalog,
  }) {
    final items = _items(chest);
    final indices = <int>[];
    final moving = <Map<String, Object?>>[];
    for (var i = 0; i < _capacity(chest, items.length); i++) {
      if (!_movable(items[i])) continue;
      indices.add(i);
      if (items[i] != null) {
        moving.add(Map<String, Object?>.from(items[i] as Map));
      }
    }
    final before = _totals(moving);
    for (var i = 0; i < moving.length; i++) {
      final target = moving[i];
      final max = catalog
          ?.byId('items', target['itemType']!)
          ?.fields['maxStack'];
      if (max is! int ||
          max < 1 ||
          max > 9999 ||
          (target['stack'] as int) > max) {
        continue;
      }
      for (
        var j = i + 1;
        j < moving.length && (target['stack'] as int) < max;
        j++
      ) {
        final source = moving[j];
        if (_signature(source) != _signature(target) ||
            (source['stack'] as int) > max) {
          continue;
        }
        final available = max - (target['stack'] as int);
        final amount = (source['stack'] as int) < available
            ? source['stack'] as int
            : available;
        target['stack'] = (target['stack'] as int) + amount;
        source['stack'] = (source['stack'] as int) - amount;
      }
    }
    moving.removeWhere((item) => item['stack'] == 0);
    final after = _totals(moving);
    if (before.length != after.length ||
        before.entries.any((e) => after[e.key] != e.value)) {
      throw const FormatException('物品守恒校验失败。');
    }
    moving.sort((a, b) {
      var comparison = (a['itemType'] as int).compareTo(b['itemType'] as int);
      if (comparison == 0) {
        comparison = (a['prefix'] as int).compareTo(b['prefix'] as int);
      }
      if (comparison == 0) {
        comparison = (b['stack'] as int).compareTo(a['stack'] as int);
      }
      if (comparison == 0) comparison = _signature(a).compareTo(_signature(b));
      return comparison;
    });
    for (var i = 0; i < indices.length; i++) {
      items[indices[i]] = i < moving.length ? moving[i] : null;
    }
    return {...chest, 'items': items};
  }

  static ChestPrefixResult bestPrefixes(
    List<Map<String, Object?>> chests, {
    required PrefixRules rules,
    required int version,
  }) {
    if (version <= 0) throw const FormatException('无法确定世界版本。');
    var changedItems = 0, changedChests = 0;
    final recommendations = <(int, int), PrefixCandidate?>{};
    final result = <Map<String, Object?>>[];
    for (final chest in chests) {
      final items = _items(chest);
      var changed = false;
      for (var i = 0; i < _capacity(chest, items.length); i++) {
        final item = items[i];
        if (item is! Map ||
            item['itemType'] is! int ||
            item['stack'] is! int ||
            (item['stack'] as int) <= 0 ||
            item['prefix'] is! int) {
          continue;
        }
        final key = (item['itemType'] as int, item['prefix'] as int);
        if (!recommendations.containsKey(key)) {
          recommendations[key] = rules.bestPrefix(
            key.$1,
            version: version,
            current: key.$2,
          );
        }
        final best = recommendations[key];
        if (best == null || best.id == item['prefix']) continue;
        items[i] = {...Map<String, Object?>.from(item), 'prefix': best.id};
        changed = true;
        changedItems++;
      }
      if (changed) changedChests++;
      result.add({...chest, 'items': items});
    }
    return ChestPrefixResult(result, changedItems, changedChests);
  }
}
