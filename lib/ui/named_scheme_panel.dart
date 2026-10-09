import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/named_scheme_library.dart';

/// Emits local library intents only. Persistence and editor draft synchronization
/// belong to the controller, which receives stable IDs rather than labels.
class NamedSchemePanel extends StatefulWidget {
  final NamedSchemeLibrary library;
  final bool busy;
  final Future<void> Function(String, Map<String, Object?>) onAction;
  const NamedSchemePanel({
    super.key,
    required this.library,
    required this.busy,
    required this.onAction,
  });

  @override
  State<NamedSchemePanel> createState() => _NamedSchemePanelState();
}

class _NamedSchemePanelState extends State<NamedSchemePanel> {
  bool _sending = false;
  String? _error;
  bool get _enabled => !widget.busy && !_sending;

  Future<void> _send(String action, Map<String, Object?> args) async {
    if (!_enabled) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onAction(action, {
        'kind': widget.library.kind.name,
        ...args,
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _same(NamedScheme source) {
    final current = widget.library.schemeFor(source.id);
    return current != null &&
        jsonEncode(current.toJson()) == jsonEncode(source.toJson());
  }

  Future<void> _name(String action, [NamedScheme? source]) async {
    final kind = widget.library.kind;
    final initial = action == 'schemeRename'
        ? source!.name
        : widget.library.uniqueName(
            source == null
                ? '新建方案'
                : '${source.name.substring(0, source.name.length.clamp(0, 157))} 副本',
          );
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: switch (action) {
          'schemeClone' => '复制新建方案',
          'schemeRename' => '重命名方案',
          _ => '新建方案',
        },
        initialName: initial,
        validate: (name) {
          if (name.trim().isEmpty || name.length > 160) {
            return '请输入 1–160 个字符的名称';
          }
          if (widget.library.schemes.any(
            (item) =>
                (action != 'schemeRename' || item.id != source!.id) &&
                item.name.toLowerCase() == name.trim().toLowerCase(),
          )) {
            return '方案名称已存在，请使用其他名称';
          }
          return null;
        },
      ),
    );
    if (result == null || !mounted || !_enabled) return;
    if (widget.library.kind != kind || (source != null && !_same(source))) {
      setState(() => _error = '方案已变化，请重新操作');
      return;
    }
    await _send(action, {'name': result, if (source != null) 'id': source.id});
  }

  Future<void> _delete(NamedScheme source) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除方案？'),
        content: Text('删除本地方案「${source.name}」？此操作仅删除方案配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted || !_enabled) return;
    if (!_same(source)) {
      setState(() => _error = '方案已变化，请重新操作');
      return;
    }
    await _send('schemeDelete', {'id': source.id, 'confirmed': true});
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library, selected = library.selected;
    final editable = selected != null && !selected.isBuiltin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          library.kind == NamedSchemeKind.mapping ? '像素映射方案库' : '世界规则方案库',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (library.schemes.isEmpty)
          const Text('尚无保存的方案，请新建一个方案。')
        else
          DropdownButtonFormField<String>(
            key: ValueKey(
              'schemeSelection:${library.kind.name}:${library.selectedId}',
            ),
            initialValue: library.selectedId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '当前方案'),
            items: [
              for (final scheme in library.schemes)
                DropdownMenuItem(
                  value: scheme.id,
                  child: Text(
                    '${scheme.name}${scheme.id == library.defaultId ? ' · 默认' : ''}${scheme.isBuiltin ? ' · 内置' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _enabled
                ? (id) {
                    if (id != null) _send('schemeSelect', {'id': id});
                  }
                : null,
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed:
                  _enabled &&
                      library.schemes.length < NamedSchemeLibrary.maxSchemes
                  ? () => _name('schemeCreate')
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('新建方案'),
            ),
            OutlinedButton(
              onPressed:
                  _enabled &&
                      selected != null &&
                      selected.canClone &&
                      library.schemes.length < NamedSchemeLibrary.maxSchemes
                  ? () => _name('schemeClone', selected)
                  : null,
              child: const Text('复制新建'),
            ),
            OutlinedButton(
              onPressed: _enabled && editable
                  ? () => _name('schemeRename', selected)
                  : null,
              child: const Text('重命名'),
            ),
            OutlinedButton(
              onPressed:
                  _enabled &&
                      selected != null &&
                      selected.id != library.defaultId
                  ? () => _send('schemeSetDefault', {'id': selected.id})
                  : null,
              child: const Text('设为默认'),
            ),
            TextButton(
              onPressed: _enabled && editable ? () => _delete(selected) : null,
              child: const Text('删除方案'),
            ),
          ],
        ),
        if (selected?.isCorePreset == true)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('内置环境规则由核心生成，尚未提供可编辑规则展开；可选择和设为默认，暂不能克隆其内部规则。'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  final String title, initialName;
  final String? Function(String) validate;
  const _NameDialog({
    required this.title,
    required this.initialName,
    required this.validate,
  });
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final error = widget.validate(_name.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('schemeNameInput'),
      controller: _name,
      autofocus: true,
      maxLength: 160,
      decoration: InputDecoration(labelText: '方案名称', errorText: _error),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}
