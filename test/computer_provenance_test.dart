import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/domain/computer_provenance.dart';
import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/platform/vault_native.dart';

class _MemoryVault implements LocalVault {
  final entries = <String, VaultEntry>{};
  final data = <String, Uint8List>{};
  bool failList = false;
  bool failRead = false;
  bool failPut = false;
  bool failAfterPut = false;
  bool failRemove = false;
  bool ignoreRemove = false;
  bool corruptPut = false;
  bool mismatchedMetadata = false;
  Completer<void>? holdPut;
  Completer<void>? holdRead;
  int putCalls = 0;
  int readCalls = 0;

  @override
  Future<List<VaultEntry>> list() async {
    if (failList) throw const VaultException('list failed');
    return entries.values.toList();
  }

  @override
  Future<Uint8List> read(String id) async {
    readCalls++;
    await holdRead?.future;
    if (failRead) throw const VaultException('read failed');
    return Uint8List.fromList(data[id]!);
  }

  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) async {
    putCalls++;
    validateVaultBytes(entry, bytes);
    await holdPut?.future;
    if (failPut) throw const VaultException('put failed');
    if (entries.containsKey(entry.id)) {
      throw const VaultException('immutable');
    }
    entries[entry.id] = mismatchedMetadata
        ? _copyEntry(entry, sha256: 'f' * 64)
        : entry;
    data[entry.id] = corruptPut
        ? Uint8List(bytes.length)
        : Uint8List.fromList(bytes);
    if (failAfterPut) throw const VaultException('put response lost');
  }

  @override
  Future<void> remove(String id) async {
    if (failRemove) throw const VaultException('remove failed');
    if (ignoreRemove) return;
    entries.remove(id);
    data.remove(id);
  }
}

VaultEntry _copyEntry(VaultEntry entry, {String? sha256, int? size}) =>
    VaultEntry(
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      sha256: sha256 ?? entry.sha256,
      size: size ?? entry.size,
      modified: entry.modified,
    );

ComputerProvenanceRecord _record(int index, {Uint8List? image, int? pulses}) =>
    ComputerProvenanceRecord(
      wldSha256: index.toRadixString(16).padLeft(64, '0'),
      twldSha256: (index + 100).toRadixString(16).padLeft(64, '0'),
      programName: '程序-$index.bin',
      programImage: image ?? Uint8List.fromList([index, 0, 0, 0]),
      physicalPulses: pulses,
    );

Map<String, dynamic> _json([ComputerProvenanceRecord? record]) => jsonDecode(
  ComputerProvenanceRegistry().register(record ?? _record(1)).encode(),
) as Map<String, dynamic>;

void main() {
  test('exact pair and image metadata survive codec without source bytes', () {
    final record = _record(1, pulses: 12345);
    final encoded = ComputerProvenanceRegistry().register(record).encode();
    final decoded = ComputerProvenanceRegistry.decode(encoded);
    final restored = decoded.find(record.wldSha256, record.twldSha256)!;
    expect(restored.baseProfileSha256, ComputerrariaComputer.sourceSha256);
    expect(restored.programKnown, isTrue);
    expect(restored.programName, '程序-1.bin');
    expect(restored.programImage, [1, 0, 0, 0]);
    expect(restored.physicalPulses, 12345);
    expect(restored.programSha256, record.programSha256);
    expect(decoded.find(record.wldSha256, _record(2).twldSha256), isNull);
    expect(decoded.find(_record(2).wldSha256, record.twldSha256), isNull);
    expect(decoded.find('程序-1.bin', record.twldSha256), isNull);
    expect(encoded, isNot(contains('worldBytes')));
    expect(encoded, isNot(contains('path')));
  });

  test('verified empty ROM stays distinct from a loaded zero program', () {
    final empty = ComputerProvenanceRecord(
      wldSha256: 'a' * 64,
      twldSha256: 'b' * 64,
      programName: null,
      programImage: Uint8List(0),
    );
    final registry = ComputerProvenanceRegistry.decode(
      ComputerProvenanceRegistry().register(empty).encode(),
    );
    expect(registry.records.single.programKnown, isFalse);
    expect(registry.records.single.programImage, isEmpty);
    expect(registry.records.single.physicalPulses, isNull);
    expect(_record(0).programKnown, isTrue);
  });

  test('input, output images and record collection cannot mutate evidence', () {
    final input = Uint8List.fromList([1, 0, 255, 0]);
    final record = _record(1, image: input);
    final registry = ComputerProvenanceRegistry().register(record);
    input[0] = 0;
    record.programImage.fillRange(0, 4, 9);
    registry.find(record.wldSha256, record.twldSha256)!.programImage[2] = 0;
    expect(record.programImage, [1, 0, 255, 0]);
    expect(() => registry.records.add(_record(2)), throwsUnsupportedError);
    final restored = ComputerProvenanceRegistry.decode(registry.encode());
    restored.records.single.programImage[0] = 0;
    expect(restored.records.single.programImage, [1, 0, 255, 0]);
  });

  test('retained ROM extent clears a previous longer program tail', () {
    final record = _record(
      1,
      image: Uint8List.fromList([1, 0, 0, 0, 2, 0, 0, 0]),
    );
    final restored = ComputerProvenanceRegistry.decode(
      ComputerProvenanceRegistry().register(record).encode(),
    ).records.single;
    final writes = ComputerrariaComputer.programWrites(
      restored.programImage,
      Uint8List.fromList([1, 0, 0, 0]),
    ).expand((batch) => batch).toList();
    final (x, y) = ComputerrariaComputer.romLamp(4, 1);
    expect(writes, [x, y, 0, 0]);
  });

  test(
    'duplicates replace and refresh age; oldest pair eviction is stable',
    () {
      var registry = ComputerProvenanceRegistry();
      for (var index = 1; index <= 8; index++) {
        registry = registry.register(_record(index));
      }
      registry = registry.register(_record(1, pulses: 17));
      expect(registry.records.length, 8);
      expect(registry.records.last.physicalPulses, 17);
      registry = registry.register(_record(9));
      expect(registry.records.length, 8);
      expect(
        registry.find(_record(2).wldSha256, _record(2).twldSha256),
        isNull,
      );
      expect(
        registry.find(_record(1).wldSha256, _record(1).twldSha256),
        isNotNull,
      );
      expect(
        ComputerProvenanceRegistry.decode(registry.encode()).encode(),
        registry.encode(),
      );
    },
  );

  test('eight maximum ROM records fit the bounded JSON budget', () {
    var registry = ComputerProvenanceRegistry();
    final image = Uint8List(ComputerrariaComputer.romBytes);
    image[image.length - 1] = 255;
    for (var index = 1; index <= 8; index++) {
      registry = registry.register(_record(index, image: image));
    }
    final encoded = registry.encode();
    expect(
      utf8.encode(encoded).length,
      lessThan(ComputerProvenanceRegistry.maxJsonBytes),
    );
    expect(
      ComputerProvenanceRegistry.decode(encoded).records.last.programImage.last,
      255,
    );
  });

  test(
    'constructor rejects incomplete images, names, digests and counters',
    () {
      for (final size in [1, 3, 5, ComputerrariaComputer.romBytes + 4]) {
        expect(() => _record(1, image: Uint8List(size)), throwsFormatException);
      }
      for (final name in ['', ' ', 'x' * 256, 'bad\nname', '/source/rom.bin']) {
        expect(
          () => ComputerProvenanceRecord(
            wldSha256: 'a' * 64,
            twldSha256: 'b' * 64,
            programName: name,
            programImage: Uint8List(4),
          ),
          throwsFormatException,
        );
      }
      expect(() => _record(1, image: Uint8List(0)), throwsFormatException);
      expect(() => _record(1, pulses: -1), throwsFormatException);
      expect(() => _record(1, pulses: 9007199254740992), throwsFormatException);
      expect(
        () => ComputerProvenanceRecord(
          wldSha256: 'A' * 64,
          twldSha256: 'b' * 64,
          programName: null,
          programImage: Uint8List(0),
        ),
        throwsFormatException,
      );
      expect(
        () => ComputerProvenanceRecord(
          wldSha256: 'a' * 64,
          twldSha256: 'b' * 64,
          programName: null,
          programImage: Uint8List(4),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'malformed version, profile, records and unknown fields fail closed',
    () {
      final mutations = <void Function(Map<String, dynamic>)>[
        (j) => j['format'] = 'other',
        (j) => j['version'] = 2,
        (j) => j['version'] = 1.0,
        (j) => j['baseProfileSha256'] = 'a' * 64,
        (j) => j['extra'] = true,
        (j) => j['records'] = {},
        (j) => (j['records'] as List).add((j['records'] as List).single),
        (j) => j['records'] = List.generate(9, (i) => _record(i).toJson()),
      ];
      for (final mutate in mutations) {
        final json = _json();
        mutate(json);
        expect(
          () => ComputerProvenanceRegistry.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
      for (final encoded in [
        'null',
        '[]',
        '{',
        ' ' * (ComputerProvenanceRegistry.maxJsonBytes + 1),
      ]) {
        expect(
          () => ComputerProvenanceRegistry.decode(encoded),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'ROM hash, metadata, base64 and explicit known status are validated',
    () {
      final changes = <String, Object?>{
        'wldSha256': 'A' * 64,
        'twldSha256': 'b' * 63,
        'programName': 12,
        'programKnown': false,
        'programLength': 3,
        'programSha256': 'f' * 64,
        'programImage': '!!!!!!!!',
        'physicalPulses': -1,
        'unexpected': true,
      };
      for (final change in changes.entries) {
        final json = _json();
        ((json['records'] as List).single as Map)[change.key] = change.value;
        expect(
          () => ComputerProvenanceRegistry.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
      for (final key in _record(1).toJson().keys) {
        final json = _json();
        ((json['records'] as List).single as Map).remove(key);
        expect(
          () => ComputerProvenanceRegistry.decode(jsonEncode(json)),
          throwsFormatException,
        );
      }
    },
  );

  test('null vault retains only this store in memory', () async {
    final store = ComputerProvenanceStore();
    final record = _record(1);
    expect(store.available, isTrue);
    await store.register(record);
    await store.load();
    expect(store.find(record.wldSha256, record.twldSha256), same(record));
    expect(
      ComputerProvenanceStore().find(record.wldSha256, record.twldSha256),
      isNull,
    );
  });

  test('pair stays invisible until the persistent put has completed', () async {
    final vault = _MemoryVault()..holdPut = Completer<void>();
    final store = ComputerProvenanceStore(vault: vault);
    await store.load();
    final record = _record(1);
    final saving = store.register(record);
    while (vault.putCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.find(record.wldSha256, record.twldSha256), isNull);
    vault.holdPut!.complete();
    await saving;
    expect(store.find(record.wldSha256, record.twldSha256), isNotNull);
    final reopened = ComputerProvenanceStore(vault: vault);
    await reopened.load();
    expect(reopened.registry.encode(), store.registry.encode());
    expect(vault.entries.length, 1);
    expect(
      ComputerProvenanceStore.isEntry(vault.entries.values.single),
      isTrue,
    );
  });

  test('committed pair stays invisible until read-back is verified', () async {
    final vault = _MemoryVault()..holdRead = Completer<void>();
    final store = ComputerProvenanceStore(vault: vault);
    await store.load();
    final record = _record(1);
    final saving = store.register(record);
    while (vault.readCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(vault.entries.length, 1);
    expect(store.find(record.wldSha256, record.twldSha256), isNull);
    vault.holdRead!.complete();
    await saving;
    expect(store.find(record.wldSha256, record.twldSha256), isNotNull);
  });

  for (final failure in ['put', 'afterPut', 'corruptPut', 'metadata']) {
    test('$failure never exposes a newly unverified persistent pair', () async {
      final vault = _MemoryVault()
        ..failPut = failure == 'put'
        ..failAfterPut = failure == 'afterPut'
        ..corruptPut = failure == 'corruptPut'
        ..mismatchedMetadata = failure == 'metadata';
      final store = ComputerProvenanceStore(vault: vault);
      final record = _record(1);
      await expectLater(store.register(record), throwsA(isA<VaultException>()));
      expect(store.available, isFalse);
      expect(store.registry.records, isEmpty);
      expect(store.find(record.wldSha256, record.twldSha256), isNull);
      expect(store.diagnostic, contains('普通世界'));
      if (failure == 'afterPut') {
        vault.failAfterPut = false;
        await store.load();
        expect(store.find(record.wldSha256, record.twldSha256), isNotNull);
        expect(store.error, isNull);
      }
    });
  }

  for (final failure in ['read', 'list', 'checksum', 'payload', 'oversize']) {
    test(
      '$failure clears prior recognition without using stale data',
      () async {
        final vault = _MemoryVault();
        final store = ComputerProvenanceStore(vault: vault);
        final record = _record(1);
        await store.register(record);
        final entry = vault.entries.values.single;
        vault.failRead = failure == 'read';
        vault.failList = failure == 'list';
        if (failure == 'checksum') vault.data[entry.id]![0] ^= 1;
        if (failure == 'payload') {
          final bytes = Uint8List.fromList(utf8.encode('{}'));
          vault.data[entry.id] = bytes;
          vault.entries[entry.id] = _copyEntry(
            entry,
            size: bytes.length,
            sha256: crypto.sha256.convert(bytes).toString(),
          );
        }
        if (failure == 'oversize') {
          vault.entries[entry.id] = _copyEntry(
            entry,
            size: ComputerProvenanceRegistry.maxJsonBytes + 1,
          );
        }
        await expectLater(store.load(), throwsA(isA<Exception>()));
        expect(store.available, isFalse);
        expect(store.registry.records, isEmpty);
        expect(store.find(record.wldSha256, record.twldSha256), isNull);
      },
    );
  }

  test(
    'failed cleanup remains bounded and newest corruption never falls back',
    () async {
      final vault = _MemoryVault();
      final store = ComputerProvenanceStore(vault: vault);
      await store.register(_record(1));
      vault.failRemove = true;
      await expectLater(
        store.register(_record(2)),
        throwsA(isA<VaultException>()),
      );
      expect(vault.entries.length, 2);
      for (var index = 3; index < 6; index++) {
        await expectLater(
          store.register(_record(index)),
          throwsA(isA<VaultException>()),
        );
        expect(vault.entries.length, 2);
      }
      final latest = vault.entries.keys.toList()..sort();
      vault.data[latest.last]![0] ^= 1;
      await expectLater(store.load(), throwsA(isA<VaultException>()));
      expect(store.find(_record(1).wldSha256, _record(1).twldSha256), isNull);
      expect(store.available, isFalse);
    },
  );

  test('silent cleanup failure is detected and can safely recover', () async {
    final vault = _MemoryVault();
    final store = ComputerProvenanceStore(vault: vault);
    await store.register(_record(1));
    vault.ignoreRemove = true;
    await expectLater(
      store.register(_record(2)),
      throwsA(isA<VaultException>()),
    );
    expect(vault.entries.length, 2);
    vault.ignoreRemove = false;
    await store.register(_record(3));
    expect(vault.entries.length, 1);
    expect(store.registry.records.length, 3);
  });

  test(
    'stores sharing a vault serialize and merge current persisted evidence',
    () async {
      final vault = _MemoryVault();
      final first = ComputerProvenanceStore(vault: vault);
      final second = ComputerProvenanceStore(vault: vault);
      await Future.wait([
        first.register(_record(1)),
        second.register(_record(2)),
      ]);
      final reopened = ComputerProvenanceStore(vault: vault);
      await reopened.load();
      expect(reopened.registry.records.length, 2);
      expect(vault.entries.length, 1);
      for (var index = 3; index <= 12; index++) {
        await second.register(_record(index));
      }
      expect(second.registry.records.length, 8);
      expect(second.registry.records.first.wldSha256, _record(5).wldSha256);
      expect(vault.entries.length, 1);
    },
  );

  test(
    'native immutable vault survives reopen with exact program bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'computer-provenance-',
      );
      try {
        final store = ComputerProvenanceStore(
          vault: NativeLocalVault(directory: () async => root),
        );
        await store.register(_record(1, pulses: 23));
        await store.register(_record(2));
        final reopened = ComputerProvenanceStore(
          vault: NativeLocalVault(directory: () async => root),
        );
        await reopened.load();
        expect(reopened.registry.encode(), store.registry.encode());
        expect(reopened.registry.records.first.physicalPulses, 23);
        expect((await reopened.vault!.list()).length, 1);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
