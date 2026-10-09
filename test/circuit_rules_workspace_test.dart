import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/circuit_rules_workspace.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/circuit_rules_backend.dart';
import 'package:terraforge/platform/files.dart';

import 'workspace_test.dart' show FakeEngine;

class _Files implements FileGateway {
  bool accepted = true;
  String? name;
  Uint8List? output;
  @override
  Future<PickedFile?> pick(String kind) async => null;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    this.name = name;
    output = bytes;
    return accepted;
  }
}

class _Host implements CircuitRulesBackend {
  final calls = <String>[];
  Map<String, Object?> document = {
    'format': 'viewer-terralogic',
    'version': 1,
    'target': 'test',
    'source': 'source',
    'title': 'Test',
    'tick': 0,
    'world': {'width': 16, 'height': 16, 'tiles': [], 'wires': []},
  };
  int generation = 1;
  bool dirty = false, malformed = false;
  Completer<Object?>? hold;
  String? holdMethod;
  Map<String, Object?> snapshot() => {
    'id': 1,
    'generation': generation,
    'document': jsonEncode(document),
    'revision': generation,
    'dirty': dirty,
    'canUndo': dirty,
    'canRedo': false,
    'selection': null,
    'clipboardAvailable': false,
    'canReset': false,
  };
  @override
  Future<Object?> invokeCircuitRules(String method, List<Object?> args) async {
    calls.add(method);
    if (method == holdMethod && hold != null) return hold!.future;
    if (malformed) {
      malformed = false;
      return {...snapshot(), 'document': '{"format":"wrong"}'};
    }
    switch (method) {
      case 'capabilities':
        return {'available': true, 'apiVersion': 1};
      case 'catalog':
        return {
          'target': {'game': 'test', 'source': 'source'},
          'palette': [],
          'definitions': {},
          'demos': [],
        };
      case 'editor.new':
        document = {...document, 'title': args.isEmpty ? 'Test' : args[0]};
        dirty = false;
        generation++;
        return snapshot();
      case 'editor.open':
        document = Map<String, Object?>.from(
          jsonDecode(args[0] as String) as Map,
        );
        // The real facade constructs a new CircuitEditor whose initial JSON
        // is its saved baseline, even when that JSON is a recovery copy.
        dirty = false;
        generation++;
        return snapshot();
      case 'editor.command':
        if ((args.first as Map)['method'] == 'markSaved') {
          dirty = false;
        } else {
          dirty = true;
          document = {...document, 'title': 'Edited'};
        }
        generation++;
        return snapshot();
      case 'host.reset':
        generation = 0;
        return null;
      case 'editor.close':
        return null;
      case 'simulation.command':
        document = {...document, 'tick': 6};
        return snapshot();
      default:
        throw StateError(method);
    }
  }
}

class _WorkspaceHost extends FakeEngine implements CircuitRulesBackend {
  final rules = _Host();
  @override
  Future<Object?> invokeCircuitRules(String method, List<Object?> args) =>
      rules.invokeCircuitRules(method, args);
}

class _WaitingFiles extends _Files {
  final pickResult = Completer<PickedFile?>();
  @override
  Future<PickedFile?> pick(String kind) => pickResult.future;
}

void main() {
  test('navigation pause crosses the root workspace busy boundary', () async {
    final files = _WaitingFiles();
    final app = Workspace(engine: _WorkspaceHost(), files: files);
    await app.dispatch('rulesOpen');
    await app.dispatch('rulesToggleRun');
    final picking = app.dispatch('import', {'kind': 'project'});
    await Future<void>.delayed(Duration.zero);
    expect(app.view.busy, isTrue);
    await app.dispatch('rulesPause');
    await app.dispatch('rulesPause');
    expect((app.view.result['rulesCircuit'] as Map)['running'], isFalse);
    files.pickResult.complete(null);
    await picking;
    await app.close();
    app.dispose();
  });

  test('accepted snapshots are immutable; file cancellation keeps dirty state; recovery keeps exact document', () async {
    final host = _Host(), files = _Files(), persisted = <Uint8List>[];
    final app = CircuitRulesWorkspace(
      backend: host,
      files: files,
      persist: (name, kind, bytes) async {
        persisted.add(bytes);
      },
    );
    await app.dispatch('rulesOpen');
    expect(app.error, isEmpty);
    expect(
      () => ((app.state['document'] as Map)['title'] = 'forged'),
      throwsUnsupportedError,
    );
    await app.dispatch('rulesEdit', {'method': 'updateTile', 'args': []});
    expect((app.state['snapshot'] as Map)['dirty'], isTrue);
    final accepted = (app.state['snapshot'] as Map)['document'];
    files.accepted = false;
    await app.dispatch('rulesExport');
    expect((app.state['snapshot'] as Map)['dirty'], isTrue);
    expect(host.calls.where((m) => m == 'editor.command').length, 1);
    host.malformed = true;
    await app.dispatch('rulesEdit', {'method': 'updateTile', 'args': []});
    expect(app.error, isNotEmpty);
    expect((app.state['snapshot'] as Map)['document'], accepted);
    await app.dispatch('rulesRecover');
    expect(app.error, isEmpty);
    expect((app.state['snapshot'] as Map)['document'], accepted);
    expect(host.dirty, isFalse);
    expect((app.state['snapshot'] as Map)['dirty'], isTrue);
    expect(host.calls, contains('host.reset'));
    await app.dispatch('rulesRecover');
    expect((app.state['snapshot'] as Map)['dirty'], isTrue);
    await app.dispatch('rulesExport');
    expect((app.state['snapshot'] as Map)['dirty'], isTrue);
    files.accepted = true;
    await app.dispatch('rulesExport');
    expect(utf8.decode(files.output!), accepted);
    expect((app.state['snapshot'] as Map)['dirty'], isFalse);
    await app.dispatch('rulesRecover');
    expect((app.state['snapshot'] as Map)['dirty'], isFalse);
    await app.dispatch('rulesEdit', {'method': 'updateTile', 'args': []});
    await app.dispatch('rulesRecover');
    expect((app.state['snapshot'] as Map)['dirty'], isTrue);
    await app.dispatch('rulesNew', {'title': 'Deliberate new document'});
    expect((app.state['snapshot'] as Map)['dirty'], isFalse);
    expect(persisted, isNotEmpty);
    await app.close();
    app.dispose();
  });
  test(
    'close waits for an accepted command boundary and discards its stale reply',
    () async {
      final host = _Host()
        ..holdMethod = 'editor.new'
        ..hold = Completer<Object?>();
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {},
      );
      final opening = app.dispatch('rulesOpen');
      await Future<void>.delayed(Duration.zero);
      expect(app.busy, isTrue);
      final closing = app.close();
      expect(host.calls, isNot(contains('editor.close')));
      host.hold!.complete(host.snapshot());
      await opening;
      await closing;
      expect(app.state['snapshot'], isNull);
      expect(host.calls.last, 'editor.close');
      expect(app.busy, isFalse);
      app.dispose();
    },
  );
  testWidgets('pause is accepted while a continuous tick is still computing', (
    tester,
  ) async {
    final host = _Host();
    final controller = CircuitRulesWorkspace(
      backend: host,
      files: _Files(),
      persist: (a, b, c) async {},
    );
    await controller.dispatch('rulesOpen');
    host.holdMethod = 'simulation.command';
    host.hold = Completer<Object?>();
    await controller.dispatch('rulesToggleRun');
    await tester.pump(const Duration(milliseconds: 101));
    expect(controller.busy, isTrue);
    await controller.dispatch('rulesPause');
    await controller.dispatch('rulesPause');
    expect(controller.running, isFalse);
    host.document = {...host.document, 'tick': 6};
    host.hold!.complete(host.snapshot());
    await tester.pump();
    expect((controller.state['document'] as Map)['tick'], 6);
    expect(controller.busy, isFalse);
    final simulationCount = host.calls
        .where((m) => m == 'simulation.command')
        .length;
    await tester.pump(const Duration(seconds: 1));
    expect(
      host.calls.where((m) => m == 'simulation.command').length,
      simulationCount,
    );
    await controller.close();
    controller.dispose();
  });
}
