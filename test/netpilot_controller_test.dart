import 'dart:async';

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

  test('unresolved URL saves without an HTTP dependency scan', () async {
    final scanner = FakeDependencyScanner([]);
    final repo = MemoryRulesRepository();
    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: repo,
      dependencyScanner: scanner,
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: 'https://unknown.company.local',
      interfaceId: 'en7',
    );

    final rule = controller.rules.single;
    expect(rule.status, RuleStatus.unresolved);
    expect(rule.lastError, contains('LAN DNS'));
    expect(rule.dependencyScanStatus, DependencyScanStatus.failed);
    expect(rule.dependencyScanError, contains('Scan skipped'));
    expect(scanner.scanCount, 0);
    expect(
      (await repo.load()).single.normalizedDestination,
      'unknown.company.local',
    );
  });

  test('DNS timeout saves unresolved and ignores a late response', () async {
    final platform = StalledResolutionPlatform();
    final scanner = FakeDependencyScanner([]);
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
      dependencyScanner: scanner,
      resolutionTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    await controller.start();
    await controller.upsertRule(
      rawDestination: 'https://unknown.company.local',
      interfaceId: 'en7',
    );

    expect(controller.rules.single.status, RuleStatus.unresolved);
    expect(scanner.scanCount, 0);
    platform.response.complete(const ResolveHostResult(ips: ['10.0.0.4']));
    await Future<void>.delayed(Duration.zero);
    expect(controller.rules.single.resolvedIps, isEmpty);
    expect(platform.managed, isEmpty);
  });

  for (final failScan in [false, true]) {
    test(
      'delete during scan cannot restore a rule (failure=$failScan)',
      () async {
        final scanner = DeferredDependencyScanner();
        final platform = FakeNetworkPlatform();
        final repo = MemoryRulesRepository();
        final controller = NetPilotController(
          platform: platform,
          rulesRepository: repo,
          dependencyScanner: scanner,
        );
        addTearDown(controller.dispose);
        await controller.start();
        final saving = controller.upsertRule(
          rawDestination: 'https://lan.example.test',
          interfaceId: 'en7',
          hostIpv4: '10.0.0.1',
        );
        await scanner.started.future;
        await controller.deleteRule(controller.rules.single.id);
        scanner.complete(fail: failScan);
        await saving;

        expect(controller.rules, isEmpty);
        expect(await repo.load(), isEmpty);
        expect(platform.managed, isEmpty);
        expect(platform.managedHostMappings, isEmpty);
      },
    );

    test('disable during scan stays disabled (failure=$failScan)', () async {
      final scanner = DeferredDependencyScanner();
      final platform = FakeNetworkPlatform();
      final repo = MemoryRulesRepository();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: repo,
        dependencyScanner: scanner,
      );
      addTearDown(controller.dispose);
      await controller.start();
      final saving = controller.upsertRule(
        rawDestination: 'https://lan.example.test',
        interfaceId: 'en7',
        hostIpv4: '10.0.0.1',
      );
      await scanner.started.future;
      await controller.setRuleEnabled(controller.rules.single.id, false);
      scanner.complete(fail: failScan);
      await saving;

      expect(controller.rules.single.enabled, isFalse);
      expect((await repo.load()).single.enabled, isFalse);
      expect(platform.managed, isEmpty);
      expect(platform.managedHostMappings, isEmpty);
    });
  }

  test('older pending DNS edit cannot overwrite a newer save', () async {
    final platform = StalledResolutionPlatform();
    final scanner = FakeDependencyScanner([]);
    final controller = NetPilotController(
      platform: platform,
      rulesRepository: MemoryRulesRepository(),
      dependencyScanner: scanner,
    );
    addTearDown(controller.dispose);
    await controller.start();
    await controller.upsertRule(rawDestination: '10.0.0.1', interfaceId: 'en7');
    final id = controller.rules.single.id;
    final olderSave = controller.upsertRule(
      id: id,
      rawDestination: 'https://old.example.test',
      interfaceId: 'en7',
    );
    await controller.upsertRule(
      id: id,
      rawDestination: '10.0.0.2',
      interfaceId: 'en7',
    );
    platform.response.complete(const ResolveHostResult(ips: ['10.0.0.3']));
    await olderSave;

    expect(controller.rules.single.rawDestination, '10.0.0.2');
    expect(platform.managed.single.destinationCidr, '10.0.0.2/32');
    expect(scanner.scanCount, 0);
  });

  test(
    'blank pin refreshes LAN DNS without resolving its old hosts entry',
    () async {
      final platform = HostsAwareResolutionPlatform();
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
      final id = controller.rules.single.id;
      await controller.upsertRule(
        rawDestination: 'other.example.test',
        interfaceId: 'en7',
        hostIpv4: '10.0.0.5',
      );
      platform.resolveMap = {
        'lan.example.test': ['10.0.0.2'],
      };
      await controller.upsertRule(
        id: id,
        rawDestination: 'lan.example.test',
        interfaceId: 'en7',
        manageHostname: true,
      );

      expect(controller.rules.first.hostIpv4, '10.0.0.2');
      expect(platform.managedHostMappings.map((mapping) => mapping.ipv4), [
        '10.0.0.2',
        '10.0.0.5',
      ]);
      expect(platform.mappingsAtLookup.map((mapping) => mapping.host), [
        'other.example.test',
      ]);
    },
  );

  test('failed LAN DNS refresh restores the current saved mapping', () async {
    final platform = HostsAwareResolutionPlatform();
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
    platform.failDns = true;
    await expectLater(
      controller.upsertRule(
        id: controller.rules.single.id,
        rawDestination: 'lan.example.test',
        interfaceId: 'en7',
        manageHostname: true,
      ),
      throwsA(isA<StateError>()),
    );

    expect(controller.rules.single.hostIpv4, '10.0.0.1');
    expect(platform.managedHostMappings.single.ipv4, '10.0.0.1');
    expect(platform.managed.single.destinationCidr, '10.0.0.1/32');
  });

  test(
    'delete during pin refresh does not restore the deleted mapping',
    () async {
      final platform = HostsAwareResolutionPlatform();
      final repo = MemoryRulesRepository();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: repo,
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.upsertRule(
        rawDestination: 'lan.example.test',
        interfaceId: 'en7',
        hostIpv4: '10.0.0.1',
      );
      final id = controller.rules.single.id;
      platform.deferredDns = Completer<ResolveHostResult>();
      platform.lookupStarted = Completer<void>();
      final refreshing = controller.upsertRule(
        id: id,
        rawDestination: 'lan.example.test',
        interfaceId: 'en7',
        manageHostname: true,
      );
      await platform.lookupStarted!.future;
      await controller.deleteRule(id);
      platform.deferredDns!.complete(
        const ResolveHostResult(ips: ['10.0.0.2']),
      );
      await refreshing;

      expect(controller.rules, isEmpty);
      expect(await repo.load(), isEmpty);
      expect(platform.managedHostMappings, isEmpty);
      expect(platform.managed, isEmpty);
    },
  );

  test(
    'private discovered host mappings follow child and parent toggles',
    () async {
      final platform = FakeNetworkPlatform(
        resolveMap: {
          'api.example.test': ['10.0.0.2'],
          'public.example.test': ['203.0.113.4'],
        },
      );
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: MemoryRulesRepository(),
        dependencyScanner: FakeDependencyScanner([
          'api.example.test',
          'public.example.test',
        ]),
      );
      addTearDown(controller.dispose);
      await controller.start();
      await controller.upsertRule(
        rawDestination: 'https://lan.example.test',
        interfaceId: 'en7',
        hostIpv4: '10.0.0.1',
      );
      final rule = controller.rules.single;
      expect(platform.managedHostMappings.map((mapping) => mapping.host), [
        'lan.example.test',
        'api.example.test',
      ]);
      await controller.setSubRuleEnabled(
        rule.id,
        rule.subRules.first.id,
        false,
      );
      expect(platform.managedHostMappings.single.host, 'lan.example.test');
      await controller.setSubRuleEnabled(rule.id, rule.subRules.first.id, true);
      expect(platform.managedHostMappings, hasLength(2));
      await controller.setRuleEnabled(rule.id, false);
      expect(platform.managedHostMappings, isEmpty);
    },
  );

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

class StalledResolutionPlatform extends FakeNetworkPlatform {
  final response = Completer<ResolveHostResult>();

  @override
  Future<ResolveHostResult> resolveHost(String host, {String? interfaceId}) =>
      response.future;
}

class DeferredDependencyScanner implements DependencyScanner {
  final started = Completer<void>();
  final response = Completer<DependencyScanResult>();

  @override
  Future<DependencyScanResult> scan(Uri uri) {
    started.complete();
    return response.future;
  }

  void complete({required bool fail}) {
    if (fail) {
      response.completeError(
        const DependencyScanException('Scan failed'),
        StackTrace.current,
      );
    } else {
      response.complete(
        DependencyScanResult(
          destinations: const [],
          finalUri: Uri.parse('https://lan.example.test'),
        ),
      );
    }
  }
}

class HostsAwareResolutionPlatform extends FakeNetworkPlatform {
  bool failDns = false;
  Completer<ResolveHostResult>? deferredDns;
  Completer<void>? lookupStarted;
  List<HostMapping> mappingsAtLookup = [];

  @override
  Future<ResolveHostResult> resolveHost(
    String host, {
    String? interfaceId,
  }) async {
    mappingsAtLookup = List.of(managedHostMappings);
    if (deferredDns != null) {
      lookupStarted?.complete();
      return deferredDns!.future;
    }
    if (failDns) throw StateError('LAN DNS unavailable');
    final local = managedHostMappings
        .where((mapping) => mapping.host == host)
        .firstOrNull;
    if (local != null) return ResolveHostResult(ips: [local.ipv4]);
    return super.resolveHost(host, interfaceId: interfaceId);
  }
}
