import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:terraforge/domain/region_document.dart';
import 'package:terraforge/domain/fusion_placement.dart';
import 'package:terraforge/platform/resource_store.dart';
import 'package:terraforge/ui/region_texture_canvas.dart';

import 'resource_store_test.dart' as fixture;
import 'support/fusion_placement_fixture.dart' as placement;

AdvancedRegionDocument region({
  int tile = 21,
  int fx = 0,
  int fy = 0,
  int shape = 0,
  int wall = 0,
}) {
  final d = ByteData(32)
    ..setUint32(8, tile | (1 << 16), Endian.little)
    ..setUint32(12, fx | (fy << 16), Endian.little)
    ..setUint32(16, wall, Endian.little)
    ..setUint32(20, shape << 16, Endian.little);
  return AdvancedRegionDocument(
    width: 1,
    height: 1,
    records: d.buffer.asUint8List(),
  );
}

ResourceStore synthetic() {
  final pixels = img.Image(width: 256, height: 180, numChannels: 4);
  for (var y = 0; y < pixels.height; y++) {
    for (var x = 0; x < pixels.width; x++) {
      pixels.setPixelRgba(x, y, x, y, 200, 255);
    }
  }
  final png = img.encodePng(pixels), path = 'images/${sha256.convert(png)}.png';
  return ResourceStore.importPack(
    fixture.pack({
      path: png,
      'catalog/tile-atlases.json': utf8.encode(
        jsonEncode([
          {'id': 21, 'icon': path, 'frameImportant': true},
          {
            'id': 0,
            'icon': path,
            'ordinaryFrames': true,
            'frameImportant': false,
          },
        ]),
      ),
      'catalog/wall-atlases.json': utf8.encode(
        jsonEncode([
          {'id': 1, 'icon': path},
        ]),
      ),
      'catalog/tile-object-data.json': utf8.encode(
        jsonEncode([
          {
            'id': '21:0',
            'tile': 21,
            'frameX': 0,
            'frameY': 0,
            'width': 2,
            'height': 2,
            'coordinateWidth': 16,
            'coordinatePadding': 2,
            'coordinateHeights': [16, 18],
          },
        ]),
      ),
    }),
  );
}

Future<ui.Image> decode(Uint8List data) async {
  final c = await ui.instantiateImageCodec(data);
  final f = await c.getNextFrame();
  c.dispose();
  return f.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('display-frame contents render the imported item icon separately from furniture', () async {
    final document = placement.blankRegion();
    FusionPlacementPlan.preview(
      document: document,
      brush: FusionPlacementCatalog(placement.placementCatalog())
          .brush(1000, display: true),
      x: 2,
      y: 1,
      worldVersion: 326,
    ).apply(document);
    final pixels = img.Image(width: 4, height: 4, numChannels: 4);
    img.fill(pixels, color: img.ColorRgba8(255, 0, 255, 255));
    final png = img.encodePng(pixels),
        path = 'images/${sha256.convert(png)}.png';
    final store = ResourceStore.importPack(
      fixture.pack({
        path: png,
        'catalog/items.json': utf8.encode(
          jsonEncode([
            {'id': 1000, 'name': 'Original test icon', 'icon': path},
          ]),
        ),
      }),
    );
    final layout = RegionTextureLayout(document, store);
    expect(layout.displayItems.single.itemId, 1000);
    final icon = await decode(png), recorder = ui.PictureRecorder();
    RegionTexturePainter(layout, {
      path: icon,
    }).paint(Canvas(recorder), const Size(96, 80));
    final picture = recorder.endRecording(),
        out = await picture.toImage(96, 80);
    final bytes = (await out.toByteData())!;
    expect(bytes.getUint32((32 * 96 + 48) * 4), 0xff00ffff);
    out.dispose();
    picture.dispose();
    icon.dispose();
  });
  test(
    'multi-cell furniture selects stored frame with original row height',
    () {
      final l = RegionTextureLayout(region(fx: 18, fy: 18), synthetic());
      final f = l.frame(l.cells.values.single)!;
      expect(f.source, const Rect.fromLTWH(18, 18, 16, 18));
      expect(f.destination, const Rect.fromLTWH(0, 0, 16, 18));
      expect(f.approximate, false);
    },
  );
  test(
    'unknown important frames are marked missing rather than frame zero',
    () {
      final l = RegionTextureLayout(region(fx: 99), synthetic());
      expect(l.frame(l.cells.values.single), null);
    },
  );
  test(
    'ordinary frame and half-block preserve atlas crop; walls expand behind',
    () {
      final l = RegionTextureLayout(
            region(tile: 0, shape: 1, wall: 1),
            synthetic(),
          ),
          c = l.cells.values.single;
      expect(l.frame(c)!.source, const Rect.fromLTWH(162, 54, 16, 8));
      expect(l.frame(c)!.destination, const Rect.fromLTWH(0, 8, 16, 8));
      expect(
        l.frame(c, wall: true)!.source,
        const Rect.fromLTWH(324, 108, 32, 32),
      );
      expect(
        l.frame(c, wall: true)!.destination,
        const Rect.fromLTWH(-8, -8, 32, 32),
      );
    },
  );
  test(
    'rendered synthetic crop equals exact source pixels, not repeated icon',
    () async {
      final store = synthetic(),
          l = RegionTextureLayout(region(fx: 18), store),
          f = l.frame(l.cells.values.single)!;
      final source = await decode(store.iconBytes(f.atlas)!);
      final recorder = ui.PictureRecorder();
      RegionTexturePainter(l, {
        f.atlas.iconPath!: source,
      }).paint(Canvas(recorder), const Size(16, 16));
      final picture = recorder.endRecording(),
          out = await picture.toImage(16, 16);
      final rgba = (await out.toByteData())!,
          src = (await source.toByteData())!;
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          expect(
            rgba.getUint32((y * 16 + x) * 4),
            src.getUint32((y * source.width + x + 18) * 4),
          );
        }
      }
      out.dispose();
      picture.dispose();
      source.dispose();
    },
  );
  test(
    'private reference atlas crop matches source cell without publishing bytes',
    () async {
      final path = Platform.environment['ABC_PRIVATE_PACK'];
      if (path == null) return;
      final store = ResourceStore.importPack(await File(path).readAsBytes());
      expect(store.catalog.families['tile-atlases']!.length, greaterThan(700));
      final l = RegionTextureLayout(region(tile: 0), store),
          f = l.frame(l.cells.values.single)!;
      final source = await decode(store.iconBytes(f.atlas)!);
      final recorder = ui.PictureRecorder();
      RegionTexturePainter(l, {
        f.atlas.iconPath!: source,
      }).paint(Canvas(recorder), const Size(16, 16));
      final picture = recorder.endRecording(),
          out = await picture.toImage(16, 16);
      final rgba = (await out.toByteData())!,
          src = (await source.toByteData())!;
      var opaque = 0;
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          final at = ((y + 54) * source.width + x + 162) * 4;
          if (src.getUint8(at + 3) == 255) {
            opaque++;
            expect(rgba.getUint32((y * 16 + x) * 4), src.getUint32(at));
          }
        }
      }
      expect(opaque, greaterThan(150));
      out.dispose();
      picture.dispose();
      source.dispose();
    },
  );
}
