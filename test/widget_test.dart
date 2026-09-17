import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/app/netpilot_app.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';

void main() {
  testWidgets('home shows interfaces and add rule', (tester) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: MemoryRulesRepository(),
    );

    await tester.pumpWidget(NetPilotApp(controller: controller));
    await controller.start();
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.text('NetPilot'))).brightness,
      Brightness.dark,
    );
    expect(find.text('NetPilot'), findsOneWidget);
    expect(find.text('Add rule'), findsOneWidget);

    await tester.tap(find.text('Networks'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wi-Fi'), findsWidgets);

    await tester.tap(find.text('Rules'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    expect(find.text('Add routing rule'), findsOneWidget);
  });

  testWidgets('rule expands discovered sub-rules and toggles one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = MemoryRulesRepository();
    await repo.save([
      RoutingRule(
        id: 'parent',
        rawDestination: 'https://example.test',
        kind: DestinationKind.url,
        normalizedDestination: 'example.test',
        interfaceId: 'en7',
        enabled: true,
        resolvedIps: const ['203.0.113.1'],
        status: RuleStatus.pending,
        updatedAt: DateTime(2026),
        dependencyScanStatus: DependencyScanStatus.succeeded,
        subRules: const [
          RoutingSubRule(
            id: 'child',
            destination: 'api.example.test',
            kind: DestinationKind.hostname,
            enabled: true,
            resolvedIps: ['203.0.113.2'],
            status: RuleStatus.pending,
          ),
        ],
      ),
    ]);
    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: repo,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(NetPilotApp(controller: controller));
    await controller.start();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subrules-parent')));
    await tester.pumpAndSettle();
    expect(find.text('Discovered dependencies'), findsOneWidget);
    expect(find.text('api.example.test'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subrule-toggle-child')));
    await tester.pumpAndSettle();
    expect(controller.rules.single.subRules.single.enabled, isFalse);
  });
}
