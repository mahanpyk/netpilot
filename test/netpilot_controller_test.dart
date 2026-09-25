import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/models/routing_rule.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/core/utils/dependency_scanner.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';

void main() {
  test('apply result decodes browser reconnect diagnostics', () {
    final result = ApplyRoutesResult.fromMap({
      'ok': true,
      'added': 1,
      'removed': 0,
      'errors': <String>[],
      'connectionResetDestinations': ['203.0.113.44/32'],
      'restartedProcesses': [
        {'pid': 424, 'name': 'Google Chrome Helper'},
      ],
    });

    expect(result.connectionResetDestinations, ['203.0.113.44/32']);
    expect(result.restartedProcesses.single.pid, 424);
    expect(result.restartedProcesses.single.name, 'Google Chrome Helper');
  });

  test('URL save discovers, resolves, and applies sub-rules', () async {
    final scanner = FakeDependencyScanner([
      'api.company.local',
      '203.0.113.20',
    ]);
    final platform = FakeNetworkPlatform(
      resolveMap: {
        'intranet.company.local': ['10.10.1.5'],
        'api.company.local': ['10.10.1.6'],
      },
    );
    final repo = MemoryRulesRepository();
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: repo,
      dependencyScanner: scanner,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: 'https://intranet.company.local/wiki',
      interfaceId: 'en7',
      label: 'Wiki',
    );

    final rule = controller.rules.single;
    expect(rule.normalizedDestination, 'intranet.company.local');
    expect(rule.dependencyScanStatus, DependencyScanStatus.succeeded);
    expect(rule.subRules.map((subRule) => subRule.destination), [
      'api.company.local',
      '203.0.113.20',
    ]);
    expect(rule.subRules.first.resolvedIps, ['10.10.1.6']);
    expect(rule.subRules.every((subRule) => subRule.enabled), isTrue);
    expect(platform.managed.map((route) => route.destinationCidr).toSet(), {
      '10.10.1.5/32',
      '10.10.1.6/32',
      '203.0.113.20/32',
    });
    expect(scanner.scanCount, 1);
  });

  test('scan failure keeps and applies only the parent rule', () async {
    final scanner = FakeDependencyScanner(
      const [],
      error: const DependencyScanException('Page unavailable'),
    );
    final platform = FakeNetworkPlatform(
      resolveMap: {
        'intranet.company.local': ['10.10.1.5'],
      },
    );
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
      dependencyScanner: scanner,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: 'https://intranet.company.local/wiki',
      interfaceId: 'en7',
    );

    final rule = controller.rules.single;
    expect(rule.dependencyScanStatus, DependencyScanStatus.failed);
    expect(rule.dependencyScanError, 'Page unavailable');
    expect(rule.subRules, isEmpty);
    expect(platform.managed.single.destinationCidr, '10.10.1.5/32');
  });

  test('resave preserves toggles and DNS refresh does not rescan', () async {
    final scanner = FakeDependencyScanner(['api.company.local']);
    final platform = FakeNetworkPlatform(
      resolveMap: {
        'intranet.company.local': ['10.10.1.5'],
        'api.company.local': ['10.10.1.6'],
        'cdn.company.local': ['10.10.1.7'],
      },
    );
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
      dependencyScanner: scanner,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: 'https://intranet.company.local/wiki',
      interfaceId: 'en7',
    );
    final original = controller.rules.single;
    final originalSubRule = original.subRules.single;
    await controller.setSubRuleEnabled(original.id, originalSubRule.id, false);

    scanner.destinations = ['api.company.local', 'cdn.company.local'];
    await controller.upsertRule(
      id: original.id,
      rawDestination: original.rawDestination,
      interfaceId: 'en7',
    );

    final saved = controller.rules.single;
    final preserved = saved.subRules.firstWhere(
      (subRule) => subRule.destination == 'api.company.local',
    );
    expect(preserved.id, originalSubRule.id);
    expect(preserved.enabled, isFalse);
    expect(
      saved.subRules
          .firstWhere((subRule) => subRule.destination == 'cdn.company.local')
          .enabled,
      isTrue,
    );
    expect(scanner.scanCount, 2);

    await controller.refreshResolutions();
    expect(scanner.scanCount, 2);

    await controller.setRuleEnabled(saved.id, false);
    expect(platform.managed, isEmpty);
    await controller.setRuleEnabled(saved.id, true);
    expect(platform.managed.map((route) => route.destinationCidr).toSet(), {
      '10.10.1.5/32',
      '10.10.1.7/32',
    });
    await controller.deleteRule(saved.id);
    expect(platform.managed, isEmpty);
  });

  test('kernel route verification failure is shown on the rule', () async {
    final controller = NetPilotController(
      platform: FailingVerificationPlatform(),
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: '203.0.113.44',
      interfaceId: 'en7',
    );

    expect(controller.rules.single.status, RuleStatus.error);
    expect(controller.rules.single.lastError, contains('actual utun6'));
    expect(controller.routeDiagnostics.join('\n'), contains('203.0.113.44/32'));
    expect(controller.routeDiagnostics.join('\n'), contains('✗'));
  });

  test('a failed de-duplicated route marks every owning rule', () async {
    final controller = NetPilotController(
      platform: FailingVerificationPlatform(),
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: '203.0.113.44',
      interfaceId: 'en7',
      label: 'First',
    );
    await controller.upsertRule(
      rawDestination: '203.0.113.44',
      interfaceId: 'en7',
      label: 'Second',
    );

    expect(controller.rules, hasLength(2));
    expect(
      controller.rules.every((rule) => rule.status == RuleStatus.error),
      isTrue,
    );
  });
}

class FailingVerificationPlatform extends FakeNetworkPlatform {
  @override
  Future<ApplyRoutesResult> reconcileRoutes(List<DesiredRoute> desired) async {
    if (desired.isEmpty) {
      return const ApplyRoutesResult(
        ok: true,
        added: 0,
        removed: 0,
        errors: [],
      );
    }
    final route = desired.single;
    return ApplyRoutesResult(
      ok: false,
      added: 1,
      removed: 0,
      errors: const ['route verification failed'],
      routeChecks: [
        RouteCheckResult(
          destination: route.destinationCidr,
          expectedInterface: route.interfaceName,
          expectedGateway: route.gateway,
          actualInterface: 'utun6',
          actualGateway: '192.0.2.1',
          verified: false,
          message:
              'route ${route.destinationCidr} expected ${route.interfaceName}, actual utun6',
        ),
      ],
    );
  }
}

class FakeDependencyScanner implements DependencyScanner {
  FakeDependencyScanner(this.destinations, {this.error});

  List<String> destinations;
  Object? error;
  int scanCount = 0;

  @override
  Future<DependencyScanResult> scan(Uri uri) async {
    scanCount += 1;
    final failure = error;
    if (failure != null) throw failure;
    return DependencyScanResult(
      destinations: List.of(destinations),
      finalUri: uri,
    );
  }
}
