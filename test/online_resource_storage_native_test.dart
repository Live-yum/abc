import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/resources/online_resource_storage.dart';
import 'package:terraforge/resources/online_resource_storage_native.dart';

void main() {
  test(
    'native durable values, exact keys, concurrent atomic active and backup',
    () async {
      final dir = await Directory.systemTemp.createTemp('abc-online-test-');
      addTearDown(() => dir.delete(recursive: true));
      final a = NativeOnlineResourceStorage(directory: dir);
      final b = NativeOnlineResourceStorage(directory: dir);
      final digest = 'a' * 64, ns = 'b' * 64;
      final input = Uint8List.fromList([1, 2, 3]);
      final saved = a.write('objects', digest, input);
      input[0] = 99;
      await saved;
      expect(await b.read('objects', digest), [1, 2, 3]);
      await Future.wait([
        a.commitActive(ns, Uint8List.fromList([1])),
        b.commitActive(ns, Uint8List.fromList([2])),
      ]);
      expect(await a.read('state', 'active-$ns'), [2]);
      expect(await a.read('state', 'backup-$ns'), [1]);
      expect((await a.list()).length, 3);
      for (final bad in ['$digest\n', '$digest\u2028', '../$digest']) {
        expect(
          () => validateOnlineResourceKey('objects', bad),
          throwsArgumentError,
        );
      }
      await a.remove('objects', digest);
      expect(await b.read('objects', digest), isNull);
    },
  );
  test(
    'native rejects symlink targets and preserves active on failed backup',
    () async {
      final dir = await Directory.systemTemp.createTemp('abc-online-test-');
      addTearDown(() => dir.delete(recursive: true));
      final store = NativeOnlineResourceStorage(directory: dir), ns = 'a' * 64;
      await store.commitActive(ns, Uint8List.fromList([7]));
      final outside = File('${dir.path}/unrelated')
        ..writeAsStringSync('unchanged');
      await Link('${dir.path}/state/backup-$ns.json').create(outside.path);
      await expectLater(
        store.commitActive(ns, Uint8List.fromList([8])),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.read('state', 'active-$ns'), [7]);
      expect(await outside.readAsString(), 'unchanged');
    },
  );
}
