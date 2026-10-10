import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import 'support/circuit_painter_c61_reference.dart';

const _worldX = 40, _worldY = 50;

Uint8List _records(int width, int height) {
  // Four complete out-of-bounds records and an incomplete final record prove
  // that filtering and the record boundary remain independent of Paint reuse.
  final bytes = Uint8List((width * height + 4) * 16 + 7);
  final data = ByteData.sublistView(bytes);
  void record(int index, int x, int y, int type, int flags, int wires) {
    final offset = index * 16;
    data.setUint32(offset, x, Endian.little);
    data.setUint32(offset + 4, y, Endian.little);
    data.setUint32(
      offset + 8,
      type | (flags << 16) | (wires << 24),
      Endian.little,
    );
    data.setInt16(offset + 12, (index % 5 - 2) * 18, Endian.little);
    data.setInt16(offset + 14, (index % 7 - 3) * 18, Endian.little);
  }

  for (var index = 0; index < width * height; index++) {
    record(
      index,
      _worldX + index % width,
      _worldY + index ~/ width,
      index * 7 % 701,
      (index * 5 + index ~/ 16) % 8,
      index % 16,
    );
  }
  final count = width * height;
  record(count, _worldX - 1, _worldY, 144, 7, 15);
  record(count + 1, _worldX, _worldY - 1, 144, 7, 15);
  record(count + 2, _worldX + width, _worldY, 144, 7, 15);
  record(count + 3, _worldX, _worldY + height, 144, 7, 15);
  bytes.fillRange(bytes.length - 7, bytes.length, 255);
  return bytes;
}

Future<({Uint8List rgba, Uint8List? png})> _raster(
  CustomPainter painter,
  Size size, {
  required bool capturePng,
}) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    try {
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final png = capturePng
          ? await image.toByteData(format: ui.ImageByteFormat.png)
          : null;
      return (
        rgba: Uint8List.sublistView(rgba),
        png: png == null ? null : Uint8List.sublistView(png),
      );
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['ABC_CIRCUIT_PAINTER_DIR'] ?? '';
  final capturePng = output.isNotEmpty;
  final fontEvidence = <String, String>{};
  setUpAll(() async {
    for (final entry in const {
      terraFontFamily: 'assets/fonts/TerraForgeCJK-Regular.otf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final bytes = await rootBundle.load(entry.value);
      fontEvidence[entry.value] = sha256
          .convert(Uint8List.sublistView(bytes))
          .toString();
      await (FontLoader(entry.key)..addFont(Future.value(bytes))).load();
    }
    if (capturePng) Directory(output).createSync(recursive: true);
  });

  for (final screen in [const Size(1440, 1000), const Size(390, 844)]) {
    for (final region in [(8, 4), (16, 12), (48, 32)]) {
      final width = region.$1, height = region.$2;
      final name = '${screen.width.toInt()}-${width}x$height';
      testWidgets('visible circuit painter matches frozen c61 pixels $name', (
        tester,
      ) async {
        tester.view.physicalSize = screen;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final bytes = _records(width, height);
        final state = <String, Object?>{
          'open': true,
          'busy': false,
          'dirty': false,
          'width': 600,
          'height': 400,
          'optimizationSupported': true,
          'optimizationEnabled': false,
          'records': bytes,
          'viewport': {
            'x': _worldX,
            'y': _worldY,
            'width': width,
            'height': height,
          },
        };
        final calls = <String>[];
        Widget app(Color primary) {
          final theme = terraTheme();
          return MaterialApp(
            theme: theme.copyWith(
              colorScheme: theme.colorScheme.copyWith(primary: primary),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: WorldCircuitPanel(
                    state: state,
                    dispatch: (action, args) async {
                      calls.add(action);
                    },
                  ),
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(app(TerraColors.mint));
        await tester.pumpAndSettle();
        final viewport = find.bySemanticsLabel('实际世界电路视口，点击选择设备或线路');
        Future<void> compare(
          String phase,
          Color primary, {
          int? selectedX,
          int? selectedY,
        }) async {
          await Scrollable.ensureVisible(
            tester.element(viewport),
            alignment: .5,
          );
          await tester.pumpAndSettle();
          final rect = tester.getRect(viewport);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(screen.width));
          expect(rect.bottom, lessThanOrEqualTo(screen.height));
          final paint = find.descendant(
            of: viewport,
            matching: find.byType(CustomPaint),
          );
          expect(paint, findsOneWidget);
          final size = tester.getSize(paint);
          expect(size.width, greaterThan(0));
          expect(size.height, greaterThan(0));
          final theme = Theme.of(tester.element(paint));
          expect(theme.textTheme.bodyMedium!.fontFamily, terraFontFamily);
          expect(theme.colorScheme.primary, primary);
          final production = tester.widget<CustomPaint>(paint).painter!;
          final reference = C61CircuitPainter(
            bytes,
            _worldX,
            _worldY,
            width,
            height,
            selectedX: selectedX,
            selectedY: selectedY,
            selectionColor: primary,
          );
          final rasters = (await tester.runAsync(
            () => Future.wait([
              _raster(production, size, capturePng: capturePng),
              _raster(reference, size, capturePng: capturePng),
            ]),
          ))!;
          final actual = rasters[0].rgba, expected = rasters[1].rgba;
          expect(actual.length, expected.length);
          var differences = 0, firstDifference = -1;
          for (var index = 0; index < actual.length; index++) {
            if (actual[index] != expected[index]) {
              if (firstDifference < 0) firstDifference = index;
              differences++;
            }
          }
          final actualHash = sha256.convert(actual).toString();
          final expectedHash = sha256.convert(expected).toString();
          expect(
            differences,
            0,
            reason:
                '$name/$phase first differing RGBA byte: $firstDifference; '
                'candidate=$actualHash, c61=$expectedHash',
          );
          // All cases contain visible non-background wires/blocks. An empty
          // recording must not satisfy the oracle through matching blank data.
          var paintedPixels = 0;
          for (var index = 0; index < actual.length; index += 4) {
            if (actual[index + 3] != 0 &&
                (actual[index] != 0x12 ||
                    actual[index + 1] != 0x1d ||
                    actual[index + 2] != 0x28)) {
              paintedPixels++;
            }
          }
          expect(paintedPixels, greaterThan(0));
          if (capturePng) {
            final prefix = '${Directory(output).absolute.path}/$name-$phase';
            File('$prefix-candidate.png').writeAsBytesSync(rasters[0].png!);
            File('$prefix-c61.png').writeAsBytesSync(rasters[1].png!);
            File('$prefix.json').writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert({
                'schema': 'abc-circuit-painter-pixel-equivalence-v1',
                'sourceCommit': Platform.environment['GITHUB_SHA'],
                'referenceCommit': 'c61d7a1d8c5155515808611fdf2c3b5992b666f3',
                'screen': [screen.width, screen.height],
                'visibleCanvas': [rect.left, rect.top, rect.width, rect.height],
                'canvasSize': [size.width, size.height],
                'rasterSize': [size.width.ceil(), size.height.ceil()],
                'devicePixelRatio': 1,
                'region': state['viewport'],
                'selected': [selectedX, selectedY],
                'phase': phase,
                'fontSha256': fontEvidence,
                'candidateRgbaSha256': actualHash,
                'referenceRgbaSha256': expectedHash,
                'differingRgbaBytes': differences,
                'paintedPixels': paintedPixels,
                'method':
                    'Rasterize the actual painter obtained from the visible '
                    'shared-theme panel at its responsive layout size; compare '
                    'every RGBA byte against the unchanged c61 painter.',
                'notMeasured': ['device frame rate', 'RSS', 'native heap'],
              }),
            );
          }
          expect(tester.takeException(), isNull);
        }

        await compare('unselected', TerraColors.mint);
        final rect = tester.getRect(viewport);
        await tester.tapAt(
          Offset(
            rect.right - rect.width / width / 2,
            rect.bottom - rect.height / height / 2,
          ),
        );
        await tester.pump();
        expect(
          find.textContaining(
            '选中 (${_worldX + width - 1}, ${_worldY + height - 1})',
          ),
          findsOneWidget,
        );
        await compare(
          'selected',
          TerraColors.mint,
          selectedX: _worldX + width - 1,
          selectedY: _worldY + height - 1,
        );
        await tester.pumpWidget(app(Colors.purpleAccent));
        await compare(
          'theme-change',
          Colors.purpleAccent,
          selectedX: _worldX + width - 1,
          selectedY: _worldY + height - 1,
        );
        expect(
          calls,
          isEmpty,
          reason: 'Selection and theme changes send no command.',
        );
        expect(state['optimizationEnabled'], isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
