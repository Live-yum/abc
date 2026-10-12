import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../diagnostics/host_stage_timings.dart';

typedef ComputerPixelDecoder = void Function(
  Uint8List rgba,
  int width,
  int height,
  void Function(ui.Image) complete,
);

void _decodePixels(
  Uint8List rgba,
  int width,
  int height,
  void Function(ui.Image) complete,
) => ui.decodeImageFromPixels(
  rgba,
  width,
  height,
  ui.PixelFormat.rgba8888,
  complete,
);

/// Pixel-exact presentation of a frame read from the retained wiring engine.
/// Only one image decode can be pending; newer frames replace the pending one.
class ComputerDisplay extends StatefulWidget {
  final Uint8List rgba;
  final HostStageTimings? hostStages;

  /// Injectable completion timing for deterministic ownership/lifecycle tests.
  @visibleForTesting
  final ComputerPixelDecoder decodePixels;
  final int width, height;
  final String label;
  final Color backgroundColor;
  const ComputerDisplay({
    super.key,
    required this.rgba,
    required this.width,
    required this.height,
    required this.label,
    this.hostStages,
    this.backgroundColor = Colors.black,
    this.decodePixels = _decodePixels,
  });

  @override
  State<ComputerDisplay> createState() => _ComputerDisplayState();
}

class _ComputerDisplayState extends State<ComputerDisplay> {
  ui.Image? _image;
  bool _decoding = false;
  int _revision = 0, _identityRevision = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant ComputerDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height ||
        oldWidget.label != widget.label;
    if (identityChanged) {
      _identityRevision++;
      _image?.dispose();
      _image = null;
    }
    if (!identical(oldWidget.rgba, widget.rgba) || identityChanged) {
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
    final revision = _revision, identityRevision = _identityRevision;
    final watch = Stopwatch()..start();
    final timings = widget.hostStages, generation = timings?.generation;
    widget.decodePixels(widget.rgba, widget.width, widget.height, (image) {
      if (timings?.generation == generation) {
        timings?.record(
          'display.imageDecodeCallbackWall',
          watch.elapsedMicroseconds,
        );
      }
      _decoding = false;
      if (!mounted) {
        image.dispose();
        return;
      }
      if (identityRevision != _identityRevision) {
        image.dispose();
        _decode();
        return;
      }
      final previous = _image;
      final publish = Stopwatch()..start();
      setState(() => _image = image);
      timings?.record('display.publishSetState', publish.elapsedMicroseconds);
      previous?.dispose();
      // Publish completed work even if a newer same-monitor frame arrived.
      // One decode stays in flight; intermediate pending frames are coalesced.
      if (revision != _revision) _decode();
    });
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
          color: widget.backgroundColor,
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
