// Opt in with ABC_RESOURCE_PERF_REPORT. Every transport response is synthetic;
// timings are client CPU + actual app-private storage, never network latency.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/platform/resource_store.dart';
import 'package:terraforge/resources/online_resource_normalizer.dart';
import 'package:terraforge/resources/online_resource_protocol.dart';
import 'package:terraforge/resources/online_resource_service.dart';
import 'package:terraforge/resources/online_resource_storage.dart';
import 'package:terraforge/resources/online_resource_storage_native.dart';
import 'package:terraforge/resources/online_resource_transport.dart';

import '../support/online_resource_fixture.dart';
import 'measurements.dart';

class _MeasuredStorage implements OnlineResourceStorage {
  _MeasuredStorage(this.inner, this.bench, this.fixture);
  final OnlineResourceStorage inner;
  final Measurements bench;
  final String fixture;
  bool failCommit = false;
  @override
  Future<Uint8List?> read(String kind, String id) => bench.measure(
    'storage.read.$kind',
    fixture,
    0,
    () => inner.read(kind, id),
  );
  @override
  Future<void> write(String kind, String id, Uint8List bytes) => bench.measure(
    'storage.write.$kind',
    fixture,
    bytes.length,
    () => inner.write(kind, id, bytes),
  );
  @override
  Future<List<OnlineResourceEntry>> list() =>
      bench.measure('storage.list', fixture, 0, inner.list);
  @override
  Future<void> remove(String kind, String id) => bench.measure(
    'storage.remove.$kind',
    fixture,
    0,
    () => inner.remove(kind, id),
  );
  @override
  Future<void> commitActive(String namespace, Uint8List bytes) async {
    if (failCommit) throw StateError('Synthetic atomic-commit fault');
    await bench.measure(
      'storage.activate.atomic',
      fixture,
      bytes.length,
      () => inner.commitActive(namespace, bytes),
    );
  }
}

Future<Object> _failure(Future<void> action) async {
  try {
    await action;
  } catch (failure) {
    return failure;
  }
  throw StateError('Expected operation to reject');
}

void main() {
  final output = Platform.environment['ABC_RESOURCE_PERF_REPORT'];
  test(
    'measured online-resource lifecycle preserves integrity and closes owners',
    () async {
      final bench = Measurements();
      final rows = int.parse(
        Platform.environment['ABC_RESOURCE_PERF_ROWS'] ??
            {'ci': '128', 'local': '4096', 'soak': '8192'}[bench.tier]!,
      );
      expect(bench.cycles, greaterThanOrEqualTo(3));
      expect(bench.warmup, greaterThanOrEqualTo(1));
      final icons = int.parse(
        Platform.environment['ABC_RESOURCE_PERF_ICONS'] ??
            {'ci': '16', 'local': '128', 'soak': '256'}[bench.tier]!,
      );
      final a = OnlineFixture('Synthetic A', rows, icons);
      final b = OnlineFixture('Synthetic B', rows, icons);
      final c = OnlineFixture('Synthetic C', rows, icons);
      final fixture = 'synthetic-resource-$rows-items-$icons-icons';
      final wireBytes = a.files.values.fold<int>(0, (sum, v) => sum + v.length);
      bench.report['suite'] = 'online-resource-actions';
      bench.report['buildMode'] =
          'flutter-test-debug-client-native-file-storage';
      bench.report['methodology'] = {
        'clock': 'Stopwatch',
        'cold': 'First process invocation; OS cache is not flushed',
        'warmupCycles': bench.warmup,
        'measuredCycles': bench.cycles,
        'timing': 'Synthetic in-process transport, real Dart decode/validation/normalization and native file operations. Not live HTTP latency or frame smoothness.',
        'nestedTimings': 'Installer aggregates include the separately reported storage samples; they are not additive.',
        'storageSamples': 'Each file operation is one sample. Read/list bytesPerOperation is unspecified (0); file-write sizes vary by object.',
        'memory': 'Process-wide RSS after disposed resource-service owners; includes the test VM, allocators and fixture bytes. Live Dart/native heaps and browser memory are not inferred.',
      };
      bench.fixture(
        fixture,
        'original-gzip-manifest-row-catalog-and-$icons-pngs',
        wireBytes,
        sha256: resourceDigest(
          utf8.encode(
            jsonEncode([
              for (final source in [a, b, c])
                [
                  for (final path in (source.files.keys.toList()..sort()))
                    [path, base64Encode(source.files[path]!)],
                ],
            ]),
          ),
        ),
      );
      (bench.report['gaps'] as List<String>).addAll(<String>[
        'No real network, production asset download, credentials or account calls.',
        '$icons distinct original 1x1 PNGs; this exercises file count and catalog/storage costs, not representative atlas decoding.',
        'Debug Flutter test timings are not a frame-rate or mobile-device acceptance claim.',
        'IndexedDB persistence has separate transaction tests; this suite measures native files.',
      ]);
      try {
        for (var cycle = -1; cycle < bench.warmup + bench.cycles; cycle++) {
          bench.cycle = cycle;
          final temporary = await Directory.systemTemp.createTemp(
            'abc-resource-perf-',
          );
          final root = Directory(await temporary.resolveSymbolicLinks());
          final storage = _MeasuredStorage(
            NativeOnlineResourceStorage(directory: root),
            bench,
            fixture,
          );
          final transport = FixtureResourceTransport(a)
            ..add(b)
            ..add(c);
          final service = OnlineResourceService(
            transport: transport,
            storage: storage,
          );
          bench.owners.add('installer');
          bench.memory('before-open');
          try {
            await bench.measure(
              'initialize.empty',
              fixture,
              0,
              service.initialize,
            );
            await bench.measure(
              'approval.check.manifest',
              fixture,
              a.manifest.length,
              service.checkForUpdate,
            );
            expect(service.available!.sha256, a.sha);
            final manifest = OnlineManifest.parse(a.manifest, a.sha);
            final itemRef = manifest.families['items']!.single.object;
            final wire = await bench.measure(
              'download.mock.object',
              fixture,
              itemRef.bytes,
              () => transport.fetch(
                itemRef.path,
                a.sha,
                itemRef.bytes,
                OnlineResourceCancellation(),
              ),
            );
            final decoded = await bench.measure(
              'decode.gzip.sha.crc',
              fixture,
              itemRef.bytes,
              () async => itemRef.decode(wire),
            );
            await bench.measure(
              'validate.decoded.json',
              fixture,
              decoded.length,
              () async => itemRef.validateDecoded(decoded),
            );
            final normalized = await bench.measure(
              'normalize.abcpack1',
              fixture,
              wireBytes,
              () => normalizeOnlineResources(
                manifest: manifest,
                authorityEndpoint: transport.authorityEndpoint,
                authorityId: 'synthetic-authority',
                readObject: (ref) async => ref.decode(a.files[ref.path]!),
                readImage: (texture) async => a.files[texture.object.path]!,
                check: () {},
              ),
            );
            final verified = await bench.measure(
              'validate.abcpack1',
              fixture,
              normalized.length,
              () async => ResourceStore.importPack(normalized),
            );
            expect(verified.catalog.families['items']!.length, rows);
            await bench.measure(
              'install.full',
              fixture,
              wireBytes,
              service.install,
            );
            expect(service.activeManifestSha256, a.sha);
            expect(
              service.activeStore!.catalog.families['research']!.length,
              rows,
            );
            expect(
              service.activeStore!.catalog
                  .stableColorCandidates()
                  .single['blockID'],
              42,
            );

            transport.offline = true;
            final restored = OnlineResourceService(
              transport: transport,
              storage: storage,
            );
            bench.owners.add('offline-reader');
            try {
              await bench.measure(
                'initialize.offline.restore',
                fixture,
                normalized.length,
                restored.initialize,
              );
              expect(
                restored.activeStore!.packSha256,
                service.activeStore!.packSha256,
              );
            } finally {
              restored.dispose();
              bench.owners.remove('offline-reader');
            }
            transport.offline = false;
            final previousRequests = transport.requests.length;
            await bench.measure(
              'install.cached.revalidate',
              fixture,
              normalized.length,
              service.install,
            );
            expect(transport.requests.skip(previousRequests), [
              'releases/${a.sha}.json',
            ]);

            transport.approvalBytes = b.approval(sequence: '2');
            final reached = Completer<void>();
            transport.beforeFetch = (path, cancel) async {
              if (path == b.itemPath) {
                reached.complete();
                await cancel.signal;
                cancel.check();
              }
            };
            final paused = _failure(service.install());
            await reached.future;
            await bench.measure('cancel.inflight', fixture, 0, () async {
              service.cancel();
              expect(await paused, isA<OnlineResourceCancelled>());
            });
            expect(service.activeManifestSha256, a.sha);
            transport.beforeFetch = null;
            await bench.measure(
              'install.resume',
              fixture,
              wireBytes,
              service.install,
            );
            expect(service.activeManifestSha256, b.sha);

            transport.approvalBytes = c.approval(sequence: '3');
            transport.corruptPath = c.itemPath;
            await bench.measure(
              'install.reject.hash',
              fixture,
              wireBytes,
              () async {
                expect(
                  await _failure(service.install()),
                  isA<FormatException>(),
                );
              },
            );
            expect(service.activeManifestSha256, b.sha);
            transport.corruptPath = null;
            storage.failCommit = true;
            await bench.measure(
              'install.rollback.commit-fault',
              fixture,
              wireBytes,
              () async {
                expect(await _failure(service.install()), isA<StateError>());
              },
            );
            expect(service.activeManifestSha256, b.sha);
            storage.failCommit = false;
            await bench.measure(
              'install.retry.atomic',
              fixture,
              wireBytes,
              service.install,
            );
            expect(service.activeManifestSha256, c.sha);
            final activeGuard = service.assertActiveUsable;
            transport.approvalBytes = c.approval(
              sequence: '4',
              revoked: [c.sha],
              active: false,
            );
            await bench.measure('approval.revoke.active', fixture, 0, () async {
              expect(
                await _failure(service.checkForUpdate()),
                isA<StateError>(),
              );
            });
            expect(activeGuard, throwsStateError);
            expect(service.activeStore, isNull);
            await bench.measure(
              'cache.collect.inactive',
              fixture,
              wireBytes,
              service.clearInactiveCache,
            );
            expect(await storage.read('releases', a.sha), isNull);
            expect(
              await storage.read(
                'state',
                'authority-${service.authority.namespace}-0',
              ),
              isNotNull,
            );
            bench.memory('before-close');
          } finally {
            service.dispose();
            bench.owners.remove('installer');
            await temporary.delete(recursive: true);
            bench.memory('after-close');
            expect(bench.owners, isEmpty);
          }
        }
        await bench.write(output!, 'passed');
      } catch (_) {
        await bench.write(output!, 'failed');
        rethrow;
      }
    },
    skip: output == null ? 'Set ABC_RESOURCE_PERF_REPORT to opt in' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
