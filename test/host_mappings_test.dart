import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/core/utils/destination_parser.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';
import 'package:netpilot_desktop/features/routing_rules/presentation/rule_editor_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'LAN pin persists, bypasses missing DNS and reconciles its lifecycle',
    () async {
      final platform = FakeNetworkPlatform();
      final repo = MemoryRulesRepository();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: repo,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.upsertRule(
        rawDestination: 'intranet.example.test',
        interfaceId: 'en7',
        hostIpv4: '192.168.2.122',
      );
      final saved = controller.rules.single;
      expect(saved.status, RuleStatus.applied);
      expect(saved.resolvedIps, ['192.168.2.122']);
      expect(RoutingRule.fromJson(saved.toJson()).hostIpv4, '192.168.2.122');
      expect(platform.managedHostMappings.single.host, 'intranet.example.test');
      expect(platform.managed.single.destinationCidr, '192.168.2.122/32');
      await controller.refreshResolutions();
      expect(controller.rules.single.resolvedIps, ['192.168.2.122']);
      await controller.setRuleEnabled(saved.id, false);
      expect(platform.managedHostMappings, isEmpty);
      await controller.setRuleEnabled(saved.id, true);
      expect(platform.managedHostMappings.single.ipv4, '192.168.2.122');
      await controller.deleteRule(saved.id);
      expect(platform.managedHostMappings, isEmpty);
      expect(platform.managed, isEmpty);
    },
  );

  test('opt-in snapshots one private LAN answer but not public DNS', () async {
    final platform = FakeNetworkPlatform(
      resolveMap: {
        'lan.example.test': ['172.20.109.17'],
        'public.example.test': ['203.0.113.3'],
      },
    );
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.upsertRule(
      rawDestination: 'lan.example.test',
      interfaceId: 'en7',
      manageHostname: true,
    );
    await controller.upsertRule(
      rawDestination: 'public.example.test',
      interfaceId: 'en7',
      manageHostname: true,
    );
    expect(controller.rules.first.hostIpv4, '172.20.109.17');
    expect(controller.rules.last.hostIpv4, isNull);
    expect(platform.managedHostMappings, hasLength(1));
  });

  test('bad overrides fail before persistence or helper mutation', () async {
    final platform = FakeNetworkPlatform();
    final repo = MemoryRulesRepository();
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: repo,
    );
    addTearDown(controller.dispose);
    await controller.start();
    for (final bad in [
      '10.0.0.1\n127.0.0.1 localhost',
      '300.1.1.1',
      '10.0.0.0/8',
    ]) {
      await expectLater(
        controller.upsertRule(
          rawDestination: 'lan.example.test',
          interfaceId: 'en7',
          hostIpv4: bad,
        ),
        throwsA(isA<DestinationParseException>()),
      );
    }
    expect(controller.rules, isEmpty);
    expect(platform.managedHostMappings, isEmpty);
  });

  test(
    'manual hosts conflict fails the rule and prevents route reconciliation',
    () async {
      final platform = RejectHostsPlatform();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: MemoryRulesRepository(),
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.upsertRule(
        rawDestination: 'lan.example.test',
        interfaceId: 'en7',
        hostIpv4: '10.0.0.1',
      );
      expect(controller.rules.single.status, RuleStatus.error);
      expect(controller.rules.single.lastError, contains('manual hosts entry'));
      expect(platform.managed, isEmpty);
    },
  );

  testWidgets('mapped hostname can be edited into a literal IP', (
    tester,
  ) async {
    final platform = FakeNetworkPlatform();
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.upsertRule(
      rawDestination: 'lan.example.test',
      interfaceId: 'en7',
      hostIpv4: '10.0.0.1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => RuleEditorSheet(
                  controller: controller,
                  existing: controller.rules.single,
                ),
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '10.0.0.2');
    await tester.pump();
    expect(find.text('LAN IPv4 (optional override)'), findsNothing);
    await tester.ensureVisible(find.text('Save & apply'));
    await tester.tap(find.text('Save & apply'));
    await tester.pumpAndSettle();
    expect(controller.rules.single.kind, DestinationKind.ipv4);
    expect(controller.rules.single.hostIpv4, isNull);
    expect(platform.managedHostMappings, isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('channel payload uses structured host mappings', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('test.netpilot.hosts');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {'ok': true, 'changed': true, 'errors': <String>[]};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final platform = MethodChannelNetworkPlatform(methodChannel: channel);
    final result = await platform.reconcileHostMappings([
      const HostMapping(host: 'lan.example.test', ipv4: '10.0.0.1'),
    ]);
    expect(result.ok, isTrue);
    expect(result.changed, isTrue);
    expect(calls.single.method, 'reconcileHostMappings');
    expect(calls.single.arguments, {
      'desired': [
        {'host': 'lan.example.test', 'ipv4': '10.0.0.1'},
      ],
    });
  });
}

class RejectHostsPlatform extends FakeNetworkPlatform {
  @override
  Future<HostMappingsResult> reconcileHostMappings(
    List<HostMapping> desired,
  ) async => desired.isEmpty
      ? const HostMappingsResult(ok: true)
      : const HostMappingsResult(
          ok: false,
          errors: ['Hostname already has a different manual hosts entry.'],
        );
}
