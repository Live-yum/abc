import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/resources/online_resource_authority.dart';
import 'package:terraforge/resources/online_resource_normalizer.dart';
import 'package:terraforge/resources/online_resource_protocol.dart';
import 'package:terraforge/resources/online_resource_service.dart';
import 'package:terraforge/resources/online_resource_storage.dart';
import 'package:terraforge/resources/online_resource_transport.dart';

import 'support/online_resource_fixture.dart';

void main() {
  test(
    'transient authority read failure retries without resetting high water',
    () async {
      final fixture = OnlineFixture(), storage = FaultResourceStorage();
      final authority = OnlineResourceAuthority(
        storage,
        'https://resources.example.test',
      );
      await authority.accept(fixture.approval(sequence: '2'));
      storage.failRead = true;
      final restored = OnlineResourceAuthority(
        storage,
        'https://resources.example.test',
      );
      await expectLater(restored.restore(), throwsStateError);
      storage.failRead = false;
      await restored.restore();
      await expectLater(
        restored.accept(fixture.approval()),
        throwsFormatException,
      );
      restored.assertUsable(fixture.sha, restored.namespace);
    },
  );
  test(
    'disposal releases active views and rejects held guards or later tasks',
    () async {
      final service = OnlineResourceService(
        transport: FixtureResourceTransport(OnlineFixture()),
        storage: MemoryOnlineResourceStorage(),
      );
      await service.install();
      final guard = service.assertActiveUsable;
      service.dispose();
      expect(service.activeStore, isNull);
      expect(service.available, isNull);
      expect(service.activeManifestSha256, isNull);
      expect(guard, throwsStateError);
      await expectLater(service.install(), throwsStateError);
    },
  );
  test('expired stages are collected while active cache and approval ledger remain', () async {
    final a = OnlineFixture('A'), b = OnlineFixture('B');
    final storage = MemoryOnlineResourceStorage();
    var now = DateTime.utc(2026, 1, 1);
    final transport = FixtureResourceTransport(a)..add(b);
    final service = OnlineResourceService(
      transport: transport,
      storage: storage,
      now: () => now,
    );
    await service.install();
    transport.approvalBytes = b.approval(sequence: '2');
    transport.corruptPath = b.itemPath;
    await expectLater(service.install(), throwsFormatException);
    final ns = service.authority.namespace;
    final ledger = await storage.read('state', 'authority-$ns-0');
    final stage = 'staging-${b.sha}-$ns';
    expect(await storage.read('state', stage), isNotNull);
    now = now.add(const Duration(days: 8));
    final restarted = OnlineResourceService(
      transport: transport,
      storage: storage,
      now: () => now,
    );
    await restarted.initialize();
    expect(
      jsonDecode(utf8.decode((await storage.read('state', stage))!))['state'],
      'ABANDONED',
    );
    await restarted.clearInactiveCache();
    expect(await storage.read('state', stage), isNull);
    expect(await storage.read('releases', b.sha), isNull);
    expect(await storage.read('state', 'authority-$ns-0'), ledger);
    expect(restarted.activeStore!.catalog.byId('items', 17)!.name, 'A');
    transport.offline = true;
    final offline = OnlineResourceService(
      transport: transport,
      storage: storage,
    );
    await offline.initialize();
    expect(offline.activeStore!.catalog.byId('items', 17)!.name, 'A');
  });

  test(
    'transient ledger failure can be repaired without losing revocations',
    () async {
      final a = OnlineFixture('A'), b = OnlineFixture('B');
      final storage = FaultResourceStorage();
      final authority = OnlineResourceAuthority(
        storage,
        'https://resource.example.test',
      );
      await authority.accept(a.approval());
      storage.failAuthority = true;
      final next = b.approval(sequence: '2', revoked: [a.sha]);
      await expectLater(authority.accept(next), throwsStateError);
      expect(
        () => authority.assertUsable(b.sha, authority.namespace),
        throwsStateError,
      );
      storage.failAuthority = false;
      await authority.accept(next);
      authority.assertUsable(b.sha, authority.namespace);
      expect(
        () => authority.assertUsable(a.sha, authority.namespace),
        throwsStateError,
      );
      final offline = OnlineResourceAuthority(
        storage,
        'https://resource.example.test',
      );
      await offline.restore();
      expect(
        () => offline.assertUsable(a.sha, offline.namespace),
        throwsStateError,
      );
    },
  );

  test(
    'installs manifest-backed catalogs, normalizes IDs and restores offline',
    () async {
      final fixture = OnlineFixture(), storage = MemoryOnlineResourceStorage();
      final transport = FixtureResourceTransport(fixture);
      final service = OnlineResourceService(
        transport: transport,
        storage: storage,
      );
      await service.install();
      final store = service.activeStore!;
      expect(store.catalog.byId('items', 17)!.name, 'Synthetic');
      expect(store.catalog.byId('items', 17)!.fields['maxStack'], 9);
      expect(store.catalog.byId('research', 17)!.fields['required'], 3);
      expect(store.catalog.stableColorCandidates().single['blockID'], 42);
      expect(store.iconBytes(store.catalog.byId('items', 17)!), isNotEmpty);
      for (final family in onlineSupplementalFamilies) {
        expect(store.catalog.families, isNot(contains(family)));
      }
      expect(store.catalog.provenance['sourceManifestSha256'], fixture.sha);
      transport.offline = true;
      final restored = OnlineResourceService(
        transport: transport,
        storage: storage,
      );
      await restored.initialize();
      expect(restored.activeStore!.packSha256, store.packSha256);
      expect(restored.activeManifestSha256, fixture.sha);
      expect(
        (await storage.list()).where((e) => e.id.startsWith('staging-')),
        isEmpty,
      );
    },
  );

  test('hash mismatch and failed commit preserve active, retry uses verified objects', () async {
    final a = OnlineFixture('A'),
        b = OnlineFixture('B'),
        storage = FaultResourceStorage();
    final transport = FixtureResourceTransport(a)..add(b);
    final service = OnlineResourceService(
      transport: transport,
      storage: storage,
    );
    await service.install();
    final ns = service.authority.namespace;
    final active = await storage.read('state', 'active-$ns');
    transport.approvalBytes = b.approval(sequence: '2');
    transport.corruptPath = b.itemPath;
    await expectLater(service.install(), throwsFormatException);
    expect(service.activeStore!.catalog.byId('items', 17)!.name, 'A');
    expect(await storage.read('state', 'active-$ns'), active);
    transport.corruptPath = null;
    storage.failCommit = true;
    await expectLater(service.install(), throwsStateError);
    expect(await storage.read('state', 'active-$ns'), active);
    expect(service.activeStore!.catalog.byId('items', 17)!.name, 'A');
    final requested = transport.requests.length;
    storage.failCommit = false;
    await service.install();
    expect(transport.requests.skip(requested), ['releases/${b.sha}.json']);
    expect(service.activeStore!.catalog.byId('items', 17)!.name, 'B');
    expect(await storage.read('state', 'backup-$ns'), active);
  });

  test(
    'cancel writes a resumable checkpoint and retry does not trust its counts',
    () async {
      final fixture = OnlineFixture(), storage = MemoryOnlineResourceStorage();
      final transport = FixtureResourceTransport(fixture);
      final service = OnlineResourceService(
        transport: transport,
        storage: storage,
      );
      final reached = Completer<void>();
      transport.beforeFetch = (path, cancel) async {
        if (path == fixture.itemPath) {
          reached.complete();
          await cancel.signal;
          cancel.check();
        }
      };
      final install = service.install();
      final cancelled = expectLater(
        install,
        throwsA(isA<OnlineResourceCancelled>()),
      );
      await reached.future;
      service.cancel();
      await cancelled;
      expect(service.activeStore, isNull);
      final key = 'staging-${fixture.sha}-${service.authority.namespace}';
      final state = jsonDecode(
        utf8.decode((await storage.read('state', key))!),
      );
      expect(state['state'], 'PAUSED');
      expect(state['resumable'], isTrue);
      transport.beforeFetch = null;
      await service.install();
      expect(service.activeStore, isNotNull);
    },
  );

  test(
    'revocation before activation aborts, survives restart and rejects replay',
    () async {
      final fixture = OnlineFixture(), storage = MemoryOnlineResourceStorage();
      final transport = FixtureResourceTransport(fixture);
      final service = OnlineResourceService(
        transport: transport,
        storage: storage,
      );
      var approvals = 0;
      transport.beforeApproval = (_) async {
        if (++approvals == 2) {
          transport.approvalBytes = fixture.approval(
            sequence: '2',
            revoked: [fixture.sha],
            active: false,
          );
        }
      };
      await expectLater(service.install(), throwsStateError);
      expect(service.activeStore, isNull);
      final restored = OnlineResourceService(
        transport: transport,
        storage: storage,
      );
      await restored.initialize();
      await expectLater(
        restored.authority.accept(fixture.approval()),
        throwsFormatException,
      );
      expect(
        () => restored.authority.assertUsable(
          fixture.sha,
          restored.authority.namespace,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'observed revocation blocks held consumer even when ledger write fails',
    () async {
      final fixture = OnlineFixture(), storage = FaultResourceStorage();
      final service = OnlineResourceService(
        transport: FixtureResourceTransport(fixture),
        storage: storage,
      );
      await service.install();
      final guard = service.assertActiveUsable;
      storage.failAuthority = true;
      await expectLater(
        service.authority.accept(
          fixture.approval(
            sequence: '2',
            revoked: [fixture.sha],
            active: false,
          ),
        ),
        throwsStateError,
      );
      expect(guard, throwsStateError);
      expect(service.activeStore, isNull);
    },
  );

  test(
    'approval high water uses exact huge sequences and rejects equivocation',
    () async {
      final a = OnlineFixture('A'), b = OnlineFixture('B');
      final storage = MemoryOnlineResourceStorage();
      final authority = OnlineResourceAuthority(
        storage,
        'https://resources.example.test/api',
      );
      await authority.accept(a.approval(sequence: '9007199254740993'));
      await expectLater(
        authority.accept(b.approval(sequence: '9007199254740993')),
        throwsFormatException,
      );
      await expectLater(
        authority.accept(a.approval(sequence: '9007199254740992')),
        throwsFormatException,
      );
      await authority.accept(
        b.approval(sequence: '9007199254740994', revoked: [a.sha]),
      );
      await expectLater(
        authority.accept(b.approval(sequence: '9007199254740995')),
        throwsFormatException,
      );
      final restored = OnlineResourceAuthority(
        storage,
        'https://resources.example.test/api',
      );
      await restored.restore();
      expect(restored.current!.sequence, '9007199254740994');
      expect(
        () => restored.assertUsable(a.sha, restored.namespace),
        throwsStateError,
      );
    },
  );

  test(
    'corrupt ledger fails closed, no network state resets its high water',
    () async {
      final fixture = OnlineFixture(), storage = MemoryOnlineResourceStorage();
      final authority = OnlineResourceAuthority(
        storage,
        'https://resources.example.test/api',
      );
      await authority.accept(fixture.approval());
      await storage.write(
        'state',
        'authority-${authority.namespace}-0',
        Uint8List.fromList([1, 2]),
      );
      final restored = OnlineResourceAuthority(
        storage,
        'https://resources.example.test/api',
      );
      await restored.restore();
      await expectLater(
        restored.accept(fixture.approval(sequence: '2')),
        throwsStateError,
      );
    },
  );

  test('bounded gzip rejects declaration underflow and invalid CRC', () {
    final fixture = OnlineFixture();
    final manifest = OnlineManifest.parse(fixture.manifest, fixture.sha);
    final ref = manifest.families['items']!.single.object;
    final tiny = OnlineObjectRef.parse({...ref.raw, 'decodedBytes': 1});
    expect(() => tiny.decode(fixture.files[ref.path]!), throwsFormatException);
    final tooLarge = OnlineObjectRef.parse({
      ...ref.raw,
      'decodedBytes': ref.decodedBytes! + 1,
    });
    expect(
      () => tooLarge.decode(fixture.files[ref.path]!),
      throwsFormatException,
    );
    final bytes = Uint8List.fromList(fixture.files[ref.path]!);
    bytes[bytes.length - 8] ^= 1;
    final sha = resourceDigest(bytes);
    final badCrc = OnlineObjectRef.parse({
      ...ref.raw,
      'path': 'objects/${sha.substring(0, 2)}/$sha.json.gz',
      'sha256': sha,
    });
    expect(() => badCrc.decode(bytes), throwsA(anything));
  });

  test(
    'manifest and object paths reject traversal, mismatched digests and sizes',
    () {
      final fixture = OnlineFixture();
      expect(
        () => OnlineManifest.parse(fixture.manifest, 'a' * 64),
        throwsFormatException,
      );
      expect(
        () => OnlineObjectRef.parse({
          'path': '../secret',
          'sha256': 'a' * 64,
          'bytes': 1,
        }),
        throwsFormatException,
      );
      expect(
        () => normalizeResourceEndpoint('http://example.test'),
        throwsFormatException,
      );
      expect(
        () => normalizeResourceEndpoint('https://user:pass@example.test'),
        throwsFormatException,
      );
      expect(
        () => normalizeResourceEndpoint('https://example.test/?token=secret'),
        throwsFormatException,
      );
      expect(
        parseResourceJson(
          Uint8List.fromList(
            utf8.encode(
              r'{"id":9007199254740993,"text":"a\"9007199254740993"}',
            ),
          ),
        ),
        {'id': '9007199254740993', 'text': 'a"9007199254740993'},
      );
    },
  );
}
