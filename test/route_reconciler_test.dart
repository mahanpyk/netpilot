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
    expect(desired.map((e) => e.destinationCidr), ['1.1.1.1/32', '1.0.0.1/32']);
  });
}
