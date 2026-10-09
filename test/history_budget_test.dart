import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/canvas_document.dart';
import 'package:terraforge/domain/save_record.dart';
import 'package:terraforge/domain/circuit_document.dart';

void main() {
  test(
    'failed history activation restores bytes and pruned history exactly',
    () async {
      final r = SaveRecord(
        id: 'a',
        name: 'a.wld',
        kind: 'wld',
        bytes: Uint8List(2),
        historyBudgetBytes: 4,
      );
      r.commit(Uint8List.fromList([1, 1]));
      r.commit(Uint8List.fromList(List.filled(10, 2)));
      await expectLater(
        r.navigateHistory(
          forward: false,
          verify: () async {
            expect(r.current, [1, 1]);
            expect(r.canRedo, false);
            throw StateError('reopen failed');
          },
        ),
        throwsStateError,
      );
      expect(r.current, List.filled(10, 2));
      expect(r.canUndo, true);
      expect(r.canRedo, false);
      r.undo();
      expect(r.current, [1, 1]);
    },
  );
  test(
    'raster history prunes oldest snapshots by bytes, retaining recent undo',
    () {
      final c = CanvasDocument(3, 1, historyBudgetBytes: 48);
      for (var i = 1; i <= 4; i++) {
        c.paint(0, 0, i);
      }
      c.undo();
      expect(c.pixels.first, 3);
      c.undo();
      expect(c.pixels.first, 2);
      expect(c.canUndo, false);
      c.redo();
      expect(c.pixels.first, 3);
      c.redo();
      expect(c.pixels.first, 4);
    },
  );
  test(
    'save history enforces bytes across differently sized undo and redo',
    () {
      final r = SaveRecord(
        id: 'a',
        name: 'a.wld',
        kind: 'wld',
        bytes: Uint8List(2),
        historyBudgetBytes: 4,
      );
      r.commit(Uint8List.fromList([1, 1]));
      r.commit(Uint8List.fromList([2, 2]));
      r.commit(Uint8List.fromList([3, 3]));
      r.undo();
      expect(r.current, [2, 2]);
      r.undo();
      expect(r.current, [1, 1]);
      expect(r.canUndo, false);
      r.redo();
      expect(r.current, [2, 2]);
      r.commit(Uint8List(10));
      r.undo();
      expect(r.current, [2, 2]);
      expect(r.canRedo, false); // The 10-byte newer version cannot fit history.
      expect(r.original, [0, 0]);
    },
  );
  test('sparse circuit history is budgeted through undo and redo', () {
    final c = CircuitDocument(width: 3, height: 1, historyBudgetBytes: 384);
    for (var i = 0; i < 4; i++) {
      c.paintWire(0, 0, i);
    }
    c.undo();
    expect(c.cell(0, 0).wires, 7);
    c.undo();
    expect(c.cell(0, 0).wires, 3);
    expect(c.canUndo, false);
    c.redo();
    expect(c.cell(0, 0).wires, 7);
    c.redo();
    expect(c.cell(0, 0).wires, 15);
  });
  test('zero history budget retains no history', () {
    final c = CanvasDocument(1, 1, historyBudgetBytes: 0)..paint(0, 0, 1);
    final r = SaveRecord(
      id: 'a',
      name: 'a.wld',
      kind: 'wld',
      bytes: Uint8List(2),
      historyBudgetBytes: 0,
    )..commit(Uint8List(3));
    final circuit = CircuitDocument(historyBudgetBytes: 0)..paintWire(0, 0, 0);
    expect(c.canUndo, false);
    expect(r.canUndo, false);
    expect(circuit.canUndo, false);
  });
}
