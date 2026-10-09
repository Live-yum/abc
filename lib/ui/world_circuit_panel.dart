import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

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
  int _mask = 15;
  int? _selectedX, _selectedY;
  String? _localError;
  bool get _busy => widget.state['busy'] == true;
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
        const Text('使用真实接线与设备时钟。下方为电路示意图，显示引擎返回的方块和线色。点击格子触发开关；保存会生成待验证的世界副本。'),
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
                onPressed: _busy ? null : () => _send('worldCircuitToggle'),
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(running ? '暂停' : '运行'),
              ),
              OutlinedButton(
                onPressed: _busy || running
                    ? null
                    : () => _send('worldCircuitStep'),
                child: const Text('单步'),
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
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
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
