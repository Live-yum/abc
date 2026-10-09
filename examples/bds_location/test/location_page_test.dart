import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bds_location/main.dart';

void main() {
  testWidgets('Chinese location screen renders on a narrow phone without requesting location', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const LocationApp());
    expect(find.text('BDS定位'), findsOneWidget);
    expect(find.text('纬度（WGS84）'), findsOneWidget);
    expect(find.text('经度（WGS84）'), findsOneWidget);
    expect(find.text('状态：等待定位'), findsOneWidget);
    expect(find.text('开始定位'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
