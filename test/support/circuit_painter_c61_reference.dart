// Frozen rendering oracle from Live-yum/abc c61d7a1d8c5155515808611fdf2c3b5992b666f3.
// The class/constructor/type name is the only change to the copied painter.
// Keep this implementation independent of the production painter. It records
// the pre-optimization draw order, geometry, colors, labels, and selection.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

class C61CircuitPainter extends CustomPainter {
  final Uint8List bytes;
  final int x, y, width, height;
  final int? selectedX, selectedY;
  final Color selectionColor;
  C61CircuitPainter(
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
  bool shouldRepaint(covariant C61CircuitPainter old) =>
      old.bytes != bytes ||
      old.x != x ||
      old.y != y ||
      old.width != width ||
      old.height != height ||
      old.selectedX != selectedX ||
      old.selectedY != selectedY ||
      old.selectionColor != selectionColor;
}
