import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/engine/engine.dart';
import 'package:terraforge/platform/files.dart';
import 'package:terraforge/resources/online_resource_service.dart';
import 'package:terraforge/resources/online_resource_storage.dart';

import 'support/online_resource_fixture.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;

class DelayedEditEngine extends FakeEngine {
  final started = Completer<void>(), proceed = Completer<void>();
  @override
  Future<void> mutate(
    EngineDocument document,
    String operation,
    Map<String, dynamic> args,
  ) async {
    started.complete();
    await proceed.future;
    await super.mutate(document, operation, args);
  }
}

void main() {
  test(
    'resource revocation during candidate work aborts document publication',
    () async {
      final fixture = OnlineFixture();
      final service = OnlineResourceService(
        transport: FixtureResourceTransport(fixture),
        storage: MemoryOnlineResourceStorage(),
      );
      addTearDown(service.dispose);
      await service.install();
      final engine = DelayedEditEngine(),
          files = FakeFiles()
            ..next = PickedFile(
              'synthetic.wld',
              Uint8List.fromList([1, 2, 3, 4]),
            );
      final workspace = Workspace(
        engine: engine,
        files: files,
        onlineResources: service,
      );
      addTearDown(workspace.dispose);
      await workspace.initialize();
      expect(workspace.view.resources, isNotNull);
      await workspace.dispatch('import', {'kind': 'world'});
      final edit = workspace.dispatch('stageWorld', {
        'field': 'name',
        'value': 'candidate',
      });
      await engine.started.future;
      await service.authority.accept(
        fixture.approval(sequence: '2', revoked: [fixture.sha], active: false),
      );
      expect(workspace.view.resources, isNull);
      engine.proceed.complete();
      await edit;
      expect(workspace.view.error, isNotEmpty);
      expect(workspace.view.result['worldModified'], isFalse);
      expect(engine.handles.values.single, [1, 2, 3, 4]);
      await workspace.close();
    },
  );
}
