import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';

void main() {
  test('controller upserts rule, resolves, and reconciles', () async {
    final platform = FakeNetworkPlatform(
      resolveMap: {
        'intranet.company.local': ['10.10.1.5'],
      },
    );
    final repo = MemoryRulesRepository();
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: repo,
    );

    await controller.start();
    expect(controller.interfaces.length, 2);

    await controller.upsertRule(
      rawDestination: 'https://intranet.company.local/wiki',
      interfaceId: 'en7',
      label: 'Wiki',
    );

    expect(controller.rules.length, 1);
    expect(controller.rules.first.normalizedDestination, 'intranet.company.local');
    expect(controller.rules.first.resolvedIps, ['10.10.1.5']);
    expect(controller.rules.first.status.name, 'applied');
    expect(platform.managed.length, 1);
    expect(platform.managed.first.destinationCidr, '10.10.1.5/32');

    final loaded = await repo.load();
    expect(loaded.length, 1);
  });
}
