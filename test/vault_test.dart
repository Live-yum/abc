import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/platform/vault_native.dart';

void main() {
  late Directory root;
  late NativeLocalVault vault;
  final bytes = Uint8List.fromList([0, 255, 128, 13, 10, 0, 3]);

  VaultEntry entry(String id, {Uint8List? data, DateTime? modified}) {
    final payload = data ?? bytes;
    return VaultEntry(
      id: id,
      name: 'original.wld',
      kind: 'world',
      sha256: sha256.convert(payload).toString(),
      size: payload.length,
      modified: modified ?? DateTime.utc(2026, 10, 8),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('terra-vault-test-');
    vault = NativeLocalVault(directory: () async => root);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('persists exact binary bytes across backend recreation', () async {
    await vault.put(entry('version_1'), bytes);
    final reopened = NativeLocalVault(directory: () async => root);
    expect(await reopened.read('version_1'), bytes);
    final records = await reopened.list();
    expect(records.single.toJson(), entry('version_1').toJson());
    final metadata = await File('${root.path}/version_1.record/entry.json')
        .readAsString();
    expect(metadata, isNot(contains(root.path)));
    expect(
      jsonDecode(metadata).keys,
      unorderedEquals(['id', 'name', 'kind', 'sha256', 'size', 'modified']),
    );
  });

  test('versions are immutable and remain independently readable', () async {
    await vault.put(entry('v1'), bytes);
    await expectLater(
      vault.put(entry('v1'), bytes),
      throwsA(isA<VaultException>()),
    );
    final newer = Uint8List.fromList([7, 8]);
    await vault.put(entry('v2', data: newer), newer);
    expect(await vault.read('v1'), bytes);
    expect(await vault.read('v2'), newer);
  });

  test('captures mutable caller buffer before asynchronous write', () async {
    final mutable = Uint8List.fromList(bytes);
    final pending = vault.put(entry('copy'), mutable);
    mutable.fillRange(0, mutable.length, 42);
    await pending;
    expect(await vault.read('copy'), bytes);
  });

  test('concurrent instances never overwrite a version', () async {
    final other = NativeLocalVault(directory: () async => root);
    final results = await Future.wait([
      vault.put(entry('race'), bytes).then((_) => true, onError: (_) => false),
      other.put(entry('race'), bytes).then((_) => true, onError: (_) => false),
    ]);
    expect(results.where((success) => success).length, 1);
    expect(await vault.read('race'), bytes);
  });

  test('read and list refuse checksum corruption', () async {
    await vault.put(entry('broken'), bytes);
    await File('${root.path}/broken.record/data.bin')
        .writeAsBytes(List.filled(bytes.length, 99));
    await expectLater(vault.read('broken'), throwsA(isA<VaultException>()));
    await expectLater(vault.list(), throwsA(isA<VaultException>()));
  });

  test('refuses truncated payload and malformed metadata', () async {
    await vault.put(entry('broken'), bytes);
    await File('${root.path}/broken.record/data.bin').writeAsBytes([1]);
    await expectLater(vault.read('broken'), throwsA(isA<VaultException>()));
    await File('${root.path}/broken.record/entry.json').writeAsString('{');
    await expectLater(vault.read('broken'), throwsA(isA<VaultException>()));
  });

  test('rejects metadata id substitution', () async {
    await vault.put(entry('original'), bytes);
    await File('${root.path}/original.record/entry.json')
        .writeAsString(jsonEncode(entry('substitute').toJson()));
    await expectLater(vault.read('original'), throwsA(isA<VaultException>()));
  });

  test(
    'recovers complete validated journal after interrupted commit',
    () async {
      final journal = Directory('${root.path}/.pending-recover');
      await journal.create();
      await File('${journal.path}/data.bin').writeAsBytes(bytes);
      await File('${journal.path}/entry.json')
          .writeAsString(jsonEncode(entry('recover').toJson()));
      expect((await vault.list()).single.id, 'recover');
      expect(await journal.exists(), false);
      expect(await vault.read('recover'), bytes);
    },
  );

  test('retains but never exposes incomplete or corrupt journals', () async {
    final journal = Directory('${root.path}/.pending-partial');
    await journal.create();
    await File('${journal.path}/data.bin').writeAsBytes([1]);
    expect(await vault.list(), isEmpty);
    expect(await journal.exists(), true);
    await File('${journal.path}/entry.json')
        .writeAsString(jsonEncode(entry('partial').toJson()));
    expect(await vault.list(), isEmpty);
    await expectLater(vault.read('partial'), throwsA(isA<VaultException>()));
  });

  test('never overwrites committed record with a recovery journal', () async {
    await vault.put(entry('keep'), bytes);
    final journal = Directory('${root.path}/.pending-keep');
    await journal.create();
    final other = Uint8List.fromList([9]);
    await File('${journal.path}/data.bin').writeAsBytes(other);
    await File('${journal.path}/entry.json')
        .writeAsString(jsonEncode(entry('keep', data: other).toJson()));
    expect(await vault.read('keep'), bytes);
  });

  test(
    'remove persists, is idempotent and ignores deleted tombstones',
    () async {
      await vault.put(entry('delete'), bytes);
      await vault.remove('delete');
      await vault.remove('delete');
      await Directory('${root.path}/.deleted-old').create();
      expect(await vault.list(), isEmpty);
      await expectLater(vault.read('delete'), throwsA(isA<VaultException>()));
    },
  );

  test(
    'removing a version cannot resurrect an older duplicate journal',
    () async {
      await vault.put(entry('gone'), bytes);
      final journal = Directory('${root.path}/.pending-gone');
      await journal.create();
      await File('${journal.path}/data.bin').writeAsBytes(bytes);
      await File('${journal.path}/entry.json')
          .writeAsString(jsonEncode(entry('gone').toJson()));
      await vault.remove('gone');
      expect(await vault.list(), isEmpty);
      await expectLater(vault.read('gone'), throwsA(isA<VaultException>()));
    },
  );

  test('sorts latest versions first', () async {
    await vault.put(entry('old'), bytes);
    await vault.put(entry('new', modified: DateTime.utc(2026, 11)), bytes);
    expect((await vault.list()).map((e) => e.id), ['new', 'old']);
  });

  test('rejects traversal, separators, hidden and oversized identifiers', () {
    for (final id in [
      '',
      '..',
      '../escape',
      '/tmp/x',
      r'C:\x',
      'a/b',
      '.hidden',
      'x' * 97,
      '🪴',
    ]) {
      expect(() => vault.read(id), throwsA(isA<VaultException>()));
      expect(() => vault.remove(id), throwsA(isA<VaultException>()));
      expect(() => vault.put(entry(id), bytes), throwsA(isA<VaultException>()));
    }
  });

  test(
    'rejects wrong checksum, size, source-path names and oversize metadata',
    () {
      final base = entry('bad').toJson();
      for (final patch in <Map<String, Object>>[
        {'sha256': '0' * 64},
        {'size': 2},
        {'size': maxVaultBytes + 1},
        {'size': -1},
        {'name': '/private/world.wld'},
        {'name': r'C:\private\world.wld'},
        {'sha256': 'invalid'},
        {'name': ''},
        {'kind': ''},
      ]) {
        expect(() {
          final candidate = VaultEntry.fromJson({...base, ...patch});
          return vault.put(candidate, bytes);
        }, throwsA(isA<VaultException>()));
      }
    },
  );

  test('permission and unavailable storage failures are explicit', () async {
    final file = File('${root.path}/not-a-directory');
    await file.writeAsString('occupied');
    final badVault = NativeLocalVault(
      directory: () async => Directory(file.path),
    );
    await expectLater(
      badVault.put(entry('cannot-save'), bytes),
      throwsA(isA<VaultException>()),
    );
  });

  test('refuses symbolic links for record data', () async {
    if (Platform.isWindows) {
      return;
    }
    await vault.put(entry('linked'), bytes);
    final data = File('${root.path}/linked.record/data.bin');
    await data.delete();
    final outside = File('${root.path}/outside.bin');
    await outside.writeAsBytes(bytes);
    await Link(data.path).create(outside.path);
    await expectLater(vault.read('linked'), throwsA(isA<VaultException>()));
  });
}
