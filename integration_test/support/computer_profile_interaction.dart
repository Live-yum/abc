import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/ui/computer_display.dart';

/// Merged monitor semantics can cover the full-width Align, including blank
/// space. Pointer interactions must use the painted monitor's own bounds.
Finder findComputerProfileMonitor(String label) => find.byWidgetPredicate(
  (widget) => widget is ComputerDisplay && widget.label == label,
  description: 'painted ComputerDisplay with label "$label"',
);

/// Finish scroll layout before checking and using the actual pointer target.
/// A fixed pump also works while the physical clock continuously schedules work.
Future<void> revealComputerProfileTarget(
  WidgetTester tester,
  Finder target,
) async {
  expect(target, findsOneWidget);
  await tester.pump();
  await tester.ensureVisible(target);
  await tester.pump();
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason:
        'The revealed production control must receive a real pointer. '
        'Target ${tester.getRect(target)}, '
        'viewport ${MediaQuery.sizeOf(tester.element(target))}.',
  );
}

/// Acquire keyboard focus only through the production monitor's pointer handler.
Future<void> focusComputerProfileMonitor(
  WidgetTester tester,
  Finder monitor,
) async {
  await revealComputerProfileTarget(tester, monitor);
  await tester.tap(monitor);
  await tester.pump();
  expect(
    Focus.maybeOf(tester.element(monitor))?.hasPrimaryFocus,
    isTrue,
    reason: 'The real monitor tap must focus its production keyboard handler.',
  );
}
