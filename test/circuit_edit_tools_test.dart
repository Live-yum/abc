import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/circuit_edit_tools.dart';

void main() {
  testWidgets(
    'numeric selection, colour mask, route and mirror emit complete intents',
    (tester) async {
      final actions = <(String, Map<String, Object?>)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CircuitEditTools(
                state: const {
                  'selection': {'x': 0, 'y': 0, 'width': 2, 'height': 3},
                  'clipboard': {'width': 2, 'height': 3, 'count': 1},
                },
                onAction: (action, args) async {
                  actions.add((action, args));
                },
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('circuit-edit-x')), '2');
      await tester.enterText(find.byKey(const ValueKey('circuit-edit-y')), '3');
      await tester.enterText(
        find.byKey(const ValueKey('circuit-edit-width')),
        '4',
      );
      await tester.enterText(
        find.byKey(const ValueKey('circuit-edit-height')),
        '5',
      );
      await tester.tap(find.byKey(const ValueKey('circuit-edit-select')));
      await tester.pump();
      expect(actions.last.$1, 'circuitSelect');
      expect(actions.last.$2, {'x': 2, 'y': 3, 'width': 4, 'height': 5});
      await tester.tap(find.byKey(const ValueKey('circuit-edit-colour-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('circuit-edit-network')));
      await tester.pump();
      expect(actions.last.$1, 'circuitNetworkPreview');
      expect(actions.last.$2, {'x': 2, 'y': 3, 'mask': 3});
      await tester.tap(find.byKey(const ValueKey('circuit-edit-route')));
      await tester.pump();
      expect(actions.last.$1, 'circuitRoutePreview');
      expect(actions.last.$2, {
        'startX': 2,
        'startY': 3,
        'endX': 5,
        'endY': 0,
        'mask': 3,
      });
      await tester.tap(find.byKey(const ValueKey('circuit-edit-mirror-v')));
      await tester.pump();
      expect(actions.last.$1, 'circuitMirror');
      expect(actions.last.$2, {'axis': 'vertical'});
      await tester.enterText(
        find.byKey(const ValueKey('circuit-edit-x')),
        'bad',
      );
      final count = actions.length;
      await tester.tap(find.byKey(const ValueKey('circuit-edit-select')));
      await tester.pump();
      expect(actions.length, count);
      expect(find.text('请输入整数坐标和选区尺寸。'), findsOneWidget);
    },
  );

  testWidgets('stale preview disables confirm but preserves cancel', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CircuitEditTools(
              state: const {
                'preview': {
                  'kind': 'removeNetwork',
                  'stale': true,
                  'count': 3,
                  'colourCounts': [3, 0, 0, 0],
                },
              },
              onAction: (action, args) async {
                actions.add(action);
              },
            ),
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('circuit-edit-confirm')),
    );
    expect(button.onPressed, isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('circuit-edit-cancel')),
    );
    await tester.tap(find.byKey(const ValueKey('circuit-edit-cancel')));
    await tester.pump();
    expect(actions, ['circuitCancelEdit']);
  });
}
