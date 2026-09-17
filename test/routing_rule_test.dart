import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';

void main() {
  test('legacy JSON defaults to no dependency scan or sub-rules', () {
    final rule = RoutingRule.fromJson({
      'id': 'legacy',
      'rawDestination': 'legacy.example.test',
      'kind': 'hostname',
      'normalizedDestination': 'legacy.example.test',
      'interfaceId': 'en7',
      'enabled': true,
      'resolvedIps': ['203.0.113.1'],
      'status': 'applied',
      'updatedAt': '2026-09-17T00:00:00.000Z',
    });

    expect(rule.subRules, isEmpty);
    expect(rule.dependencyScanStatus, DependencyScanStatus.notApplicable);
    expect(rule.dependencyScanError, isNull);
  });

  test('sub-rules and scan metadata survive JSON round trip', () {
    final original = RoutingRule(
      id: 'parent',
      rawDestination: 'https://example.test',
      kind: DestinationKind.url,
      normalizedDestination: 'example.test',
      interfaceId: 'en7',
      enabled: true,
      resolvedIps: const ['203.0.113.1'],
      status: RuleStatus.applied,
      updatedAt: DateTime.utc(2026, 9, 17),
      dependencyScanStatus: DependencyScanStatus.succeeded,
      subRules: const [
        RoutingSubRule(
          id: 'child',
          destination: 'api.example.test',
          kind: DestinationKind.hostname,
          enabled: false,
          resolvedIps: ['203.0.113.2'],
          status: RuleStatus.pending,
        ),
      ],
    );

    final restored = RoutingRule.fromJson(original.toJson());
    expect(restored.dependencyScanStatus, DependencyScanStatus.succeeded);
    expect(restored.subRules.single.id, 'child');
    expect(restored.subRules.single.enabled, isFalse);
    expect(restored.subRules.single.resolvedIps, ['203.0.113.2']);
  });
}
