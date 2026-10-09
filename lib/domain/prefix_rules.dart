import 'dart:typed_data';

import 'resource_catalog.dart';

class PrefixCandidate {
  PrefixCandidate(this.id, Iterable<int> ties, this.score)
    : ties = List<int>.unmodifiable(ties);
  final int id;
  final List<int> ties;
  final double score;
}

/// Scores only explicit, imported compatibility metadata. Does not infer pools
/// from weapon names or embed game catalog tables.
class PrefixRules {
  PrefixRules(this.catalog);
  final ResourceCatalog catalog;
  // Catalog rows are immutable; nullable outcomes are cached for this instance.
  final Map<(int, int), double?> _scores = {};

  static double float32(num n) => (Float32List(1)..[0] = n.toDouble())[0];
  static double _multiply(num a, num b) => float32(float32(a) * float32(b));

  /// Native midpoint-to-even rounding, including negative half values.
  static int roundEven(double n) {
    if (!n.isFinite) throw const FormatException('非有限数值');
    final lower = n.floor();
    final fraction = n - lower;
    return fraction == .5 ? (lower.isEven ? lower : lower + 1) : n.round();
  }

  List<int> eligiblePrefixes(int itemId, {required int version}) {
    if (version <= 0 || itemId <= 0) return const [];
    final item = catalog.byId('items', itemId)?.fields;
    if (item == null) return const [];
    Object? ids = item['eligiblePrefixes'];
    // Pre-1.4.5 summons used the magic pool; 85+ prefixes were introduced later.
    if (version < 315 && item['prefixPool'] == 'PrefixesForSummons') {
      ids = [
        for (final row in catalog.families['prefixes'] ?? <CatalogEntry>[])
          if (row.fields['pools'] is List &&
              (row.fields['pools'] as List).contains('PrefixesForMagic'))
            row.numericId,
      ];
    }
    if (ids is! List || ids.any((id) => id is! int || id <= 0 || id > 255)) {
      return const [];
    }
    return ids
        .cast<int>()
        .toSet()
        .where((id) {
          if (version < 315 && id >= 85) return false;
          final score = prefixScore(itemId, id);
          return score != null && score > 0;
        })
        .toList(growable: false);
  }

  double? prefixScore(int itemId, int prefixId) {
    final key = (itemId, prefixId);
    if (_scores.containsKey(key)) return _scores[key];
    final result = _computeScore(itemId, prefixId);
    _scores[key] = result;
    return result;
  }

  double? _computeScore(int itemId, int prefixId) {
    final row = catalog.byId('prefixes', prefixId)?.fields;
    final stats = row?['stats'];
    final gameplay = catalog.byId('items', itemId)?.fields['gameplay'];
    if (row == null || stats is! Map || gameplay is! Map) return null;
    const multipliers = ['dmg', 'spd', 'mcst', 'size', 'kb', 'shtspd'];
    const bonuses = ['crt', 'arpen', 'tagdmg'];
    final values = <String, double>{};
    for (final key in [...multipliers, ...bonuses]) {
      final value = stats.containsKey(key)
          ? stats[key]
          : (multipliers.contains(key) ? 1 : 0);
      if (value is! num ||
          !value.isFinite ||
          !float32(value).isFinite ||
          (multipliers.contains(key) && value <= 0)) {
        return null;
      }
      values[key] = float32(value);
    }
    for (final pair in {
      'dmg': 'damage',
      'spd': 'useAnimation',
      'mcst': 'mana',
    }.entries) {
      final multiplier = values[pair.key]!;
      if (!stats.containsKey(pair.key) || stats[pair.key] == 1) continue;
      final base = gameplay[pair.value];
      if (base is! num ||
          !base.isFinite ||
          base < 0 ||
          base != base.roundToDouble()) {
        return null;
      }
      final product = _multiply(base, multiplier);
      if (!product.isFinite || roundEven(product) == base) return null;
    }
    if (stats.containsKey('kb') && stats['kb'] != 1) {
      final base = gameplay['knockBack'];
      if (base is! num || !base.isFinite || base <= 0) return null;
    }
    final factors = <double>[
      values['dmg']!,
      float32(2 - values['spd']!),
      float32(2 - values['mcst']!),
      values['size']!,
      values['kb']!,
      values['shtspd']!,
      float32(1 + _multiply(values['crt']!, .02)),
      float32(1 + _multiply(values['arpen']!, .015)),
      float32(1 + _multiply(values['tagdmg']!, .03)),
    ];
    final pools = row['pools'];
    if (pools is! List || pools.any((p) => p is! String)) return null;
    if (pools.contains('PrefixesForAccessories')) {
      final value = row['valueMultiplier'];
      if (value is! num || !value.isFinite || value <= 0) return null;
      factors.add(float32(value));
    }
    var score = 1.0;
    for (final factor in factors) {
      if (!factor.isFinite || factor <= 0) return null;
      score = _multiply(score, factor);
    }
    return score.isFinite && score > 0 ? score : null;
  }

  PrefixCandidate? bestPrefix(
    int itemId, {
    required int version,
    required int current,
  }) {
    var best = 0.0;
    final ties = <int>[];
    for (final id in eligiblePrefixes(itemId, version: version)) {
      final score = prefixScore(itemId, id)!;
      if (score > best) {
        best = score;
        ties.clear();
      }
      if (score == best) ties.add(id);
    }
    if (ties.isEmpty) return null;
    return PrefixCandidate(
      ties.contains(current) ? current : ties.first,
      ties,
      best,
    );
  }
}
