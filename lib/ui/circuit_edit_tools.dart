import 'package:flutter/material.dart';

/// Coordinate forms keep selection, clipboard and confirmed edit plans usable
/// on mouse, touch and keyboard without relying on a particular canvas gesture.
class CircuitEditTools extends StatefulWidget {
  final Map<String, Object?> state;
  final Future<void> Function(String, Map<String, Object?>) onAction;
  final bool disabled;
  const CircuitEditTools({
    super.key,
    required this.state,
    required this.onAction,
    this.disabled = false,
  });
  @override
  State<CircuitEditTools> createState() => _CircuitEditToolsState();
}

class _CircuitEditToolsState extends State<CircuitEditTools> {
  final _x = TextEditingController(text: '0');
  final _y = TextEditingController(text: '0');
  final _width = TextEditingController(text: '1');
  final _height = TextEditingController(text: '1');
  final _endX = TextEditingController(text: '5');
  final _endY = TextEditingController(text: '0');
  int _mask = 1;
  bool _sending = false;
  String? _error;
  bool get _busy => _sending || widget.state['busy'] == true;
  bool get _enabled => !widget.disabled && !_busy;

  @override
  void dispose() {
    for (final controller in [_x, _y, _width, _height, _endX, _endY]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _send(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      await widget.onAction(action, args);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _coordinates(String action) {
    final x = int.tryParse(_x.text), y = int.tryParse(_y.text);
    final width = int.tryParse(_width.text),
        height = int.tryParse(_height.text);
    final endX = int.tryParse(_endX.text), endY = int.tryParse(_endY.text);
    if (x == null ||
        y == null ||
        action == 'circuitSelect' && (width == null || height == null) ||
        action == 'circuitRoutePreview' && (endX == null || endY == null)) {
      setState(() => _error = '请输入整数坐标和选区尺寸。');
      return;
    }
    _send(action, switch (action) {
      'circuitSelect' => {'x': x, 'y': y, 'width': width, 'height': height},
      'circuitNetworkPreview' => {'x': x, 'y': y, 'mask': _mask},
      'circuitRoutePreview' => {
        'startX': x,
        'startY': y,
        'endX': endX,
        'endY': endY,
        'mask': _mask,
      },
      _ => {'x': x, 'y': y},
    });
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.state['selection'] as Map?;
    final clipboard = widget.state['clipboard'] as Map?;
    final preview = widget.state['preview'] as Map?;
    final stale = preview?['stale'] == true;
    final deleting = preview?['kind'] == 'removeNetwork';
    Widget field(String label, String id, TextEditingController controller) =>
        SizedBox(
          width: 96,
          child: TextField(
            key: ValueKey('circuit-edit-$id'),
            controller: controller,
            enabled: _enabled,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: InputDecoration(labelText: label, isDense: true),
          ),
        );
    Widget action(
      String label,
      String id,
      VoidCallback callback, {
      bool ready = true,
    }) => OutlinedButton(
      key: ValueKey('circuit-edit-$id'),
      onPressed: _enabled && ready ? callback : null,
      child: Text(label),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '选区、剪贴板与安全布线',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('坐标从 0 开始。起点也用作选区左上角、粘贴位置和网络删除种子。'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            field('起点 X', 'x', _x),
            field('起点 Y', 'y', _y),
            field('选区宽', 'width', _width),
            field('选区高', 'height', _height),
            field('终点 X', 'end-x', _endX),
            field('终点 Y', 'end-y', _endY),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            action('设置选区', 'select', () => _coordinates('circuitSelect')),
            action(
              '复制选区',
              'copy',
              () => _send('circuitCopy'),
              ready: selection != null,
            ),
            action(
              '剪切选区',
              'cut',
              () => _send('circuitCut'),
              ready: selection != null,
            ),
            action(
              '粘贴到起点',
              'paste',
              () => _coordinates('circuitPaste'),
              ready: clipboard != null,
            ),
            action(
              '旋转剪贴板 90°',
              'rotate',
              () => _send('circuitRotate'),
              ready: clipboard != null,
            ),
            action(
              '水平镜像剪贴板',
              'mirror-h',
              () => _send('circuitMirror', {'axis': 'horizontal'}),
              ready: clipboard != null,
            ),
            action(
              '垂直镜像剪贴板',
              'mirror-v',
              () => _send('circuitMirror', {'axis': 'vertical'}),
              ready: clipboard != null,
            ),
          ],
        ),
        if (selection != null)
          Text(
            '选区：(${selection['x']}, ${selection['y']}) · ${selection['width']} × ${selection['height']}',
          ),
        if (clipboard != null)
          Text(
            '剪贴板：${clipboard['width']} × ${clipboard['height']} · ${clipboard['count']} 个非空格。粘贴替换整个矩形，保留初始开关状态与计时设置。',
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var colour = 0; colour < 4; colour++)
              FilterChip(
                key: ValueKey('circuit-edit-colour-$colour'),
                label: Text(const ['红线', '蓝线', '绿线', '黄线'][colour]),
                selected: (_mask & (1 << colour)) != 0,
                onSelected: !_enabled
                    ? null
                    : (selected) => setState(() {
                        _mask = selected
                            ? _mask | (1 << colour)
                            : _mask & ~(1 << colour);
                      }),
              ),
            action(
              '预览网络删除',
              'network',
              () => _coordinates('circuitNetworkPreview'),
              ready: _mask != 0,
            ),
            action(
              '预览自动布线',
              'route',
              () => _coordinates('circuitRoutePreview'),
              ready: _mask != 0,
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (preview != null) ...[
          const SizedBox(height: 8),
          Text(
            stale
                ? '电路已改变，这份预览已失效，请重新预览。'
                : '${deleting ? '将移除所选颜色的网络电线' : '将添加所选颜色的安全路径'}：${preview['count']} 格。${deleting ? '元件和其他线色保留。' : ''}',
          ),
          if (preview['colourCounts'] case final List counts)
            Text(
              '红 ${counts[0]} · 蓝 ${counts[1]} · 绿 ${counts[2]} · 黄 ${counts[3]}',
            ),
        ],
        if (preview != null || _busy)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (preview != null)
                FilledButton(
                  key: const ValueKey('circuit-edit-confirm'),
                  onPressed: _enabled && !stale
                      ? () => _send('circuitConfirmEdit')
                      : null,
                  child: Text(deleting ? '确认删除网络' : '确认布线'),
                ),
              TextButton(
                key: const ValueKey('circuit-edit-cancel'),
                onPressed: () => _send('circuitCancelEdit'),
                child: const Text('取消预览'),
              ),
            ],
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        const Text('适用于当前单格元件沙盒。接线盒、像素盒和多格元件的方向与变换尚不支持。'),
      ],
    );
  }
}
