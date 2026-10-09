// Opt in with ABC_CLOUD_PERF_REPORT. All HTTP is in-process MockClient traffic.
// Native vault I/O is real; operation-journal storage and authentication are
// injected memory adapters. This does not measure service/network/login latency.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/cloud/cloud.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/vault_native.dart';

import '../cloud_reference_contract_test.dart'
    show
        ReferenceService,
        PreviewEngine,
        account,
        envelope,
        saveId,
        operationId,
        saveJson,
        recommendationJson,
        recommendation;
import '../workspace_test.dart' show FakeEngine, FakeFiles;
import 'measurements.dart';

class _SyntheticAuth implements AuthProvider {
  @override
  Future<CloudSession> signIn() async => account('synthetic-benchmark-account');
  @override
  Future<void> signOut() async {}
}

void main() {
  final output = Platform.environment['ABC_CLOUD_PERF_REPORT'];
  test(
    'cloud protocol, guards, local commit and recovery operation timing',
    () async {
      final measurements = Measurements();
      measurements.report['suite'] = 'cloud-client-local';
      measurements.report['buildMode'] = 'flutter-test-debug-local-mocks';
      final methodology =
          measurements.report['methodology'] as Map<String, Object?>;
      methodology['timing'] = 'Awaited client protocol, state, hashing and real native-vault I/O latency. All HTTP responses and auth adapters are in-process mocks; no network/server/auth-provider timing.';
      methodology['memory'] = 'RSS is process-wide and includes the test VM and allocator capacity. ownedHandles counts benchmark-owned cloud/workspace controllers only. Empty ownership after cleanup is not a native/Dart heap or leak proof.';
      methodology['preview'] = 'World-upload preview uses a fixed repository-authored 2x2 PNG through a synthetic engine; actual WLD rendering latency is excluded and measured separately.';
      methodology['journal'] = 'Real CloudOperationJournal serialization and restart decoding over an injected memory store. SharedPreferences platform/plugin disk latency is not measured.';
      (measurements.report['gaps'] as List<String>).addAll([
        'No live account, authentication provider, network, cloud service, transfer moderation or generation job was contacted.',
        'No frame-time or UI responsiveness conclusion follows from these debug-mode operation timings.',
        'Native vault I/O is real; warm filesystem cache is not flushed. Binary fixtures are opaque synthetic protocol data, not claims of valid Terraria saves.',
        'Reported RSS is process-wide; zero owned benchmark controllers after cleanup is not a zero-allocation or leak-free proof.',
      ]);
      final root = await Directory.systemTemp.createTemp(
        'abc-cloud-performance-',
      );
      var status = 'failed';
      try {
        for (final length in [32 * 1024, 1024 * 1024]) {
          final fixtureId = 'synthetic-cloud-${length ~/ 1024}k';
          final bytes = Uint8List.fromList(
            List.generate(length, (index) => (index * 31 + 17) & 255),
          );
          measurements.fixture(
            fixtureId,
            'opaque-protocol-bytes',
            bytes.length,
            sha256: sha256.convert(bytes).toString(),
          );
          for (
            measurements.cycle = -1;
            measurements.cycle < measurements.warmup + measurements.cycles;
            measurements.cycle++
          ) {
            final service = ReferenceService();
            var uncertainTransfer = true;
            service.handler = (request) async {
              switch (request.url.path) {
                case '/viewer/cloud-saves/get':
                case '/viewer/cloud-saves/upload':
                  return envelope({...saveJson(), 'fileSize': bytes.length});
                case '/viewer/cloud-saves/list':
                  return envelope({
                    'list': [
                      {...saveJson(), 'fileSize': bytes.length},
                    ],
                  });
                case '/viewer/recommendations/list':
                  return envelope({
                    'list': [
                      {...recommendationJson(), 'fileSize': bytes.length},
                    ],
                  });
                case '/viewer/recommendations/get':
                  return envelope({
                    ...recommendationJson(),
                    'fileSize': bytes.length,
                  });
                case '/viewer/cloud-saves/download':
                case '/viewer/recommendations/download':
                  return http.Response.bytes(bytes, 200);
                case '/viewer/recommendations/download-ticket':
                  return envelope({
                    'operationId': operationId,
                    'downloadUrl':
                        '/viewer/recommendations/download?operationId=$operationId',
                    'fileName': 'synthetic-reference.wld',
                    'fileSize': bytes.length,
                    'expiresAt': DateTime.now()
                        .add(const Duration(minutes: 30))
                        .toUtc()
                        .toIso8601String(),
                  });
                case '/viewer/recommendations/transfer':
                  if (uncertainTransfer) {
                    uncertainTransfer = false;
                    throw http.ClientException('Synthetic lost response');
                  }
                  return service.response(request);
                default:
                  return service.response(request);
              }
            };
            final cloud = CloudBackend(
              api: service.api,
              auth: _SyntheticAuth(),
              operationStore: service.operations,
            );
            final local = NativeLocalVault(
              directory: () async =>
                  Directory('${root.path}/$fixtureId-${measurements.cycle}'),
            );
            final files = FakeFiles()
              ..next = PickedFile('synthetic.wld', bytes);
            final workspace = Workspace(
              engine: PreviewEngine(),
              files: files,
              vault: local,
              cloud: cloud,
            );
            CloudBackend? restored;
            Workspace? recovered;
            measurements.owners.addAll(['cloud', 'workspace']);
            measurements.memory('before-cycle');
            try {
              await measurements.measure(
                'cloud.auth.local_adapter_handoff',
                fixtureId,
                0,
                cloud.signIn,
              );
              expect(cloud.connected, isTrue);
              await measurements.measure(
                'cloud.session.validity_check',
                fixtureId,
                0,
                () async {
                  expect(cloud.session.valid, isTrue);
                },
              );
              await measurements.measure(
                'cloud.saves.list_json_decode',
                fixtureId,
                0,
                cloud.refreshSaves,
              );
              await measurements.measure(
                'cloud.recommendations.list_json_decode',
                fixtureId,
                0,
                cloud.loadRecommendations,
              );
              await measurements.measure(
                'cloud.help.json_decode',
                fixtureId,
                0,
                cloud.loadHelp,
              );
              await measurements.measure(
                'cloud.profile.read_whitelist',
                fixtureId,
                0,
                cloud.loadProfile,
              );
              await measurements.measure(
                'cloud.profile.validate_encode_commit',
                fixtureId,
                0,
                () => cloud.saveProfile({
                  'id': 7,
                  'nickname': 'Synthetic',
                  'avatar': '',
                }),
              );
              expect(cloud.error, isNull);
              await measurements.measure(
                'cloud.upload.prepare_snapshot',
                fixtureId,
                bytes.length,
                () => workspace.dispatch('cloudPrepareUpload'),
              );
              await measurements.measure(
                'cloud.upload.hash_duplicate_multipart_commit',
                fixtureId,
                bytes.length,
                () => workspace.dispatch('cloudUploadPrepared'),
              );
              expect(workspace.view.error, isEmpty);
              await measurements.measure(
                'cloud.download.binary_native_vault_commit',
                fixtureId,
                bytes.length,
                () => workspace.dispatch('cloudRecommendationDownload', {
                  'item': recommendation(),
                }),
              );
              expect(workspace.view.error, isEmpty);
              expect(workspace.view.files.length, 1);
              service.receiptStatus = 503;
              await measurements.measure(
                'cloud.receipt.pending_after_cached_adoption',
                fixtureId,
                bytes.length,
                () => workspace.dispatch('cloudRecommendationDownload', {
                  'item': recommendation(),
                }),
              );
              expect(workspace.view.error, isEmpty);
              expect(cloud.pendingReceiptCount, 1);
              service.receiptStatus = 200;
              restored = CloudBackend(
                api: service.api,
                session: cloud.session,
                operationStore: service.operations,
              );
              measurements.owners.add('restored-cloud');
              await measurements.measure(
                'cloud.receipt.restore_decode_retry',
                fixtureId,
                0,
                restored.retryRecommendationReceipts,
              );
              expect(restored.pendingReceiptCount, 0);
              await measurements.measure(
                'cloud.transfer.persist_uncertain_post',
                fixtureId,
                0,
                () => restored!.transferRecommendation(recommendation()),
              );
              expect(restored.error, isNotNull);
              await measurements.measure(
                'cloud.transfer.retry_same_request',
                fixtureId,
                0,
                () => restored!.transferRecommendation(recommendation()),
              );
              expect(
                restored.recommendationTransfers[saveId]!.status,
                'pending',
              );
              await measurements.measure(
                'cloud.transfer.query_completion',
                fixtureId,
                0,
                () => restored!.transferRecommendation(recommendation()),
              );
              expect(restored.recommendationTransfers[saveId]!.status, 'ready');
              recovered = Workspace(
                engine: FakeEngine(),
                files: FakeFiles(),
                vault: local,
              );
              measurements.owners.add('restored-workspace');
              await measurements.measure(
                'cloud.local_vault.restart_restore',
                fixtureId,
                bytes.length,
                recovered.initialize,
              );
              expect(recovered.view.files.length, 1);
              await measurements.measure(
                'cloud.cancel.before_transfer',
                fixtureId,
                bytes.length,
                () async {
                  final cancellation = CloudCancellation()..cancel();
                  await expectLater(
                    service.api.download(
                      cloud.session,
                      saveId,
                      expectedBytes: bytes.length,
                      cancellation: cancellation,
                    ),
                    throwsA(isA<CloudFailure>()),
                  );
                },
              );
              await measurements.measure(
                'cloud.errors.reject_invalid_ticket_destination',
                fixtureId,
                0,
                () async {
                  expect(
                    () => service.api.recommendationDownload(
                      cloud.session,
                      CloudRecommendationTicket(
                        operationId: operationId,
                        downloadUrl: 'https://other.invalid/file',
                        fileName: 'synthetic.wld',
                        fileSize: bytes.length,
                        expiresAt: DateTime.now().add(
                          const Duration(minutes: 1),
                        ),
                      ),
                    ),
                    throwsA(isA<CloudFailure>()),
                  );
                },
              );
              await measurements.measure(
                'cloud.auth.local_disconnect',
                fixtureId,
                0,
                cloud.signOut,
              );
              expect(cloud.connected, isFalse);
            } finally {
              await workspace.close();
              workspace.dispose();
              await recovered?.close();
              recovered?.dispose();
              restored?.dispose();
              cloud.dispose();
              measurements.owners.clear();
              measurements.memory('after-close');
            }
          }
        }
        status = 'passed';
      } finally {
        await measurements.write(output!, status);
        await root.delete(recursive: true);
      }
    },
    skip: output == null
        ? 'Set ABC_CLOUD_PERF_REPORT for opt-in local mock timing.'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
