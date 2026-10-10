// Responsive UI observations from a synthetic generic WLD contract fixture.
// These are not native-device captures or runtime-performance measurements.
// Optional capture: ABC_GENERIC_VISUAL_DIR=<directory> flutter test
//   --update-goldens test/generic_circuit_visual_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

import 'support/generic_circuit_backend.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;

class _Sources implements WorldCircuitFileGateway {
  @override
  Future<WorldCircuitSource?> pick() async => const WorldCircuitSource.file(
    path: '/fixture/generic-controls.wld',
    length: 2048,
    name: 'generic-controls.wld',
  );

  @override
  Future<bool> save(WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async => true;
}

Future<void> _operation(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  final tracked = operation.then<void>((_) { done = true; },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        done = true;
      });
  for (var turn = 0; turn < 100 && !done; turn++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(done, isTrue, reason: 'Static generic fixture operation did not settle.');
  await tracked;
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['ABC_GENERIC_VISUAL_DIR'];
  final fontEvidence = <String, String>{};
  setUpAll(() async {
    // Use the product CJK family and official SDK icon font. Their actual
    // bytes are recorded for each generated observation; never use test glyphs.
    for (final entry in const {
      terraFontFamily: 'assets/fonts/TerraForgeCJK-Regular.otf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final bytes = await rootBundle.load(entry.value);
      fontEvidence[entry.value] = sha256.convert(bytes.buffer.asUint8List(
          bytes.offsetInBytes, bytes.lengthInBytes)).toString();
      final font = FontLoader(entry.key)..addFont(Future.value(bytes));
      await font.load();
    }
    if (output != null && output.isNotEmpty) {
      expect(autoUpdateGoldenFiles, isTrue,
          reason: 'PNG generation requires --update-goldens; it is not a baseline pass.');
      Directory(output).createSync(recursive: true);
    }
  });

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    final name = size.width == 1440 ? 'desktop-1440x1000' : 'mobile-390x844';
    testWidgets('generic full application controls and pixels $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final oldDisableShadows = debugDisableShadows;
      final backend = GenericCircuitBackend();
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: _Sources(),
      );
      const capture = ValueKey('generic-full-application-visual');
      Map<String, Object?> state() => workspace.worldCircuitView;
      try {
        debugDisableShadows = false;
        await _operation(tester, workspace.dispatch('worldCircuitChooseWorld'));
        await _operation(tester, workspace.dispatch('worldCircuitImport'));
        // Explicit fixture selections use the same public actions as the UI.
        // The sparse display is a separate row from the discovered controls.
        await _operation(tester, workspace.dispatch('worldCircuitViewport',
            {'x': 40, 'y': 50, 'width': 8, 'height': 1}));
        await _operation(tester, workspace.dispatch('worldCircuitReadDisplay',
            {'x': 40, 'y': 52, 'width': 4, 'height': 1}));
        expect(workspace.view.error, isEmpty);
        expect(state()['running'], isFalse);
        expect(state()['ticks'], 0);
        expect(state()['dirty'], isFalse);
        expect(state()['optimizationEnabled'], isFalse);
        expect(backend.commands.any((command) => command.mutates), isFalse);

        await tester.pumpWidget(RepaintBoundary(
          key: capture,
          child: TerraForgeApp(controller: workspace),
        ));
        await tester.pumpAndSettle();
        if (size.width < 1000) {
          await tester.tap(find.byTooltip('全部功能'));
          await tester.pumpAndSettle();
          final target = find.descendant(of: find.byType(Drawer),
              matching: find.text('电路实验室'));
          await tester.ensureVisible(target);
          await tester.tap(target);
        } else {
          await tester.tap(find.text('电路实验室').first);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('世界电路'));
        await tester.pumpAndSettle();

        // Discover and select a real input record through its visible label.
        final pressure = find.widgetWithText(ListTile, '压力板');
        await tester.ensureVisible(pressure, alignment: .3);
        await tester.tap(pressure);
        await tester.pump();
        expect(state()['dirty'], isFalse, reason: 'Selection does not operate the circuit.');
        final operate = find.text('操作所选设备');
        await tester.ensureVisible(operate, alignment: .5);
        await tester.tap(operate);
        await tester.pumpAndSettle();
        expect(workspace.view.error, isEmpty);
        expect(state()['dirty'], isTrue);
        expect(state()['netPulses'], 1);
        expect(state()['ticks'], 0);
        final timer = find.widgetWithText(ListTile, '定时器（关闭）');
        expect(timer, findsOneWidget);
        expect(state()['displayPixelCount'], 1);
        final frame = state()['displayFrame'] as Uint8List;
        expect(frame.sublist(0, 12), everyElement(0),
            reason: 'Sparse gaps remain transparent.');
        expect(frame.sublist(12), everyElement(255),
            reason: 'The selected fixture input lights its one PixelBox.');

        final monitor = find.byType(ComputerDisplay);
        final rawImage = find.descendant(of: monitor, matching: find.byType(RawImage));
        var decodedCurrentFrame = false;
        for (var turn = 0; turn < 100 && !decodedCurrentFrame; turn++) {
          final image = tester.widget<RawImage>(rawImage).image;
          if (image != null) {
            final retained = image.clone();
            try {
              final pixels = await tester.runAsync(() =>
                  retained.toByteData(format: ui.ImageByteFormat.rawRgba));
              if (pixels != null) {
                decodedCurrentFrame = sha256.convert(pixels.buffer.asUint8List(
                    pixels.offsetInBytes, pixels.lengthInBytes)).toString() ==
                    sha256.convert(frame).toString();
              }
            } finally {
              retained.dispose();
            }
          }
          if (!decodedCurrentFrame) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
            await tester.pump();
          }
        }
        expect(decodedCurrentFrame, isTrue,
            reason: 'Capture requires the decoded image of the current selected-pixel frame.');
        final wiring = find.bySemanticsLabel('实际世界电路视口，点击选择设备或线路');
        await Scrollable.ensureVisible(tester.element(wiring), alignment: .02);
        await tester.pumpAndSettle();
        final contentBottom = size.width < 1000
            ? tester.getRect(find.byType(NavigationBar)).top : size.height;
        for (final target in [wiring, pressure, timer, operate, monitor]) {
          final rect = tester.getRect(target);
          expect(rect.top, greaterThanOrEqualTo(66));
          expect(rect.bottom, lessThanOrEqualTo(contentBottom));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
        }
        final theme = Theme.of(tester.element(find.byType(WorldCircuitPanel)));
        expect(theme.textTheme.bodyMedium!.fontFamily, terraFontFamily);
        expect(theme.colorScheme.primary, TerraColors.mint);
        expect(tester.widget<ComputerDisplay>(monitor).backgroundColor,
            theme.colorScheme.surfaceContainerHighest);
        expect(find.byType(NavigationBar), size.width < 1000
            ? findsOneWidget : findsNothing);
        expect(tester.getSize(find.byKey(capture)), size);
        expect(state()['running'], isFalse);
        expect(tester.takeException(), isNull);

        if (output != null && output.isNotEmpty) {
          final png = File('${Directory(output).absolute.path}/generic-$name.png');
          // Official golden update produces observations. No old CPU screenshot
          // or visual baseline comparison is treated as an acceptance result.
          await expectLater(find.byKey(capture), matchesGoldenFile(png.uri));
          final bytes = png.readAsBytesSync();
          final header = ByteData.sublistView(bytes);
          expect(header.getUint32(16), size.width.toInt());
          expect(header.getUint32(20), size.height.toInt());
          File('${png.path}.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
            'schema': 'abc-generic-circuit-visual-v1',
            'kind': 'synthetic-widget-observation',
            'testHostOS': Platform.operatingSystem,
            'notMeasured': ['native device rendering', 'frame rate', 'runtime performance'],
            'sourceCommit': Platform.environment['GITHUB_SHA'],
            'png': png.uri.pathSegments.last,
            'pngSha256': sha256.convert(bytes).toString(),
            'width': size.width.toInt(), 'height': size.height.toInt(),
            'devicePixelRatio': 1, 'fontSha256': fontEvidence,
            'fixture': 'GenericCircuitBackend: ordinary controls and one sparse PixelBox',
            'viewport': state()['viewport'], 'displayRegion': state()['displayRegion'],
            'displayPixelCount': state()['displayPixelCount'],
            'displayRgbaSha256': sha256.convert(frame).toString(),
            'ticks': state()['ticks'], 'netPulses': state()['netPulses'],
            'optimizationEnabled': state()['optimizationEnabled'],
            'running': state()['running'],
            'validation': 'generated observation; no pixel baseline comparison',
          }));
        }
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await _operation(tester, workspace.close());
          workspace.dispose();
        } finally {
          debugDisableShadows = oldDisableShadows;
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }
}
