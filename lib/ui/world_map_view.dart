import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/world_map_overlay.dart';

class WorldMapView extends StatefulWidget {
  final Uint8List png;
  final WorldMapOverlay? overlay;
  final bool overlayBusy;
  final void Function(int x, int y, int width, int height)? onLoadOverlay;
  final int worldWidth, worldHeight;
  final Offset? location;
  final List<Offset> markers;
  final void Function(int, int)? onLocate;
  const WorldMapView({
    super.key,
    required this.png,
    required this.worldWidth,
    required this.worldHeight,
    this.location,
    this.markers = const [],
    this.onLocate,
    this.overlay,
    this.overlayBusy = false,
    this.onLoadOverlay,
  });
  @override
  State<WorldMapView> createState() => _WorldMapViewState();
}

class _WorldMapViewState extends State<WorldMapView> {
  final transform = TransformationController();
  Offset? _focused;
  int _wireMask = 15;
  bool _showLiquids = true;
  String? _overlayHint;
  Rect? _mapRect;
  Size? _viewportSize;

  void _loadOverlay() {
    final rect = _mapRect, viewport = _viewportSize;
    if (rect == null || viewport == null) return;
    final tiles = visibleWorldMapTiles(
      viewport: viewport,
      mapRect: rect,
      transform: transform,
      worldWidth: widget.worldWidth,
      worldHeight: widget.worldHeight,
    );
    if (tiles.isEmpty) {
      setState(() => _overlayHint = '当前视口未覆盖地图，请重置或平移地图。');
      return;
    }
    if (tiles.width * tiles.height > WorldMapOverlay.maxCells) {
      setState(() => _overlayHint = '视口超过 262144 格，请放大地图后读取。');
      return;
    }
    setState(() => _overlayHint = null);
    widget.onLoadOverlay?.call(
      tiles.left.toInt(),
      tiles.top.toInt(),
      tiles.width.toInt(),
      tiles.height.toInt(),
    );
  }

  @override
  void didUpdateWidget(covariant WorldMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.overlay != oldWidget.overlay ||
        widget.worldWidth != oldWidget.worldWidth ||
        widget.worldHeight != oldWidget.worldHeight) {
      _overlayHint = null;
    }
    if (widget.worldWidth != oldWidget.worldWidth ||
        widget.worldHeight != oldWidget.worldHeight) {
      transform.value = Matrix4.identity();
      _focused = null;
    }
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var bit = 0; bit < 4; bit++)
            FilterChip(
              key: ValueKey('world-map-wire-$bit'),
              label: Text(['红线', '蓝线', '绿线', '黄线'][bit]),
              avatar: Icon(
                Icons.horizontal_rule,
                color: WorldMapOverlayPainter.wireColors[bit],
                size: 18,
              ),
              selected: (_wireMask & (1 << bit)) != 0,
              onSelected: (selected) => setState(() {
                _wireMask = selected
                    ? _wireMask | (1 << bit)
                    : _wireMask & ~(1 << bit);
              }),
            ),
          FilterChip(
            key: const ValueKey('world-map-liquids'),
            label: const Text('液体'),
            selected: _showLiquids,
            onSelected: (value) => setState(() => _showLiquids = value),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const ValueKey('world-map-load-overlay'),
          onPressed: widget.overlayBusy || widget.onLoadOverlay == null
              ? null
              : _loadOverlay,
          icon: widget.overlayBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.layers_outlined),
          label: Text(widget.overlayBusy ? '正在读取视口图层…' : '读取当前视口图层'),
        ),
      ),
      Text(
        _overlayHint ?? _overlaySummary(),
        key: const ValueKey('world-map-overlay-status'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 340,
        child: LayoutBuilder(
          builder: (context, limits) {
            final width = math.max(1, widget.worldWidth),
                height = math.max(1, widget.worldHeight);
            final ratio = math.min(
              limits.maxWidth / width,
              limits.maxHeight / height,
            );
            final rect = Rect.fromLTWH(
              (limits.maxWidth - width * ratio) / 2,
              (limits.maxHeight - height * ratio) / 2,
              width * ratio,
              height * ratio,
            );
            _mapRect = rect;
            _viewportSize = Size(limits.maxWidth, limits.maxHeight);
            Offset point(Offset tile) =>
                Offset(rect.left + tile.dx * ratio, rect.top + tile.dy * ratio);
            final location = widget.location;
            if (location != null && location != _focused) {
              _focused = location;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) {
                  return;
                }
                final p = point(location);
                const zoom = 4.0;
                transform.value = Matrix4.identity()
                  ..translateByDouble(
                    limits.maxWidth / 2 - p.dx * zoom,
                    limits.maxHeight / 2 - p.dy * zoom,
                    0,
                    1,
                  )
                  ..scaleByDouble(zoom, zoom, 1, 1);
              });
            }
            return Stack(
              children: [
                InteractiveViewer(
                  transformationController: transform,
                  minScale: 1,
                  maxScale: 24,
                  boundaryMargin: const EdgeInsets.all(10000),
                  child: GestureDetector(
                    onLongPressStart: (details) {
                      final p = details.localPosition;
                      final x = ((p.dx - rect.left) / ratio).floor(),
                          y = ((p.dy - rect.top) / ratio).floor();
                      if (x >= 0 && y >= 0 && x < width && y < height) {
                        widget.onLocate?.call(x, y);
                      }
                    },
                    child: SizedBox(
                      width: limits.maxWidth,
                      height: limits.maxHeight,
                      child: Stack(
                        children: [
                          Positioned.fromRect(
                            rect: rect,
                            child: Image.memory(
                              widget.png,
                              fit: BoxFit.fill,
                              gaplessPlayback: true,
                            ),
                          ),
                          if (widget.overlay != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  key: const ValueKey(
                                    'world-map-overlay-painter',
                                  ),
                                  painter: WorldMapOverlayPainter(
                                    overlay: widget.overlay!,
                                    mapRect: rect,
                                    worldWidth: width,
                                    worldHeight: height,
                                    wireMask: _wireMask,
                                    showLiquids: _showLiquids,
                                  ),
                                ),
                              ),
                            ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _MarkerPainter(
                                  widget.markers.map(point).toList(),
                                  location == null ? null : point(location),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton.filledTonal(
                    tooltip: '重置地图缩放',
                    onPressed: () {
                      transform.value = Matrix4.identity();
                    },
                    icon: const Icon(Icons.fit_screen),
                  ),
                ),
                if (location != null)
                  Positioned(
                    left: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      color: const Color(0xdd102029),
                      child: Text(
                        'X ${location.dx.toInt()} · Y ${location.dy.toInt()}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xff9be7c1),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ],
  );

  String _overlaySummary() {
    final overlay = widget.overlay;
    if (overlay == null) return '尚未读取图层；放大地图后点击读取当前视口。';
    return '已读取 X ${overlay.x}–${overlay.x + overlay.width - 1} · '
        'Y ${overlay.y}–${overlay.y + overlay.height - 1}（${overlay.cellCount} 格）\n'
        '红/蓝/绿/黄线：${overlay.wireCounts.join(" / ")} 格 · '
        '水/熔岩/蜂蜜/微光：${overlay.liquidCounts.join(" / ")} 格\n'
        '仅显示已读取区域；移动或缩放后可再次读取。';
  }
}

/// Invert the viewer transform, intersect with the actual letterboxed map, and
/// include every partially visible tile. No region is fetched implicitly.
Rect visibleWorldMapTiles({
  required Size viewport,
  required Rect mapRect,
  required TransformationController transform,
  required int worldWidth,
  required int worldHeight,
}) {
  if (worldWidth <= 0 || worldHeight <= 0 || mapRect.isEmpty) return Rect.zero;
  final points = [
    Offset.zero,
    Offset(viewport.width, 0),
    Offset(0, viewport.height),
    Offset(viewport.width, viewport.height),
  ].map(transform.toScene).toList();
  if (points.any((p) => !p.dx.isFinite || !p.dy.isFinite)) return Rect.zero;
  final visible = Rect.fromLTRB(
    points.map((p) => p.dx).reduce(math.min),
    points.map((p) => p.dy).reduce(math.min),
    points.map((p) => p.dx).reduce(math.max),
    points.map((p) => p.dy).reduce(math.max),
  ).intersect(mapRect);
  if (visible.isEmpty) return Rect.zero;
  final left = ((visible.left - mapRect.left) / mapRect.width * worldWidth)
          .floor()
          .clamp(0, worldWidth),
      top = ((visible.top - mapRect.top) / mapRect.height * worldHeight)
          .floor()
          .clamp(0, worldHeight),
      right = ((visible.right - mapRect.left) / mapRect.width * worldWidth)
          .ceil()
          .clamp(0, worldWidth),
      bottom = ((visible.bottom - mapRect.top) / mapRect.height * worldHeight)
          .ceil()
          .clamp(0, worldHeight);
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

class WorldMapOverlayPainter extends CustomPainter {
  static const wireColors = [
    Color(0xffff5252),
    Color(0xff448aff),
    Color(0xff69f06e),
    Color(0xffffdf42),
  ];
  static const liquidColors = [
    Color(0xbb3589ff),
    Color(0xd9ff5722),
    Color(0xccffb82e),
    Color(0xcdb694ff),
  ];
  final WorldMapOverlay overlay;
  final Rect mapRect;
  final int worldWidth, worldHeight, wireMask;
  final bool showLiquids;
  const WorldMapOverlayPainter({
    required this.overlay,
    required this.mapRect,
    required this.worldWidth,
    required this.worldHeight,
    required this.wireMask,
    required this.showLiquids,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (worldWidth <= 0 || worldHeight <= 0 || mapRect.isEmpty) return;
    final sx = mapRect.width / worldWidth, sy = mapRect.height / worldHeight;
    final pen = Paint()..isAntiAlias = false;
    canvas.save();
    canvas.clipRect(mapRect);
    for (var index = 0; index < overlay.cellCount; index++) {
      final wires = overlay.wireMasks[index] & wireMask;
      final amount = showLiquids ? overlay.liquidAmounts[index] : 0;
      if (wires == 0 && amount == 0) continue;
      final x = overlay.x + index % overlay.width,
          y = overlay.y + index ~/ overlay.width;
      final cell = Rect.fromLTWH(
        mapRect.left + x * sx,
        mapRect.top + y * sy,
        sx,
        sy,
      );
      if (!cell.overlaps(mapRect)) continue;
      if (amount != 0) {
        pen.color = liquidColors[overlay.liquidKinds[index] - 1];
        canvas.drawRect(
          Rect.fromLTRB(
            cell.left,
            cell.bottom - sy * amount / 255,
            cell.right,
            cell.bottom,
          ),
          pen,
        );
      }
      for (var bit = 0; bit < 4; bit++) {
        if ((wires & (1 << bit)) == 0) continue;
        pen
          ..color = wireColors[bit]
          ..strokeWidth = sy * 0.16;
        // Each color has its own lane, so crossing colors stay distinguishable.
        final lane = cell.top + sy * (bit + 0.5) / 4;
        canvas.drawLine(Offset(cell.left, lane), Offset(cell.right, lane), pen);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WorldMapOverlayPainter old) =>
      old.overlay != overlay ||
      old.mapRect != mapRect ||
      old.worldWidth != worldWidth ||
      old.worldHeight != worldHeight ||
      old.wireMask != wireMask ||
      old.showLiquids != showLiquids;
}

class _MarkerPainter extends CustomPainter {
  final List<Offset> points;
  final Offset? location;
  _MarkerPainter(this.points, this.location);
  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = const Color(0xffffbf70),
        border = Paint()
          ..color = const Color(0xff15241e)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8;
    for (final p in points) {
      canvas.drawCircle(p, 2.3, fill);
      canvas.drawCircle(p, 2.3, border);
    }
    if (location case final p?) {
      final pen = Paint()
        ..color = const Color(0xff9be7c1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawCircle(p, 4, pen);
      canvas.drawLine(p + const Offset(-7, 0), p + const Offset(7, 0), pen);
      canvas.drawLine(p + const Offset(0, -7), p + const Offset(0, 7), pen);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerPainter old) =>
      old.location != location || old.points != points;
}
