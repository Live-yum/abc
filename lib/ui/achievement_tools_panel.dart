import 'package:flutter/material.dart';

import '../domain/achievement_catalog.dart';
import '../domain/resource_catalog.dart';

/// A catalog-backed view of imported conditions. Editing intents retain the
/// original record and condition IDs; unknown data belongs to the parent file.
class AchievementToolsPanel extends StatefulWidget {
  const AchievementToolsPanel({
    super.key,
    required this.records,
    required this.catalog,
    required this.busy,
    required this.onAction,
  });

  final List<Map<String, Object?>> records;
  final ResourceCatalog? catalog;
  final bool busy;
  final void Function(String, Map<String, Object?>) onAction;

  @override
  State<AchievementToolsPanel> createState() => _AchievementToolsPanelState();
}

class _AchievementToolsPanelState extends State<AchievementToolsPanel> {
  String _query = '', _status = 'all', _category = '';
  AchievementCatalog? _catalog;
  String? _catalogError;

  @override
  void initState() {
    super.initState();
    _readCatalog();
  }

  @override
  void didUpdateWidget(covariant AchievementToolsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.catalog != widget.catalog) _readCatalog();
  }

  void _readCatalog() {
    _catalog = null;
    _catalogError = null;
    if (widget.catalog == null) return;
    try {
      _catalog = AchievementCatalog.fromResourceCatalog(widget.catalog!);
    } on FormatException {
      _catalogError = '成就目录格式无效；数值进度与目录批量操作已禁用。';
    }
  }

  bool get _hasCatalog => _catalog?.definitions.isNotEmpty == true;
  bool get _canCreate =>
      _hasCatalog &&
      _catalog!.definitions.values.every(
        (definition) =>
            definition.conditions.isNotEmpty &&
            definition.conditions.values.every(
              (condition) => condition.editable,
            ),
      );

  AchievementDefinition? _definition(String id) => _catalog?.definitions[id];
  AchievementConditionDefinition? _condition(String id, String conditionId) =>
      _definition(id)?.conditions[conditionId];

  List<Map> _conditions(Map record) =>
      (record['conditions'] is List ? record['conditions'] as List : const [])
          .whereType<Map>()
          .toList(growable: false);

  String _recordCategory(Map record) {
    final category = _definition('${record['id']}')?.category ?? '';
    return category.isEmpty ? '未分类' : category;
  }

  bool _editable(String id, Map condition) {
    final kind = '${condition['kind']}';
    final definition = _condition(id, '${condition['id']}');
    if (definition != null) return definition.matches(kind);
    // Legacy booleans have an unambiguous representation without a catalog.
    return kind == 'boolean';
  }

  String _readOnlyReason(String id, Map condition) {
    final kind = '${condition['kind']}';
    final definition = _condition(id, '${condition['id']}');
    if (definition != null && definition.kind != kind) {
      return '只读：文件类型 $kind 与目录类型 ${definition.kind} 不匹配。';
    }
    if (kind == 'int' || kind == 'float') {
      return '只读：缺少与此条件 ID、类型匹配的已验证目标值；不会根据当前进度猜测。';
    }
    return '只读：此条件类型尚不支持安全编辑；原始数据保留。';
  }

  void _send(String action, Map<String, Object?> args) {
    if (!widget.busy) widget.onAction(action, args);
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
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

  Future<void> _completeKnown() async {
    if (widget.busy || !_hasCatalog || widget.records.isEmpty) return;
    final catalog = widget.catalog;
    final accepted = await _confirm(
      '完成目录内已知成就？',
      '仅完成当前文件中与目录 ID、条件 ID 和类型匹配的可编辑条件，数值进度设为已验证目标值。'
          '目录外成就、未知条件和未验证的数值均保留。不受当前搜索或筛选限制。',
    );
    if (!accepted || !mounted || widget.catalog != catalog) return;
    if (_hasCatalog && widget.records.isNotEmpty) {
      _send('achievementCompleteKnown', {'confirmed': true});
    }
  }

  Future<void> _create() async {
    if (widget.busy || !_canCreate) return;
    final catalog = widget.catalog;
    final accepted = await _confirm(
      '从目录新建成就文件？',
      '将使用当前目录中的 ${_catalog!.definitions.length} 项成就创建未完成的成就文件，'
          '替换当前工作区中的成就文档。此操作不会修改原始导入文件。',
    );
    if (!accepted || !mounted || widget.catalog != catalog || !_canCreate) {
      return;
    }
    _send('achievementNew', {'confirmed': true});
  }

  Future<void> _editProgress(String id, Map condition) async {
    if (widget.busy || !_editable(id, condition)) return;
    final conditionId = '${condition['id']}';
    final kind = '${condition['kind']}';
    final maximum = _condition(id, conditionId)?.maximum;
    if (maximum == null || (kind != 'int' && kind != 'float')) return;
    final controller = TextEditingController(
      text: '${condition['value'] ?? 0}',
    );
    final catalog = widget.catalog;
    String? error;
    final route = DialogRoute<num>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('编辑成就进度'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$id · $conditionId'),
                const SizedBox(height: 12),
                Text('目录目标值：$maximum。达到目标时自动标记完成。'),
                TextField(
                  key: const Key('achievement-progress-value'),
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: kind == 'float',
                  ),
                  decoration: InputDecoration(
                    labelText: kind == 'int' ? '整数进度' : '数值进度',
                    helperText: '范围：0–$maximum',
                    errorText: error,
                    errorMaxLines: 3,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('achievement-progress-save'),
              onPressed: () {
                final value = num.tryParse(controller.text.trim());
                if (value == null || !value.isFinite) {
                  update(() => error = '请输入有限的有效数值。');
                } else if (kind == 'int' && value != value.truncateToDouble()) {
                  update(() => error = '此条件的进度必须是整数。');
                } else if (value < 0 || value > maximum) {
                  update(() => error = '进度必须在 0–$maximum 之间。');
                } else {
                  Navigator.pop(context, kind == 'int' ? value.toInt() : value);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final value = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    controller.dispose();
    if (value == null || !mounted || widget.catalog != catalog) return;
    if (_editable(id, condition)) {
      _send('achievementCondition', {
        'id': id,
        'conditionId': conditionId,
        'value': value,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.records.map(_recordCategory).toSet().toList()
      ..sort();
    final category = categories.contains(_category) ? _category : '';
    final terms = _query.trim().toLowerCase().split(RegExp(r'\s+'));
    final visible = widget.records
        .where((record) {
          final id = '${record['id']}';
          final definition = _definition(id);
          final haystack =
              '$id ${definition?.name ?? ''} ${definition?.description ?? ''}'
                  .toLowerCase();
          return terms.every(haystack.contains) &&
              (_status == 'all' ||
                  (record['completed'] == true) == (_status == 'completed')) &&
              (category.isEmpty || _recordCategory(record) == category);
        })
        .toList(growable: false);
    final completed = widget.records
        .where((r) => r['completed'] == true)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('achievement-new'),
              onPressed: widget.busy || !_canCreate ? null : _create,
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('从目录新建'),
            ),
            OutlinedButton.icon(
              key: const Key('achievement-complete-known'),
              onPressed: widget.busy || !_hasCatalog || widget.records.isEmpty
                  ? null
                  : _completeKnown,
              icon: const Icon(Icons.done_all),
              label: const Text('完成已知成就'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!_hasCatalog)
          Text(_catalogError ?? '导入成就资源目录后，可编辑已验证的数值进度或新建文件。现有布尔条件仍可逐项编辑。')
        else if (!_canCreate)
          const Text('目录含未支持的条件或缺少目标值，无法安全新建文件；可继续编辑已验证条件。'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('achievement-search'),
          decoration: const InputDecoration(
            labelText: '搜索名称、描述或 ID',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth < 440
                ? constraints.maxWidth
                : 210.0;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: width,
                  child: DropdownButtonFormField<String>(
                    key: const Key('achievement-status-filter'),
                    initialValue: _status,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '完成状态'),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部状态')),
                      DropdownMenuItem(value: 'completed', child: Text('已完成')),
                      DropdownMenuItem(value: 'incomplete', child: Text('未完成')),
                    ],
                    onChanged: (value) =>
                        setState(() => _status = value ?? 'all'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('achievement-category-filter-$category'),
                    initialValue: category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '成就分类'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部分类')),
                      for (final value in categories)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _category = value ?? ''),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          '成就 ${widget.records.length} · 已完成 $completed · 显示 ${visible.length}',
        ),
        if (widget.busy) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        if (widget.records.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('导入 achievements.dat 或使用已验证目录新建成就文件。'),
          )
        else if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('没有匹配当前搜索与筛选的成就。'),
          ),
        for (final record in visible) _recordCard(record),
      ],
    );
  }

  Widget _recordCard(Map record) {
    final id = '${record['id']}';
    final definition = _definition(id);
    final conditions = _conditions(record);
    return Card(
      key: Key('achievement-$id'),
      child: ExpansionTile(
        key: PageStorageKey('achievement-expansion-$id'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Text(definition?.name ?? id),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$id · ${_recordCategory(record)} · ${record['completed'] == true ? '已完成' : '未完成'}',
            ),
            if (definition?.description.isNotEmpty == true)
              Text(definition!.description),
          ],
        ),
        children: [
          for (final condition in conditions) _conditionRow(id, condition),
          if (conditions.isEmpty) const Text('没有可读取的条件。'),
        ],
      ),
    );
  }

  Widget _conditionRow(String id, Map condition) {
    final conditionId = '${condition['id']}';
    final kind = '${condition['kind']}';
    final editable = _editable(id, condition);
    final numeric = kind == 'int' || kind == 'float';
    final maximum = _condition(id, conditionId)?.maximum;
    return Padding(
      key: Key('achievement-condition-$id-$conditionId'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conditionId,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      numeric
                          ? '$kind · 进度 ${condition['value'] ?? '未知'} / ${maximum ?? '目标未知'}'
                          : '$kind · ${condition['completed'] == true ? '已完成' : '未完成'}',
                    ),
                  ],
                ),
              ),
              Checkbox(
                key: Key('achievement-toggle-$id-$conditionId'),
                semanticLabel: '$id $conditionId 完成状态',
                value: condition['completed'] == true,
                onChanged: widget.busy || !editable
                    ? null
                    : (value) => _send('achievementCondition', {
                        'id': id,
                        'conditionId': conditionId,
                        'completed': value == true,
                      }),
              ),
            ],
          ),
          if (numeric)
            OutlinedButton.icon(
              key: Key('achievement-progress-$id-$conditionId'),
              onPressed: widget.busy || !editable
                  ? null
                  : () => _editProgress(id, condition),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('编辑进度'),
            ),
          if (!editable) Text(_readOnlyReason(id, condition)),
        ],
      ),
    );
  }
}
