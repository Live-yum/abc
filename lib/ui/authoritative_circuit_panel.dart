import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../platform/resource_store.dart';
import 'terra_theme.dart';

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const <String, Object?>{};
List<Object?> _list(Object? value) => value is List ? value : const [];
int _integer(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;
Color _color(Object? value, Color fallback) {
  final hex = value?.toString().replaceFirst('#', '');
  final rgb = hex?.length == 6 ? int.tryParse(hex!, radix: 16) : null;
  return rgb == null ? fallback : Color(0xff000000 | rgb);
}

/// Original schematic UI for the authoritative, schema-1 circuit session.
/// All edits and simulations are validated and executed by the rules backend.
class AuthoritativeCircuitPanel extends StatefulWidget {
  final Map<String, Object?> state;
  final ResourceStore? resources;
  final Future<void> Function(String, Map<String, Object?>) onAction;

  const AuthoritativeCircuitPanel({
    super.key,
    required this.state,
    this.resources,
    required this.onAction,
  });

  @override
  State<AuthoritativeCircuitPanel> createState() =>
      _AuthoritativeCircuitPanelState();
}

class _AuthoritativeCircuitPanelState extends State<AuthoritativeCircuitPanel> {
  final _x = TextEditingController(text: '0');
  final _y = TextEditingController(text: '0');
  final _width = TextEditingController(text: '1');
  final _height = TextEditingController(text: '1');
  final _ticks = TextEditingController(text: '1');
  String _tool = 'inspect';
  Map<String, Object?>? _brush;
  String? _error;
  bool _pending = false,
      _merge = false,
      _dialogOpen = false,
      _pausePending = false;
  bool get _running => widget.state['running'] == true;
  int _mask = 1;
  Offset _origin = Offset.zero, _scaleOrigin = Offset.zero;
  Offset _scaleFocus = Offset.zero;
  double _cell = 24, _scaleCell = 24;
  Size _stageSize = const Size(600, 360);
  Offset? _selected;
  Map<String, Object?> get _snapshot => _map(widget.state['snapshot']);
  Map<String, Object?> get _document => _map(widget.state['document']);
  Map<String, Object?> get _world => _map(_document['world']);
  Map<String, Object?> get _catalog => _map(widget.state['catalog']);
  Map<String, Object?> get _definitions => _map(_catalog['definitions']);
  bool get _loaded => _document['format'] == 'viewer-terralogic';
  bool get _busy => _pending || widget.state['busy'] == true;
  bool get _dirty => _snapshot['dirty'] == true;
  String? get _backendError {
    final error = widget.state['error']?.toString();
    return error == null || error.isEmpty ? null : error;
  }

  List<Map<String, Object?>> get _tiles =>
      _list(_world['tiles']).whereType<Map>().map(_map).toList();
  List<Map<String, Object?>> get _palette =>
      _list(_catalog['palette']).whereType<Map>().map(_map).toList();

  @override
  void initState() {
    super.initState();
    _readViewport();
  }

  void _readViewport() {
    final viewport = _map(_document['viewport']);
    _origin = Offset(
      (_integer(viewport['x']) / 16).clamp(0, 2147483646),
      (_integer(viewport['y']) / 16).clamp(0, 2147483646),
    );
    _cell = ((viewport['zoom'] is num ? viewport['zoom'] as num : 1.5) * 16)
        .toDouble()
        .clamp(2, 96);
  }

  @override
  void didUpdateWidget(covariant AuthoritativeCircuitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = _map(oldWidget.state['snapshot']);
    if (previous['id'] != _snapshot['id']) {
      _selected = null;
      _readViewport();
    }
  }

  Future<void> _pause() async {
    if (_running) await _send('rulesToggleRun');
  }

  Future<T?> _dialog<T>(WidgetBuilder builder) async {
    if (_dialogOpen || !mounted) return null;
    _dialogOpen = true;
    try {
      await _pause();
      if (!mounted) return null;
      return await showDialog<T>(context: context, builder: builder);
    } finally {
      _dialogOpen = false;
    }
  }

  Future<bool> _send(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    // Stopping the owner-managed clock is safe even while its last tick runs.
    if (action == 'rulesToggleRun' && _running && mounted) {
      if (_pausePending) return false;
      _pausePending = true;
      try {
        await widget.onAction(action, args);
        return true;
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return false;
      } finally {
        _pausePending = false;
      }
    }
    if (_busy || !mounted) return false;
    setState(() {
      _pending = true;
      _error = null;
    });
    try {
      await widget.onAction(action, args);
      // The owner may report a caught backend failure through ChangeNotifier.
      // Read the refreshed state after that notification has rebuilt this panel.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      if (_backendError != null) {
        return false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
      return false;
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<bool> _edit(String method, [List<Object?> args = const []]) =>
      _send('rulesEdit', {'method': method, 'args': args});
  Future<bool> _simulate(String method, [List<Object?> args = const []]) =>
      _send('rulesSimulate', {'method': method, 'args': args});

  Future<bool> _confirmDiscard(String operation) async {
    if (!_dirty) return true;
    return await _dialog<bool>(
          (context) => AlertDialog(
            title: Text(operation),
            content: const Text('当前电路有未导出的修改。继续会丢弃这些修改。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('丢弃并继续'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _replace(
    String action,
    String title, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_busy) return;
    if (await _confirmDiscard(title) && mounted) await _send(action, args);
  }

  Future<void> _newDocument() async {
    var title = '未命名电路';
    final result = await _dialog<String>(
      (context) => AlertDialog(
        title: const Text('新建电路'),
        content: TextFormField(
          initialValue: title,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '名称'),
          onChanged: (value) => title = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, title),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await _replace('rulesNew', '新建电路', {'title': result});
    }
  }

  int _number(TextEditingController controller, String label, {int min = 0}) {
    final value = int.tryParse(controller.text);
    if (value == null || value < min || value > 2147483647) {
      throw FormatException('$label 必须是 $min–2147483647 的整数');
    }
    return value;
  }

  Map<String, Object?> _point() => {
    'x': _number(_x, 'X'),
    'y': _number(_y, 'Y'),
  };
  Map<String, Object?> _rect() => {
    ..._point(),
    'width': _number(_width, '宽', min: 1),
    'height': _number(_height, '高', min: 1),
  };
  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _chooseBrush(Map<String, Object?> brush) {
    unawaited(_pause());
    setState(() {
      _brush = brush;
      _tool = 'tile';
    });
  }

  Future<void> _showPalette() async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    await _pause();
    if (!mounted) {
      _dialogOpen = false;
      return;
    }
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _CircuitPalette(
              palette: _palette,
              definitions: _definitions,
              resources: widget.resources,
              selectedId: _brush?['id']?.toString(),
              onSelect: (brush) {
                _chooseBrush(brush);
                Navigator.pop(context);
              },
            ),
          ),
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  Map<String, Object?>? _tileAt(int x, int y) {
    for (final tile in _tiles) {
      final tx = _integer(tile['x']), ty = _integer(tile['y']);
      if (x >= tx &&
          y >= ty &&
          x < tx + _integer(tile['width'], 1) &&
          y < ty + _integer(tile['height'], 1)) {
        return tile;
      }
    }
    return null;
  }

  Future<void> _inspect(int x, int y) async {
    final tile = _tileAt(x, y);
    if (tile == null) {
      setState(() => _error = '($x, $y) 没有元件。');
      return;
    }
    await _dialog<void>(
      (context) => _CircuitProperties(
        tile: tile,
        name:
            _map(_definitions[tile['kind']])['name']?.toString() ??
            tile['kind'].toString(),
        onApply: (changes) async {
          final ok = await _edit('updateTile', [tile['x'], tile['y'], changes]);
          return ok ? null : _error ?? _backendError ?? '修改未完成';
        },
      ),
    );
  }

  Future<void> _actAt(Map<String, Object?> point) async {
    if (_busy || !_loaded) return;
    final x = point['x'] as int, y = point['y'] as int;
    setState(() {
      _selected = Offset(x.toDouble(), y.toDouble());
      _x.text = '$x';
      _y.text = '$y';
    });
    switch (_tool) {
      case 'pan':
        return;
      case 'inspect':
        await _inspect(x, y);
      case 'interact':
        await _simulate('interact', [x, y]);
      case 'input':
        await _simulate('emitInput', [x, y]);
      case 'pulse':
        await _simulate('trigger', [
          [point],
          _mask,
        ]);
      case 'tile':
        if (_brush == null) {
          setState(() => _error = '请先选择一个实际元件。');
        } else {
          await _edit('placeTile', [_brush, point]);
        }
      case 'select':
        await _edit('select', [
          {...point, 'width': 1, 'height': 1},
        ]);
      case 'network':
        await _edit('removeNetwork', [point, _mask]);
      default:
        await _edit('paint', [
          point,
          point,
          {'tool': _tool, 'mask': _mask},
        ]);
    }
  }

  void _tap(Offset local) {
    final x = (_origin.dx + local.dx / _cell).floor();
    final y = (_origin.dy + local.dy / _cell).floor();
    if (x < 0 ||
        y < 0 ||
        x >= _integer(_world['width']) ||
        y >= _integer(_world['height'])) {
      return;
    }
    unawaited(_actAt({'x': x, 'y': y}));
  }

  void _zoom(double factor, [Offset? focal]) {
    final focus = focal ?? _stageSize.center(Offset.zero);
    final next = (_cell * factor).clamp(.02, 96.0);
    setState(() {
      _origin = _positive(_origin + focus / _cell - focus / next);
      _cell = next;
    });
  }

  Offset _positive(Offset point) =>
      Offset(math.max(0, point.dx), math.max(0, point.dy));

  void _fit() {
    var left = double.infinity,
        top = double.infinity,
        right = 0.0,
        bottom = 0.0;
    void include(num x, num y, num width, num height) {
      left = math.min(left, x.toDouble());
      top = math.min(top, y.toDouble());
      right = math.max(right, (x + width).toDouble());
      bottom = math.max(bottom, (y + height).toDouble());
    }

    for (final tile in _tiles) {
      include(
        _integer(tile['x']),
        _integer(tile['y']),
        _integer(tile['width'], 1),
        _integer(tile['height'], 1),
      );
    }
    for (final wire in _list(_world['wires']).whereType<List>()) {
      if (wire.length >= 3) include(_integer(wire[0]), _integer(wire[1]), 1, 1);
    }
    setState(() {
      if (!left.isFinite) {
        _origin = Offset.zero;
        _cell = 24;
      } else {
        _origin = _positive(Offset(left - 2, top - 2));
        _cell = math
            .min(
              _stageSize.width / (right - left + 4),
              _stageSize.height / (bottom - top + 4),
            )
            .clamp(.02, 48);
      }
    });
  }

  void _toggleRun() => unawaited(_send('rulesToggleRun'));

  Widget _button(
    String label,
    VoidCallback action, {
    bool enabled = true,
    IconData? icon,
  }) => OutlinedButton.icon(
    onPressed: _busy || !enabled ? null : action,
    icon: Icon(icon ?? Icons.chevron_right, size: 16),
    label: Text(label),
  );
  Widget _numberField(String label, TextEditingController controller) =>
      SizedBox(
        width: 86,
        child: TextField(
          key: ValueKey('circuit-$label'),
          controller: controller,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  void dispose() {
    for (final controller in [_x, _y, _width, _height, _ticks]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error ?? _backendError;
    final selection = _map(_snapshot['selection']);
    final clipboard = _snapshot['clipboardAvailable'] == true;
    final demos = _list(_catalog['demos']);
    final target = _map(_catalog['target']);
    final colors = _list(_catalog['wireColors']);
    final names = _list(_catalog['wireNames']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('电路实验室', style: Theme.of(context).textTheme.titleLarge),
            TerraPill(
              _loaded
                  ? '${_document['title']} ${_dirty ? '· 未导出' : ''}'
                  : '尚未加载',
            ),
            if (target['game'] != null)
              TerraPill('Terraria ${target['game']}', color: TerraColors.blue),
          ],
        ),
        const SizedBox(height: 8),
        const Text('独立电路画布 · 使用原版规则与实际元件数据。示意图显示占格、状态和四色线路。'),
        const SizedBox(height: 12),
        if (error != null) ...[
          TerraNotice(error, warning: true, icon: Icons.error_outline),
          TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final confirmed =
                        !_loaded ||
                        await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('重新载入当前副本？'),
                                content: const Text(
                                  '当前副本内容保留。计算会话和内存撤销历史将重新开始。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('重新载入'),
                                  ),
                                ],
                              ),
                            ) ==
                            true;
                    if (confirmed && mounted) await _send('rulesRecover');
                  },
            icon: const Icon(Icons.refresh),
            label: const Text('重新连接计算引擎'),
          ),
        ],
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!_loaded)
              FilledButton.icon(
                onPressed: _busy ? null : () => _send('rulesOpen'),
                icon: const Icon(Icons.power_settings_new),
                label: const Text('加载电路规则'),
              ),
            if (widget.state['ready'] == true || _loaded) ...[
              _button('新建', _newDocument, icon: Icons.add),
              _button(
                '导入电路',
                () => _replace('rulesImport', '导入电路'),
                icon: Icons.file_open_outlined,
              ),
              PopupMenuButton<String>(
                tooltip: '加载示例',
                enabled: !_busy && demos.isNotEmpty,
                onSelected: (name) =>
                    _replace('rulesDemo', '加载示例', {'name': name}),
                itemBuilder: (context) => demos.map((entry) {
                  final record = _map(entry);
                  final name = entry is String
                      ? entry
                      : '${record['name'] ?? record['id']}';
                  return PopupMenuItem(
                    value: name,
                    child: Text('${record['label'] ?? name}'),
                  );
                }).toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                  child: Text('示例 (${demos.length}) ▾'),
                ),
              ),
            ],
            if (_loaded) ...[
              _button('导出电路', () => _send('rulesExport'), icon: Icons.save_alt),
              _button(
                '撤销',
                () => _edit('undo'),
                enabled: _snapshot['canUndo'] == true,
                icon: Icons.undo,
              ),
              _button(
                '重做',
                () => _edit('redo'),
                enabled: _snapshot['canRedo'] == true,
                icon: Icons.redo,
              ),
              _button(
                '重置模拟',
                () => _replace('rulesReset', '重置模拟'),
                enabled: _snapshot['canReset'] == true,
                icon: Icons.restart_alt,
              ),
              _button(
                '关闭电路',
                () => _replace('rulesClose', '关闭电路'),
                icon: Icons.close,
              ),
            ],
          ],
        ),
        if (!_loaded) ...[
          const SizedBox(height: 12),
          const TerraNotice('加载规则后，可从完整目录新建电路，或导入兼容工程继续编辑。'),
        ] else ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _busy && !_running ? null : _toggleRun,
                icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                label: Text(_running ? '暂停' : '运行'),
              ),
              _button('单步', () => _simulate('step', [1])),
              _numberField('Tick 数', _ticks),
              _button(
                '推进',
                () => _guard(() async {
                  final count = _number(_ticks, 'Tick 数', min: 1);
                  if (count > 60) throw const FormatException('每次推进 1–60 tick');
                  await _simulate('step', [count]);
                }),
              ),
              Text(
                'tick ${_document['tick'] ?? 0} · ${_running ? '运行中' : '已暂停'}',
              ),
              FilterChip(
                label: const Text('记录信号轨迹'),
                selected: widget.state['debug'] == true,
                onSelected: _busy
                    ? null
                    : (enabled) => _send('rulesDebug', {'enabled': enabled}),
              ),
            ],
          ),
          if (_snapshot['packet'] is Map)
            ExpansionTile(
              title: const Text('信号与事件'),
              subtitle: Text(
                '运算 ${(_snapshot['packet'] as Map)['operations'] ?? 0}',
              ),
              children: [
                for (final key in ['trace', 'events'])
                  if ((_snapshot['packet'] as Map)[key] is List) ...[
                    Text(
                      '${key == 'trace' ? '信号轨迹' : '事件'} · ${((_snapshot['packet'] as Map)[key] as List).length} 条',
                    ),
                    SizedBox(
                      height: 140,
                      child: ListView.builder(
                        itemCount: math.min(
                          200,
                          ((_snapshot['packet'] as Map)[key] as List).length,
                        ),
                        itemBuilder: (context, index) => ListTile(
                          dense: true,
                          title: Text(
                            jsonEncode(
                              ((_snapshot['packet'] as Map)[key]
                                  as List)[index],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    if (((_snapshot['packet'] as Map)[key] as List).length >
                        200)
                      const Text('列表显示前 200 条。'),
                  ],
              ],
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('circuit-tool-$_tool'),
                  initialValue: _tool,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '画布工具'),
                  items:
                      const {
                            'inspect': '查看属性',
                            'pan': '平移画布',
                            'interact': '交互开关',
                            'tile': '放置元件',
                            'wire': '铺设电线',
                            'wire-erase': '剪除电线',
                            'select': '选择格子',
                            'erase': '擦除格子',
                            'actuator-on': '安装致动器',
                            'actuator-off': '拆除致动器',
                            'input': '元件测试输入',
                            'pulse': '触发线路',
                            'network': '删除相连网络',
                          }.entries
                          .map(
                            (entry) => DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                          )
                          .toList(),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          _tool = value!;
                        }),
                ),
              ),
              _button(
                '元件库 (${_palette.length})',
                _showPalette,
                icon: Icons.grid_view,
              ),
              if (_brush != null)
                Text('画笔：${_brush!['label'] ?? _brush!['kind']}'),
              for (var i = 0; i < colors.length && i < 4; i++)
                FilterChip(
                  label: Text(i < names.length ? '${names[i]}' : '通道 ${i + 1}'),
                  avatar: CircleAvatar(
                    backgroundColor: _color(colors[i], TerraColors.muted),
                    radius: 5,
                  ),
                  selected: _mask & (1 << i) != 0,
                  onSelected: _busy
                      ? null
                      : (value) => setState(() {
                          final next = value
                              ? _mask | (1 << i)
                              : _mask & ~(1 << i);
                          if (next != 0) _mask = next;
                        }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final board = _buildStage(colors);
              if (constraints.maxWidth < 1000) return board;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 270,
                    height: 420,
                    child: _CircuitPalette(
                      palette: _palette,
                      definitions: _definitions,
                      resources: widget.resources,
                      selectedId: _brush?['id']?.toString(),
                      onSelect: _chooseBrush,
                      enabled: !_busy,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: board),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _button('缩小', () => _zoom(.8), icon: Icons.remove),
              _button('放大', () => _zoom(1.25), icon: Icons.add),
              _button('适应内容', _fit, icon: Icons.fit_screen),
              Text(
                '${_tiles.length} 元件 · ${_list(_world['wires']).length} 线格 · ${_cell.toStringAsFixed(1)} px/格',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '选择平移工具拖动画布，或双指缩放。点击按当前工具操作；元件色块表示真实占格，非游戏贴图。',
            style: TextStyle(color: TerraColors.muted, fontSize: 11),
          ),
          const SizedBox(height: 16),
          TerraPanel(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  selection.isEmpty
                      ? '坐标与选区'
                      : '选区 (${selection['x']}, ${selection['y']}) · ${selection['width']} × ${selection['height']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _numberField('X', _x),
                    _numberField('Y', _y),
                    _numberField('宽', _width),
                    _numberField('高', _height),
                    _button('执行当前工具', () => _guard(() => _actAt(_point()))),
                    _button(
                      '定位坐标',
                      () => _guard(() async {
                        final point = _point();
                        setState(
                          () => _origin = _positive(
                            Offset(
                              (point['x'] as int).toDouble() - 2,
                              (point['y'] as int).toDouble() - 2,
                            ),
                          ),
                        );
                      }),
                    ),
                    _button(
                      '框选区域',
                      () => _guard(() async {
                        await _edit('select', [_rect()]);
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _button(
                      '复制',
                      () => _edit('copy'),
                      enabled: selection.isNotEmpty,
                      icon: Icons.copy,
                    ),
                    _button(
                      '剪切',
                      () => _edit('cut'),
                      enabled: selection.isNotEmpty,
                      icon: Icons.cut,
                    ),
                    _button(
                      '粘贴到坐标',
                      () => _guard(() async {
                        await _edit('paste', [
                          _point(),
                          {'merge': _merge},
                        ]);
                      }),
                      enabled: clipboard,
                      icon: Icons.paste,
                    ),
                    FilterChip(
                      label: const Text('合并粘贴'),
                      selected: _merge,
                      onSelected: _busy
                          ? null
                          : (v) => setState(() => _merge = v),
                    ),
                    _button(
                      '旋转剪贴板',
                      () => _edit('transformClipboard', ['rotate']),
                      enabled: clipboard,
                    ),
                    _button(
                      '水平镜像',
                      () => _edit('transformClipboard', ['flipX']),
                      enabled: clipboard,
                    ),
                    _button(
                      '垂直镜像',
                      () => _edit('transformClipboard', ['flipY']),
                      enabled: clipboard,
                    ),
                    _button(
                      '填充电线',
                      () => _edit('fill', [
                        {'mask': _mask},
                      ]),
                      enabled: selection.isNotEmpty,
                    ),
                    _button(
                      '填充元件',
                      () => _edit('fill', [
                        {'tile': _brush},
                      ]),
                      enabled: selection.isNotEmpty && _brush != null,
                    ),
                    _button(
                      '删除选区',
                      () => _edit('erase'),
                      enabled: selection.isNotEmpty,
                    ),
                    _button(
                      '剪除选区线色',
                      () => _edit('erase', [selection, _mask]),
                      enabled: selection.isNotEmpty,
                    ),
                    _button(
                      '选区安装致动器',
                      () => _edit('applyActuators', [true]),
                      enabled: selection.isNotEmpty,
                    ),
                    _button(
                      '选区拆除致动器',
                      () => _edit('applyActuators', [false]),
                      enabled: selection.isNotEmpty,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _button('恢复一次性机关', () => _edit('rearm')),
                    _button(
                      '推进黎明边界',
                      () => _simulate('advanceBoundary', ['dawn']),
                    ),
                    _button(
                      '推进黄昏边界',
                      () => _simulate('advanceBoundary', ['dusk']),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if ('${_document['notes'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 12),
            TerraNotice('${_document['notes']}', icon: Icons.info_outline),
          ],
          if (_snapshot['packet'] != null)
            ExpansionTile(
              title: const Text('实际模拟反馈'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ')
                      .convert(_snapshot['packet']),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _buildStage(List<Object?> colors) => SizedBox(
    height: 360,
    child: LayoutBuilder(
      builder: (context, constraints) {
        _stageSize = Size(constraints.maxWidth, constraints.maxHeight);
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Semantics(
            label: '原版电路示意画布，点击格子执行当前工具',
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) => _zoom(
                      event.scrollDelta.dy > 0 ? .85 : 1.15,
                      event.localPosition,
                    ),
                  );
                }
              },
              child: GestureDetector(
                key: const ValueKey('authoritative-circuit-stage'),
                behavior: HitTestBehavior.opaque,
                onTapUp: _busy ? null : (event) => _tap(event.localPosition),
                onScaleStart: (event) {
                  _scaleOrigin = _origin;
                  _scaleCell = _cell;
                  _scaleFocus = event.localFocalPoint;
                },
                onScaleUpdate: (event) {
                  if (event.pointerCount < 2 && _tool != 'pan') return;
                  setState(() {
                    _cell = (_scaleCell * event.scale).clamp(.02, 96);
                    _origin = _positive(
                      _scaleOrigin +
                          _scaleFocus / _scaleCell -
                          event.localFocalPoint / _cell,
                    );
                  });
                },
                child: CustomPaint(
                  painter: _CircuitSchematic(
                    world: _world,
                    definitions: _definitions,
                    origin: _origin,
                    cell: _cell,
                    selection: _map(_snapshot['selection']),
                    selected: _selected,
                    wireColors: colors
                        .map((v) => _color(v, TerraColors.muted))
                        .toList(),
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _CircuitPalette extends StatefulWidget {
  final List<Map<String, Object?>> palette;
  final Map<String, Object?> definitions;
  final ResourceStore? resources;
  final String? selectedId;
  final bool enabled;
  final ValueChanged<Map<String, Object?>> onSelect;
  const _CircuitPalette({
    required this.palette,
    required this.definitions,
    required this.resources,
    required this.selectedId,
    required this.onSelect,
    this.enabled = true,
  });
  @override
  State<_CircuitPalette> createState() => _CircuitPaletteState();
}

class _CircuitPaletteState extends State<_CircuitPalette> {
  String _query = '', _group = '';
  String _groupOf(Map<String, Object?> row) =>
      '${row['group'] ?? _map(widget.definitions[row['kind']])['group'] ?? '其他'}';
  @override
  Widget build(BuildContext context) {
    final groups = widget.palette.map(_groupOf).toSet().toList()..sort();
    final terms = _query.trim().toLowerCase().split(RegExp(r'\s+'));
    final rows = widget.palette
        .where(
          (row) =>
              (_group.isEmpty || _groupOf(row) == _group) &&
              terms.every(
                '${row['label']} ${row['kind']} ${row['id']} ${row['itemId']} ${row['itemName']} ${_groupOf(row)}'
                    .toLowerCase()
                    .contains,
              ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '实际元件库 · ${rows.length}/${widget.palette.length}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('circuit-palette-search'),
          decoration: const InputDecoration(
            labelText: '搜索名称、类型或物品 ID',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: '元件分组'),
          items: [
            const DropdownMenuItem(value: '', child: Text('所有分组')),
            ...groups.map(
              (group) => DropdownMenuItem(value: group, child: Text(group)),
            ),
          ],
          onChanged: (value) => setState(() => _group = value ?? ''),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('没有匹配的实际元件'))
              : ListView.builder(
                  key: const ValueKey('circuit-palette-list'),
                  itemExtent: 68,
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final resource = row['itemId'] == null
                        ? null
                        : widget.resources?.catalog.byId(
                            'items',
                            row['itemId']!,
                          );
                    final bytes = resource == null
                        ? null
                        : widget.resources?.iconBytes(resource);
                    return ListTile(
                      key: ValueKey('circuit-brush-${row['id']}'),
                      selected: '${row['id']}' == widget.selectedId,
                      enabled: widget.enabled,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      leading: SizedBox(
                        width: 30,
                        height: 30,
                        child: bytes == null
                            ? const Icon(Icons.memory, color: TerraColors.muted)
                            : Image.memory(
                                bytes,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.none,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.broken_image_outlined),
                              ),
                      ),
                      title: Text(
                        '${row['label'] ?? row['kind']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_groupOf(row)} · ${row['kind']}${row['itemId'] == null ? '' : ' · #${row['itemId']}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => widget.onSelect(row),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CircuitProperties extends StatefulWidget {
  final Map<String, Object?> tile;
  final String name;
  final Future<String?> Function(Map<String, Object?>) onApply;
  const _CircuitProperties({
    required this.tile,
    required this.name,
    required this.onApply,
  });
  @override
  State<_CircuitProperties> createState() => _CircuitPropertiesState();
}

class _CircuitPropertiesState extends State<_CircuitProperties> {
  static const _identity = {'kind', 'x', 'y', 'width', 'height'};
  final _controllers = <String, TextEditingController>{};
  final _booleans = <String, bool>{};
  String? _error;
  bool _pending = false;
  @override
  void initState() {
    super.initState();
    for (final entry in widget.tile.entries.where(
      (e) => !_identity.contains(e.key),
    )) {
      if (entry.value is bool) {
        _booleans[entry.key] = entry.value as bool;
      } else {
        _controllers[entry.key] = TextEditingController(
          text: entry.value is String
              ? entry.value as String
              : jsonEncode(entry.value),
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _apply() async {
    if (_pending) return;
    final changes = <String, Object?>{};
    try {
      for (final entry in _booleans.entries) {
        if (entry.value != widget.tile[entry.key]) {
          changes[entry.key] = entry.value;
        }
      }
      for (final entry in _controllers.entries) {
        final old = widget.tile[entry.key];
        final Object? value;
        if (old is String) {
          value = entry.value.text;
        } else {
          value = jsonDecode(entry.value.text);
          if (old is num && value is! num) {
            throw FormatException('${entry.key} 必须是数字');
          }
        }
        if (jsonEncode(old) != jsonEncode(value)) changes[entry.key] = value;
      }
      if (changes.isEmpty) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _pending = true;
        _error = null;
      });
      final error = await widget.onApply(changes);
      if (!mounted) return;
      if (error == null) {
        Navigator.pop(context);
        return;
      }
      setState(() => _error = error);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_pending,
    child: AlertDialog(
      title: Text('${widget.name} · 实际属性'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.tile['kind']} · (${widget.tile['x']}, ${widget.tile['y']}) · ${widget.tile['width']} × ${widget.tile['height']}',
              ),
              const SizedBox(height: 8),
              const Text('以下字段来自当前元件。样式、朝向、状态及复杂 JSON 的合法性由原版规则验证；失败会保留原电路。'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: TerraColors.red),
                  ),
                ),
              for (final key in _booleans.keys)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(key),
                  value: _booleans[key]!,
                  onChanged: _pending
                      ? null
                      : (v) => setState(() => _booleans[key] = v),
                ),
              for (final entry in _controllers.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextField(
                    key: ValueKey('circuit-property-${entry.key}'),
                    controller: entry.value,
                    enabled: !_pending,
                    minLines: 1,
                    maxLines:
                        widget.tile[entry.key] is Map ||
                            widget.tile[entry.key] is List ||
                            entry.key == 'message'
                        ? 6
                        : 1,
                    decoration: InputDecoration(
                      labelText:
                          '${entry.key}${widget.tile[entry.key] is Map || widget.tile[entry.key] is List ? ' (JSON)' : ''}',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _pending ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _pending ? null : _apply,
          child: Text(_pending ? '验证中…' : '应用属性'),
        ),
      ],
    ),
  );
}

class _CircuitSchematic extends CustomPainter {
  final Map<String, Object?> world, definitions, selection;
  final Offset origin;
  final Offset? selected;
  final double cell;
  final List<Color> wireColors;
  const _CircuitSchematic({
    required this.world,
    required this.definitions,
    required this.origin,
    required this.cell,
    required this.selection,
    required this.selected,
    required this.wireColors,
  });
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff0b141d),
    );
    canvas.clipRect(Offset.zero & size);
    final visible = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      size.width / cell,
      size.height / cell,
    );
    Rect screenRect(num x, num y, num w, num h) => Rect.fromLTWH(
      (x - origin.dx) * cell,
      (y - origin.dy) * cell,
      w * cell,
      h * cell,
    );
    if (cell >= 8) {
      final paint = Paint()
        ..color = TerraColors.border.withValues(alpha: .45)
        ..strokeWidth = .5;
      for (double x = -(origin.dx % 1) * cell; x < size.width; x += cell) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (double y = -(origin.dy % 1) * cell; y < size.height; y += cell) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
    for (final raw in _list(world['background']).whereType<List>()) {
      if (raw.length < 2) continue;
      final x = _integer(raw[0]), y = _integer(raw[1]);
      if (!visible.overlaps(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1))) {
        continue;
      }
      canvas.drawRect(
        screenRect(x, y, 1, 1).deflate(1),
        Paint()..color = TerraColors.border.withValues(alpha: .35),
      );
    }
    for (final tile in _list(world['tiles']).whereType<Map>()) {
      final x = _integer(tile['x']),
          y = _integer(tile['y']),
          w = _integer(tile['width'], 1),
          h = _integer(tile['height'], 1);
      if (!visible.overlaps(
        Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble()),
      )) {
        continue;
      }
      final rect = screenRect(x, y, w, h).deflate(math.min(1.5, cell * .1));
      final inactive = tile['inactive'] == true;
      final active = tile['on'] == true || _integer(tile['pulseTicks']) > 0;
      final base = tile['faulty'] == true
          ? TerraColors.red
          : active
          ? TerraColors.amber
          : TerraColors.blue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()
          ..color = base.withValues(
            alpha: inactive
                ? .08
                : active
                ? .38
                : .17,
          ),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()
          ..color = base.withValues(alpha: inactive ? .3 : .8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      if (inactive) {
        canvas.drawLine(
          rect.topLeft,
          rect.bottomRight,
          Paint()..color = base.withValues(alpha: .45),
        );
      }
      if (tile['actuator'] == true || _list(tile['cellActuators']).isNotEmpty) {
        canvas.drawCircle(
          rect.bottomRight - const Offset(4, 4),
          2,
          Paint()..color = TerraColors.mint,
        );
      }
      if (cell >= 18 && rect.width >= 18) {
        final label =
            '${_map(definitions[tile['kind']])['name'] ?? tile['kind']}';
        final text = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(color: base, fontSize: math.min(11, cell * .4)),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: math.max(1, rect.width - 3));
        text.paint(canvas, Offset(rect.left + 2, rect.top + 2));
      }
    }
    final wires = <String, int>{};
    for (final wire in _list(world['wires']).whereType<List>()) {
      if (wire.length >= 3) wires['${wire[0]},${wire[1]}'] = _integer(wire[2]);
    }
    for (final wire in _list(world['wires']).whereType<List>()) {
      if (wire.length < 3) continue;
      final x = _integer(wire[0]),
          y = _integer(wire[1]),
          mask = _integer(wire[2]);
      if (!visible.inflate(1).contains(Offset(x.toDouble(), y.toDouble()))) {
        continue;
      }
      final center = screenRect(x, y, 1, 1).center;
      for (var channel = 0; channel < 4; channel++) {
        final bit = 1 << channel;
        if (mask & bit == 0) continue;
        final paint = Paint()
          ..color = channel < wireColors.length
              ? wireColors[channel]
              : TerraColors.muted
          ..strokeWidth = math.max(.65, math.min(2, cell / 12))
          ..strokeCap = StrokeCap.round;
        final shift = Offset(
          (channel - 1.5) * math.min(2, cell / 10),
          (channel - 1.5) * math.min(2, cell / 10),
        );
        var connected = false;
        for (final direction in const [
          Offset(1, 0),
          Offset(-1, 0),
          Offset(0, 1),
          Offset(0, -1),
        ]) {
          if ((wires['${x + direction.dx.toInt()},${y + direction.dy.toInt()}'] ??
                      0) &
                  bit !=
              0) {
            canvas.drawLine(
              center + shift,
              center + shift + direction * (cell / 2),
              paint,
            );
            connected = true;
          }
        }
        if (!connected) {
          canvas.drawCircle(
            center + shift,
            math.max(.8, math.min(2, cell / 12)),
            paint,
          );
        }
      }
    }
    if (selection.isNotEmpty) {
      final rect = screenRect(
        _integer(selection['x']),
        _integer(selection['y']),
        _integer(selection['width']),
        _integer(selection['height']),
      );
      canvas.drawRect(
        rect,
        Paint()..color = TerraColors.mint.withValues(alpha: .09),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = TerraColors.mint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (selected != null) {
      canvas.drawRect(
        screenRect(selected!.dx, selected!.dy, 1, 1),
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CircuitSchematic oldDelegate) => true;
}
