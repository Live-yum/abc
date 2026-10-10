import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/terra_theme.dart';
import 'package:terraforge/ui/world_circuit_panel.dart';

void main() {
  for (final action in [
    ('重置', 'worldCircuitReset', <String, Object?>{}),
    ('保存模拟结果', 'worldCircuitSave', <String, Object?>{}),
    ('关闭', 'worldCircuitClose', <String, Object?>{'discard': true}),
  ]) {
    testWidgets('${action.$2} confirmation belongs to its mounted panel', (
      tester,
    ) async {
      final visible = ValueNotifier(true);
      final viewState = ValueNotifier<Map<String, Object?>>({
        'open': true,
        'dirty': true,
        'busy': false,
        'width': 600,
        'height': 400,
        'optimizationSupported': true,
        'displayIdentity': Object(),
      });
      final calls = <(String, Map<String, Object?>)>[];
      addTearDown(visible.dispose);
      addTearDown(viewState.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: terraTheme(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, showPanel, child) => showPanel
                  ? SingleChildScrollView(
                      child: ValueListenableBuilder<Map<String, Object?>>(
                        valueListenable: viewState,
                        builder: (context, state, child) => WorldCircuitPanel(
                          state: state,
                          dispatch: (name, args) async {
                            calls.add((name, args));
                          },
                        ),
                      ),
                    )
                  : const Text('另一页面'),
            ),
          ),
        ),
      );

      Future<void> requestConfirmation() async {
        final button = find.text(action.$1);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
      }

      await requestConfirmation();
      // Keep the root Navigator and its dialog, but remove the originating
      // feature page. A delayed confirmation must not operate a later page.
      visible.value = false;
      await tester.pump();
      expect(find.byType(WorldCircuitPanel), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(calls, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('另一页面'), findsOneWidget);

      visible.value = true;
      await tester.pump();
      final retainedPanel = tester.state(find.byType(WorldCircuitPanel));
      await requestConfirmation();
      viewState.value = {
        ...viewState.value,
        'displayIdentity': Object(),
      };
      await tester.pump();
      expect(tester.state(find.byType(WorldCircuitPanel)), same(retainedPanel));
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty, reason: 'A replaced session cannot use old consent.');
      expect(tester.takeException(), isNull);

      await requestConfirmation();
      viewState.value = {...viewState.value, 'open': false};
      await tester.pump();
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty, reason: 'A closed session has no pending action.');
      viewState.value = {...viewState.value, 'open': true};
      await tester.pump();

      await requestConfirmation();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);

      await requestConfirmation();
      // The engine replaces frames during normal ticks without changing the
      // display identity. A fresh snapshot for the same owner stays valid.
      final identity = viewState.value['displayIdentity'];
      viewState.value = {
        ...viewState.value,
        'running': true,
        'ticks': 6,
        'displayFrame': Uint8List.fromList([255, 255, 255, 255]),
      };
      await tester.pump();
      expect(viewState.value['displayIdentity'], same(identity));
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single.$1, action.$2);
      expect(calls.single.$2, action.$3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

