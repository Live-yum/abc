import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/engine/circuit_rules_backend.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/engine/native_circuit_rules_runtime.dart';
import 'package:terraforge/engine/native_engine.dart';
import 'package:terraforge/engine/region_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final libraryPath = Platform.environment['TERRAFORGE_ENGINE_LIBRARY'];
  if (libraryPath == null) {
    throw StateError(
      'Set TERRAFORGE_ENGINE_LIBRARY and LIBQUICKJSC_TEST_PATH. Build the authorized private circuit rules bundle before this test.',
    );
  }
  final source = File('assets/private/circuit_rules_native.js')
      .readAsStringSync();

  test('real bundled 15 demos run full rules through native traversal in the owner isolate', () async {
    final summaries = await Isolate.run(() {
      final runtime = NativeCircuitRulesRuntime(
        DynamicLibrary.open(libraryPath),
        source,
      );
      try {
        final capabilities = runtime.invoke('capabilities', []) as Map;
        if (capabilities['sourceCommit'] !=
            '366ebc57751cadfb077f968f4d5069028b3bf9a6') {
          throw StateError('Unpinned private rules');
        }
        final summaries = <Map>[];
        for (final name in capabilities['demos'] as List) {
          final watch = Stopwatch()..start();
          final before = runtime.invoke('editor.demo', [name]) as Map;
          final doc = jsonDecode(before['document'] as String) as Map;
          final wires = ((doc['world'] as Map)['wires'] as List);
          final first = wires.isEmpty ? [0, 0] : wires.first as List;
          final triggered = runtime.invoke('simulation.command', [
            {
              'method': 'trigger',
              'args': [
                [
                  {'x': first[0], 'y': first[1]},
                ],
                15,
              ],
              'debug': true,
            },
          ]) as Map;
          final packet = triggered['packet'] as Map;
          final stepped = runtime.invoke('simulation.command', [
            {
              'method': 'step',
              'args': [60],
              'debug': true,
            },
          ]) as Map;
          final reset = runtime.invoke('simulation.reset', []) as Map;
          if (reset['document'] != before['document']) {
            throw StateError('Reset changed $name');
          }
          final reopened =
              runtime.invoke('editor.open', [triggered['document']]) as Map;
          if (reopened['document'] != triggered['document']) {
            throw StateError('Round trip changed $name');
          }
          summaries.add({
            'name': name,
            'native': packet['native'],
            'hasWires': wires.isNotEmpty,
            'tick': (stepped['packet'] as Map)['tick'],
          });
          runtime.invoke('editor.close', []);
          stdout.writeln(
            'Native rules demo $name passed in ${watch.elapsedMilliseconds} ms',
          );
        }
        return summaries;
      } finally {
        runtime.dispose();
      }
    });
    expect(summaries, hasLength(15));
    for (final summary in summaries) {
      final native = summary['native'] as Map;
      expect(native['available'], isTrue, reason: summary['name'].toString());
      expect(native['fallback'], isFalse, reason: summary['name'].toString());
      if (summary['hasWires'] == true) {
        expect(
          native['commandVisits'],
          greaterThan(0),
          reason: summary['name'].toString(),
        );
      }
      expect(summary['tick'], 60, reason: summary['name'].toString());
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('engine asset initialization retries and dispose recreates without breaking WLD PLR or region APIs', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var failAsset = true;
    rootBundle.clear();
    messenger.setMockMessageHandler('flutter/assets', (
      ByteData? message,
    ) async {
      final name = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      if (name != 'assets/private/circuit_rules_native.js' || failAsset) {
        return null;
      }
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(source)));
    });
    final engine = createTerraEngine();
    final rules = engine as CircuitRulesBackend;
    try {
      await expectLater(
        rules.invokeCircuitRules('capabilities', []),
        throwsA(isA<FlutterError>()),
      );
      failAsset = false;
      expect(
        (await rules.invokeCircuitRules('capabilities', [])
            as Map)['available'],
        true,
      );
      final before =
          await rules.invokeCircuitRules('editor.demo', ['hello']) as Map;
      final player = await (engine as CreatablePlayerEngine).createPlayer(
        '规则回归',
      );
      final playerBytes = await engine.save(player);
      await engine.close(player);
      final reopenedPlayer = await engine.open(playerBytes, kind: 'plr');
      expect((await engine.inspect(reopenedPlayer))['name'], '规则回归');
      await engine.close(reopenedPlayer);
      final worldBytes = File('assets/qa/synthetic-circuit.wld')
          .readAsBytesSync();
      final world = await engine.open(worldBytes, kind: 'wld');
      expect(await engine.save(world), worldBytes);
      await engine.close(world);
      final matched = await (engine as RegionBackend).matchColors(
        Uint32List.fromList([0xfe0000]),
        Uint32List.fromList([0xff0000, 0x0000ff]),
        Uint32List.fromList([0, 0]),
      );
      expect(matched, [0]);
      expect(
        (await rules.invokeCircuitRules('editor.snapshot', [])
            as Map)['document'],
        before['document'],
      );
      final retainedWorld = await engine.open(worldBytes, kind: 'wld');
      await rules.invokeCircuitRules('host.reset', []);
      expect(await engine.save(retainedWorld), worldBytes);
      await engine.close(retainedWorld);
      expect(
        (await rules.invokeCircuitRules('capabilities', [])
            as Map)['available'],
        true,
      );
      await expectLater(
        rules.invokeCircuitRules('editor.snapshot', []),
        throwsA(isA<EngineException>()),
      );
      await rules.invokeCircuitRules('editor.demo', ['timer']);
    } finally {
      await rules.invokeCircuitRules('dispose', []);
      messenger.setMockMessageHandler('flutter/assets', null);
      rootBundle.clear();
    }
  });
}
