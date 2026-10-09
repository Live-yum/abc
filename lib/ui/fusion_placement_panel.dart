import 'package:flutter/material.dart';

import '../domain/chest_tools.dart';
import '../domain/fusion_placement.dart';
import '../domain/region_document.dart';
import '../domain/resource_catalog.dart';

/// Searches local item metadata and emits a narrow placement intent. The host
/// re-derives the brush, stages history, then validates/inserts the core overlay.
class FusionPlacementPanel extends StatefulWidget {
  final ResourceCatalog? catalog;
  final AdvancedRegionDocument? document;
  final int x, y, worldVersion;
  final bool busy, readOnly;
  final Future<void> Function(String action, Map<String, Object?> args)
  onAction;
  const FusionPlacementPanel({
    super.key,
    required this.catalog,
    required this.document,
    required this.worldVersion,
    this.x = 0,
    this.y = 0,
    this.busy = false,
    this.readOnly = false,
    required this.onAction,
  });
  @override
  State<FusionPlacementPanel> createState() => _FusionPlacementPanelState();
}

class _FusionPlacementPanelState extends State<FusionPlacementPanel> {
  final _query = TextEditingController();
  final _name = TextEditingController(), _text = TextEditingController();
  bool _logicOn = false;
  FusionPlacementCatalog? _catalog;
  String? _error;
  bool _display = false, _sending = false;
  int? _item;
  int _variant = 0, _page = 0;
  static const _pageSize = 24;
  bool get _locked => widget.busy || widget.readOnly || _sending;
  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void didUpdateWidget(covariant FusionPlacementPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.catalog, oldWidget.catalog)) _loadCatalog();
  }

  void _loadCatalog() {
    _item = null;
    _variant = 0;
    _page = 0;
    _error = null;
    _catalog = null;
    _resetOptions();
    if (widget.catalog == null) return;
    try {
      _catalog = FusionPlacementCatalog(widget.catalog!);
    } catch (e) {
      _error = '$e';
    }
  }

  void _resetOptions() {
    _name.clear();
    _text.clear();
    _logicOn = false;
  }

  @override
  void dispose() {
    _query.dispose();
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _place(FusionPlacementBrush brush) async {
    if (_locked) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onAction('fusionPlace', brush.intent(widget.x, widget.y));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final rows =
        catalog?.search(query: _query.text, display: _display) ??
        const <CatalogEntry>[];
    final pages = ((rows.length + _pageSize - 1) ~/ _pageSize).clamp(1, 10000);
    final page = _page.clamp(0, pages - 1);
    final visible = rows.skip(page * _pageSize).take(_pageSize);
    final shapes = _item == null
        ? const <FusionPlacementGeometry>[]
        : catalog?.variants(_item!, display: _display) ??
              const <FusionPlacementGeometry>[];
    final reason = _item == null
        ? null
        : catalog?.unavailableReason(_item!, display: _display);
    FusionPlacementBrush? brush;
    String? optionsError;
    final tile = shapes.isNotEmpty ? shapes[_variant].tile : null;
    final container = {21, 88, 467}.contains(tile);
    final sign = {55, 85, 425, 573}.contains(tile);
    if (catalog != null && _item != null && shapes.isNotEmpty) {
      try {
        brush = catalog.brush(
          _item!,
          variantIndex: _variant,
          display: _display,
          name: container ? _name.text : '',
          text: sign ? _text.text : '',
          logicOn: tile == 423 && _logicOn,
        );
      } catch (error) {
        optionsError = '$error';
      }
    }
    final document = widget.document;
    final preview = brush != null && document != null
        ? FusionPlacementPlan.preview(
            document: document,
            brush: brush,
            x: widget.x,
            y: widget.y,
            worldVersion: widget.worldVersion,
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('新增家具与展示框', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('先在读取区域选择左上角。物件必须完整放在空白占格；暂存后再校验并插入世界。'),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (catalog == null)
          const Text('请导入包含物品目录与 tile-object-data 的本地资源包。')
        else ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('fusion-mode-furniture'),
                label: const Text('放置家具'),
                selected: !_display,
                onSelected: _locked
                    ? null
                    : (_) => setState(() {
                        _display = false;
                        _resetOptions();
                        _variant = 0;
                        _page = 0;
                      }),
              ),
              ChoiceChip(
                key: const ValueKey('fusion-mode-display'),
                label: const Text('展示框陈列物品'),
                selected: _display,
                onSelected: _locked
                    ? null
                    : (_) => setState(() {
                        _display = true;
                        _resetOptions();
                        _variant = 0;
                        _page = 0;
                      }),
              ),
              Text(
                '资源 ${catalog.catalog.gameVersion} · WLD ${widget.worldVersion}',
              ),
            ],
          ),
          TextField(
            key: const ValueKey('fusion-placement-search'),
            controller: _query,
            enabled: !_locked,
            decoration: const InputDecoration(
              labelText: '搜索物品名称、ID 或 tile:编号',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) => setState(() => _page = 0),
          ),
          SizedBox(
            height: 230,
            child: rows.isEmpty
                ? const Center(child: Text('没有匹配的可放置物品'))
                : ListView(
                    children: [
                      for (final item in visible)
                        ListTile(
                          key: ValueKey('fusion-item-${item.id}'),
                          dense: true,
                          selected: _item == item.numericId,
                          title: Text(
                            '${item.name} · ${item.id}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            catalog.unavailableReason(
                                  item.numericId ?? 0,
                                  display: _display,
                                ) ??
                                (_display
                                    ? '展示物品 ${item.id} · 物品框 Tile 395'
                                    : 'Tile ${item.fields['createTile']} · 原版占格'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: _locked
                              ? null
                              : () => setState(() {
                                  _item = item.numericId;
                                  _resetOptions();
                                  _variant = 0;
                                  _error = null;
                                }),
                        ),
                    ],
                  ),
          ),
          Row(
            children: [
              IconButton(
                key: const ValueKey('fusion-placement-previous'),
                tooltip: '上一页',
                onPressed: !_locked && page > 0
                    ? () => setState(() => _page = page - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${rows.length} 条 · ${page + 1} / $pages 页',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                key: const ValueKey('fusion-placement-next'),
                tooltip: '下一页',
                onPressed: !_locked && page + 1 < pages
                    ? () => setState(() => _page = page + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          if (reason != null) Text(reason),
          if (container) ...[
            TextField(
              key: const ValueKey('fusion-placement-name'),
              controller: _name,
              enabled: !_locked,
              maxLength: ChestTools.maxNameLength,
              decoration: const InputDecoration(labelText: '容器名称（可留空）'),
              onChanged: (_) => setState(() {}),
            ),
            const Text('新容器有 40 个空格；不会从物品目录填入内容。'),
          ],
          if (sign)
            TextField(
              key: const ValueKey('fusion-placement-text'),
              controller: _text,
              enabled: !_locked,
              minLines: 2,
              maxLines: 5,
              maxLength: 1048576,
              decoration: const InputDecoration(labelText: '文字（可留空）'),
              onChanged: (_) => setState(() {}),
            ),
          if (tile == 423)
            SwitchListTile(
              key: const ValueKey('fusion-placement-logic-on'),
              title: const Text('感应器初始开启'),
              subtitle: Text('检测类型由原版样式 ${shapes[_variant].style} 决定'),
              value: _logicOn,
              onChanged: _locked
                  ? null
                  : (value) => setState(() => _logicOn = value),
            ),
          if (optionsError != null)
            Text(
              optionsError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (shapes.isNotEmpty) ...[
            Text(
              '已选：${catalog.catalog.byId('items', _item!)!.name} · Tile $tile',
            ),
            DropdownButton<int>(
              key: const ValueKey('fusion-placement-variant'),
              value: _variant,
              isExpanded: true,
              items: [
                for (var i = 0; i < shapes.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      shapes[i].label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _locked
                  ? null
                  : (value) {
                      if (value != null) setState(() => _variant = value);
                    },
            ),
            Text(
              '占格 ${shapes[_variant].width} × ${shapes[_variant].height} · 区域左上角 ${widget.x}, ${widget.y}',
            ),
            if (_display) const Text('展示数量 1 · 前缀 0 · 附加记录与物块一起撤销、保存'),
          ],
          if (document == null) const Text('请先读取完整世界选区'),
          if (preview != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 112,
              child: CustomPaint(
                key: const ValueKey('fusion-placement-footprint'),
                painter: _FootprintPainter(
                  preview,
                  Theme.of(context).colorScheme,
                ),
                child: Center(
                  child: Text(preview.canPlace ? '完整空白占格' : '不能放置'),
                ),
              ),
            ),
            for (final issue in preview.blockers)
              Text(
                issue,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('fusion-placement-stage'),
            onPressed: !_locked && preview?.canPlace == true && brush != null
                ? () => _place(brush!)
                : null,
            icon: const Icon(Icons.add_box_outlined),
            label: Text(_sending ? '正在暂存…' : '暂存新增物件'),
          ),
        ],
      ],
    );
  }
}

class _FootprintPainter extends CustomPainter {
  final FusionPlacementPlan plan;
  final ColorScheme colors;
  _FootprintPainter(this.plan, this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    final cell = (size.width / plan.width)
        .clamp(1.0, 40.0)
        .clamp(1.0, size.height / plan.height);
    final left = (size.width - cell * plan.width) / 2;
    final top = (size.height - cell * plan.height) / 2;
    final color = plan.canPlace ? colors.primary : colors.error;
    final fill = Paint()..color = color.withValues(alpha: .13);
    final border = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    for (var x = 0; x < plan.width; x++) {
      for (var y = 0; y < plan.height; y++) {
        final rect = Rect.fromLTWH(left + x * cell, top + y * cell, cell, cell);
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, border);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FootprintPainter oldDelegate) => true;
}
