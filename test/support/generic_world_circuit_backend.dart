import 'dart:async';
import 'dart:typed_data';

import 'package:terraforge/engine/world_circuit_backend.dart';

/// Ordinary small wiring-world fake. No CPU geometry, program or signature.
class GenericWorldCircuitBackend implements WorldCircuitSourceBackend {
  static const savedWldSha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  String digest =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  int opens = 0, closes = 0, cancels = 0;
  Completer<void>? holdOpen;
  final commands = <WorldCircuitCommand>[];
  final released = <String?>[];
  final stats = List<int>.filled(24, 0)
    ..[0] = 2
    ..[2] = 40
    ..[3] = 32
    ..[4] = 20
    ..[5] = 16
    ..[6] = 5
    ..[7] = 5
    ..[8] = 8
    ..[9] = 5
    ..[10] = 4
    ..[11] = 2
    ..[13] = 1;

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List bytes) =>
      throw StateError('Use source descriptors');
  @override
  Future<WorldCircuitResult> openWorldCircuitSource(
    WorldCircuitSource source, {
    void Function(WorldCircuitProgress)? onProgress,
  }) async {
    opens++;
    onProgress?.call(
      const WorldCircuitProgress(
        stage: 'compile',
        phase: 1,
        completed: 1,
        total: 2,
      ),
    );
    await holdOpen?.future;
    final saved = source.path?.startsWith('/output/') == true;
    stats[18] = 0;
    return WorldCircuitResult(
      opens,
      List.of(stats),
      Uint8List(0),
      sourceSha256: saved ? savedWldSha : digest,
    );
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    commands.add(command);
    final kind = command.words[1];
    if (kind == 3) {
      stats[18] += command.words[8];
    }
    if (kind == 2) {
      stats[20]++;
    }
    return WorldCircuitResult(
      session,
      List.of(stats),
      Uint8List(0),
      resultKind: kind,
      worldSource: kind == 6
          ? const WorldCircuitSource.file(
              path: '/output/copy.wld',
              length: 1365,
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
