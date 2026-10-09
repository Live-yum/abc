import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

void main() {
  testWidgets('focused monitor forwards key edges; focus loss releases keys', (
    tester,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldCircuitPanel(
              state: {
                'open': true,
                'computerVerified': true,
                'canRunComputer': true,
                'keyboardVerified': true,
                'programName': 'p.bin',
                'width': 15200,
                'height': 7200,
              },
              dispatch: (action, args) async {
                calls.add((action, args));
              },
            ),
          ),
        ),
      ),
    );
    final screen = find.bySemanticsLabel('黑白显示器，显示实际物理像素状态');
    await tester.ensureVisible(screen);
    await tester.tap(screen);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    expect(calls.where((e) => e.$1 == 'worldCircuitInput').map((e) => e.$2), [
      {'direction': 'up', 'pressed': true},
      {'direction': 'up', 'pressed': false},
    ]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.any((e) => e.$1 == 'worldCircuitReleaseKeys'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'physical computer controls show actual frames and allow pause while engine busy',
    (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WorldCircuitPanel(
                state: {
                  'open': true,
                  'busy': true,
                  'running': true,
                  'computerVerified': true,
                  'canRunComputer': true,
                  'programName': 'Pong.bin',
                  'width': 15200,
                  'height': 7200,
                  'displayFrames': {'黑白显示器': Uint8List(64 * 48 * 4)},
                },
                dispatch: (action, args) async {
                  calls.add(action);
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(calls, ['worldCircuitPause']);
      expect(find.text('载入 Pong 程序'), findsOneWidget);
      expect(find.textContaining('键盘映射待实际传感器校准'), findsOneWidget);
      expect(find.bySemanticsLabel('黑白显示器，显示实际物理像素状态'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real circuit viewport renders and dispatches tile coordinates', (
    tester,
  ) async {
    final bytes = Uint8List(16), data = ByteData(16);
    data.setUint32(0, 2, Endian.little);
    data.setUint32(4, 10, Endian.little);
    data.setUint32(8, 144 | (1 << 16) | (1 << 24), Endian.little);
    bytes.setAll(0, data.buffer.asUint8List());
    final calls = <String>[], args = <Map<String, Object?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldCircuitPanel(
              state: {
                'open': true,
                'busy': false,
                'dirty': true,
                'width': 7,
                'height': 32,
                'records': bytes,
                'viewport': {'x': 2, 'y': 10, 'width': 1, 'height': 1},
              },
              dispatch: (name, values) async {
                calls.add(name);
                args.add(values);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('单步'));
    await tester.pump();
    expect(calls.last, 'worldCircuitStep');
    final target = find.bySemanticsLabel('实际世界电路视口，点击格子触发开关');
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
    expect(calls.last, 'worldCircuitTrigger');
    expect(args.last, {'x': 2, 'y': 10, 'mask': 15});
    await tester.ensureVisible(find.text('关闭'));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('当前模拟尚未保存，仍要关闭并丢弃？'), findsOneWidget);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(calls.last, 'worldCircuitClose');
    expect(args.last, {'discard': true});
    expect(tester.takeException(), isNull);
  });
}
