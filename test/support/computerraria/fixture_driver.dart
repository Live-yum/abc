import 'dart:typed_data';

import 'package:terraforge/engine/world_circuit_backend.dart';

import 'layout.dart';
import 'provenance.dart';

typedef FixtureCommandExecutor = Future<WorldCircuitResult> Function(
  WorldCircuitCommand command,
);

/// Test adapter for the public physical computer fixture. The supplied
/// executor owns serialization and lifecycle; this class owns no app state,
/// backend, timer, file picker or UI and is never imported by production.
class ComputerrariaFixtureDriver {
  ComputerrariaFixtureDriver(this.execute);
  final FixtureCommandExecutor execute;
  Future<void> _queue = Future<void>.value();
  int _generation = 0;
  int? _session;
  bool verified = false;
  bool programIncomplete = false;
  String? programName;
  int physicalPulses = 0;
  Uint8List _program = Uint8List(0);
  Uint8List? pixels;
  final _held = <String>{}, _pending = <String>{};
  bool get canRun => verified && !programIncomplete && programName != null;
  Uint8List get programImage => Uint8List.fromList(_program);
  Set<String> get heldKeys => Set.unmodifiable(_held);

  Future<T> _serial<T>(Future<T> Function(int generation) body) {
    final generation = _generation;
    final next = _queue.then((_) => body(generation));
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  void _check(int generation) {
    if (generation != _generation) {
      throw StateError('Fixture operation cancelled');
    }
  }

  Future<WorldCircuitResult> _command(
    int generation,
    WorldCircuitCommand command,
  ) async {
    _check(generation);
    final result = await execute(command);
    _check(generation);
    if (_session != null && result.session != _session) {
      throw StateError('Fixture executor changed world session');
    }
    return result;
  }

  Future<bool> verifyFixture(
    WorldCircuitResult opened, {
    ComputerProvenanceRecord? provenance,
  }) => _serial((generation) async {
    if (programIncomplete) {
      throw StateError('Reimport after partial ROM writes');
    }
    if (_session != null && _session != opened.session) {
      throw StateError('Create a fresh fixture driver for a new session');
    }
    if (verified) {
      return true;
    }
    final original = opened.sourceSha256 == ComputerrariaComputer.sourceSha256;
    final restored = provenance != null && provenance.matches(opened.sourceSha256 ?? '');
    if ((!original && !restored) || opened.width != 15200 || opened.height != 7200) {
      return false;
    }
    _session = opened.session;
    ComputerrariaComputer.isReady(await _command(generation, ComputerrariaComputer.ready()));
    final points = <int>[];
    for (final address in [0, ComputerrariaComputer.romBytes - 4]) {
      final (x, y) = ComputerrariaComputer.romLamp(address, 0);
      points.addAll([x, y, 0, 0]);
    }
    for (final mirror in [0, 1]) {
      final (x, y) = ComputerrariaComputer.ramLamp(0x100000, 31, mirror: mirror);
      points.addAll([x, y, 0, 0]);
    }
    await _lamps(generation, points);
    await _readMonitor(generation);
    if (restored) {
      _program = provenance.programImage;
      programName = provenance.programName;
      physicalPulses = provenance.physicalPulses ?? 0;
    }
    verified = true;
    return true;
  });

  Future<Uint8List> _lamps(int generation, List<int> points) async {
    final result = await _command(generation, WorldCircuitCommand.lamps(points));
    if (result.records.length != points.length * 4) {
      throw const FormatException('Incomplete fixture lamp records');
    }
    final data = ByteData.sublistView(result.records);
    for (var at = 0; at < points.length; at += 4) {
      if (data.getUint32(at * 4, Endian.little) != points[at] ||
          data.getUint32(at * 4 + 4, Endian.little) != points[at + 1] ||
          data.getUint32(at * 4 + 12, Endian.little) != 419) {
        throw const FormatException('Fixture lamp identity mismatch');
      }
    }
    return result.records;
  }

  Future<Uint8List> lampSignature(List<int> points) =>
      _serial((generation) => _lamps(generation, points));

  Future<void> _readMonitor(int generation) async {
    final region = ComputerrariaComputer.mono;
    final result = await _command(generation, WorldCircuitCommand.pixels(region.x, region.y, region.width, region.height));
    pixels = region.decode(result);
  }

  Future<void> readMonitor() => _serial(_readMonitor);

  Future<void> _reset(int generation) async {
    for (var i = 0; i < 3; i++) {
      if (ComputerrariaComputer.isReady(await _command(generation, ComputerrariaComputer.ready()))) {
        break;
      }
      await _command(generation, ComputerrariaComputer.clock());
    }
    if (!ComputerrariaComputer.isReady(await _command(generation, ComputerrariaComputer.ready()))) {
      await _command(generation, ComputerrariaComputer.resetSignal());
    }
    for (final command in ComputerrariaComputer.resetBus) {
      await _command(generation, command);
    }
  }

  Future<void> loadProgram(String name, Uint8List bytes) {
    final image = ComputerrariaComputer.parseProgram(name, bytes);
    return _serial((generation) async {
      if (!verified || programIncomplete) {
        throw StateError('Verify or reimport the fixture first');
      }
      programIncomplete = true;
      await _reset(generation);
      for (final records in ComputerrariaComputer.programWrites(_program, image)) {
        await _command(generation, WorldCircuitCommand.lamps(records, write: true));
      }
      await _reset(generation);
      await _readMonitor(generation);
      _program = image;
      programName = name;
      physicalPulses = 0;
      programIncomplete = false;
    });
  }

  Future<void> step([int pulses = 1]) {
    if (pulses < 1 || pulses > 128) {
      throw RangeError.range(pulses, 1, 128);
    }
    return _serial((generation) async {
      if (!canRun) {
        throw StateError('Load the fixture ROM first');
      }
      final keys = {..._pending, ..._held};
      _pending.clear();
      for (final key in keys) {
        await _command(generation, ComputerrariaComputer.key(key));
      }
      await _command(generation, ComputerrariaComputer.clock(pulses));
      physicalPulses += pulses;
      await _readMonitor(generation);
    });
  }

  void setKey(String direction, bool pressed) {
    ComputerrariaComputer.key(direction);
    if (!pressed) { _held.remove(direction); return; }
    if (!canRun) {
      throw StateError('Load the fixture ROM first');
    }
    if (_held.add(direction)) {
      _pending.add(direction);
    }
  }

  void releaseKeys() { _held.clear(); _pending.clear(); }
  void cancel() { _generation++; releaseKeys(); }

  ComputerProvenanceRecord savedProvenance(String sha256) {
    if (!verified || programIncomplete) {
      throw StateError('Incomplete fixture state');
    }
    return ComputerProvenanceRecord(wldSha256: sha256, programName: programName,
        programImage: _program, physicalPulses: physicalPulses);
  }
}
