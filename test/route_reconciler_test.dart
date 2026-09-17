import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';
import 'package:netpilot_desktop/core/utils/route_reconciler.dart';

void main() {
  const reconciler = RouteReconciler();

  test('diff computes add/remove', () {
    final desired = [
      const DesiredRoute(
        destinationCidr: '10.0.0.1/32',
        interfaceName: 'en7',
        ruleId: 'a',
        gateway: '10.0.0.1',
      ),
      const DesiredRoute(
        destinationCidr: '10.0.0.2/32',
        interfaceName: 'en7',
        ruleId: 'a',
        gateway: '10.0.0.1',
      ),
    ];
    final current = [
      desired[0],
      const DesiredRoute(
        destinationCidr: '10.0.0.9/32',
        interfaceName: 'en7',
        ruleId: 'b',
        gateway: '10.0.0.1',
      ),
    ];
    final diff = reconciler.diff(desired: desired, current: current);
    expect(diff.toAdd.map((e) => e.destinationCidr), ['10.0.0.2/32']);
    expect(diff.toRemove.map((e) => e.destinationCidr), ['10.0.0.9/32']);
    expect(diff.unchanged.length, 1);
  });

  test('desiredFromRules expands hostnames and skips disabled', () {
    final rules = [
      RoutingRule(
        id: '1',
        rawDestination: 'foo',
        kind: DestinationKind.hostname,
        normalizedDestination: 'foo',
        interfaceId: 'en7',
        enabled: true,
        resolvedIps: const ['1.1.1.1', '1.0.0.1'],
        status: RuleStatus.pending,
        updatedAt: DateTime(2026),
      ),
      RoutingRule(
        id: '2',
        rawDestination: '10.0.0.0/8',
        kind: DestinationKind.cidr,
        normalizedDestination: '10.0.0.0/8',
        interfaceId: 'en7',
        enabled: false,
        resolvedIps: const [],
        status: RuleStatus.pending,
        updatedAt: DateTime(2026),
      ),
    ];
    final desired = reconciler.desiredFromRules(
      rules,
      gatewayFor: (_) => '10.0.0.1',
    );
    expect(desired.length, 2);
    expect(desired.map((e) => e.destinationCidr).toSet(), {
      '1.1.1.1/32',
      '1.0.0.1/32',
    });
  });

  test('plan de-duplicates equivalent parent and sub-rule routes', () {
    final rules = [
      RoutingRule(
        id: 'parent',
        rawDestination: 'https://example.test',
        kind: DestinationKind.url,
        normalizedDestination: 'example.test',
        interfaceId: 'en7',
        enabled: true,
        resolvedIps: const ['203.0.113.10'],
        status: RuleStatus.pending,
        updatedAt: DateTime(2026),
        subRules: const [
          RoutingSubRule(
            id: 'child',
            destination: 'api.example.test',
            kind: DestinationKind.hostname,
            enabled: true,
            resolvedIps: ['203.0.113.10'],
            status: RuleStatus.pending,
          ),
        ],
      ),
    ];

    final plan = reconciler.planFromRules(rules, gatewayFor: (_) => '10.0.0.1');

    expect(plan.routes, hasLength(1));
    expect(plan.routes.single.destinationCidr, '203.0.113.10/32');
    expect(plan.hasConflicts, isFalse);
  });

  test(
    'plan blocks an exact destination requested via different interfaces',
    () {
      RoutingRule rule(String id, String interface) => RoutingRule(
        id: id,
        rawDestination: '$id.example.test',
        kind: DestinationKind.hostname,
        normalizedDestination: '$id.example.test',
        interfaceId: interface,
        enabled: true,
        resolvedIps: const ['203.0.113.50'],
        status: RuleStatus.pending,
        updatedAt: DateTime(2026),
      );

      final plan = reconciler.planFromRules(
        [rule('one', 'en7'), rule('two', 'en8')],
        gatewayFor: (rule) =>
            rule.interfaceId == 'en7' ? '10.0.0.1' : '192.168.8.1',
      );

      expect(plan.routes, isEmpty);
      expect(plan.conflictsByRuleId.keys, containsAll(['one', 'two']));
      expect(
        plan.conflictsByRuleId['one']!.single,
        contains('203.0.113.50/32'),
      );
    },
  );
}
