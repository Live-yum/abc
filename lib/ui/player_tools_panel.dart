import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/player_tools.dart';
import '../domain/prefix_rules.dart';
import '../domain/resource_catalog.dart';
import 'terra_theme.dart';

/// Specialized editors for the actual decoded player schema, not a template.
class PlayerToolsPanel extends StatefulWidget {
  const PlayerToolsPanel({
    super.key,
    required this.player,
    required this.dispatch,
    this.itemRules,
    this.catalog,
    this.knownBuffIds = const {},
  });
  final Map<String, Object?> player;
  final Future<void> Function(String, Map<String, Object?>) dispatch;
  final PlayerRulesLookup? itemRules;
  final ResourceCatalog? catalog;
  final Set<int> knownBuffIds;
  @override
  State<PlayerToolsPanel> createState() => _PlayerToolsPanelState();
}

class _PlayerToolsPanelState extends State<PlayerToolsPanel> {
  String _section = '角色', _store = 'inventory';
  bool _busy = false;
  bool _dialogOpen = false;
  Map<String, Object?>? _clipboard;
  String? _error;
  Map<String, Object?> get p => widget.player;
  PlayerItemRules? rules(int id) => widget.itemRules?.call(id);
  bool get _canEditSlots => PlayerTools.number(p['version']) >= 38;
  PrefixRules? _prefixRules;
  PrefixRules? get prefixRules {
    final catalog = widget.catalog;
    if (catalog == null || !_canEditSlots) return null;
    if (!identical(_prefixRules?.catalog, catalog)) {
      _prefixRules = PrefixRules(catalog);
    }
    return _prefixRules;
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _patch(String field, Object? value) =>
      widget.dispatch('stagePlayer', {'field': field, 'value': value});
  @override
  Widget build(BuildContext context) {
    if (p.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text('导入角色后，可编辑装备、库存、状态和旅行研究。'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in const ['角色', '库存', '装备', '状态', '旅行与研究', '高级'])
              ChoiceChip(
                label: Text(s),
                selected: _section == s,
                onSelected: _busy ? null : (_) => setState(() => _section = s),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '存档 v${p['version'] ?? '未知'} · 所有更改先暂存，导出时验证',
          style: const TextStyle(color: TerraColors.muted),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              _error!,
              style: const TextStyle(color: TerraColors.red),
            ),
          ),
        const SizedBox(height: 14),
        switch (_section) {
          '库存' => _inventory(),
          '装备' => _equipment(),
          '状态' => _buffs(),
          '旅行与研究' => _journey(),
          '高级' => _advanced(),
          _ => _character(),
        },
      ],
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  Widget _character() => Column(
    children: [
      _card('角色属性', [
        if (p['name'] is String) _textField('name', '名称'),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final e in const {
              'statLife': '当前生命',
              'statLifeMax': '最大生命',
              'statMana': '当前魔力',
              'statManaMax': '最大魔力',
              'anglerQuestsFinished': '渔夫任务',
              'numberOfDeathsPve': 'PvE 死亡',
              'numberOfDeathsPvp': 'PvP 死亡',
            }.entries)
              if (PlayerTools.supports(p, e.key) && p[e.key] is num)
                SizedBox(
                  width: 150,
                  child: _textField(e.key, e.value, numeric: true),
                ),
          ],
        ),
        if (p['difficulty'] is num)
          DropdownButtonFormField<int>(
            key: ValueKey('difficulty-${p['difficulty']}'),
            initialValue: PlayerTools.number(p['difficulty']),
            decoration: const InputDecoration(labelText: '角色模式'),
            items: [
              for (
                var i = 0;
                i < (PlayerTools.number(p['version']) >= 218 ? 4 : 3);
                i++
              )
                DropdownMenuItem(
                  value: i,
                  child: Text(const ['经典', '中核', '硬核', '旅行'][i]),
                ),
            ],
            onChanged: _busy
                ? null
                : (v) {
                    if (v != null) _run(() => _patch('difficulty', v));
                  },
          ),
      ]),
      _card('永久增益与解锁', [
        for (final e in const {
          'extraAccessory': '恶魔之心饰品位',
          'ateArtisanBread': '工匠面包',
          'usedAegisCrystal': '活力水晶',
          'usedAegisFruit': '神盾果',
          'usedArcaneCrystal': '奥术水晶',
          'usedGalaxyPearl': '星系珍珠',
          'usedGummyWorm': '黏性蠕虫',
          'usedAmbrosia': '仙馔密酒',
          'unlockedBiomeTorches': '生物群落火把',
          'unlockedSuperCart': '超级矿车',
          'hbLocked': '锁定快捷栏',
        }.entries)
          if (PlayerTools.supports(p, e.key) && p[e.key] is bool)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.value),
              value: p[e.key] == true,
              onChanged: _busy ? null : (v) => _run(() => _patch(e.key, v)),
            ),
      ]),
      _card('外观颜色', [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in const {
              'hairColor': '头发',
              'skinColor': '皮肤',
              'eyeColor': '眼睛',
              'shirtColor': '上衣',
              'underShirtColor': '内衬',
              'pantsColor': '裤装',
              'shoeColor': '鞋子',
            }.entries)
              if (p[e.key] is Map)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _editColor(e.key, e.value),
                  icon: Icon(Icons.circle, color: _color(p[e.key])),
                  label: Text(e.value),
                ),
          ],
        ),
      ]),
    ],
  );
  Widget _textField(String field, String label, {bool numeric = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('$field-${p[field]}'),
          initialValue: '${p[field]}',
          enabled: !_busy,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: label, helperText: '按回车暂存'),
          onFieldSubmitted: (text) => _run(() async {
            if (!numeric) {
              if (text.trim().isEmpty || text.length > 100) {
                throw const FormatException('名称需要 1–100 个字符。');
              }
              await _patch(field, text);
              return;
            }
            final n = int.tryParse(text);
            if (n == null || n < 0 || n > 2147483647) {
              throw const FormatException('请输入有效非负整数。');
            }
            await _patch(field, n);
          }),
        ),
      );
  Color _color(Object? value) {
    final c = PlayerTools.slot(value);
    return Color.fromARGB(
      255,
      PlayerTools.number(c['r']).clamp(0, 255),
      PlayerTools.number(c['g']).clamp(0, 255),
      PlayerTools.number(c['b']).clamp(0, 255),
    );
  }

  Future<void> _editColor(String field, String label) async {
    final rgb = _color(p[field]).toARGB32() & 0xffffff;
    final controller = TextEditingController(
      text: rgb.toRadixString(16).padLeft(6, '0'),
    );
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('$label颜色'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '六位 RGB 色值'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('暂存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      await _run(() async {
        if (!RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(value)) {
          throw const FormatException('请输入六位十六进制色值。');
        }
        final n = int.parse(value.replaceAll('#', ''), radix: 16);
        await _patch(field, {
          ...PlayerTools.slot(p[field]),
          'r': n >> 16,
          'g': (n >> 8) & 255,
          'b': n & 255,
        });
      });
    }
  }

  Widget _inventory() {
    final stores = PlayerTools.stores.where((s) => p[s] is List).toList();
    if (stores.isEmpty) return const Text('此存档没有可编辑的库存。');
    final group = stores.contains(_store) ? _store : stores.first;
    final values = PlayerTools.slots(p[group]);
    return _card('库存与储物', [
      Wrap(
        spacing: 8,
        children: [
          for (final s in stores)
            ChoiceChip(
              label: Text(_groupName(s)),
              selected: s == group,
              onSelected: (_) => setState(() => _store = s),
            ),
        ],
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy || widget.itemRules == null
            ? null
            : () => _run(
                () => _patch(group, PlayerTools.organize(p, group, rules)),
              ),
        icon: const Icon(Icons.sort),
        label: const Text('合并堆叠 · 按 ID 整理'),
      ),
      Wrap(
        spacing: 8,
        children: [
          _prefixButton('当前储物栏最佳前缀', [group]),
          _prefixButton('全部储物栏最佳前缀', stores),
        ],
      ),
      if (group == 'inventory')
        OutlinedButton.icon(
          onPressed: _busy || widget.itemRules == null
              ? null
              : () => _run(
                  () => _patch('inventory', PlayerTools.refillAmmo(p, rules)),
                ),
          icon: const Icon(Icons.move_down),
          label: const Text('从背包补充现有弹药栏'),
        ),
      const Text(
        '保留快捷栏、收藏、钱币/弹药栏以及未知物品。无可靠上限资料时不自动合并。',
        style: TextStyle(color: TerraColors.muted),
      ),
      if (!_canEditSlots) const Text('此版本使用旧物品格式，暂不支持格子编辑。'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < values.length; i++)
            _slotTile(
              group,
              i,
              values[i],
              group == 'inventory'
                  ? i < 10
                        ? '快捷 ${i + 1}'
                        : i >= 54 && i < 58
                        ? '弹药 ${i - 53}'
                        : i >= 50 && i < 54
                        ? '钱币 ${i - 49}'
                        : '${i + 1}'
                  : '${i + 1}',
            ),
        ],
      ),
    ]);
  }

  String _groupName(String s) =>
      const {
        'inventory': '背包',
        'piggyBank': '储蓄罐',
        'safe': '保险箱',
        'defendersForge': '护卫熔炉',
        'voidVault': '虚空袋',
        'armor': '装备与时装',
        'dyes': '染料',
        'miscEquips': '宠物与工具',
        'miscDyes': '工具染料',
      }[s] ??
      s;
  Widget _slotTile(
    String group,
    int index,
    Map<String, Object?> item,
    String label, {
    int? loadout,
  }) => SizedBox(
    width: 104,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(8)),
      onPressed: _busy || _dialogOpen || !_canEditSlots
          ? null
          : () => _editItem(group, index, item, label, loadout: loadout),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: TerraColors.muted),
          ),
          Text(
            PlayerTools.empty(item) ? '空' : '#${item['itemType']}',
            maxLines: 1,
          ),
          Text(
            PlayerTools.empty(item)
                ? '—'
                : '×${item['stack']} ${item['favorited'] == true ? '★' : ''}',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    ),
  );
  Widget _equipment() {
    Widget layout(Map<String, Object?> source, {int? loadout}) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final cell in PlayerTools.equipmentLayout(p, loadout: loadout))
          _slotTile(
            cell.group,
            cell.index,
            PlayerTools.slots(source[cell.group])[cell.index],
            cell.label,
            loadout: loadout,
          ),
      ],
    );
    final loadouts = p['loadouts'] is List ? p['loadouts'] as List : const [];
    return Column(
      children: [
        _card('当前装备', [
          _prefixButton(
            '当前装备最佳前缀',
            PlayerTools.equipment.where((group) => p[group] is List).toList(),
          ),
          layout(p),
        ]),
        for (var i = 0; i < loadouts.length; i++)
          _card('备用套装 ${i + 1}', [
            _prefixButton(
              '套装 ${i + 1} 最佳前缀',
              ['armor', 'dyes']
                  .where(
                    (group) => PlayerTools.slot(loadouts[i])[group] is List,
                  )
                  .toList(),
              loadout: i,
            ),
            layout(PlayerTools.slot(loadouts[i]), loadout: i),
          ]),
        const Text(
          '装备槽按存档实际布局显示；缺失槽位不会自动补齐。套装切换须由游戏执行，避免仅改变编号造成装备错位。',
          style: TextStyle(color: TerraColors.muted),
        ),
      ],
    );
  }

  Widget _prefixButton(String label, List<String> groups, {int? loadout}) {
    PlayerPrefixResult? preview;
    final scoring = prefixRules;
    if (scoring != null && groups.isNotEmpty) {
      try {
        preview = PlayerTools.bestPrefixes(
          p,
          groups: groups,
          rules: scoring,
          loadout: loadout,
        );
      } on FormatException {
        // Missing or unsupported schemas remain read-only.
      }
    }
    return Tooltip(
      message: scoring == null
          ? '需要已验证的物品与前缀资料。'
          : preview?.changedItems == 0
          ? '此范围已是最佳前缀或没有可重铸的物品。'
          : label,
      child: OutlinedButton.icon(
        onPressed:
            _busy || _dialogOpen || preview == null || preview.changedItems == 0
            ? null
            : () => _reforge(groups, preview!.changedItems, loadout: loadout),
        icon: const Icon(Icons.auto_fix_high),
        label: Text(label),
      ),
    );
  }

  Future<void> _reforge(List<String> groups, int count, {int? loadout}) async {
    if (_busy || _dialogOpen) return;
    final source = p, catalog = widget.catalog;
    setState(() => _dialogOpen = true);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认最佳前缀'),
        content: Text(
          '将修改 $count 件物品的前缀。范围：${loadout == null ? '' : '套装 ${loadout + 1} · '}${groups.map(_groupName).join('、')}。收藏和其他资料保留；不支持重铸的物品不变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认应用'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _dialogOpen = false);
    if (accepted != true) return;
    await _run(() async {
      if (!identical(source, p) || !identical(catalog, widget.catalog)) {
        throw const FormatException('角色或资源资料已改变，请重新确认范围。');
      }
      await widget.dispatch('playerBestPrefixes', {
        'groups': groups,
        'loadout': ?loadout,
        'confirmed': true,
      });
    });
  }

  Future<void> _editItem(
    String group,
    int index,
    Map<String, Object?> original,
    String label, {
    int? loadout,
  }) async {
    if (_busy || _dialogOpen || !_canEditSlots) return;
    final source = p, catalog = widget.catalog;
    final version = PlayerTools.number(source['version']);
    var draft = Map<String, Object?>.from(original);
    final id = TextEditingController(text: '${original['itemType'] ?? 0}'),
        quantity = TextEditingController(text: '${original['stack'] ?? 0}'),
        prefix = TextEditingController(text: '${original['prefix'] ?? 0}');
    var favorite = original['favorited'] == true;
    String? dialogError, notice;
    Map<String, Object?> readDraft() {
      final itemId = int.tryParse(id.text),
          count = int.tryParse(quantity.text),
          prefixId = int.tryParse(prefix.text);
      if (itemId == null || count == null || prefixId == null) {
        throw const FormatException('请输入整数。');
      }
      return PlayerTools.pasteSlot(
        original,
        {
          ...draft,
          'itemType': itemId,
          'stack': count,
          'prefix': prefixId,
          if (original.containsKey('favorited')) 'favorited': favorite,
        },
        version: version,
        catalog: catalog,
        lookup: rules,
      );
    }

    setState(() => _dialogOpen = true);
    final accepted = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) {
          final best = prefixRules?.bestPrefix(
            int.tryParse(id.text) ?? 0,
            version: version,
            current: int.tryParse(prefix.text) ?? 0,
          );
          void modify(void Function() work) {
            update(() {
              dialogError = null;
              notice = null;
              try {
                work();
              } catch (e) {
                dialogError = '$e';
              }
            });
          }

          return AlertDialog(
            title: Text('编辑 $label'),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in [
                      (id, '物品 ID；0 清空'),
                      (quantity, '数量'),
                      (prefix, '前缀 ID；0 无前缀'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TextField(
                          controller: e.$1,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => update(() {
                            dialogError = null;
                            notice = null;
                          }),
                          decoration: InputDecoration(labelText: e.$2),
                        ),
                      ),
                    if (original.containsKey('favorited'))
                      SwitchListTile(
                        title: const Text('收藏'),
                        value: favorite,
                        onChanged: (v) => update(() => favorite = v),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => modify(() {
                            _clipboard = PlayerTools.copySlot(readDraft());
                            notice = '已复制到本次编辑的物品剪贴板。';
                          }),
                          icon: const Icon(Icons.copy),
                          label: const Text('复制'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _clipboard == null
                              ? null
                              : () => modify(() {
                                  final pasted = PlayerTools.pasteSlot(
                                    original,
                                    _clipboard!,
                                    version: version,
                                    catalog: catalog,
                                    lookup: rules,
                                  );
                                  draft = pasted;
                                  id.text = '${pasted['itemType']}';
                                  quantity.text = '${pasted['stack']}';
                                  prefix.text = '${pasted['prefix']}';
                                  favorite = pasted['favorited'] == true;
                                  notice = '已粘贴到草稿，暂存后生效。';
                                }),
                          icon: const Icon(Icons.paste),
                          label: const Text('粘贴'),
                        ),
                        OutlinedButton.icon(
                          onPressed: best == null
                              ? null
                              : () => modify(() {
                                  prefix.text = '${best.id}';
                                  notice = best.ties.length > 1
                                      ? '存在并列最佳前缀；优先保留当前值。'
                                      : '已选择最佳前缀，暂存后生效。';
                                }),
                          icon: const Icon(Icons.auto_fix_high),
                          label: const Text('最佳前缀'),
                        ),
                      ],
                    ),
                    if (best != null)
                      Text(
                        '建议：${catalog?.byId('prefixes', best.id)?.name ?? '#${best.id}'}',
                      ),
                    if (dialogError != null)
                      Text(
                        dialogError!,
                        style: const TextStyle(color: TerraColors.red),
                      ),
                    if (notice != null) Text(notice!),
                    const Text(
                      '新增物品、增加数量和改变前缀需要可靠物品资料。',
                      style: TextStyle(color: TerraColors.muted),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    Navigator.pop(c, readDraft());
                  } catch (e) {
                    update(() => dialogError = '$e');
                  }
                },
                child: const Text('暂存'),
              ),
            ],
          );
        },
      ),
    );
    // Route teardown may still read the field controllers during its animation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      id.dispose();
      quantity.dispose();
      prefix.dispose();
    });
    if (!mounted) return;
    setState(() => _dialogOpen = false);
    if (accepted == null) return;
    await _run(() async {
      if (!identical(source, p) || !identical(catalog, widget.catalog)) {
        throw const FormatException('角色或资源资料已改变，请重新打开物品。');
      }
      await widget.dispatch('playerSlotEdit', {
        'group': group,
        'index': index,
        'loadout': ?loadout,
        'slot': accepted,
      });
    });
  }

  Widget _buffs() {
    final values = PlayerTools.slots(p['buffs']);
    final capacity = PlayerTools.buffCapacity(p);
    return _card('增益与减益 · $capacity 个槽位', [
      const Text('持续时间以秒输入，保存时换算为 60 帧/秒。新增状态须有可靠状态目录。'),
      for (var i = 0; i < capacity; i++)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            PlayerTools.number(values[i]['buffType']) == 0
                ? '空槽 ${i + 1}'
                : '状态 #${values[i]['buffType']}',
          ),
          subtitle: Text(
            '${(PlayerTools.number(values[i]['buffTime']) / 60).toStringAsFixed(2)} 秒',
          ),
          trailing: Wrap(
            children: [
              IconButton(
                tooltip: '编辑时长或状态',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _busy ? null : () => _editBuff(i, values[i]),
              ),
              if (PlayerTools.number(values[i]['buffType']) != 0)
                IconButton(
                  tooltip: '移除状态',
                  icon: const Icon(Icons.clear),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () =>
                              _patch('buffs', PlayerTools.editBuff(p, i, 0, 0)),
                        ),
                ),
            ],
          ),
        ),
      if (capacity == 0) const Text('此版本没有支持的状态槽位。'),
    ]);
  }

  Future<void> _editBuff(int index, Map<String, Object?> original) async {
    final id = TextEditingController(text: '${original['buffType'] ?? 0}'),
        seconds = TextEditingController(
          text: '${PlayerTools.number(original['buffTime']) / 60}',
        );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('状态槽 ${index + 1}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: id,
              decoration: const InputDecoration(labelText: '状态 ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: seconds,
              decoration: const InputDecoration(labelText: '持续秒数'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('暂存'),
          ),
        ],
      ),
    );
    final buff = int.tryParse(id.text), time = double.tryParse(seconds.text);
    id.dispose();
    seconds.dispose();
    if (accepted == true) {
      await _run(() async {
        if (buff == null || time == null) {
          throw const FormatException('请输入有效状态 ID 与秒数。');
        }
        await _patch(
          'buffs',
          PlayerTools.editBuff(
            p,
            index,
            buff,
            time,
            knownIds: widget.knownBuffIds,
          ),
        );
      });
    }
  }

  Widget _journey() {
    final powers = PlayerTools.slot(p['creativePowers']);
    final research = PlayerTools.slots(p['creativeItemSacrifices']);
    return Column(
      children: [
        _card('旅行能力', [
          if (PlayerTools.number(p['difficulty']) != 3)
            const Text('这些能力仅在旅行角色进入旅行世界后生效。'),
          if (!PlayerTools.supports(p, 'creativePowers'))
            const Text('此版本不支持旅行能力。'),
          if (PlayerTools.supports(p, 'creativePowers')) ...[
            for (final e in const {
              'godmodeEnabled': '上帝模式',
              'farPlacementEnabled': '远距离放置',
            }.entries)
              if (powers[e.key] is bool)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.value),
                  value: powers[e.key] == true,
                  onChanged: _busy
                      ? null
                      : (v) => _run(
                          () => _patch(
                            'creativePowers',
                            PlayerTools.power(p, e.key, v),
                          ),
                        ),
                ),
            if (powers['spawnRateSlider'] is num)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('刷怪设置：停止 → 默认 → 提高'),
                  Slider(
                    value: (powers['spawnRateSlider'] as num).toDouble().clamp(
                      0,
                      1,
                    ),
                    onChanged: _busy ? null : (v) {},
                    onChangeEnd: _busy
                        ? null
                        : (v) => _run(
                            () => _patch(
                              'creativePowers',
                              PlayerTools.power(p, 'spawnRateSlider', v),
                            ),
                          ),
                  ),
                ],
              ),
          ],
        ]),
        _card('物品研究', [
          if (!PlayerTools.supports(p, 'creativeItemSacrifices'))
            const Text('此版本不支持研究。')
          else ...[
            Text('已有 ${research.length} 条研究记录；未知记录保持原样。'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy || widget.itemRules == null
                  ? null
                  : _editResearch,
              icon: const Icon(Icons.science_outlined),
              label: const Text('设置单项研究进度'),
            ),
            for (final r in research.take(50))
              ListTile(
                dense: true,
                title: Text('${r['persistentId']}'),
                trailing: Text('${r['amount']}'),
              ),
            if (research.length > 50) const Text('仅展示前 50 条。可按物品 ID 精确编辑其他记录。'),
          ],
        ]),
      ],
    );
  }

  Future<void> _editResearch() async {
    final id = TextEditingController(), amount = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('设置研究进度'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: id,
              decoration: const InputDecoration(labelText: '物品 ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              decoration: const InputDecoration(labelText: '研究数量；0 移除此项'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('暂存'),
          ),
        ],
      ),
    );
    final item = int.tryParse(id.text), count = int.tryParse(amount.text);
    id.dispose();
    amount.dispose();
    if (accepted == true) {
      await _run(() async {
        final metadata = item == null ? null : rules(item);
        if (metadata == null || count == null) {
          throw const FormatException('缺少可靠研究资料或数量无效。');
        }
        await _patch(
          'creativeItemSacrifices',
          PlayerTools.research(p, metadata, count),
        );
      });
    }
  }

  Widget _advanced() => _card('高级 · 原始结构只读', [
    const Text('未知字段保留原样。版本转换需要真实转换引擎、损失预览与确认；不能仅修改 version 字段。'),
    ExpansionTile(
      title: const Text('查看解码后的 JSON'),
      children: [
        SelectableText(
          const JsonEncoder.withIndent('  ').convert(p),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ],
    ),
  ]);
}
