import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/terraria_map.dart';
import 'map_backend.dart';
import 'map_worker_owner.dart';

MapBackend createMapBackend() => _NativeMapBackend();

class _NativeMapBackend implements MapBackend {
  Isolate? _isolate;
  ReceivePort? _replies, _errors, _exit;
  Future<SendPort>? _starting;
  final _pending = <int, Completer<MapWorkerReply>>{};
  int _sequence = 0, _token = 0, _generation = 0;
  bool _disposed = false;
  Future<SendPort> _start() async {
    final ready = Completer<SendPort>(), generation = _generation;
    final replies = _replies = ReceivePort(),
        errors = _errors = ReceivePort(),
        exits = _exit = ReceivePort();
    void failed(Object error) {
      if (generation != _generation) return;
      if (!ready.isCompleted) ready.completeError(error);
      _shutdown(error);
    }

    errors.listen((e) => failed(StateError('MAP owner failed: $e')));
    exits.listen((_) {
      if (generation == _generation) failed(StateError('MAP owner closed'));
    });
    replies.listen((dynamic raw) {
      if (generation != _generation) return;
      if (raw is SendPort) {
        ready.complete(raw);
        return;
      }
      final list = raw as List;
      final waiting = _pending.remove(list[0] as int);
      if (waiting == null) return;
      if (list[1] == true) {
        final payload = list[3] as TransferableTypedData?;
        waiting.complete(
          MapWorkerReply(
            Map<String, Object?>.from(list[2] as Map),
            payload?.materialize().asUint8List(),
          ),
        );
      } else {
        waiting.completeError(StateError(list[2] as String));
      }
    });
    final spawned = await Isolate.spawn(
      _entry,
      replies.sendPort,
      onError: errors.sendPort,
      onExit: exits.sendPort,
    );
    if (generation != _generation) {
      spawned.kill(priority: Isolate.immediate);
      throw StateError('MAP owner superseded');
    }
    _isolate = spawned;
    return ready.future;
  }

  void _shutdown(Object error) {
    _generation++;
    _token = 0;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _starting = null;
    _replies?.close();
    _errors?.close();
    _exit?.close();
    _replies = null;
    _errors = null;
    _exit = null;
    for (final request in _pending.values) {
      request.completeError(error);
    }
    _pending.clear();
  }

  Future<MapWorkerReply> _call(
    String method,
    Map<String, Object?> args, [
    Uint8List? bytes,
  ]) async {
    if (_disposed) throw StateError('MAP backend is disposed');
    if (bytes != null &&
        (bytes.length < 4 || bytes.length > TerrariaMapSession.maxInputBytes)) {
      throw StateError('MAP input size exceeds supported bounds');
    }
    final generation = _generation;
    final payload = bytes == null
        ? null
        : TransferableTypedData.fromList([bytes]);
    final owner = await (_starting ??= _start());
    if (generation != _generation || _disposed) {
      throw StateError('MAP operation superseded');
    }
    if (_pending.length >= 8) throw StateError('MAP request queue is full');
    final id = ++_sequence, result = Completer<MapWorkerReply>();
    _pending[id] = result;
    owner.send([id, method, args, payload]);
    final response = await result.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _shutdown(TimeoutException('MAP owner timed out'));
        throw TimeoutException('MAP owner timed out');
      },
    );
    if (generation != _generation || _disposed) {
      throw StateError('MAP operation superseded');
    }
    return response;
  }

  Future<MapSessionInfo> _info(
    String method,
    Map<String, Object?> args, [
    Uint8List? bytes,
  ]) async {
    final generation = _generation;
    final response = await _call(method, args, bytes);
    if (generation != _generation || _disposed) {
      throw StateError('MAP operation superseded');
    }
    final info = MapSessionInfo.fromJson(
      Map<String, dynamic>.from(response.metadata),
    );
    _token = info.token;
    return info;
  }

  @override
  Future<MapSessionInfo> open(
    Uint8List bytes, {
    Map<String, Object?>? expectedWorld,
  }) => _info('open', {
    'expectedWorld': expectedWorld == null
        ? null
        : Map<String, Object?>.from(expectedWorld),
  }, bytes);
  @override
  Future<MapSessionInfo> editRect(
    int x,
    int y,
    int width,
    int height, {
    int? light,
    int? color,
  }) => _info('edit', {
    'token': _token,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'light': light,
    'color': color,
  });
  @override
  Future<MapSessionInfo> undo() => _info('undo', {'token': _token});
  @override
  Future<MapSessionInfo> redo() => _info('redo', {'token': _token});
  @override
  Future<TerrariaMapRaster> render({int maxWidth = 960}) async {
    final response = await _call('render', {
      'token': _token,
      'maxWidth': maxWidth,
    });
    return TerrariaMapRaster(
      response.metadata['width'] as int,
      response.metadata['height'] as int,
      response.bytes!,
    );
  }

  @override
  Future<Uint8List> exportVerified() async =>
      (await _call('export', {'token': _token})).bytes!;
  @override
  Future<void> close() async {
    _shutdown(StateError('MAP session closed'));
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _shutdown(StateError('MAP backend disposed'));
  }
}

void _entry(SendPort reply) {
  final owner = MapWorkerOwner(), requests = ReceivePort();
  reply.send(requests.sendPort);
  requests.listen((dynamic raw) {
    final request = raw as List, id = request[0] as int;
    try {
      final input = request[3] as TransferableTypedData?;
      final result = owner.invoke(
        request[1] as String,
        Map<String, dynamic>.from(request[2] as Map),
        input?.materialize().asUint8List(),
      );
      reply.send([
        id,
        true,
        result.metadata,
        result.bytes == null
            ? null
            : TransferableTypedData.fromList([result.bytes!]),
      ]);
    } catch (error) {
      reply.send([id, false, error.toString()]);
    }
  });
}
