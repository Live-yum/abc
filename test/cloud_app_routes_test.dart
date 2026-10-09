import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/cloud/cloud.dart';
import 'package:terraforge/ui/terra_app.dart';

import 'cloud_reference_contract_test.dart'
    show ReferenceService, saveJson, envelope;
import 'cloud_test.dart' show schemaJson;
import 'terra_ui_test.dart' show FakeController;

Future<void> navigate(WidgetTester tester, String section, double width) async {
  if (width < 800) {
    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    final target = find
        .descendant(of: find.byType(Drawer), matching: find.text(section))
        .first;
    await tester.ensureVisible(target);
    await tester.tap(target);
  } else {
    await tester.tap(find.text(section).first);
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [1440.0, 390.0]) {
    testWidgets('actual cloud and online resource routes fit width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = ReferenceService();
      service.handler = (request) async {
        if (request.url.path == '/viewer/world-generation/options') {
          return envelope({
            'enabled': true,
            'versions': ['supported'],
            'schema': schemaJson,
          });
        }
        return service.response(request);
      };
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      cloud.saves = [CloudSave.fromJson(saveJson())];
      cloud.job = CloudSave.fromJson(saveJson());
      cloud.account = {'id': 7, 'nickname': 'Explorer', 'avatar': ''};
      final controller = FakeController()..state = TerraViewState(cloud: cloud);
      await tester.pumpWidget(TerraForgeApp(controller: controller));
      await tester.pumpAndSettle();
      await navigate(tester, '设置与资源', width);
      expect(tester.takeException(), isNull);
      expect(service.requests, isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('cloudHelpLoad')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('cloudHelpLoad')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.text('Help'), findsOneWidget);
      await tester.ensureVisible(find.text('加载生成选项'));
      await tester.runAsync(() async {
        await tester.tap(find.text('加载生成选项'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('group'));
      await tester.tap(find.text('group'));
      await tester.pumpAndSettle();
      expect(find.text('name'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await navigate(tester, '存档中心', width);
      await tester.ensureVisible(find.text('地图推荐'));
      await tester.tap(find.text('地图推荐'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('加载推荐'));
      await tester.runAsync(() async {
        await tester.tap(find.text('加载推荐'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(
        service
            .at('/viewer/recommendations/list')
            .single
            .url
            .queryParameters['kind'],
        'world',
      );
      await tester.ensureVisible(find.text('下载推荐'));
      await tester.tap(find.text('下载推荐'));
      await tester.pumpAndSettle();
      expect(controller.actions, contains('cloudRecommendationDownload'));
      expect(tester.takeException(), isNull);
      await navigate(tester, '图鉴与成就', width);
      await tester.ensureVisible(find.text('线上资源'));
      await tester.tap(find.text('线上资源'));
      await tester.pumpAndSettle();
      expect(find.textContaining('线上资源尚未配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await navigate(tester, '设置与资源', width);
      await tester.ensureVisible(find.text('编辑资料'));
      await tester.tap(find.text('编辑资料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cloudProfileNickname')), findsNothing);
      expect(tester.takeException(), isNull);
      expect(service.at('/viewer/user-info/updateAppUserInfo'), isEmpty);
    });
  }
}
