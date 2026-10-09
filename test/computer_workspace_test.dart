import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';

import 'support/computer_circuit_backend.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;
import 'vault_history_test.dart' show MemoryVault;

class _Sources implements WorldCircuitFileGateway {
  Completer<WorldCircuitSource?>? pending;
  final saves = <String>[];
  List<Object> saveResults = [];
  bool derived = false;
  @override
  Future<WorldCircuitSource?> pick({required bool companion}) async =>
      pending == null
      ? WorldCircuitSource.file(
          path: derived
              ? companion
                    ? '/output/copy.twld'
                    : '/output/copy.wld'
              : companion
              ? '/fixture/p.twld'
              : '/fixture/p.wld',
          length: companion ? 427712 : 405983441,
          name: companion ? 'p.twld' : 'p.wld',
        )
      : pending!.future;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    saves.add(name);
    final result = saveResults.isEmpty ? true : saveResults.removeAt(0);
    if (result is bool) return result;
    throw result;
  }
}

void main() {
  test('fully saved pair persists across Workspace recreation and resumes without CPU reset', () async {
    final backend = ComputerCircuitBackend(),
        vault = MemoryVault(),
        sources = _Sources();
    final files = FakeFiles()
      ..next = PickedFile(
        'long.bin',
        Uint8List.fromList([1, 0, 0, 0, 1, 0, 0, 0]),
      );
    var workspace = Workspace(
      engine: FakeEngine(),
      files: files,
      vault: vault,
      worldCircuitBackend: backend,
      worldCircuitFiles: sources,
    );
    await workspace.dispatch('worldCircuitChooseWorld');
    await workspace.dispatch('worldCircuitChooseTwld');
    await workspace.dispatch('worldCircuitImport');
    await workspace.dispatch('worldCircuitLoadProgram');
    await workspace.dispatch('worldCircuitStep', {'pulses': 128});
    await workspace.dispatch('worldCircuitSave');
    expect(workspace.view.error, isEmpty);
    expect((workspace.view.result['worldCircuit'] as Map)['dirty'], isFalse);
    expect(vault.records.length, 1);
    await workspace.close();
    workspace.dispose();
    sources.derived = true;
    backend.commands.clear();
    workspace = Workspace(
      engine: FakeEngine(),
      files: files,
      vault: vault,
      worldCircuitBackend: backend,
      worldCircuitFiles: sources,
    );
    await workspace.dispatch('worldCircuitChooseWorld');
    await workspace.dispatch('worldCircuitChooseTwld');
    await workspace.dispatch('worldCircuitImport');
    final state = workspace.view.result['worldCircuit'] as Map;
    expect(state['restoredFromExport'], isTrue);
    expect(state['programName'], 'long.bin');
    expect(state['physicalPulses'], 128);
    expect(state['canRunComputer'], isTrue);
    expect(backend.commands.where((c) => c.mutates), isEmpty);
    await workspace.dispatch('worldCircuitStep');
    expect(
      (workspace.view.result['worldCircuit'] as Map)['physicalPulses'],
      129,
    );
    await workspace.close();
    workspace.dispose();
  });

  test(
    'workspace close cancels pending import and shares one teardown',
    () async {
      final backend = ComputerCircuitBackend()..holdOpen = Completer<void>();
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: _Sources(),
      );
      await workspace.dispatch('worldCircuitChooseWorld');
      final opening = workspace.dispatch('worldCircuitImport');
      while (backend.opens == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final closing = workspace.close();
      while (backend.cancels == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      backend.holdOpen!.complete();
      await Future.wait([opening, closing]);
      expect(backend.closes, 1);
      expect(backend.commands, isEmpty);
      expect((workspace.view.result['worldCircuit'] as Map)['open'], isFalse);
      workspace.dispose();
    },
  );

  for (final scenario in ['cancel-wld', 'cancel-twld', 'fail-twld']) {
    test(
      'paired source export retains dirty session and releases both outputs: $scenario',
      () async {
        final backend = ComputerCircuitBackend();
        final vault = MemoryVault();
        final sources = _Sources()
          ..saveResults = scenario == 'cancel-wld'
              ? [false]
              : scenario == 'cancel-twld'
              ? [true, false]
              : [true, StateError('disk full')];
        final files = FakeFiles()
          ..next = PickedFile('p.bin', Uint8List.fromList([1, 0, 0, 0]));
        final workspace = Workspace(
          engine: FakeEngine(),
          files: files,
          vault: vault,
          worldCircuitBackend: backend,
          worldCircuitFiles: sources,
        );
        await workspace.dispatch('worldCircuitChooseWorld');
        await workspace.dispatch('worldCircuitChooseTwld');
        await workspace.dispatch('worldCircuitImport');
        await workspace.dispatch('worldCircuitLoadProgram');
        await workspace.dispatch('worldCircuitSave');
        final state = workspace.view.result['worldCircuit'] as Map;
        expect(state['open'], isTrue);
        expect(state['dirty'], isTrue);
        expect(state['programName'], 'p.bin');
        expect(backend.released.toSet(), {'wld', 'twld'});
        expect(vault.records, isEmpty);
        expect(backend.closes, 0);
        expect(sources.saves.length, scenario == 'cancel-wld' ? 1 : 2);
        if (scenario == 'cancel-wld') {
          expect(workspace.view.status, contains('已取消 WLD'));
        } else {
          expect(workspace.view.status, contains('WLD 已导出'));
          expect(workspace.view.status, isNot(contains('已导出模拟世界及匹配')));
        }
        if (scenario == 'fail-twld') {
          expect(workspace.view.error, contains('TWLD 导出失败'));
        }
        await workspace.close();
        workspace.dispose();
      },
    );
  }

  test(
    'cancelled opening cannot adopt a late result; same source can reopen',
    () async {
      final backend = ComputerCircuitBackend()..holdOpen = Completer<void>();
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: _Sources(),
      );
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitChooseTwld');
      final opening = workspace.dispatch('worldCircuitImport');
      while (backend.opens == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await workspace.dispatch('worldCircuitCancel');
      backend.holdOpen!.complete();
      await opening;
      expect((workspace.view.result['worldCircuit'] as Map)['open'], isFalse);
      expect(backend.closes, 1);
      expect(backend.commands, isEmpty);
      backend.holdOpen = null;
      await workspace.dispatch('worldCircuitImport');
      expect(
        (workspace.view.result['worldCircuit'] as Map)['computerVerified'],
        isTrue,
      );
      await workspace.close();
      workspace.dispose();
      expect(backend.closes, 2);
    },
  );

  test('new WLD clears prior pairing; reset clears program and keeps empty viewport safe', () async {
    final backend = ComputerCircuitBackend(),
        sources = _Sources(),
        files = FakeFiles();
    final workspace = Workspace(
      engine: FakeEngine(),
      files: files,
      worldCircuitBackend: backend,
      worldCircuitFiles: sources,
    );
    Map state() => workspace.view.result['worldCircuit'] as Map;
    await workspace.dispatch('worldCircuitChooseWorld');
    await workspace.dispatch('worldCircuitChooseTwld');
    expect(state()['companionName'], 'p.twld');
    await workspace.dispatch('worldCircuitChooseWorld');
    expect(state()['companionName'], isNull);
    await workspace.dispatch('worldCircuitChooseTwld');
    await workspace.dispatch('worldCircuitImport');
    files.next = PickedFile('p.bin', Uint8List.fromList([1, 0, 0, 0]));
    await workspace.dispatch('worldCircuitLoadProgram');
    expect(state()['canRunComputer'], isTrue);
    await workspace.dispatch('worldCircuitReset');
    expect(workspace.view.error, isEmpty);
    expect(state()['canRunComputer'], isFalse);
    expect(state()['programName'], isNull);
    expect(state()['keyboardVerified'], isTrue);
    await workspace.close();
    workspace.dispose();
  });
}
