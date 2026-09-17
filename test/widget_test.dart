import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/app/netpilot_app.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';

void main() {
  testWidgets('home shows interfaces and add rule', (tester) async {
    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: MemoryRulesRepository(),
    );

    await tester.pumpWidget(NetPilotApp(controller: controller));
    await controller.start();
    await tester.pumpAndSettle();

    expect(find.text('NetPilot'), findsOneWidget);
    expect(find.textContaining('Wi-Fi'), findsWidgets);
    expect(find.text('Add rule'), findsOneWidget);

    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    expect(find.text('Add routing rule'), findsOneWidget);
  });
}
