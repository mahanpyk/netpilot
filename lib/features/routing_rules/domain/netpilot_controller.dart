import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/network_interface_info.dart';
import '../../../core/models/routing_rule.dart';
import '../../../core/platform/network_platform.dart';
import '../../../core/utils/dependency_scanner.dart';
import '../../../core/utils/destination_parser.dart';
import '../../../core/utils/route_reconciler.dart';
import '../data/rules_repository.dart';

class NetPilotController extends ChangeNotifier {
  NetPilotController({
    required this._platform,
    required this._rulesRepository,
    DestinationParser? parser,
    RouteReconciler? reconciler,
    DependencyScanner? dependencyScanner,
    this._resolutionTimeout = const Duration(seconds: 10),
    Uuid? uuid,
  }) : _parser = parser ?? const DestinationParser(),
       _reconciler = reconciler ?? const RouteReconciler(),
       _dependencyScanner = dependencyScanner ?? HttpDependencyScanner(),
       _uuid = uuid ?? const Uuid();

  final NetworkPlatform _platform;
  final RulesRepository _rulesRepository;
  final DestinationParser _parser;
  final RouteReconciler _reconciler;
  final DependencyScanner _dependencyScanner;
  final Uuid _uuid;
  final Duration _resolutionTimeout;
  final Map<String, Object> _ruleSaveOperations = {};

  List<NetworkInterfaceInfo> _interfaces = [];
  List<RoutingRule> _rules = [];
  HelperStatus _helperStatus = const HelperStatus(
    installed: false,
    enabled: false,
    status: 'unknown',
  );
  bool _loading = true;
  bool _busy = false;
  String? _bannerError;
  List<String> _routeDiagnostics = const [];
  StreamSubscription<void>? _networkSub;

  List<NetworkInterfaceInfo> get interfaces => List.unmodifiable(_interfaces);
  List<RoutingRule> get rules => List.unmodifiable(_rules);
  HelperStatus get helperStatus => _helperStatus;
  bool get loading => _loading;
  bool get busy => _busy;
  bool get supportsHostMappings => _platform.supportsHostMappings;
  String? get bannerError => _bannerError;
  List<String> get routeDiagnostics => List.unmodifiable(_routeDiagnostics);

  List<NetworkInterfaceInfo> get activeInterfaces =>
      _interfaces.where((i) => i.isActive).toList();

  Future<void> start() async {
    _loading = true;
    notifyListeners();
    try {
      _rules = await _rulesRepository.load();
      await refreshInterfaces();
      await refreshHelperStatus();
      _networkSub ??= _platform.interfacesChanged.listen((_) async {
        await refreshInterfaces();
        await applyAll();
      });
      await applyAll();
    } catch (e) {
      _bannerError = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _ruleSaveOperations.clear();
    _networkSub?.cancel();
    super.dispose();
  }

  Future<void> refreshInterfaces() async {
    _interfaces = await _platform.listInterfaces();
    notifyListeners();
  }

  Future<void> refreshHelperStatus() async {
    _helperStatus = await _platform.getHelperStatus();
    notifyListeners();
  }

  Future<void> installHelper() async {
    _busy = true;
    notifyListeners();
    var shouldApply = false;
    try {
      _helperStatus = await _platform.installHelper();
      shouldApply = _helperStatus.enabled;
      _bannerError = _helperStatus.enabled
          ? null
          : (_helperStatus.message ??
                'Helper not enabled. Approve Login Items in System Settings.');
    } catch (e) {
      _bannerError = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
    if (shouldApply) {
      await applyAll();
    }
  }

  ParsedDestination previewDestination(String input) => _parser.parse(input);

  Future<List<String>> resolvePreview(
    String host, {
    String? interfaceId,
  }) async {
    final result = await _resolveHost(host, interfaceId: interfaceId);
    return result.ips;
  }

  Future<void> upsertRule({
    String? id,
    required String rawDestination,
    required String interfaceId,
    String? label,
    bool enabled = true,
    String? hostIpv4,
    bool manageHostname = false,
  }) async {
    final parsed = _parser.parse(rawDestination);
    final isHostname =
        (parsed.kind == DestinationKind.hostname ||
            parsed.kind == DestinationKind.url) &&
        !_parser.isIpv4(parsed.normalized);
    var pinnedIp = hostIpv4?.trim();
    if (pinnedIp?.isEmpty == true) pinnedIp = null;
    if (pinnedIp != null) {
      if (!supportsHostMappings || !isHostname || !_parser.isIpv4(pinnedIp)) {
        throw DestinationParseException(
          'Enter a valid LAN IPv4 for a hostname or URL on macOS.',
        );
      }
      pinnedIp = pinnedIp.split('.').map(int.parse).join('.');
    }
    final ruleId = id ?? _uuid.v4();
    final operation = Object();
    _ruleSaveOperations[ruleId] = operation;
    final initialRule = _rules.where((rule) => rule.id == ruleId).firstOrNull;
    bool isCurrentSave() => identical(_ruleSaveOperations[ruleId], operation);
    RoutingRule? currentRule() => isCurrentSave()
        ? _rules.where((rule) => rule.id == ruleId).firstOrNull
        : null;

    List<String> ips = [];
    var status = RuleStatus.pending;
    String? error;

    if (pinnedIp != null) {
      ips = [pinnedIp];
    } else if (parsed.kind == DestinationKind.hostname ||
        parsed.kind == DestinationKind.url) {
      final refreshPinnedMapping =
          manageHostname &&
          supportsHostMappings &&
          initialRule?.hostIpv4 != null;
      try {
        if (refreshPinnedMapping) {
          // Do not resolve our own old hosts override when the editor requests
          // a fresh LAN DNS answer. Preserve every other live rule's mappings.
          await _reconcileManagedHostMappings(excludingRuleId: ruleId);
          if (!isCurrentSave()) return;
        }
        final resolved = await _resolveHost(
          parsed.normalized,
          interfaceId: interfaceId,
        );
        ips = resolved.ips;
      } finally {
        if (refreshPinnedMapping) {
          // Use current state, including deletions/toggles/newer saves that may
          // have happened during DNS. The normal apply publishes the new pin.
          await _reconcileManagedHostMappings();
        }
      }
      if (ips.isEmpty) {
        status = RuleStatus.unresolved;
        error = _resolutionError(parsed.normalized);
      }
    } else if (parsed.kind == DestinationKind.ipv4) {
      ips = [parsed.normalized];
    }

    // A newer edit or deletion may finish while this save waits for DNS.
    if (!isCurrentSave() || (initialRule != null && currentRule() == null)) {
      return;
    }

    // Snapshot a single private LAN answer for system/browser resolution.
    // Public DNS answers remain dynamic unless an explicit override was entered.
    if (pinnedIp == null &&
        manageHostname &&
        supportsHostMappings &&
        isHostname &&
        ips.length == 1 &&
        _isPrivateIpv4(ips.single)) {
      pinnedIp = ips.single;
    }

    final existingIndex = id == null
        ? -1
        : _rules.indexWhere((r) => r.id == id);
    final existingRule = existingIndex < 0 ? null : _rules[existingIndex];
    final scansDependencies = parsed.kind == DestinationKind.url;
    final rule = RoutingRule(
      id: ruleId,
      label: label,
      rawDestination: rawDestination.trim(),
      kind: parsed.kind,
      normalizedDestination: parsed.normalized,
      interfaceId: interfaceId,
      enabled:
          initialRule != null && currentRule()?.enabled != initialRule.enabled
          ? currentRule()!.enabled
          : enabled,
      resolvedIps: ips,
      status: status,
      lastError: error,
      hostIpv4: pinnedIp,
      updatedAt: DateTime.now(),
      subRules: const [],
      dependencyScanStatus: !scansDependencies
          ? DependencyScanStatus.notApplicable
          : ips.isEmpty
          ? DependencyScanStatus.failed
          : DependencyScanStatus.pending,
      dependencyScanError: scansDependencies && ips.isEmpty
          ? 'Scan skipped: ${_resolutionError(parsed.normalized)} Save again after fixing name resolution.'
          : null,
    );

    await _replaceRule(rule, existingIndex: existingIndex);
    if (currentRule() == null) return;
    // Apply the parent first so the page and same-origin scripts are fetched
    // over the interface selected for this rule.
    await applyAll();

    // A scan cannot reach an unresolved parent, and retrying system HTTP DNS
    // here used to add another long wait after the native lookup failed.
    if (!scansDependencies || ips.isEmpty) return;
    final appliedParent = currentRule();
    if (appliedParent == null) return;
    if (appliedParent.status != RuleStatus.applied) {
      await _replaceRule(
        appliedParent.copyWith(
          dependencyScanStatus: DependencyScanStatus.failed,
          dependencyScanError:
              'Scan skipped: ${appliedParent.lastError ?? 'parent route was not applied'}.',
        ),
      );
      return;
    }

    try {
      final result = await _dependencyScanner.scan(
        Uri.parse(rule.rawDestination),
      );
      if (currentRule() == null) return;
      final previousByDestination = {
        for (final subRule
            in existingRule?.subRules ?? const <RoutingSubRule>[])
          subRule.destination: subRule,
      };
      final subRules = await _resolveDependencies(
        result.destinations,
        interfaceId: interfaceId,
        previousByDestination: previousByDestination,
      );
      final liveRule = currentRule();
      if (liveRule == null) return;
      final scannedRule = liveRule.copyWith(
        subRules: subRules,
        dependencyScanStatus: DependencyScanStatus.succeeded,
        clearDependencyScanError: true,
        updatedAt: DateTime.now(),
      );
      debugPrint(
        '[NetPilot] Dependency scan: url=${rule.rawDestination} '
        'finalUrl=${result.finalUri} dependencies=${result.destinations}',
      );
      await _replaceRule(scannedRule);
      if (currentRule() == null) return;
      await applyAll();
    } catch (error, stackTrace) {
      final liveRule = currentRule();
      if (liveRule == null) return;
      final message = error is DependencyScanException
          ? error.message
          : error.toString();
      debugPrint(
        '[NetPilot] Dependency scan failed: url=${rule.rawDestination} error=$message',
      );
      debugPrintStack(stackTrace: stackTrace);
      final failedRule = liveRule.copyWith(
        subRules: const [],
        dependencyScanStatus: DependencyScanStatus.failed,
        dependencyScanError: message,
        updatedAt: DateTime.now(),
      );
      await _replaceRule(failedRule);
      if (currentRule() == null) return;
      await applyAll();
    }
  }

  Future<void> setSubRuleEnabled(
    String ruleId,
    String subRuleId,
    bool enabled,
  ) async {
    final index = _rules.indexWhere((rule) => rule.id == ruleId);
    if (index < 0) return;
    final rule = _rules[index];
    final subRules = rule.subRules.map((subRule) {
      if (subRule.id != subRuleId) return subRule;
      return subRule.copyWith(
        enabled: enabled,
        status: RuleStatus.pending,
        clearLastError: true,
      );
    }).toList();
    _rules = List.of(_rules)
      ..[index] = rule.copyWith(subRules: subRules, updatedAt: DateTime.now());
    await _rulesRepository.save(_rules);
    notifyListeners();
    await applyAll();
  }

  Future<void> setRuleEnabled(String id, bool enabled) async {
    final index = _rules.indexWhere((r) => r.id == id);
    if (index < 0) return;
    _rules = List.of(_rules)
      ..[index] = _rules[index].copyWith(
        enabled: enabled,
        updatedAt: DateTime.now(),
        status: RuleStatus.pending,
      );
    await _rulesRepository.save(_rules);
    notifyListeners();
    await applyAll();
  }

  Future<void> deleteRule(String id) async {
    _ruleSaveOperations.remove(id);
    _rules = _rules.where((r) => r.id != id).toList();
    await _rulesRepository.save(_rules);
    notifyListeners();
    await applyAll();
  }

  Future<void> refreshResolutions() async {
    final next = <RoutingRule>[];
    for (final rule in _rules) {
      RoutingRule refreshedRule;
      if (rule.hostIpv4 != null) {
        refreshedRule = rule.copyWith(
          resolvedIps: [rule.hostIpv4!],
          status: RuleStatus.pending,
          clearLastError: true,
          updatedAt: DateTime.now(),
        );
      } else if (rule.kind == DestinationKind.hostname ||
          rule.kind == DestinationKind.url) {
        final resolved = await _resolveHost(
          rule.normalizedDestination,
          interfaceId: rule.interfaceId,
        );
        refreshedRule = rule.copyWith(
          resolvedIps: resolved.ips,
          status: resolved.ips.isEmpty
              ? RuleStatus.unresolved
              : RuleStatus.pending,
          lastError: resolved.ips.isEmpty
              ? _resolutionError(rule.normalizedDestination)
              : null,
          clearLastError: resolved.ips.isNotEmpty,
          updatedAt: DateTime.now(),
        );
      } else {
        refreshedRule = rule;
      }
      final refreshedSubRules = <RoutingSubRule>[];
      for (final subRule in refreshedRule.subRules) {
        refreshedSubRules.add(
          await _refreshSubRule(subRule, interfaceId: rule.interfaceId),
        );
      }
      next.add(refreshedRule.copyWith(subRules: refreshedSubRules));
    }
    _rules = next;
    await _rulesRepository.save(_rules);
    notifyListeners();
    await applyAll();
  }

  Future<void> applyAll() async {
    _busy = true;
    notifyListeners();
    try {
      await refreshHelperStatus();
      final hostMappings = _desiredHostMappings();
      await _reconcileManagedHostMappings();
      String gatewayFor(RoutingRule rule) {
        final iface = _interfaces.cast<NetworkInterfaceInfo?>().firstWhere(
          (i) =>
              i?.nativeId == rule.interfaceId ||
              i?.interfaceName == rule.interfaceId ||
              i?.id == rule.interfaceId,
          orElse: () => null,
        );
        return iface?.gateway ?? '';
      }

      final plan = _reconciler.planFromRules(
        _rules,
        gatewayFor: (rule) => gatewayFor(rule),
      );
      final desired = plan.routes;
      final conflictMessages = plan.conflictsByRuleId.values
          .expand((messages) => messages)
          .toSet()
          .toList();
      if (conflictMessages.isNotEmpty) {
        debugPrint('[NetPilot] Route conflicts: $conflictMessages');
      }

      if (!_helperStatus.enabled && desired.isNotEmpty) {
        debugPrint(
          '[NetPilot] Route apply skipped: helper is not enabled. '
          'desired=${desired.map((route) => route.toMap()).toList()}',
        );
        _rules = _rules
            .map(
              (r) => r.enabled
                  ? r.copyWith(
                      status: RuleStatus.error,
                      lastError: 'Helper not enabled. Install/approve the NetPilot helper.',
                      subRules: r.subRules
                          .map(
                            (subRule) => subRule.enabled
                                ? subRule.copyWith(
                                    status: RuleStatus.error,
                                    lastError: 'Helper not enabled.',
                                  )
                                : subRule,
                          )
                          .toList(),
                    )
                  : r,
            )
            .toList();
        _bannerError = 'Helper not enabled. Install it to apply routes (Login Items approval may be required).';
        notifyListeners();
        return;
      }

      final result = await _platform.reconcileRoutes(desired);
      final checksByRoute = {
        for (final check in result.routeChecks)
          '${check.destination}|${check.expectedInterface}': check,
      };
      String? verificationError({
        required DestinationKind kind,
        required String destination,
        required List<String> resolvedIps,
        required String interfaceId,
      }) {
        if (result.routeChecks.isEmpty) return null;
        final cidrs = switch (kind) {
          DestinationKind.cidr => [destination],
          DestinationKind.ipv4 => ['$destination/32'],
          DestinationKind.hostname ||
          DestinationKind.url => [for (final ip in resolvedIps) '$ip/32'],
        };
        for (final cidr in cidrs) {
          final check = checksByRoute['$cidr|$interfaceId'];
          if (check == null) {
            return 'Route $cidr was not verified by the helper.';
          }
          if (!check.verified) {
            return check.message ?? 'Route $cidr is not using $interfaceId.';
          }
        }
        return null;
      }

      _routeDiagnostics = [
        if (hostMappings.isNotEmpty)
          'Hostname mappings: ${hostMappings.entries.map((entry) => '${entry.key} → ${entry.value}').join(', ')}',
        'Desired routes: ${desired.length} · added: ${result.added} · removed: ${result.removed}',
        for (final check in result.routeChecks)
          '${check.verified ? '✓' : '✗'} ${check.destination} → '
              '${check.actualInterface ?? 'unavailable'}'
              '${check.actualGateway == null ? '' : ' via ${check.actualGateway}'} '
              '(expected ${check.expectedInterface}'
              '${check.expectedGateway == null ? '' : ' via ${check.expectedGateway}'})'
              '${check.message == null ? '' : '\n  ${check.message}'}',
        for (final error in result.errors) 'Error: $error',
        if (result.restartedProcesses.isNotEmpty)
          'Reconnected browser networking: ${result.restartedProcesses.map((process) => '${process.name} (${process.pid})').join(', ')}',
        if (result.connectionResetDestinations.isNotEmpty &&
            result.restartedProcesses.isEmpty)
          'No browser network service was restarted for changed destinations: ${result.connectionResetDestinations.join(', ')}',
      ];
      debugPrint(
        '[NetPilot] Route reconcile: '
        'desired=${desired.map((route) => route.toMap()).toList()} '
        'added=${result.added} removed=${result.removed} '
        'ok=${result.ok} errors=${result.errors} '
        'checks=${result.routeChecks.map((check) => {'destination': check.destination, 'expectedInterface': check.expectedInterface, 'expectedGateway': check.expectedGateway, 'actualInterface': check.actualInterface, 'actualGateway': check.actualGateway, 'verified': check.verified}).toList()} '
        'restartedProcesses=${result.restartedProcesses.map((process) => {'pid': process.pid, 'name': process.name}).toList()} '
        'resetDestinations=${result.connectionResetDestinations}',
      );
      _rules = _rules.map((rule) {
        if (!rule.enabled) {
          return rule.copyWith(
            status: RuleStatus.pending,
            clearLastError: true,
            subRules: rule.subRules
                .map(
                  (subRule) => subRule.copyWith(
                    status: RuleStatus.pending,
                    clearLastError: true,
                  ),
                )
                .toList(),
          );
        }
        final subRules = rule.subRules.map((subRule) {
          if (!subRule.enabled) {
            return subRule.copyWith(
              status: RuleStatus.pending,
              clearLastError: true,
            );
          }
          if ((subRule.kind == DestinationKind.hostname ||
                  subRule.kind == DestinationKind.url) &&
              subRule.resolvedIps.isEmpty) {
            return subRule.copyWith(status: RuleStatus.unresolved);
          }
          final conflicts =
              plan.conflictsBySubRuleKey['${rule.id}:${subRule.id}'];
          if (conflicts != null && conflicts.isNotEmpty) {
            return subRule.copyWith(
              status: RuleStatus.error,
              lastError: conflicts.join(' '),
            );
          }
          final routeError = verificationError(
            kind: subRule.kind,
            destination: subRule.destination,
            resolvedIps: subRule.resolvedIps,
            interfaceId: rule.interfaceId,
          );
          if (routeError != null) {
            return subRule.copyWith(
              status: RuleStatus.error,
              lastError: routeError,
            );
          }
          if (!result.ok && result.routeChecks.isEmpty) {
            return subRule.copyWith(
              status: RuleStatus.error,
              lastError: result.errors.isEmpty
                  ? 'Failed to reconcile route'
                  : result.errors.join('; '),
            );
          }
          return subRule.copyWith(
            status: RuleStatus.applied,
            clearLastError: true,
          );
        }).toList();
        if (rule.kind == DestinationKind.hostname ||
            rule.kind == DestinationKind.url) {
          if (rule.resolvedIps.isEmpty) {
            return rule.copyWith(
              status: RuleStatus.unresolved,
              subRules: subRules,
            );
          }
        }
        final conflicts = plan.conflictsByRuleId[rule.id];
        if (conflicts != null && conflicts.isNotEmpty) {
          return rule.copyWith(
            status: RuleStatus.error,
            lastError: conflicts.toSet().join(' '),
            subRules: subRules,
          );
        }
        final routeError = verificationError(
          kind: rule.kind,
          destination: rule.normalizedDestination,
          resolvedIps: rule.resolvedIps,
          interfaceId: rule.interfaceId,
        );
        if (routeError != null) {
          return rule.copyWith(
            status: RuleStatus.error,
            lastError: routeError,
            subRules: subRules,
          );
        }
        if (!result.ok && result.routeChecks.isEmpty) {
          return rule.copyWith(
            status: RuleStatus.error,
            lastError: result.errors.isEmpty
                ? 'Failed to reconcile routes'
                : result.errors.join('; '),
            subRules: subRules,
          );
        }
        return rule.copyWith(
          status: RuleStatus.applied,
          clearLastError: true,
          subRules: subRules,
        );
      }).toList();
      await _rulesRepository.save(_rules);
      final errors = <String>[
        ...conflictMessages,
        if (!result.ok)
          result.errors.isEmpty
              ? 'Failed to apply routes'
              : result.errors.join('; '),
      ];
      _bannerError = errors.isEmpty ? null : errors.join('\n');
    } catch (error, stackTrace) {
      debugPrint('[NetPilot] Route reconcile threw: $error');
      debugPrintStack(stackTrace: stackTrace);
      _bannerError = error.toString();
      _routeDiagnostics = ['Route reconcile threw: $error'];
      _rules = _rules
          .map(
            (r) => r.enabled
                ? r.copyWith(
                    status: RuleStatus.error,
                    lastError: error.toString(),
                    subRules: r.subRules
                        .map(
                          (subRule) => subRule.enabled
                              ? subRule.copyWith(
                                  status: RuleStatus.error,
                                  lastError: error.toString(),
                                )
                              : subRule,
                        )
                        .toList(),
                  )
                : r,
          )
          .toList();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Map<String, String> _desiredHostMappings({String? excludingRuleId}) {
    final mappings = <String, String>{};
    void add(String host, String ipv4) {
      final previous = mappings[host];
      if (previous != null && previous != ipv4) {
        throw StateError('Conflicting LAN IPv4 mappings for $host.');
      }
      mappings[host] = ipv4;
    }

    for (final rule in _rules) {
      if (!rule.enabled ||
          rule.id == excludingRuleId ||
          rule.hostIpv4 == null) {
        continue;
      }
      add(rule.normalizedDestination, rule.hostIpv4!);
      for (final child in rule.subRules) {
        if (child.enabled &&
            child.kind == DestinationKind.hostname &&
            child.resolvedIps.length == 1 &&
            _isPrivateIpv4(child.resolvedIps.single)) {
          add(child.destination, child.resolvedIps.single);
        }
      }
    }
    return mappings;
  }

  Future<void> _reconcileManagedHostMappings({String? excludingRuleId}) async {
    final desired = _desiredHostMappings(excludingRuleId: excludingRuleId);
    if (!supportsHostMappings) {
      if (desired.isNotEmpty) {
        throw StateError('Hostname mappings currently require macOS.');
      }
      return;
    }
    if (!_helperStatus.enabled && desired.isNotEmpty) {
      throw StateError(
        'Install/repair and approve the NetPilot helper to apply hostname mappings.',
      );
    }
    final result = await _platform.reconcileHostMappings([
      for (final entry in desired.entries)
        HostMapping(host: entry.key, ipv4: entry.value),
    ]);
    if (!result.ok) {
      throw StateError(
        result.errors.isEmpty
            ? 'Could not apply hostname mappings. Use Repair Helper.'
            : result.errors.join('; '),
      );
    }
  }

  bool _isPrivateIpv4(String ip) {
    if (!_parser.isIpv4(ip)) return false;
    final parts = ip.split('.').map(int.parse).toList();
    return parts[0] == 10 ||
        (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
        (parts[0] == 192 && parts[1] == 168);
  }

  Future<void> _replaceRule(RoutingRule rule, {int? existingIndex}) async {
    final index =
        existingIndex ?? _rules.indexWhere((item) => item.id == rule.id);
    if (index >= 0) {
      _rules = List.of(_rules)..[index] = rule;
    } else {
      _rules = [..._rules, rule];
    }
    await _rulesRepository.save(_rules);
    notifyListeners();
  }

  String _resolutionError(String host) =>
      'Could not resolve $host. Check LAN DNS or add a hostname-to-IPv4 mapping.';

  Future<ResolveHostResult> _resolveHost(String host, {String? interfaceId}) =>
      _platform
          .resolveHost(host, interfaceId: interfaceId)
          .timeout(
            _resolutionTimeout,
            onTimeout: () {
              debugPrint('[NetPilot] DNS resolution timed out: host=$host');
              return const ResolveHostResult(ips: []);
            },
          );

  Future<List<RoutingSubRule>> _resolveDependencies(
    List<String> destinations, {
    required String interfaceId,
    required Map<String, RoutingSubRule> previousByDestination,
  }) async {
    var expired = false;
    Future<List<RoutingSubRule>> resolve() async {
      final result = <RoutingSubRule>[];
      // Resolve a few hosts together rather than accumulating a full DNS wait
      // for every dependency; do not flood the native resolver with all hosts.
      for (var offset = 0; offset < destinations.length; offset += 4) {
        if (expired) break;
        result.addAll(
          await Future.wait(
            destinations
                .skip(offset)
                .take(4)
                .map(
                  (destination) => _resolveSubRule(
                    destination,
                    interfaceId: interfaceId,
                    existing: previousByDestination[destination],
                  ),
                ),
          ),
        );
      }
      return result;
    }

    return resolve().timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        expired = true;
        throw const DependencyScanException(
          'Dependency DNS resolution timed out. The parent rule was saved.',
        );
      },
    );
  }

  Future<RoutingSubRule> _resolveSubRule(
    String destination, {
    required String interfaceId,
    RoutingSubRule? existing,
  }) async {
    final parsed = _parser.parse(destination);
    if (parsed.kind == DestinationKind.ipv4) {
      return RoutingSubRule(
        id: existing?.id ?? _uuid.v4(),
        destination: parsed.normalized,
        kind: DestinationKind.ipv4,
        enabled: existing?.enabled ?? true,
        resolvedIps: [parsed.normalized],
        status: RuleStatus.pending,
      );
    }
    final resolved = await _resolveHost(
      parsed.normalized,
      interfaceId: interfaceId,
    );
    return RoutingSubRule(
      id: existing?.id ?? _uuid.v4(),
      destination: parsed.normalized,
      kind: DestinationKind.hostname,
      enabled: existing?.enabled ?? true,
      resolvedIps: resolved.ips,
      status: resolved.ips.isEmpty ? RuleStatus.unresolved : RuleStatus.pending,
      lastError: resolved.ips.isEmpty
          ? _resolutionError(parsed.normalized)
          : null,
    );
  }

  Future<RoutingSubRule> _refreshSubRule(
    RoutingSubRule subRule, {
    required String interfaceId,
  }) async {
    if (subRule.kind == DestinationKind.ipv4) {
      return subRule.copyWith(
        resolvedIps: [subRule.destination],
        status: RuleStatus.pending,
        clearLastError: true,
      );
    }
    final resolved = await _resolveHost(
      subRule.destination,
      interfaceId: interfaceId,
    );
    return subRule.copyWith(
      resolvedIps: resolved.ips,
      status: resolved.ips.isEmpty ? RuleStatus.unresolved : RuleStatus.pending,
      lastError: resolved.ips.isEmpty
          ? _resolutionError(subRule.destination)
          : null,
      clearLastError: resolved.ips.isNotEmpty,
    );
  }
}
