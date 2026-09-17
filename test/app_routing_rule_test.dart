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
    expect(restored.platform, AppRoutingHostPlatform.macos);
  });

  test('round-trips Windows path identity and reviewed helpers', () {
    final windows = AppRoutingRule(
      id: 'windows-browser',
      displayName: 'Browser.exe',
      bundlePath: r'C:\Program Files\Browser\Browser.exe',
      bundleIdentifier: '',
      signingIdentifier: '',
      teamIdentifier: '',
      platform: AppRoutingHostPlatform.windows,
      executablePath: r'C:\Program Files\Browser\Browser.exe',
      wfpAppId: 'aabbcc',
      publisher: 'Example Corp',
      isSigned: true,
      helperExecutables: const [
        AppExecutableIdentity(
          path: r'C:\Program Files\Browser\helper.exe',
          wfpAppId: 'ddeeff',
          publisher: 'Example Corp',
          isSigned: true,
          enabled: false,
        ),
      ],
      interfaceId: '123456',
      enabled: true,
      failurePolicy: AppRoutingFailurePolicy.fallback,
      updatedAt: DateTime.utc(2026),
    );

    final restored = AppRoutingRule.fromJson(windows.toJson());
    expect(restored.platform, AppRoutingHostPlatform.windows);
    expect(restored.wfpAppId, 'aabbcc');
    expect(restored.helperExecutables.single.enabled, isFalse);
    expect(restored.allIdentityKeys, {'aabbcc'});
    expect(
      windows.toProviderJson()['helperExecutables'],
      isEmpty,
      reason: 'disabled helper candidates must not reach the service',
    );
  });

  test('Windows configuration hash ignores helper discovery order', () {
    const firstHelper = AppExecutableIdentity(
      path: r'C:\Browser\a.exe',
      wfpAppId: 'aa',
    );
    const secondHelper = AppExecutableIdentity(
      path: r'C:\Browser\b.exe',
      wfpAppId: 'bb',
    );
    AppRoutingRule windows(List<AppExecutableIdentity> helpers) =>
        AppRoutingRule(
          id: 'browser',
          displayName: 'Browser',
          bundlePath: r'C:\Browser\browser.exe',
          bundleIdentifier: '',
          signingIdentifier: '',
          teamIdentifier: '',
          platform: AppRoutingHostPlatform.windows,
          executablePath: r'C:\Browser\browser.exe',
          wfpAppId: 'main',
          helperExecutables: helpers,
          interfaceId: '123',
          enabled: true,
          failurePolicy: AppRoutingFailurePolicy.block,
          updatedAt: DateTime.utc(2026),
        );

    expect(
      AppRoutingConfiguration(
        masterEnabled: true,
        rules: [
          windows([firstHelper, secondHelper]),
        ],
      ).hash,
      AppRoutingConfiguration(
        masterEnabled: true,
        rules: [
          windows([secondHelper, firstHelper]),
        ],
      ).hash,
    );
  });
}
