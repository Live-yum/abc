import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/circuit_document.dart';
import 'package:terraforge/engine/circuit_backend.dart';

class StubTraversal implements CircuitBackend {
  List<int> hits = [];
  bool fail = false;
  int calls = 0;
  @override
  Future<List<int>> propagate(
    int width,
    int height,
    List<int> cells,
    int x,
    int y,
    int colour,
  ) async {
    calls++;
    if (fail) throw StateError('injected native failure');
    return hits;
  }
}

void main() {
  test('four wire layers, transactional strokes and project round-trip', () {
    final d = CircuitDocument(width: 8, height: 8);
    d.beginStroke();
    for (var c = 0; c < 4; c++) {
      d.paintWire(2, 3, c);
    }
    d.placeElement(2, 3, CircuitElement.timer, initialOn: true, interval: 30);
    d.endStroke();
    expect(d.cell(2, 3).wires, 15);
    expect(CircuitDocument.fromJson(d.toJson()).toJson(), d.toJson());
    d.undo();
    expect(d.cells, isEmpty);
    d.redo();
    expect(d.cell(2, 3).wires, 15);
    d.paintWire(2, 3, 1, erase: true);
    expect(d.cell(2, 3).wires, 13);
  });
  test('reject unknown versions, duplicates and malformed input', () {
    final d = CircuitDocument()..paintWire(1, 1, 0);
    expect(
      () => CircuitDocument.fromJson({...d.toJson(), 'version': 2}),
      throwsFormatException,
    );
    final cell = (d.toJson()['cells'] as List).single;
    expect(
      () => CircuitDocument.fromJson({
        ...d.toJson(),
        'cells': [cell, cell],
      }),
      throwsFormatException,
    );
    expect(
      () => CircuitDocument.fromJson({
        ...d.toJson(),
        'cells': [
          {'at': -1},
        ],
      }),
      throwsFormatException,
    );
    expect(() => CircuitDocument(width: 257), throwsFormatException);
  });
  test(
    'only real backend hits toggle lamps, duplicate hits and source skip once',
    () async {
      final d = CircuitDocument(width: 8, height: 8)
        ..paintWire(1, 1, 0)
        ..placeElement(1, 1, CircuitElement.switchInput)
        ..paintWire(3, 1, 0)
        ..placeElement(3, 1, CircuitElement.lamp);
      final backend = StubTraversal()..hits = [9, 11, 11];
      final s = CircuitSimulator(d, backend);
      await s.trigger(1, 1);
      expect(s.isOn(3, 1), isTrue);
      expect(s.trace, {9, 11});
      await s.trigger(1, 1);
      expect(s.isOn(3, 1), isFalse);
      expect(backend.calls, 2);
    },
  );
  test(
    'timer advances exact ticks and rolls back on failed native pulse',
    () async {
      final d = CircuitDocument(width: 8, height: 8)
        ..paintWire(1, 1, 0)
        ..placeElement(1, 1, CircuitElement.timer, initialOn: true, interval: 2)
        ..paintWire(3, 1, 0)
        ..placeElement(3, 1, CircuitElement.lamp);
      final backend = StubTraversal()..hits = [9, 11];
      final s = CircuitSimulator(d, backend);
      await s.step();
      expect(backend.calls, 0);
      expect(s.tick, 1);
      backend.fail = true;
      await expectLater(s.step(), throwsStateError);
      expect(s.tick, 1);
      expect(s.isOn(3, 1), isFalse);
      backend.fail = false;
      await s.step();
      expect(s.tick, 2);
      expect(s.isOn(3, 1), isTrue);
    },
  );
  test(
    'editing topology resets simulation; gate reads stacked lamps',
    () async {
      final d = CircuitDocument(width: 8, height: 8)
        ..paintWire(0, 0, 0)
        ..placeElement(2, 2, CircuitElement.lamp)
        ..placeElement(2, 3, CircuitElement.lamp, initialOn: true)
        ..placeElement(2, 4, CircuitElement.xorGate);
      final b = StubTraversal()..hits = [0, 18];
      final s = CircuitSimulator(d, b)..reset();
      expect(s.isOn(2, 4), true);
      await s.trigger(0, 0);
      expect(s.isOn(2, 4), false);
      d.undo();
      s.reset();
      expect(s.tick, 0);
    },
  );
}
