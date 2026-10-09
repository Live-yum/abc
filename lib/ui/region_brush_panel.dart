import 'package:flutter/material.dart';

import '../domain/region_brush.dart';
import '../domain/resource_catalog.dart';

/// Emits configuration only. The host snapshots this intent when a stroke starts
/// and re-derives each patch against the current cell, preserving other layers.
class RegionBrushPanel extends StatefulWidget {
  final RegionBrush? brush;
  final ResourceCatalog? catalog;
  final bool busy, readOnly;
  final Future<void> Function(String action, Map<String, Object?> args)
  onAction;

  const RegionBrushPanel({
    super.key,
    this.brush,
    this.catalog,
    this.busy = false,
    this.readOnly = false,
    required this.onAction,
  });

  @override
  State<RegionBrushPanel> createState() => _RegionBrushPanelState();
}

class _RegionBrushPanelState extends State<RegionBrushPanel> {
  final _id = TextEditingController(text: '1');
  final _paint = TextEditingController(text: '0');
  final _amount = TextEditingController(text: '255');
  RegionBrushKind _kind = RegionBrushKind.block;
  RegionBrushLayer _layer = RegionBrushLayer.block;
  int _liquid = 1, _mask = 1, _shape = 0;
  bool _remove = false, _sending = false;
  String? _error;
  bool get _locked => widget.busy || widget.readOnly || _sending;

  static const _kinds = {
    RegionBrushKind.block: '方块 ID',
    RegionBrushKind.wall: '背景墙 ID',
    RegionBrushKind.paint: '涂漆 / 去漆',
    RegionBrushKind.liquid: '液体',
    RegionBrushKind.wire: '四色电线',
    RegionBrushKind.shape: '坡形 / 半砖',
    RegionBrushKind.actuator: '制动器',
    RegionBrushKind.erase: '按图层擦除',
  };
  static const _layers = {
    RegionBrushLayer.block: '前景方块',
    RegionBrushLayer.wall: '背景墙',
    RegionBrushLayer.liquid: '液体',
    RegionBrushLayer.wire: '电线与制动器',
    RegionBrushLayer.all: '所有图层',
  };

  @override
  void initState() {
    super.initState();
    _load(widget.brush);
  }

  @override
  void didUpdateWidget(covariant RegionBrushPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.brush != oldWidget.brush) _load(widget.brush);
  }

  void _load(RegionBrush? brush) {
    if (brush == null) return;
    _kind = brush.kind;
    _layer = brush.layer;
    _id.text = '${brush.id}';
    _paint.text = '${brush.paint}';
    _amount.text = '${brush.amount}';
    _liquid = brush.liquidType;
    _mask = brush.mask;
    _shape = brush.shape;
    _remove = brush.remove;
    _error = null;
  }

  @override
  void dispose() {
    _id.dispose();
    _paint.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _useBrush() async {
    if (_locked) return;
    try {
      final config = RegionBrush.fromIntent({
        'kind': _kind.name,
        ...switch (_kind) {
          RegionBrushKind.block ||
          RegionBrushKind.wall => {'id': int.tryParse(_id.text)},
          RegionBrushKind.paint => {
            'layer': _layer.name,
            'paint': int.tryParse(_paint.text),
          },
          RegionBrushKind.liquid => {
            'liquidType': _liquid,
            'amount': int.tryParse(_amount.text),
          },
          RegionBrushKind.wire => {'mask': _mask, 'remove': _remove},
          RegionBrushKind.shape => {'shape': _shape},
          RegionBrushKind.actuator => {'remove': _remove},
          RegionBrushKind.erase => {'layer': _layer.name},
        },
      });
      setState(() {
        _sending = true;
        _error = null;
      });
      await widget.onAction('regionBrush', config.intent);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _number(String key, String label, TextEditingController controller) =>
      SizedBox(
        width: 170,
        child: TextField(
          key: ValueKey(key),
          controller: controller,
          enabled: !_locked,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() => _error = null),
        ),
      );

  Widget _operation() => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final remove in [false, true])
        ChoiceChip(
          key: ValueKey('region-brush-remove-$remove'),
          label: Text(remove ? '拆除' : '添加'),
          selected: _remove == remove,
          onSelected: _locked ? null : (_) => setState(() => _remove = remove),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final structural =
        _kind == RegionBrushKind.block ||
        _kind == RegionBrushKind.shape ||
        (_kind == RegionBrushKind.erase &&
            (_layer == RegionBrushLayer.block ||
                _layer == RegionBrushLayer.all));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('连续图层画笔', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('选择参数后启用，在画布拖动绘制；一次拖动可整体撤销。'),
        DropdownButton<RegionBrushKind>(
          key: const ValueKey('region-brush-kind'),
          isExpanded: true,
          value: _kind,
          items: [
            for (final entry in _kinds.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: _locked
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() {
                    _kind = value;
                    _error = null;
                    if (_kind == RegionBrushKind.paint &&
                        _layer != RegionBrushLayer.block &&
                        _layer != RegionBrushLayer.wall) {
                      _layer = RegionBrushLayer.block;
                    }
                  });
                },
        ),
        if (_kind == RegionBrushKind.block || _kind == RegionBrushKind.wall)
          Wrap(children: [_number('region-brush-id', '原版 ID · 0–65535', _id)]),
        if (_kind == RegionBrushKind.paint || _kind == RegionBrushKind.erase)
          DropdownButton<RegionBrushLayer>(
            key: const ValueKey('region-brush-layer'),
            isExpanded: true,
            value: _layer,
            items: [
              for (final entry in _layers.entries)
                if (_kind != RegionBrushKind.paint ||
                    entry.key == RegionBrushLayer.block ||
                    entry.key == RegionBrushLayer.wall)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _locked
                ? null
                : (value) {
                    if (value != null) setState(() => _layer = value);
                  },
          ),
        if (_kind == RegionBrushKind.paint) ...[
          Wrap(
            children: [_number('region-brush-paint', '油漆 ID · 0–30', _paint)],
          ),
          const Text('0 去漆；跳过没有对应方块或墙体的格子。'),
        ],
        if (_kind == RegionBrushKind.liquid) ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in {1: '水', 2: '岩浆', 3: '蜂蜜', 4: '微光'}.entries)
                ChoiceChip(
                  key: ValueKey('region-brush-liquid-${entry.key}'),
                  label: Text(entry.value),
                  selected: _liquid == entry.key,
                  onSelected: _locked
                      ? null
                      : (_) => setState(() => _liquid = entry.key),
                ),
            ],
          ),
          Wrap(
            children: [_number('region-brush-amount', '液量 · 0–255', _amount)],
          ),
          const Text('液量 0 清除液体；微光写入仍须通过目标世界版本校验。'),
        ],
        if (_kind == RegionBrushKind.wire) ...[
          _operation(),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final entry in {1: '红', 2: '蓝', 4: '绿', 8: '黄'}.entries)
                FilterChip(
                  key: ValueKey('region-brush-wire-${entry.key}'),
                  label: Text(entry.value),
                  selected: _mask & entry.key != 0,
                  onSelected: _locked
                      ? null
                      : (_) => setState(() {
                          final next = _mask ^ entry.key;
                          if (next != 0) _mask = next;
                        }),
                ),
            ],
          ),
          const Text('可组合四色，只改变选中的通道；至少保留一种颜色。'),
        ],
        if (_kind == RegionBrushKind.shape)
          DropdownButton<int>(
            key: const ValueKey('region-brush-shape'),
            isExpanded: true,
            value: _shape,
            items: [
              for (final entry in {
                0: '完整方块',
                1: '半砖',
                2: '◣ 坡形',
                3: '◢ 坡形',
                4: '◤ 坡形',
                5: '◥ 坡形',
              }.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _locked
                ? null
                : (value) {
                    if (value != null) setState(() => _shape = value);
                  },
          ),
        if (_kind == RegionBrushKind.actuator) ...[
          _operation(),
          const Text('拆除制动器同时清除非激活状态。'),
        ],
        if (structural)
          Text(
            widget.catalog == null
                ? '请导入包含普通方块元数据的本地资源包。家具主体不会被连续画笔覆盖。'
                : '仅编辑元数据已验证的普通方块；家具主体、未知方块会被保护。',
          ),
        if (widget.readOnly) const Text('当前区域只读。'),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('region-brush-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const ValueKey('region-brush-apply'),
          onPressed: _locked ? null : _useBrush,
          icon: const Icon(Icons.brush_outlined),
          label: Text(_sending ? '正在启用…' : '使用连续画笔'),
        ),
      ],
    );
  }
}
