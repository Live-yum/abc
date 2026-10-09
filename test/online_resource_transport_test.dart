import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:terraforge/resources/online_resource_transport.dart';

void main() {
  test(
    'public file route pins manifest and sends no account credentials',
    () async {
      final requests = <http.Request>[];
      final transport = HttpOnlineResourceTransport(
        'https://resource.example.test/api/',
        clientFactory: () => MockClient((request) async {
          requests.add(request);
          return http.Response.bytes([1, 2], 200);
        }),
      );
      await transport.approval(OnlineResourceCancellation());
      final sha = 'a' * 64;
      await transport.fetch(
        'releases/$sha.json',
        sha,
        16,
        OnlineResourceCancellation(),
      );
      expect(
        requests.first.url.toString(),
        'https://resource.example.test/api/viewer/resources/approval-state',
      );
      expect(requests.last.url.path, '/api/viewer/resources/file');
      expect(requests.last.url.queryParameters, {
        'path': 'releases/$sha.json',
        'manifestSha256': sha,
      });
      expect(requests.last.headers.containsKey('authorization'), isFalse);
      expect(requests.last.headers.containsKey('cookie'), isFalse);
      expect(requests.last.followRedirects, isFalse);
    },
  );
  test(
    'streaming size cap and HTTP redirects fail without accepting content',
    () async {
      final sha = 'a' * 64;
      final large = HttpOnlineResourceTransport(
        'https://resource.example.test',
        clientFactory: () => MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable([
              [1, 2],
              [3, 4],
            ]),
            200,
          ),
        ),
      );
      await expectLater(
        large.fetch('releases/$sha.json', sha, 3, OnlineResourceCancellation()),
        throwsFormatException,
      );
      final redirect = HttpOnlineResourceTransport(
        'https://resource.example.test',
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'https://other.test'},
          ),
        ),
      );
      await expectLater(
        redirect.approval(OnlineResourceCancellation()),
        throwsStateError,
      );
    },
  );
  test(
    'cancel and timeout bound a transport that never sends headers',
    () async {
      final response = Completer<http.StreamedResponse>();
      final transport = HttpOnlineResourceTransport(
        'https://resource.example.test',
        clientFactory: () => MockClient.streaming((_, _) => response.future),
        timeout: const Duration(milliseconds: 30),
      );
      final cancel = OnlineResourceCancellation();
      final result = expectLater(
        transport.approval(cancel),
        throwsA(isA<OnlineResourceCancelled>()),
      );
      cancel.cancel();
      await result;
      await expectLater(
        transport.approval(OnlineResourceCancellation()),
        throwsA(isA<TimeoutException>()),
      );
      response.complete(http.StreamedResponse(Stream.value(Uint8List(0)), 200));
    },
  );
}
