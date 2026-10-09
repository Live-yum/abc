import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/terraria_map.dart';
import '../engine/map_backend.dart';

class TerrariaMapPanel extends StatefulWidget {
  final MapSessionInfo? session;
  final TerrariaMapRaster? raster;
  final Future<void> Function(String action, Map<String, Object?> args)
  onAction;
  final bool busy, canGenerateWorldMap;
  const TerrariaMapPanel({
    super.key,
    required this.session,
    required this.onAction,
    this.raster,
    this.busy = false,
    this.canGenerateWorldMap = false,
  });
  @override
  State<TerrariaMapPanel> createState() => _TerrariaMapPanelState();
}

class _TerrariaMapPanelState extends State<TerrariaMapPanel> {
  final _fields = <String, TextEditingController>{
    'x': TextEditingController(text: '0'),
    'y': TextEditingController(text: '0'),
    'width': TextEditingController(text: '1'),
    'height': TextEditingController(text: '1'),
    'light': TextEditingController(text: '255'),
    'color': TextEditingController(),
  };
  ui.Image? _image;
  int _epoch = 0, _renderedRevision = -1;
  String? _error;
  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(covariant TerrariaMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session) ||
        !identical(oldWidget.raster, widget.raster) ||
        _renderedRevision != widget.session?.revision) {
      _render();
    }
  }

  void _render() {
    final epoch = ++_epoch, session = widget.session;
    _image?.dispose();
    _image = null;
    _renderedRevision = session?.revision ?? -1;
    _error = null;
    final raster = widget.raster;
    if (session == null || raster == null) return;
    try {
      ui.decodeImageFromPixels(
        raster.rgba,
        raster.width,
        raster.height,
        ui.PixelFormat.rgba8888,
        (image) {
          if (!mounted || epoch != _epoch) {
            image.dispose();
            return;
          }
          setState(() => _image = image);
        },
      );
    } catch (error) {
      _error = error.toString();
    }
  }

  Future<void> _edit() async {
    try {
      final args = <String, Object?>{};
      for (final entry in _fields.entries) {
        final text = entry.value.text.trim();
        if (entry.key == 'color' && text.isEmpty) continue;
        final value = int.tryParse(text);
        if (value == null) throw FormatException('${entry.key} 必须是整数');
        args[entry.key] = value;
      }
      setState(() => _error = null);
      await widget.onAction('editMapRect', args);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _replace(String action) async {
    if (widget.session?.isModified == true) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃当前 MAP 修改？'),
          content: const Text('当前 MAP 有修改。继续会关闭这份编辑会话；可取消后先导出 .MAP。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃修改并继续'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    await widget.onAction(action, {});
  }

  @override
  void dispose() {
    _epoch++;
    _image?.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final available = session != null && !session.isClosed;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('探索存档 · .MAP', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('直接读取和导出 Terraria 二进制 MAP。下方显示探索亮度的灰度图；颜色与世界地形预览分开。'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: widget.busy ? null : () => _replace('importMap'),
              icon: const Icon(Icons.folder_open),
              label: const Text('打开 .MAP'),
            ),
            if (widget.canGenerateWorldMap)
              OutlinedButton(
                onPressed: widget.busy
                    ? null
                    : () => _replace('generateMapFromWorld'),
                child: const Text('从世界生成全亮 MAP'),
              ),
            OutlinedButton(
              onPressed: widget.busy || !available
                  ? null
                  : () => widget.onAction('exportMap', {}),
              child: const Text('导出 .MAP'),
            ),
            TextButton(
              onPressed: widget.busy || !available
                  ? null
                  : () => _replace('closeMap'),
              child: const Text('关闭 MAP'),
            ),
          ],
        ),
        if (available) ...[
          const SizedBox(height: 12),
          Text(
            '${session.worldName} · ${session.width} × ${session.height} · v${session.version} · '
            '${session.chunked ? '分块压缩' : 'Deflate/RLE'}${session.isModified ? ' · 已修改' : ''}',
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 260,
            child: ColoredBox(
              color: Colors.black,
              child: _image == null
                  ? const Center(
                      child: Text(
                        '正在读取探索亮度图',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : InteractiveViewer(
                      minScale: 1,
                      maxScale: 12,
                      child: Center(
                        child: RawImage(
                          image: _image,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.none,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('区域修改：亮度 0–255，绘制颜色编号 0–31（可留空）。仅修改选定区域，最多 262,144 格。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 10,
            children: [
              for (final entry in _fields.entries)
                SizedBox(
                  width: 104,
                  child: TextField(
                    controller: entry.value,
                    enabled: !widget.busy,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      labelText: {
                        'x': 'X',
                        'y': 'Y',
                        'width': '宽',
                        'height': '高',
                        'light': '亮度',
                        'color': '颜色编号',
                      }[entry.key],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: widget.busy ? null : _edit,
                child: const Text('应用区域修改'),
              ),
              OutlinedButton(
                onPressed: widget.busy || !session.canUndo
                    ? null
                    : () => widget.onAction('undoMap', {}),
                child: const Text('撤销'),
              ),
              OutlinedButton(
                onPressed: widget.busy || !session.canRedo
                    ? null
                    : () => widget.onAction('redoMap', {}),
                child: const Text('重做'),
              ),
            ],
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
