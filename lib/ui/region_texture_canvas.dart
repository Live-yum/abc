import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/region_document.dart';
import '../domain/fusion_placement.dart';
import '../domain/resource_catalog.dart';
import '../platform/resource_store.dart';

/// Source rectangles are in original PNG pixels, never inventory icon bounds.
class RegionTextureFrame {
  final CatalogEntry atlas;
  final Rect source, destination;
  final int shape, paint;
  final bool approximate;
  const RegionTextureFrame(
    this.atlas,
    this.source,
    this.destination, {
    this.shape = 0,
    this.paint = 0,
    this.approximate = false,
  });
}

/// Static preview only: ordinary material merges, paint and liquids are previews.
/// Unsupported furniture frames remain explicit; no invented frame-zero fallback.
class RegionTextureLayout {
  final AdvancedRegionDocument region;
  final ResourceStore? resources;
  final Map<(int, int), Map<String, int>> cells = {};
  final Map<(int, int, int), (int, int, int)> _geometry = {};
  List<FusionDisplayItem> displayItems = const [];
  RegionTextureLayout(this.region, this.resources) {
    try {
      displayItems = FusionDisplayItem.readAll(region);
    } on FormatException {
      // Malformed or unsupported companions never imply guessed display items.
    }
    for (var i = 0; i < region.recordCount; i++) {
      final c = region.cellAtIndex(i);
      cells[(c['x']!, c['y']!)] = c;
    }
    for (final entry
        in resources?.catalog.families['tile-object-data'] ??
            <CatalogEntry>[]) {
      final r = entry.fields;
      int? n(String k) => r[k] is int ? r[k] as int : null;
      final type = n('tile'),
          fx = n('frameX'),
          fy = n('frameY'),
          width = n('width'),
          height = n('height'),
          cw = n('coordinateWidth'),
          padding = n('coordinatePadding');
      final heights = r['coordinateHeights'];
      if (type == null ||
          fx == null ||
          fy == null ||
          width == null ||
          height == null ||
          cw == null ||
          padding == null ||
          width < 1 ||
          width > 32 ||
          height < 1 ||
          height > 32 ||
          cw < 1 ||
          cw > 64 ||
          padding < 0 ||
          padding > 16 ||
          heights is! List ||
          heights.length != height) {
        continue;
      }
      var sy = fy;
      for (var y = 0; y < height; y++) {
        final ch = heights[y];
        if (ch is! int || ch < 1 || ch > 64) break;
        for (var x = 0; x < width; x++) {
          _geometry[(type, fx + x * (cw + padding), sy)] = (
            cw,
            ch,
            n('drawYOffset') ?? 0,
          );
        }
        sy += ch + padding;
      }
    }
  }
  // Verified ordinary 18px frame and 36px wall grid layout from source recipes.
  static const blockFrames = [
    (162, 54),
    (108, 54),
    (216, 0),
    (18, 72),
    (162, 0),
    (0, 72),
    (108, 72),
    (18, 36),
    (108, 0),
    (90, 0),
    (18, 54),
    (72, 0),
    (0, 54),
    (0, 0),
    (18, 0),
    (18, 18),
  ];
  static const wallFrames = [
    (9, 3),
    (6, 3),
    (12, 0),
    (1, 4),
    (9, 0),
    (0, 4),
    (6, 4),
    (1, 2),
    (6, 0),
    (5, 0),
    (1, 3),
    (4, 0),
    (0, 3),
    (0, 0),
    (1, 0),
    (1, 1),
  ];
  int _mask(Map<String, int> c, bool wall) {
    final x = c['x']!, y = c['y']!;
    bool same(int dx, int dy) {
      final n = cells[(x + dx, y + dy)];
      return n != null &&
          (wall
              ? n['wall']! > 0 && n['invisibleWall'] == 0
              : n['active'] == 1 &&
                    n['block'] == c['block'] &&
                    n['invisibleBlock'] == 0);
    }

    return (same(0, -1) ? 1 : 0) |
        (same(-1, 0) ? 2 : 0) |
        (same(1, 0) ? 4 : 0) |
        (same(0, 1) ? 8 : 0);
  }

  RegionTextureFrame? frame(Map<String, int> c, {bool wall = false}) {
    if (wall
        ? c['wall'] == 0 || c['invisibleWall'] == 1
        : c['active'] == 0 || c['invisibleBlock'] == 1) {
      return null;
    }
    final atlas = resources?.catalog.byId(
      wall ? 'wall-atlases' : 'tile-atlases',
      c[wall ? 'wall' : 'block']!,
    );
    if (atlas == null || atlas.iconPath == null) return null;
    final x = c['x']! * 16.0, y = c['y']! * 16.0;
    if (wall) {
      final f = wallFrames[_mask(c, true)];
      return RegionTextureFrame(
        atlas,
        Rect.fromLTWH(f.$1 * 36.0, f.$2 * 36.0, 32, 32),
        Rect.fromLTWH(x - 8, y - 8, 32, 32),
        paint: c['wallPaint']!,
        approximate: true,
      );
    }
    final shape = c['slope']!;
    if (shape > 5) return null;
    if (atlas.fields['frameImportant'] == true) {
      final fx = c['frameX']!,
          fy = c['frameY']!,
          g = _geometry[(c['block']!, c['frameX']!, c['frameY']!)];
      if (fx < 0 || fy < 0 || g == null) return null;
      return RegionTextureFrame(
        atlas,
        Rect.fromLTWH(
          fx.toDouble(),
          fy.toDouble(),
          g.$1.toDouble(),
          g.$2.toDouble(),
        ),
        Rect.fromLTWH(
          x + ((16 - g.$1) / 2).floor(),
          y + g.$3,
          g.$1.toDouble(),
          g.$2.toDouble(),
        ),
        paint: c['blockPaint']!,
      );
    }
    if (atlas.fields['ordinaryFrames'] != true) return null;
    final f = blockFrames[_mask(c, false)], h = shape == 1 ? 8.0 : 16.0;
    return RegionTextureFrame(
      atlas,
      Rect.fromLTWH(f.$1.toDouble(), f.$2.toDouble(), 16, h),
      Rect.fromLTWH(x, y + (shape == 1 ? 8 : 0), 16, h),
      shape: shape,
      paint: c['blockPaint']!,
      approximate: true,
    );
  }
}

class RegionTextureCanvas extends StatefulWidget {
  final AdvancedRegionDocument region;
  final ResourceStore? resources;
  final Offset? selection;
  final void Function(int x, int y)? onTap, onDraw;
  final VoidCallback? onStrokeStart, onStrokeEnd;
  final bool drawMode;
  const RegionTextureCanvas({
    super.key,
    required this.region,
    this.resources,
    this.selection,
    this.onTap,
    this.onDraw,
    this.onStrokeStart,
    this.onStrokeEnd,
    this.drawMode = false,
  });
  @override
  State<RegionTextureCanvas> createState() => _RegionTextureCanvasState();
}

class _RegionTextureCanvasState extends State<RegionTextureCanvas> {
  final Map<String, ui.Image> _images = {};
  int _generation = 0;
  int _revision = -1;
  late RegionTextureLayout _layout;
  void _refreshLayout() {
    _revision = widget.region.revision;
    _layout = RegionTextureLayout(widget.region, widget.resources);
  }

  @override
  void initState() {
    super.initState();
    _refreshLayout();
    _load();
  }

  @override
  void didUpdateWidget(covariant RegionTextureCanvas old) {
    super.didUpdateWidget(old);
    if (old.region != widget.region ||
        old.resources != widget.resources ||
        _revision != widget.region.revision) {
      _refreshLayout();
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation, store = widget.resources;
    final wanted = <String, CatalogEntry>{};
    final layout = _layout;
    for (final c in layout.cells.values) {
      for (final wall in [true, false]) {
        final frame = layout.frame(c, wall: wall);
        if (frame?.atlas.iconPath != null) {
          wanted[frame!.atlas.iconPath!] = frame.atlas;
        }
      }
    }
    for (final display in layout.displayItems) {
      final item = store?.catalog.byId('items', display.itemId);
      if (item?.iconPath != null) wanted[item!.iconPath!] = item;
    }
    // Bounded decoded working set. Missing entries are visibly marked.
    for (final key in _images.keys.toList()) {
      if (!wanted.containsKey(key)) {
        _images.remove(key)!.dispose();
      }
    }
    var pixels = _images.values.fold<int>(
      0,
      (sum, image) => sum + image.width * image.height,
    );
    for (final row in wanted.values.take(256)) {
      final path = row.iconPath!;
      if (_images.containsKey(path)) continue;
      final data = store?.iconBytes(row);
      if (data == null) continue;
      try {
        final codec = await ui.instantiateImageCodec(data);
        final f = await codec.getNextFrame();
        codec.dispose();
        if (!mounted || generation != _generation) {
          f.image.dispose();
          return;
        }
        pixels += f.image.width * f.image.height;
        if (pixels > 16 * 1024 * 1024) {
          f.image.dispose();
          break;
        }
        _images[path] = f.image;
      } catch (_) {
        /* Invalid decode remains a missing-atlas marker. */
      }
    }
    if (mounted && generation == _generation) setState(() {});
  }

  @override
  void dispose() {
    _generation++;
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    void point(Offset p, Size size, bool draw) {
      final x = (p.dx / size.width * widget.region.width).floor(),
          y = (p.dy / size.height * widget.region.height).floor();
      if (x >= 0 &&
          x < widget.region.width &&
          y >= 0 &&
          y < widget.region.height) {
        (draw ? widget.onDraw : widget.onTap)?.call(x, y);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '原图静态预览 · 普通方块/墙邻接为近似 · 液体/涂漆为示意 · × 表示资源或帧缺失',
          style: TextStyle(fontSize: 11, color: Color(0xff91b4a9)),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(
                widget.region.width * 24.0,
                widget.region.height * 24.0,
              );
              return InteractiveViewer(
                constrained: false,
                minScale: 0.05,
                maxScale: 8,
                panEnabled: !widget.drawMode,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: widget.drawMode
                      ? (e) {
                          widget.onStrokeStart?.call();
                          point(e.localPosition, size, false);
                          point(e.localPosition, size, true);
                        }
                      : null,
                  onPointerMove: widget.drawMode
                      ? (e) {
                          if (e.buttons != 0) {
                            point(e.localPosition, size, true);
                          }
                        }
                      : null,
                  onPointerUp: widget.drawMode
                      ? (_) => widget.onStrokeEnd?.call()
                      : null,
                  onPointerCancel: widget.drawMode
                      ? (_) => widget.onStrokeEnd?.call()
                      : null,
                  child: GestureDetector(
                    onTapDown: widget.drawMode
                        ? null
                        : (d) => point(d.localPosition, size, false),
                    child: CustomPaint(
                      size: size,
                      painter: RegionTexturePainter(
                        layout,
                        _images,
                        selection: widget.selection,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class RegionTexturePainter extends CustomPainter {
  final RegionTextureLayout layout;
  final Map<String, ui.Image> images;
  final Offset? selection;
  RegionTexturePainter(this.layout, this.images, {this.selection});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff101d1a),
    );
    canvas.save();
    canvas.scale(
      size.width / (layout.region.width * 16),
      size.height / (layout.region.height * 16),
    );
    final visible = canvas.getLocalClipBounds();
    for (final wall in [true, false]) {
      for (final c in layout.cells.values) {
        if (!visible.overlaps(
          Rect.fromLTWH(c['x']! * 16.0 - 32, c['y']! * 16.0 - 32, 80, 80),
        )) {
          continue;
        }
        if (wall
            ? c['wall'] == 0 || c['invisibleWall'] == 1
            : c['active'] == 0 || c['invisibleBlock'] == 1) {
          continue;
        }
        final f = layout.frame(c, wall: wall),
            image = f == null ? null : images[f.atlas.iconPath];
        if (f == null ||
            image == null ||
            f.source.left < 0 ||
            f.source.top < 0 ||
            f.source.right > image.width ||
            f.source.bottom > image.height) {
          _missing(canvas, c, wall);
          continue;
        }
        canvas.save();
        if (f.shape >= 2) {
          final r = f.destination;
          final points = switch (f.shape) {
            2 => [r.topLeft, r.bottomRight, r.bottomLeft],
            3 => [r.bottomLeft, r.topRight, r.bottomRight],
            4 => [r.topLeft, r.topRight, r.bottomLeft],
            _ => [r.topLeft, r.topRight, r.bottomRight],
          };
          canvas.clipPath(Path()..addPolygon(points, true));
        }
        final paint = Paint()..filterQuality = FilterQuality.none;
        if (!wall && c['inactive'] == 1) paint.color = const Color(0x77ffffff);
        final color = layout.resources?.catalog
            .byId('paints', f.paint)
            ?.fields['color'];
        if (f.paint > 0 &&
            color is Map &&
            color['r'] is int &&
            color['g'] is int &&
            color['b'] is int) {
          paint.colorFilter = ColorFilter.mode(
            Color.fromARGB(
              255,
              color['r'] as int,
              color['g'] as int,
              color['b'] as int,
            ),
            BlendMode.modulate,
          );
        }
        canvas.drawImageRect(image, f.source, f.destination, paint);
        canvas.restore();
      }
    }
    for (final display in layout.displayItems) {
      final rectangle = Rect.fromLTWH(
        display.x * 16.0,
        display.y * 16.0,
        display.width * 16.0,
        display.height * 16.0,
      ).deflate(4);
      if (!visible.overlaps(rectangle)) continue;
      final row = layout.resources?.catalog.byId('items', display.itemId);
      final image = row == null ? null : images[row.iconPath];
      if (image == null) {
        canvas.drawRect(
          rectangle.deflate(3),
          Paint()
            ..color = const Color(0xffd0a271)
            ..style = PaintingStyle.stroke,
        );
        continue;
      }
      final fit = applyBoxFit(
        BoxFit.contain,
        Size(image.width.toDouble(), image.height.toDouble()),
        rectangle.size,
      );
      final destination = Alignment.center.inscribe(fit.destination, rectangle);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        destination,
        Paint()..filterQuality = FilterQuality.none,
      );
    }
    for (final c in layout.cells.values) {
      final x = c['x']! * 16.0, y = c['y']! * 16.0, liquid = c['liquid']!;
      if (liquid > 0) {
        final h = 16 * liquid / 255;
        const colors = [
          Color(0x00000000),
          Color(0x884682e3),
          Color(0x99ff682f),
          Color(0x99db9b2d),
          Color(0x998f73e8),
        ];
        canvas.drawRect(
          Rect.fromLTWH(x, y + 16 - h, 16, h),
          Paint()..color = colors[c['liquidType']!.clamp(0, 4)],
        );
      }
      const wires = [Colors.red, Colors.blue, Colors.green, Colors.yellow];
      for (var bit = 0; bit < 4; bit++) {
        if (c['wires']! & (1 << bit) != 0) {
          final p = Paint()
            ..color = wires[bit]
            ..strokeWidth = 1;
          canvas.drawLine(
            Offset(x, y + 5 + bit * 2),
            Offset(x + 16, y + 5 + bit * 2),
            p,
          );
        }
      }
      if (c['actuator'] == 1) {
        canvas.drawRect(
          Rect.fromLTWH(x + 5, y + 5, 6, 6),
          Paint()
            ..color = Colors.orange
            ..style = PaintingStyle.stroke,
        );
      }
    }
    if (selection != null) {
      canvas.drawRect(
        Rect.fromLTWH(selection!.dx * 16, selection!.dy * 16, 16, 16),
        Paint()
          ..color = const Color(0xff7de5bf)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    canvas.restore();
  }

  void _missing(Canvas canvas, Map<String, int> c, bool wall) {
    final r = Rect.fromLTWH(c['x']! * 16.0, c['y']! * 16.0, 16, 16);
    final p = Paint()
      ..color = wall ? const Color(0xff795b7b) : const Color(0xffd0a271)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    canvas.drawRect(r.deflate(1), p);
    canvas.drawLine(
      r.topLeft + const Offset(3, 3),
      r.bottomRight - const Offset(3, 3),
      p,
    );
    canvas.drawLine(
      r.bottomLeft + const Offset(3, -3),
      r.topRight + const Offset(-3, 3),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant RegionTexturePainter oldDelegate) => true;
}
