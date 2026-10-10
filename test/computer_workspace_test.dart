import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/world_circuit_backend.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/platform/world_circuit_files.dart';

import 'support/generic_world_circuit_backend.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;
import 'vault_history_test.dart' show MemoryVault;

class _Sources implements WorldCircuitFileGateway {
  Completer<WorldCircuitSource?>? pending;
  Completer<bool>? pendingSave;
  final saves = <String>[];
  final protected = <List<WorldCircuitSource>>[];
  List<Object> saveResults = [];
  bool derived = false;
  String? inputToken;
  @override
  Future<WorldCircuitSource?> pick() async => pending == null
      ? WorldCircuitSource.file(
          path: derived ? '/output/copy.wld' : '/fixture/p.wld',
          length: 1365,
          name: 'p.wld',
          token: inputToken,
        )
      : pending!.future;
  @override
  Future<bool> save(
    WorldCircuitSource source, {
    required String name,
    List<WorldCircuitSource> protectedSources = const [],
  }) async {
    saves.add(name);
    protected.add(List.of(protectedSources));
    if (pendingSave != null) return pendingSave!.future;
    final result = saveResults.isEmpty ? true : saveResults.removeAt(0);
    if (result is bool) return result;
    throw result;
  }
}

class _LeaseBackend extends GenericWorldCircuitBackend {
  int releaseFailures = 0;
  bool byteMode = false;
  Completer<void>? holdClose;
  final releaseAttempts = <WorldCircuitSource>[];
  final events = <String>[];

  @override
  Future<WorldCircuitResult> openWorldCircuit(Uint8List bytes) async {
    if (!byteMode) return super.openWorldCircuit(bytes);
    return WorldCircuitResult(++opens, stats, Uint8List(0));
  }

  @override
  Future<WorldCircuitResult> commandWorldCircuit(
    int session,
    WorldCircuitCommand command,
  ) async {
    if (command.words[1] == 6) events.add('save');
    if (byteMode && command.words[1] == 6) {
      return WorldCircuitResult(
        session,
        stats,
        Uint8List(0),
        world: Uint8List.fromList([7, 9]),
        resultKind: 6,
        resultCount: 2,
      );
    }
    return super.commandWorldCircuit(session, command);
  }

  @override
  Future<void> releaseWorldCircuitSource(WorldCircuitSource source) async {
    releaseAttempts.add(source);
    events.add('release');
    if (releaseFailures > 0) {
      releaseFailures--;
      throw StateError('OPFS remove failed');
    }
    await super.releaseWorldCircuitSource(source);
  }

  @override
  Future<void> closeWorldCircuit(int session) async {
    events.add('close');
    await holdClose?.future;
    await super.closeWorldCircuit(session);
  }
}

void main() {
  test('fully saved generic WLD persists across Workspace recreation and reopens ordinary ticks without a reset', () async {
    final backend = GenericWorldCircuitBackend(),
        vault = MemoryVault(),
        sources = _Sources();
    final files = FakeFiles();
    var workspace = Workspace(
      engine: FakeEngine(),
      files: files,
      vault: vault,
      worldCircuitBackend: backend,
      worldCircuitFiles: sources,
    );
    await workspace.dispatch('worldCircuitChooseWorld');
    await workspace.dispatch('worldCircuitImport');
    await workspace.dispatch('worldCircuitStep', {});
    await workspace.dispatch('worldCircuitSave');
    expect(workspace.view.error, isEmpty);
    expect((workspace.view.result['worldCircuit'] as Map)['dirty'], isFalse);
    expect(sources.saves, ['p_circuit.wld']);
    expect(backend.released, ['wld']);
    expect(vault.records, isEmpty);
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
    await workspace.dispatch('worldCircuitImport');
    final state = workspace.view.result['worldCircuit'] as Map;
    expect(state['open'], isTrue);
    expect(state.containsKey('programName'), isFalse);
    expect(state['ticks'], 1);
    expect(backend.commands.where((c) => c.mutates), isEmpty);
    await workspace.dispatch('worldCircuitStep');
    expect(
      (workspace.view.result['worldCircuit'] as Map)['ticks'],
      2,
    );
    await workspace.close();
    workspace.dispose();
  });

  test(
    'workspace close cancels pending import and shares one teardown',
    () async {
      final backend = GenericWorldCircuitBackend()..holdOpen = Completer<void>();
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

  for (final scenario in ['cancel-wld', 'fail-wld']) {
    test(
      'WLD export retains dirty session and releases output: $scenario',
      () async {
        final backend = GenericWorldCircuitBackend();
        final vault = MemoryVault();
        final sources = _Sources()
          ..saveResults = scenario == 'cancel-wld'
              ? [false]
              : [StateError('disk full')];
        final files = FakeFiles();
        final workspace = Workspace(
          engine: FakeEngine(),
          files: files,
          vault: vault,
          worldCircuitBackend: backend,
          worldCircuitFiles: sources,
        );
        await workspace.dispatch('worldCircuitChooseWorld');
        await workspace.dispatch('worldCircuitImport');
        await workspace.dispatch('worldCircuitStep');
        await workspace.dispatch('worldCircuitSave');
        final state = workspace.view.result['worldCircuit'] as Map;
        expect(state['open'], isTrue);
        expect(state['dirty'], isTrue);
        expect(state['ticks'], 1);
        expect(backend.released.toSet(), {'wld'});
        expect(vault.records, isEmpty);
        expect(backend.closes, 0);
        expect(sources.saves.length, 1);
        if (scenario == 'cancel-wld') {
          expect(workspace.view.status, contains('已取消 WLD'));
        } else {
          expect(workspace.view.error, contains('disk full'));
        }
        await workspace.close();
        workspace.dispose();
      },
    );
  }

  for (final action in ['worldCircuitClose', 'worldCircuitReset']) {
    test(
      '$action retries retained output before changing the session',
      () async {
        final backend = _LeaseBackend()..releaseFailures = 2;
        final sources = _Sources()
          ..saveResults = [false]
          ..inputToken = 'original-picker-token';
        final workspace = Workspace(
          engine: FakeEngine(),
          files: FakeFiles(),
          worldCircuitBackend: backend,
          worldCircuitFiles: sources,
        );
        await workspace.dispatch('worldCircuitChooseWorld');
        await workspace.dispatch('worldCircuitImport');
        await workspace.dispatch('worldCircuitSave');
        expect(workspace.view.error, contains('OPFS remove failed'));
        expect(workspace.view.status, contains('已保留'));
        expect(backend.releaseAttempts.length, 1);
        expect(backend.released, isEmpty);
        // A new result must not erase the only descriptor for failed cleanup.
        await workspace.dispatch('worldCircuitViewport', {
          'x': 0,
          'y': 0,
          'width': 1,
          'height': 1,
        });
        expect(workspace.view.error, isEmpty);
        await workspace.dispatch(action, {'discard': true});
        expect(workspace.view.error, contains('OPFS remove failed'));
        expect(backend.closes, 0);
        expect(backend.opens, 1);
        expect((workspace.view.result['worldCircuit'] as Map)['open'], isTrue);

        await workspace.dispatch(action, {'discard': true});
        expect(workspace.view.error, isEmpty);
        expect(backend.releaseAttempts.length, 3);
        expect(backend.released, ['wld']);
        expect(backend.closes, 1);
        expect(backend.opens, action == 'worldCircuitReset' ? 2 : 1);
        expect(workspace.view.status, isNot(contains('临时导出文件清理失败')));
        expect(backend.events.take(5), [
          'save',
          'release',
          'release',
          'release',
          'close',
        ]);
        expect(
          backend.releaseAttempts.every((source) => source.token == 'wld'),
          isTrue,
        );
        expect(sources.protected.single.single.token, 'original-picker-token');
        await workspace.close();
        expect(
          backend.releaseAttempts.length,
          3,
          reason: 'Release ACK removes the retry entry.',
        );
        workspace.dispose();
      },
    );
  }

  test(
    'next export retries its old output before creating a new one',
    () async {
      final backend = _LeaseBackend()..releaseFailures = 2;
      final sources = _Sources()..saveResults = [false, false];
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: sources,
      );
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      await workspace.dispatch('worldCircuitSave');
      await workspace.dispatch('worldCircuitSave');
      expect(workspace.view.error, contains('OPFS remove failed'));
      expect(sources.saves.length, 1);
      expect(backend.events, ['save', 'release', 'release']);

      await workspace.dispatch('worldCircuitSave');
      expect(workspace.view.error, isEmpty);
      expect(sources.saves.length, 2);
      expect(backend.events, [
        'save',
        'release',
        'release',
        'release',
        'save',
        'release',
      ]);
      expect(backend.released, ['wld', 'wld']);
      await workspace.close();
      expect(backend.releaseAttempts.length, 4);
      workspace.dispose();
    },
  );

  test(
    'cleanup failure preserves the original export error and retry owner',
    () async {
      final backend = _LeaseBackend()..releaseFailures = 1;
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: _Sources()..saveResults = [StateError('disk full')],
      );
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      await workspace.dispatch('worldCircuitSave');
      expect(workspace.view.error, 'Bad state: disk full');
      expect(workspace.view.status, contains('临时导出文件清理失败'));
      expect(backend.releaseAttempts.length, 1);
      await workspace.close();
      expect(backend.releaseAttempts.length, 2);
      expect(backend.released, ['wld']);
      workspace.dispose();
    },
  );

  for (final failRelease in [false, true]) {
    test(
      'close waits for the output consumer before release (retry: $failRelease)',
      () async {
        final backend = _LeaseBackend()..releaseFailures = failRelease ? 1 : 0;
        final sources = _Sources()..pendingSave = Completer<bool>();
        final workspace = Workspace(
          engine: FakeEngine(),
          files: FakeFiles(),
          worldCircuitBackend: backend,
          worldCircuitFiles: sources,
        );
        await workspace.dispatch('worldCircuitChooseWorld');
        await workspace.dispatch('worldCircuitImport');
        final saving = workspace.dispatch('worldCircuitSave');
        while (sources.saves.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        var closed = false;
        final closing = workspace.close().then((_) => closed = true);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        expect(backend.releaseAttempts, isEmpty);
        expect(backend.closes, 0);

        sources.pendingSave!.complete(false);
        await Future.wait([saving, closing]);
        expect(backend.releaseAttempts.length, failRelease ? 2 : 1);
        expect(backend.released, ['wld']);
        expect(backend.events.last, 'close');
        expect(backend.closes, 1);
        expect((workspace.view.result['worldCircuit'] as Map)['open'], isFalse);
        workspace.dispose();
      },
    );
  }

  test(
    'byte save can close its own session without waiting on itself',
    () async {
      final backend = _LeaseBackend()..byteMode = true;
      final files = FakeFiles()
        ..next = PickedFile('small.wld', Uint8List.fromList([1, 2]));
      final workspace = Workspace(
        engine: FakeEngine(),
        files: files,
        worldCircuitBackend: backend,
      );
      await workspace.dispatch('import', {'kind': 'world'});
      await workspace.dispatch('worldCircuitOpen');
      expect(workspace.view.error, isEmpty);
      await workspace
          .dispatch('worldCircuitSave')
          .timeout(const Duration(seconds: 2));
      expect(workspace.view.error, isEmpty);
      expect(files.bytes, [7, 9]);
      expect(backend.closes, 1);
      expect(backend.releaseAttempts, isEmpty);
      await workspace.close();
      workspace.dispose();
    },
  );

  test(
    'cancel during reset close keeps the picker source available for import',
    () async {
      final backend = _LeaseBackend();
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        worldCircuitBackend: backend,
        worldCircuitFiles: _Sources(),
      );
      await workspace.dispatch('worldCircuitChooseWorld');
      await workspace.dispatch('worldCircuitImport');
      backend.holdClose = Completer<void>();
      final resetting = workspace.dispatch('worldCircuitReset');
      while (!backend.events.contains('close')) {
        await Future<void>.delayed(Duration.zero);
      }
      await workspace.dispatch('worldCircuitCancel');
      backend.holdClose!.complete();
      await resetting;
      expect(workspace.view.error, contains('已取消'));
      expect(backend.opens, 1);
      expect(backend.closes, 1);
      expect((workspace.view.result['worldCircuit'] as Map)['open'], isFalse);
      expect(
        (workspace.view.result['worldCircuit'] as Map)['sourceName'],
        'p.wld',
      );
      expect(backend.releaseAttempts, isEmpty);

      backend.holdClose = null;
      await workspace.dispatch('worldCircuitImport');
      expect(workspace.view.error, isEmpty);
      expect(backend.opens, 2);
      expect(
        (workspace.view.result['worldCircuit'] as Map)['open'],
        isTrue,
      );
      await workspace.close();
      workspace.dispose();
    },
  );

  test(
    'cancelled opening cannot adopt a late result; same source can reopen',
    () async {
      final backend = GenericWorldCircuitBackend()..holdOpen = Completer<void>();
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
      await workspace.dispatch('worldCircuitCancel');
      backend.holdOpen!.complete();
      await opening;
      expect((workspace.view.result['worldCircuit'] as Map)['open'], isFalse);
      expect(backend.closes, 1);
      expect(backend.commands, isEmpty);
      backend.holdOpen = null;
      await workspace.dispatch('worldCircuitImport');
      expect(
        (workspace.view.result['worldCircuit'] as Map)['open'],
        isTrue,
      );
      await workspace.close();
      workspace.dispose();
      expect(backend.closes, 2);
    },
  );

  test('WLD reset restores original ticks and clears selected display', () async {
    final backend = GenericWorldCircuitBackend();
    final workspace = Workspace(engine: FakeEngine(), files: FakeFiles(),
        worldCircuitBackend: backend, worldCircuitFiles: _Sources());
    Map state() => workspace.view.result['worldCircuit'] as Map;
    await workspace.dispatch('worldCircuitChooseWorld');
    await workspace.dispatch('worldCircuitImport');
    await workspace.dispatch('worldCircuitStep');
    expect(state()['ticks'], 1);
    expect(state()['dirty'], isTrue);
    await workspace.dispatch('worldCircuitReset');
    expect(workspace.view.error, isEmpty);
    expect(state()['ticks'], 0);
    expect(state()['dirty'], isFalse);
    expect(state()['displayRegion'], isNull);
    expect(state().containsKey('programName'), isFalse);
    expect(backend.opens, 2);
    expect(backend.closes, 1);
    await workspace.close();
    workspace.dispose();
  });
}
