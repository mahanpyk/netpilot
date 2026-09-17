import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/app_routing_rule.dart';

void main() {
  AppRoutingRule rule(String id) => AppRoutingRule(
    id: id,
    displayName: 'Browser $id',
    bundlePath: '/Applications/$id.app',
    bundleIdentifier: 'example.$id',
    signingIdentifier: 'example.$id',
    teamIdentifier: 'TEAM123',
    helperSigningIdentifiers: ['example.$id.helper'],
    interfaceId: 'en0',
    enabled: true,
    failurePolicy: AppRoutingFailurePolicy.block,
    updatedAt: DateTime.utc(2026),
  );

  test('round-trips new app rule JSON', () {
    final original = rule('one');
    final restored = AppRoutingRule.fromJson(original.toJson());

    expect(restored.signingIdentifier, original.signingIdentifier);
    expect(restored.teamIdentifier, 'TEAM123');
    expect(restored.helperSigningIdentifiers, ['example.one.helper']);
    expect(restored.failurePolicy, AppRoutingFailurePolicy.block);
  });

  test('configuration hash ignores rule order and runtime status', () {
    final a = rule('a');
    final b = rule('b');
    final first = AppRoutingConfiguration(masterEnabled: true, rules: [a, b]);
    final second = AppRoutingConfiguration(
      masterEnabled: true,
      rules: [
        b.copyWith(status: AppRoutingRuleStatus.error, lastError: 'runtime'),
        a,
      ],
    );

    expect(first.hash, second.hash);
    expect(first.hash.length, 64);
    expect(
      first.hash,
      isNot(AppRoutingConfiguration(masterEnabled: false, rules: [a, b]).hash),
    );
  });

  test('old JSON falls back to bundle identifier as signing identifier', () {
    final restored = AppRoutingRule.fromJson({
      'id': 'legacy',
      'bundleIdentifier': 'example.legacy',
      'interfaceId': 'en0',
      'enabled': true,
    });

    expect(restored.signingIdentifier, 'example.legacy');
    expect(restored.failurePolicy, AppRoutingFailurePolicy.block);
  });
}
