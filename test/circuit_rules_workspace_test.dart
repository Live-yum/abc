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
  final commands = <Map<String, Object?>>[];
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
  Map<String, Object?>? preview;
  Map<String, Object?> Function(Map<String, Object?>)? alterPreview;
  Completer<Object?>? hold;
  String? holdMethod, holdCommand;
  Map<String, Object?>? heldSnapshot;
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
    'preview': preview,
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
      case 'editor.demo':
        document = {...document, 'title': args.isEmpty ? 'Test' : args[0]};
        preview = null;
        dirty = false;
        generation++;
        return snapshot();
      case 'editor.open':
        preview = null;
        document = Map<String, Object?>.from(
          jsonDecode(args[0] as String) as Map,
        );
        // The real facade constructs a new CircuitEditor whose initial JSON
        // is its saved baseline, even when that JSON is a recovery copy.
        dirty = false;
        generation++;
        return snapshot();
      case 'editor.command':
        final command = Map<String, Object?>.from(args.first as Map);
        commands.add(command);
        final commandArgs = command['args'] as List;
        if (command['method'] == 'previewRoute' ||
            command['method'] == 'previewNetwork') {
          final route = command['method'] == 'previewRoute';
          final start = commandArgs[0] as Map;
          final end = route
              ? commandArgs[1] as Map
              : {'x': (start['x'] as int) + 1, 'y': start['y']};
          final mask = commandArgs[route ? 2 : 1] as int;
          final cells = [
            [start['x'], start['y'], mask],
            [end['x'], end['y'], mask],
          ];
          preview = {
            'kind': route ? 'route' : 'removeNetwork',
            'token': commandArgs.last,
            'editorId': 1,
            'generation': generation,
            'revision': generation,
            'cells': cells,
            'count': cells.length,
            'colourCounts': [
              for (var colour = 0; colour < 4; colour++)
                (mask & (1 << colour)) != 0 ? cells.length : 0,
            ],
          };
          preview = alterPreview?.call(preview!) ?? preview;
        } else if (command['method'] == 'cancelPreview') {
          preview = null;
        } else if (command['method'] == 'commitPreview') {
          if (preview?['token'] != commandArgs.single) {
            throw StateError('stale preview');
          }
          document = {
            ...document,
            'world': {
              ...document['world'] as Map,
              'wires': preview!['kind'] == 'route' ? preview!['cells'] : [],
            },
          };
          preview = null;
          dirty = true;
          generation++;
        } else if (command['method'] == 'markSaved') {
          dirty = false;
          generation++;
        } else {
          preview = null;
          dirty = true;
          document = {...document, 'title': 'Edited'};
          generation++;
        }
        if (command['method'] == holdCommand && hold != null) {
          heldSnapshot = snapshot();
          return hold!.future;
        }
        return snapshot();
      case 'host.reset':
        preview = null;
        generation = 0;
        return null;
      case 'editor.close':
        return null;
      case 'simulation.command':
        preview = null;
        document = {...document, 'tick': 6};
        return snapshot();
      case 'simulation.reset':
        preview = null;
        document = {...document, 'tick': 0};
        generation++;
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

Future<void> _route(CircuitRulesWorkspace app, {int mask = 1}) => app.dispatch(
  'rulesPreviewRoute',
  {'startX': 1, 'startY': 1, 'endX': 3, 'endY': 1, 'mask': mask},
);

Map _snapshot(CircuitRulesWorkspace app) => app.state['snapshot'] as Map;

Map? _preview(CircuitRulesWorkspace app) =>
    (app.state['snapshot'] as Map?)?['preview'] as Map?;

void main() {
  test(
    'route preview pauses, stays immutable, and persists only one commit',
    () async {
      final host = _Host(), persisted = <Uint8List>[];
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (name, kind, bytes) async => persisted.add(bytes),
      );
      await app.dispatch('rulesOpen');
      final original = _snapshot(app)['document'];
      await app.dispatch('rulesToggleRun');
      await _route(app, mask: 5);
      expect(app.error, isEmpty);
      expect(app.running, isFalse);
      expect(_snapshot(app)['document'], original);
      expect(persisted, isEmpty);
      final preview = _preview(app)!;
      expect(preview['kind'], 'route');
      expect(preview['colourCounts'], [2, 0, 2, 0]);
      expect(() => preview['token'] = 'forged', throwsUnsupportedError);
      expect(
        () => ((preview['cells'] as List).first as List)[0] = 10,
        throwsUnsupportedError,
      );
      await app.dispatch('rulesCommitPreview', {'token': 'forged'});
      expect(app.error, isNotEmpty);
      expect(
        host.commands.where((c) => c['method'] == 'commitPreview'),
        isEmpty,
      );
      expect(_preview(app)!['token'], preview['token']);
      await app.dispatch('rulesCommitPreview', {'token': preview['token']});
      expect(app.error, isEmpty);
      expect(_preview(app), isNull);
      expect(_snapshot(app)['document'], isNot(original));
      expect(persisted.length, 1);
      expect(utf8.decode(persisted.single), _snapshot(app)['document']);
      await app.dispatch('rulesCommitPreview', {'token': preview['token']});
      expect(app.error, isNotEmpty);
      expect(
        host.commands.where((c) => c['method'] == 'commitPreview').length,
        1,
      );
      expect(persisted.length, 1);
      await app.close();
      app.dispose();
    },
  );

  test(
    'preview rejects forged ownership, malformed cells, and unbounded replies',
    () async {
      final host = _Host();
      var persistenceCount = 0;
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {
          persistenceCount++;
        },
      );
      await app.dispatch('rulesOpen');
      final original = _snapshot(app)['document'];
      final corruptions = <Map<String, Object?>>[
        {'token': 'forged'},
        {'kind': 'removeNetwork'},
        {'editorId': 2},
        {'editorId': 1.0},
        {'generation': -1},
        {'revision': -1},
        {'count': 1},
        {
          'colourCounts': [0, 0, 0, 0],
        },
        {
          'colourCounts': [2, 0, 0],
        },
        {
          'cells': [
            [-1, 1, 1],
            [3, 1, 1],
          ],
        },
        {
          'cells': [
            [16, 1, 1],
            [3, 1, 1],
          ],
        },
        {
          'cells': [
            [1, 1, 0],
            [3, 1, 1],
          ],
        },
        {
          'cells': [
            [1, 1, 16],
            [3, 1, 1],
          ],
        },
        {
          'cells': [
            [1, 1, 1],
            [1, 1, 1],
          ],
        },
        {
          'cells': [
            [1, 1],
            [3, 1, 1],
          ],
        },
        {'extra': 'unrecognized data'},
        {
          'count': CircuitRulesWorkspace.maxPreviewCells + 1,
          'cells': List.filled(CircuitRulesWorkspace.maxPreviewCells + 1, [
            1,
            1,
            1,
          ]),
        },
      ];
      for (final corrupt in corruptions) {
        host.alterPreview = (preview) => {...preview, ...corrupt};
        await _route(app);
        expect(app.error, isNotEmpty, reason: corrupt.keys.join(','));
        expect(_preview(app), isNull);
        expect(_snapshot(app)['document'], original);
      }
      expect(persistenceCount, 0);
      host.alterPreview = null;
      await _route(app);
      expect(app.error, isEmpty);
      await app.close();
      app.dispose();
    },
  );

  test(
    'sparse preview coordinates stay distinct above Web integer precision',
    () async {
      final host = _Host();
      host.document['world'] = {
        'width': 2147483647,
        'height': 2147483647,
        'tiles': [],
        'wires': [],
      };
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {},
      );
      await app.dispatch('rulesOpen');
      await app.dispatch('rulesPreviewRoute', {
        'startX': 1,
        'startY': 2147483646,
        'endX': 2,
        'endY': 2147483646,
        'mask': 1,
      });
      expect(app.error, isEmpty);
      expect(_preview(app)!['count'], 2);
      await app.close();
      app.dispose();
    },
  );

  test(
    'preview rejects invalid input and editor-command token bypass',
    () async {
      final host = _Host();
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {},
      );
      await app.dispatch('rulesOpen');
      for (final invalid in <Map<String, Object?>>[
        {'x': -1, 'y': 1, 'mask': 1},
        {'x': 1, 'y': 1.5, 'mask': 1},
        {'x': 1, 'y': 16, 'mask': 1},
        {'x': 1, 'y': 1, 'mask': 0},
        {'x': 1, 'y': 1, 'mask': 16},
      ]) {
        await app.dispatch('rulesPreviewNetwork', invalid);
        expect(app.error, isNotEmpty);
      }
      for (final method in [
        'previewRoute',
        'previewNetwork',
        'commitPreview',
        'cancelPreview',
      ]) {
        await app.dispatch('rulesEdit', {
          'method': method,
          'args': ['forged'],
        });
        expect(app.error, isNotEmpty);
      }
      expect(host.commands, isEmpty);
      await app.close();
      app.dispose();
    },
  );

  test(
    'cancel pending preview clears immediately and queues backend cleanup',
    () async {
      final host = _Host();
      var persistenceCount = 0;
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {
          persistenceCount++;
        },
      );
      await app.dispatch('rulesOpen');
      await _route(app);
      final original = _snapshot(app)['document'];
      host.holdCommand = 'previewNetwork';
      host.hold = Completer<Object?>();
      final pending = app.dispatch('rulesPreviewNetwork', {
        'x': 1,
        'y': 1,
        'mask': 3,
      });
      await Future<void>.delayed(Duration.zero);
      expect(app.busy, isTrue);
      final cancelling = app.dispatch('rulesCancelPreview');
      expect(_preview(app), isNull);
      expect(host.commands.last['method'], 'previewNetwork');
      host.hold!.complete(host.heldSnapshot);
      await pending;
      await cancelling;
      expect(host.commands.last['method'], 'cancelPreview');
      expect(_preview(app), isNull);
      expect(_snapshot(app)['document'], original);
      expect(host.preview, isNull);
      expect(app.error, isEmpty);
      expect(app.busy, isFalse);
      expect(persistenceCount, 0);
      await app.close();
      app.dispose();
    },
  );

  test(
    'cancel before preview dispatch prevents a late request from starting',
    () async {
      final host = _Host();
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {},
      );
      await app.dispatch('rulesOpen');
      final pending = _route(app);
      final cancelling = app.dispatch('rulesCancelPreview');
      await pending;
      await cancelling;
      expect(host.commands.map((c) => c['method']), ['cancelPreview']);
      expect(_preview(app), isNull);
      expect(app.error, isEmpty);
      await app.close();
      app.dispose();
    },
  );

  test(
    'cancel during commit preserves its accepted document and persistence',
    () async {
      final host = _Host(), persisted = <Uint8List>[];
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, bytes) async => persisted.add(bytes),
      );
      await app.dispatch('rulesOpen');
      await _route(app);
      final token = _preview(app)!['token'];
      host.holdCommand = 'commitPreview';
      host.hold = Completer<Object?>();
      final committing = app.dispatch('rulesCommitPreview', {'token': token});
      await Future<void>.delayed(Duration.zero);
      final cancelling = app.dispatch('rulesCancelPreview');
      host.hold!.complete(host.heldSnapshot);
      await committing;
      await cancelling;
      expect(app.error, isEmpty);
      expect(_preview(app), isNull);
      expect((app.state['document'] as Map)['world']['wires'], isNotEmpty);
      expect(persisted.length, 1);
      expect(utf8.decode(persisted.single), _snapshot(app)['document']);
      expect(host.commands.last['method'], 'cancelPreview');
      await app.close();
      app.dispose();
    },
  );

  test('replacement, simulation and recovery invalidate tokens without reusing them', () async {
    final host = _Host(), tokens = <Object?>{};
    final app = CircuitRulesWorkspace(
      backend: host,
      files: _Files(),
      persist: (a, b, c) async {},
    );
    await app.dispatch('rulesOpen');
    for (final action in [
      'rulesReset',
      'rulesRecover',
      'rulesNew',
      'rulesDemo',
      'rulesSimulate',
      'rulesEdit',
      'rulesToggleRun',
    ]) {
      await _route(app);
      final token = _preview(app)!['token'];
      expect(tokens.add(token), isTrue);
      await app.dispatch(action, {
        'method': 'step',
        'args': [1],
        'name': 'hello',
      });
      expect(app.error, isEmpty);
      expect(_preview(app), isNull);
      await app.dispatch('rulesPause');
      await app.dispatch('rulesCommitPreview', {'token': token});
      expect(app.error, isNotEmpty);
    }
    await app.dispatch('rulesPreviewNetwork', {'x': 1, 'y': 1, 'mask': 10});
    expect(_preview(app)!['kind'], 'removeNetwork');
    expect(_preview(app)!['colourCounts'], [0, 2, 0, 2]);
    expect(tokens.add(_preview(app)!['token']), isTrue);
    await app.close();
    app.dispose();
    final second = CircuitRulesWorkspace(
      backend: _Host(),
      files: _Files(),
      persist: (a, b, c) async {},
    );
    await second.dispatch('rulesOpen');
    await _route(second);
    expect(tokens.add(_preview(second)!['token']), isTrue);
    await second.close();
    second.dispose();
  });

  test(
    'document import invalidates pending preview before its response arrives',
    () async {
      final host = _Host();
      final app = CircuitRulesWorkspace(
        backend: host,
        files: _Files(),
        persist: (a, b, c) async {},
      );
      await app.dispatch('rulesOpen');
      host.holdCommand = 'previewRoute';
      host.hold = Completer<Object?>();
      final pending = _route(app);
      await Future<void>.delayed(Duration.zero);
      final imported = jsonEncode({...host.document, 'title': 'Imported'});
      final loading = app.loadDocument(
        Uint8List.fromList(utf8.encode(imported)),
        name: 'import.json',
      );
      var acceptedPreview = false;
      app.addListener(() {
        acceptedPreview |= _preview(app) != null;
      });
      host.hold!.complete(host.heldSnapshot);
      await pending;
      await loading;
      expect(acceptedPreview, isFalse);
      expect(_preview(app), isNull);
      expect((app.state['document'] as Map)['title'], 'Imported');
      await app.close();
      app.dispose();
    },
  );

  test(
    'preview cancellation crosses the root workspace busy boundary',
    () async {
      final files = _WaitingFiles(), host = _WorkspaceHost();
      final app = Workspace(engine: host, files: files);
      await app.dispatch('rulesOpen');
      await app.dispatch('rulesPreviewRoute', {
        'startX': 1,
        'startY': 1,
        'endX': 3,
        'endY': 1,
        'mask': 1,
      });
      final picking = app.dispatch('import', {'kind': 'project'});
      await Future<void>.delayed(Duration.zero);
      expect(app.view.busy, isTrue);
      await app.dispatch('rulesCancelPreview');
      expect(
        (app.view.result['rulesCircuit'] as Map)['snapshot']['preview'],
        isNull,
      );
      expect(host.rules.commands.last['method'], 'cancelPreview');
      files.pickResult.complete(null);
      await picking;
      await app.close();
      app.dispose();
    },
  );

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
