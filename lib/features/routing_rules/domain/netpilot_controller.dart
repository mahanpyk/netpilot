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
  StreamSubscription<void>? _networkSub;

  List<NetworkInterfaceInfo> get interfaces => List.unmodifiable(_interfaces);
  List<RoutingRule> get rules => List.unmodifiable(_rules);
  HelperStatus get helperStatus => _helperStatus;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get bannerError => _bannerError;

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
    final result = await _platform.resolveHost(host, interfaceId: interfaceId);
    return result.ips;
  }

  Future<void> upsertRule({
    String? id,
    required String rawDestination,
    required String interfaceId,
    String? label,
    bool enabled = true,
  }) async {
    final parsed = _parser.parse(rawDestination);
    List<String> ips = [];
    var status = RuleStatus.pending;
    String? error;

    if (parsed.kind == DestinationKind.hostname ||
        parsed.kind == DestinationKind.url) {
      final resolved = await _platform.resolveHost(
        parsed.normalized,
        interfaceId: interfaceId,
      );
      ips = resolved.ips;
      if (ips.isEmpty) {
        status = RuleStatus.unresolved;
        error = 'Could not resolve ${parsed.normalized} via selected LAN DNS';
      }
    } else if (parsed.kind == DestinationKind.ipv4) {
      ips = [parsed.normalized];
    }

    final existingIndex = id == null
        ? -1
        : _rules.indexWhere((r) => r.id == id);
    final existingRule = existingIndex < 0 ? null : _rules[existingIndex];
    final scansDependencies = parsed.kind == DestinationKind.url;
    final rule = RoutingRule(
      id: id ?? _uuid.v4(),
      label: label,
      rawDestination: rawDestination.trim(),
      kind: parsed.kind,
      normalizedDestination: parsed.normalized,
      interfaceId: interfaceId,
      enabled: enabled,
      resolvedIps: ips,
      status: status,
      lastError: error,
      updatedAt: DateTime.now(),
      subRules: const [],
      dependencyScanStatus: scansDependencies
          ? DependencyScanStatus.pending
          : DependencyScanStatus.notApplicable,
    );

    await _replaceRule(rule, existingIndex: existingIndex);
    // Apply the parent first so the page and same-origin scripts are fetched
    // over the interface selected for this rule.
    await applyAll();

    if (!scansDependencies) return;

    try {
      final result = await _dependencyScanner.scan(
        Uri.parse(rule.rawDestination),
      );
      final previousByDestination = {
        for (final subRule
            in existingRule?.subRules ?? const <RoutingSubRule>[])
          subRule.destination: subRule,
      };
      final subRules = <RoutingSubRule>[];
      for (final destination in result.destinations) {
        final previous = previousByDestination[destination];
        subRules.add(
          await _resolveSubRule(
            destination,
            interfaceId: interfaceId,
            existing: previous,
          ),
        );
      }
      final scannedRule = rule.copyWith(
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
      await applyAll();
    } catch (error, stackTrace) {
      final message = error is DependencyScanException
          ? error.message
          : error.toString();
      debugPrint(
        '[NetPilot] Dependency scan failed: url=${rule.rawDestination} error=$message',
      );
      debugPrintStack(stackTrace: stackTrace);
      final failedRule = rule.copyWith(
        subRules: const [],
        dependencyScanStatus: DependencyScanStatus.failed,
        dependencyScanError: message,
        updatedAt: DateTime.now(),
      );
      await _replaceRule(failedRule);
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
    _rules = _rules.where((r) => r.id != id).toList();
    await _rulesRepository.save(_rules);
    notifyListeners();
    await applyAll();
  }

  Future<void> refreshResolutions() async {
    final next = <RoutingRule>[];
    for (final rule in _rules) {
      RoutingRule refreshedRule;
      if (rule.kind == DestinationKind.hostname ||
          rule.kind == DestinationKind.url) {
        final resolved = await _platform.resolveHost(
          rule.normalizedDestination,
          interfaceId: rule.interfaceId,
        );
        refreshedRule = rule.copyWith(
          resolvedIps: resolved.ips,
          status: resolved.ips.isEmpty
              ? RuleStatus.unresolved
              : RuleStatus.pending,
          lastError: resolved.ips.isEmpty
              ? 'Could not resolve ${rule.normalizedDestination}'
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
      debugPrint(
        '[NetPilot] Route reconcile: '
        'desired=${desired.map((route) => route.toMap()).toList()} '
        'added=${result.added} removed=${result.removed} '
        'ok=${result.ok} errors=${result.errors}',
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
          if (!result.ok) {
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
        if (!result.ok) {
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
    final resolved = await _platform.resolveHost(
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
          ? 'Could not resolve ${parsed.normalized}'
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
    final resolved = await _platform.resolveHost(
      subRule.destination,
      interfaceId: interfaceId,
    );
    return subRule.copyWith(
      resolvedIps: resolved.ips,
      status: resolved.ips.isEmpty ? RuleStatus.unresolved : RuleStatus.pending,
      lastError: resolved.ips.isEmpty
          ? 'Could not resolve ${subRule.destination}'
          : null,
      clearLastError: resolved.ips.isNotEmpty,
    );
  }
}
