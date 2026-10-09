import 'package:flutter/material.dart';

import '../domain/bestiary_tools.dart';
import '../domain/resource_catalog.dart';

class BestiaryToolsPanel extends StatefulWidget {
  const BestiaryToolsPanel({
    super.key,
    required this.bestiary,
    this.catalog,
    required this.busy,
    required this.readOnly,
    required this.onAction,
  });
  final Map<String, Object?> bestiary;
  final ResourceCatalog? catalog;
  final bool busy, readOnly;
  final Future<void> Function(String action, Map<String, Object?> args)
  onAction;
  @override
  State<BestiaryToolsPanel> createState() => _BestiaryToolsPanelState();
}

class _BestiaryToolsPanelState extends State<BestiaryToolsPanel> {
  String _query = '', _status = '全部';
  String? _error;
  int _limit = 40;
  bool _pending = false;
  bool get _disabled => widget.busy || widget.readOnly || _pending;
  Future<void> _run(String action, Map<String, Object?> args) async {
    if (_disabled) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await widget.onAction(action, args);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _edit(BestiaryEntry row) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => _KillCountDialog(row: row),
    );
    if (!mounted || value == null || _disabled) return;
    await _run('bestiaryEntry', {
      'id': row.id,
      'kind': row.kind,
      'value': value,
    });
  }

  Future<void> _unlock() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('一键解锁已知条目？'),
        content: const Text(
          '仅处理本地目录中规则已验证的条目。保留已有正数击杀记录；零计数使用该条目的解锁数量。未知条目保持原样。此操作先暂存，导出才会写出新世界文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认解锁'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _disabled) return;
    await _run('bestiaryUnlockKnown', {'confirmed': true});
  }

  @override
  Widget build(BuildContext context) {
    List<BestiaryEntry> rows;
    try {
      rows = BestiaryTools.entries(widget.bestiary, widget.catalog);
    } catch (error) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('图鉴暂不可编辑：$error'),
      );
    }
    final known = rows.where((r) => r.editable).length;
    final unlocked = rows.where((r) => r.unlocked).length;
    final filtered = rows
        .where(
          (r) =>
              r.searchText.contains(_query.trim().toLowerCase()) &&
              (_status == '全部' ||
                  (_status == '已解锁'
                      ? r.unlocked
                      : _status == '未解锁'
                      ? !r.unlocked
                      : !r.editable)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '怪物图鉴',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          '已解锁 $unlocked · 未解锁 ${rows.length - unlocked} · 总数 ${rows.length}',
        ),
        Text(
          widget.catalog == null
              ? '请导入同版本本地资源包；未知记录仅供查看。'
              : '本地目录 ${widget.catalog!.gameVersion} · 可编辑 $known · 未知/只读 ${rows.length - known}',
        ),
        const Text('统计按持久 ID 合并变体；已解锁表示有进度，不代表全部掉落信息已显示。'),
        if (widget.readOnly) const Text('当前世界仅供查看，不能修改图鉴。'),
        if (known == 0) const Text('没有已验证的可编辑图鉴规则，无法一键解锁。'),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            labelText: '搜索名称或 ID',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() {
            _query = value;
            _limit = 40;
          }),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final status in ['全部', '已解锁', '未解锁', '未知/只读'])
              ChoiceChip(
                label: Text(status),
                selected: _status == status,
                onSelected: (_) => setState(() {
                  _status = status;
                  _limit = 40;
                }),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _disabled || known == 0 ? null : _unlock,
            icon: const Icon(Icons.lock_open),
            label: const Text('一键解锁'),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_pending) const LinearProgressIndicator(),
        if (filtered.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('没有匹配的图鉴条目')),
        for (final row in filtered.take(_limit))
          Card(
            child: ListTile(
              title: Text(row.name),
              subtitle: Text(
                '${row.id}\n${!row.editable
                    ? '未知元数据 · 只读'
                    : row.kind == 'kills'
                    ? '击杀 ${row.killCount} · 解锁计数 ${row.fullUnlockCount}'
                    : row.kind == 'chats'
                    ? '交谈记录'
                    : '目击记录'}',
              ),
              isThreeLine: true,
              trailing: !row.editable
                  ? const Icon(Icons.lock_outline)
                  : row.kind == 'kills'
                  ? IconButton(
                      tooltip: '编辑击杀数量',
                      onPressed: _disabled ? null : () => _edit(row),
                      icon: const Icon(Icons.edit_outlined),
                    )
                  : Switch(
                      value: row.unlocked,
                      onChanged: _disabled
                          ? null
                          : (value) => _run('bestiaryEntry', {
                              'id': row.id,
                              'kind': row.kind,
                              'value': value,
                            }),
                    ),
            ),
          ),
        if (filtered.length > _limit)
          TextButton(
            onPressed: () => setState(() => _limit += 40),
            child: Text('加载更多（已显示 $_limit / ${filtered.length}）'),
          ),
      ],
    );
  }
}

class _KillCountDialog extends StatefulWidget {
  const _KillCountDialog({required this.row});
  final BestiaryEntry row;
  @override
  State<_KillCountDialog> createState() => _KillCountDialogState();
}

class _KillCountDialogState extends State<_KillCountDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.row.killCount}',
  );
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final value = RegExp(r'^\d+$').hasMatch(text) ? int.tryParse(text) : null;
    if (value == null || value > BestiaryTools.maxKillCount) {
      setState(() => _error = '请输入 0–999,999,999 的整数');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设置击杀数量'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.row.name),
        TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: '击杀数量', errorText: _error),
          onSubmitted: (_) => _submit(),
        ),
        const Text('范围：0–999,999,999（整数）'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('暂存')),
    ],
  );
}
