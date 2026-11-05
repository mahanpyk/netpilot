import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/routing_mode_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/routing_mode.dart';

void main() {
  test(
    'routing mode persists and defaults to Custom for older installs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'netpilot-mode-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final repository = FileRoutingModeRepository(
        directoryProvider: () async => directory,
      );

      expect(await repository.load(), RoutingMode.custom);
      await repository.save(RoutingMode.systemDefault);
      expect(await repository.load(), RoutingMode.systemDefault);
      expect(
        await FileRoutingModeRepository(
          directoryProvider: () async => directory,
        ).load(),
        RoutingMode.systemDefault,
      );
    },
  );

  test('malformed mode preferences fall back to Custom', () async {
    final directory = await Directory.systemTemp.createTemp(
      'netpilot-mode-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/netpilot_routing_mode.json');
    await file.writeAsString('{incomplete');
    final repository = FileRoutingModeRepository(
      directoryProvider: () async => directory,
    );

    expect(await repository.load(), RoutingMode.custom);
  });

  test(
    'System Default removes managed routes and hosts, Custom restores them',
    () async {
      final platform = FakeNetworkPlatform();
      final modeRepository = MemoryRoutingModeRepository();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: MemoryRulesRepository(),
        routingModeRepository: modeRepository,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.upsertRule(
        rawDestination: '10.10.20.31',
        interfaceId: 'en7',
      );
      await controller.upsertRule(
        rawDestination: 'lan.example.test',
        interfaceId: 'en7',
        hostIpv4: '10.10.20.32',
      );
      expect(platform.managed, hasLength(2));
      expect(platform.managedHostMappings, hasLength(1));

      await controller.setRoutingMode(RoutingMode.systemDefault);
      expect(controller.routingMode, RoutingMode.systemDefault);
      expect(await modeRepository.load(), RoutingMode.systemDefault);
      expect(platform.managed, isEmpty);
      expect(platform.managedHostMappings, isEmpty);
      expect(
        controller.rules.map((rule) => rule.enabled),
        everyElement(isTrue),
      );
      expect(
        controller.rules.map((rule) => rule.status),
        everyElement(RuleStatus.pending),
      );

      await controller.refreshResolutions();
      platform.notifyInterfacesChanged();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(platform.managed, isEmpty);
      expect(platform.managedHostMappings, isEmpty);

      await controller.setRoutingMode(RoutingMode.custom);
      expect(platform.managed, hasLength(2));
      expect(platform.managedHostMappings, hasLength(1));
    },
  );

  test('route removal still runs when hostname cleanup fails', () async {
    final platform = _FailingHostCleanupPlatform();
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
      routingModeRepository: MemoryRoutingModeRepository(),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.upsertRule(
      rawDestination: '10.10.20.31',
      interfaceId: 'en7',
    );
    expect(platform.managed, isNotEmpty);

    platform.failHostCleanup = true;
    await controller.setRoutingMode(RoutingMode.systemDefault);

    expect(platform.managed, isEmpty);
    expect(controller.bannerError, contains('Host mapping cleanup'));
  });

  test(
    'saved System Default mode stays inactive on next controller start',
    () async {
      final platform = FakeNetworkPlatform();
      final rules = MemoryRulesRepository();
      final mode = MemoryRoutingModeRepository();
      final first = NetPilotController(
        platform: platform,
        rulesRepository: rules,
        routingModeRepository: mode,
      );
      await first.start();
      await first.upsertRule(rawDestination: '10.1.2.3', interfaceId: 'en7');
      await first.setRoutingMode(RoutingMode.systemDefault);
      first.dispose();

      final second = NetPilotController(
        platform: platform,
        rulesRepository: rules,
        routingModeRepository: mode,
      );
      addTearDown(second.dispose);
      await second.start();
      expect(second.routingMode, RoutingMode.systemDefault);
      expect(platform.managed, isEmpty);
      expect(second.rules.single.enabled, isTrue);
      await second.setRoutingMode(RoutingMode.custom);
      expect(platform.managed.single.destinationCidr, '10.1.2.3/32');
    },
  );
  test(
    'editing and toggling rules while System Default never reapplies routes',
    () async {
      final platform = FakeNetworkPlatform();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: MemoryRulesRepository(),
        routingModeRepository: MemoryRoutingModeRepository(),
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.setRoutingMode(RoutingMode.systemDefault);
      await controller.upsertRule(
        rawDestination: '10.12.0.1',
        interfaceId: 'en7',
      );
      final first = controller.rules.single;
      await controller.setRuleEnabled(first.id, false);
      await controller.upsertRule(
        rawDestination: '10.12.0.2',
        interfaceId: 'en7',
      );
      expect(platform.managed, isEmpty);
      expect(controller.rules.map((rule) => rule.enabled), [false, true]);

      await controller.setRoutingMode(RoutingMode.custom);
      expect(platform.managed.single.destinationCidr, '10.12.0.2/32');
    },
  );
}

class _FailingHostCleanupPlatform extends FakeNetworkPlatform {
  bool failHostCleanup = false;

  @override
  Future<HostMappingsResult> reconcileHostMappings(List<HostMapping> desired) {
    if (failHostCleanup && desired.isEmpty) {
      throw StateError('XPC unavailable');
    }
    return super.reconcileHostMappings(desired);
  }
}
