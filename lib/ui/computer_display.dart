import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Pixel-exact presentation of a frame read from the retained wiring engine.
/// Only one image decode can be pending; newer frames replace the pending one.
class ComputerDisplay extends StatefulWidget {
  final Uint8List rgba;
  final int width, height;
  final String label;
  const ComputerDisplay({
    super.key,
    required this.rgba,
    required this.width,
    required this.height,
    required this.label,
  });

  @override
  State<ComputerDisplay> createState() => _ComputerDisplayState();
}

class _ComputerDisplayState extends State<ComputerDisplay> {
  ui.Image? _image;
  bool _decoding = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant ComputerDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.rgba, widget.rgba) ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _revision++;
      _decode();
    }
  }

  void _decode() {
    if (_decoding || !mounted) return;
    if (widget.width < 1 ||
        widget.height < 1 ||
        widget.width > 256 ||
        widget.height > 256 ||
        widget.rgba.length != widget.width * widget.height * 4) {
      final previous = _image;
      _image = null;
      previous?.dispose();
      return;
    }
    _decoding = true;
    final revision = _revision;
    ui.decodeImageFromPixels(
      widget.rgba,
      widget.width,
      widget.height,
      ui.PixelFormat.rgba8888,
      (image) {
        _decoding = false;
        if (!mounted) {
          image.dispose();
          return;
        }
        if (revision != _revision) {
          image.dispose();
          _decode();
          return;
        }
        final previous = _image;
        setState(() => _image = image);
        previous?.dispose();
      },
    );
  }

  @override
  void dispose() {
    _revision++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.label,
    image: true,
    child: RepaintBoundary(
      child: AspectRatio(
        aspectRatio: widget.width > 0 && widget.height > 0
            ? widget.width / widget.height
            : 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: RawImage(
            image: _image,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.none,
            isAntiAlias: false,
          ),
        ),
      ),
    ),
  );
}
