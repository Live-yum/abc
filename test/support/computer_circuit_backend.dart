import 'dart:async';
import 'dart:typed_data';

import 'package:terraforge/domain/computerraria_computer.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';

/// Contract-only fake. It reports tile states; it does not execute a CPU.
class ComputerCircuitBackend implements WorldCircuitSourceBackend {
  static const savedWldSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  static const savedTwldSha =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  String digest = ComputerrariaComputer.sourceSha256;
  String twldDigest =
      'c6de694b3d034701513dc1ba17311213561ec359d3ecddde7bc35ea3c9611ed8';
  bool profile = true;
  bool optimized = false;
  int opens = 0, closes = 0, cancels = 0;
  Completer<void>? holdOpen, holdClock, holdWrite;
  final commands = <WorldCircuitCommand>[];
  final released = <String?>[];
  final stats = List<int>.filled(24, 0)
    ..[2] = 15200
    ..[3] = 7200;

  @override
  Future<WorldCircuitResult> openWorldCircuit(
    Uint8List bytes, {
    Uint8List? twld,
  }) => throw StateError('Large inputs must use source descriptors');

  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource world, {
    WorldCircuitSource? twld,
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
      reserved: profile ? 1 : 0,
      sourceSha256: world.path?.startsWith('/output/') == true
          ? savedWldSha
          : digest,
      twldSourceSha256: twld?.path?.startsWith('/output/') == true
          ? savedTwldSha
          : twldDigest,
    );
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    final kind = command.words[1];
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
          data.setUint32(at + 8, x == 7371 ? 65534 : 445, Endian.little);
        }
      }
    }
    return WorldCircuitResult(
      session,
      stats,
      records,
      resultKind: kind,
      reserved: (profile ? 1 : 0) | (optimized ? 2 : 0),
      worldSource: kind == 6
          ? const WorldCircuitSource.file(
              path: '/output/copy.wld',
              length: 100,
              name: 'copy.wld',
              token: 'wld',
              sha256: savedWldSha,
            )
          : null,
      twldSource: kind == 6
          ? const WorldCircuitSource.file(
              path: '/output/copy.twld',
              length: 100,
              name: 'copy.twld',
              token: 'twld',
              sha256: savedTwldSha,
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
