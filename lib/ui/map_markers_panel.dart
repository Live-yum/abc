import 'package:flutter/material.dart';

import '../domain/map_markers.dart';
import '../domain/resource_catalog.dart';

class MapMarkersPanel extends StatefulWidget {
  const MapMarkersPanel({
    super.key,
    required this.profile,
    this.catalog,
    required this.busy,
    required this.hasWorld,
    required this.onAction,
  });
  final MapMarkerProfile profile;
  final ResourceCatalog? catalog;
  final bool busy, hasWorld;
  final Future<void> Function(String, Map<String, Object?>) onAction;
  @override
  State<MapMarkersPanel> createState() => _MapMarkersPanelState();
}

class _MapMarkersPanelState extends State<MapMarkersPanel> {
  String _kind = 'item', _query = '';
  String? _error;
  bool _pending = false;
  bool get _disabled => widget.busy || _pending;
  Map<String, _MarkerCandidate> _catalog(String kind) {
    final result = <String, _MarkerCandidate>{};
    final families = widget.catalog?.families;
    for (final row in [
      if (kind == 'tile') ...?families?['entity-markers'],
      ...?families?[kind == 'item' ? 'items' : 'tiles'],
    ]) {
      try {
        final raw = row.fields['selector'];
        if (raw is Map && raw.keys.any((key) => key is! String)) continue;
        final selectorFields = raw is Map
            ? Map<String, Object?>.from(raw)
            : null;
        if (selectorFields?.containsKey('tile_type') == true &&
            selectorFields!['tile_type'] is! int) {
          continue;
        }
        final rawId = selectorFields?.remove('tile_type');
        final id = rawId is int ? rawId : int.tryParse(row.id.split(':').first);
        if (id == null ||
            (raw != null && selectorFields == null) ||
            (row.family == 'entity-markers' &&
                (rawId is! int ||
                    selectorFields == null ||
                    ![1, 2].contains(selectorFields['locate'])))) {
          continue;
        }
        final marker = MapMarker(
          kind: kind,
          id: id,
          selector: selectorFields == null
              ? null
              : MapMarkerSelector.fromJson(selectorFields),
        );
        final existing = result[marker.key];
        result[marker.key] = _MarkerCandidate(
          marker,
          existing?.name ?? row.name,
          '${existing?.searchText ?? ''} ${row.searchText}',
        );
      } on FormatException {
        // A missing or malformed selector never becomes a guessed variant.
        continue;
      }
    }
    return result;
  }

  String _selectorLabel(MapMarker marker) {
    final s = marker.selector;
    if (s == null) return marker.kind == 'tile' ? '全部变体' : '';
    String frame(int value, int modulo) =>
        value < 0 ? '任意' : '$value${modulo > 0 ? '（模 $modulo）' : ''}';
    return '${s.locate == 1 ? '逐点定位' : '连通区域'} · 帧 X ${frame(s.frameX, s.frameXMod)} · 帧 Y ${frame(s.frameY, s.frameYMod)}';
  }

  Future<void> _chooseSelector(MapMarker marker) async {
    final selector = await showDialog<MapMarkerSelector>(
      context: context,
      builder: (_) => _MarkerSelectorDialog(marker: marker),
    );
    if (mounted && selector != null) {
      await _run(
        'markerToggle',
        MapMarker(
          kind: marker.kind,
          id: marker.id,
          selector: selector,
        ).identity,
      );
    }
  }

  Future<void> _run(String name, Map<String, Object?> args) async {
    if (_disabled) return;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await widget.onAction(name, args);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空所有地图标记？'),
        content: const Text('将清除本地保存的标记偏好，世界内容不会改变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _run('markerClear', {'confirmed': true});
    }
  }

  Future<void> _edit(MapMarker marker) async {
    final style = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _MarkerStyleDialog(marker: marker),
    );
    if (mounted && style != null) {
      await _run('markerStyle', {...marker.identity, ...style});
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalogs = {'item': _catalog('item'), 'tile': _catalog('tile')};
    final catalog = catalogs[_kind]!;
    final query = _query.trim().toLowerCase();
    final matches = catalog.entries
        .where(
          (e) =>
              e.value.searchText.contains(query) ||
              '${e.value.marker.id}' == query,
        )
        .take(40)
        .toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '地图标记 ${widget.profile.length}/256',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text('标记含指定物品的箱子或实体方块。仅影响地图预览，不修改世界内容；配置保存在本机。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed:
                    _disabled || !widget.hasWorld || widget.profile.isEmpty
                    ? null
                    : () => _run('markerRender', {}),
                icon: const Icon(Icons.map_outlined),
                label: const Text('渲染标记预览'),
              ),
              OutlinedButton(
                onPressed: _disabled || widget.profile.isEmpty ? null : _clear,
                child: const Text('清空标记'),
              ),
            ],
          ),
          if (!widget.hasWorld) const Text('导入世界后可渲染实际匹配位置。'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: '标记类型'),
            items: const [
              DropdownMenuItem(value: 'item', child: Text('箱内物品')),
              DropdownMenuItem(value: 'tile', child: Text('实体方块')),
            ],
            onChanged: _disabled
                ? null
                : (v) => setState(() {
                    _kind = v!;
                    _query = '';
                  }),
          ),
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('marker-search-$_kind'),
            enabled: !_disabled && catalog.isNotEmpty,
            decoration: const InputDecoration(
              labelText: '搜索名称或已知 ID',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          if (catalog.isEmpty) const Text('请导入对应资源目录后添加标记；已保存的未知 ID 会保留。'),
          if (catalog.isNotEmpty)
            Text('显示前 ${matches.length} 项；输入名称或 ID 缩小范围。'),
          for (final entry in matches)
            CheckboxListTile(
              key: ValueKey(
                'marker-candidate-$_kind-${entry.value.marker.id}${entry.value.marker.selector == null ? '' : ':${entry.value.marker.selector!.key}'}',
              ),
              contentPadding: EdgeInsets.zero,
              title: Text(entry.value.name),
              subtitle: Text(
                'ID ${entry.value.marker.id}${_kind == 'tile' ? ' · ${_selectorLabel(entry.value.marker)}' : ''}',
              ),
              secondary: _kind == 'tile'
                  ? IconButton(
                      tooltip: '输入定位条件',
                      onPressed: _disabled
                          ? null
                          : () => _chooseSelector(entry.value.marker),
                      icon: const Icon(Icons.tune),
                    )
                  : null,
              value: widget.profile.contains(
                _kind,
                entry.value.marker.id,
                selector: entry.value.marker.selector,
              ),
              onChanged:
                  _disabled ||
                      (!widget.profile.contains(
                            _kind,
                            entry.value.marker.id,
                            selector: entry.value.marker.selector,
                          ) &&
                          widget.profile.length >= MapMarkerProfile.maxMarkers)
                  ? null
                  : (_) => _run('markerToggle', entry.value.marker.identity),
            ),
          const Divider(),
          const Text('已选标记'),
          if (widget.profile.isEmpty) const Text('尚未选择标记。'),
          for (final marker in widget.profile.markers)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${marker.kind == 'item' ? '箱内物品' : '实体方块'} · ${catalogs[marker.kind]![marker.key]?.name ?? catalogs[marker.kind]!['${marker.kind}:${marker.id}']?.name ?? '未知 ID ${marker.id}'}',
                    ),
                    Text(
                      'ID ${marker.id} · ${marker.color} · 半径 ${marker.radius} · 线宽 ${marker.lineWidth}',
                    ),
                    if (marker.kind == 'tile') Text(_selectorLabel(marker)),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          key: ValueKey('marker-style-${marker.key}'),
                          onPressed: _disabled ? null : () => _edit(marker),
                          child: const Text('编辑样式'),
                        ),
                        TextButton(
                          key: ValueKey('marker-remove-${marker.key}'),
                          onPressed: _disabled
                              ? null
                              : () => _run('markerRemove', marker.identity),
                          child: const Text('移除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkerStyleDialog extends StatefulWidget {
  const _MarkerStyleDialog({required this.marker});
  final MapMarker marker;
  @override
  State<_MarkerStyleDialog> createState() => _MarkerStyleDialogState();
}

class _MarkerStyleDialogState extends State<_MarkerStyleDialog> {
  late final _color = TextEditingController(text: widget.marker.color);
  late final _radius = TextEditingController(text: '${widget.marker.radius}');
  late final _lineWidth = TextEditingController(
    text: '${widget.marker.lineWidth}',
  );
  String? _error;
  @override
  void dispose() {
    _color.dispose();
    _radius.dispose();
    _lineWidth.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final marker = MapMarker(
        kind: widget.marker.kind,
        id: widget.marker.id,
        selector: widget.marker.selector,
        color: _color.text.trim(),
        radius: int.tryParse(_radius.text) ?? -1,
        lineWidth: int.tryParse(_lineWidth.text) ?? -1,
      );
      Navigator.pop(context, {
        'color': marker.color,
        'radius': marker.radius,
        'lineWidth': marker.lineWidth,
      });
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('标记样式'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _color,
            decoration: const InputDecoration(labelText: '颜色 #RRGGBB'),
          ),
          TextField(
            controller: _radius,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '半径 1–60'),
          ),
          TextField(
            controller: _lineWidth,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '线宽 1–15'),
          ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存样式')),
    ],
  );
}

class _MarkerCandidate {
  const _MarkerCandidate(this.marker, this.name, this.searchText);
  final MapMarker marker;
  final String name, searchText;
}

class _MarkerSelectorDialog extends StatefulWidget {
  const _MarkerSelectorDialog({required this.marker});
  final MapMarker marker;
  @override
  State<_MarkerSelectorDialog> createState() => _MarkerSelectorDialogState();
}

class _MarkerSelectorDialogState extends State<_MarkerSelectorDialog> {
  late int _locate = widget.marker.selector?.locate ?? 1;
  late final _fields = <String, TextEditingController>{
    'frame_x': TextEditingController(
      text: '${widget.marker.selector?.frameX ?? -1}',
    ),
    'frame_y': TextEditingController(
      text: '${widget.marker.selector?.frameY ?? -1}',
    ),
    'frame_x_mod': TextEditingController(
      text: '${widget.marker.selector?.frameXMod ?? 0}',
    ),
    'frame_y_mod': TextEditingController(
      text: '${widget.marker.selector?.frameYMod ?? 0}',
    ),
  };
  String? _error;
  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      final selector = MapMarkerSelector.fromJson({
        'locate': _locate,
        for (final field in _fields.entries)
          field.key: int.tryParse(field.value.text.trim()),
      });
      Navigator.pop(context, selector);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('方块 ${widget.marker.id} 定位条件'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('输入已知的世界帧坐标；目录变体序号不等于帧坐标。-1 匹配任意帧，取模 0 表示精确匹配。'),
          DropdownButtonFormField<int>(
            initialValue: _locate,
            decoration: const InputDecoration(labelText: '定位模式'),
            items: const [
              DropdownMenuItem(value: 1, child: Text('每个匹配方块')),
              DropdownMenuItem(value: 2, child: Text('每个连通区域')),
            ],
            onChanged: (value) => setState(() => _locate = value!),
          ),
          for (final field in _fields.entries)
            TextField(
              key: ValueKey('marker-selector-${field.key}'),
              controller: field.value,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: InputDecoration(
                labelText: switch (field.key) {
                  'frame_x' => '帧 X（-1–32767）',
                  'frame_y' => '帧 Y（-1–32767）',
                  'frame_x_mod' => 'X 取模（0–32767）',
                  _ => 'Y 取模（0–32767）',
                },
              ),
            ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('切换此定位标记')),
    ],
  );
}
