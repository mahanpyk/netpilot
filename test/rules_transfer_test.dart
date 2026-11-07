import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_transfer.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';

RoutingRule sampleRule() => RoutingRule(
  id: 'old-id',
  label: 'Company',
  rawDestination: 'https://company.test/wiki',
  kind: DestinationKind.url,
  normalizedDestination: 'company.test',
  interfaceId: 'old-lan',
  enabled: true,
  resolvedIps: const ['10.0.0.99'],
  hostIpv4: '10.0.0.1',
  status: RuleStatus.applied,
  updatedAt: DateTime(2026),
  subRules: const [
    RoutingSubRule(
      id: 'old-child',
      destination: 'api.company.test',
      kind: DestinationKind.hostname,
      enabled: false,
      resolvedIps: ['10.0.0.98'],
      status: RuleStatus.error,
      lastError: 'old error',
    ),
  ],
);

void main() {
  const transfer = RulesTransfer();
  test('portable export retains configuration but excludes runtime state', () {
    final text = transfer.encode([sampleRule()]);
    final decoded = transfer.decode(text).single;
    expect(decoded.label, 'Company');
    expect(decoded.rawDestination, 'https://company.test/wiki');
    expect(decoded.interfaceId, 'old-lan');
    expect(decoded.hostIpv4, '10.0.0.1');
    expect(decoded.subRules.single.enabled, isFalse);
    expect(decoded.resolvedIps, isEmpty);
    expect(decoded.subRules.single.resolvedIps, isEmpty);
    expect(text, isNot(contains('old-id')));
    expect(text, isNot(contains('old error')));
    expect(text, isNot(contains('10.0.0.99')));
  });
  test('rejects malformed, unsupported and partly invalid backups', () {
    final valid = jsonDecode(transfer.encode([sampleRule()])) as Map;
    for (final text in [
      'bad',
      '[]',
      '{}',
      jsonEncode({...valid, 'version': 99}),
      jsonEncode({
        ...valid,
        'rules': [
          valid['rules'][0],
          {'destination': 'bad/path'},
        ],
      }),
    ]) {
      expect(() => transfer.decode(text), throwsFormatException);
    }
  });
  test(
    'import maps networks, creates IDs, skips duplicates and starts paused',
    () async {
      final platform = FakeNetworkPlatform();
      final repo = MemoryRulesRepository();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: repo,
      );
      addTearDown(controller.dispose);
      await controller.start();
      final imported = transfer.decode(transfer.encode([sampleRule()]));
      final count = await controller.importRules(
        imported,
        interfaceMapping: {'old-lan': 'en7'},
      );
      expect(count, 1);
      final rule = controller.rules.single;
      expect(rule.interfaceId, 'en7');
      expect(rule.id, isNot('old-id'));
      expect(rule.subRules.single.id, isNot('old-child'));
      expect(rule.enabled, isFalse);
      expect(rule.resolvedIps, ['10.0.0.1']);
      expect(platform.managed, isEmpty);
      expect(
        await controller.importRules(
          imported,
          interfaceMapping: {'old-lan': 'en7'},
        ),
        0,
      );
      expect((await repo.load()), hasLength(1));
    },
  );
  test('invalid network mapping changes nothing', () async {
    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await expectLater(
      controller.importRules(
        [sampleRule()],
        interfaceMapping: {'old-lan': 'missing'},
      ),
      throwsArgumentError,
    );
    expect(controller.rules, isEmpty);
  });

  test('fresh DNS, enabled flags, multiple networks and existing rules survive import', () async {
    final platform = FakeNetworkPlatform(
      resolveMap: {
        'company.test': ['10.0.0.5'],
        'api.company.test': ['10.0.0.6'],
      },
    );
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.upsertRule(
      rawDestination: '192.0.2.1',
      interfaceId: 'en0',
    );
    final dynamicRule = sampleRule().copyWith(clearHostIpv4: true);
    final disabled = sampleRule().copyWith(
      interfaceId: 'other',
      enabled: false,
    );
    expect(
      await controller.importRules(
        [dynamicRule, dynamicRule, disabled],
        interfaceMapping: {'old-lan': 'en7', 'other': 'en0'},
        activate: true,
      ),
      2,
    );
    expect(controller.rules, hasLength(3));
    final imported = controller.rules[1];
    expect(imported.resolvedIps, ['10.0.0.5']);
    expect(imported.subRules.single.resolvedIps, ['10.0.0.6']);
    expect(imported.subRules.single.enabled, isFalse);
    expect(controller.rules[2].enabled, isFalse);
    expect(
      platform.managed.map((r) => r.destinationCidr),
      containsAll(['192.0.2.1/32', '10.0.0.5/32']),
    );
  });
  test('failed persistence leaves the visible rules intact', () async {
    final repo = FailingImportRepository();
    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: repo,
    );
    addTearDown(controller.dispose);
    await controller.start();
    repo.fail = true;
    await expectLater(
      controller.importRules(
        [sampleRule()],
        interfaceMapping: {'old-lan': 'en7'},
      ),
      throwsStateError,
    );
    expect(controller.rules, isEmpty);
    expect(await repo.load(), isEmpty);
  });
  test('invalid backup fields are rejected as a whole', () {
    final envelope = jsonDecode(transfer.encode([sampleRule()])) as Map;
    final rule = (envelope['rules'] as List).single as Map;
    final cases = [
      null,
      {...rule, 'destination': ''},
      {...rule, 'interface': 42},
      {...rule, 'label': 42},
      {...rule, 'enabled': 'yes'},
      {...rule, 'hostIpv4': 'invalid'},
      {...rule, 'dependencies': false},
      {
        ...rule,
        'dependencies': [false],
      },
      {
        ...rule,
        'dependencies': [
          {'destination': 'bad/path', 'enabled': true},
        ],
      },
      {
        ...rule,
        'dependencies': [
          {'destination': '10.0.0.0/8', 'enabled': true},
        ],
      },
      {
        ...rule,
        'dependencies': List.filled(2, {
          'destination': 'api.test',
          'enabled': true,
        }),
      },
      {
        ...rule,
        'dependencies': List.filled(257, {
          'destination': 'api.test',
          'enabled': true,
        }),
      },
    ];
    for (final value in cases) {
      expect(
        () => transfer.decode(
          jsonEncode({
            ...envelope,
            'rules': [rule, value],
          }),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => transfer.decode(' ' * (RulesTransfer.maxFileBytes + 1)),
      throwsFormatException,
    );
    expect(
      () => transfer.decode(
        jsonEncode({...envelope, 'rules': List.filled(1001, rule)}),
      ),
      throwsFormatException,
    );
    expect(transfer.decode(transfer.encode([])), isEmpty);
  });
}

class FailingImportRepository extends MemoryRulesRepository {
  bool fail = false;
  @override
  Future<void> save(List<RoutingRule> rules) async {
    if (fail) throw StateError("Disk full");
    await super.save(rules);
  }
}
