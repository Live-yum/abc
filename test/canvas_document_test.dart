import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/canvas_document.dart';

void main() {
  test('one pointer stroke is one undo transaction', () {
    final c = CanvasDocument(3, 3);
    c.beginStroke();
    c.paint(0, 0, 1);
    c.paint(1, 0, 2);
    c.endStroke();
    expect(c.pixels.take(3), [1, 2, 0]);
    c.undo();
    expect(c.pixels, everyElement(0));
    expect(c.canUndo, false);
    c.redo();
    expect(c.pixels.take(3), [1, 2, 0]);
  });
  test('flood fill does not cross boundaries and redo is invalidated', () {
    final c = CanvasDocument(3, 3);
    for (var y = 0; y < 3; y++) {
      c.paint(1, y, 1);
    }
    c.paint(0, 0, 2, fill: true);
    expect(c.pixels, [2, 1, 0, 2, 1, 0, 2, 1, 0]);
    c.undo();
    c.paint(2, 2, 3);
    expect(c.canRedo, false);
  });
  test('out of range positions ignored and input bounds enforced', () {
    final c = CanvasDocument(2, 2);
    c.paint(-1, 0, 1);
    expect(c.canUndo, false);
    expect(() => CanvasDocument(0, 2), throwsArgumentError);
    expect(() => CanvasDocument(4096, 4096), throwsArgumentError);
  });
  test('project round trip and malformed data rejection', () {
    final c = CanvasDocument(3, 2);
    c.paint(2, 1, 0xff123456);
    final d = CanvasDocument.fromJson(c.toJson());
    expect(d.pixels, c.pixels);
    expect(
      () => CanvasDocument.fromJson({
        'format': 'terraforge.canvas',
        'version': 2,
      }),
      throwsFormatException,
    );
    expect(() => d.replace(1, 1, [1, 2]), throwsFormatException);
  });
  test('zero-change strokes do not consume history', () {
    final c = CanvasDocument(2, 2);
    c.beginStroke();
    c.endStroke();
    expect(c.canUndo, false);
  });
}
