import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/authoritative_circuit_panel.dart';

import 'authoritative_circuit_panel_test.dart' show fixture;

void main() {
  testWidgets('signal panels preserve distinct state after outer scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = fixture();
    final outer = ScrollController();
    addTearDown(outer.dispose);
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return SingleChildScrollView(
                key: const PageStorageKey('circuit'),
                controller: outer,
                child: AuthoritativeCircuitPanel(
                  state: state,
                  onAction: (_, _) async {},
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    outer.jumpTo(300);
    await tester.pumpAndSettle();
    // A packet first appears only after a simulation, when the parent already
    // has a saved double scroll offset under its own PageStorageKey.
    refresh(
      () => (state['snapshot'] as Map)['packet'] = {
        'operations': 1,
        'trace': List.generate(40, (index) => {'x': index, 'y': 0}),
        'events': [],
      },
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final signal = find.text('信号与事件');
    await tester.ensureVisible(signal);
    await tester.pumpAndSettle();
    await tester.tap(signal);
    await tester.pumpAndSettle();
    final trace = find.byKey(
      const PageStorageKey('authoritative-circuit-events-trace'),
    );
    await tester.ensureVisible(trace);
    await tester.pumpAndSettle();
    await tester.drag(trace, const Offset(0, -160));
    await tester.pumpAndSettle();
    refresh(() => (state['snapshot'] as Map).remove('packet'));
    await tester.pumpAndSettle();
    refresh(
      () => (state['snapshot'] as Map)['packet'] = {
        'operations': 2,
        'trace': [],
        'events': [],
      },
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('信号与事件'), findsOneWidget);
  });
}
