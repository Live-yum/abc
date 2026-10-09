import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'online_resource_protocol.dart';
import 'public_resource_client.dart'
    if (dart.library.js_interop) 'public_resource_client_web.dart'
    as platform;

class OnlineResourceCancelled implements Exception {
  const OnlineResourceCancelled();
  @override
  String toString() => '下载已暂停，可继续安装';
}

class OnlineResourceCancellation {
  final _cancelled = Completer<void>();
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get signal => _cancelled.future;
  void cancel() {
    if (!cancelled) _cancelled.complete();
  }

  void check() {
    if (cancelled) throw const OnlineResourceCancelled();
  }
}

abstract interface class OnlineResourceTransport {
  String get authorityEndpoint;
  Future<Uint8List> approval(OnlineResourceCancellation cancellation);
  Future<Uint8List> fetch(
    String path,
    String manifestSha256,
    int maxBytes,
    OnlineResourceCancellation cancellation,
  );
}

/// The reference's browser/public HTTP contract. The endpoint is explicitly
/// configured by the application; no production service or credentials default.
class HttpOnlineResourceTransport implements OnlineResourceTransport {
  HttpOnlineResourceTransport(
    String endpoint, {
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 30),
  }) : authorityEndpoint = normalizeResourceEndpoint(endpoint),
       _clientFactory = clientFactory ?? platform.createPublicResourceClient;
  @override
  final String authorityEndpoint;
  final http.Client Function() _clientFactory;
  final Duration timeout;

  @override
  Future<Uint8List> approval(OnlineResourceCancellation cancellation) => _get(
    Uri.parse('$authorityEndpoint/viewer/resources/approval-state'),
    onlineApprovalMaxBytes,
    cancellation,
  );

  @override
  Future<Uint8List> fetch(
    String path,
    String manifestSha256,
    int maxBytes,
    OnlineResourceCancellation cancellation,
  ) {
    final valid = RegExp(
      r'^(?:releases/[a-f0-9]{64}\.json|objects/([a-f0-9]{2})/([a-f0-9]{64})\.(?:json\.gz|srgb\.gz|txci\.gz|zip(?:\.gz)?|png))$',
    ).firstMatch(path);
    resourceRequire(
      valid != null &&
          (valid[1] == null || valid[1] == valid[2]!.substring(0, 2)) &&
          onlineHashPattern.hasMatch(manifestSha256) &&
          maxBytes > 0 &&
          maxBytes <= onlineObjectMaxBytes,
      '公开资源路径或上限无效',
    );
    return _get(
      Uri.parse('$authorityEndpoint/viewer/resources/file').replace(
        queryParameters: {'path': path, 'manifestSha256': manifestSha256},
      ),
      maxBytes,
      cancellation,
    );
  }

  Future<Uint8List> _get(
    Uri uri,
    int maxBytes,
    OnlineResourceCancellation cancellation,
  ) async {
    cancellation.check();
    final client = _clientFactory();
    var closed = false;
    void close() {
      if (!closed) {
        closed = true;
        client.close();
      }
    }

    final timer = Timer(timeout, close);
    final cancelled = cancellation.signal.then<Uint8List>((_) {
      close();
      throw const OnlineResourceCancelled();
    });
    Future<Uint8List> run() async {
      try {
        final request =
            http.AbortableRequest('GET', uri, abortTrigger: cancellation.signal)
              ..followRedirects = false
              ..headers['Cache-Control'] = 'no-store';
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw StateError('资源下载失败 (${response.statusCode})');
        }
        if ((response.contentLength ?? 0) > maxBytes) {
          throw const FormatException('资源下载超过大小限制');
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          cancellation.check();
          if (builder.length + chunk.length > maxBytes) {
            throw const FormatException('资源下载超过大小限制');
          }
          builder.add(chunk);
        }
        cancellation.check();
        return builder.takeBytes();
      } finally {
        timer.cancel();
        close();
      }
    }

    // The explicit race also bounds injected transports that don't implement
    // AbortableRequest. Both futures have error listeners after cancellation.
    return Future.any([run(), cancelled]).timeout(
      timeout,
      onTimeout: () {
        close();
        throw TimeoutException('资源下载超时');
      },
    );
  }
}

String normalizeResourceEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint);
  resourceRequire(
    uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(uri.host) &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        !endpoint.contains(RegExp(r'[\s\x00-\x1f\\]')) &&
        !uri.pathSegments.any((s) => s == '..' || s == '.'),
    '资源后台需要明确的 HTTPS 地址',
  );
  return uri!.replace(path: uri.path.replaceAll(RegExp(r'/+$'), '')).toString();
}
