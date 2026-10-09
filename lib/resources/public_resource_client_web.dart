import 'dart:async';
import 'dart:js_interop';

import 'package:http/http.dart' as http;

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, _Options options);

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external JSObject get signal;
  external void abort();
}

extension type _Options._(JSObject _) implements JSObject {
  external factory _Options({
    required JSString method,
    required JSString credentials,
    required JSString cache,
    required JSString redirect,
    required JSObject signal,
    required JSObject headers,
  });
}

extension type _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external _Headers get headers;
  external _Body? get body;
}

extension type _Body._(JSObject _) implements JSObject {
  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_Chunk> read();
  external JSPromise<JSAny?> cancel();
  external void releaseLock();
}

extension type _Chunk._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

http.Client createPublicResourceClient() => _PublicResourceClient();

/// BrowserClient uses credentials:same-origin. Public resource downloads need
/// credentials:omit even when the application and resource host share an origin.
class _PublicResourceClient extends http.BaseClient {
  final Set<_AbortController> _controllers = {};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Public resource client is closed');
    if (request.method != 'GET' ||
        request.headers.keys.any(
          (key) => ['authorization', 'cookie'].contains(key.toLowerCase()),
        )) {
      throw http.ClientException(
        'Public resources require a credential-free GET',
      );
    }
    final controller = _AbortController();
    _controllers.add(controller);
    var complete = false;
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          if (!complete) controller.abort();
        }),
      );
    }
    try {
      final response = await _fetch(
        request.url.toString().toJS,
        _Options(
          method: 'GET'.toJS,
          credentials: 'omit'.toJS,
          cache: 'no-store'.toJS,
          redirect: 'error'.toJS,
          signal: controller.signal,
          headers: request.headers.jsify()! as JSObject,
        ),
      ).toDart;
      final size = response.headers.get('content-length'.toJS)?.toDart;
      final reader = response.body?.getReader();
      Stream<List<int>> stream() async* {
        try {
          if (reader == null) return;
          for (;;) {
            final chunk = await reader.read().toDart;
            if (chunk.done) break;
            final bytes = chunk.value;
            if (bytes == null) {
              throw http.ClientException('Invalid resource response body');
            }
            yield bytes.toDart;
          }
        } finally {
          complete = true;
          try {
            await reader?.cancel().toDart;
          } finally {
            reader?.releaseLock();
            _controllers.remove(controller);
          }
        }
      }

      return http.StreamedResponse(
        stream(),
        response.status,
        contentLength: size == null ? null : int.tryParse(size),
        request: request,
      );
    } catch (_) {
      complete = true;
      controller.abort();
      _controllers.remove(controller);
      rethrow;
    }
  }

  @override
  void close() {
    _closed = true;
    for (final controller in _controllers) {
      controller.abort();
    }
    _controllers.clear();
  }
}
