import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/terra_app.dart';
import 'package:terraforge/ui/terra_painters.dart';

class FakeController extends TerraController {
  TerraViewState state = const TerraViewState();
  final List<String> actions = [];
  final List<Map<String, Object?>> payloads = [];
  @override
  TerraViewState get view => state;
  @override
  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    actions.add(action);
    payloads.add(args);
  }
}

void main() {
  setUp(() {
    final handler = FlutterError.onError;
    FlutterError.onError = (details) {
      debugPrint(details.toString());
      handler?.call(details);
    };
  });
  testWidgets('desktop exposes all twelve sections and empty states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController();
    await tester.pumpWidget(TerraForgeApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('把每一次冒险，变成你的作品'), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final title in [
      '世界档案',
      '存档中心',
      '像素工坊',
      '角色实验室',
      '电路实验室',
      '融合画布',
      '世界生成',
      '写入工作流',
      '图鉴与成就',
      '映射方案',
      '设置与资源',
      '工作台',
    ]) {
      await tester.tap(find.text(title).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: title);
    }
    expect(controller.actions, isEmpty);
  });
  testWidgets('mobile has five navigation destinations and more drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TerraForgeApp(controller: FakeController()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(tester.takeException(), isNull);
    for (final title in [
      '世界档案',
      '存档中心',
      '像素工坊',
      '角色实验室',
      '电路实验室',
      '融合画布',
      '世界生成',
      '写入工作流',
      '图鉴与成就',
      '映射方案',
      '设置与资源',
      '工作台',
    ]) {
      await tester.tap(find.text('更多').last);
      await tester.pumpAndSettle();
      final nav = find
          .descendant(of: find.byType(Drawer), matching: find.text(title))
          .first;
      await tester.ensureVisible(nav);
      await tester.tap(nav);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: title);
    }
  });
  testWidgets('cancel import never dispatches operation', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController();
    await tester.pumpWidget(TerraForgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入存档'));
    await tester.pumpAndSettle();
    expect(find.text('导入到工作空间'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.actions, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('actual editor data paints and engine failure remains visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController()
      ..state = TerraViewState(
        error: '测试：不支持的版本',
        canvases: {
          'pixel': TerraCanvas(
            width: 34,
            height: 22,
            colors: List.filled(34 * 22, 0xff1b252f),
          ),
        },
      );
    await tester.pumpWidget(TerraForgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('像素工坊').first);
    await tester.pumpAndSettle();
    expect(find.text('测试：不支持的版本'), findsOneWidget);
    expect(find.text('34 × 22 px'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'circuit components dispatch placement and trigger to simulator',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FakeController()
        ..state = TerraViewState(
          canvases: {
            'circuit': TerraCanvas(
              width: 16,
              height: 12,
              colors: List.filled(192, 0),
            ),
          },
          result: {
            'circuitCells': [
              {'at': 20, 'element': 'lamp', 'on': true, 'wires': 1},
            ],
            'circuitTrace': [20],
          },
        );
      await tester.pumpWidget(TerraForgeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('电路实验室').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('电路沙盒'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开关'));
      await tester.tap(find.text('开关'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(GridCanvas));
      await tester.pumpAndSettle();
      expect(controller.actions, contains('circuitPlace'));
      await tester.tap(find.text('触发开关'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(GridCanvas));
      await tester.pumpAndSettle();
      expect(controller.actions, contains('circuitTrigger'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'advanced role editor blocks invalid JSON and cancel does not write',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = FakeController()
        ..state = const TerraViewState(
          player: {
            'name': '真实读取角色',
            'armor': [
              {'itemType': 1, 'stack': 1, 'prefix': 0},
            ],
            'buffs': [],
          },
        );
      await tester.pumpWidget(TerraForgeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('角色实验室').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('装备与外观'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑 JSON').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '{invalid');
      await tester.tap(find.text('校验并暂存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('JSON 无效'), findsOneWidget);
      expect(controller.actions, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.actions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('numeric-looking player name remains a string', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController()
      ..state = const TerraViewState(
        player: {'name': '原名', 'health': 100, 'mana': 20, 'difficulty': 0},
      );
    await tester.pumpWidget(TerraForgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('角色实验室').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('角色属性'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑角色名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '00123');
    await tester.tap(find.text('保存更改'));
    await tester.pumpAndSettle();
    expect(controller.actions.last, 'stagePlayer');
    expect(controller.payloads.last['value'], '00123');
    expect(tester.takeException(), isNull);
  });
  testWidgets('plr save opens the player section and matching filter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = FakeController()
      ..state = const TerraViewState(
        files: [TerraFile(id: 'p', name: 'Explorer.plr', kind: 'plr')],
      );
    await tester.pumpWidget(TerraForgeApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('存档中心').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('角色'));
    await tester.pumpAndSettle();
    expect(find.text('Explorer.plr'), findsOneWidget);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('角色实验室，等待一位探险者'), findsOneWidget);
    expect(controller.actions.last, 'openFile');
    expect(controller.payloads.last['id'], 'p');
    expect(tester.takeException(), isNull);
  });
}
