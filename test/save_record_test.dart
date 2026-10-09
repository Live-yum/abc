import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/save_record.dart';

void main() {
  test('original remains immutable through edits and undo redo', () {
    final source = Uint8List.fromList([1, 2]);
    final r = SaveRecord(
      id: '1',
      name: 'hello.wld',
      kind: 'wld',
      bytes: source,
    );
    source[0] = 9;
    r.original[0] = 8;
    expect(r.original, [1, 2]);
    r.commit(Uint8List.fromList([3, 4]));
    expect(r.modified, true);
    expect(r.original, [1, 2]);
    r.undo();
    expect(r.current, [1, 2]);
    expect(r.modified, false);
    r.redo();
    expect(r.current, [3, 4]);
    expect(r.modified, true);
    expect(r.exportName, 'hello_terraforge.wld');
  });
  test('clean commit has no history', () {
    final r = SaveRecord(
      id: '1',
      name: 'a.plr.bak',
      kind: 'plr',
      bytes: Uint8List.fromList([1]),
    );
    r.commit(Uint8List.fromList([1]));
    expect(r.canUndo, false);
    expect(r.exportName, 'a_terraforge.plr');
  });
  test('cached digest rolls back with failed history activation', () async {
    final r = SaveRecord(
      id: 'digest',
      name: 'digest.wld',
      kind: 'wld',
      bytes: Uint8List.fromList([1, 2]),
    );
    final originalHash = r.originalHash;
    r.commit(Uint8List.fromList([3, 4]));
    await expectLater(
      r.navigateHistory(
        forward: false,
        verify: () async {
          throw StateError('open failed');
        },
      ),
      throwsStateError,
    );
    expect(r.modified, isTrue);
    expect(r.current, [3, 4]);
    expect(r.originalHash, originalHash);
    r.undo();
    expect(r.modified, isFalse);
    r.commit(Uint8List.fromList([1, 2]));
    expect(r.canUndo, isFalse);
    r.redo();
    expect(r.modified, isTrue);
  });
}
