import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/circuit_document.dart';
import 'package:terraforge/domain/circuit_edit_plan.dart';
import 'package:terraforge/engine/circuit_backend.dart';

class PlannedTraversal implements CircuitBackend {
  final List<(int, int, int)> calls = [];
  final Map<(int, int, int), List<int>> results = {};
  Completer<List<int>>? pending;
  @override
  Future<List<int>> propagate(
    int width,
    int height,
    List<int> cells,
    int x,
    int y,
    int colour,
  ) async {
    calls.add((x, y, colour));
    if (pending != null) return pending!.future;
    return results[(x, y, colour)] ?? [y * width + x];
  }
}

void main() {
  test(
    'network preview uses each selected core colour; confirm is one edit',
    () async {
      final doc = CircuitDocument(width: 8, height: 8);
      doc.beginStroke();
      for (var x = 1; x <= 3; x++) {
        doc.paintWire(x, 1, 0);
        doc.paintWire(x, 1, 1);
        doc.paintWire(x, 1, 3);
      }
      doc.placeElement(
        2,
        1,
        CircuitElement.timer,
        initialOn: true,
        interval: 17,
      );
      doc.endStroke();
      final backend = PlannedTraversal()
        ..results[(1, 1, 0)] = [9, 10, 11]
        ..results[(1, 1, 1)] = [9, 10, 11];
      final session = CircuitEditSession(doc, backend);
      final before = doc.toJson(), revision = doc.revision;
      final plan = await session.previewNetwork(1, 1, 3);
      expect(backend.calls, [(1, 1, 0), (1, 1, 1)]);
      expect(plan!.wireMasks, {9: 3, 10: 3, 11: 3});
      expect(doc.toJson(), before);
      expect(doc.revision, revision);
      expect(session.snapshot()['preview'], containsPair('count', 3));
      expect(() => plan.wireMasks[0] = 1, throwsUnsupportedError);
      expect(() => session.snapshot()['busy'] = true, throwsUnsupportedError);
      expect(session.confirmPreview(), isTrue);
      expect(doc.revision, revision + 1);
      expect(
        doc.cell(2, 1),
        const CircuitCell(
          wires: 8,
          element: CircuitElement.timer,
          initialOn: true,
          interval: 17,
        ),
      );
      doc.undo();
      expect(doc.toJson(), before);
      doc.redo();
      expect(doc.cell(2, 1).wires, 8);
      expect(() => session.confirmPreview(), throwsStateError);
    },
  );

  test(
    'cancel and stale confirmation never change document or history',
    () async {
      final doc = CircuitDocument(width: 8, height: 8)..paintWire(1, 1, 0);
      final session = CircuitEditSession(doc, PlannedTraversal());
      await session.previewNetwork(1, 1, 1);
      session.cancelPreview();
      expect(() => session.confirmPreview(), throwsStateError);
      expect(doc.cell(1, 1).wires, 1);
      await session.previewNetwork(1, 1, 1);
      doc.paintWire(2, 1, 0);
      final before = doc.toJson();
      expect(session.snapshot()['preview'], containsPair('stale', true));
      expect(() => session.confirmPreview(), throwsStateError);
      expect(doc.toJson(), before);
      expect(session.preview, isNull);
      doc.undo();
      expect(doc.cell(1, 1).wires, 1);
      expect(doc.cell(2, 1).wires, 0);
    },
  );

  test(
    'pending cancellation, replacement and changed document discard old work',
    () async {
      final doc = CircuitDocument(width: 8, height: 8)..paintWire(1, 1, 0);
      final backend = PlannedTraversal()..pending = Completer<List<int>>();
      final session = CircuitEditSession(doc, backend);
      final first = session.previewNetwork(1, 1, 1);
      expect(session.busy, isTrue);
      session.cancelPreview();
      expect(session.busy, isFalse);
      final old = backend.pending!;
      backend.pending = null;
      await session.previewRoute(3, 3, 5, 3, 2);
      old.complete([9]);
      expect(await first, isNull);
      expect(session.preview!.kind, CircuitEditKind.route);
      backend.pending = Completer<List<int>>();
      final stale = session.previewNetwork(1, 1, 1);
      doc.paintWire(1, 2, 0);
      backend.pending!.complete([9]);
      await expectLater(stale, throwsStateError);
      expect(session.preview, isNull);
      expect(session.busy, isFalse);
    },
  );

  test('invalid core output and missing selected wire fail closed', () async {
    final doc = CircuitDocument(width: 8, height: 8)..paintWire(1, 1, 0);
    final backend = PlannedTraversal()..results[(1, 1, 0)] = [9, 64];
    final session = CircuitEditSession(doc, backend);
    final before = doc.toJson();
    await expectLater(session.previewNetwork(1, 1, 1), throwsStateError);
    backend.results[(1, 1, 0)] = [10];
    await expectLater(session.previewNetwork(1, 1, 1), throwsStateError);
    await expectLater(session.previewNetwork(1, 1, 2), throwsStateError);
    expect(() => session.previewNetwork(1, 1, 0), throwsRangeError);
    expect(doc.toJson(), before);
    expect(session.preview, isNull);
  });

  test(
    'bounded A* detours around unrelated same-colour net and loads',
    () async {
      final doc = CircuitDocument(width: 12, height: 9)
        ..paintWire(5, 4, 0)
        ..paintWire(4, 2, 1)
        ..placeElement(6, 2, CircuitElement.lamp);
      final session = CircuitEditSession(doc, PlannedTraversal());
      final before = doc.toJson();
      final plan = (await session.previewRoute(1, 4, 10, 4, 1))!;
      expect(doc.toJson(), before);
      expect(plan.wireMasks.keys, containsAll([49, 58]));
      for (final key in plan.wireMasks.keys) {
        final x = key % 12, y = key ~/ 12;
        expect((x - 5).abs() + (y - 4).abs(), greaterThan(1));
        expect(key, isNot(2 * 12 + 6));
      }
      final indices = plan.wireMasks.keys.toList();
      for (var i = 1; i < indices.length; i++) {
        expect(
          (indices[i] % 12 - indices[i - 1] % 12).abs() +
              (indices[i] ~/ 12 - indices[i - 1] ~/ 12).abs(),
          1,
        );
      }
      session.confirmPreview();
      expect(doc.cell(5, 4).wires, 1);
      doc.undo();
      expect(doc.toJson(), before);
    },
  );

  test(
    'route traces both endpoint networks and independently chosen colours',
    () async {
      final doc = CircuitDocument(width: 8, height: 8);
      for (final x in [1, 2, 5, 6]) {
        doc.paintWire(x, 2, 0);
        doc.paintWire(x, 2, 1);
      }
      final backend = PlannedTraversal();
      for (var colour = 0; colour < 2; colour++) {
        backend.results[(1, 2, colour)] = [17, 18];
        backend.results[(6, 2, colour)] = [21, 22];
      }
      final session = CircuitEditSession(doc, backend);
      final plan = await session.previewRoute(1, 2, 6, 2, 3);
      expect(backend.calls, [(1, 2, 0), (6, 2, 0), (1, 2, 1), (6, 2, 1)]);
      expect(plan!.wireMasks.keys, [17, 18, 19, 20, 21, 22]);
      session.confirmPreview();
      expect(doc.cell(3, 2).wires, 3);
    },
  );

  test(
    'route rejects endpoint short, no safe path and work budget exhaustion',
    () async {
      final doc = CircuitDocument(width: 8, height: 8)..paintWire(2, 1, 0);
      final session = CircuitEditSession(doc, PlannedTraversal());
      final before = doc.toJson();
      await expectLater(session.previewRoute(1, 1, 5, 5, 1), throwsStateError);
      await expectLater(
        session.previewRoute(0, 3, 7, 3, 2, visitLimit: 1),
        throwsStateError,
      );
      expect(session.preview, isNull);
      expect(doc.toJson(), before);
      for (var y = 0; y < 8; y++) {
        doc.paintWire(3, y, 0);
      }
      await expectLater(session.previewRoute(0, 4, 7, 4, 1), throwsStateError);
      expect(session.preview, isNull);
    },
  );

  test(
    'selection copy, rotated/mirrored paste retain settings and replace blanks',
    () {
      final doc = CircuitDocument(width: 10, height: 10)
        ..placeElement(
          1,
          1,
          CircuitElement.timer,
          initialOn: true,
          interval: 13,
        )
        ..paintWire(1, 1, 2)
        ..placeElement(
          2,
          3,
          CircuitElement.xorGate,
          initialOn: true,
          interval: 72,
        )
        ..paintWire(6, 5, 0);
      final session = CircuitEditSession(doc, PlannedTraversal());
      session.selectRect(1, 1, 2, 3);
      final before = doc.toJson();
      final clip = session.copySelection();
      expect(clip.width, 2);
      expect(clip.height, 3);
      expect(() => clip.cells.clear(), throwsUnsupportedError);
      final rotated = session.transformClipboard(
        CircuitClipboardTransform.rotateClockwise,
      );
      expect(rotated.width, 3);
      expect(rotated.height, 2);
      expect(rotated.cells[2], doc.cell(1, 1));
      expect(rotated.cells[3], doc.cell(2, 3));
      session.pasteClipboard(5, 5);
      expect(doc.cell(7, 5), clip.cells[0]);
      expect(doc.cell(5, 6), clip.cells[5]);
      expect(doc.cell(6, 5), const CircuitCell());
      doc.undo();
      expect(doc.toJson(), before);
      doc.redo();
      expect(doc.cell(7, 5).interval, 13);
      for (var turn = 0; turn < 3; turn++) {
        session.transformClipboard(CircuitClipboardTransform.rotateClockwise);
      }
      expect(session.clipboard!.cells, clip.cells);
      session.transformClipboard(CircuitClipboardTransform.mirrorHorizontal);
      session.transformClipboard(CircuitClipboardTransform.mirrorHorizontal);
      session.transformClipboard(CircuitClipboardTransform.mirrorVertical);
      session.transformClipboard(CircuitClipboardTransform.mirrorVertical);
      expect(session.clipboard!.cells, clip.cells);
    },
  );

  test(
    'cut is one history entry and invalid paste does not partially apply',
    () {
      final doc = CircuitDocument(width: 8, height: 8)
        ..paintWire(1, 1, 0)
        ..paintWire(2, 2, 3)
        ..placeElement(2, 2, CircuitElement.timer, interval: 42);
      final session = CircuitEditSession(doc, PlannedTraversal());
      final before = doc.toJson();
      session.selectRect(1, 1, 2, 2);
      expect(session.cutSelection(), isTrue);
      expect(doc.cells, isEmpty);
      doc.undo();
      expect(doc.toJson(), before);
      expect(() => session.pasteClipboard(7, 7), throwsRangeError);
      expect(doc.toJson(), before);
      expect(() => session.selectRect(-1, 0, 2, 2), throwsRangeError);
      expect(session.selection!.x, 1);
      doc.beginStroke();
      expect(() => session.pasteClipboard(3, 3), throwsStateError);
      doc.endStroke();
      expect(doc.toJson(), before);
    },
  );

  test(
    'future multi-cell input fails explicitly; out-of-bounds cannot alias row',
    () {
      final doc = CircuitDocument(width: 8, height: 8)..paintWire(0, 1, 0);
      expect(doc.cell(8, 0).wires, 0);
      final raw = Map<String, Object>.from(
        (doc.toJson()['cells'] as List).single as Map,
      );
      expect(
        () => CircuitDocument.fromJson({
          ...doc.toJson(),
          'cells': [
            {...raw, 'width': 2},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => CircuitDocument.fromJson({
          ...doc.toJson(),
          'cells': [
            {...raw, 'footprintHeight': 2},
          ],
        }),
        throwsFormatException,
      );
      final revision = doc.revision;
      doc.paintWire(0, 1, 0);
      expect(doc.revision, revision);
    },
  );
}
