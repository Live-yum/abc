import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terraforge/application/workspace.dart';
import 'package:terraforge/resources/online_resource_service.dart';
import 'package:terraforge/resources/online_resource_storage.dart';
import 'package:terraforge/ui/online_resources_panel.dart';

import 'support/online_resource_fixture.dart';
import 'workspace_test.dart' show FakeEngine, FakeFiles;

void main() {
  testWidgets(
    'unconfigured and install states, guarded Workspace withdraws revoked catalog',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OnlineResourcesPanel(onActivate: (_, _) {})),
        ),
      );
      expect(find.textContaining('线上资源尚未配置'), findsOneWidget);
      final fixture = OnlineFixture();
      final service = OnlineResourceService(
        transport: FixtureResourceTransport(fixture),
        storage: MemoryOnlineResourceStorage(),
      );
      final workspace = Workspace(
        engine: FakeEngine(),
        files: FakeFiles(),
        onlineResources: service,
      );
      addTearDown(workspace.dispose);
      addTearDown(service.dispose);
      var activations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OnlineResourcesPanel(
              service: service,
              onActivate: (store, guard) {
                activations++;
                guard();
                workspace.dispatch('activateOnlineResources');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(workspace.view.resources, isNull);
      await tester.tap(find.text('安装已审批资源'));
      await tester.pumpAndSettle();
      expect(activations, 1);
      expect(workspace.view.resources, isNotNull);
      // The installer publishes through the panel's install callback or explicit
      // restoration; a route remount must restore the verified active store.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OnlineResourcesPanel(
              service: service,
              onActivate: (store, guard) {
                activations++;
                guard();
                workspace.dispatch('activateOnlineResources');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(activations, 2);
      expect(
        workspace.view.resources!.catalog.byId('items', 17)!.name,
        'Synthetic',
      );
      expect(find.textContaining('单独验证的来源'), findsOneWidget);
      await service.authority.accept(
        fixture.approval(sequence: '2', revoked: [fixture.sha], active: false),
      );
      await tester.pumpAndSettle();
      expect(workspace.view.resources, isNull);
      expect(find.textContaining('此游戏资源版本已撤销'), findsOneWidget);
    },
  );
}
