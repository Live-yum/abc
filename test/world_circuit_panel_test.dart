import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/diagnostics/host_stage_timings.dart';
import 'package:terraforge/ui/computer_display.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

Uint8List _switchRecord(int x, int y, {int type = 135, int frameY = 0}) {
  final bytes = Uint8List(16), data = ByteData(16);
  data.setUint32(0, x, Endian.little);
  data.setUint32(4, y, Endian.little);
  data.setUint32(8, type | (1 << 16) | (1 << 24), Endian.little);
  data.setInt16(14, frameY, Endian.little);
  bytes.setAll(0, data.buffer.asUint8List());
  return bytes;
}

Map<String, Object?> _state() => {
  'open': true,
  'busy': false,
  'dirty': false,
  'optimizationSupported': true,
  'width': 600,
  'height': 400,
  'records': _switchRecord(40, 50),
  'viewport': {'x': 40, 'y': 50, 'width': 4, 'height': 3},
};

Widget _panel(
  Map<String, Object?> state,
  List<(String, Map<String, Object?>)> calls,
) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: WorldCircuitPanel(
        state: state,
        dispatch: (action, args) async {
          calls.add((action, args));
        },
      ),
    ),
  ),
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets(
      'performance expansion preserves the circuit scroll state at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final bucket = PageStorageBucket();
        final controller = ScrollController();
        final restoredController = ScrollController();
        final timings = HostStageTimings();
        const scrollKey = PageStorageKey('circuit');
        final scroll = find.byKey(scrollKey);
        final performance = find.byType(ExpansionTile);

        Widget app({required bool open, required ScrollController scroll}) =>
            MaterialApp(
              home: Scaffold(
                body: PageStorage(
                  bucket: bucket,
                  child: SingleChildScrollView(
                    key: scrollKey,
                    controller: scroll,
                    child: Column(
                      children: [
                        WorldCircuitPanel(
                          state: _state()..['open'] = open,
                          hostStages: timings,
                          dispatch: (action, args) async {},
                        ),
                        const SizedBox(height: 2400),
                      ],
                    ),
                  ),
                ),
              ),
            );

        try {
          await tester.pumpWidget(app(open: false, scroll: controller));
          expect(performance, findsNothing);
          // Save a real ScrollPosition double before the open panel mounts.
          await tester.drag(scroll, const Offset(0, -180));
          await tester.pumpAndSettle();
          final priorOffset = bucket.readState(tester.element(scroll));
          expect(priorOffset, isA<double>());
          expect(priorOffset, greaterThan(0));
          expect(controller.offset, priorOffset);

          await tester.pumpWidget(app(open: true, scroll: controller));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(performance, findsOneWidget);
          expect(controller.offset, priorOffset);
          await _reveal(tester, find.text('性能明细 / Performance'));
          final savedOffset = bucket.readState(tester.element(scroll));
          expect(savedOffset, isA<double>());
          expect(controller.offset, savedOffset);

          for (final expanded in [true, false]) {
            await tester.tap(find.text('性能明细 / Performance'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(
              bucket.readState(tester.element(performance)),
              expanded,
            );
            expect(bucket.readState(tester.element(scroll)), isA<double>());
            expect(bucket.readState(tester.element(scroll)), savedOffset);
            expect(controller.offset, savedOffset);
          }

          controller.jumpTo(controller.offset + 180);
          await tester.pumpAndSettle();
          final restorationOffset = bucket.readState(tester.element(scroll));
          expect(restorationOffset, isA<double>());
          expect(restorationOffset, greaterThan(0));
          expect(controller.offset, restorationOffset);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(app(open: true, scroll: restoredController));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(restoredController.offset, restorationOffset);
          expect(bucket.readState(tester.element(scroll)), restorationOffset);
        } finally {
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          restoredController.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  for (final size in [const Size(1440, 1000), const Size(390, 844)]) {
    testWidgets('generic selection and sparse pixels fit at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() {
        WidgetController.hitTestWarningShouldBeFatal = previousFatal;
      });
      final calls = <(String, Map<String, Object?>)>[];
      final frame = Uint8List(4 * 3 * 4)..[47] = 255;
      final state = _state()
        ..addAll({
          'displayRegion': {
            'name': 'selected pixels',
            'x': 40,
            'y': 50,
            'width': 4,
            'height': 3,
          },
          'displayFrame': frame,
          'displayPixelCount': 1,
          'displayIdentity': Object(),
        });
      await tester.pumpWidget(_panel(state, calls));
      await tester.pumpAndSettle();
      final target = find.bySemanticsLabel('实际世界电路视口，点击选择设备或线路');
      await _reveal(tester, target);
      final viewportRect = tester.getRect(target);
      expect(viewportRect.width, lessThanOrEqualTo(size.width));
      await tester.tapAt(
        Offset(
          viewportRect.left + viewportRect.width / 8,
          viewportRect.top + viewportRect.height / 6,
        ),
      );
      await tester.pump();
      expect(
        calls,
        isEmpty,
        reason: 'Selecting a cell does not trigger wiring',
      );
      expect(find.textContaining('选中 (40, 50)'), findsOneWidget);
      await _reveal(tester, find.text('操作所选设备'));
      await tester.tap(find.text('操作所选设备'));
      await tester.pump();
      expect(calls.last.$1, 'worldCircuitTrigger');
      expect(calls.last.$2, {'x': 40, 'y': 50, 'mask': 15});
      await _reveal(tester, find.text('发送线路脉冲'));
      await tester.tap(find.text('发送线路脉冲'));
      await tester.pump();
      expect(calls.last.$1, 'worldCircuitTrigger');
      expect(calls.last.$2, {'x': 40, 'y': 50, 'mask': 15, 'direct': true});

      final display = find.byType(ComputerDisplay);
      await _reveal(tester, display);
      final displayRect = tester.getRect(display);
      expect(displayRect.width, greaterThan(0));
      expect(displayRect.width, lessThanOrEqualTo(size.width));
      expect(displayRect.width / displayRect.height, closeTo(4 / 3, .001));
      expect(tester.widget<ComputerDisplay>(display).rgba, same(frame));
      expect(find.textContaining('实际像素盒 1 个'), findsOneWidget);
      await _reveal(tester, find.text('刷新像素区域'));
      await tester.tap(find.text('刷新像素区域'));
      await tester.pump();
      expect(calls.last.$1, 'worldCircuitRefreshDisplay');
      await _finish(tester);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('generic controls pause even while the engine is busy', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    await tester.pumpWidget(
      _panel(_state()..addAll({'busy': true, 'running': true}), calls),
    );
    await tester.tap(find.text('暂停'));
    await tester.pump();
    expect(calls.single.$1, 'worldCircuitPause');
    final step = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '单步 1 tick'),
    );
    expect(step.onPressed, isNull);
    await _finish(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final supported in [false, true]) {
    testWidgets('pixel mode explains current topology support: $supported', (
      tester,
    ) async {
      final calls = <(String, Map<String, Object?>)>[];
      await tester.pumpWidget(
        _panel(_state()..['optimizationSupported'] = supported, calls),
      );
      expect(find.textContaining('后续运行结果可能不同'), findsOneWidget);
      expect(find.textContaining('历史显示不会重算'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.value, isFalse);
      if (supported) {
        expect(toggle.onChanged, isNotNull);
        await _reveal(tester, find.byType(SwitchListTile));
        await tester.tap(find.byType(SwitchListTile));
        await tester.pump();
        expect(calls.single.$1, 'worldCircuitOptimization');
        expect(calls.single.$2, {'enabled': true});
      } else {
        expect(toggle.onChanged, isNull);
        expect(find.textContaining('同色跨轴网络尚未支持'), findsOneWidget);
        expect(calls, isEmpty);
      }
      await _finish(tester);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets(
    'region inputs dispatch explicit rectangles and reject overflow',
    (tester) async {
      final calls = <(String, Map<String, Object?>)>[];
      await tester.pumpWidget(_panel(_state(), calls));
      for (final entry in ['100', '75', '6', '4'].asMap().entries) {
        final field = find.byType(TextField).at(entry.key);
        await _reveal(tester, field);
        await tester.enterText(field, entry.value);
      }
      await _reveal(tester, find.text('读取区域像素'));
      await tester.tap(find.text('读取区域像素'));
      await tester.pump();
      expect(calls.single.$1, 'worldCircuitReadDisplay');
      expect(calls.single.$2, {'x': 100, 'y': 75, 'width': 6, 'height': 4});
      await _reveal(tester, find.text('查看接线'));
      await tester.tap(find.text('查看接线'));
      await tester.pump();
      expect(calls.last.$1, 'worldCircuitViewport');
      expect(calls.last.$2, calls.first.$2);
      final field = find.byType(TextField).first;
      await _reveal(tester, field);
      await tester.enterText(field, '599');
      await _reveal(tester, find.text('读取区域像素'));
      await tester.tap(find.text('读取区域像素'));
      await tester.pump();
      expect(calls, hasLength(2));
      expect(find.textContaining('请输入世界范围内的区域'), findsOneWidget);
      await _finish(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'new view synchronizes coordinates and empty pixel region is clear',
    (tester) async {
      final calls = <(String, Map<String, Object?>)>[];
      await tester.pumpWidget(_panel(_state(), calls));
      final next = _state()
        ..['viewport'] = {'x': 100, 'y': 75, 'width': 6, 'height': 4}
        ..['records'] = _switchRecord(100, 75)
        ..['displayRegion'] = {
          'name': 'empty pixels',
          'x': 100,
          'y': 75,
          'width': 6,
          'height': 4,
        }
        ..['displayFrame'] = Uint8List(6 * 4 * 4)
        ..['displayPixelCount'] = 0;
      await tester.pumpWidget(_panel(next, calls));
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((field) => field.controller!.text),
        ['100', '75', '6', '4'],
      );
      expect(find.text('选区无原版像素装置。'), findsOneWidget);
      expect(find.byType(ComputerDisplay), findsNothing);
      await _finish(tester);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('discovered timer selection requires an explicit operation', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    final state = _state()..['records'] = _switchRecord(42, 50, type: 144);
    await tester.pumpWidget(_panel(state, calls));
    expect(find.textContaining('导入的定时器默认关闭'), findsOneWidget);
    expect(find.textContaining('当前视口发现 1 个可操作输入格'), findsOneWidget);
    final timer = find.text('定时器（关闭）');
    await _reveal(tester, timer);
    await tester.tap(timer);
    await tester.pump();
    expect(calls, isEmpty);
    expect(find.textContaining('选中 (42, 50)'), findsOneWidget);
    await _reveal(tester, find.text('操作所选设备'));
    await tester.tap(find.text('操作所选设备'));
    await tester.pump();
    expect(calls.single.$1, 'worldCircuitTrigger');
    expect(calls.single.$2, {'x': 42, 'y': 50, 'mask': 15});
    final started = Map<String, Object?>.of(state)
      ..['records'] = _switchRecord(42, 50, type: 144, frameY: 18);
    await tester.pumpWidget(_panel(started, calls));
    expect(find.text('定时器（已启动）'), findsOneWidget);
    await _finish(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('viewport navigation moves by the displayed rectangle', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    await tester.pumpWidget(_panel(_state(), calls));
    for (final move in [
      ('左移视口', 36, 50),
      ('右移视口', 44, 50),
      ('上移视口', 40, 47),
      ('下移视口', 40, 53),
    ]) {
      await _reveal(tester, find.text(move.$1));
      await tester.tap(find.text(move.$1));
      await tester.pump();
      expect(calls.last.$1, 'worldCircuitViewport');
      expect(calls.last.$2, {
        'x': move.$2,
        'y': move.$3,
        'width': 4,
        'height': 3,
      });
    }
    final edge = _state()
      ..['viewport'] = {'x': 0, 'y': 0, 'width': 4, 'height': 3};
    await tester.pumpWidget(_panel(edge, calls));
    for (final label in ['左移视口', '上移视口']) {
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, label),
      );
      expect(button.onPressed, isNull);
    }
    await _finish(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('single tick and dirty close retain their explicit actions', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    await tester.pumpWidget(_panel(_state()..['dirty'] = true, calls));
    await tester.tap(find.text('单步 1 tick'));
    await tester.pump();
    expect(calls.last.$1, 'worldCircuitStep');
    await _reveal(tester, find.text('关闭'));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('当前模拟尚未保存，仍要关闭并丢弃？'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'worldCircuitClose');
    expect(calls.last.$2, {'discard': true});
    await _finish(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
