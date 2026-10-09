import 'package:flutter/material.dart';

import '../domain/vault_history.dart';
import '../platform/vault.dart';

/// Uses only parent-provided immutable versions; never reads source files.
class VaultHistoryPanel extends StatefulWidget {
  final List<VaultEntry> entries;
  final Future<void> Function(String id) onRestore;
  final Future<void> Function(String id)? onTrash;

  const VaultHistoryPanel({
    super.key,
    required this.entries,
    required this.onRestore,
    this.onTrash,
  });

  @override
  State<VaultHistoryPanel> createState() => _VaultHistoryPanelState();
}

class _VaultHistoryPanelState extends State<VaultHistoryPanel> {
  String? _busy;
  String? _error;

  Future<void> _act(VaultEntry entry, bool trash) async {
    if (_busy != null) return;
    if (trash) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('移入回收站？'),
          content: Text(
            '将本地存档「${entry.name}」移入回收站，可稍后恢复。\n'
            '只移动应用存档库中的版本，原始导入文件与导出文件不受影响。\n\n'
            '版本：${entry.id}\n大小：${entry.size} 字节\nSHA-256：${entry.sha256}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移入回收站'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || _busy != null) return;
    }
    setState(() {
      _busy = entry.id;
      _error = null;
    });
    try {
      await (trash ? widget.onTrash!(entry.id) : widget.onRestore(entry.id));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('本地版本与回收站', style: Theme.of(context).textTheme.titleMedium),
      const Text('回收站保留完整副本，可恢复；不会修改原始导入文件。'),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectableText(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (widget.entries.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('暂无本地版本')),
      for (final entry in widget.entries)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.name, style: Theme.of(context).textTheme.titleSmall),
                SelectableText(
                  '${VaultHistory.isTrashed(entry) ? '回收站' : '本地版本'} · ${entry.kind}\n'
                  '版本：${entry.id}\n大小：${entry.size} 字节\n'
                  '修改时间：${entry.modified.toUtc().toIso8601String()}\nSHA-256：${entry.sha256}',
                ),
                if (VaultHistory.isTrashed(entry))
                  TextButton.icon(
                    onPressed: _busy == null ? () => _act(entry, false) : null,
                    icon: const Icon(Icons.restore),
                    label: const Text('恢复此版本'),
                  )
                else if (widget.onTrash != null)
                  TextButton.icon(
                    onPressed: _busy == null ? () => _act(entry, true) : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('移入回收站'),
                  ),
                if (_busy == entry.id) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
    ],
  );
}
