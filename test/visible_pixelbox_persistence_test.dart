// Functional full-app acceptance using a real NativeEngine and an original WLD.
// Captures use the same Flutter test rasterizer for both layouts, not devices or FPS.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

class _NoSmallFiles implements FileGateway {
  @override
  Future<PickedFile?> pick(String kind) async => null;
  @override
  Future<bool> save(String name, Uint8List bytes) async => false;
}

// Only the operating-system file dialogs are substituted. Imports, simulation,
// display decoding, export bytes, output leases, and reopen use production code.
class _FileDialogs implements WorldCircuitFileGateway {
  _FileDialogs(this.input, this.directory);
  File input;
  final Directory directory;
  bool cancelPick = true, acceptSave = false;
  int saves = 0;
  File? saved;
  final outputLeases = <String>[];

  @override
  Future<WorldCircuitSource?> pick() async {
    if (cancelPick) {
      cancelPick = false;
      return null;
    }
    return WorldCircuitSource.file(
      path: input.absolute.path,
      length: input.lengthSync(),
      name: input.uri.pathSegments.last,
    );
  }

  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    saves++;
    expect(source.token, isNotNull);
    expect(protectedSources.map((s) => s.path), contains(input.absolute.path));
    expect(source.path, isNot(input.absolute.path));
    final candidate = File(source.path!);
    expect(candidate.lengthSync(), source.length);
    outputLeases.add(candidate.path);
    if (!acceptSave) return false;
    saved = candidate.copySync('${directory.path}/$name');
    return true;
  }
}

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

Map<String, int> _onlyTile(Map<String, Object?> state, int type) {
  final records = state['records'] as Uint8List;
  final data = ByteData.sublistView(records);
  final matches = <Map<String, int>>[];
  for (var offset = 0; offset < records.length; offset += 16) {
    final word = data.getUint32(offset + 8, Endian.little);
    if ((word & 65535) == type && (word & (1 << 16)) != 0) {
      matches.add({
        'x': data.getUint32(offset, Endian.little),
        'y': data.getUint32(offset + 4, Endian.little),
        'frameX': data.getInt16(offset + 12, Endian.little),
        'frameY': data.getInt16(offset + 14, Endian.little),
      });
    }
  }
  expect(matches, hasLength(1));
  return matches.single;
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var attempt = 0; attempt < 1000; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (ready()) {
      await tester.pump();
      expect(tester.takeException(), isNull);
      return;
    }
  }
  fail('Timed out: $reason');
}

Future<Uint8List> _decodedFrame(WidgetTester tester, Uint8List expected) async {
  final raw = find.descendant(
    of: find.byType(ComputerDisplay),
    matching: find.byType(RawImage),
  );
  Uint8List? observed;
  for (var attempt = 0; attempt < 100; attempt++) {
    final image = tester.widget<RawImage>(raw).image;
    if (image != null) {
      final retained = image.clone();
      try {
        final bytes = await tester.runAsync(
          () => retained.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        if (bytes != null) {
          observed = Uint8List.fromList(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          );
          if (_hash(observed) == _hash(expected)) return observed;
        }
      } finally {
        retained.dispose();
      }
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('ComputerDisplay never decoded the current engine frame: $observed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  final output = Platform.environment['ABC_VISIBLE_PIXELBOX_DIR'];
  final fontHashes = <String, String>{};
  setUpAll(() async {
    if (library == null) return;
    for (final entry in const {
      terraFontFamily: 'assets/fonts/TerraForgeCJK-Regular.otf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final bytes = await rootBundle.load(entry.value);
      fontHashes[entry.value] = _hash(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await (FontLoader(entry.key)..addFont(Future.value(bytes))).load();
    }
    if (output != null) {
      expect(autoUpdateGoldenFiles, isTrue);
      Directory(output).createSync(recursive: true);
    }
  });

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    for (final optimized in [false, true]) {
      final name =
          '${size.width.toInt()}x${size.height.toInt()}-${optimized ? 'on' : 'off'}';
      testWidgets(
        'real visible PixelBox, ordinary controls and WLD persistence $name',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final previousShadows = debugDisableShadows;
          debugDisableShadows = false;
          final previousHitTest = WidgetController.hitTestWarningShouldBeFatal;
          WidgetController.hitTestWarningShouldBeFatal = true;
          final directory = Directory.systemTemp.createTempSync(
            'abc-visible-pixels-',
          );
          final original = File(
            'test/fixtures/generic-circuit/synthetic-visible-pixelbox.wld',
          ).absolute;
          final originalHash = _hash(original.readAsBytesSync());
          final dialogs = _FileDialogs(original, directory);
          final engine = createTerraEngine();
          Workspace makeWorkspace() => Workspace(
            engine: engine,
            files: _NoSmallFiles(),
            worldCircuitBackend: engine as WorldCircuitSourceBackend,
            worldCircuitFiles: dialogs,
          );
          var workspace = makeWorkspace();
          const capture = ValueKey('real-visible-pixelbox-application');
          Map<String, Object?> state() => workspace.worldCircuitView;
          final observations = <Map<String, Object?>>[];

          Future<void> idle() async {
            await _waitFor(
              tester,
              () => state()['busy'] != true,
              'production native command completion',
            );
            expect(workspace.view.error, isEmpty);
            expect(state()['error'], isNull);
          }

          Future<void> tap(Finder target) async {
            await Scrollable.ensureVisible(
              tester.element(target),
              alignment: .5,
            );
            await tester.pumpAndSettle();
            expect(target.hitTestable(), findsOneWidget);
            await tester.tap(target);
            await tester.pump();
            await idle();
          }

          Future<void> button(String text) => tap(find.text(text));
          Future<void> confirm() => button('继续');

          Future<void> mount() async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: TerraForgeApp(controller: workspace),
              ),
            );
            await tester.pumpAndSettle();
            if (size.width < 1000) {
              await tester.tap(find.byTooltip('全部功能'));
              await tester.pumpAndSettle();
              await tap(
                find.descendant(
                  of: find.byType(Drawer),
                  matching: find.text('电路实验室'),
                ),
              );
            } else {
              await tap(find.text('电路实验室').first);
            }
            await button('世界电路');
          }

          Future<void> choosePixelRegion() async {
            final pixel = _onlyTile(state(), 445);
            final values = {
              'X': '${pixel['x']! - 1}',
              'Y': '${pixel['y']}',
              '宽度': '3',
              '高度': '1',
            };
            for (final entry in values.entries) {
              final field = find.byKey(
                PageStorageKey('world-circuit-coordinate-${entry.key}'),
              );
              await Scrollable.ensureVisible(
                tester.element(field),
                alignment: .5,
              );
              await tester.pumpAndSettle();
              await tester.enterText(field, entry.value);
            }
            await button('读取区域像素');
            expect(state()['displayPixelCount'], 1);
            expect(find.byType(ComputerDisplay), findsOneWidget);
          }

          Uint8List expectPixel(bool lit) {
            final expected = Uint8List.fromList([
              0,
              0,
              0,
              0,
              lit ? 255 : 0,
              lit ? 255 : 0,
              lit ? 255 : 0,
              255,
              0,
              0,
              0,
              0,
            ]);
            expect(state()['displayFrame'], orderedEquals(expected));
            expect(_onlyTile(state(), 445)['frameX'], lit ? 18 : 0);
            return expected;
          }

          Future<Uint8List> observe(String phase, bool lit) async {
            final expected = expectPixel(lit);
            final decoded = await _decodedFrame(tester, expected);
            final display = find.byType(ComputerDisplay);
            await Scrollable.ensureVisible(
              tester.element(display),
              alignment: .5,
            );
            await tester.pumpAndSettle();
            final rect = tester.getRect(display);
            expect(rect.top, greaterThanOrEqualTo(66));
            final bottom = size.width < 1000
                ? tester.getRect(find.byType(NavigationBar)).top
                : size.height;
            expect(rect.bottom, lessThanOrEqualTo(bottom));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width));
            final theme = Theme.of(
              tester.element(find.byType(WorldCircuitPanel)),
            );
            expect(theme.textTheme.bodyMedium!.fontFamily, terraFontFamily);
            expect(theme.colorScheme.primary, TerraColors.mint);
            expect(
              tester.widget<ComputerDisplay>(display).backgroundColor,
              theme.colorScheme.surfaceContainerHighest,
            );
            final row = <String, Object?>{
              'phase': phase,
              'optimizationEnabled': state()['optimizationEnabled'],
              'ticks': state()['ticks'],
              'netPulses': state()['netPulses'],
              'dirty': state()['dirty'],
              'pixelFrameX': _onlyTile(state(), 445)['frameX'],
              'displayPixelCount': state()['displayPixelCount'],
              'displayRegion': state()['displayRegion'],
              'renderedRgbaSha256': _hash(decoded),
            };
            if (output != null) {
              final png = File(
                '${Directory(output).absolute.path}/$name-$phase.png',
              );
              await expectLater(
                find.byKey(capture),
                matchesGoldenFile(png.uri),
              );
              final raster = img.decodePng(png.readAsBytesSync())!;
              expect(raster.width, size.width.toInt());
              expect(raster.height, size.height.toInt());
              // Check the actual full-app raster at the visible PixelBox centre,
              // in addition to checking the source and decoded RawImage buffers.
              final pixel = raster.getPixel(
                rect.center.dx.floor(),
                rect.center.dy.floor(),
              );
              final painted = [
                pixel.r.toInt(),
                pixel.g.toInt(),
                pixel.b.toInt(),
                pixel.a.toInt(),
              ];
              expect(painted, lit ? [255, 255, 255, 255] : [0, 0, 0, 255]);
              row['png'] = png.uri.pathSegments.last;
              row['pngSha256'] = _hash(png.readAsBytesSync());
              row['visiblePixelRgba'] = painted;
            }
            observations.add(row);
            return decoded;
          }

          try {
            await mount();
            await button(
              '选择完整 WLD',
            ); // Cancelled OS picker leaves the panel closed.
            expect(state()['open'], isFalse);
            await button('选择完整 WLD');
            await button('导入完整电路');
            expect(state()['open'], isTrue);
            expect(state()['ticks'], 0);
            expect(state()['dirty'], isFalse);
            expect(state()['optimizationEnabled'], isFalse);
            expect(state()['optimizationSupported'], isTrue);
            await choosePixelRegion();
            if (optimized) await tap(find.byType(SwitchListTile));

            // Use actual control discovery and ordinary HitSwitch, never a direct
            // wire pulse or a test-injected command. Only red is selected first.
            for (final color in ['蓝线', '绿线', '黄线']) {
              await tap(find.widgetWithText(FilterChip, color));
            }
            await tap(find.widgetWithText(ListTile, '开关'));
            expect(
              state()['dirty'],
              isFalse,
              reason: 'Selecting does not trigger.',
            );
            await button('操作所选设备');
            expectPixel(!optimized);
            if (!optimized) {
              await button('操作所选设备');
              expectPixel(false);
            }
            await tap(find.widgetWithText(FilterChip, '蓝线'));
            final dark = await observe('before', false);
            await button('操作所选设备');
            final lit = await observe('after', true);
            expect(_hash(lit), isNot(_hash(dark)));

            // The isolated timer tests ordinary start, tick and stop semantics;
            // wall-clock timing is not an assertion or a performance claim.
            await tap(find.widgetWithText(ListTile, '定时器（关闭）'));
            await button('操作所选设备');
            expect(_onlyTile(state(), 144)['frameY'], 18);
            await button('单步 1 tick');
            expect(state()['ticks'], 1);
            expectPixel(true);
            await button('操作所选设备');
            expect(_onlyTile(state(), 144)['frameY'], 0);

            // Dismissing confirmation must neither export nor change the frame.
            await button('保存模拟结果');
            await button('取消');
            expect(dialogs.saves, 0);
            expectPixel(true);
            await button('保存模拟结果');
            await confirm(); // Cancelled OS save dialog releases the real output.
            expect(dialogs.saves, 1);
            expect(dialogs.saved, isNull);
            expect(state()['dirty'], isTrue);
            expect(
              dialogs.outputLeases.every((p) => !File(p).existsSync()),
              isTrue,
            );
            dialogs.acceptSave = true;
            await button('保存模拟结果');
            await confirm();
            expect(dialogs.saves, 2);
            expect(state()['dirty'], isFalse);
            final saved = dialogs.saved!;
            final savedHash = _hash(saved.readAsBytesSync());
            expect(savedHash, isNot(originalHash));
            expect(_hash(original.readAsBytesSync()), originalHash);
            expect(
              dialogs.outputLeases.every((p) => !File(p).existsSync()),
              isTrue,
            );

            await tap(find.widgetWithText(ListTile, '开关'));
            await button('操作所选设备');
            expectPixel(false);
            await button('重置');
            await button('取消');
            expectPixel(false);
            expect(state()['dirty'], isTrue);
            await button('重置');
            await confirm();
            expect(state()['dirty'], isFalse);
            expect(state()['ticks'], 0);
            expect(state()['optimizationEnabled'], isFalse);
            expect(_onlyTile(state(), 445)['frameX'], 0);
            expect(find.byType(ComputerDisplay), findsNothing);
            await button('关闭');
            expect(state()['open'], isFalse);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(workspace.close);
            workspace.dispose();

            // A new Workspace/owner opens the actual exported file from disk.
            // Persistent tile frames survive; runtime tick phase and mode do not.
            dialogs.input = saved;
            workspace = makeWorkspace();
            await mount();
            await button('选择完整 WLD');
            await button('导入完整电路');
            expect(state()['ticks'], 0);
            expect(state()['dirty'], isFalse);
            expect(state()['optimizationEnabled'], isFalse);
            expect(_onlyTile(state(), 144)['frameY'], 0);
            await choosePixelRegion();
            final reopened = await observe('reopened', true);
            expect(reopened, orderedEquals(lit));

            // A real mutation proves dirty close cancellation and confirmed close.
            await tap(find.widgetWithText(ListTile, '开关'));
            await button('操作所选设备');
            expectPixel(false);
            await button('关闭');
            await button('取消');
            expect(state()['open'], isTrue);
            expect(state()['dirty'], isTrue);
            expectPixel(false);
            await button('关闭');
            await confirm();
            expect(state()['open'], isFalse);
            expect(find.byType(ComputerDisplay), findsNothing);
            expect(find.byType(AlertDialog), findsNothing);
            expect(_hash(saved.readAsBytesSync()), savedHash);
            expect(_hash(original.readAsBytesSync()), originalHash);
            expect(tester.takeException(), isNull);
            if (output != null) {
              File(
                '${Directory(output).absolute.path}/$name.json',
              ).writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert({
                  'schema': 'abc.visible-pixelbox-persistence.v1',
                  'status': 'passed',
                  'kind': 'original-synthetic-WLD-native-full-app-functional-observation',
                  'rasterizer': 'same Flutter widget-test rasterizer for both layouts',
                  'notMeasured': [
                    'native device rendering',
                    'FPS',
                    'runtime performance',
                  ],
                  'sourceCommit': Platform.environment['GITHUB_SHA'],
                  'engineSha256': _hash(File(library!).readAsBytesSync()),
                  'sourceWldSha256': originalHash,
                  'savedWldSha256': savedHash,
                  'savedWldChanged': true,
                  'sourceWldUnchanged': true,
                  'width': size.width.toInt(),
                  'height': size.height.toInt(),
                  'devicePixelRatio': 1,
                  'fontSha256': fontHashes,
                  'ordinaryRedCrossingLit': !optimized,
                  'ordinaryRedBlueCrossingLit': true,
                  'persistentState': 'PixelBox frameX=18 survives actual WLD save/new-Workspace reopen',
                  'nonPersistentState':
                      'tick count, timer phase, optimization mode',
                  'fileDialogBoundary': 'OS dialogs replaced with local-file picker/copy; native import/export and release are real',
                  'lifecycle': [
                    'cancel picker',
                    'cancel save confirmation',
                    'cancel OS save',
                    'save',
                    'cancel reset',
                    'reset',
                    'close',
                    'new Workspace reopen',
                    'cancel dirty close',
                    'discard close',
                  ],
                  'observations': observations,
                }),
              );
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(workspace.close);
            workspace.dispose();
            directory.deleteSync(recursive: true);
            WidgetController.hitTestWarningShouldBeFatal = previousHitTest;
            debugDisableShadows = previousShadows;
          }
        },
        skip: library == null,
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }
  }
}
