import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/computerraria_computer.dart';
import '../domain/computer_provenance.dart';
import 'world_circuit_backend.dart';
import '../diagnostics/host_stage_timings.dart';

/// UI lifecycle for the circuit scheduler and verified physical computer.
/// Device ticks and hardware clock pulses remain distinct engine commands.
class WorldCircuitSession extends ChangeNotifier {
  final WorldCircuitBackend backend;
  final HostStageTimings hostStages;
  final Uint8List? _original;
  final WorldCircuitSource? source;
  WorldCircuitResult? result;
  bool dirty = false;
  bool running = false;
  bool busy = false;
  Object? error;
  Timer? _timer;
  bool _computerPumpActive = false, _computerWakePending = false;
  int _computerRunGeneration = 0;
  Timer? _progressTimer;
  Future<void>? _progressPoll;
  int _progressEpoch = 0;
  WorldCircuitProgress? progress;
  bool computerVerified = false;
  bool programIncomplete = false;
  bool programBaselineKnown = true;
  ComputerProvenanceRecord? _restoredProvenance;
  bool get restoredFromExport => _restoredProvenance != null;
  String? programName;
  Uint8List _program = Uint8List(0);
  Uint8List get programImage => Uint8List.fromList(_program);
  final Map<String, Uint8List> displayFrames = {};
  final Map<String, ComputerDisplayRegion> _displayFrameRegions = {};
  Object displayIdentity = Object();
  final Stopwatch _runWatch = Stopwatch();
  int physicalPulses = 0, displayedFrames = 0, _lastDisplayMicros = 0;
  int _measuredPulses = 0, _measuredFrames = 0;
  int clockBatch = 128;
  bool optimizationEnabled = false;
  bool optimizationSupported = false;
  bool wireHeadPixelRulesEnabled = false;
  int _programGeneration = 0;
  final Set<String> _heldKeys = {}, _pendingKeys = {};
  Set<String> get heldKeys => Set.unmodifiable(_heldKeys);
  double get physicalClockHz => _runWatch.elapsedMicroseconds == 0
      ? 0
      : _measuredPulses * 1000000 / _runWatch.elapsedMicroseconds;
  double get displayPollHz => _runWatch.elapsedMicroseconds == 0
      ? 0
      : _measuredFrames * 1000000 / _runWatch.elapsedMicroseconds;
  bool get canRunComputer =>
      computerVerified &&
      programName != null &&
      !programIncomplete &&
      programBaselineKnown;
  bool get streamed => source != null;
  void markSaved() {
    if (_closed || _closing) return;
    dirty = false;
    notifyListeners();
  }

  bool _closing = false;
  Future<void>? _closeFuture;
  WorldCircuitCommand? _viewport;
  bool _closed = false;
  final Map<int, WorldCircuitFragment> _fragments = {};
  List<int>? _indexedGeometry;
  Future<void> _queue = Future.value();
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
    _programGeneration++;
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
        if (!running) _runWatch.stop();
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

  /// The original content hash and physical anchors jointly gate the fixed
  /// memory map. Merely naming another world "computerraria" never enables it.
  Future<bool> verifyComputer({ComputerProvenanceRecord? provenance}) =>
      _serial(() async {
        if (computerVerified) return true;
        final active = result;
        computerVerified = false;
        final candidate = provenance ?? _restoredProvenance;
        final issuedWorld =
            active != null &&
            candidate != null &&
            candidate.matches(active.sourceSha256 ?? '');
        final originalWorld =
            active != null &&
            active.sourceSha256 == ComputerrariaComputer.sourceSha256;
        if (active == null ||
            (!issuedWorld && !originalWorld) ||
            active.width != 15200 ||
            active.height != 7200) {
          return false;
        }
        final ready = await backend.commandWorldCircuit(
          active.session,
          ComputerrariaComputer.ready(),
        );
        ComputerrariaComputer.isReady(ready);
        final points = <int>[];
        for (final address in [0, ComputerrariaComputer.romBytes - 4]) {
          final (x, y) = ComputerrariaComputer.romLamp(address, 0);
          points.addAll([x, y, 0, 0]);
        }
        for (final mirror in [0, 1]) {
          final (x, y) = ComputerrariaComputer.ramLamp(
            0x100000,
            31,
            mirror: mirror,
          );
          points.addAll([x, y, 0, 0]);
        }
        final lamps = await backend.commandWorldCircuit(
          active.session,
          WorldCircuitCommand.lamps(points),
        );
        final data = ByteData.sublistView(lamps.records);
        if (lamps.records.length != points.length * 4) {
          throw const FormatException('计算机存储器锚点不完整。');
        }
        for (var at = 0; at < points.length; at += 4) {
          if (data.getUint32(at * 4, Endian.little) != points[at] ||
              data.getUint32(at * 4 + 4, Endian.little) != points[at + 1] ||
              data.getUint32(at * 4 + 12, Endian.little) != 419) {
            throw const FormatException('计算机存储器与已核验布局不匹配。');
          }
        }
        await _refreshComputerDisplays(active.session);
        _restoredProvenance = issuedWorld ? candidate : null;
        if (issuedWorld) {
          _program = candidate.programImage;
          programName = candidate.programName;
          physicalPulses = candidate.physicalPulses ?? 0;
        }
        programBaselineKnown = true;
        computerVerified = true;
        return true;
      });

  Future<WorldCircuitResult> _observedCommand(
    int id,
    WorldCircuitCommand command,
    String stage,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final response = await backend.commandWorldCircuit(id, command);
      hostStages.recordBridge(stage, response.hostStagesUs);
      return response;
    } finally {
      hostStages.record(stage, watch.elapsedMicroseconds);
    }
  }

  @override
  void notifyListeners() =>
      hostStages.measure('session.publishListeners', super.notifyListeners);

  WorldCircuitCommand _displayQuery(ComputerDisplayRegion region) =>
      WorldCircuitCommand.pixels(
        region.x,
        region.y,
        region.width,
        region.height,
      );

  String _displayStage(ComputerDisplayRegion region) => 'mono.query';

  void _acceptDisplay(
    ComputerDisplayRegion region,
    WorldCircuitResult response,
  ) {
    final rgba = hostStages.measure(
      'display.rgbaDecode',
      () => region.decode(
        response,
        previous: displayFrames[region.name],
        previousRegion: _displayFrameRegions[region.name],
      ),
    );
    final unchanged = hostStages.measure(
      'display.frameIdentity',
      () => identical(displayFrames[region.name], rgba),
    );
    if (!unchanged) displayFrames[region.name] = rgba;
    _displayFrameRegions[region.name] = region;
  }

  Future<void> _refreshDisplay(int id, ComputerDisplayRegion region) async {
    _acceptDisplay(
      region,
      await _observedCommand(id, _displayQuery(region), _displayStage(region)),
    );
  }

  void _countDisplayRead() {
    displayedFrames++;
    if (_runWatch.isRunning) _measuredFrames++;
  }

  Future<void> _refreshComputerDisplays(int id) async {
    await _refreshDisplay(id, ComputerrariaComputer.mono);
    _countDisplayRead();
  }

  /// Explicit UI pause retains a full, fresh validation snapshot after drain.
  Future<void> pauseAndRefreshDisplays() async {
    pause();
    if (computerVerified && result != null && !_closed && !_closing) {
      await refreshComputerDisplays();
    }
  }

  Future<void> _runtimeComputerBatch() async {
    final id = result!.session, pulses = clockBatch.clamp(32, 128);
    const region = ComputerrariaComputer.mono;
    final computerBackend = backend;
    final watch = Stopwatch()..start();
    try {
      if (computerBackend is WorldCircuitComputerBackend) {
        final frame = await computerBackend.clockAndReadDisplay(
          id,
          ComputerrariaComputer.clock(pulses),
          _displayQuery(region),
        );
        result = frame.clock;
        physicalPulses += pulses;
        _measuredPulses += pulses;
        dirty = true;
        hostStages.recordBridge('runtime.batch', frame.hostStagesUs);
        hostStages.recordBridge('physical.command', frame.clock.hostStagesUs);
        final display = frame.display;
        if (display == null) {
          throw StateError(frame.displayError ?? '计算机显示读取未完成。');
        }
        hostStages.recordBridge(_displayStage(region), display.hostStagesUs);
        _acceptDisplay(region, display);
      } else {
        result = await _observedCommand(
          id,
          ComputerrariaComputer.clock(pulses),
          'physical.command',
        );
        physicalPulses += pulses;
        _measuredPulses += pulses;
        dirty = true;
        await _refreshDisplay(id, region);
      }
      _countDisplayRead();
    } finally {
      hostStages.record('runtime.batch', watch.elapsedMicroseconds);
    }
  }

  Future<void> refreshComputerDisplays() => _serial(() async {
    if (!computerVerified || result == null) throw StateError('计算机布局尚未核验。');
    await _refreshComputerDisplays(result!.session);
  });

  Future<void> setOptimization(bool enabled) {
    pause(releaseKeys: false);
    return _serial(() async {
      final active = result;
      if (active == null) throw StateError('请先载入世界电路。');
      if (enabled && !optimizationSupported) {
        throw StateError('当前世界的像素接线拓扑不支持此模式；同色跨轴网络暂不支持，请保持电路优化关闭。');
      }
      final next = await backend.commandWorldCircuit(
        active.session,
        WorldCircuitCommand.optimization(enabled),
      );
      if (next.circuitOptimizationEnabled != enabled ||
          next.wireHeadPixelRulesEnabled != enabled ||
          (enabled && !next.circuitOptimizationSupported)) {
        throw StateError('引擎未确认电路优化模式，当前会话保持暂停。');
      }
      result = next;
      optimizationEnabled = enabled;
      optimizationSupported = next.circuitOptimizationSupported;
      wireHeadPixelRulesEnabled = next.wireHeadPixelRulesEnabled;
      _runWatch.reset();
      _measuredPulses = 0;
      _measuredFrames = 0;
      _lastDisplayMicros = 0;
      if (computerVerified) await _refreshComputerDisplays(active.session);
      error = null;
    });
  }

  Future<void> _resetComputer(int id) async {
    for (var i = 0; i < 3; i++) {
      final ready = await backend.commandWorldCircuit(
        id,
        ComputerrariaComputer.ready(),
      );
      if (ComputerrariaComputer.isReady(ready)) break;
      await backend.commandWorldCircuit(id, ComputerrariaComputer.clock());
      dirty = true;
    }
    if (!ComputerrariaComputer.isReady(
      await backend.commandWorldCircuit(id, ComputerrariaComputer.ready()),
    )) {
      await backend.commandWorldCircuit(
        id,
        ComputerrariaComputer.resetSignal(),
      );
      dirty = true;
    }
    for (final command in ComputerrariaComputer.resetBus) {
      await backend.commandWorldCircuit(id, command);
      dirty = true;
    }
  }

  Future<void> loadProgram(String name, Uint8List bytes) {
    final image = ComputerrariaComputer.parseProgram(name, bytes);
    pause();
    final generation = ++_programGeneration;
    return _serial(() async {
      if (!computerVerified ||
          result == null ||
          programIncomplete ||
          !programBaselineKnown) {
        throw StateError('请先导入并核验完整计算机；中断加载后需重新导入。');
      }
      final id = result!.session;
      programIncomplete = true;
      await _resetComputer(id);
      var lamps = 0;
      for (final records in ComputerrariaComputer.programWrites(
        _program,
        image,
      )) {
        if (_closing || generation != _programGeneration) {
          throw StateError('程序加载已取消，请重新导入世界。');
        }
        result = await backend.commandWorldCircuit(
          id,
          WorldCircuitCommand.lamps(records, write: true),
        );
        dirty = true;
        lamps += records.length ~/ 4;
        progress = WorldCircuitProgress(
          stage: '写入实际 ROM 灯位',
          phase: 0,
          completed: lamps,
          total: 0,
        );
        notifyListeners();
        await Future<void>.delayed(Duration.zero);
      }
      if (_closing || generation != _programGeneration) {
        throw StateError('程序加载已取消，请重新导入世界。');
      }
      await _resetComputer(id);
      _program = image;
      programName = name;
      programIncomplete = false;
      programBaselineKnown = true;
      dirty = true;
      physicalPulses = 0;
      displayedFrames = 0;
      _measuredPulses = 0;
      _measuredFrames = 0;
      _lastDisplayMicros = 0;
      _runWatch.reset();
      await _refreshComputerDisplays(id);
      progress = null;
    });
  }

  Future<void> stepComputer([int pulses = 1]) {
    if (pulses < 1 || pulses > 128) throw RangeError.range(pulses, 1, 128);
    return _serial(() async {
      if (!canRunComputer || result == null) {
        throw StateError('请先完整加载 RV32I 程序。');
      }
      await _applyComputerKeys(result!.session);
      result = await _observedCommand(
        result!.session,
        ComputerrariaComputer.clock(pulses),
        'physical.command',
      );
      physicalPulses += pulses;
      dirty = true;
      await _refreshComputerDisplays(result!.session);
    });
  }

  void setComputerKey(String direction, bool pressed) {
    ComputerrariaComputer.key(direction); // Validate even a release event.
    if (_closed || _closing) return;
    if (!pressed) {
      if (_heldKeys.remove(direction)) notifyListeners();
      return;
    }
    if (!canRunComputer) throw StateError('请先加载程序再使用已校准的方向键。');
    if (_heldKeys.add(direction)) {
      _pendingKeys.add(direction);
      notifyListeners();
    }
  }

  void releaseComputerKeys() {
    final hadKeys = _heldKeys.isNotEmpty || _pendingKeys.isNotEmpty;
    _heldKeys.clear();
    _pendingKeys.clear();
    if (hadKeys && !_closed) notifyListeners();
  }

  Future<void> _applyComputerKeys(int id) async {
    final keys = {..._pendingKeys, ..._heldKeys};
    _pendingKeys.clear();
    for (final key in keys) {
      await backend.commandWorldCircuit(id, ComputerrariaComputer.key(key));
      dirty = true;
    }
  }

  bool _computerRunCurrent(int generation) =>
      running && !_closing && !_closed && generation == _computerRunGeneration;

  bool get _usesExternalOwnerEvents =>
      backend is WorldCircuitExternalOwnerBackend &&
      (backend as WorldCircuitExternalOwnerBackend)
          .completesComputerBatchFromExternalEvent;

  void _scheduleComputer() {
    if (!running ||
        _closing ||
        _closed ||
        _computerPumpActive ||
        _computerWakePending) {
      return;
    }
    final generation = _computerRunGeneration;
    final ownerEvents = _usesExternalOwnerEvents;
    final scheduled = Stopwatch()..start();
    void launch() {
      _computerWakePending = false;
      _timer = null;
      if (!_computerRunCurrent(generation) || _computerPumpActive) return;
      hostStages.record(
        ownerEvents ? 'runtime.ownerContinuationGap' : 'runtime.timerWait',
        scheduled.elapsedMicroseconds,
      );
      unawaited(_runComputerBatch(generation));
    }

    if (ownerEvents) {
      // Each successful preceding batch awaited a worker message event. The
      // next batch immediately returns control while its owner is computing.
      launch();
    } else {
      // A Future alone does not promise an event-loop turn. Keep an explicit
      // yield for native/unknown owners and immediately completing test fakes.
      _computerWakePending = true;
      _timer = Timer(const Duration(milliseconds: 1), launch);
    }
  }

  Future<void> _runComputerBatch(int generation) async {
    if (!_computerRunCurrent(generation) || _computerPumpActive) return;
    _computerPumpActive = true;
    final loop = Stopwatch()..start();
    var publishFrame = false, acceptedBatch = false;
    try {
      // Await the existing serialized owner once per pending operation instead
      // of spinning or polling a busy owner. Pause invalidates this generation.
      while (busy) {
        await _queue;
        if (!_computerRunCurrent(generation)) return;
      }
      if (!_computerRunCurrent(generation)) return;
      await _serial(() async {
        if (!_computerRunCurrent(generation) || result == null) return;
        acceptedBatch = true;
        await _applyComputerKeys(result!.session);
        await _runtimeComputerBatch();
        final now = _runWatch.elapsedMicroseconds;
        if (!running || now - _lastDisplayMicros >= 16667) {
          _lastDisplayMicros = _runWatch.elapsedMicroseconds;
          publishFrame = true;
        }
      }, notifyState: false);
      if (publishFrame && !_closed && !_closing) notifyListeners();
    } catch (_) {
      pause();
    } finally {
      if (acceptedBatch) {
        hostStages.record('runtime.loop', loop.elapsedMicroseconds);
      }
      _computerPumpActive = false;
      // A pause/restart may have created a newer generation while the accepted
      // old batch drained. Only this single pump may start its replacement.
      if (running && !_closed && !_closing) _scheduleComputer();
    }
  }

  Future<WorldCircuitResult> command(
    WorldCircuitCommand command, {
    bool refreshViewport = false,
  }) => _serial(() async {
    final active = result;
    if (active == null) throw StateError('Open the circuit first');
    if (command.words[1] == 6 && computerVerified) {
      await _refreshComputerDisplays(active.session);
    }
    final next = await backend.commandWorldCircuit(active.session, command);
    // Fragment queries return eight-word records, unlike the viewport. Keep
    // those out of the live four-word display and retain its current state.
    if (command.words[1] != 4 &&
        command.words[1] != 7 &&
        command.words[1] != 8 &&
        command.words[1] != 9) {
      result = next;
    }
    if (command.mutates) {
      dirty = true;
      if (computerVerified) programBaselineKnown = false;
    }
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
    return command.words[1] == 4 ||
            command.words[1] == 7 ||
            command.words[1] == 8 ||
            command.words[1] == 9
        ? next
        : result!;
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
    if (_closed || _closing || running || result == null) return;
    if (computerVerified) {
      if (!canRunComputer) throw StateError('请先完整加载 RV32I 程序。');
      hostStages.reset();
      _computerRunGeneration++;
      running = true;
      _runWatch.start();
      _scheduleComputer();
      notifyListeners();
      return;
    }
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

  void pause({bool releaseKeys = true}) {
    _computerRunGeneration++;
    _computerWakePending = false;
    _timer?.cancel();
    _timer = null;
    running = false;
    if (releaseKeys) releaseComputerKeys();
    if (!busy) _runWatch.stop();
    if (!_closed) notifyListeners();
  }

  Future<void> reset() {
    final generation = ++_programGeneration;
    pause();
    return _serial(() async {
      await _stopProgressPolling();
      final active = result;
      if (active != null) {
        try {
          await backend.closeWorldCircuit(active.session);
        } catch (_) {
          // A partly closed owner cannot accept commands. close() can retry.
          _closing = true;
          rethrow;
        }
      }
      result = null;
      progress = null;
      _fragments.clear();
      _indexedGeometry = null;
      dirty = false;
      computerVerified = false;
      optimizationEnabled = false;
      optimizationSupported = false;
      wireHeadPixelRulesEnabled = false;
      programIncomplete = false;
      programBaselineKnown = true;
      programName = null;
      _program = Uint8List(0);
      displayFrames.clear();
      _displayFrameRegions.clear();
      displayIdentity = Object();
      physicalPulses = 0;
      displayedFrames = 0;
      _measuredPulses = 0;
      _measuredFrames = 0;
      _lastDisplayMicros = 0;
      _runWatch.reset();
      // Cancellation may arrive while an accepted batch, progress control, or
      // close ACK is draining. Finish releasing that owner, but do not start a
      // replacement import or keep publishing the closed world's ready state.
      if (_closing || generation != _programGeneration) {
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

  /// Flush pending commands and stop before closing a world handle or adopting
  /// returned WLD bytes in the application's ordinary save pipeline.
  Future<void> close() => _closeFuture ??= _close().catchError((Object e) {
    _closeFuture = null;
    error = e;
    if (!_closed) notifyListeners();
    throw e;
  });

  Future<void> _close() async {
    pause();
    _closing = true;
    _programGeneration++;
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
    displayFrames.clear();
    _displayFrameRegions.clear();
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
