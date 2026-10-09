import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:terraforge/cloud/cloud.dart';
import 'package:terraforge/ui/cloud_workspace_panel.dart';
import 'package:terraforge/ui/generation_options_form.dart';

import 'support/cloud_preview.dart';

CloudSession session() => CloudSession(
  accessToken: 'test-session',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);
final schemaJson = <String, dynamic>{
  'revision': 'sample-1',
  'root': {
    'count': {'kind': 'integer', 'min': 1, 'max': 10},
    'enabled': {'kind': 'boolean'},
    'group': {'kind': 'object', 'ref': 'Group'},
    'rows': {
      'kind': 'array',
      'item': {'kind': 'number'},
    },
    'weights': {
      'kind': 'map',
      'keyKind': 'integer',
      'item': {'kind': 'number'},
    },
    'locked': {'kind': 'string', 'readOnly': true},
  },
  'types': {
    'Group': {
      'name': {
        'kind': 'string',
        'choices': ['one', 'two'],
      },
      'child': {'kind': 'object', 'ref': 'Group'},
    },
  },
};
Map<String, dynamic> save([String status = 'gen_queued']) => {
  'id': '11111111-1111-4111-8111-111111111111',
  'fileName': 'sample.wld',
  'fileSize': 4,
  'kind': 'world',
  'status': status,
};
http.Response envelope(Object? value) =>
    http.Response(jsonEncode({'code': 0, 'data': value}), 200);
CloudServiceConfig config({int cap = 4096}) => CloudServiceConfig(
  baseUri: Uri.parse('https://service.example/'),
  routes: {
    'listSaves': 'list',
    'upload': 'upload',
    'download': 'download',
    'options': 'options',
    'submit': 'submit',
    'refresh': 'job',
    'retry': 'retry',
    'cancel': 'cancel',
    'profile': 'profile',
    'updateProfile': 'update',
    'recommendations': 'recommended',
  },
  capabilities: CloudCapability.values.toSet(),
  maxJsonBytes: cap,
);
GenerationRequest request({Map<String, dynamic> values = const {}}) =>
    GenerationRequest(
      name: 'test',
      version: 'supported',
      seed: '',
      size: 'small',
      difficulty: 'classic',
      evil: 'random',
      config: values,
      revision: 'sample-1',
    );

void main() {
  test(
    'schema validates bounds, types, refs, readonly and list/map budgets',
    () {
      final schema = GenerationSchema.fromJson(schemaJson);
      expect(
        schema.validate({
          'count': 3,
          'group': {'name': 'one'},
          'weights': {'1': 0.5},
        }),
        isEmpty,
      );
      for (final value in <Map<String, dynamic>>[
        {'count': 11},
        {'count': 1.2},
        {'enabled': 'true'},
        {'missing': true},
        {'locked': 'x'},
        {
          'group': {'name': 'other'},
        },
        {'rows': List.filled(257, 1)},
        {
          'weights': {'bad': 1},
        },
      ]) {
        expect(schema.validate(value), isNotEmpty, reason: '$value');
      }
      dynamic nested = {'name': 'one'};
      for (var i = 0; i < 20; i++) {
        nested = {'child': nested};
      }
      expect(schema.validate({'group': nested}), isNotEmpty);
      final broken = GenerationSchema('x', {
        'x': {'kind': 'object', 'ref': 'missing'},
      }, {});
      expect(broken.validate({'x': {}}), isNotEmpty);
    },
  );
  test('configuration rejects insecure and cross-origin API routes', () {
    expect(
      () => CloudServiceConfig(
        baseUri: Uri.parse('http://service.example'),
        routes: {},
        capabilities: {},
      ),
      throwsA(isA<CloudFailure>()),
    );
    expect(
      () => CloudServiceConfig(
        baseUri: Uri.parse('https://service.example'),
        routes: {'profile': '//other.example/profile'},
        capabilities: {},
      ),
      throwsA(isA<CloudFailure>()),
    );
  });
  test(
    'authenticated saves preserve route/query and do not follow redirects',
    () async {
      final api = HttpCloudApi(
        config: config(),
        client: MockClient((req) async {
          expect(req.url.path, '/list');
          expect(req.url.queryParameters['pageNo'], '2');
          expect(req.headers['Authorization'], 'Bearer test-session');
          expect(req.followRedirects, isFalse);
          return envelope({
            'list': [save('ready')],
            'total': 1,
          });
        }),
      );
      expect(
        (await api.listSaves(session(), page: 2)).single.status,
        CloudJobStatus.ready,
      );
      expect(
        () => api.listSaves(session(), pageSize: 201),
        throwsA(isA<CloudFailure>()),
      );
    },
  );
  test(
    'private download is authenticated binary data without redirects',
    () async {
      var calls = 0;
      final api = HttpCloudApi(
        config: config(),
        client: MockClient((req) async {
          calls++;
          expect(req.url.path, '/download');
          expect(
            req.url.queryParameters['id'],
            '11111111-1111-4111-8111-111111111111',
          );
          expect(req.headers['Authorization'], 'Bearer test-session');
          expect(req.followRedirects, isFalse);
          return http.Response.bytes([1, 2, 3], 200);
        }),
      );
      expect(
        await api.download(
          session(),
          '11111111-1111-4111-8111-111111111111',
          expectedBytes: 3,
        ),
        [1, 2, 3],
      );
      expect(calls, 1);
    },
  );
  test('response cap and safe errors hide remote error details', () async {
    final api = HttpCloudApi(
      config: config(cap: 20),
      client: MockClient(
        (req) async => http.Response('private-secret' * 10, 200),
      ),
    );
    await expectLater(
      api.listSaves(session()),
      throwsA(
        isA<CloudFailure>().having(
          (e) => e.message,
          'safe message',
          isNot(contains('private-secret')),
        ),
      ),
    );
    final redirect = HttpCloudApi(
      config: config(),
      client: MockClient(
        (req) async => http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example'},
        ),
      ),
    );
    await expectLater(
      redirect.listSaves(session()),
      throwsA(isA<CloudFailure>()),
    );
  });
  test(
    'upload is explicit multipart and cancelled transfer never starts',
    () async {
      var count = 0;
      final api = HttpCloudApi(
        config: config(),
        client: MockClient((req) async {
          count++;
          expect(
            req.headers['content-type'],
            startsWith('multipart/form-data'),
          );
          return envelope(save());
        }),
      );
      await api.upload(
        session(),
        Uint8List.fromList([1]),
        'test.wld',
        'world',
        preview: syntheticCloudPreview(),
      );
      final cancel = CloudCancellation()..cancel();
      await expectLater(
        api.upload(
          session(),
          Uint8List.fromList([1]),
          'test.wld',
          'world',
          preview: syntheticCloudPreview(),
          cancellation: cancel,
        ),
        throwsA(isA<CloudFailure>()),
      );
      expect(count, 1);
    },
  );
  test(
    'submit pending guard, polling state, cancel and retry lifecycle',
    () async {
      final submit = Completer<http.Response>();
      var submissions = 0;
      final api = HttpCloudApi(
        config: config(),
        client: MockClient((req) async {
          switch (req.url.path) {
            case '/options':
              return envelope({
                'enabled': true,
                'versions': ['supported'],
                'schema': schemaJson,
              });
            case '/submit':
              submissions++;
              return submit.future;
            case '/cancel':
              return envelope(save('cancelled'));
            case '/retry':
              return envelope(save('generating'));
            default:
              return envelope(save('ready'));
          }
        }),
      );
      final backend = CloudBackend(api: api, session: session());
      addTearDown(backend.dispose);
      await backend.loadOptions();
      final first = backend.submitGeneration(request());
      await backend.submitGeneration(request());
      submit.complete(envelope(save()));
      await first;
      expect(submissions, 1);
      expect(backend.job!.status, CloudJobStatus.generationQueued);
      await backend.cancelJob();
      expect(backend.job!.status, CloudJobStatus.cancelled);
      await backend.retryJob();
      expect(backend.job!.status, CloudJobStatus.generating);
      await backend.refreshJob();
      expect(backend.job!.status, CloudJobStatus.ready);
    },
  );
  test('uncertain submit cannot be automatically repeated', () async {
    var submits = 0;
    final backend = CloudBackend(
      session: session(),
      api: HttpCloudApi(
        config: config(),
        client: MockClient((req) async {
          if (req.url.path == '/options') {
            return envelope({
              'enabled': true,
              'versions': ['supported'],
              'schema': schemaJson,
            });
          }
          submits++;
          throw Exception('sensitive');
        }),
      ),
    );
    addTearDown(backend.dispose);
    await backend.loadOptions();
    await backend.submitGeneration(request());
    await backend.submitGeneration(request());
    expect(submits, 1);
    expect(backend.submissionUncertain, isTrue);
    expect(backend.error, isNot(contains('sensitive')));
  });
  test('disconnect discards stale in-flight profile result', () async {
    final response = Completer<http.Response>();
    final backend = CloudBackend(
      session: session(),
      api: HttpCloudApi(
        config: config(),
        client: MockClient((req) => response.future),
      ),
    );
    addTearDown(backend.dispose);
    final load = backend.loadProfile();
    backend.setSession(null);
    response.complete(envelope({'nickname': 'stale'}));
    await load;
    expect(backend.account, isNull);
    expect(backend.connected, isFalse);
  });
  testWidgets('cloud panel stays disconnected with no provider', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CloudWorkspacePanel())),
    );
    expect(find.textContaining('云端未连接'), findsOneWidget);
    expect(find.text('提交生成任务'), findsNothing);
  });
  testWidgets('schema form edits values and reports validation', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    List<String>? errors;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GenerationOptionsForm(
              schema: GenerationSchema.fromJson(schemaJson),
              onChanged: (v, e) {
                result = v;
                errors = e;
              },
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField).first, '11');
    expect(result!['count'], 11);
    expect(errors, isNotEmpty);
    await tester.enterText(find.byType(TextFormField).first, '3');
    expect(errors, isEmpty);
    expect(result!.containsKey('group'), isFalse);
    expect(find.text('Read-only service setting'), findsOneWidget);
  });
  test(
    'expired session and missing capabilities reject without requests',
    () async {
      var calls = 0;
      final api = HttpCloudApi(
        config: config(),
        client: MockClient((request) async {
          calls++;
          return envelope({});
        }),
      );
      await expectLater(
        api.profile(
          CloudSession(accessToken: 'expired', expiresAt: DateTime(2000)),
        ),
        throwsA(isA<CloudFailure>()),
      );
      expect(calls, 0);
      final limited = HttpCloudApi(
        config: CloudServiceConfig(
          baseUri: Uri.parse('https://service.example'),
          routes: {},
          capabilities: {},
        ),
        client: MockClient((request) async {
          calls++;
          return envelope({});
        }),
      );
      expect(() => limited.listSaves(session()), throwsA(isA<CloudFailure>()));
      expect(calls, 0);
    },
  );
  test('invalid save identifier fails before a download request', () async {
    final api = HttpCloudApi(
      config: config(),
      client: MockClient(
        (request) async => envelope({'downloadUrl': 'https:opaque'}),
      ),
    );
    await expectLater(
      api.download(session(), 'sample'),
      throwsA(isA<CloudFailure>()),
    );
  });
  testWidgets('injected provider makes no request until refresh is clicked', (
    tester,
  ) async {
    var calls = 0;
    final backend = CloudBackend(
      session: session(),
      api: HttpCloudApi(
        config: config(),
        client: MockClient((request) async {
          calls++;
          return envelope({
            'list': [save('ready')],
          });
        }),
      ),
    );
    addTearDown(backend.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CloudWorkspacePanel(backend: backend)),
      ),
    );
    expect(calls, 0);
    await tester.runAsync(() async {
      await tester.tap(find.text('刷新存档'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(calls, 1);
    expect(find.text('sample.wld'), findsOneWidget);
  });
  testWidgets('polling reaches terminal status and stops', (tester) async {
    var polls = 0;
    final backend = CloudBackend(
      session: session(),
      api: HttpCloudApi(
        config: config(),
        client: MockClient((request) async {
          polls++;
          return envelope(save('ready'));
        }),
      ),
    );
    addTearDown(backend.dispose);
    backend.observeJob(CloudSave.fromJson(save()));
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(backend.job!.status, CloudJobStatus.ready);
    await tester.pump(const Duration(seconds: 20));
    expect(polls, 1);
  });
}
