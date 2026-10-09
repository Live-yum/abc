import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/terra_app.dart';

class _Controller extends TerraController {
  bool running = false;
  final actions = <String>[];

  @override
  TerraViewState get view => TerraViewState(
    result: {
      'rulesCircuit': {'running': running, 'ready': false, 'error': ''},
    },
  );

  void startClock() {
    running = true;
    notifyListeners();
  }

  @override
  Future<void> dispatch(
    String action, [
    Map<String, Object?> args = const {},
  ]) async {
    actions.add(action);
    if (action == 'rulesPause') {
      running = false;
      notifyListeners();
    }
  }
}

void main() {
  testWidgets('leaving the full circuit tab or section pauses its owner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _Controller();
    await tester.pumpWidget(TerraForgeApp(controller: controller));
    await tester.tap(find.text('电路实验室').first);
    await tester.pumpAndSettle();

    controller.startClock();
    await tester.pump();
    await tester.tap(find.text('电路沙盒'));
    await tester.pumpAndSettle();
    expect(controller.actions, ['rulesPause']);
    expect(controller.running, isFalse);

    await tester.tap(find.text('完整电路工坊'));
    await tester.pumpAndSettle();
    controller.startClock();
    await tester.pump();
    await tester.tap(find.text('工作台').first);
    await tester.pumpAndSettle();
    expect(controller.actions, ['rulesPause', 'rulesPause']);
    expect(controller.running, isFalse);

    await tester.tap(find.text('电路实验室').first);
    await tester.pumpAndSettle();
    expect(controller.running, isFalse);
    expect(controller.actions, ['rulesPause', 'rulesPause']);
    expect(tester.takeException(), isNull);
  });
}
