import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

void main() {
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
