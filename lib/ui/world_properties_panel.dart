import 'package:flutter/material.dart';

/// An editor over actual decoded scalar header values. It never builds a header.
class WorldPropertiesPanel extends StatefulWidget {
  const WorldPropertiesPanel({
    super.key,
    required this.world,
    required this.busy,
    required this.onEdit,
  });

  final Map<String, Object?> world;
  final bool busy;
  final Future<void> Function(String field, Object value) onEdit;

  @override
  State<WorldPropertiesPanel> createState() => _WorldPropertiesPanelState();
}

class _WorldPropertiesPanelState extends State<WorldPropertiesPanel> {
  String _search = '';
  String _group = '全部';
  String? _error;
  bool _saving = false;

  Map<String, Object?> get _header {
    final header = widget.world['header'];
    return header is Map
        ? {
            for (final e in header.entries)
              if (e.key is String) e.key as String: e.value,
          }
        : widget.world;
  }

  bool get _locked {
    final format = widget.world['format'];
    return (_version ?? 0) > 326 ||
        widget.busy ||
        _saving ||
        widget.world['readOnly'] == true ||
        _header['readOnly'] == true ||
        widget.world['futureVersion'] == true ||
        widget.world['isFutureVersion'] == true ||
        _header['futureVersion'] == true ||
        _header['isFutureVersion'] == true ||
        (format is Map &&
            (format['readOnly'] == true || format['futureVersion'] == true));
  }

  static const _labels = <String, String>{
    'name': '世界名称',
    'worldName': '世界名称',
    'seed': '世界种子',
    'gameMode': '游戏难度',
    'spawnTileX': '出生点 X',
    'spawnTileY': '出生点 Y',
    'crimson': '猩红世界',
    'hardMode': '困难模式',
    'dayTime': '白天',
    'time': '当前时间',
    'moonPhase': '月相',
    'bloodMoon': '血月',
    'eclipse': '日食',
    'raining': '正在下雨',
    'rainTime': '剩余降雨时间',
    'maxRain': '降雨强度',
    'windSpeedTarget': '目标风速',
    'invasionDelay': '入侵延迟',
    'invasionSize': '入侵规模',
    'invasionSizeStart': '入侵初始规模',
    'invasionType': '入侵类型',
    'invasionX': '入侵位置',
    'shadowOrbSmashed': '已破坏暗影珠',
    'shadowOrbCount': '暗影珠计数',
    'spawnMeteor': '生成陨石',
    'altarCount': '祭坛计数',
    'downedEyeOfCthulhu': '已击败克苏鲁之眼',
    'downedEaterOfWorldsOrBrainOfCthulhu': '已击败世界吞噬者或克苏鲁之脑',
    'downedSkeletron': '已击败骷髅王',
    'downedQueenBee': '已击败蜂王',
    'downedDestroyer': '已击败毁灭者',
    'downedTwins': '已击败双子魔眼',
    'downedSkeletronPrime': '已击败机械骷髅王',
    'downedAnyMechBoss': '已击败机械 Boss',
    'downedPlantera': '已击败世纪之花',
    'downedGolem': '已击败石巨人',
    'downedKingSlime': '已击败史莱姆王',
    'savedGoblin': '已解救哥布林工匠',
    'savedWizard': '已解救巫师',
    'savedMech': '已解救机械师',
    'downedGoblins': '已击败哥布林入侵',
    'downedClown': '已击败小丑',
    'downedFrost': '已击败雪人军团',
    'downedPirates': '已击败海盗入侵',
  };

  static const _structure = {
    'version',
    'type',
    'revision',
    'favoriteFlags',
    'tileTypeCount',
    'bitmap',
    'maxTilesX',
    'maxTilesY',
    'leftWorld',
    'rightWorld',
    'topWorld',
    'bottomWorld',
    'worldId',
    'worldID',
    'guid',
    'uniqueID',
    'uniqueId',
    'readOnly',
    'futureVersion',
    'isFutureVersion',
  };
  static const _basic = {
    'name',
    'worldName',
    'seed',
    'gameMode',
    'crimson',
    'spawnTileX',
    'spawnTileY',
  };
  static const _bools = {
    'hardMode',
    'downedEyeOfCthulhu',
    'downedEaterOfWorldsOrBrainOfCthulhu',
    'downedSkeletron',
    'downedQueenBee',
    'downedDestroyer',
    'downedTwins',
    'downedSkeletronPrime',
    'downedAnyMechBoss',
    'downedPlantera',
    'downedGolem',
    'downedKingSlime',
    'savedGoblin',
    'savedWizard',
    'savedMech',
    'downedGoblins',
    'downedClown',
    'downedFrost',
    'downedPirates',
    'dayTime',
    'bloodMoon',
    'eclipse',
    'raining',
    'crimson',
    'shadowOrbSmashed',
    'spawnMeteor',
    'pumpkinMoon',
    'snowMoon',
    'fastForwardTime',
    'fastForwardTimeToDawn',
    'fastForwardTimeToDusk',
    'invasionScheduled',
    'lunarApocalypseIsUp',
  };
  static const _numbers = {
    'gameMode',
    'spawnTileX',
    'spawnTileY',
    'time',
    'moonPhase',
    'rainTime',
    'maxRain',
    'windSpeedTarget',
    'invasionDelay',
    'invasionSize',
    'invasionType',
    'invasionX',
    'invasionSizeStart',
    'invasionProgress',
    'invasionProgressMax',
    'invasionProgressWave',
    'slimeRainTime',
    'sundialCooldown',
    'moondialCooldown',
    'shadowOrbCount',
    'altarCount',
  };
  bool _progress(String field) =>
      field.startsWith('downed') ||
      field.startsWith('saved') ||
      field == 'hardMode';
  String _category(String field) => _structure.contains(field)
      ? '只读与其他'
      : _basic.contains(field)
      ? '基本信息'
      : _progress(field)
      ? '进度'
      : _bools.contains(field) || _numbers.contains(field)
      ? '时间、天气与事件'
      : '只读与其他';

  static const _floating = {
    'time',
    'maxRain',
    'windSpeedTarget',
    'invasionX',
    'slimeRainTime',
  };

  int? get _version {
    final value = _header['version'] ?? widget.world['version'];
    return value is int ? value : null;
  }

  bool _editable(String field, Object value) {
    if (_structure.contains(field)) return false;
    if (value is bool) return _bools.contains(field) && _versionSupports(field);
    if (value is String) {
      return const {'name', 'worldName'}.contains(field) ||
          (field == 'seed' && (_version ?? 0) >= 179);
    }
    if (value is int && field == 'seed') return (_version ?? 0) >= 179;
    return (value is int || value is double) &&
        _numbers.contains(field) &&
        _versionSupports(field);
  }

  // A conservative version floor: normalized future defaults are not proof
  // that an older format can store the field. Unknown progression flags stay
  // visible but read-only, even when the decoder supplies a default value.
  bool _versionSupports(String field) {
    final version = _header['version'] ?? widget.world['version'];
    if (version is! int || version < 139) return false;
    if (const {
      'pumpkinMoon',
      'snowMoon',
      'fastForwardTime',
      'fastForwardTimeToDawn',
      'fastForwardTimeToDusk',
      'slimeRainTime',
      'sundialCooldown',
      'moondialCooldown',
      'invasionProgress',
      'invasionProgressMax',
      'invasionProgressWave',
      'invasionScheduled',
      'lunarApocalypseIsUp',
    }.contains(field)) {
      return false;
    }
    return true;
  }

  Object _parse(String field, Object original, String input) {
    if (original is String) return input;
    final value = original is int && !_floating.contains(field)
        ? int.tryParse(input.trim())
        : double.tryParse(input.trim());
    if (value == null || !value.isFinite) {
      throw const FormatException('请输入有效的有限数值；整数不能包含小数。');
    }
    if (field == 'seed') return value;
    num min = 0, max = 2147483647;
    if (field.startsWith('spawn')) {
      final x = field.endsWith('X');
      final bound = _header[x ? 'maxTilesX' : 'maxTilesY'];
      if (bound is! int || bound <= 0) {
        throw const FormatException('缺少有效世界尺寸，无法验证出生点。');
      }
      max = bound - 1;
    } else if (field == 'gameMode') {
      max = (_version ?? 0) >= 209
          ? 3
          : (_version ?? 0) >= 208
          ? 2
          : 1;
    } else if (field == 'moonPhase') {
      max = 7;
    } else if (field == 'maxRain') {
      max = 1;
    } else if (field == 'windSpeedTarget') {
      min = -1;
      max = 1;
    } else if (field == 'time') {
      max = 86400;
    } else if (field == 'invasionType') {
      max = 4;
    } else if (field == 'sundialCooldown' || field == 'moondialCooldown') {
      max = 255;
    }
    if (value < min || value > max) throw FormatException('数值范围：$min 至 $max');
    return value;
  }

  Future<void> _save(String field, Object value) async {
    if (_locked) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onEdit(field, value);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(String field, Object original) async {
    final controller = TextEditingController(text: '$original');
    String? error;
    final value = await showDialog<Object>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_labels[field] ?? field),
          content: TextField(
            key: const ValueKey('world-property-input'),
            controller: controller,
            autofocus: true,
            keyboardType: original is num
                ? const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )
                : TextInputType.text,
            decoration: InputDecoration(
              labelText: original is int && !_floating.contains(field)
                  ? '整数'
                  : original is double || _floating.contains(field)
                  ? '小数'
                  : '文本',
              errorText: error,
              errorMaxLines: 3,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(
                    context,
                    _parse(field, original, controller.text),
                  );
                } on FormatException catch (e) {
                  update(() => error = e.message);
                }
              },
              child: const Text('暂存'),
            ),
          ],
        ),
      ),
    );
    // Wait for the dialog's reverse transition before disposing its controller.
    if (value != null && mounted && !_locked) await _save(field, value);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        _header.entries.where((entry) {
          final value = entry.value;
          return (value is bool ||
                  value is String ||
                  value is int ||
                  value is double) &&
              (_group == '全部' || _category(entry.key) == _group) &&
              '${entry.key} ${_labels[entry.key] ?? ''}'.toLowerCase().contains(
                _search.toLowerCase(),
              );
        }).toList()..sort((a, b) {
          const order = ['基本信息', '进度', '时间、天气与事件', '只读与其他'];
          final group = order
              .indexOf(_category(a.key))
              .compareTo(order.indexOf(_category(b.key)));
          return group == 0 ? a.key.compareTo(b.key) : group;
        });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('进度、天气与更多属性', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('显示引擎解码出的标量字段；旧版本默认项不代表可写。候选仍需核心校验，未知字段只读。'),
        if (_locked) const Text('当前不可编辑（忙碌、只读或未来版本）。'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('world-property-search'),
          decoration: const InputDecoration(
            labelText: '搜索字段',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _search = value),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final group in const ['全部', '基本信息', '进度', '时间、天气与事件', '只读与其他'])
              ChoiceChip(
                label: Text(group),
                selected: _group == group,
                onSelected: (_) => setState(() => _group = group),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('${entries.length} 个字段'),
        SizedBox(
          height: 420,
          child: entries.isEmpty
              ? const Center(child: Text('没有匹配的实际字段'))
              : ListView.builder(
                  primary: false,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final e = entries[index];
                    final value = e.value!;
                    final editable = _editable(e.key, value);
                    final enabled = editable && !_locked;
                    final subtitle =
                        '${e.key} · ${_category(e.key)} · ${editable ? '暂存修改' : '只读'}';
                    return value is bool
                        ? SwitchListTile(
                            key: ValueKey('world-property-${e.key}'),
                            title: Text(_labels[e.key] ?? e.key),
                            subtitle: Text(subtitle),
                            value: value,
                            onChanged: enabled
                                ? (value) => _save(e.key, value)
                                : null,
                          )
                        : ListTile(
                            key: ValueKey('world-property-${e.key}'),
                            title: Text(_labels[e.key] ?? e.key),
                            subtitle: Text('$value\n$subtitle', softWrap: true),
                            trailing: Icon(
                              enabled
                                  ? Icons.edit_outlined
                                  : Icons.lock_outline,
                              size: 18,
                            ),
                            onTap: enabled ? () => _edit(e.key, value) : null,
                          );
                  },
                ),
        ),
      ],
    );
  }
}
