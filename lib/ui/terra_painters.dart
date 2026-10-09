import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'terra_contract.dart';
import 'terra_theme.dart';

/// Original procedural illustration. Never represents a parsed game world.
class LandscapePainter extends CustomPainter {
  const LandscapePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    canvas.drawRect(
      Offset.zero & size,
      p
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xff244c59), Color(0xff7eaa9c), Color(0xff243a37)],
        ).createShader(Offset.zero & size),
    );
    p.shader = null;
    final sx = size.width / 120, sy = size.height / 70;
    void block(double x, double y, double w, double h, int c) {
      canvas.drawRect(
        Rect.fromLTWH(x * sx, y * sy, w * sx, h * sy),
        p..color = Color(c),
      );
    }

    block(91, 9, 8, 8, 0xffd8d5a2);
    block(89, 11, 12, 4, 0xffd8d5a2);
    for (var layer = 0; layer < 3; layer++) {
      final colors = [0xff436e6d, 0xff33584f, 0xff25483c];
      for (var x = 0; x < 120; x += 3) {
        final top =
            25 +
            layer * 7 +
            math.sin(x * .08 + layer * 2) * 7 +
            math.sin(x * .23) * 2;
        block(x.toDouble(), top, 3, 70 - top, colors[layer]);
      }
    }
    final rng = math.Random(42);
    for (var x = 0; x < 120; x += 2) {
      final top = 49 + math.sin(x * .07) * 4 + math.sin(x * .19) * 2;
      block(x.toDouble(), top, 2, 70 - top, 0xff655440);
      block(x.toDouble(), top, 2, 2, 0xff8aaa69);
      for (var y = top.toInt() + 4; y < 70; y += 3) {
        if (rng.nextBool()) block(x.toDouble(), y.toDouble(), 2, 2, 0xff746047);
      }
    }
    for (final x in [8, 18, 31, 77, 91, 107]) {
      final y = 49 + math.sin(x * .07) * 4;
      block(x.toDouble(), y - 16, 2, 16, 0xff675640);
      block(x - 5.0, y - 19, 12, 8, 0xff416d46);
      block(x - 3.0, y - 23, 8, 5, 0xff5d8752);
      block(x - 7.0, y - 15, 16, 5, 0xff4b7749);
    }
    block(43, 36, 25, 15, 0xff655547);
    block(45, 38, 21, 12, 0xffb39768);
    block(41, 34, 29, 3, 0xff414d58);
    block(44, 31, 23, 3, 0xff4b5760);
    block(48, 28, 15, 3, 0xff53636b);
    block(47, 40, 5, 5, 0xffe3c485);
    block(60, 40, 4, 5, 0xffe3c485);
    block(54, 43, 4, 8, 0xff5b4739);
    block(53, 42, 6, 1, 0xff786147);
    block(0, 66, 120, 4, 0xff233231);
  }

  @override
  bool shouldRepaint(covariant LandscapePainter oldDelegate) => false;
}

class GridCanvas extends StatelessWidget {
  final TerraCanvas data;
  final bool grid;
  final double zoom;
  final List<Map<String, Object?>> circuitCells;
  final Set<int> trace;
  final void Function(int, int)? onPoint;
  final VoidCallback? onStart, onEnd;
  const GridCanvas({
    super.key,
    required this.data,
    this.grid = true,
    this.zoom = 1,
    this.circuitCells = const [],
    this.trace = const {},
    this.onPoint,
    this.onStart,
    this.onEnd,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final ratio = data.width / data.height;
      final width = math.min(c.maxWidth, 900.0),
          height = (width / ratio).clamp(180.0, 520.0);
      return SizedBox(
        height: height,
        child: InteractiveViewer(
          panEnabled: onPoint == null,
          scaleEnabled: onPoint == null,
          minScale: .5,
          maxScale: 8,
          child: Center(
            child: AspectRatio(
              aspectRatio: ratio,
              child: LayoutBuilder(
                builder: (context, box) {
                  void point(Offset p) {
                    final x = (p.dx / box.maxWidth * data.width).floor().clamp(
                          0,
                          data.width - 1,
                        ),
                        y = (p.dy / box.maxHeight * data.height).floor().clamp(
                          0,
                          data.height - 1,
                        );
                    onPoint?.call(x, y);
                  }

                  return MouseRegion(
                    cursor: onPoint == null
                        ? SystemMouseCursors.grab
                        : SystemMouseCursors.precise,
                    child: GestureDetector(
                      onTapDown: onPoint == null
                          ? null
                          : (d) {
                              onStart?.call();
                              point(d.localPosition);
                            },
                      onTapUp: onPoint == null ? null : (_) => onEnd?.call(),
                      onPanStart: onPoint == null
                          ? null
                          : (d) {
                              onStart?.call();
                              point(d.localPosition);
                            },
                      onPanUpdate: onPoint == null
                          ? null
                          : (d) => point(d.localPosition),
                      onPanEnd: onPoint == null ? null : (_) => onEnd?.call(),
                      child: CustomPaint(
                        painter: TilePainter(
                          data,
                          grid,
                          circuitCells: circuitCells,
                          trace: trace,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

class TilePainter extends CustomPainter {
  final TerraCanvas data;
  final bool grid;
  final List<Map<String, Object?>> circuitCells;
  final Set<int> trace;
  TilePainter(
    this.data,
    this.grid, {
    this.circuitCells = const [],
    this.trace = const {},
  });
  @override
  void paint(Canvas c, Size s) {
    final p = Paint();
    final w = s.width / data.width, h = s.height / data.height;
    c.drawRect(Offset.zero & s, p..color = const Color(0xff132833));
    for (var y = 0; y < data.height; y++) {
      for (var x = 0; x < data.width; x++) {
        final i = y * data.width + x;
        if (i >= data.colors.length) continue;
        p.color = Color(data.colors[i]);
        c.drawRect(Rect.fromLTWH(x * w, y * h, w + .1, h + .1), p);
      }
    }
    if (grid && w > 4 && h > 4) {
      p
        ..color = Colors.black.withValues(alpha: .2)
        ..strokeWidth = .5;
      for (var x = 0; x <= data.width; x++) {
        c.drawLine(Offset(x * w, 0), Offset(x * w, s.height), p);
      }
      for (var y = 0; y <= data.height; y++) {
        c.drawLine(Offset(0, y * h), Offset(s.width, y * h), p);
      }
    }
    for (final cell in circuitCells) {
      final at = cell['at'];
      if (at is! int || at < 0 || at >= data.width * data.height) continue;
      final x = at % data.width, y = at ~/ data.width;
      final center = Offset((x + .5) * w, (y + .5) * h),
          rect = Rect.fromLTWH(x * w + 1, y * h + 1, w - 2, h - 2);
      final wires = cell['wires'] is int ? cell['wires'] as int : 0;
      for (var bit = 0; bit < 4; bit++) {
        if ((wires & (1 << bit)) != 0) {
          p
            ..color = const [
              Color(0xffed796f),
              Color(0xff75acdf),
              Color(0xff7ecf97),
              Color(0xffead16c),
            ][bit]
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.0, w * .09);
          final dy = (bit - 1.5) * h * .12;
          c.drawLine(
            Offset(x * w, center.dy + dy),
            Offset((x + 1) * w, center.dy + dy),
            p,
          );
          c.drawLine(
            Offset(center.dx + dy, y * h),
            Offset(center.dx + dy, (y + 1) * h),
            p,
          );
        }
      }
      final element = '${cell['element'] ?? 'none'}';
      if (element != 'none') {
        p
          ..style = PaintingStyle.fill
          ..color = cell['on'] == true
              ? const Color(0xffd9c379)
              : const Color(0xff415764);
        c.drawRRect(
          RRect.fromRectAndRadius(
            rect.deflate(math.min(w, h) * .08),
            const Radius.circular(3),
          ),
          p,
        );
        final label =
            const {
              'switchInput': 'S',
              'lamp': 'L',
              'timer': 'T',
              'andGate': '&',
              'orGate': '≥1',
              'xorGate': '=1',
            }[element] ??
            '?';
        final text = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: cell['on'] == true
                  ? const Color(0xff263128)
                  : Colors.white,
              fontSize: math.min(w, h) * .52,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: w);
        text.paint(c, center - Offset(text.width / 2, text.height / 2));
      }
      if (trace.contains(at)) {
        c.drawRect(
          rect,
          p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = TerraColors.mint,
        );
      }
      p.style = PaintingStyle.fill;
    }
    c.drawRect(
      Offset.zero & s,
      p
        ..style = PaintingStyle.stroke
        ..color = TerraColors.mint.withValues(alpha: .45)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant TilePainter oldDelegate) => true;
}
