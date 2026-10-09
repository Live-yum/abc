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
    this.tenantId,
    this.terminal,
    this.maxJsonBytes = 2 * 1024 * 1024,
    this.maxFileBytes = 64 * 1024 * 1024,
    this.timeout = const Duration(seconds: 30),
  }) : routes = Map.unmodifiable(routes),
       capabilities = Set.unmodifiable(capabilities) {
    if (baseUri.scheme != 'https' ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      throw const CloudFailure(
        'Cloud configuration requires a secure service origin.',
      );
    }
    for (final value in [tenantId, terminal]) {
      if (value != null && !RegExp(r'^[0-9]{1,20}$').hasMatch(value)) {
        throw const CloudFailure(
          'Invalid service tenant or terminal identifier.',
        );
      }
    }
    if (maxJsonBytes < 1 || maxFileBytes < 1 || timeout <= Duration.zero) {
      throw const CloudFailure('Invalid transfer limits.');
    }
    for (final route in routes.values) {
      final relative = Uri.tryParse(route);
      if (relative == null ||
          relative.hasScheme ||
          relative.hasAuthority ||
          route.contains(RegExp(r'[\\\x00-\x20\x7f]')) ||
          relative.pathSegments.any(
            (segment) => segment == '.' || segment == '..',
          )) {
        throw const CloudFailure('Cloud routes must be local service paths.');
      }
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
  }

  /// Verified viewer wire routes; the service origin is supplied by the host.
  factory CloudServiceConfig.viewer({
    required Uri baseUri,
    int maxFileBytes = 100 * 1024 * 1024,
    String? tenantId,
    String? terminal,
  }) => CloudServiceConfig(
    baseUri: baseUri.replace(
      path: '${baseUri.path.replaceAll(RegExp(r"/+$"), "")}/',
    ),
    maxFileBytes: maxFileBytes,
    tenantId: tenantId,
    terminal: terminal,
    capabilities: CloudCapability.values.toSet(),
    routes: const {
      'listSaves': 'viewer/cloud-saves/list',
      'getSave': 'viewer/cloud-saves/get',
      'duplicate': 'viewer/cloud-saves/duplicate',
      'deleteSave': 'viewer/cloud-saves/delete',
      'upload': 'viewer/cloud-saves/upload',
      'download': 'viewer/cloud-saves/download',
      'recommendations': 'viewer/recommendations/list',
      'getRecommendation': 'viewer/recommendations/get',
      'likeRecommendation': 'viewer/recommendations/like',
      'recommendationTicket': 'viewer/recommendations/download-ticket',
      'recommendationDownload': 'viewer/recommendations/download',
      'recommendationComplete': 'viewer/recommendations/download-complete',
      'recommendationTransfer': 'viewer/recommendations/transfer',
      'recommendationOperation': 'viewer/recommendations/operation',
      'help': 'viewer/helper-info/searchAllHelperInfo',
      'profile': 'viewer/user-info/getUserInfo',
      'updateProfile': 'viewer/user-info/updateAppUserInfo',
      'options': 'viewer/world-generation/options',
      'submit': 'viewer/world-generation/submit',
      'refresh': 'viewer/cloud-saves/get',
      'retry': 'viewer/world-generation/retry',
      'cancel': 'viewer/world-generation/cancel',
    },
  );

  final Uri baseUri;
  final String? tenantId, terminal;
  final Map<String, String> routes;
  final Set<CloudCapability> capabilities;
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
  String get serviceOrigin;
  String? get tenantId;
  String? get terminal;
  String? normalizeAvatar(String value);
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
    Uint8List? preview,
    CloudCancellation? cancellation,
  });
  Future<Uint8List> download(
    CloudSession session,
    String id, {
    int? expectedBytes,
    CloudCancellation? cancellation,
  });
  Future<CloudSave> getSave(
    CloudSession session,
    String id, {
    CloudCancellation? cancellation,
  });
  Future<CloudSave?> duplicate(
    CloudSession session, {
    required String kind,
    required String hash,
    required int fileSize,
    CloudCancellation? cancellation,
  });
  Future<void> deleteSave(CloudSession session, String id);
  Future<List<CloudRecommendation>> recommendations(
    CloudSession? session, {
    String kind = 'all',
    int page = 1,
    int pageSize = 30,
  });
  Future<CloudRecommendation> getRecommendation(
    CloudSession? session,
    String id, {
    CloudCancellation? cancellation,
  });
  Future<CloudRecommendationCounts> likeRecommendation(
    CloudSession session,
    String id,
  );
  Future<CloudRecommendationTicket> recommendationTicket(
    CloudSession session,
    String id,
    String requestId, {
    CloudCancellation? cancellation,
  });
  Future<Uint8List> recommendationDownload(
    CloudSession session,
    CloudRecommendationTicket ticket, {
    CloudCancellation? cancellation,
  });
  Future<CloudRecommendationCounts> recommendationComplete(
    CloudSession session,
    String operationId,
  );
  Future<CloudRecommendationTransfer> recommendationTransfer(
    CloudSession session,
    String id,
    String requestId, {
    CloudCancellation? cancellation,
  });
  Future<CloudRecommendationTransfer> recommendationOperation(
    CloudSession session,
    String operationId, {
    CloudCancellation? cancellation,
  });
  Future<List<CloudHelpArticle>> help(CloudSession? session);
  Future<Map<String, dynamic>> profile(CloudSession session);
  Future<void> updateProfile(CloudSession session, Map<String, dynamic> values);
  Future<GenerationOptions> options(CloudSession session);
  Future<CloudSave> submit(CloudSession session, GenerationRequest request);
  Future<CloudSave> refresh(CloudSession session, String id);
  Future<CloudSave> retry(CloudSession session, String id);
  Future<CloudSave> cancel(CloudSession session, String id);
}

class HttpCloudApi implements CloudApi {
  HttpCloudApi({required this.config, required http.Client client})
    // Keep the public injection name stable and the owned field private.
    // ignore: prefer_initializing_formals
    : _client = client;
  final CloudServiceConfig config;
  final http.Client _client;
  @override
  Set<CloudCapability> get capabilities => config.capabilities;
  @override
  String get serviceOrigin => config.baseUri.origin;
  @override
  String? get tenantId => config.tenantId;
  @override
  String? get terminal => config.terminal;
  @override
  String? normalizeAvatar(String value) {
    final text = value.trim();
    if (text.isEmpty) return '';
    if (RegExp(r'^https://[^/?#]*@', caseSensitive: false).hasMatch(text)) {
      return null;
    }
    if (text.length > 2048 ||
        text.contains(RegExp(r'[\x00-\x20\x7f-\x9f]')) ||
        text.contains(r'\') ||
        RegExp(
          r'%(?:0[0-9a-f]|1[0-9a-f]|7f)',
          caseSensitive: false,
        ).hasMatch(text)) {
      return null;
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.hasFragment ||
        text.startsWith('//')) {
      return null;
    }
    final resolved = uri.hasScheme ? uri : config.baseUri.resolve(text);
    if (resolved.scheme != 'https' ||
        resolved.host.isEmpty ||
        resolved.userInfo.isNotEmpty) {
      return null;
    }
    if (!uri.hasScheme && !text.startsWith('/')) return null;
    return resolved.toString();
  }

  void _require(CloudCapability c) {
    if (!capabilities.contains(c)) {
      throw const CloudFailure('This capability is unavailable.');
    }
  }

  void _session(CloudSession s) {
    if (!s.valid) throw const CloudFailure('Your cloud session has expired.');
  }

  Map<String, String> _headers(CloudSession? s, {bool json = true}) {
    if (s != null) _session(s);
    return {
      if (s != null) 'Authorization': 'Bearer ${s.accessToken}',
      'Accept': '*/*',
      if (json) 'Content-Type': 'application/json',
      if (config.tenantId != null) 'tenant-id': config.tenantId!,
      if (config.terminal != null) 'terminal': config.terminal!,
    };
  }

  Future<Uint8List> _send(
    http.BaseRequest request,
    int cap,
    CloudCancellation? cancellation, {
    int? expectedBytes,
  }) async {
    cancellation?.check();
    request.followRedirects = false;
    try {
      final response = await _client.send(request).timeout(config.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CloudFailure(
          'Cloud request failed. Check your session and try again.',
          statusCode: response.statusCode,
        );
      }
      if (expectedBytes != null &&
          response.contentLength != null &&
          response.contentLength != expectedBytes) {
        throw const CloudFailure(
          'Downloaded file length does not match the expected file.',
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
      if (expectedBytes != null && bytes.length != expectedBytes) {
        throw const CloudFailure('Downloaded file is incomplete.');
      }
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
        throw CloudFailure(
          'Cloud service returned an unsuccessful response.',
          statusCode: result is Map && result['code'] is int
              ? result['code'] as int
              : null,
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
    CloudSession? s,
    String route, {
    String method = 'GET',
    Map<String, String>? query,
    Object? body,
    CloudCancellation? cancellation,
  }) async {
    final request = http.AbortableRequest(
      method,
      config.endpoint(route, query),
      abortTrigger: cancellation?.signal,
    )..headers.addAll(_headers(s));
    if (body != null) request.body = jsonEncode(body);
    return _decode(await _send(request, config.maxJsonBytes, cancellation));
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
    if (page < 1 || page > 100000 || pageSize < 1 || pageSize > 100) {
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
    Uint8List? preview,
    CloudCancellation? cancellation,
  }) async {
    _require(CloudCapability.upload);
    _session(session);
    if (bytes.isEmpty ||
        bytes.length > config.maxFileBytes ||
        !{'world', 'player', 'image'}.contains(kind) ||
        fileName.trim().isEmpty ||
        fileName.length > 180 ||
        (kind == 'world' && !fileName.toLowerCase().endsWith('.wld')) ||
        (kind == 'player' && !fileName.toLowerCase().endsWith('.plr')) ||
        (kind == 'image' &&
            (bytes.length > 10 * 1024 * 1024 ||
                !RegExp(
                  r'\.(png|jpe?g|bmp|gif)$',
                  caseSensitive: false,
                ).hasMatch(fileName))) ||
        fileName.contains(RegExp(r'[/\\\r\n]'))) {
      throw const CloudFailure('Invalid upload.');
    }
    cloudFileName(fileName);
    if (kind == 'world' && preview == null) {
      throw const CloudFailure('World uploads require a rendered PNG preview.');
    }
    if (preview != null) {
      if (preview.length < 33 ||
          preview.length > 10 * 1024 * 1024 ||
          preview.sublist(0, 8).join(',') != '137,80,78,71,13,10,26,10') {
        throw const CloudFailure('Invalid cloud preview image.');
      }
      final header = ByteData.sublistView(preview);
      final width = header.getUint32(16), height = header.getUint32(20);
      if (width < 1 || height < 1 || width > 32000000 ~/ height) {
        throw const CloudFailure('Cloud preview dimensions exceed the limit.');
      }
    }
    final request =
        http.AbortableMultipartRequest(
            'POST',
            config.endpoint('upload'),
            abortTrigger: cancellation?.signal,
          )
          ..headers.addAll(_headers(session, json: false))
          ..fields.addAll({
            'kind': kind,
            'fileName': fileName,
            if (preview != null) 'preview': base64Encode(preview),
          })
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
    int? expectedBytes,
    CloudCancellation? cancellation,
  }) async {
    _require(CloudCapability.download);
    if (expectedBytes != null &&
        (expectedBytes < 1 || expectedBytes > config.maxFileBytes)) {
      throw const CloudFailure('Invalid cloud file size.');
    }
    cloudUuid(id);
    final request = http.AbortableRequest(
      'GET',
      config.endpoint('download', {'id': id}),
      abortTrigger: cancellation?.signal,
    )..headers.addAll(_headers(session, json: false));
    return _send(
      request,
      expectedBytes ?? config.maxFileBytes,
      cancellation,
      expectedBytes: expectedBytes,
    );
  }

  @override
  Future<CloudSave> getSave(
    CloudSession session,
    String id, {
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.saves);
    return _typed(
      _json(
        session,
        'getSave',
        query: {'id': cloudUuid(id)},
        cancellation: cancellation,
      ),
      (v) => CloudSave.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudSave?> duplicate(
    CloudSession session, {
    required String kind,
    required String hash,
    required int fileSize,
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.upload);
    if (!{'world', 'player'}.contains(kind) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(hash) ||
        fileSize < 1 ||
        fileSize > config.maxFileBytes) {
      throw const CloudFailure('Invalid duplicate check.');
    }
    return _typed(
      _json(
        session,
        'duplicate',
        query: {'kind': kind, 'hash': hash, 'fileSize': '$fileSize'},
        cancellation: cancellation,
      ),
      (v) => v == null ? null : CloudSave.fromJson(_map(v)),
    );
  }

  @override
  Future<void> deleteSave(CloudSession session, String id) async {
    _require(CloudCapability.saves);
    if (await _json(
          session,
          'deleteSave',
          method: 'DELETE',
          query: {'id': cloudUuid(id)},
        ) !=
        true) {
      throw const CloudFailure(
        'The service did not confirm deletion. Refresh the list before retrying.',
      );
    }
  }

  @override
  Future<List<CloudRecommendation>> recommendations(
    CloudSession? session, {
    String kind = 'all',
    int page = 1,
    int pageSize = 30,
  }) {
    _require(CloudCapability.recommendations);
    if (!{'all', 'world', 'player'}.contains(kind) ||
        page < 1 ||
        pageSize < 1 ||
        pageSize > 200) {
      throw const CloudFailure('Invalid recommendation query.');
    }
    return _typed(
      _json(
        session?.valid == true ? session : null,
        'recommendations',
        query: {'pageNo': '$page', 'pageSize': '$pageSize', 'kind': kind},
      ),
      (v) => (_map(v)['list'] as List)
          .map((v) => CloudRecommendation.fromJson(_map(v)))
          .toList(),
    );
  }

  @override
  Future<CloudRecommendation> getRecommendation(
    CloudSession? session,
    String id, {
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session?.valid == true ? session : null,
        'getRecommendation',
        query: {'id': cloudUuid(id)},
        cancellation: cancellation,
      ),
      (v) => CloudRecommendation.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudRecommendationCounts> likeRecommendation(
    CloudSession session,
    String id,
  ) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session,
        'likeRecommendation',
        method: 'POST',
        body: {'id': cloudUuid(id)},
      ),
      (v) => CloudRecommendationCounts.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudRecommendationTicket> recommendationTicket(
    CloudSession session,
    String id,
    String requestId, {
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session,
        'recommendationTicket',
        method: 'POST',
        body: {'id': cloudUuid(id), 'requestId': cloudUuid(requestId)},
        cancellation: cancellation,
      ),
      (v) => CloudRecommendationTicket.fromJson(_map(v)),
    );
  }

  @override
  Future<Uint8List> recommendationDownload(
    CloudSession session,
    CloudRecommendationTicket ticket, {
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.recommendations);
    final path =
        '/viewer/recommendations/download?operationId=${cloudUuid(ticket.operationId)}';
    if (ticket.downloadUrl != path ||
        ticket.fileSize < 1 ||
        ticket.fileSize > config.maxFileBytes ||
        !ticket.expiresAt.isAfter(DateTime.now())) {
      throw const CloudFailure(
        'Recommendation download destination or size is invalid.',
      );
    }
    // Match the reference path exactly before resolving against the service.
    // No redirect or arbitrary response-supplied origin ever receives credentials.
    final request = http.AbortableRequest(
      'GET',
      config.endpoint('recommendationDownload', {
        'operationId': ticket.operationId,
      }),
      abortTrigger: cancellation?.signal,
    )..headers.addAll(_headers(session, json: false));
    return _send(
      request,
      ticket.fileSize,
      cancellation,
      expectedBytes: ticket.fileSize,
    );
  }

  @override
  Future<CloudRecommendationCounts> recommendationComplete(
    CloudSession session,
    String operationId,
  ) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session,
        'recommendationComplete',
        method: 'POST',
        body: {'operationId': cloudUuid(operationId)},
      ),
      (v) => CloudRecommendationCounts.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudRecommendationTransfer> recommendationTransfer(
    CloudSession session,
    String id,
    String requestId, {
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session,
        'recommendationTransfer',
        method: 'POST',
        body: {'id': cloudUuid(id), 'requestId': cloudUuid(requestId)},
        cancellation: cancellation,
      ),
      (v) => CloudRecommendationTransfer.fromJson(_map(v)),
    );
  }

  @override
  Future<CloudRecommendationTransfer> recommendationOperation(
    CloudSession session,
    String operationId, {
    CloudCancellation? cancellation,
  }) {
    _require(CloudCapability.recommendations);
    return _typed(
      _json(
        session,
        'recommendationOperation',
        query: {'operationId': cloudUuid(operationId)},
        cancellation: cancellation,
      ),
      (v) => CloudRecommendationTransfer.fromJson(_map(v)),
    );
  }

  @override
  Future<List<CloudHelpArticle>> help(CloudSession? session) {
    _require(CloudCapability.help);
    return _typed(_json(session?.valid == true ? session : null, 'help'), (v) {
      if (v is! List || v.length > 200) {
        throw const CloudFailure('Invalid help list.');
      }
      return v.map((v) => CloudHelpArticle.fromJson(_map(v))).toList();
    });
  }

  @override
  Future<Map<String, dynamic>> profile(CloudSession session) {
    _require(CloudCapability.profile);
    return _typed(_json(session, 'profile'), (value) {
      final data = _map(value);
      if (data['id'] is! int ||
          (data['nickname'] != null && data['nickname'] is! String) ||
          (data['avatar'] != null && data['avatar'] is! String)) {
        throw const CloudFailure('Invalid account profile.');
      }
      return {
        'id': data['id'],
        'nickname': data['nickname'] ?? '',
        'avatar': data['avatar'] ?? '',
      };
    });
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
                (values['avatar'] as String).length > 2048 ||
                normalizeAvatar(values['avatar'] as String) == null))) {
      throw const CloudFailure('Invalid profile fields.');
    }
    final normalized = {
      ...values,
      if (values.containsKey('avatar'))
        'avatar': normalizeAvatar(values['avatar'] as String),
    };
    if (await _json(
          session,
          'updateProfile',
          method: 'POST',
          body: normalized,
        ) !=
        true) {
      throw const CloudFailure(
        'The service did not confirm the profile update.',
      );
    }
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
