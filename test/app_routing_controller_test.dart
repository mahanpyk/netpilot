import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/app_routing_rule.dart';
import 'package:netpilot_desktop/core/models/network_interface_info.dart';
import 'package:netpilot_desktop/core/platform/app_routing_platform.dart';
import 'package:netpilot_desktop/features/app_routing/data/app_rules_repository.dart';
import 'package:netpilot_desktop/features/app_routing/domain/app_routing_controller.dart';

void main() {
  const interfaces = [
    NetworkInterfaceInfo(
      id: 'en0',
      name: 'Wi-Fi',
      interfaceName: 'en0',
      kind: NetworkInterfaceKind.wifi,
      ipv4Addresses: ['192.168.1.2'],
      dnsServers: [],
      isDefaultRoute: true,
      isActive: true,
    ),
    NetworkInterfaceInfo(
      id: 'en8',
      name: 'Ethernet',
      interfaceName: 'en8',
      kind: NetworkInterfaceKind.ethernet,
      ipv4Addresses: ['192.168.8.2'],
      dnsServers: [],
      isDefaultRoute: false,
      isActive: true,
    ),
  ];

  const app = AppDescriptor(
    displayName: 'Browser',
    bundlePath: '/Applications/Browser.app',
    bundleIdentifier: 'example.browser',
    signingIdentifier: 'example.browser',
    teamIdentifier: 'TEAM123',
    helperSigningIdentifiers: ['example.browser.helper'],
  );

  test('edits are persisted as pending until manual apply', () async {
    final platform = FakeAppRoutingPlatform();
    final repository = MemoryAppRulesRepository();
    final controller = AppRoutingController(
      platform: platform,
      repository: repository,
      interfacesProvider: () => interfaces,
    );
    await controller.start();
    await controller.upsertRule(
      app: app,
      interfaceId: 'en8',
      failurePolicy: AppRoutingFailurePolicy.block,
    );
    await controller.setMasterEnabled(true);

    expect(controller.hasPendingChanges, isTrue);
    expect(platform.applyCount, 0);
    await controller.applyAndRestart();
    expect(platform.applyCount, 1);
    expect(controller.hasPendingChanges, isFalse);
    expect(repository.state.rules.single.status, AppRoutingRuleStatus.active);
  });

  test(
    'blocks signing identifier overlap across different interfaces',
    () async {
      final platform = FakeAppRoutingPlatform();
      final controller = AppRoutingController(
        platform: platform,
        repository: MemoryAppRulesRepository(),
        interfacesProvider: () => interfaces,
      );
      await controller.start();
      await controller.upsertRule(
        app: app,
        interfaceId: 'en0',
        failurePolicy: AppRoutingFailurePolicy.block,
      );
      await controller.upsertRule(
        app: const AppDescriptor(
          displayName: 'Companion',
          bundlePath: '/Applications/Companion.app',
          bundleIdentifier: 'example.companion',
          signingIdentifier: 'example.companion',
          teamIdentifier: 'TEAM123',
          helperSigningIdentifiers: ['example.browser.helper'],
        ),
        interfaceId: 'en8',
        failurePolicy: AppRoutingFailurePolicy.fallback,
      );

      expect(controller.validate(), contains('conflicts'));
      await controller.applyAndRestart();
      expect(platform.applyCount, 0);
      expect(controller.error, contains('conflicts'));
    },
  );

  test('rejects utun and inactive interfaces', () async {
    final controller = AppRoutingController(
      platform: FakeAppRoutingPlatform(),
      repository: MemoryAppRulesRepository(),
      interfacesProvider: () => interfaces,
    );
    await controller.start();
    await controller.upsertRule(
      app: app,
      interfaceId: 'utun6',
      failurePolicy: AppRoutingFailurePolicy.block,
    );
    expect(controller.validate(), contains('unavailable physical interface'));
  });
}
