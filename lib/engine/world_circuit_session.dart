import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/circuit_display.dart';
import '../diagnostics/host_stage_timings.dart';
import 'world_circuit_backend.dart';

/// Owns one generic WLD wiring session and its selected view regions.
class WorldCircuitSession extends ChangeNotifier {
  final WorldCircuitBackend backend;
  final HostStageTimings hostStages;
  final Uint8List? _original;
  final WorldCircuitSource? source;
  WorldCircuitResult? result;
  WorldCircuitProgress? progress;
  bool dirty = false, running = false, busy = false;
  Object? error;
  bool optimizationEnabled = false, optimizationSupported = false;
  bool wireHeadPixelRulesEnabled = false;
  bool _publishingRuntimeFrame = false, _lastPublishedDirty = false;
  bool get isRuntimeFramePublication => _publishingRuntimeFrame;
  bool get streamed => source != null;
  Timer? _timer, _progressTimer;
  Future<void>? _progressPoll, _closeFuture;
  int _progressEpoch = 0, _operationGeneration = 0, _runGeneration = 0;
  bool _runtimePending = false, _closing = false, _closed = false;
  Future<void> _queue = Future.value();
  WorldCircuitCommand? _viewport;
  final Map<int, WorldCircuitFragment> _fragments = {};
  List<int>? _indexedGeometry;
  CircuitDisplayRegion? displayRegion;
  Uint8List? displayFrame;
  int displayPixelCount = 0;
  Object displayIdentity = Object();

  void markSaved() {
    if (_closed || _closing) return;
    dirty = false;
    notifyListeners();
  }

  WorldCircuitSession(
    this.backend,
    Uint8List original, {
    HostStageTimings? hostStages,
  }) : hostStages = hostStages ?? HostStageTimings(),
       _original = Uint8List.fromList(original),
       source = null;

  WorldCircuitSession.fromSource(
    this.backend,
    this.source, {
    HostStageTimings? hostStages,
  }) : hostStages = hostStages ?? HostStageTimings(),
       _original = null {
    if (source == null || backend is! WorldCircuitSourceBackend) {
      throw ArgumentError('Streaming world backend and source are required');
    }
  }

  Future<WorldCircuitResult> _openOriginal() async {
    final input = source;
    if (input == null) {
      return backend.openWorldCircuit(_original!);
    }
    return (backend as WorldCircuitSourceBackend).openWorldCircuitSource(input);
  }

  Future<void> cancelOperation() async {
    pause();
    _operationGeneration++;
    if (backend is WorldCircuitSourceBackend) {
      await (backend as WorldCircuitSourceBackend)
          .cancelWorldCircuitOperation();
    }
  }

  void _startProgressPolling() {
    if (backend is! WorldCircuitSourceBackend || _closed || _closing) return;
    final epoch = ++_progressEpoch;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_progressPoll != null ||
          epoch != _progressEpoch ||
          _closed ||
          _closing ||
          !busy) {
        return;
      }
      final poll = _readProgress(epoch);
      _progressPoll = poll;
      unawaited(
        poll.then<void>((_) {
          if (identical(_progressPoll, poll)) _progressPoll = null;
        }),
      );
    });
  }

  Future<void> _readProgress(int epoch) async {
    try {
      final next = await (backend as WorldCircuitSourceBackend)
          .worldCircuitProgress();
      if (next != null &&
          epoch == _progressEpoch &&
          busy &&
          !_closed &&
          !_closing) {
        progress = next;
        notifyListeners();
      }
    } catch (_) {
      // The operation reports its own failure. A settled progress Future is
      // only a Dart drain; the transport still requires a real owner ACK.
    }
  }

  Future<void> _stopProgressPolling() async {
    _progressEpoch++;
    _progressTimer?.cancel();
    _progressTimer = null;
    final poll = _progressPoll;
    await poll;
    if (identical(_progressPoll, poll)) _progressPoll = null;
  }

  Future<T> _serial<T>(
    Future<T> Function() task, {
    bool notifyState = true,
    bool pollProgress = true,
  }) {
    final queued = Stopwatch()..start();
    final work = _queue.then((_) async {
      hostStages.record('session.queueWait', queued.elapsedMicroseconds);
      if (_closed || _closing) throw StateError('Circuit session is closed');
      busy = true;
      if (notifyState) notifyListeners();
      try {
        // Dispatch first so the first poll belongs to this operation.
        final pending = task();
        if (pollProgress) _startProgressPolling();
        return await pending;
      } catch (e) {
        error = e;
        pause();
        rethrow;
      } finally {
        await _stopProgressPolling();
        busy = false;
        if (!_closed && notifyState) notifyListeners();
      }
    });
    _queue = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> open() => _serial(() async {
    if (result != null) throw StateError('Circuit already open');
    progress = null;
    result = await _openOriginal();
    optimizationEnabled = result!.circuitOptimizationEnabled;
    optimizationSupported = result!.circuitOptimizationSupported;
    wireHeadPixelRulesEnabled = result!.wireHeadPixelRulesEnabled;
    error = null;
  });

  @override
  void notifyListeners() => _publishListeners();

  void _publishListeners({bool runtimeFrame = false}) {
    final previous = _publishingRuntimeFrame;
    // Dirty may first change in a throttled batch that did not publish. Compare
    // with the last publication, not just the beginning of this batch.
    _publishingRuntimeFrame = runtimeFrame && dirty == _lastPublishedDirty;
    _lastPublishedDirty = dirty;
    try {
      hostStages.measure('session.publishListeners', super.notifyListeners);
    } finally {
      _publishingRuntimeFrame = previous;
    }
  }

  Future<WorldCircuitResult> _observedCommand(
    int id, WorldCircuitCommand command,
  ) async {
    final stage = 'command.${command.words[1]}';
    final watch = Stopwatch()..start();
    try {
      final reply = await backend.commandWorldCircuit(id, command);
      hostStages.recordBridge(stage, reply.hostStagesUs);
      return reply;
    } finally {
      hostStages.record(stage, watch.elapsedMicroseconds);
    }
  }

  Uint8List _decodeDisplay(CircuitDisplayRegion region, WorldCircuitResult reply) =>
      hostStages.measure('display.rgbaDecode', () => region.decode(reply));

  void _acceptDisplay(Uint8List pixels) {
    final unchanged = hostStages.measure('display.listEquals',
        () => listEquals(pixels, displayFrame));
    if (!unchanged) displayFrame = pixels;
  }

  void _clearDisplay() {
    displayRegion = null;
    displayFrame = null;
    displayPixelCount = 0;
    displayIdentity = Object();
  }

  Future<void> _readDisplay(int id) async {
    final region = displayRegion;
    if (region == null) return;
    final reply = await _observedCommand(id, region.command);
    final pixels = _decodeDisplay(region, reply);
    displayPixelCount = reply.records.length ~/ 16;
    _acceptDisplay(pixels);
  }

  Future<void> readDisplay(CircuitDisplayRegion region) => _serial(() async {
    final active = result;
    if (active == null) throw StateError('请先载入世界电路。');
    region.validate();
    if (region.x + region.width > active.width ||
        region.y + region.height > active.height) {
      throw const FormatException('显示选区超出当前世界边界。');
    }
    final reply = await _observedCommand(active.session, region.command);
    final pixels = _decodeDisplay(region, reply);
    final previous = displayRegion;
    if (previous == null || previous.x != region.x || previous.y != region.y ||
        previous.width != region.width || previous.height != region.height) {
      displayIdentity = Object();
    }
    displayRegion = region;
    displayFrame = pixels;
    displayPixelCount = reply.records.length ~/ 16;
    error = null;
  });

  Future<void> refreshDisplay() => _serial(() async {
    if (displayRegion == null) return;
    final active = result;
    if (active == null) throw StateError('请先载入世界电路。');
    await _readDisplay(active.session);
    error = null;
  });

  Future<void> setOptimization(bool enabled) {
    pause();
    return _serial(() async {
      final active = result;
      if (active == null) throw StateError('请先载入世界电路。');
      if (enabled && !optimizationSupported) {
        throw StateError('当前像素接线拓扑不支持此模式；同色跨轴网络暂不支持，请保持电路优化关闭。');
      }
      final next = await _observedCommand(active.session,
          WorldCircuitCommand.optimization(enabled));
      if (next.circuitOptimizationEnabled != enabled ||
          next.wireHeadPixelRulesEnabled != enabled ||
          (enabled && !next.circuitOptimizationSupported)) {
        throw StateError('引擎未确认电路优化模式，当前会话保持暂停。');
      }
      result = next;
      optimizationEnabled = enabled;
      optimizationSupported = next.circuitOptimizationSupported;
      wireHeadPixelRulesEnabled = next.wireHeadPixelRulesEnabled;
      if (_viewport != null) {
        result = await _observedCommand(active.session, _viewport!);
      }
      await _readDisplay(active.session);
      error = null;
    });
  }

  Future<WorldCircuitResult> _applyCommand(WorldCircuitCommand command,
      {bool refreshViewport = false}) async {
    final active = result;
    if (active == null) throw StateError('Open the circuit first');
    final region = displayRegion;
    final transport = backend;
    WorldCircuitResult next;
    WorldCircuitBatchResult? batch;
    if (refreshViewport && region != null &&
        transport is WorldCircuitBatchBackend &&
        (command.words[1] == 2 || command.words[1] == 3)) {
      final watch = Stopwatch()..start();
      try {
        batch = await transport.commandAndReadPixels(active.session, command,
            region.command);
      } finally {
        hostStages.record('runtime.batch', watch.elapsedMicroseconds);
      }
      next = batch.command;
    } else {
      next = await _observedCommand(active.session, command);
    }
    final query = [4, 7, 8, 9].contains(command.words[1]);
    if (!query) result = next;
    if (command.mutates) dirty = true;
    if (batch != null) {
      // A successful mutation survives a subsequent read failure. Never replay it.
      final pixels = batch.pixels;
      if (pixels == null) {
        throw StateError(batch.readError ?? '电路命令完成，但选区读取未完成。');
      }
      final rgba = _decodeDisplay(region!, pixels);
      displayPixelCount = pixels.records.length ~/ 16;
      _acceptDisplay(rgba);
      hostStages.recordBridge('runtime.batch', batch.hostStagesUs);
    }
    if (command.words[1] == 1) {
      _viewport = WorldCircuitCommand.viewport(command.words[2], command.words[3],
          command.words[4], command.words[5], stride: command.words[6],
          walls: (command.words[12] & 2) != 0);
    }
    if (refreshViewport && _viewport != null) {
      result = await _observedCommand(active.session, _viewport!);
    }
    if (refreshViewport && batch == null) await _readDisplay(active.session);
    error = null;
    return query ? next : result!;
  }

  Future<WorldCircuitResult> command(WorldCircuitCommand command,
      {bool refreshViewport = false}) => _serial(() =>
          _applyCommand(command, refreshViewport: refreshViewport));

  /// Publish a completed generic running batch and its selected views together.
  Future<WorldCircuitResult> runtimeCommand(WorldCircuitCommand command) async {
    final generation = _runGeneration;
    try {
      return await _serial(() => _applyCommand(command, refreshViewport: true),
          notifyState: false, pollProgress: false);
    } finally {
      // Errors are first published while busy; also publish their settled state.
      if (!_closed && !_closing) {
        _publishListeners(runtimeFrame:
            error == null && generation == _runGeneration && running);
      }
    }
  }

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
      final response = await _observedCommand(
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
      final response = await _observedCommand(
        active.session,
        WorldCircuitCommand.extract(fragment.id),
      );
      final extraction = WorldCircuitExtraction.fromResult(response, fragment);
      error = null;
      return extraction;
    });
  }

  /// Request up to 60 virtual mechanical ticks per second. Busy owners slow
  /// simulation rather than dropping or inventing ticks or entity collisions.
  void run() {
    if (_closed || _closing || running || result == null) return;
    running = true;
    _runGeneration++;
    hostStages.reset();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (busy || !running || _runtimePending) return;
      _runtimePending = true;
      unawaited(runtimeCommand(WorldCircuitCommand.ticks(6)).then<void>((_) {},
          onError: (Object failure, StackTrace stack) {
            // The serialized operation retains the error and pauses.
          }).whenComplete(() { _runtimePending = false; }));
    });
    notifyListeners();
  }

  void pause() {
    _runGeneration++;
    _timer?.cancel();
    _timer = null;
    running = false;
    if (!_closed) notifyListeners();
  }

  Future<void> reset() {
    final generation = ++_operationGeneration;
    pause();
    return _serial(() async {
      await _stopProgressPolling();
      final active = result;
      if (active != null) {
        try { await backend.closeWorldCircuit(active.session); }
        catch (_) { _closing = true; rethrow; }
      }
      result = null;
      progress = null;
      _fragments.clear();
      _indexedGeometry = null;
      _viewport = null;
      dirty = false;
      optimizationEnabled = false;
      optimizationSupported = false;
      wireHeadPixelRulesEnabled = false;
      _clearDisplay();
      if (_closing || generation != _operationGeneration) {
        throw StateError('世界重置已取消，原始文件保留，可重新导入。');
      }
      final opening = _openOriginal();
      _startProgressPolling();
      result = await opening;
      optimizationEnabled = result!.circuitOptimizationEnabled;
      optimizationSupported = result!.circuitOptimizationSupported;
      wireHeadPixelRulesEnabled = result!.wireHeadPixelRulesEnabled;
      error = null;
    }, pollProgress: false);
  }

  Future<void> close() => _closeFuture ??= _close().catchError((Object e) {
    _closeFuture = null;
    error = e;
    if (!_closed) notifyListeners();
    throw e;
  });

  Future<void> _close() async {
    pause();
    _closing = true;
    _operationGeneration++;
    final progressDrained = _stopProgressPolling();
    if (result == null && busy && backend is WorldCircuitSourceBackend) {
      try {
        await (backend as WorldCircuitSourceBackend)
            .cancelWorldCircuitOperation();
      } catch (e) {
        error = e;
      }
    }
    await _queue;
    await progressDrained;
    if (_closed) return;
    final active = result;
    if (active != null) {
      await backend.closeWorldCircuit(active.session);
    } else if (backend is WorldCircuitIdleCleanupBackend) {
      await (backend as WorldCircuitIdleCleanupBackend).cleanupWorldCircuit();
    }
    result = null;
    _fragments.clear();
    _indexedGeometry = null;
    _clearDisplay();
    _closed = true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressTimer?.cancel();
    _progressEpoch++;
    // Caller must await close before dispose; asynchronous engine teardown is
    // deliberately not hidden in a synchronous Widget disposal callback.
    assert(_closed, 'Await WorldCircuitSession.close before dispose');
    super.dispose();
  }
}
