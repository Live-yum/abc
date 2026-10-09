import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_models.dart';

class CloudServiceConfig {
  CloudServiceConfig({
    required this.baseUri,
    required Map<String, String> routes,
    required Set<CloudCapability> capabilities,
    Set<String> downloadOrigins = const {},
    this.maxJsonBytes = 2 * 1024 * 1024,
    this.maxFileBytes = 64 * 1024 * 1024,
    this.timeout = const Duration(seconds: 30),
  }) : routes = Map.unmodifiable(routes),
       capabilities = Set.unmodifiable(capabilities),
       downloadOrigins = Set.unmodifiable(downloadOrigins) {
    if (baseUri.scheme != 'https' ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      throw const CloudFailure(
        'Cloud configuration requires a secure service origin.',
      );
    }
    if (maxJsonBytes < 1 || maxFileBytes < 1 || timeout <= Duration.zero) {
      throw const CloudFailure('Invalid transfer limits.');
    }
    for (final route in routes.values) {
      final uri = baseUri.resolve(route);
      if (uri.origin != baseUri.origin ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.hasQuery) {
        throw const CloudFailure(
          'Cloud route must remain on its configured origin.',
        );
      }
    }
    for (final origin in downloadOrigins) {
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.origin != origin ||
          uri.userInfo.isNotEmpty) {
        throw const CloudFailure('Invalid download origin.');
      }
    }
  }
  final Uri baseUri;
  final Map<String, String> routes;
  final Set<CloudCapability> capabilities;
  final Set<String> downloadOrigins;
  final int maxJsonBytes, maxFileBytes;
  final Duration timeout;
  Uri endpoint(String name, [Map<String, String>? query]) {
    final route = routes[name];
    if (route == null) {
      throw const CloudFailure('This operation is not configured.');
    }
    return baseUri.resolve(route).replace(queryParameters: query);
  }
}

class CloudCancellation {
  final _abort = Completer<void>();
  bool get cancelled => _abort.isCompleted;
  Future<void> get signal => _abort.future;
  void cancel() {
    if (!cancelled) _abort.complete();
  }

  void check() {
    if (cancelled) throw const CloudFailure('Operation cancelled.');
  }
}

abstract interface class CloudApi {
  Set<CloudCapability> get capabilities;
  Future<List<CloudSave>> listSaves(
    CloudSession session, {
    int page = 1,
    int pageSize = 30,
  });
  Future<CloudSave> upload(
    CloudSession session,
    Uint8List bytes,
    String fileName,
    String kind, {
    CloudCancellation? cancellation,
  });
  Future<Uint8List> download(
    CloudSession session,
    String id, {
    CloudCancellation? cancellation,
  });
  Future<List<Map<String, dynamic>>> recommendations(CloudSession session);
  Future<Map<String, dynamic>> profile(CloudSession session);
  Future<void> updateProfile(CloudSession session, Map<String, dynamic> values);
  Future<GenerationOptions> options(CloudSession session);
  Future<CloudSave> submit(CloudSession session, GenerationRequest request);
  Future<CloudSave> refresh(CloudSession session, String id);
  Future<CloudSave> retry(CloudSession session, String id);
  Future<CloudSave> cancel(CloudSession session, String id);
}

class HttpCloudApi implements CloudApi {
  HttpCloudApi({required this.config, required this._client});
  final CloudServiceConfig config;
  final http.Client _client;
  @override
  Set<CloudCapability> get capabilities => config.capabilities;
  void _require(CloudCapability c) {
    if (!capabilities.contains(c)) {
      throw const CloudFailure('This capability is unavailable.');
    }
  }

  void _session(CloudSession s) {
    if (!s.valid) throw const CloudFailure('Your cloud session has expired.');
  }

  Map<String, String> _headers(CloudSession s) {
    _session(s);
    return {
      'Authorization': 'Bearer ${s.accessToken}',
      'Content-Type': 'application/json',
    };
  }

  Future<Uint8List> _send(
    http.BaseRequest request,
    int cap,
    CloudCancellation? cancellation,
  ) async {
    cancellation?.check();
    request.followRedirects = false;
    try {
      final response = await _client.send(request).timeout(config.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const CloudFailure(
          'Cloud request failed. Check your session and try again.',
        );
      }
      if ((response.contentLength ?? 0) > cap) {
        throw const CloudFailure('Cloud response exceeds the size limit.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(config.timeout)) {
        cancellation?.check();
        if (bytes.length + chunk.length > cap) {
          throw const CloudFailure('Cloud response exceeds the size limit.');
        }
        bytes.add(chunk);
      }
      cancellation?.check();
      return bytes.takeBytes();
    } on CloudFailure {
      rethrow;
    } catch (_) {
      throw const CloudFailure('Cloud request could not be completed.');
    }
  }

  dynamic _decode(Uint8List bytes) {
    try {
      final result = jsonDecode(utf8.decode(bytes));
      if (result is! Map ||
          result['code'] != 0 ||
          !result.containsKey('data')) {
        throw const CloudFailure(
          'Cloud service returned an unsuccessful response.',
        );
      }
      return result['data'];
    } on CloudFailure {
      rethrow;
    } catch (_) {
      throw const CloudFailure('Cloud response has an invalid format.');
    }
  }

  Future<dynamic> _json(
    CloudSession s,
    String route, {
    String method = 'GET',
    Map<String, String>? query,
    Object? body,
  }) async {
    final request = http.Request(method, config.endpoint(route, query))
      ..headers.addAll(_headers(s));
    if (body != null) request.body = jsonEncode(body);
    return _decode(await _send(request, config.maxJsonBytes, null));
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const CloudFailure('Cloud response has an invalid format.');
    }
    return value;
  }

  Future<T> _typed<T>(Future<dynamic> data, T Function(dynamic) parse) async {
    try {
      return parse(await data);
    } on CloudFailure {
      rethrow;
    } catch (_) {
      throw const CloudFailure('Cloud response has an invalid format.');
    }
  }

  @override
  Future<List<CloudSave>> listSaves(
    CloudSession session, {
    int page = 1,
    int pageSize = 30,
  }) {
    _require(CloudCapability.saves);
    if (page < 1 || pageSize < 1 || pageSize > 200) {
      throw const CloudFailure('Invalid page range.');
    }
    return _typed(
      _json(
        session,
        'listSaves',
        query: {'pageNo': '$page', 'pageSize': '$pageSize', 'kind': 'all'},
      ),
      (v) => (_map(v)['list'] as List)
          .map((v) => CloudSave.fromJson(_map(v)))
          .toList(),
    );
  }

  @override
  Future<CloudSave> upload(
    CloudSession session,
    Uint8List bytes,
    String fileName,
    String kind, {
    CloudCancellation? cancellation,
  }) async {
    _require(CloudCapability.upload);
    _session(session);
    if (bytes.isEmpty ||
        bytes.length > config.maxFileBytes ||
        !{'world', 'player', 'image'}.contains(kind) ||
        fileName.isEmpty ||
        fileName.length > 255 ||
        fileName.contains(RegExp(r'[/\\\r\n]'))) {
      throw const CloudFailure('Invalid upload.');
    }
    final request =
        http.AbortableMultipartRequest(
            'POST',
            config.endpoint('upload'),
            abortTrigger: cancellation?.signal,
          )
          ..headers['Authorization'] = 'Bearer ${session.accessToken}'
          ..fields.addAll({'kind': kind, 'fileName': fileName})
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: fileName),
          );
    return _typed(
      _send(request, config.maxJsonBytes, cancellation).then(_decode),
      (v) => CloudSave.fromJson(_map(v)),
    );
  }

  @override
  Future<Uint8List> download(
    CloudSession session,
    String id, {
    CloudCancellation? cancellation,
  }) async {
    _require(CloudCapability.download);
    final ticket = _map(await _json(session, 'download', query: {'id': id}));
    final uri = Uri.tryParse(
      ticket['downloadUrl'] is String ? ticket['downloadUrl'] as String : '',
    );
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        !config.downloadOrigins.contains(uri.origin)) {
      throw const CloudFailure('Download destination is not approved.');
    }
    // Signed links are separate requests: never forward the service session.
    return _send(
      http.AbortableRequest('GET', uri, abortTrigger: cancellation?.signal),
      config.maxFileBytes,
      cancellation,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> recommendations(CloudSession session) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session,
        'recommendations',
        query: {'pageNo': '1', 'pageSize': '30', 'kind': 'all'},
      ),
      (v) => (_map(v)['list'] as List).map(_map).toList(),
    );
  }

  @override
  Future<Map<String, dynamic>> profile(CloudSession session) {
    _require(CloudCapability.profile);
    return _typed(_json(session, 'profile'), _map);
  }

  @override
  Future<void> updateProfile(
    CloudSession session,
    Map<String, dynamic> values,
  ) async {
    _require(CloudCapability.updateProfile);
    if (values.keys.any((k) => !{'id', 'nickname', 'avatar'}.contains(k))) {
      throw const CloudFailure('Unsupported profile field.');
    }
    if (values['id'] is! int ||
        (values.containsKey('nickname') &&
            (values['nickname'] is! String ||
                (values['nickname'] as String).length > 80)) ||
        (values.containsKey('avatar') &&
            (values['avatar'] is! String ||
                (values['avatar'] as String).length > 2048))) {
      throw const CloudFailure('Invalid profile fields.');
    }
    await _json(session, 'updateProfile', method: 'POST', body: values);
  }

  @override
  Future<GenerationOptions> options(CloudSession session) {
    _require(CloudCapability.generation);
    return _typed(
      _json(session, 'options'),
      (v) => GenerationOptions.fromJson(_map(v)),
    );
  }

  Future<CloudSave> _job(
    CloudSession session,
    String route,
    String id,
    String method,
  ) {
    _require(CloudCapability.generation);
    return _typed(
      _json(session, route, method: method, query: {'id': id}),
      (v) => CloudSave.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudSave> submit(CloudSession session, GenerationRequest request) {
    _require(CloudCapability.generation);
    return _typed(
      _json(session, 'submit', method: 'POST', body: request.toJson()),
      (v) => CloudSave.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudSave> refresh(CloudSession session, String id) =>
      _job(session, 'refresh', id, 'GET');
  @override
  Future<CloudSave> retry(CloudSession session, String id) =>
      _job(session, 'retry', id, 'POST');
  @override
  Future<CloudSave> cancel(CloudSession session, String id) =>
      _job(session, 'cancel', id, 'POST');
}
