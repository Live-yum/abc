import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/vault_history.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/platform/vault_native.dart';
import 'package:terraforge/ui/vault_history_panel.dart';

class MemoryVault implements LocalVault {
  final records = <String, VaultEntry>{};
  final data = <String, Uint8List>{};
  bool failPut = false;
  bool failAfterPut = false;
  bool failRemove = false;
  bool failAfterRemove = false;
  bool corruptPut = false;
  final log = <String>[];
  @override
  Future<List<VaultEntry>> list() async => records.values.toList();
  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) async {
    log.add('put:${entry.id}');
    if (failPut) throw const VaultException('put failed');
    validateVaultBytes(entry, bytes);
    if (records.containsKey(entry.id)) throw const VaultException('immutable');
    records[entry.id] = entry;
    data[entry.id] = corruptPut
        ? Uint8List(bytes.length)
        : Uint8List.fromList(bytes);
    if (failAfterPut) throw const VaultException('put response lost');
  }

  @override
  Future<Uint8List> read(String id) async {
    log.add('read:$id');
    return Uint8List.fromList(data[id]!);
  }

  @override
  Future<void> remove(String id) async {
    log.add('remove:$id');
    if (failRemove) throw const VaultException('remove failed');
    records.remove(id);
    data.remove(id);
    if (failAfterRemove) throw const VaultException('remove response lost');
  }
}

void main() {
  final bytes = Uint8List.fromList([0, 255, 128, 13, 10]);
  VaultEntry entry([String id = 'v1', String kind = 'world']) => VaultEntry(
    id: id,
    name: 'original.wld',
    kind: kind,
    sha256: sha256.convert(bytes).toString(),
    size: bytes.length,
    modified: DateTime.utc(2026, 10, 8),
  );
  late MemoryVault vault;
  late VaultHistory history;
  setUp(() async {
    vault = MemoryVault();
    history = VaultHistory(vault);
    await vault.put(entry(), bytes);
    vault.log.clear();
  });

  test(
    'copy is verified before remove, exact bytes and metadata restore',
    () async {
      final trashed = await history.trash(entry());
      expect(trashed.kind, 'trash:world');
      expect(
        vault.log.indexOf('read:${trashed.id}'),
        lessThan(vault.log.indexOf('remove:v1')),
      );
      expect((await history.load()).active, isEmpty);
      expect((await history.load()).trashed.single.id, trashed.id);
      final restored = await history.restore(trashed);
      expect(restored.toJson(), entry().toJson());
      expect(await vault.read('v1'), bytes);
      expect((await history.load()).trashed, isEmpty);
    },
  );

  for (final failure in ['put', 'afterPut', 'remove', 'afterRemove']) {
    test(
      'trash retries recover from $failure without duplicate loss',
      () async {
        vault.failPut = failure == 'put';
        vault.failAfterPut = failure == 'afterPut';
        vault.failRemove = failure == 'remove';
        vault.failAfterRemove = failure == 'afterRemove';
        await expectLater(
          history.trash(entry()),
          throwsA(isA<VaultException>()),
        );
        expect(
          vault.data.values.any(
            (d) => sha256.convert(d).toString() == entry().sha256,
          ),
          isTrue,
        );
        vault.failPut = vault.failAfterPut = vault.failRemove =
            vault.failAfterRemove = false;
        final trashed = await history.trash(entry());
        expect(vault.records.keys, [trashed.id]);
        expect(await vault.read(trashed.id), bytes);
      },
    );
    test('restore retries recover from $failure', () async {
      final trashed = await history.trash(entry());
      vault.failPut = failure == 'put';
      vault.failAfterPut = failure == 'afterPut';
      vault.failRemove = failure == 'remove';
      vault.failAfterRemove = failure == 'afterRemove';
      await expectLater(
        history.restore(trashed),
        throwsA(isA<VaultException>()),
      );
      vault.failPut = vault.failAfterPut = vault.failRemove =
          vault.failAfterRemove = false;
      final restored = await history.restore(trashed);
      expect(vault.records.keys, [restored.id]);
      expect(await vault.read(restored.id), bytes);
    });
  }
  test('corrupt new copy cannot remove the source', () async {
    vault.corruptPut = true;
    await expectLater(history.trash(entry()), throwsA(isA<VaultException>()));
    expect(await vault.read('v1'), bytes);
    expect(vault.log.where((e) => e.startsWith('remove:')), isEmpty);
  });
  test('existing matching metadata requires checksum verification', () async {
    vault.failRemove = true;
    await expectLater(history.trash(entry()), throwsA(isA<VaultException>()));
    vault.failRemove = false;
    vault.data['t1_v1'] = Uint8List(bytes.length);
    await expectLater(history.trash(entry()), throwsA(isA<VaultException>()));
    expect(await vault.read('v1'), bytes);
  });
  test('destination collision is never overwritten', () async {
    await vault.put(entry('t1_v1'), bytes);
    await expectLater(history.trash(entry()), throwsA(isA<VaultException>()));
    expect(vault.records.length, 2);
    expect(vault.log.where((e) => e.startsWith('remove:')), isEmpty);
  });
  test('restore collision preserves trash and conflicting original', () async {
    final trashed = await history.trash(entry());
    await vault.put(entry('v1', 'region'), bytes);
    await expectLater(history.restore(trashed), throwsA(isA<VaultException>()));
    expect(vault.records.length, 2);
    expect(vault.records['v1']!.kind, 'region');
  });
  test('restore interrupted trash verifies existing original', () async {
    vault.failRemove = true;
    await expectLater(history.trash(entry()), throwsA(isA<VaultException>()));
    vault.failRemove = false;
    final result = await history.restore(vault.records['t1_v1']!);
    expect(result.id, 'v1');
    expect(vault.records.keys, ['v1']);
  });
  test(
    '96 character IDs use bounded safe deterministic recovery IDs',
    () async {
      final original = entry('x' * 96);
      await vault.put(original, bytes);
      final trash = await history.trash(original);
      validateVaultEntry(trash);
      final restored = await history.restore(trash);
      validateVaultEntry(restored);
      expect(restored.name, original.name);
      expect(restored.kind, original.kind);
      expect(restored.sha256, original.sha256);
      expect(await vault.read(restored.id), bytes);
    },
  );
  test('long ID interrupted trash recovers actual original ID', () async {
    final original = entry('x' * 96);
    await vault.put(original, bytes);
    vault.failRemove = true;
    await expectLater(history.trash(original), throwsA(isA<VaultException>()));
    vault.failRemove = false;
    final restored = await history.restore(
      (await history.load()).trashed.single,
    );
    expect(restored.id, original.id);
  });
  test('traversal and oversized kind are rejected without mutation', () async {
    await expectLater(
      history.trash(entry('../v1')),
      throwsA(isA<VaultException>()),
    );
    await expectLater(
      history.trash(entry('v2', 'a' * 59)),
      throwsA(isA<VaultException>()),
    );
    expect(vault.records.keys, ['v1']);
    expect(vault.log, isEmpty);
  });
  test('multiple service instances serialize retries on one vault', () async {
    final results = await Future.wait([
      history.trash(entry()),
      VaultHistory(vault).trash(entry()),
    ]);
    expect(results[0].id, results[1].id);
    expect(vault.records.length, 1);
  });
  test(
    'native recycle survives reopen and leaves external source untouched',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'terra-history-synthetic-',
      );
      try {
        final externalSource = File('${root.path}/source.wld');
        await externalSource.writeAsBytes(bytes);
        final vaultRoot = Directory('${root.path}/vault');
        final native = NativeLocalVault(directory: () async => vaultRoot);
        await native.put(entry(), bytes);
        final trashed = await VaultHistory(native).trash(entry());
        final reopened = NativeLocalVault(directory: () async => vaultRoot);
        expect(
          (await VaultHistory(reopened).load()).trashed.single.toJson(),
          trashed.toJson(),
        );
        final restored = await VaultHistory(reopened).restore(trashed);
        expect(restored.toJson(), entry().toJson());
        expect(await reopened.read(restored.id), bytes);
        expect(await externalSource.readAsBytes(), bytes);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets('trash requires confirmation and restore is explicit', (
    tester,
  ) async {
    var trashCalls = 0;
    var restoreCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VaultHistoryPanel(
              entries: [entry()],
              onTrash: (_) async {
                trashCalls++;
              },
              onRestore: (_) async {
                restoreCalls++;
              },
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining(entry().sha256), findsOneWidget);
    await tester.tap(find.text('移入回收站'));
    await tester.pumpAndSettle();
    expect(trashCalls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(trashCalls, 0);
    await tester.tap(find.text('移入回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
    await tester.pumpAndSettle();
    expect(trashCalls, 1);
    final trash = await history.trash(entry());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultHistoryPanel(
            entries: [trash],
            onRestore: (_) async {
              restoreCalls++;
            },
          ),
        ),
      ),
    );
    expect(restoreCalls, 0);
    await tester.tap(find.text('恢复此版本'));
    await tester.pumpAndSettle();
    expect(restoreCalls, 1);
  });
  testWidgets('operation errors remain visible with exact metadata', (
    tester,
  ) async {
    final trash = await history.trash(entry());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VaultHistoryPanel(
            entries: [trash],
            onRestore: (_) async {
              throw const VaultException('synthetic checksum failure');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('恢复此版本'));
    await tester.pumpAndSettle();
    expect(find.textContaining('synthetic checksum failure'), findsOneWidget);
    expect(find.textContaining(trash.id), findsOneWidget);
  });
}
