import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../engine/world_circuit_backend.dart';
import 'computer_display.dart';
import '../diagnostics/host_stage_timings.dart';

/// Schematic view of actual VM records, not a rendered game-world preview.
class WorldCircuitPanel extends StatefulWidget {
  final Map<String, Object?> state;
  final HostStageTimings? hostStages;
  final Future<void> Function(String, Map<String, Object?>) dispatch;
  const WorldCircuitPanel({
    super.key,
    required this.state,
    required this.dispatch,
    this.hostStages,
  });
  @override
  State<WorldCircuitPanel> createState() => _WorldCircuitPanelState();
}

class _WorldCircuitPanelState extends State<WorldCircuitPanel> {
  final _x = TextEditingController(text: '0');
  final _y = TextEditingController(text: '0');
  final _width = TextEditingController(text: '48');
  final _height = TextEditingController(text: '32');
  int _mask = 15;
  bool _performanceExpanded = false;
  Map<String, Object?>? _performanceSnapshot;
  List<Widget> _performanceDetails(Map<String, Object?> snapshot) {
    final stages = snapshot['stages'] as Map;
    return [
      const Text(
        '每行：调用总数 · 最近均值 / P95 / 最大值（毫秒）。各阶段相互包含，不能相加；不代表 Flutter 帧或实际呈现延迟。运行开始时清零。',
      ),
      Text('主机：${snapshot['host']}'),
      for (final entry in stages.entries)
        Text(
          '${entry.key}: n=${(entry.value as Map)['count']} · '
          '${((entry.value as Map)['recentMeanUs'] as num).toDouble() / 1000 < .01 ? '<0.01' : (((entry.value as Map)['recentMeanUs'] as num) / 1000).toStringAsFixed(2)} / '
          '${(((entry.value as Map)['recentP95Us'] as num) / 1000).toStringAsFixed(2)} / '
          '${(((entry.value as Map)['recentMaxUs'] as num) / 1000).toStringAsFixed(2)} ms',
        ),
    ];
  }

  int? _selectedX, _selectedY;
  String? _localError;
  Uint8List? _controlRecords;
  final List<_CircuitControl> _controls = [];
  int _controlCount = 0;

  void _readControls(Uint8List records) {
    if (identical(_controlRecords, records)) return;
    _controlRecords = records;
    _controls.clear();
    _controlCount = 0;
    final data = ByteData.sublistView(records);
    for (var offset = 0; offset + 16 <= records.length; offset += 16) {
      final word = data.getUint32(offset + 8, Endian.little);
      final type = word & 65535;
      final frameX = data.getInt16(offset + 12, Endian.little);
      if ((word & (1 << 16)) == 0 || !_isControl(type, frameX)) continue;
      _controlCount++;
      if (_controls.length == 256) continue;
      _controls.add(
        _CircuitControl(
          data.getUint32(offset, Endian.little),
          data.getUint32(offset + 4, Endian.little),
          type,
          data.getInt16(offset + 14, Endian.little),
        ),
      );
    }
  }

  // These are the input tile kinds accepted by the generic engine HitSwitch
  // path. Multi-tile records remain selectable; the engine normalizes them.
  bool _isControl(int type, int frameX) =>
      const {
        132,
        135,
        136,
        144,
        314,
        411,
        423,
        428,
        440,
        441,
        442,
        468,
        476,
      }.contains(type) ||
      (type == 467 && frameX ~/ 36 == 4);

  Future<void> _moveViewport(int dx, int dy) async {
    final viewport = widget.state['viewport'];
    if (viewport is! Map || viewport.isEmpty) return;
    final width = viewport['width'] as int, height = viewport['height'] as int;
    final worldWidth = widget.state['width'] as int;
    final worldHeight = widget.state['height'] as int;
    await _send('worldCircuitViewport', {
      'x': ((viewport['x'] as int) + dx * width).clamp(0, worldWidth - width),
      'y': ((viewport['y'] as int) + dy * height).clamp(
        0,
        worldHeight - height,
      ),
      'width': width,
      'height': height,
    });
  }

  bool get _busy => widget.state['busy'] == true;
  String _progressLabel(String stage) => switch (stage) {
    'hash' => '核验完整文件',
    'open' || 'decode' => '分段读取世界',
    'compile' => '编译真实接线',
    'command' || 'run' => '执行电路操作',
    'save' => '生成模拟副本',
    'ready' => '电路已就绪',
    _ => stage,
  };

  String _memorySize(Object? bytes) {
    if (bytes is! num ||
        !bytes.isFinite ||
        bytes < 0 ||
        bytes > 9007199254740991 ||
        bytes % 1 != 0) {
      return '不可得';
    }
    return '${(bytes / 1048576).toStringAsFixed(1)} MiB';
  }

  Future<void> _send(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    setState(() => _localError = null);
    try {
      await widget.dispatch(action, args);
    } catch (e) {
      if (mounted) setState(() => _localError = e.toString());
    }
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认操作'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _viewport({bool pixels = false}) async {
    final x = int.tryParse(_x.text),
        y = int.tryParse(_y.text),
        w = int.tryParse(_width.text),
        h = int.tryParse(_height.text);
    final worldW = widget.state['width'] as int? ?? 0,
        worldH = widget.state['height'] as int? ?? 0;
    if (x == null ||
        y == null ||
        w == null ||
        h == null ||
        x < 0 ||
        y < 0 ||
        w < 1 ||
        h < 1 ||
        w > 256 ||
        h > 256 ||
        x + w > worldW ||
        y + h > worldH) {
      setState(() => _localError = '请输入世界范围内的区域；宽高各不超过 256 格。');
      return;
    }
    await _send(pixels ? 'worldCircuitReadDisplay' : 'worldCircuitViewport', {
      'x': x,
      'y': y,
      'width': w,
      'height': h,
    });
  }

  void _syncViewport() {
    final viewport = widget.state['viewport'];
    if (viewport is! Map || viewport.isEmpty) return;
    _x.text = '${viewport['x']}';
    _y.text = '${viewport['y']}';
    _width.text = '${viewport['width']}';
    _height.text = '${viewport['height']}';
    _selectedX = null;
    _selectedY = null;
  }

  @override
  void initState() {
    super.initState();
    _syncViewport();
  }

  @override
  void didUpdateWidget(covariant WorldCircuitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.state['viewport'] as Map?;
    final next = widget.state['viewport'] as Map?;
    if (const [
      'x',
      'y',
      'width',
      'height',
    ].any((key) => previous?[key] != next?[key])) {
      _syncViewport();
    }
  }

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state,
        open = s['open'] == true,
        dirty = s['dirty'] == true,
        running = s['running'] == true;
    final loading = s['importing'] == true;
    final loadFailed =
        s['loadError'] is String && (s['loadError'] as String).isNotEmpty;
    final progressValue = loading || loadFailed
        ? s['loadProgress']
        : s['progress'];
    final progress = progressValue is WorldCircuitProgress
        ? progressValue
        : null;
    final error = _localError ?? s['error']?.toString();
    final raw = s['records'];
    final records = raw is Uint8List ? raw : Uint8List(0);
    _readControls(records);
    String? selectedDescription;
    var selectedControl = false;
    if (_selectedX != null && _selectedY != null) {
      final data = ByteData.sublistView(records);
      for (var i = 0; i + 16 <= records.length; i += 16) {
        if (data.getUint32(i, Endian.little) == _selectedX &&
            data.getUint32(i + 4, Endian.little) == _selectedY) {
          final word = data.getUint32(i + 8, Endian.little);
          selectedControl =
              (word & (1 << 16)) != 0 &&
              _isControl(word & 65535, data.getInt16(i + 12, Endian.little));
          selectedDescription =
              '选中 ($_selectedX, $_selectedY)：类型 ${word & 65535} · 帧 (${data.getInt16(i + 12, Endian.little)}, ${data.getInt16(i + 14, Endian.little)}) · 线色掩码 ${word >> 24} · 标志 ${(word >> 16) & 255}';
          break;
        }
      }
    }
    final viewport = s['viewport'] is Map
        ? Map<String, dynamic>.from(s['viewport'] as Map)
        : <String, dynamic>{};
    final vx = (viewport['x'] as num?)?.toInt() ?? 0,
        vy = (viewport['y'] as num?)?.toInt() ?? 0;
    final vw = (viewport['width'] as num?)?.toInt() ?? 0,
        vh = (viewport['height'] as num?)?.toInt() ?? 0;
    final displayRegion = s['displayRegion'] as Map?;
    final displayFrame = s['displayFrame'];
    final displayWidth = (displayRegion?['width'] as num?)?.toInt() ?? 0;
    final displayHeight = (displayRegion?['height'] as num?)?.toInt() ?? 0;
    final displayPixelCount = (s['displayPixelCount'] as num?)?.toInt() ?? 0;
    Widget coordinate(String label, TextEditingController controller) =>
        SizedBox(
          width: 90,
          child: TextField(
            controller: controller,
            enabled: open && !_busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: label),
            onSubmitted: (_) => _viewport(),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '完整世界电路',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '导入 WLD 后解析实际接线与设备。选择区域操作开关、压力板或定时器；运行与单步推进世界电路 tick。导入的定时器默认关闭，需要手动启动；不恢复原世界计时相位。',
        ),
        if (!open && s['streamingAvailable'] == true) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _send('worldCircuitChooseWorld'),
                icon: const Icon(Icons.folder_open),
                label: const Text('选择完整 WLD'),
              ),
              FilledButton(
                onPressed: _busy || s['sourceName'] == null
                    ? null
                    : () => _send('worldCircuitImport'),
                child: const Text('导入完整电路'),
              ),
            ],
          ),
          if (s['sourceName'] != null)
            Text(
              '${s['sourceName']} · ${((s['sourceBytes'] as num? ?? 0) / 1048576).toStringAsFixed(1)} MiB',
            ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!open)
              FilledButton.icon(
                onPressed: _busy ? null : () => _send('worldCircuitOpen'),
                icon: const Icon(Icons.electrical_services),
                label: const Text('加载当前世界'),
              ),
            if (open) ...[
              FilledButton.icon(
                onPressed: running
                    ? () => _send('worldCircuitPause')
                    : _busy
                    ? null
                    : () => _send('worldCircuitToggle'),
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(running ? '暂停' : '运行'),
              ),
              OutlinedButton(
                onPressed: _busy || running
                    ? null
                    : () => _send('worldCircuitStep'),
                child: const Text('单步 1 tick'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (!dirty || await _confirm('丢弃当前模拟状态并从原始世界重新加载？')) {
                          await _send('worldCircuitReset');
                        }
                      },
                child: const Text('重置'),
              ),
              FilledButton.tonal(
                onPressed: _busy || !dirty
                    ? null
                    : () async {
                        if (await _confirm('将当前模拟结果保存为待验证的世界副本？')) {
                          await _send('worldCircuitSave');
                        }
                      },
                child: const Text('保存模拟结果'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (!dirty || await _confirm('当前模拟尚未保存，仍要关闭并丢弃？')) {
                          await _send('worldCircuitClose', {'discard': dirty});
                        }
                      },
                child: const Text('关闭'),
              ),
            ],
          ],
        ),
        if (_busy && !running) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(
              value: progress != null && progress.total > 0
                  ? (progress.completed / progress.total).clamp(0, 1)
                  : null,
            ),
          ),
          if (progress != null)
            Text(
              '${_progressLabel(progress.stage)} · ${progress.completed}${progress.total > 0 ? ' / ${progress.total}' : ''}',
            ),
          if (s['importing'] == true)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: s['cancelling'] == true
                    ? null
                    : () => _send('worldCircuitCancel'),
                child: Text(s['cancelling'] == true ? '正在取消…' : '取消当前加载'),
              ),
            ),
        ],
        if (loadFailed && !_busy)
          Text(
            progress == null
                ? '加载失败，未取得有效加载进度。'
                : '加载失败前的最后有效进度：${_progressLabel(progress.stage)} · ${progress.completed}${progress.total > 0 ? ' / ${progress.total}' : ''}',
          ),
        if (loading || loadFailed) ...[
          Text(
            '引擎分配 ${_memorySize(progress?.diagnostics['nativeActiveBytes'])} · '
            '峰值 ${_memorySize(progress?.diagnostics['nativePeakBytes'])} · '
            'WASM 容量 ${_memorySize(progress?.diagnostics['wasmHeapBytes'])}',
          ),
          const Text('引擎分配/峰值、WASM 容量，非进程内存；容量不等于实际占用。'),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (open) ...[
          SwitchListTile(
            title: const Text('电路优化'),
            subtitle: const Text('默认关闭。开启后使用设备去重和 WireHead 式像素规则；后续运行结果可能不同。'),
            value: s['optimizationEnabled'] == true,
            onChanged:
                (_busy && !running) ||
                    (s['optimizationSupported'] != true &&
                        s['optimizationEnabled'] != true)
                ? null
                : (enabled) =>
                      _send('worldCircuitOptimization', {'enabled': enabled}),
            contentPadding: EdgeInsets.zero,
          ),
          const Text(
            '关闭时采用原版像素规则。切换会暂停运行，保留当前电路状态和显示帧；历史显示不会重算，继续运行才按所选规则处理信号。',
          ),
          if (s['optimizationSupported'] != true)
            const Text('此世界的像素接线拓扑暂不支持开启；同色跨轴网络尚未支持，请保持关闭。'),
        ],
        if (open) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _send('worldCircuitFragments', {'offset': 0}),
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('读取电路片段'),
              ),
              if (s['fragments'] is Map &&
                  ((s['fragments'] as Map)['offset'] as int? ?? 0) > 0)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _send('worldCircuitFragments', {
                          'offset': math.max(
                            0,
                            ((s['fragments'] as Map)['offset'] as int) - 256,
                          ),
                        }),
                  child: const Text('上一页'),
                ),
              if (s['fragments'] is Map &&
                  (s['fragments'] as Map)['hasMore'] == true)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _send('worldCircuitFragments', {
                          'offset':
                              ((s['fragments'] as Map)['offset'] as int) + 256,
                        }),
                  child: const Text('下一页'),
                ),
            ],
          ),
          if (s['fragments'] is Map) ...[
            Text(
              '共 ${(s['fragments'] as Map)['total']} 个片段；点选定位，提取后可在融合画布查看与粘贴。',
            ),
            SizedBox(
              height: 240,
              child: ListView.builder(
                itemCount: ((s['fragments'] as Map)['items'] as List).length,
                itemBuilder: (context, index) {
                  final row =
                      ((s['fragments'] as Map)['items'] as List)[index] as Map;
                  return ListTile(
                    onTap: _busy
                        ? null
                        : () => _send('worldCircuitLocateFragment', {
                            'id': row['id'],
                          }),
                    title: Text(
                      '片段 ${row['id']} · ${row['width']} × ${row['height']}',
                    ),
                    subtitle: Text(
                      '坐标 ${row['x']}, ${row['y']} · ${row['cells']} 格${row['canStamp'] == true ? '' : ' · 占格/支撑待核验'}',
                    ),
                    trailing: TextButton(
                      onPressed:
                          _busy ||
                              row['complete'] != true ||
                              row['modded'] == true
                          ? null
                          : () =>
                                _send('worldCircuitExtract', {'id': row['id']}),
                      child: const Text('提取查看'),
                    ),
                  );
                },
              ),
            ),
          ],
          if (widget.hostStages != null)
            ExpansionTile(
              key: const PageStorageKey('world-circuit-performance'),
              title: const Text('性能明细 / Performance'),
              subtitle: const Text('主机耗时，非 FPS；暂停后展开读取最近 128 次'),
              onExpansionChanged: (expanded) => setState(() {
                _performanceExpanded = expanded;
                _performanceSnapshot = expanded
                    ? widget.hostStages!.snapshot()
                    : null;
              }),
              children: [
                if (_performanceExpanded && running)
                  const Text('请暂停后重新展开，以免额外布局影响运行测量。'),
                if (_performanceExpanded &&
                    !running &&
                    _performanceSnapshot != null)
                  ..._performanceDetails(_performanceSnapshot!),
              ],
            ),
          Text(
            '${s['width'] ?? 0} × ${s['height'] ?? 0} 格 · ${s['devices'] ?? 0} 个设备 · ${s['networks'] ?? 0} 个网络 · ${s['ticks'] ?? 0} ticks · ${s['netPulses'] ?? 0} 次线路脉冲${dirty ? ' · 有未保存状态' : ''}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              coordinate('X', _x),
              coordinate('Y', _y),
              coordinate('宽度', _width),
              coordinate('高度', _height),
              OutlinedButton(
                onPressed: _busy ? null : _viewport,
                child: const Text('查看接线'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : () => _viewport(pixels: true),
                child: const Text('读取区域像素'),
              ),
            ],
          ),
          if (vw > 0 && vh > 0) ...[
            Text('当前接线视口：($vx, $vy) · $vw × $vh 格；可移动查看世界的其他区域。'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy || vx == 0
                      ? null
                      : () => _moveViewport(-1, 0),
                  child: const Text('左移视口'),
                ),
                OutlinedButton(
                  onPressed: _busy || vx + vw >= (s['width'] as int? ?? 0)
                      ? null
                      : () => _moveViewport(1, 0),
                  child: const Text('右移视口'),
                ),
                OutlinedButton(
                  onPressed: _busy || vy == 0
                      ? null
                      : () => _moveViewport(0, -1),
                  child: const Text('上移视口'),
                ),
                OutlinedButton(
                  onPressed: _busy || vy + vh >= (s['height'] as int? ?? 0)
                      ? null
                      : () => _moveViewport(0, 1),
                  child: const Text('下移视口'),
                ),
              ],
            ),
          ],
          Wrap(
            spacing: 8,
            children: [
              for (final entry in const {
                1: '红线',
                2: '蓝线',
                4: '绿线',
                8: '黄线',
              }.entries)
                FilterChip(
                  label: Text(entry.value),
                  selected: (_mask & entry.key) != 0,
                  onSelected: _busy
                      ? null
                      : (on) => setState(
                          () => _mask = on
                              ? _mask | entry.key
                              : _mask & ~entry.key,
                        ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (records.isNotEmpty && vw > 0 && vh > 0)
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : 600.0;
                final scale = math.min(width / vw, 360 / vh);
                final size = Size(vw * scale, vh * scale);
                return Align(
                  alignment: Alignment.topLeft,
                  child: Semantics(
                    label: '实际世界电路视口，点击选择设备或线路',
                    child: GestureDetector(
                      onTapUp: _busy
                          ? null
                          : (details) {
                              final x =
                                      vx +
                                      (details.localPosition.dx / scale)
                                          .floor(),
                                  y =
                                      vy +
                                      (details.localPosition.dy / scale)
                                          .floor();
                              if (x >= vx &&
                                  x < vx + vw &&
                                  y >= vy &&
                                  y < vy + vh) {
                                setState(() {
                                  _selectedX = x;
                                  _selectedY = y;
                                });
                              }
                            },
                      child: CustomPaint(
                        size: size,
                        painter: _CircuitPainter(
                          records,
                          vx,
                          vy,
                          vw,
                          vh,
                          selectedX: _selectedX,
                          selectedY: _selectedY,
                          selectionColor: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            )
          else
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('选择区域以读取真实电路记录。'),
            ),
          const SizedBox(height: 8),
          Text('当前视口发现 $_controlCount 个可操作输入格；点选后操作。'),
          if (_controls.isNotEmpty)
            SizedBox(
              height: math.min(192, _controls.length * 64).toDouble(),
              child: ListView.builder(
                itemCount: _controls.length,
                itemBuilder: (context, index) {
                  final control = _controls[index];
                  return ListTile(
                    dense: true,
                    selected:
                        control.x == _selectedX && control.y == _selectedY,
                    title: Text(control.label),
                    subtitle: Text(
                      '坐标 ${control.x}, ${control.y} · 类型 ${control.type}',
                    ),
                    onTap: _busy
                        ? null
                        : () => setState(() {
                            _selectedX = control.x;
                            _selectedY = control.y;
                          }),
                  );
                },
              ),
            ),
          if (_controlCount > _controls.length)
            const Text('列表显示前 256 个输入格；缩小接线视口可查看其他装置。'),
          if (_controlCount == 0)
            const Text('当前视口没有可操作输入，可移动视口或定位其他片段；点击线路仍可发送脉冲。'),
          if (selectedDescription != null) Text(selectedDescription),
          if (_selectedX != null && _selectedY != null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy || _mask == 0 || !selectedControl
                      ? null
                      : () => _send('worldCircuitTrigger', {
                          'x': _selectedX,
                          'y': _selectedY,
                          'mask': _mask,
                        }),
                  child: const Text('操作所选设备'),
                ),
                OutlinedButton(
                  onPressed: _busy || _mask == 0
                      ? null
                      : () => _send('worldCircuitTrigger', {
                          'x': _selectedX,
                          'y': _selectedY,
                          'mask': _mask,
                          'direct': true,
                        }),
                  child: const Text('发送线路脉冲'),
                ),
              ],
            ),
          const Text('深色格为空白；方块编号显示于较大格子。红／蓝／绿／黄线为实际接线，白框表示制动器。'),
          if (displayRegion != null &&
              displayWidth > 0 &&
              displayHeight > 0 &&
              displayFrame is Uint8List) ...[
            const SizedBox(height: 12),
            Text(
              '像素区域：${displayRegion['x']}, ${displayRegion['y']} · '
              '$displayWidth × $displayHeight 格',
            ),
            if (displayPixelCount == 0)
              const Text('选区无原版像素装置。')
            else ...[
              Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(
                      800,
                      MediaQuery.sizeOf(context).height *
                          .65 *
                          displayWidth /
                          displayHeight,
                    ),
                  ),
                  child: ComputerDisplay(
                    key: s['displayIdentity'] == null
                        ? null
                        : ObjectKey(s['displayIdentity']),
                    rgba: displayFrame,
                    width: displayWidth,
                    height: displayHeight,
                    label: '所选区域实际像素盒状态',
                    hostStages: widget.hostStages,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                  ),
                ),
              ),
              Text('实际像素盒 $displayPixelCount 个；主题底色为空位，黑色为关闭，白色为点亮。'),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _send('worldCircuitRefreshDisplay'),
                child: const Text('刷新像素区域'),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _CircuitControl {
  final int x, y, type, frameY;
  const _CircuitControl(this.x, this.y, this.type, this.frameY);
  String get label => switch (type) {
    132 => '控制杆',
    135 => '压力板',
    136 => '开关',
    144 => '定时器（${frameY == 0 ? '关闭' : '已启动'}）',
    _ => '可操作输入',
  };
}

class _CircuitPainter extends CustomPainter {
  final Uint8List bytes;
  final int x, y, width, height;
  final int? selectedX, selectedY;
  final Color selectionColor;
  _CircuitPainter(
    this.bytes,
    this.x,
    this.y,
    this.width,
    this.height, {
    this.selectedX,
    this.selectedY,
    required this.selectionColor,
  });
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff121d28),
    );
    final data = ByteData.sublistView(bytes),
        sx = size.width / width,
        sy = size.height / height;
    for (var offset = 0; offset + 16 <= bytes.length; offset += 16) {
      final cx = data.getUint32(offset, Endian.little) - x,
          cy = data.getUint32(offset + 4, Endian.little) - y;
      if (cx < 0 || cy < 0 || cx >= width || cy >= height) continue;
      final word = data.getUint32(offset + 8, Endian.little),
          type = word & 65535,
          flags = (word >> 16) & 255,
          wires = word >> 24;
      final rect = Rect.fromLTWH(cx * sx, cy * sy, sx, sy);
      if ((flags & 1) != 0) {
        canvas.drawRect(
          rect.deflate(.5),
          Paint()
            ..color = (flags & 4) != 0
                ? const Color(0xff34404c)
                : Color.lerp(
                    const Color(0xff607588),
                    const Color(0xff9ca57d),
                    (type % 13) / 13,
                  )!,
        );
      }
      const colours = [
        Colors.redAccent,
        Colors.blueAccent,
        Colors.greenAccent,
        Colors.yellowAccent,
      ];
      for (var channel = 0; channel < 4; channel++) {
        if ((wires & (1 << channel)) == 0) continue;
        final d = (channel - 1.5) * math.min(sx, sy) / 7;
        final p = Paint()
          ..color = colours[channel]
          ..strokeWidth = math.max(1, math.min(sx, sy) / 12);
        canvas.drawLine(
          Offset(rect.left, rect.center.dy + d),
          Offset(rect.right, rect.center.dy + d),
          p,
        );
        canvas.drawLine(
          Offset(rect.center.dx + d, rect.top),
          Offset(rect.center.dx + d, rect.bottom),
          p,
        );
      }
      if ((flags & 2) != 0) {
        canvas.drawRect(
          rect.deflate(1),
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
      if (sx >= 28 && sy >= 20 && (flags & 1) != 0) {
        final text = TextPainter(
          text: TextSpan(
            text: sy >= 32
                ? '$type\n${data.getInt16(offset + 12, Endian.little)},${data.getInt16(offset + 14, Endian.little)}'
                : '$type',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              backgroundColor: Colors.black54,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(canvas, rect.topLeft + const Offset(2, 2));
      }
    }
    if (selectedX != null &&
        selectedY != null &&
        selectedX! >= x &&
        selectedX! < x + width &&
        selectedY! >= y &&
        selectedY! < y + height) {
      canvas.drawRect(
        Rect.fromLTWH(
          (selectedX! - x) * sx,
          (selectedY! - y) * sy,
          sx,
          sy,
        ).deflate(math.min(1, math.min(sx, sy) / 4)),
        Paint()
          ..color = selectionColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.min(2, math.min(sx, sy) / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CircuitPainter old) =>
      old.bytes != bytes ||
      old.x != x ||
      old.y != y ||
      old.width != width ||
      old.height != height ||
      old.selectedX != selectedX ||
      old.selectedY != selectedY ||
      old.selectionColor != selectionColor;
}
