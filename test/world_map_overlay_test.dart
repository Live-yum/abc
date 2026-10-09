import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/world_map_overlay.dart';
import 'package:terraforge/ui/world_map_view.dart';

Uint8List records(
  int width,
  int height, {
  int wires = 0,
  int amount = 0,
  int kind = 0,
}) {
  final data = ByteData(width * height * 32);
  for (var x = 0; x < width; x++) {
    for (var y = 0; y < height; y++) {
      final at = (x * height + y) * 32;
      data.setUint32(at, x, Endian.little);
      data.setUint32(at + 4, y, Endian.little);
      data.setUint32(
        at + 20,
        amount | (kind << 8) | (wires << 24),
        Endian.little,
      );
    }
  }
  return data.buffer.asUint8List();
}

WorldMapOverlay snapshot(
  Uint8List data, {
  int x = 0,
  int y = 0,
  int width = 1,
  int height = 1,
}) => WorldMapOverlay.fromRecords(
  x: x,
  y: y,
  width: width,
  height: height,
  records: data,
);

void main() {
  test(
    'complete immutable snapshot preserves ABI, coordinates, masks and counts',
    () {
      final bytes = records(2, 2, wires: 15, amount: 127, kind: 4);
      final data = ByteData.sublistView(bytes);
      data.setUint32(20, 255 | (1 << 8) | (1 << 24), Endian.little);
      final overlay = snapshot(bytes, x: 5, y: 6, width: 2, height: 2);
      expect(overlay.wireMasks, [1, 15, 15, 15]);
      expect(overlay.liquidAmounts, [255, 127, 127, 127]);
      expect(overlay.liquidKinds, [1, 4, 4, 4]);
      expect(overlay.wireCounts, [4, 3, 3, 3]);
      expect(overlay.liquidCounts, [1, 0, 0, 3]);
      expect(overlay.wiredCellCount, 4);
      expect(overlay.liquidCellCount, 4);
      expect(
        [overlay.x, overlay.y, overlay.width, overlay.height],
        [5, 6, 2, 2],
      );
      bytes.fillRange(0, bytes.length, 0);
      expect(overlay.wireMasks.first, 1);
      expect(() => overlay.wireMasks[0] = 0, throwsUnsupportedError);
      expect(() => overlay.wireCounts[0] = 0, throwsUnsupportedError);
    },
  );

  test('column-major records become row-major cells without invented data', () {
    final bytes = records(2, 3);
    ByteData.sublistView(bytes).setUint32(32 + 20, 8 << 24, Endian.little);
    final overlay = snapshot(bytes, width: 2, height: 3);
    expect(overlay.wireMasks, [0, 0, 8, 0, 0, 0]);
    expect(overlay.liquidCounts, [0, 0, 0, 0]);
  });

  test(
    'rejects malformed lengths, coordinates, duplicates and region bounds',
    () {
      for (final bytes in [
        Uint8List(0),
        Uint8List(31),
        Uint8List(33),
        Uint8List(64),
      ]) {
        expect(() => snapshot(bytes), throwsFormatException);
      }
      for (final bounds in [
        [-1, 0, 1, 1],
        [0, -1, 1, 1],
        [0, 0, 0, 1],
        [0, 0, 1, -1],
        [0, 0, 513, 512],
        [0x7fffffff, 0, 1, 1],
      ]) {
        expect(
          () => snapshot(
            records(1, 1),
            x: bounds[0],
            y: bounds[1],
            width: bounds[2],
            height: bounds[3],
          ),
          throwsFormatException,
        );
      }
      final outside = records(1, 1);
      ByteData.sublistView(outside).setUint32(0, 1, Endian.little);
      expect(() => snapshot(outside), throwsFormatException);
      final duplicate = records(2, 1);
      ByteData.sublistView(duplicate).setUint32(32, 0, Endian.little);
      expect(() => snapshot(duplicate, width: 2), throwsFormatException);
    },
  );

  test('rejects invalid layer bits, liquid consistency and reserved words', () {
    for (final bad in [
      records(1, 1, wires: 16),
      records(1, 1, amount: 1),
      records(1, 1, kind: 1),
      records(1, 1, amount: 1, kind: 5),
    ]) {
      expect(() => snapshot(bad), throwsFormatException);
    }
    for (final offset in [24, 28]) {
      final bytes = records(1, 1);
      ByteData.sublistView(bytes).setUint32(offset, 1, Endian.little);
      expect(() => snapshot(bytes), throwsFormatException);
    }
  });

  test('accepts exact budget and all four liquid kinds', () {
    final overlay = snapshot(records(512, 512), width: 512, height: 512);
    expect(overlay.cellCount, WorldMapOverlay.maxCells);
    for (var kind = 1; kind <= 4; kind++) {
      expect(
        snapshot(records(1, 1, kind: kind, amount: 1)).liquidKinds.single,
        kind,
      );
    }
  });

  test('viewport inverse transform handles letterboxing, pan and empty intersection', () {
    final controller = TransformationController();
    Rect visible() => visibleWorldMapTiles(
      viewport: const Size(400, 300),
      mapRect: const Rect.fromLTWH(0, 50, 400, 200),
      transform: controller,
      worldWidth: 1000,
      worldHeight: 500,
    );
    expect(visible(), const Rect.fromLTWH(0, 0, 1000, 500));
    controller.value = Matrix4.identity()
      ..translateByDouble(-200, -100, 0, 1)
      ..scaleByDouble(2, 2, 1, 1);
    expect(visible(), const Rect.fromLTWH(250, 0, 500, 375));
    controller.value = Matrix4.identity()..translateByDouble(2000, 2000, 0, 1);
    expect(visible().isEmpty, true);
    controller.dispose();
  });

  test(
    'painter maps world offset and partial liquid height to exact pixels',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final overlay = snapshot(records(1, 1, amount: 128, kind: 1), x: 1, y: 1);
      WorldMapOverlayPainter(
        overlay: overlay,
        mapRect: const Rect.fromLTWH(10, 10, 40, 40),
        worldWidth: 2,
        worldHeight: 2,
        wireMask: 0,
        showLiquids: true,
      ).paint(canvas, const Size(60, 60));
      final picture = recorder.endRecording();
      final image = await picture.toImage(60, 60);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int alpha(int x, int y) => pixels.getUint8((y * 60 + x) * 4 + 3);
      expect(alpha(35, 35), 0);
      expect(alpha(35, 45), 0xbb);
      expect(alpha(25, 45), 0);
      expect(alpha(51, 45), 0);
      image.dispose();
      picture.dispose();
    },
  );

  test('painter keeps all wire lanes distinct and applies masks', () async {
    final recorder = ui.PictureRecorder();
    final painter = WorldMapOverlayPainter(
      overlay: snapshot(records(1, 1, wires: 15)),
      mapRect: const Rect.fromLTWH(0, 0, 40, 40),
      worldWidth: 1,
      worldHeight: 1,
      wireMask: 5,
      showLiquids: false,
    );
    painter.paint(Canvas(recorder), const Size(40, 40));
    final picture = recorder.endRecording();
    final image = await picture.toImage(40, 40);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    int alpha(int y) => pixels.getUint8((y * 40 + 20) * 4 + 3);
    expect(alpha(5), 255);
    expect(alpha(15), 0);
    expect(alpha(25), 255);
    expect(alpha(35), 0);
    image.dispose();
    picture.dispose();
  });

  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9uoAAAAASUVORK5CYII=',
  );
  testWidgets(
    '390px controls fit; loading is explicit, bounded and disabled while busy',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <List<int>>[];
      Widget app({
        int width = 100,
        bool busy = false,
        WorldMapOverlay? overlay,
      }) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldMapView(
              png: png,
              worldWidth: width,
              worldHeight: 100,
              overlay: overlay,
              overlayBusy: busy,
              onLoadOverlay: (x, y, w, h) => calls.add([x, y, w, h]),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pump();
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('world-map-load-overlay')));
      expect(calls, [
        [0, 0, 100, 100],
      ]);
      await tester.tap(find.byKey(const ValueKey('world-map-wire-0')));
      expect(calls.length, 1);
      await tester.pumpWidget(app(busy: true));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('world-map-load-overlay')),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(app(width: 10000));
      await tester.tap(find.byKey(const ValueKey('world-map-load-overlay')));
      await tester.pump();
      expect(find.textContaining('请放大地图'), findsOneWidget);
      expect(calls.length, 1);
      await tester.pumpWidget(app(overlay: snapshot(records(1, 1, wires: 1))));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('world-map-overlay-painter')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
