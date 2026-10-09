import 'package:flutter/material.dart';

import '../domain/resource_catalog.dart';
import '../domain/prefix_rules.dart';

/// Emits narrow editing intents; source indices and unknown VM fields stay intact.
class ChestToolsPanel extends StatefulWidget {
  final List<Map<String, Object?>> chests;
  final bool busy, readOnly, verifiedRules;
  final ResourceCatalog? catalog;
  final int worldVersion;
  final Set<int> modifiedIndices;
  final Future<void> Function(String action, Map<String, Object?> args)
  onAction;
  const ChestToolsPanel({
    super.key,
    required this.chests,
    required this.busy,
    required this.readOnly,
    this.catalog,
    this.worldVersion = 0,
    this.modifiedIndices = const {},
    required this.verifiedRules,
    required this.onAction,
  });
  @override
  State<ChestToolsPanel> createState() => _ChestToolsPanelState();
}

class _ChestToolsPanelState extends State<ChestToolsPanel> {
  String _query = '', _filter = 'all', _sort = 'coordinate';
  int? _selected;
  bool _sending = false;
  String? _error;
  bool get _locked => widget.busy || widget.readOnly || _sending;
  List items(Map chest) =>
      chest['items'] is List ? chest['items'] as List : const [];
  int occupied(Map chest) => items(chest)
      .where(
        (s) =>
            s is Map &&
            s['itemType'] is num &&
            (s['itemType'] as num) > 0 &&
            s['stack'] is num &&
            (s['stack'] as num) > 0,
      )
      .length;
  String itemName(Object? id) =>
      widget.catalog?.byId('items', '$id')?.name ?? '物品 $id';
  String name(Map chest) =>
      '${chest['name'] ?? ''}'.isEmpty ? '未命名宝箱' : '${chest['name']}';
  Future<void> send(String action, Map<String, Object?> args) async {
    if (_locked) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onAction(action, args);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> reforge([int? index]) async {
    if (_locked || !widget.verifiedRules) return;
    final count = index == null ? widget.chests.length : 1;
    if (await confirm(
          '确认最佳前缀',
          '将为${index == null ? '全部' : '当前'} $count 个宝箱中的适用物品选择最佳前缀。仅使用已验证的版本规则；完成后显示实际修改数量。',
        ) &&
        mounted) {
      if (!widget.verifiedRules) return;
      await send('chestBestPrefixes', {'index': ?index, 'confirmed': true});
    }
  }

  Future<T?> inputDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final value = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    return value;
  }

  Future<void> rename(int index) async {
    final controller = TextEditingController(
      text: '${widget.chests[index]['name'] ?? ''}',
    );
    final value = await inputDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名宝箱'),
        content: TextField(
          key: const Key('chest-name'),
          controller: controller,
          maxLength: 20,
          decoration: const InputDecoration(labelText: '宝箱名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value != null && mounted) {
      await send('stageChest', {'index': index, 'name': value});
    }
    controller.dispose();
  }

  Future<void> editSlot(int index, int slot) async {
    final value = items(widget.chests[index])[slot];
    if (value != null && value is! Map) return;
    final original =
        value as Map? ?? const {'itemType': 0, 'stack': 0, 'prefix': 0};
    final id = TextEditingController(text: '${original['itemType'] ?? ''}');
    final quantity = TextEditingController(text: '${original['stack'] ?? ''}');
    final prefix = TextEditingController(text: '${original['prefix'] ?? ''}');
    String search = '';
    String? error;
    final result = await inputDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('编辑槽位 ${slot + 1}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const Key('slot-id'),
                    controller: id,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '物品 ID'),
                  ),
                  TextField(
                    key: const Key('slot-quantity'),
                    controller: quantity,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '数量'),
                  ),
                  TextField(
                    key: const Key('slot-prefix'),
                    controller: prefix,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '前缀 ID（0 表示无前缀）',
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('slot-best-prefix'),
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text('最佳前缀'),
                      onPressed:
                          !widget.verifiedRules ||
                              widget.catalog == null ||
                              widget.worldVersion <= 0
                          ? null
                          : () {
                              final item = int.tryParse(id.text.trim());
                              final current = int.tryParse(prefix.text.trim());
                              if (item == null ||
                                  current == null ||
                                  current < 0 ||
                                  current > 255) {
                                update(() => error = '请先输入有效的物品 ID 和前缀 ID。');
                                return;
                              }
                              final candidate = PrefixRules(widget.catalog!)
                                  .bestPrefix(
                                    item,
                                    version: widget.worldVersion,
                                    current: current,
                                  );
                              if (candidate == null) {
                                update(
                                  () => error = '没有适用于此物品的已验证最佳前缀，现有值未改变。',
                                );
                                return;
                              }
                              update(() {
                                prefix.text = '${candidate.id}';
                                error = null;
                              });
                            },
                    ),
                  ),
                  if (!widget.verifiedRules)
                    const Text(
                      '资源目录仅用于名称参考。未验证版本规则时，只能减少现有物品数量并保留原前缀，或清空槽位；添加物品、增加数量及更改前缀需要匹配规则。',
                    ),
                  if (widget.catalog != null) ...[
                    TextField(
                      key: const Key('slot-catalog-search'),
                      enabled: widget.verifiedRules,
                      decoration: const InputDecoration(
                        labelText: '搜索目录中的物品名称或 ID',
                      ),
                      onChanged: (value) => update(() => search = value),
                    ),
                    if (widget.verifiedRules && search.trim().isNotEmpty)
                      SizedBox(
                        height: 150,
                        child: Builder(
                          builder: (context) {
                            final rows = widget.catalog!.search(
                              'items',
                              query: search,
                            );
                            return ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (context, i) => ListTile(
                                dense: true,
                                title: Text(rows[i].name),
                                subtitle: Text('ID ${rows[i].id}'),
                                onTap: () => update(() {
                                  id.text = rows[i].id;
                                  search = '';
                                }),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('slot-clear'),
              onPressed: () => Navigator.pop(context, <String, Object?>{
                'itemId': 0,
                'quantity': 0,
                'prefix': 0,
              }),
              child: const Text('清空此槽'),
            ),
            FilledButton(
              onPressed: () {
                final item = int.tryParse(id.text.trim()),
                    n = int.tryParse(quantity.text.trim()),
                    p = int.tryParse(prefix.text.trim());
                if (item == null ||
                    item < 0 ||
                    item > 2147483647 ||
                    n == null ||
                    n < 0 ||
                    n > 9999 ||
                    p == null ||
                    p < 0 ||
                    p > 255 ||
                    (item == 0 && (n != 0 || p != 0)) ||
                    (item > 0 && n == 0)) {
                  update(
                    () => error = '请输入有效整数：物品 ID ≥ 0，数量 0–9999，前缀 0–255。空槽必须全部为 0，非空物品数量须大于 0。',
                  );
                  return;
                }
                final entry = widget.catalog?.byId('items', item);
                final gameplay = entry?.fields['gameplay'];
                final max =
                    entry?.fields['maxStack'] ??
                    (gameplay is Map ? gameplay['maxStack'] : null);
                if (widget.verifiedRules && max is num && n > max) {
                  update(() => error = '数量超过该物品堆叠上限 $max');
                  return;
                }
                Navigator.pop(context, <String, Object?>{
                  'itemId': item,
                  'quantity': n,
                  'prefix': p,
                });
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      await send('stageChest', {'index': index, 'slot': slot, ...result});
    }
    id.dispose();
    quantity.dispose();
    prefix.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nonempty = widget.chests.where((c) => occupied(c) > 0).length;
    final index = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '宝箱 ${widget.chests.length} · 非空 $nonempty · 空 ${widget.chests.length - nonempty}',
        ),
        if (widget.readOnly) const Text('当前世界版本仅支持只读，无法编辑宝箱。'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!widget.verifiedRules) const Text('未加载匹配版本的已验证重铸规则，自动最佳前缀不可用。'),
        if (index != null && index < widget.chests.length)
          _detail(index)
        else ...[
          TextField(
            key: const Key('chest-search'),
            onChanged: (v) => setState(() => _query = v.toLowerCase().trim()),
            decoration: const InputDecoration(
              labelText: '搜索名称、坐标、物品名称或 ID',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: const Key('chest-filter'),
                value: _filter,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('全部宝箱')),
                  DropdownMenuItem(value: 'nonempty', child: Text('非空宝箱')),
                  DropdownMenuItem(value: 'empty', child: Text('空宝箱')),
                  DropdownMenuItem(value: 'modified', child: Text('已修改')),
                ],
                onChanged: (v) => setState(() => _filter = v!),
              ),
              DropdownButton<String>(
                key: const Key('chest-sort'),
                value: _sort,
                items: const [
                  DropdownMenuItem(value: 'coordinate', child: Text('按坐标')),
                  DropdownMenuItem(value: 'name', child: Text('按名称')),
                  DropdownMenuItem(value: 'occupancy', child: Text('按占用')),
                ],
                onChanged: (v) => setState(() => _sort = v!),
              ),
              OutlinedButton(
                onPressed:
                    _locked || !widget.verifiedRules || widget.chests.isEmpty
                    ? null
                    : () => reforge(),
                child: const Text('全部最佳前缀'),
              ),
            ],
          ),
          SizedBox(height: 360, child: _list()),
        ],
      ],
    );
  }

  Widget _list() {
    final indices = List<int>.generate(widget.chests.length, (i) => i).where((
      i,
    ) {
      final c = widget.chests[i], used = occupied(widget.chests[i]);
      if (_filter == 'modified' && !widget.modifiedIndices.contains(i)) {
        return false;
      }
      if (_filter == 'empty' && used > 0 ||
          _filter == 'nonempty' && used == 0) {
        return false;
      }
      final text =
          '${name(c)} ${c['x']} ${c['y']} ${items(c).whereType<Map>().map((s) => '${s['itemType']} ${itemName(s['itemType'])}').join(' ')}'
              .toLowerCase();
      return _query.isEmpty || text.contains(_query);
    }).toList();
    num coordinate(Map c, String key) => c[key] is num ? c[key] as num : 0;
    indices.sort((a, b) {
      final ca = widget.chests[a], cb = widget.chests[b];
      final result = switch (_sort) {
        'name' => name(ca).compareTo(name(cb)),
        'occupancy' => occupied(cb).compareTo(occupied(ca)),
        _ =>
          coordinate(ca, 'x').compareTo(coordinate(cb, 'x')) != 0
              ? coordinate(ca, 'x').compareTo(coordinate(cb, 'x'))
              : coordinate(ca, 'y').compareTo(coordinate(cb, 'y')),
      };
      return result == 0 ? a.compareTo(b) : result;
    });
    if (indices.isEmpty) return const Center(child: Text('没有符合条件的宝箱'));
    return ListView.builder(
      itemCount: indices.length,
      itemBuilder: (context, row) {
        final i = indices[row], c = widget.chests[i];
        return ListTile(
          key: Key('chest-$i'),
          title: Text(
            '${name(c)}${widget.modifiedIndices.contains(i) ? ' · 已修改' : ''}',
          ),
          subtitle: Text(
            '坐标 (${c['x'] ?? '?'}, ${c['y'] ?? '?'}) · ${occupied(c)}/${items(c).length} 槽',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => _selected = i),
        );
      },
    );
  }

  Widget _detail(int index) {
    final c = widget.chests[index], slots = items(widget.chests[index]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _selected = null),
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回宝箱列表'),
          ),
        ),
        Text('${name(c)} · 坐标 (${c['x'] ?? '?'}, ${c['y'] ?? '?'})'),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _locked ? null : () => rename(index),
              child: const Text('重命名'),
            ),
            OutlinedButton(
              onPressed: _locked
                  ? null
                  : () => send('chestOrganize', {'index': index}),
              child: const Text('整理宝箱'),
            ),
            OutlinedButton(
              onPressed: _locked || !widget.verifiedRules
                  ? null
                  : () => reforge(index),
              child: const Text('当前最佳前缀'),
            ),
            OutlinedButton(
              onPressed: _locked
                  ? null
                  : () async {
                      if (await confirm(
                            '确认清空宝箱',
                            '清空「${name(c)}」中 ${occupied(c)} 个已占用槽位？',
                          ) &&
                          mounted) {
                        await send('chestClear', {
                          'index': index,
                          'confirmed': true,
                        });
                      }
                    },
              child: const Text('清空宝箱'),
            ),
          ],
        ),
        Text('已占用 ${occupied(c)}/${slots.length} 槽 · 点击槽位查看或编辑'),
        SizedBox(
          height: 320,
          child: slots.isEmpty
              ? const Center(child: Text('此宝箱没有可用槽位数据'))
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisExtent: 100,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: slots.length,
                  itemBuilder: (context, slot) {
                    final value = slots[slot];
                    final s = value is Map
                        ? value
                        : const {'itemType': 0, 'stack': 0, 'prefix': 0};
                    return OutlinedButton(
                      key: Key('chest-slot-$slot'),
                      onPressed: _locked || (value != null && value is! Map)
                          ? null
                          : () => editSlot(index, slot),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(5),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('#${slot + 1}'),
                          Text(
                            s['itemType'] == 0 ? '空槽' : itemName(s['itemType']),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'ID ${s['itemType'] ?? '?'} ×${s['stack'] ?? '?'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text('前缀 ${s['prefix'] ?? '?'}', maxLines: 1),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
