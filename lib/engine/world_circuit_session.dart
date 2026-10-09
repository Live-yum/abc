import 'dart:async';

import 'package:flutter/foundation.dart';

import 'world_circuit_backend.dart';

/// UI lifecycle for the actual 60 Hz circuit scheduler. Wall-clock callbacks
/// merely enqueue native ticks; device timing and wiring are engine-owned.
class WorldCircuitSession extends ChangeNotifier {
  final WorldCircuitBackend backend;
  final Uint8List _original;
  final Uint8List? _originalTwld;
  WorldCircuitResult? result;
  bool dirty = false;
  bool running = false;
  bool busy = false;
  Object? error;
  Timer? _timer;
  WorldCircuitCommand? _viewport;
  bool _closed = false;
  final Map<int, WorldCircuitFragment> _fragments = {};
  List<int>? _indexedGeometry;
  Future<void> _queue = Future.value();
  WorldCircuitSession(this.backend, Uint8List original, {Uint8List? twld})
    : _original = Uint8List.fromList(original),
      _originalTwld = twld == null ? null : Uint8List.fromList(twld);

  Future<T> _serial<T>(Future<T> Function() task) {
    final work = _queue.then((_) async {
      if (_closed) throw StateError('Circuit session is closed');
      busy = true;
      notifyListeners();
      try {
        return await task();
      } catch (e) {
        error = e;
        pause();
        rethrow;
      } finally {
        busy = false;
        if (!_closed) notifyListeners();
      }
    });
    _queue = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> open() => _serial(() async {
    if (result != null) throw StateError('Circuit already open');
    result = await backend.openWorldCircuit(_original, twld: _originalTwld);
    error = null;
  });

  Future<WorldCircuitResult> command(
    WorldCircuitCommand command, {
    bool refreshViewport = false,
  }) => _serial(() async {
    final active = result;
    if (active == null) throw StateError('Open the circuit first');
    final next = await backend.commandWorldCircuit(active.session, command);
    // Fragment queries return eight-word records, unlike the viewport. Keep
    // those out of the live four-word display and retain its current state.
    if (command.words[1] != 7 && command.words[1] != 8) result = next;
    if (command.mutates) dirty = true;
    if (command.words[1] == 1) {
      _viewport = WorldCircuitCommand.viewport(
        command.words[2],
        command.words[3],
        command.words[4],
        command.words[5],
        stride: command.words[6],
        walls: (command.words[12] & 2) != 0,
      );
    }
    if (refreshViewport && _viewport != null) {
      result = await backend.commandWorldCircuit(active.session, _viewport!);
    }
    error = null;
    return command.words[1] == 7 || command.words[1] == 8 ? next : result!;
  });

  Future<WorldCircuitFragmentPage> fragments({
    int offset = 0,
    int count = 256,
    List<int> geometry = const [],
  }) {
    final request = WorldCircuitCommand.fragments(
      offset: offset,
      count: count,
      geometry: geometry,
    );
    return _serial(() async {
      final active = result;
      if (active == null) throw StateError('Open the circuit first');
      final indexed = _indexedGeometry;
      if (indexed != null &&
          request.records.isNotEmpty &&
          !listEquals(indexed, request.records)) {
        throw StateError(
          'Reset the circuit before changing its object geometry',
        );
      }
      final response = await backend.commandWorldCircuit(
        active.session,
        indexed == null
            ? request
            : WorldCircuitCommand.fragments(offset: offset, count: count),
      );
      final page = WorldCircuitFragmentPage.fromResult(
        response,
        offset: offset,
        count: count,
      );
      _indexedGeometry ??= request.records;
      for (final fragment in page.fragments) {
        _fragments[fragment.id] = fragment;
      }
      error = null;
      return page;
    });
  }

  /// Pause first and wait for accepted simulation work before taking a snapshot.
  /// A descriptor from a closed/reset session is never silently reused.
  Future<WorldCircuitExtraction> extract(WorldCircuitFragment fragment) {
    pause();
    return _serial(() async {
      final active = result;
      if (active == null) throw StateError('Open the circuit first');
      if (!identical(_fragments[fragment.id], fragment)) {
        throw StateError('Refresh the circuit fragments before extracting');
      }
      final response = await backend.commandWorldCircuit(
        active.session,
        WorldCircuitCommand.extract(fragment.id),
      );
      final extraction = WorldCircuitExtraction.fromResult(response, fragment);
      error = null;
      return extraction;
    });
  }

  void run() {
    if (_closed || running || result == null) return;
    running = true;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (busy || !running) return;
      unawaited(
        command(WorldCircuitCommand.ticks(6), refreshViewport: true).catchError(
          (Object e) {
            pause();
            // _serial has already retained and surfaced the error.
            return result!;
          },
        ),
      );
    });
    notifyListeners();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    running = false;
    if (!_closed) notifyListeners();
  }

  Future<void> reset() {
    pause();
    return _serial(() async {
      final active = result;
      if (active != null) await backend.closeWorldCircuit(active.session);
      result = null;
      _fragments.clear();
      _indexedGeometry = null;
      result = await backend.openWorldCircuit(_original, twld: _originalTwld);
      dirty = false;
      error = null;
    });
  }

  /// Flush pending commands and stop before closing a world handle or adopting
  /// returned WLD bytes in the application's ordinary save pipeline.
  Future<void> close() async {
    pause();
    await _queue;
    if (_closed) return;
    final active = result;
    if (active != null) await backend.closeWorldCircuit(active.session);
    result = null;
    _fragments.clear();
    _indexedGeometry = null;
    _closed = true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Caller must await close before dispose; asynchronous engine teardown is
    // deliberately not hidden in a synchronous Widget disposal callback.
    assert(_closed, 'Await WorldCircuitSession.close before dispose');
    super.dispose();
  }
}
