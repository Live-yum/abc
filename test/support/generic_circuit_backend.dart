import 'dart:async';
import 'dart:typed_data';

import 'package:terraforge/engine/world_circuit_backend.dart';

/// Contract-only fake for an ordinary WLD and explicitly selected regions.
/// Tests drive its state; it does not substitute for a real wiring simulator.
class GenericCircuitBackend implements WorldCircuitSourceBackend {
  int opens = 0, closes = 0, cancels = 0;
  int ticks = 0, netPulses = 0, completedTickBatches = 0;
  bool optimized = false, pixelOn = false, failNextViewport = false;
  Completer<void>? holdOpen, holdTicks, activeTicks;
  final commands = <WorldCircuitCommand>[];
  final released = <String?>[];

  List<int> get stats => List<int>.filled(24, 0)
    ..[2] = 600
    ..[3] = 400
    ..[4] = 300
    ..[5] = 100
    ..[6] = 40
    ..[7] = 50
    ..[8] = 43
    ..[9] = 52
    ..[10] = 4
    ..[11] = 3
    ..[13] = 1
    ..[18] = ticks
    ..[20] = netPulses;

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List world) async =>
      _open();

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    onProgress?.call(const WorldCircuitProgress(
      stage: 'compile', phase: 1, completed: 1, total: 2,
    ));
    await holdOpen?.future;
    return _open();
  }

  WorldCircuitResult _open() {
    opens++;
    ticks = 0;
    netPulses = 0;
    pixelOn = false;
    optimized = false;
    return WorldCircuitResult(opens, stats, Uint8List(0), reserved: 4);
  }

  List<(int, int, int, int, int)> get cells => [
    (40, 50, 135, 1, 0),
    (41, 50, 0, 0, 0),
    (42, 50, 144, 1, 0),
    (43, 52, 445, 1, pixelOn ? 18 : 0),
  ];

  Uint8List _records(WorldCircuitCommand command) {
    final x = command.words[2], y = command.words[3];
    final width = command.words[4], height = command.words[5];
    final pixelsOnly = command.words[1] == 9;
    final selected = cells.where((cell) =>
        cell.$1 >= x && cell.$1 < x + width &&
        cell.$2 >= y && cell.$2 < y + height &&
        (!pixelsOnly || cell.$3 == 445)).toList();
    final bytes = Uint8List(selected.length * 16);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < selected.length; i++) {
      final cell = selected[i], at = i * 16;
      data.setUint32(at, cell.$1, Endian.little);
      data.setUint32(at + 4, cell.$2, Endian.little);
      data.setUint32(at + 8,
          cell.$3 | (cell.$4 << 16) | (1 << 24), Endian.little);
      data.setInt16(at + 12, cell.$5, Endian.little);
    }
    return bytes;
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    final kind = command.words[1];
    if (kind == 1 && failNextViewport) {
      failNextViewport = false;
      throw StateError('viewport read rejected');
    }
    if (kind == 3) {
      final gate = holdTicks;
      activeTicks = gate;
      await gate?.future;
      ticks += command.words[8];
      completedTickBatches++;
      activeTicks = null;
      pixelOn = !pixelOn;
    }
    if (kind == 2) {
      netPulses++;
      pixelOn = !pixelOn;
    }
    if (kind == 10) optimized = command.words[7] == 1;
    return WorldCircuitResult(
      session,
      stats,
      kind == 1 || kind == 9 ? _records(command) : Uint8List(0),
      resultKind: kind,
      reserved: kind == 6 ? 0 : 4 | (optimized ? 10 : 0),
      worldSource: kind == 6
          ? const WorldCircuitSource.file(
              path: '/output/generic-copy.wld',
              length: 100,
              name: 'generic-copy.wld',
              token: 'generic-output',
            )
          : null,
    );
  }

  @override
  Future<void> closeWorldCircuit(int session) async {
    closes++;
  }

  @override
  Future<void> cancelWorldCircuitOperation() async {
    cancels++;
  }

  @override
  Future<WorldCircuitProgress?> worldCircuitProgress() async => null;

  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {
    released.add(source.token);
  }
}
