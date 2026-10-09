import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/cloud/cloud.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/platform/vault.dart';
import 'package:terraforge/ui/cloud_workspace_panel.dart';

import 'workspace_test.dart' show FakeEngine, FakeFiles;
import 'support/cloud_preview.dart';

const saveId = '11111111-1111-4111-8111-111111111111';
const operationId = '22222222-2222-4222-8222-222222222222';
const requestId = '33333333-3333-4333-8333-333333333333';
CloudSession account([String id = 'account-a']) => CloudSession(
  accessToken: 'in-memory-token-$id',
  accountId: id,
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);
Map<String, dynamic> saveJson({String status = 'ready'}) => {
  'id': saveId,
  'kind': 'world',
  'fileName': 'reference.wld',
  'fileSize': 4,
  'status': status,
};
Map<String, dynamic> recommendationJson({bool visible = true}) => {
  ...saveJson(),
  'title': 'Synthetic reference',
  'description': 'Synthetic test data only',
  'visible': visible,
  'liked': false,
  'likeCount': 1,
  'downloadCount': 2,
  'metadata': {'name': 'Synthetic'},
};
CloudRecommendation recommendation() =>
    CloudRecommendation.fromJson(recommendationJson());
http.Response envelope(Object? data) =>
    http.Response(jsonEncode({'code': 0, 'data': data}), 200);

class PreviewEngine extends FakeEngine {
  bool failUploadPreview = false;
  @override
  Future<Uint8List?> preview(EngineDocument doc) async =>
      failUploadPreview && handles[doc.handle]?.first == 1
      ? null
      : syntheticCloudPreview();
}

class MemoryOperations implements CloudOperationStore {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw const CloudFailure('Storage unavailable');
    values[key] = value;
  }
}

class MemoryVault implements LocalVault {
  final entries = <String, VaultEntry>{};
  final content = <String, Uint8List>{};
  bool failWrites = false, corruptRead = false;
  @override
  Future<List<VaultEntry>> list() async => entries.values.toList();
  @override
  Future<void> put(VaultEntry entry, Uint8List bytes) async {
    if (failWrites) throw const VaultException('Storage full');
    validateVaultBytes(entry, bytes);
    entries[entry.id] = entry;
    content[entry.id] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> read(String id) async =>
      corruptRead ? Uint8List(4) : Uint8List.fromList(content[id]!);
  @override
  Future<void> remove(String id) async {
    entries.remove(id);
    content.remove(id);
  }
}

class ReferenceService {
  final requests = <http.Request>[];
  final operations = MemoryOperations();
  late final HttpCloudApi api = HttpCloudApi(
    config: CloudServiceConfig.viewer(
      baseUri: Uri.parse('https://service.example/'),
    ),
    client: MockClient((request) async {
      requests.add(request);
      expect(request.followRedirects, isFalse);
      expect(request.url.origin, 'https://service.example');
      return handler?.call(request) ?? response(request);
    }),
  );
  Future<http.Response> Function(http.Request)? handler;
  int receiptStatus = 200;
  bool visible = true;
  String latestStatus = 'ready';
  String ticketUrl =
      '/viewer/recommendations/download?operationId=$operationId';
  Uint8List bytes = Uint8List.fromList([1, 2, 3, 4]);
  http.Response response(http.Request request) {
    switch (request.url.path) {
      case '/viewer/cloud-saves/get':
        return envelope(saveJson(status: latestStatus));
      case '/viewer/cloud-saves/list':
        return envelope({
          'list': [saveJson()],
        });
      case '/viewer/cloud-saves/download':
      case '/viewer/recommendations/download':
        return http.Response.bytes(bytes, 200);
      case '/viewer/cloud-saves/duplicate':
        return envelope(null);
      case '/viewer/cloud-saves/upload':
        return envelope(saveJson());
      case '/viewer/cloud-saves/delete':
        return envelope(true);
      case '/viewer/recommendations/list':
        return envelope({
          'list': [recommendationJson(visible: visible)],
        });
      case '/viewer/recommendations/get':
        return envelope(recommendationJson(visible: visible));
      case '/viewer/recommendations/like':
        return envelope({
          'id': saveId,
          'likeCount': 2,
          'liked': true,
          'downloadCount': 2,
        });
      case '/viewer/recommendations/download-ticket':
        return envelope({
          'operationId': operationId,
          'downloadUrl': ticketUrl,
          'fileName': 'reference.wld',
          'fileSize': 4,
          'expiresAt': DateTime.now()
              .add(const Duration(minutes: 30))
              .toUtc()
              .toIso8601String(),
        });
      case '/viewer/recommendations/download-complete':
        return receiptStatus == 200
            ? envelope({'id': saveId, 'downloadCount': 3})
            : http.Response('untrusted error body', receiptStatus);
      case '/viewer/recommendations/transfer':
        return envelope({
          'operationId': operationId,
          'status': 'pending',
          'downloadCount': 2,
        });
      case '/viewer/recommendations/operation':
        return envelope({
          'operationId': operationId,
          'status': 'ready',
          'cloudSaveId': saveId,
          'downloadCount': 3,
        });
      case '/viewer/helper-info/searchAllHelperInfo':
        return envelope([
          {'id': 1, 'title': 'Help', 'content': 'Reference content'},
        ]);
      case '/viewer/user-info/getUserInfo':
        return envelope({
          'id': 7,
          'nickname': 'Explorer',
          'avatar': '/media/avatar.png',
          'openid': 'private',
          'phone': 'private',
        });
      case '/viewer/user-info/updateAppUserInfo':
        return envelope(true);
      default:
        throw StateError('Unexpected mock route ${request.url.path}');
    }
  }

  CloudBackend backend({CloudSession? session}) => CloudBackend(
    api: api,
    session: session ?? account(),
    operationStore: operations,
  );
  List<http.Request> at(String path) =>
      requests.where((r) => r.url.path == path).toList();
}

void main() {
  test('configured tenant and terminal accompany same-origin JSON binary and multipart', () async {
    final seen = <http.Request>[];
    final api = HttpCloudApi(
      config: CloudServiceConfig.viewer(
        baseUri: Uri.parse('https://service.example'),
        tenantId: '7',
        terminal: '99',
      ),
      client: MockClient((request) async {
        seen.add(request);
        expect(request.headers['tenant-id'], '7');
        expect(request.headers['terminal'], '99');
        expect(
          request.headers['Authorization'],
          'Bearer in-memory-token-account-a',
        );
        expect(request.followRedirects, isFalse);
        if (request.url.path.endsWith('/download')) {
          return http.Response.bytes([1, 2, 3, 4], 200);
        }
        return envelope(saveJson());
      }),
    );
    await api.getSave(account(), saveId);
    await api.download(account(), saveId, expectedBytes: 4);
    await api.upload(
      account(),
      Uint8List.fromList([1, 2, 3, 4]),
      'synthetic.wld',
      'world',
      preview: syntheticCloudPreview(),
    );
    expect(seen.length, 3);
    expect(
      () => CloudServiceConfig.viewer(
        baseUri: Uri.parse('https://service.example'),
        tenantId: '7\r\nother: value',
      ),
      throwsA(isA<CloudFailure>()),
    );
  });

  test('viewer route mapping preserves API prefix and validates list queries', () async {
    final config = CloudServiceConfig.viewer(
      baseUri: Uri.parse('https://service.example/app-api'),
    );
    expect(
      config.endpoint('download', {'id': saveId}).toString(),
      'https://service.example/app-api/viewer/cloud-saves/download?id=$saveId',
    );
    final service = ReferenceService();
    await service.api.recommendations(
      null,
      kind: 'player',
      page: 2,
      pageSize: 12,
    );
    expect(service.requests.single.url.queryParameters, {
      'kind': 'player',
      'pageNo': '2',
      'pageSize': '12',
    });
    expect(
      () => service.api.recommendations(null, kind: 'image'),
      throwsA(isA<CloudFailure>()),
    );
    expect(service.requests.length, 1);
  });

  test('save and recommendation pages append deduplicated records and stop at final page', () async {
    final service = ReferenceService();
    final rows = List.generate(
      30,
      (index) => {
        ...saveJson(),
        'id':
            '${index.toRadixString(16).padLeft(8, '0')}-1111-4111-8111-111111111111',
      },
    );
    service.handler = (request) async {
      final first = request.url.queryParameters['pageNo'] == '1';
      if (request.url.path == '/viewer/cloud-saves/list') {
        return envelope({
          'list': first ? rows : [rows.first],
        });
      }
      if (request.url.path == '/viewer/recommendations/list') {
        return envelope({
          'list': [
            for (final row in (first ? rows : [rows.first]))
              {...recommendationJson(), 'id': row['id']},
          ],
        });
      }
      return service.response(request);
    };
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    await cloud.refreshSaves();
    expect(cloud.hasMoreSaves, isTrue);
    await cloud.loadMoreSaves();
    expect(cloud.saves.length, 30);
    expect(cloud.hasMoreSaves, isFalse);
    await cloud.loadMoreSaves();
    expect(service.at('/viewer/cloud-saves/list').length, 2);
    await cloud.loadRecommendations(kind: 'world');
    expect(cloud.hasMoreRecommendations, isTrue);
    await cloud.loadMoreRecommendations();
    expect(cloud.recommended.length, 30);
    expect(cloud.hasMoreRecommendations, isFalse);
    expect(
      service
          .at('/viewer/recommendations/list')
          .last
          .url
          .queryParameters['pageNo'],
      '2',
    );
    expect(
      service
          .at('/viewer/recommendations/list')
          .last
          .url
          .queryParameters['kind'],
      'world',
    );
  });

  test(
    'account change after adoption still prevents a receipt for the old owner',
    () async {
      final service = ReferenceService();
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      await expectLater(
        cloud.downloadRecommendation(recommendation(), (_, _, _) async {
          cloud.setSession(account('account-b'));
        }),
        throwsA(isA<CloudFailure>()),
      );
      expect(service.at('/viewer/recommendations/download-complete'), isEmpty);
      expect(cloud.pendingReceiptCount, 0);
      expect(cloud.notice, isNull);
    },
  );

  test(
    'private save uses latest ownership lookup before exact binary transfer',
    () async {
      final service = ReferenceService();
      // The caller may hold stale metadata; only the authenticated GET is trusted.
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      var adopted = false;
      final result = await cloud.downloadSave(
        const CloudSave(
          id: saveId,
          fileName: 'stale.wld',
          kind: 'player',
          status: CloudJobStatus.failed,
          fileSize: 88,
        ),
        (save, bytes, check) async {
          check();
          adopted = true;
          expect(save.fileName, 'reference.wld');
          expect(save.kind, 'world');
          expect(bytes, [1, 2, 3, 4]);
        },
      );
      expect(adopted, isTrue);
      expect(result.save.fileSize, 4);
      expect(service.requests.map((r) => r.url.path), [
        '/viewer/cloud-saves/get',
        '/viewer/cloud-saves/download',
      ]);
      for (final request in service.requests) {
        expect(
          request.headers['Authorization'],
          'Bearer in-memory-token-account-a',
        );
      }
    },
  );

  test('not-ready latest save does not transfer or publish', () async {
    final service = ReferenceService()..latestStatus = 'deleting';
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    await expectLater(
      cloud.downloadSave(
        CloudSave.fromJson(saveJson()),
        (_, _, _) async => fail('must not publish'),
      ),
      throwsA(isA<CloudFailure>()),
    );
    expect(service.at('/viewer/cloud-saves/download'), isEmpty);
  });

  test(
    'binary short length oversized stream and redirects never publish',
    () async {
      for (final kind in ['short', 'long', 'redirect']) {
        final service = ReferenceService();
        service.handler = (request) async {
          if (request.url.path == '/viewer/cloud-saves/download') {
            return kind == 'redirect'
                ? http.Response(
                    '',
                    302,
                    headers: {'location': 'https://other.example/file'},
                  )
                : http.Response.bytes(
                    List.filled(kind == 'short' ? 3 : 5, 1),
                    200,
                  );
          }
          return service.response(request);
        };
        final cloud = service.backend();
        addTearDown(cloud.dispose);
        await expectLater(
          cloud.downloadSave(
            CloudSave.fromJson(saveJson()),
            (_, _, _) async => fail('must not publish'),
          ),
          throwsA(isA<CloudFailure>()),
        );
        expect(service.requests.length, 2);
      }
    },
  );

  test('stream cap applies even without a Content-Length', () async {
    final api = HttpCloudApi(
      config: CloudServiceConfig.viewer(
        baseUri: Uri.parse('https://service.example'),
      ),
      client: MockClient.streaming(
        (request, stream) async => http.StreamedResponse(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]),
          200,
        ),
      ),
    );
    await expectLater(
      api.download(account(), saveId, expectedBytes: 4),
      throwsA(isA<CloudFailure>()),
    );
  });

  test('recommendation receipt follows verified durable adoption', () async {
    final service = ReferenceService();
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    var durable = false;
    service.handler = (request) async {
      if (request.url.path.endsWith('/download-complete')) {
        expect(durable, isTrue);
      }
      return service.response(request);
    };
    final result = await cloud.downloadRecommendation(recommendation(), (
      save,
      bytes,
      check,
    ) async {
      check();
      // The full Workspace durable adoption is exercised separately below.
      expect(bytes.length, save.fileSize);
      durable = true;
    });
    expect(result.receiptPending, isFalse);
    expect(cloud.pendingReceiptCount, 0);
    expect(
      service.at('/viewer/recommendations/download-ticket').single.method,
      'POST',
    );
    final body = jsonDecode(
      service.at('/viewer/recommendations/download-ticket').single.body,
    ) as Map;
    expect(body['id'], saveId);
    expect(cloudUuid(body['requestId'] as String), isNotEmpty);
    expect(
      jsonDecode(
        service.at('/viewer/recommendations/download-complete').single.body,
      ),
      {'operationId': operationId},
    );
  });

  test(
    'storage failure cannot acknowledge or journal a completed download',
    () async {
      final service = ReferenceService();
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      await expectLater(
        cloud.downloadRecommendation(
          recommendation(),
          (_, _, _) async => throw const VaultException('full'),
        ),
        throwsA(isA<VaultException>()),
      );
      expect(service.at('/viewer/recommendations/download-complete'), isEmpty);
      expect(service.operations.values, isEmpty);
    },
  );

  test('tampered ticket destination and hidden recommendations fail before binary transfer', () async {
    for (final url in [
      'https://evil.example/file',
      '//evil.example/file',
      '/viewer/recommendations/download?operationId=$operationId&extra=1',
      '/viewer/cloud-saves/download?id=$saveId',
    ]) {
      final service = ReferenceService()..ticketUrl = url;
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      await expectLater(
        cloud.downloadRecommendation(
          recommendation(),
          (_, _, _) async => fail('must not publish'),
        ),
        throwsA(isA<CloudFailure>()),
      );
      expect(service.at('/viewer/recommendations/download'), isEmpty);
    }
    final service = ReferenceService()..visible = false;
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    await expectLater(
      cloud.downloadRecommendation(
        recommendation(),
        (_, _, _) async => fail('must not publish'),
      ),
      throwsA(isA<CloudFailure>()),
    );
    expect(service.at('/viewer/recommendations/download-ticket'), isEmpty);
  });

  test('receipt survives restart and stays bound to authenticated account and service', () async {
    final service = ReferenceService()..receiptStatus = 503;
    final first = service.backend();
    final result = await first.downloadRecommendation(
      recommendation(),
      (_, _, check) async => check(),
    );
    expect(result.receiptPending, isTrue);
    expect(first.pendingReceiptCount, 1);
    first.dispose();
    final encoded = service.operations.values.values.single;
    expect(encoded, contains(operationId));
    expect(encoded, isNot(contains('token')));
    expect(
      service.operations.values.keys.single,
      matches(RegExp(r'^cloud-operations-v2-[0-9a-f]{64}$')),
    );
    expect(service.operations.values.keys.single, isNot(contains('account-a')));
    service.receiptStatus = 200;
    service.requests.clear();
    final other = service.backend(session: account('account-b'));
    addTearDown(other.dispose);
    await other.retryRecommendationReceipts();
    expect(service.at('/viewer/recommendations/download-complete'), isEmpty);
    final restored = service.backend();
    addTearDown(restored.dispose);
    await restored.loadRecommendations();
    expect(restored.pendingReceiptCount, 1);
    await restored.retryRecommendationReceipts();
    expect(service.at('/viewer/recommendations/download-complete').length, 1);
    expect(restored.pendingReceiptCount, 0);
    final one = CloudOperationJournal(
      store: service.operations,
      serviceOrigin: 'https://one.example',
      accountId: 'account-a',
    );
    final two = CloudOperationJournal(
      store: service.operations,
      serviceOrigin: 'https://two.example',
      accountId: 'account-a',
    );
    expect(one.key, isNot(two.key));
  });

  test('tenant and terminal changes cannot replay another context or legacy receipts', () async {
    final store = MemoryOperations();
    final requests = <http.Request>[];
    HttpCloudApi api(String tenant, String terminal) => HttpCloudApi(
      config: CloudServiceConfig.viewer(
        baseUri: Uri.parse('https://service.example'),
        tenantId: tenant,
        terminal: terminal,
      ),
      client: MockClient((request) async {
        requests.add(request);
        return envelope({'id': saveId, 'downloadCount': 3});
      }),
    );
    final journal = CloudOperationJournal(
      store: store,
      serviceOrigin: 'https://service.example',
      tenantId: '1',
      terminal: '20',
      accountId: 'account-a',
    );
    await journal.load();
    journal.receipts.add(operationId);
    await journal.save();
    final legacyKey =
        'cloud-operations-v1-${sha256.convert(utf8.encode(jsonEncode(['https://service.example', 'account-a'])))}';
    store.values[legacyKey] = jsonEncode({
      'version': 1,
      'receipts': [requestId],
      'transfers': {},
    });
    for (final context in [('2', '20'), ('1', '10')]) {
      final other = CloudBackend(
        api: api(context.$1, context.$2),
        session: account(),
        operationStore: store,
      );
      addTearDown(other.dispose);
      await other.retryRecommendationReceipts();
      expect(requests, isEmpty);
    }
    final correct = CloudBackend(
      api: api('1', '20'),
      session: account(),
      operationStore: store,
    );
    addTearDown(correct.dispose);
    await correct.retryRecommendationReceipts();
    expect(requests.length, 1);
    expect(jsonDecode(requests.single.body), {'operationId': operationId});
    expect(store.values[legacyKey], contains(requestId));
  });

  test(
    'missing stable account identity blocks recommendation mutation',
    () async {
      final service = ReferenceService();
      final cloud = service.backend(
        session: CloudSession(
          accessToken: 'token',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      addTearDown(cloud.dispose);
      await expectLater(
        cloud.downloadRecommendation(
          recommendation(),
          (_, _, _) async => fail('must not publish'),
        ),
        throwsA(isA<CloudFailure>()),
      );
      await cloud.transferRecommendation(recommendation());
      expect(service.requests, isEmpty);
    },
  );

  test('uncertain transfer retries one request ID and resumes operation after restart', () async {
    final service = ReferenceService();
    var posts = 0;
    service.handler = (request) async {
      if (request.url.path.endsWith('/transfer') && ++posts == 1) {
        throw http.ClientException('lost response');
      }
      return service.response(request);
    };
    final cloud = service.backend();
    await cloud.transferRecommendation(recommendation());
    expect(cloud.error, isNotNull);
    service.visible = false; // Existing operation recovery remains reachable.
    await cloud.transferRecommendation(recommendation());
    final posted = service.at('/viewer/recommendations/transfer');
    expect(posted.length, 2);
    expect(service.at('/viewer/recommendations/get').length, 1);
    expect(posted[0].body, posted[1].body);
    expect(cloud.recommendationTransfers[saveId]!.status, 'pending');
    cloud.dispose();
    final resumed = service.backend();
    addTearDown(resumed.dispose);
    await resumed.transferRecommendation(recommendation());
    expect(service.at('/viewer/recommendations/transfer').length, 2);
    expect(
      service
          .at('/viewer/recommendations/operation')
          .single
          .url
          .queryParameters,
      {'operationId': operationId},
    );
    expect(resumed.recommendationTransfers[saveId]!.status, 'ready');
    expect(
      jsonDecode(service.operations.values.values.single)['transfers'],
      isEmpty,
    );
  });

  test('journal storage failure blocks transfer POST and corrupt journal is preserved', () async {
    final service = ReferenceService()..operations.failWrites = true;
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    await cloud.transferRecommendation(recommendation());
    expect(service.requests, isEmpty);
    service.operations.failWrites = false;
    final journal = CloudOperationJournal(
      store: service.operations,
      serviceOrigin: service.api.serviceOrigin,
      accountId: 'account-a',
    );
    service.operations.values[journal.key] = '{broken';
    final restarted = service.backend();
    addTearDown(restarted.dispose);
    await restarted.transferRecommendation(recommendation());
    expect(service.requests, isEmpty);
    expect(service.operations.values[journal.key], '{broken');
  });

  test(
    'account change and cancellation during transfer block adoption',
    () async {
      for (final changeAccount in [true, false]) {
        final service = ReferenceService();
        final pending = Completer<http.Response>();
        final cloud = service.backend();
        addTearDown(cloud.dispose);
        final started = Completer<void>();
        service.handler = (request) async {
          if (request.url.path == '/viewer/recommendations/download') {
            started.complete();
            return pending.future;
          }
          return service.response(request);
        };
        final operation = cloud.downloadRecommendation(
          recommendation(),
          (_, _, _) async => fail('must not publish'),
        );
        final checked = expectLater(operation, throwsA(isA<CloudFailure>()));
        await started.future;
        if (changeAccount) {
          cloud.setSession(account('account-b'));
        } else {
          cloud.cancelTransfer();
        }
        pending.complete(http.Response.bytes([1, 2, 3, 4], 200));
        await checked;
        expect(
          service.at('/viewer/recommendations/download-complete'),
          isEmpty,
        );
        expect(cloud.busy, isFalse);
        expect(cloud.pendingReceiptCount, 0);
      }
    },
  );

  test(
    'public help and recommendations omit auth; profile is whitelisted',
    () async {
      final service = ReferenceService();
      expect(
        (await service.api.help(null)).single.content,
        'Reference content',
      );
      expect(
        (await service.api.recommendations(null)).single.title,
        'Synthetic reference',
      );
      for (final request in service.requests) {
        expect(request.headers.containsKey('Authorization'), isFalse);
      }
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      await cloud.loadProfile();
      expect(cloud.account, {
        'id': 7,
        'nickname': 'Explorer',
        'avatar': '/media/avatar.png',
      });
      await cloud.saveProfile({'id': 8, 'nickname': 'Other'});
      expect(service.at('/viewer/user-info/updateAppUserInfo'), isEmpty);
      await cloud.saveProfile({
        'id': 7,
        'nickname': 'New',
        'avatar': '/media/new.png',
      });
      expect(
        jsonDecode(
          service.at('/viewer/user-info/updateAppUserInfo').single.body,
        ),
        {
          'id': 7,
          'nickname': 'New',
          'avatar': 'https://service.example/media/new.png',
        },
      );
    },
  );

  test(
    'Workspace adopts verified local bytes before receipt and restores them',
    () async {
      final service = ReferenceService(),
          vault = MemoryVault(),
          files = FakeFiles();
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      final workspace = Workspace(
        engine: FakeEngine(),
        files: files,
        vault: vault,
        cloud: cloud,
      );
      addTearDown(workspace.dispose);
      service.handler = (request) async {
        if (request.url.path.endsWith('/download-complete')) {
          expect(vault.entries.length, 1);
          expect(await vault.read(vault.entries.keys.single), [1, 2, 3, 4]);
        }
        return service.response(request);
      };
      await workspace.dispatch('cloudRecommendationDownload', {
        'item': recommendation(),
      });
      expect(workspace.view.error, isEmpty);
      expect(workspace.view.files.single.name, 'reference.wld');
      final restored = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        vault: vault,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.view.files.single.name, 'reference.wld');
      await workspace.dispatch('cloudRecommendationDownload', {
        'item': recommendation(),
      });
      expect(workspace.view.error, isEmpty);
      expect(vault.entries.length, 1);
      expect(service.at('/viewer/recommendations/download-complete').length, 2);
    },
  );

  test(
    'Workspace vault missing full or corrupt blocks receipts and export',
    () async {
      for (final mode in ['missing', 'full', 'corrupt']) {
        final service = ReferenceService();
        final vault = mode == 'missing'
            ? null
            : (MemoryVault()
                ..failWrites = mode == 'full'
                ..corruptRead = mode == 'corrupt');
        final cloud = service.backend();
        addTearDown(cloud.dispose);
        final files = FakeFiles();
        final workspace = Workspace(
          engine: FakeEngine(),
          files: files,
          vault: vault,
          cloud: cloud,
        );
        addTearDown(workspace.dispose);
        await workspace.dispatch('cloudRecommendationDownload', {
          'item': recommendation(),
        });
        expect(workspace.view.error, isNotEmpty, reason: mode);
        expect(workspace.view.files, isEmpty, reason: mode);
        expect(
          service.at('/viewer/recommendations/download-complete'),
          isEmpty,
          reason: mode,
        );
        expect(files.saved, isNull, reason: mode);
      }
    },
  );

  test('prepared upload snapshots bytes and duplicate preflight can avoid multipart upload', () async {
    final service = ReferenceService();
    final original = Uint8List.fromList([65, 66, 67, 68]);
    final files = FakeFiles()..next = PickedFile('sample.wld.bak', original);
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    final workspace = Workspace(
      engine: PreviewEngine(),
      files: files,
      cloud: cloud,
    );
    addTearDown(workspace.dispose);
    await workspace.dispatch('cloudPrepareUpload');
    original.fillRange(0, original.length, 90);
    await workspace.dispatch('cloudUploadPrepared');
    expect(workspace.view.error, isEmpty);
    final duplicate = service.at('/viewer/cloud-saves/duplicate').single;
    expect(duplicate.url.queryParameters, {
      'kind': 'world',
      'hash': sha1.convert([65, 66, 67, 68]).toString(),
      'fileSize': '4',
    });
    final upload = service.at('/viewer/cloud-saves/upload').single;
    expect(upload.body, contains('ABCD'));
    expect(upload.body, contains('filename="sample.wld"'));
    expect(upload.body, isNot(contains('sample.wld.bak')));
    expect(upload.body, isNot(contains('ZZZZ')));
    service.requests.clear();
    service.handler = (request) async => request.url.path.endsWith('/duplicate')
        ? envelope(saveJson())
        : service.response(request);
    await cloud.uploadFile(
      Uint8List.fromList([65, 66, 67, 68]),
      'sample.wld',
      'world',
    );
    expect(service.at('/viewer/cloud-saves/upload'), isEmpty);
  });

  test(
    'upload rejects backend-incompatible names before any request',
    () async {
      final service = ReferenceService();
      for (final name in ['sample.wld.bak', 'sample.plr', '${'x' * 181}.wld']) {
        await expectLater(
          service.api.upload(
            account(),
            Uint8List.fromList([1, 2, 3, 4]),
            name,
            'world',
            preview: syntheticCloudPreview(),
          ),
          throwsA(isA<CloudFailure>()),
        );
      }
      expect(service.requests, isEmpty);
      expect(
        CloudServiceConfig.viewer(baseUri: Uri.parse('https://service.example'))
            .maxFileBytes,
        100 * 1024 * 1024,
      );
    },
  );

  test(
    'world upload blocks absent or oversized preview before network mutation',
    () async {
      final service = ReferenceService();
      await expectLater(
        service.api.upload(
          account(),
          Uint8List.fromList([1, 2, 3, 4]),
          'synthetic.wld',
          'world',
        ),
        throwsA(isA<CloudFailure>()),
      );
      final bad = syntheticCloudPreview();
      ByteData.sublistView(bad).setUint32(16, 0xffffffff);
      ByteData.sublistView(bad).setUint32(20, 0xffffffff);
      await expectLater(
        service.api.upload(
          account(),
          Uint8List.fromList([1, 2, 3, 4]),
          'synthetic.wld',
          'world',
          preview: bad,
        ),
        throwsA(isA<CloudFailure>()),
      );
      expect(service.requests, isEmpty);
    },
  );

  test(
    'world upload renders required preview and restores active WLD on failure',
    () async {
      final service = ReferenceService(),
          engine = PreviewEngine(),
          files = FakeFiles()
            ..next = PickedFile('active.wld', Uint8List.fromList([8, 9, 10]));
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      final workspace = Workspace(engine: engine, files: files, cloud: cloud);
      addTearDown(workspace.dispose);
      await workspace.dispatch('import', {'kind': 'world'});
      final original = Uint8List.fromList(engine.handles.values.single);
      files.next = PickedFile('upload.wld', Uint8List.fromList([1, 2, 3, 4]));
      await workspace.dispatch('cloudPrepareUpload');
      await workspace.dispatch('cloudUploadPrepared');
      expect(workspace.view.error, isEmpty);
      expect(engine.handles.values.single, original);
      final upload = service.at('/viewer/cloud-saves/upload').single;
      expect(upload.body, contains('name="preview"'));
      expect(upload.body, contains(base64Encode(syntheticCloudPreview())));
      service.requests.clear();
      engine.failUploadPreview = true;
      await workspace.dispatch('cloudPrepareUpload');
      await workspace.dispatch('cloudUploadPrepared');
      expect(workspace.view.error, contains('预览生成失败'));
      expect(service.at('/viewer/cloud-saves/upload'), isEmpty);
      expect(engine.handles.values.single, original);
      await workspace.close();
    },
  );

  test(
    'receipt retry retires permanent failures and rotates transient conflicts',
    () async {
      final service = ReferenceService();
      final journal = CloudOperationJournal(
        store: service.operations,
        serviceOrigin: service.api.serviceOrigin,
        accountId: 'account-a',
      );
      await journal.load();
      journal.receipts.addAll([operationId, requestId, saveId]);
      await journal.save();
      service.handler = (request) async {
        final id = (jsonDecode(request.body) as Map)['operationId'];
        return id == operationId
            ? http.Response('', 409)
            : id == requestId
            ? http.Response('', 403)
            : envelope({'id': saveId, 'downloadCount': 3});
      };
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      await cloud.retryRecommendationReceipts();
      expect(cloud.pendingReceiptCount, 1);
      expect(jsonDecode(service.operations.values.values.single)['receipts'], [
        operationId,
      ]);
      expect(service.requests.length, 3);
    },
  );

  testWidgets('delete confirmation cancels and rejects a changed account', (
    tester,
  ) async {
    final service = ReferenceService();
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    cloud.saves = [CloudSave.fromJson(saveJson())];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CloudWorkspacePanel(backend: cloud)),
      ),
    );
    await tester.tap(find.text('删除云端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.requests, isEmpty);
    await tester.tap(find.text('删除云端'));
    await tester.pumpAndSettle();
    cloud.setSession(account('account-b'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '删除云端'));
    await tester.pumpAndSettle();
    expect(service.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('prepared upload cannot switch account and malformed filename never uploads', () async {
    final service = ReferenceService(),
        files = FakeFiles()
          ..next = PickedFile('sample.wld', Uint8List.fromList([1, 2, 3, 4]));
    final cloud = service.backend();
    addTearDown(cloud.dispose);
    final workspace = Workspace(
      engine: FakeEngine(),
      files: files,
      cloud: cloud,
    );
    addTearDown(workspace.dispose);
    await workspace.dispatch('cloudPrepareUpload');
    cloud.setSession(account('account-b'));
    await workspace.dispatch('cloudUploadPrepared');
    expect(workspace.view.error, isNotEmpty);
    expect(service.requests, isEmpty);
    files.next = PickedFile('save.wld.exe', Uint8List.fromList([1]));
    await workspace.dispatch('cloudPrepareUpload');
    expect(workspace.view.error, isNotEmpty);
    expect(service.requests, isEmpty);
  });

  testWidgets(
    'recommendation actions are reachable and unavailable without identity',
    (tester) async {
      final service = ReferenceService();
      final cloud = service.backend();
      addTearDown(cloud.dispose);
      await tester.runAsync(cloud.loadRecommendations);
      var downloads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CloudWorkspacePanel(
              backend: cloud,
              onRecommendationDownload: (_) async {
                downloads++;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('下载推荐'));
      await tester.pump();
      expect(downloads, 1);
      expect(find.text('转存云端 / 查询进度'), findsOneWidget);
      cloud.setSession(null);
      await tester.runAsync(cloud.loadRecommendations);
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '下载推荐'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
