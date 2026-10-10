// One visible painter stage, not a WLD controller or device FPS benchmark.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import '../test/support/circuit_painter_c61_reference.dart';

const _base = 'c61d7a1d8c5155515808611fdf2c3b5992b666f3';
const _fixtureHash =
    'fb159a71b949453a6da80642737c77c48b4b3fa8bba43a0fc00cbb97358f6e9c';
const _columns = 48, _rows = 32, _x = 40, _y = 50;
const _limit = 20000;

Uint8List _fixture() {
  final bytes = Uint8List(_columns * _rows * 16);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < _columns * _rows; i++) {
    final offset = i * 16;
    final flags = (i % 4 == 0 ? 1 : 0) | (i % 17 == 0 ? 2 : 0);
    data.setUint32(offset, _x + i % _columns, Endian.little);
    data.setUint32(offset + 4, _y + i ~/ _columns, Endian.little);
    data.setUint32(
      offset + 8,
      (i % 13) | (flags << 16) | (15 << 24),
      Endian.little,
    );
    data.setInt16(offset + 12, (i % 3) * 18, Endian.little);
  }
  return bytes;
}

class _Invalidations extends ChangeNotifier {
  int count = 0;
  void tick() {
    count++;
    notifyListeners();
  }
}

class _ObservedPainter extends CustomPainter {
  _ObservedPainter(this.delegate, _Invalidations signal)
    : super(repaint: signal);
  final CustomPainter delegate;
  final samples = <Map<String, int>>[];
  bool recording = false;
  int count = 0, dropped = 0;

  @override
  void paint(Canvas canvas, Size size) {
    count++;
    if (!recording) {
      delegate.paint(canvas, size);
      return;
    }
    final start = Timeline.now;
    delegate.paint(canvas, size);
    final elapsed = Timeline.now - start;
    if (samples.length < _limit) {
      samples.add({'startUs': start, 'durationUs': elapsed});
    } else {
      dropped++;
    }
  }

  @override
  bool shouldRepaint(covariant _ObservedPainter oldDelegate) =>
      oldDelegate.delegate != delegate;
}

Future<Map<String, Object?>> _imageProof(ui.Image image) async {
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return {
      'width': image.width,
      'height': image.height,
      'rgbaSha256': sha256.convert(Uint8List.sublistView(bytes)).toString(),
    };
  } finally {
    image.dispose();
  }
}

Future<Map<String, Object?>> _oracleProof(
  CustomPainter painter,
  Size size,
) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  try {
    return await _imageProof(
      await picture.toImage(size.width.ceil(), size.height.ceil()),
    );
  } finally {
    picture.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bounded visible generic circuit painter profile', (
    tester,
  ) async {
    expect(
      kProfileMode,
      isTrue,
      reason: 'An official profile build is required.',
    );
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final arm = Platform.environment['ABC_PAINTER_ARM'];
    final width = int.parse(Platform.environment['ABC_PAINTER_WIDTH']!);
    final height = int.parse(Platform.environment['ABC_PAINTER_HEIGHT']!);
    expect(['A', 'B'], contains(arm));
    expect([(1440, 1000), (390, 844)], contains((width, height)));
    final bytes = _fixture();
    expect(sha256.convert(bytes).toString(), _fixtureHash);
    final signal = _Invalidations();
    _ObservedPainter? observed;
    Timer? timer;
    var collectFrames = false;
    final frames = <FrameTiming>[];
    var droppedFrames = 0;
    void receive(List<FrameTiming> batch) {
      if (!collectFrames) return;
      for (final frame in batch) {
        if (frames.length < _limit) {
          frames.add(frame);
        } else {
          droppedFrames++;
        }
      }
    }

    final report = <String, Object?>{
      'schema': 'abc.circuit-painter-profile.v1',
      'status': 'failed',
      'scenario': 'visible-generic-circuit-painter',
      'referenceCommit': _base,
      'sourceCommit': const String.fromEnvironment('PAINTER_SOURCE_COMMIT'),
      'sourceManifestSha256': const String.fromEnvironment(
        'PAINTER_SOURCE_MANIFEST_SHA256',
      ),
      'renderer': const String.fromEnvironment('PAINTER_RENDERER'),
      'arm': arm,
      'buildMode': 'profile',
      'scene': {
        'width': width,
        'height': height,
        'dpr': 1,
        'columns': _columns,
        'rows': _rows,
      },
      'fixture': {
        'sha256': _fixtureHash,
        'bytes': bytes.length,
        'records': _columns * _rows,
        'wireMask': 15,
      },
      'invalidationPeriodUs': 16000,
      'limits': [
        'Visible rendering microbenchmark; no world engine or controller throughput.',
        '390px is a Linux window layout, not a mobile hardware result.',
        'Frame callbacks and invalidations are not displayed-frame or FPS measurements.',
        'No RSS, heap or allocation snapshots; constructor reduction is a source-level claim.',
        'The same shared paint timing instrumentation runs in both arms.',
        'No forced pumps or image reads during the steady measurement window.',
        'A two-second callback drain does not prove delivery of every engine frame.',
      ],
    };
    var stage = 'actual-window';
    try {
      // Render a first frame so GTK exposes its window. The host runner resizes
      // that owned X11 window; no TestFlutterView or surface-size override is used.
      await tester.pumpWidget(
        MaterialApp(
          theme: terraTheme(),
          home: const Text('Preparing circuit scene'),
        ),
      );
      final waiting = Stopwatch()..start();
      while (tester.view.physicalSize !=
              Size(width.toDouble(), height.toDouble()) ||
          tester.view.devicePixelRatio != 1) {
        if (waiting.elapsed > const Duration(seconds: 20)) {
          fail(
            'The actual Flutter window never reached the requested size/DPR.',
          );
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      stage = 'production-painter';
      await tester.pumpWidget(
        MaterialApp(
          theme: terraTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: WorldCircuitPanel(
                  state: {
                    'open': true,
                    'busy': false,
                    'dirty': false,
                    'width': 600,
                    'height': 400,
                    'optimizationEnabled': false,
                    'optimizationSupported': true,
                    'records': bytes,
                    'viewport': {
                      'x': _x,
                      'y': _y,
                      'width': _columns,
                      'height': _rows,
                    },
                  },
                  dispatch: (action, args) async {
                    fail('A painter scene must not send an engine command.');
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final wiring = find.bySemanticsLabel('实际世界电路视口，点击选择设备或线路');
      await Scrollable.ensureVisible(tester.element(wiring), alignment: .5);
      await tester.pumpAndSettle();
      final sourcePaint = find.descendant(
        of: wiring,
        matching: find.byType(CustomPaint),
      );
      expect(sourcePaint, findsOneWidget);
      final size = tester.getSize(sourcePaint);
      final sourceRect = tester.getRect(sourcePaint);
      expect(sourceRect.left, greaterThanOrEqualTo(0));
      expect(sourceRect.top, greaterThanOrEqualTo(0));
      expect(sourceRect.right, lessThanOrEqualTo(width.toDouble()));
      expect(sourceRect.bottom, lessThanOrEqualTo(height.toDouble()));
      final production = tester.widget<CustomPaint>(sourcePaint).painter!;
      final reference = C61CircuitPainter(
        bytes,
        _x,
        _y,
        _columns,
        _rows,
        selectionColor: TerraColors.mint,
      );
      report['productionPainterType'] = production.runtimeType.toString();
      report['productionCanvas'] = [
        sourceRect.left,
        sourceRect.top,
        size.width,
        size.height,
      ];
      const canvasKey = ValueKey('visible-painter-profile-canvas');
      final probe = _ObservedPainter(
        arm == 'A' ? reference : production,
        signal,
      );
      observed = probe;
      await tester.pumpWidget(
        MaterialApp(
          theme: terraTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  key: canvasKey,
                  child: CustomPaint(size: size, painter: probe),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final canvas = find.byKey(canvasKey);
      Map<String, Object?> viewport() {
        final rect = tester.getRect(canvas);
        final physical = tester.view.physicalSize;
        final dpr = tester.view.devicePixelRatio;
        expect(physical, Size(width.toDouble(), height.toDouble()));
        expect(dpr, 1);
        expect(rect.size, size);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(physical.width / dpr));
        expect(rect.bottom, lessThanOrEqualTo(physical.height / dpr));
        return {
          'surfaceWidth': physical.width / dpr,
          'surfaceHeight': physical.height / dpr,
          'dpr': dpr,
          'left': rect.left,
          'top': rect.top,
          'width': rect.width,
          'height': rect.height,
        };
      }

      Future<Map<String, Object?>> capture() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(canvas);
        return (await tester.runAsync(
          () async => _imageProof(await boundary.toImage(pixelRatio: 1)),
        ))!;
      }

      report['viewportBefore'] = viewport();
      final oracle = (await tester.runAsync(
        () => _oracleProof(reference, size),
      ))!;
      final before = await capture();
      expect(
        before,
        oracle,
        reason: 'The actual visible canvas must match c61 before measurement.',
      );
      report['oracleRgbaSha256'] = oracle['rgbaSha256'];
      report['pixelsBefore'] = before;

      stage = 'warmup';
      final warmup = Stopwatch()..start();
      await tester.runAsync(() async {
        timer = Timer.periodic(
          const Duration(milliseconds: 16),
          (_) => signal.tick(),
        );
        await Future<void>.delayed(const Duration(seconds: 5));
      });
      report['warmup'] = {'elapsedUs': warmup.elapsedMicroseconds};
      SchedulerBinding.instance.addTimingsCallback(receive);
      collectFrames = true;
      final invalidationsBefore = signal.count, paintsBefore = probe.count;
      final start = Timeline.now;
      probe.recording = true;
      stage = 'steady';
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 20)),
      );
      final end = Timeline.now;
      probe.recording = false;
      timer?.cancel();
      final invalidations = signal.count - invalidationsBefore;
      final paintCount = probe.count - paintsBefore;
      report['window'] = {
        'startUs': start,
        'endUs': end,
        'elapsedUs': end - start,
        'invalidations': invalidations,
        'paints': paintCount,
      };
      stage = 'drain';
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      collectFrames = false;
      SchedulerBinding.instance.removeTimingsCallback(receive);
      await tester.pump();
      report['viewportAfter'] = viewport();
      final after = await capture();
      expect(
        after,
        before,
        reason: 'The scene must remain pixel-identical after measurement.',
      );
      report['pixelsAfter'] = after;
      expect(invalidations, greaterThan(0));
      expect(paintCount, greaterThan(0));
      expect(paintCount, probe.samples.length);
      expect(probe.dropped, 0);
      expect(droppedFrames, 0);
      report['droppedPaints'] = probe.dropped;
      report['droppedFrames'] = droppedFrames;
      report['paints'] = probe.samples;
      report['frames'] = [
        for (final frame in frames)
          {
            'frameNumber': frame.frameNumber,
            'vsyncStartUs': frame.timestampInMicroseconds(
              ui.FramePhase.vsyncStart,
            ),
            'inWindow':
                frame.timestampInMicroseconds(ui.FramePhase.vsyncStart) >= start &&
                frame.timestampInMicroseconds(ui.FramePhase.vsyncStart) < end,
            'buildUs': frame.buildDuration.inMicroseconds,
            'rasterUs': frame.rasterDuration.inMicroseconds,
            'totalSpanUs': frame.totalSpan.inMicroseconds,
          },
      ];
      final selected = frames.where((frame) {
        final at = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
        return at >= start && at < end;
      }).toList();
      expect(selected, isNotEmpty);
      expect(
        selected.map((frame) => frame.frameNumber).toSet().length,
        selected.length,
      );
      report['windowFrameCount'] = selected.length;
      expect(tester.takeException(), isNull);
      report['status'] = 'success';
    } catch (error, stack) {
      report['failure'] = error.toString();
      report['failureStack'] = stack.toString();
      rethrow;
    } finally {
      timer?.cancel();
      if (observed != null) observed.recording = false;
      collectFrames = false;
      SchedulerBinding.instance.removeTimingsCallback(receive);
      report['lastStage'] = stage;
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        signal.dispose();
        report['cleanup'] = 'disposed';
      } finally {
        binding.reportData = report;
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
