import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/computerraria_computer.dart';
import '../engine/world_circuit_backend.dart';
import 'computer_display.dart';

/// Schematic view of actual VM records, not a rendered game-world preview.
class WorldCircuitPanel extends StatefulWidget {
  final Map<String, Object?> state;
  final Future<void> Function(String, Map<String, Object?>) dispatch;
  const WorldCircuitPanel({
    super.key,
    required this.state,
    required this.dispatch,
  });
  @override
  State<WorldCircuitPanel> createState() => _WorldCircuitPanelState();
}

class _WorldCircuitPanelState extends State<WorldCircuitPanel> {
  final _x = TextEditingController(text: '0');
  final _y = TextEditingController(text: '0');
  final _width = TextEditingController(text: '48');
  final _height = TextEditingController(text: '32');
  final _computerFocus = FocusNode(debugLabel: 'physical computer input');
  int _mask = 15;
  bool _colorDisplay = false;
  int? _selectedX, _selectedY;
  String? _localError;
  bool get _busy => widget.state['busy'] == true;
  bool get _inputEnabled =>
      widget.state['keyboardVerified'] == true &&
      widget.state['canRunComputer'] == true;

  void _input(String direction, bool pressed) {
    unawaited(
      widget.dispatch('worldCircuitInput', {
        'direction': direction,
        'pressed': pressed,
      }),
    );
  }

  void _releaseInput() {
    unawaited(
      Future<void>.microtask(
        () => widget.dispatch('worldCircuitReleaseKeys', const {}),
      ),
    );
  }

  KeyEventResult _computerKey(FocusNode node, KeyEvent event) {
    if (!_inputEnabled) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final direction =
        key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.keyW
        ? 'up'
        : key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.keyS
        ? 'down'
        : key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA
        ? 'left'
        : key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyD
        ? 'right'
        : null;
    if (direction == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _input(direction, true);
    if (event is KeyUpEvent) _input(direction, false);
    return KeyEventResult.handled;
  }

  Widget _directionButton(String direction, String label, IconData icon) {
    final held = (widget.state['heldKeys'] as Iterable? ?? const []).contains(
      direction,
    );
    return Semantics(
      label: '计算机$label',
      button: true,
      enabled: _inputEnabled,
      onTap: !_inputEnabled
          ? null
          : () {
              _computerFocus.requestFocus();
              _input(direction, true);
              _input(direction, false);
            },
      child: GestureDetector(
        excludeFromSemantics: true,
        onTapDown: !_inputEnabled
            ? null
            : (_) {
                _computerFocus.requestFocus();
                _input(direction, true);
              },
        onTapUp: !_inputEnabled ? null : (_) => _input(direction, false),
        onTapCancel: !_inputEnabled ? null : () => _input(direction, false),
        child: Container(
          width: 56,
          height: 48,
          decoration: BoxDecoration(
            color: held
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surface,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: _inputEnabled ? null : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }

  String _progressLabel(String stage) => switch (stage) {
    'hash' => '核验完整文件',
    'open' || 'decode' => '分段读取世界',
    'compile' => '编译真实接线',
    'command' || 'run' => '执行电路操作',
    'save' => '生成模拟副本',
    'ready' => '电路已就绪',
    _ => stage,
  };
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
  Future<void> _viewport() async {
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
        w > 128 ||
        h > 96 ||
        x + w > worldW ||
        y + h > worldH) {
      setState(() => _localError = '请输入世界范围内的视口；最大 128 × 96 格。');
      return;
    }
    await _send('worldCircuitViewport', {
      'x': x,
      'y': y,
      'width': w,
      'height': h,
    });
  }

  @override
  void didUpdateWidget(covariant WorldCircuitPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state['open'] != true && widget.state['open'] == true) {
      _width.text = math
          .min(48, widget.state['width'] as int? ?? 48)
          .toString();
      _height.text = math
          .min(32, widget.state['height'] as int? ?? 32)
          .toString();
    }
  }

  @override
  void dispose() {
    _releaseInput();
    _computerFocus.dispose();
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
    final computer = s['computerVerified'] == true;
    final canRunComputer = s['canRunComputer'] == true;
    final progress = s['progress'] is WorldCircuitProgress
        ? s['progress'] as WorldCircuitProgress
        : null;
    final error = _localError ?? s['error']?.toString();
    final raw = s['records'];
    final records = raw is Uint8List ? raw : Uint8List(0);
    String? selectedDescription;
    if (_selectedX != null && _selectedY != null) {
      final data = ByteData.sublistView(records);
      for (var i = 0; i + 16 <= records.length; i += 16) {
        if (data.getUint32(i, Endian.little) == _selectedX &&
            data.getUint32(i + 4, Endian.little) == _selectedY) {
          final word = data.getUint32(i + 8, Endian.little);
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
          '导入完整 WLD 后运行真实接线。Computerraria 需配套 TWLD 恢复显示器规则，并加载 RV32I 程序；无需安装 tModLoader 或 WireHead。',
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
              OutlinedButton(
                onPressed: _busy || s['sourceName'] == null
                    ? null
                    : () => _send('worldCircuitChooseTwld'),
                child: const Text('选择配套 TWLD'),
              ),
              if (s['companionName'] != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _send('worldCircuitClearTwld'),
                  child: const Text('移除配套文件'),
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
          Text(
            s['companionName'] == null
                ? '未选择 TWLD：使用原版电路规则。'
                : '配套文件：${s['companionName']}（导入后核验）',
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
                    : _busy || (computer && !canRunComputer)
                    ? null
                    : () => _send('worldCircuitToggle'),
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(
                  running
                      ? '暂停'
                      : computer
                      ? '运行物理时钟'
                      : '运行',
                ),
              ),
              OutlinedButton(
                onPressed: _busy || running || (computer && !canRunComputer)
                    ? null
                    : () => _send('worldCircuitStep'),
                child: Text(computer ? '单个时钟脉冲' : '单步'),
              ),
              if (computer)
                OutlinedButton(
                  onPressed: _busy || running || !canRunComputer
                      ? null
                      : () => _send('worldCircuitStep', {'pulses': 128}),
                  child: const Text('128 个脉冲'),
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
          if (s['importing'] == true || s['programIncomplete'] == true)
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
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (s['provenanceWarning'] != null)
          Text(s['provenanceWarning'] as String),
        if (open) ...[
          SwitchListTile(
            title: const Text('电路优化'),
            subtitle: const Text('减少无关设备的逐次清理。切换会暂停运行并保留当前状态。'),
            value: s['optimizationEnabled'] == true,
            onChanged: _busy && !running
                ? null
                : (enabled) =>
                      _send('worldCircuitOptimization', {'enabled': enabled}),
            contentPadding: EdgeInsets.zero,
          ),
          const Text('两种模式共用分组缓存和惰性状态；此开关控制设备信号去重加速，与 TWLD 显示器兼容配置分开。'),
        ],
        if (open && computer) ...[
          const SizedBox(height: 12),
          const Text('已核验：完整 Computerraria 内容、实际存储器坐标及 TWLD 显示器。'),
          if (s['restoredFromExport'] == true)
            const Text('已匹配本机导出的完整配对文件；保留保存时的实际 CPU、ROM 和显示器状态。'),
          Text(
            s['programName'] == null
                ? '原始 ROM 为空。选择从地址 0 启动的 RV32I .bin 或十六进制 .txt。'
                : 'ROM 程序：${s['programName']}',
          ),
          if (s['programIncomplete'] == true)
            const Text('程序加载未完成；请重置原始世界后重新加载程序。'),
          if (s['programBaselineKnown'] == false)
            const Text('底层电路操作改变了未跟踪的状态，请重置后再替换程序或保存可续跑文件。'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed:
                    _busy ||
                        running ||
                        s['programIncomplete'] == true ||
                        s['programBaselineKnown'] == false
                    ? null
                    : () => _send('worldCircuitLoadPong'),
                icon: const Icon(Icons.sports_esports),
                label: const Text('载入 Pong 程序'),
              ),
              FilledButton.tonalIcon(
                onPressed:
                    _busy ||
                        running ||
                        s['programIncomplete'] == true ||
                        s['programBaselineKnown'] == false
                    ? null
                    : () => _send('worldCircuitLoadProgram'),
                icon: const Icon(Icons.memory),
                label: const Text('加载 RV32I 程序'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _send('worldCircuitRefreshDisplay'),
                child: const Text('读取显示器'),
              ),
              ChoiceChip(
                label: const Text('黑白 64 × 48'),
                selected: !_colorDisplay,
                onSelected: (_) => setState(() => _colorDisplay = false),
              ),
              ChoiceChip(
                label: const Text('彩色 176 × 96'),
                selected: _colorDisplay,
                onSelected: (_) => setState(() => _colorDisplay = true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final region = _colorDisplay
                  ? ComputerrariaComputer.color
                  : ComputerrariaComputer.mono;
              final frames = s['displayFrames'] as Map? ?? const {};
              final rgba = frames[region.name];
              return Focus(
                focusNode: _computerFocus,
                onKeyEvent: _computerKey,
                onFocusChange: (focused) {
                  if (!focused) _releaseInput();
                },
                child: GestureDetector(
                  onTap: _computerFocus.requestFocus,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(
                          800,
                          MediaQuery.sizeOf(context).height *
                              .65 *
                              region.width /
                              region.height,
                        ),
                      ),
                      child: ComputerDisplay(
                        rgba: rgba is Uint8List ? rgba : Uint8List(0),
                        width: region.width,
                        height: region.height,
                        label: '${region.name}，显示实际物理像素状态',
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          Text(
            '已执行 ${s['physicalPulses'] ?? 0} 个物理时钟脉冲 · 当前模式实测 ${((s['clockHz'] as num?) ?? 0).toStringAsFixed(1)} Hz · 显示读取 ${((s['displayHz'] as num?) ?? 0).toStringAsFixed(1)} 次/秒',
          ),
          const Text('时钟脉冲不等于 CPU 指令。运行速度取决于设备；彩色视图用实际帧状态对应的平面平均色。'),
          if (s['keyboardVerified'] == true) ...[
            const Text('点显示器后使用方向键或 WASD；屏幕方向键也可长按。失去焦点或暂停会释放输入。'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _directionButton('left', '向左', Icons.arrow_back),
                _directionButton('up', '向上', Icons.arrow_upward),
                _directionButton('down', '向下', Icons.arrow_downward),
                _directionButton('right', '向右', Icons.arrow_forward),
              ],
            ),
          ] else
            const Text('键盘映射待实际传感器校准，当前未启用方向键。'),
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
            Text('共 ${(s['fragments'] as Map)['total']} 个片段；提取后在融合画布查看与粘贴。'),
            SizedBox(
              height: 240,
              child: ListView.builder(
                itemCount: ((s['fragments'] as Map)['items'] as List).length,
                itemBuilder: (context, index) {
                  final row =
                      ((s['fragments'] as Map)['items'] as List)[index] as Map;
                  return ListTile(
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
          Text(
            '${s['width'] ?? 0} × ${s['height'] ?? 0} 格 · ${s['devices'] ?? 0} 个设备 · ${s['networks'] ?? 0} 个网络 · ${s['ticks'] ?? 0} ticks${dirty ? ' · 有未保存状态' : ''}',
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
                child: const Text('查看区域'),
              ),
            ],
          ),
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
                    label: '实际世界电路视口，点击格子触发开关',
                    child: GestureDetector(
                      onTapUp: _busy || _mask == 0
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
                                _send('worldCircuitTrigger', {
                                  'x': x,
                                  'y': y,
                                  'mask': _mask,
                                });
                              }
                            },
                      child: CustomPaint(
                        size: size,
                        painter: _CircuitPainter(records, vx, vy, vw, vh),
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
          if (selectedDescription != null) Text(selectedDescription),
          const Text('深色格为空白；方块编号显示于较大格子。红／蓝／绿／黄线为实际接线，白框表示制动器。'),
        ],
      ],
    );
  }
}

class _CircuitPainter extends CustomPainter {
  final Uint8List bytes;
  final int x, y, width, height;
  _CircuitPainter(this.bytes, this.x, this.y, this.width, this.height);
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
  }

  @override
  bool shouldRepaint(covariant _CircuitPainter old) =>
      old.bytes != bytes ||
      old.x != x ||
      old.y != y ||
      old.width != width ||
      old.height != height;
}
