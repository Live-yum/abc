import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/world_rules.dart';

class WorldRulesPanel extends StatefulWidget {
  final WorldRuleScheme scheme;
  final bool busy, hasWorld, readOnly;
  final Map<String, Object?>? preview;
  final Future<void> Function(String, Map<String, Object?>) onAction;
  const WorldRulesPanel({
    super.key,
    required this.scheme,
    required this.busy,
    required this.hasWorld,
    required this.readOnly,
    this.preview,
    required this.onAction,
  });
  @override
  State<WorldRulesPanel> createState() => _WorldRulesPanelState();
}

class _WorldRulesPanelState extends State<WorldRulesPanel> {
  late WorldRuleScheme _draft;
  late final TextEditingController _name;
  String? _error;
  @override
  void initState() {
    super.initState();
    _draft = widget.scheme;
    _name = TextEditingController(text: _draft.name);
  }

  @override
  void didUpdateWidget(covariant WorldRulesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scheme.fingerprint != widget.scheme.fingerprint) {
      _draft = widget.scheme;
      _name.text = _draft.name;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  WorldRuleScheme get _current => _draft.copyWith(name: _name.text);
  bool get _stale {
    try {
      return widget.preview == null ||
          widget.preview!['stale'] == true ||
          widget.preview!['fingerprint'] != _current.fingerprint;
    } catch (_) {
      return true;
    }
  }

  Future<void> _send(String action, [Map<String, Object?>? args]) async {
    try {
      setState(() => _error = null);
      await widget.onAction(action, args ?? {'scheme': _current.toJson()});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit([int? index]) async {
    final rule = await showDialog<WorldTileRule>(
      context: context,
      builder: (_) =>
          _RuleEditor(rule: index == null ? null : _draft.rules[index]),
    );
    if (rule == null || !mounted) return;
    setState(() {
      final rules = [..._draft.rules];
      if (index == null) {
        rules.add(rule);
      } else {
        rules[index] = rule;
      }
      _draft = _draft.copyWith(rules: rules);
    });
  }

  Future<void> _apply() async {
    final scheme = _current;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('应用到整个世界？'),
        content: Text(
          '方案「${scheme.name}」将作用于整个世界，不限于当前选区。将采用已生成并验证的候选世界。请确认预览与源世界无误。',
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
    if (yes == true &&
        mounted &&
        !_stale &&
        scheme.fingerprint == _current.fingerprint &&
        !widget.busy &&
        !widget.readOnly &&
        widget.hasWorld) {
      await _send('worldRulesApply', {
        'scheme': scheme.toJson(),
        'confirmed': true,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '完整世界规则',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Text('按顺序匹配与替换世界图格；数量限制 0 表示不限。引擎负责世界版本与家具安全校验。'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('worldRuleName'),
          controller: _name,
          enabled: enabled,
          decoration: const InputDecoration(labelText: '方案名称'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey(_draft.biomeMode ?? 'custom'),
          initialValue: _draft.biomeMode ?? 'custom',
          isExpanded: true,
          decoration: const InputDecoration(labelText: '自定义或核心预设'),
          items: const [
            DropdownMenuItem(value: 'custom', child: Text('自定义规则')),
            DropdownMenuItem(value: 'purify', child: Text('净化')),
            DropdownMenuItem(value: 'corruption', child: Text('腐化')),
            DropdownMenuItem(value: 'crimson', child: Text('猩红')),
            DropdownMenuItem(value: 'hallow', child: Text('神圣')),
          ],
          onChanged: enabled
              ? (mode) => setState(() {
                  _draft = WorldRuleScheme(
                    name: _draft.name,
                    biomeMode: mode == 'custom' ? null : mode,
                  );
                })
              : null,
        ),
        if (_draft.isBuiltin)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '此预设由核心生成，不能直接展开编辑。需要原应用规则时，使用“从原方案创建可编辑副本”。两种净化规则对部分物块与墙体的转换不同；请先检查候选。切换自定义会创建空方案。',
            ),
          ),
        if (!_draft.isBuiltin) ...[
          for (var i = 0; i < _draft.rules.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '规则 ${i + 1} · 限制 ${_draft.rules[i].limit == 0 ? '不限' : _draft.rules[i].limit}',
                    ),
                    Text(
                      _draft.rules[i].where.isEmpty
                          ? '⚠ 无匹配条件：匹配整个世界'
                          : '匹配：${jsonEncode(_draft.rules[i].where)}',
                    ),
                    Text('替换：${jsonEncode(_draft.rules[i].patch)}'),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: enabled ? () => _edit(i) : null,
                          child: const Text('编辑'),
                        ),
                        IconButton(
                          tooltip: '上移规则 ${i + 1}',
                          onPressed: enabled && i > 0
                              ? () => setState(() {
                                  final rules = [..._draft.rules];
                                  final rule = rules.removeAt(i);
                                  rules.insert(i - 1, rule);
                                  _draft = _draft.copyWith(rules: rules);
                                })
                              : null,
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: '下移规则 ${i + 1}',
                          onPressed: enabled && i + 1 < _draft.rules.length
                              ? () => setState(() {
                                  final rules = [..._draft.rules];
                                  final rule = rules.removeAt(i);
                                  rules.insert(i + 1, rule);
                                  _draft = _draft.copyWith(rules: rules);
                                })
                              : null,
                          icon: const Icon(Icons.arrow_downward),
                        ),
                        IconButton(
                          tooltip: '删除规则 ${i + 1}',
                          onPressed: enabled
                              ? () => setState(() {
                                  final rules = [..._draft.rules]..removeAt(i);
                                  _draft = _draft.copyWith(rules: rules);
                                })
                              : null,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: enabled && _draft.rules.length < 128
                  ? () => _edit()
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('添加规则'),
            ),
          ),
          if (_draft.rules.isEmpty) const Text('空方案可保存；添加规则后才能生成预览。'),
        ],
        if (widget.readOnly) const Text('此世界为只读，不能生成或应用规则结果。'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: enabled ? () => _send('worldRulesSave') : null,
              child: const Text('保存方案'),
            ),
            OutlinedButton(
              onPressed: enabled
                  ? () async {
                      await _send('worldRulesSave');
                      if (_error == null) {
                        await _send('export', {'kind': 'worldRules'});
                      }
                    }
                  : null,
              child: const Text('导出方案'),
            ),
            FilledButton.tonal(
              onPressed:
                  enabled &&
                      widget.hasWorld &&
                      !widget.readOnly &&
                      _draft.canPreview
                  ? () => _send('worldRulesPreview')
                  : null,
              child: const Text('生成预览'),
            ),
            FilledButton(
              onPressed:
                  enabled && widget.hasWorld && !widget.readOnly && !_stale
                  ? _apply
                  : null,
              child: const Text('应用预览'),
            ),
          ],
        ),
        if (widget.preview != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_stale ? '预览已过期，请重新生成。' : '候选世界已验证，可应用。'),
                Text('源世界：${widget.preview!['sourceName'] ?? '未知'}'),
                Text('候选大小：${widget.preview!['bytes'] ?? '未知'} 字节'),
                Text(
                  '方案：${_draft.name} · ${_draft.isBuiltin ? _draft.biomeMode : '${_draft.rules.length} 条规则'}',
                ),
              ],
            ),
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}

class _RuleEditor extends StatefulWidget {
  final WorldTileRule? rule;
  const _RuleEditor({this.rule});
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final Map<String, Object?> _where, _patch;
  late final TextEditingController _limit;
  String? _error;
  final Map<String, String> _invalid = {};
  @override
  void initState() {
    super.initState();
    _where = {...?widget.rule?.where};
    _patch = {...?widget.rule?.patch};
    _limit = TextEditingController(text: '${widget.rule?.limit ?? 0}');
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _editMaterial(Map<String, Object?> values) async {
    final material = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) =>
          _MaterialEditor(initial: values['material'] as Map<String, Object?>?),
    );
    if (material != null && mounted) {
      setState(() => values['material'] = material);
    }
  }

  Widget _side(bool where) {
    final values = where ? _where : _patch;
    final options = worldRuleFields.entries
        .where(
          (e) =>
              (where ? e.value.where : e.value.patch) &&
              !values.containsKey(e.key),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(where ? '匹配条件（全部满足）' : '替换属性'),
        if (where && values.isEmpty) const Text('⚠ 空条件会匹配整个世界'),
        for (final entry in values.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: entry.key == 'material'
                      ? TextButton(
                          onPressed: () => _editMaterial(values),
                          child: Text('编辑材质布局：${jsonEncode(entry.value)}'),
                        )
                      : worldRuleFields[entry.key]!.boolean
                      ? DropdownButtonFormField<bool>(
                          key: ValueKey('${where}_${entry.key}'),
                          initialValue: entry.value == true || entry.value == 1,
                          decoration: InputDecoration(
                            labelText: worldRuleFields[entry.key]!.label,
                          ),
                          items: const [
                            DropdownMenuItem(value: true, child: Text('是')),
                            DropdownMenuItem(value: false, child: Text('否')),
                          ],
                          onChanged: (v) =>
                              setState(() => values[entry.key] = v),
                        )
                      : TextFormField(
                          key: ValueKey('${where}_${entry.key}'),
                          initialValue: '${entry.value}',
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText:
                                '${worldRuleFields[entry.key]!.label} (${worldRuleFields[entry.key]!.min}–${worldRuleFields[entry.key]!.max})',
                          ),
                          onChanged: (v) {
                            final parsed = int.tryParse(v);
                            final key = '${where}_${entry.key}';
                            if (parsed == null) {
                              _invalid[key] = v;
                            } else {
                              _invalid.remove(key);
                              values[entry.key] = parsed;
                            }
                          },
                        ),
                ),
                IconButton(
                  tooltip: '移除 ${entry.key}',
                  onPressed: () => setState(() {
                    values.remove(entry.key);
                    _invalid.remove('${where}_${entry.key}');
                  }),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
          ),
        if (options.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey('${where}_${values.keys.join(',')}'),
            isExpanded: true,
            decoration: InputDecoration(labelText: where ? '添加匹配字段' : '添加替换字段'),
            items: [
              for (final e in options)
                DropdownMenuItem(value: e.key, child: Text(e.value.label)),
            ],
            onChanged: (key) {
              if (key != null) {
                setState(
                  () => values[key] = worldRuleFields[key]!.boolean
                      ? true
                      : worldRuleFields[key]!.min,
                );
              }
            },
          ),
        if (!values.containsKey('material'))
          TextButton(
            onPressed: () => _editMaterial(values),
            child: const Text('添加高级材质布局'),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.rule == null ? '添加规则' : '编辑规则'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _side(true),
            _side(false),
            TextField(
              controller: _limit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '数量限制（0 为不限）'),
            ),
            const Text(
              '区域编号 1–14；主题 1 沙漠 / 2 雪地 / 3 丛林；液体 0 无 / 1 水 / 2 岩浆 / 3 蜂蜜 / 4 微光。',
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      FilledButton(
        onPressed: () {
          try {
            if (_invalid.isNotEmpty) throw const FormatException('所有数值必须是整数');
            final limit = int.tryParse(_limit.text);
            if (limit == null) throw const FormatException('数量限制必须是整数');
            Navigator.pop(
              context,
              WorldTileRule(where: _where, patch: _patch, limit: limit),
            );
          } catch (e) {
            setState(() => _error = e.toString());
          }
        },
        child: const Text('保存规则'),
      ),
    ],
  );
}

class _MaterialEditor extends StatefulWidget {
  final Map<String, Object?>? initial;
  const _MaterialEditor({this.initial});
  @override
  State<_MaterialEditor> createState() => _MaterialEditorState();
}

class _MaterialEditorState extends State<_MaterialEditor> {
  final _controllers = <String, TextEditingController>{};
  String? _error;
  static const _labels = {
    'frame_x': '起始帧 X',
    'frame_y': '起始帧 Y',
    'width': '宽度（格）',
    'height': '高度（格）',
    'coordinate_width': '单格帧宽',
    'padding': '帧间距',
    'coordinate_heights': '各行帧高（逗号分隔）',
  };
  @override
  void initState() {
    super.initState();
    final defaults = <String, Object?>{
      'frame_x': 0,
      'frame_y': 0,
      'width': 1,
      'height': 1,
      'coordinate_width': 16,
      'padding': 2,
      'coordinate_heights': [16],
    };
    for (final key in _labels.keys) {
      final value = widget.initial?[key] ?? defaults[key];
      _controllers[key] = TextEditingController(
        text: value is List ? value.join(',') : '$value',
      );
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('高级材质布局'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '匹配侧必须指定物块 ID；目标布局需要相同尺寸的匹配布局。不可同时使用原始帧或平台样式。核心将验证具体家具与版本。',
            ),
            for (final key in _labels.keys)
              TextField(
                controller: _controllers[key],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: _labels[key]),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
      FilledButton(
        onPressed: () {
          try {
            final result = <String, Object?>{};
            for (final key in _labels.keys) {
              result[key] = key == 'coordinate_heights'
                  ? _controllers[key]!.text
                        .split(',')
                        .map((v) => int.tryParse(v.trim()))
                        .toList()
                  : int.tryParse(_controllers[key]!.text);
            }
            WorldTileRule.validateMaterial(result);
            Navigator.pop(context, result);
          } catch (e) {
            setState(() => _error = e.toString());
          }
        },
        child: const Text('保存布局'),
      ),
    ],
  );
}
