import 'dart:async';
import 'dart:typed_data';

import 'computerraria/layout.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

/// Contract-only fake. It reports tile states; it does not execute a CPU.
class ComputerCircuitBackend implements WorldCircuitSourceBackend {
  static const savedWldSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  String digest = ComputerrariaComputer.sourceSha256;
  bool optimized = false;
  bool optimizationSupported = true;
  bool rejectOptimization = false;
  int opens = 0, closes = 0, cancels = 0;
  Completer<void>? holdOpen, holdClock, holdWrite;
  final commands = <WorldCircuitCommand>[];
  final released = <String?>[];
  final stats = List<int>.filled(24, 0)
    ..[2] = 15200
    ..[3] = 7200;

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List bytes) =>
      throw StateError('Large inputs must use source descriptors');

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    opens++;
    optimized = false;
    onProgress?.call(
      const WorldCircuitProgress(
        stage: 'compile',
        phase: 1,
        completed: 1,
        total: 2,
      ),
    );
    await holdOpen?.future;
    return WorldCircuitResult(
      opens,
      stats,
      Uint8List(0),
      reserved: optimizationSupported ? 4 : 0,
      sourceSha256: world.path?.startsWith('/output/') == true
          ? savedWldSha
          : digest,
    );
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    final kind = command.words[1];
    if (kind == 10 &&
        command.words[7] == 1 &&
        (!optimizationSupported || rejectOptimization)) {
      throw const EngineException('Unsupported pixel topology', -7);
    }
    if (kind == 10) optimized = command.words[7] == 1;
    if (kind == 2 && command.words[2] == 3194) await holdClock?.future;
    if (kind == 5) await holdWrite?.future;
    Uint8List records = Uint8List(0);
    if (kind == 4) {
      records = Uint8List(command.records.length * 4);
      final data = ByteData.sublistView(records);
      for (var i = 0; i < command.records.length; i += 4) {
        data.setUint32(i * 4, command.records[i], Endian.little);
        data.setUint32(i * 4 + 4, command.records[i + 1], Endian.little);
        data.setUint32(
          i * 4 + 8,
          command.records[i] == 3199 ? 1 : 0,
          Endian.little,
        );
        data.setUint32(i * 4 + 12, 419, Endian.little);
      }
    }
    if (kind == 9) {
      final x = command.words[2],
          y = command.words[3],
          w = command.words[4],
          h = command.words[5];
      records = Uint8List(w * h * 16);
      final data = ByteData.sublistView(records);
      for (var dx = 0; dx < w; dx++) {
        for (var dy = 0; dy < h; dy++) {
          final at = (dx * h + dy) * 16;
          data.setUint32(at, x + dx, Endian.little);
          data.setUint32(at + 4, y + dy, Endian.little);
          data.setUint32(at + 8, 445, Endian.little);
        }
      }
    }
    return WorldCircuitResult(
      session,
      stats,
      records,
      resultKind: kind,
      reserved: kind == 6
          ? 0
          : (optimizationSupported ? 4 : 0) | (optimized ? 10 : 0),
      worldSource: kind == 6
          ? const WorldCircuitSource.file(
              path: '/output/copy.wld',
              length: 100,
              name: 'copy.wld',
              token: 'wld',
              sha256: savedWldSha,
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
