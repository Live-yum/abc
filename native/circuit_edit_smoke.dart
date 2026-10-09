// Generated sandbox geometry only. Uses the separately supplied real C core.
import 'dart:convert';
import 'dart:io';

import 'package:terraforge/domain/circuit_document.dart';
import 'package:terraforge/domain/circuit_edit_plan.dart';
import 'package:terraforge/engine/circuit_backend.dart';
import 'package:terraforge/engine/native_engine.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final backend = createTerraEngine() as CircuitBackend;
  final doc = CircuitDocument(width: 12, height: 10);
  for (var x = 1; x <= 5; x++) {
    for (final colour in [0, 1, 3]) {
      doc.paintWire(x, 2, colour);
    }
  }
  doc.placeElement(4, 2, CircuitElement.timer, initialOn: true, interval: 17);
  doc.paintWire(7, 7, 0);
  final session = CircuitEditSession(doc, backend);
  final before = jsonEncode(doc.toJson());
  final plan = await session.previewNetwork(1, 2, 3);
  require(plan!.wireMasks.length == 5, 'Core network preview count');
  require(
    plan.wireMasks.values.every((mask) => mask == 3),
    'Per-colour core traversal',
  );
  require(jsonEncode(doc.toJson()) == before, 'Preview changed design');
  session.confirmPreview();
  require(
    doc.cell(4, 2).wires == 8 &&
        doc.cell(4, 2).initialOn &&
        doc.cell(4, 2).interval == 17,
    'Network deletion lost device or other colour',
  );
  require(doc.cell(7, 7).wires == 1, 'Network deletion reached isolated wire');
  doc.undo();
  require(
    jsonEncode(doc.toJson()) == before,
    'Network delete was not one undo entry',
  );
  await session.previewNetwork(1, 2, 1);
  session.cancelPreview();
  require(jsonEncode(doc.toJson()) == before, 'Cancel changed design');

  doc.paintWire(1, 5, 0);
  doc.paintWire(10, 5, 0);
  doc.paintWire(5, 5, 0);
  doc.placeElement(6, 3, CircuitElement.lamp);
  final route = await session.previewRoute(1, 5, 10, 5, 1);
  require(route != null && route.wireMasks.length > 10, 'A* did not detour');
  session.confirmPreview();
  final reached = (await backend.propagate(
    12,
    10,
    doc.nativeCells,
    1,
    5,
    0,
  )).toSet();
  require(reached.contains(70), 'Confirmed path fails actual core traversal');
  require(
    !reached.contains(65) && !reached.contains(91),
    'Confirmed path shorts an unrelated network',
  );
  for (final key in route!.wireMasks.keys) {
    require(
      reached.contains(key),
      'Actual core cannot reach a planned route cell',
    );
  }
  session.selectRect(1, 2, 5, 1);
  session.copySelection();
  session.transformClipboard(CircuitClipboardTransform.rotateClockwise);
  session.pasteClipboard(11, 0);
  require(
    doc.cell(11, 3).element == CircuitElement.timer &&
        doc.cell(11, 3).interval == 17 &&
        doc.cell(11, 3).initialOn,
    'Rotated clipboard lost timer settings',
  );
  stdout.writeln(
    'Actual native per-colour network preview/delete/cancel/undo, safe A* route/core readback, and settings-preserving clipboard passed',
  );
  exit(0);
}
