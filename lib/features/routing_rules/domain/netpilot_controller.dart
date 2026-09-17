import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/network_interface_info.dart';
import '../../../core/models/routing_rule.dart';
import '../../../core/platform/network_platform.dart';
import '../../../core/utils/destination_parser.dart';
import '../../../core/utils/route_reconciler.dart';
import '../data/rules_repository.dart';

class NetPilotController extends ChangeNotifier {
  NetPilotController({
    required this._platform,
    required this._rulesRepository,
    DestinationParser? parser,
    RouteReconciler? reconciler,
    Uuid? uuid,
  }) : _parser = parser ?? const DestinationParser(),
       _reconciler = reconciler ?? const RouteReconciler(),
       _uuid = uuid ?? const Uuid();

  final NetworkPlatform _platform;
  final RulesRepository _rulesRepository;
  final DestinationParser _parser;
  final RouteReconciler _reconciler;
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
      _bannerError = null;
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
    );

    if (existingIndex >= 0) {
      _rules = List.of(_rules)..[existingIndex] = rule;
    } else {
      _rules = [..._rules, rule];
    }
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
      if (rule.kind == DestinationKind.hostname ||
          rule.kind == DestinationKind.url) {
        final resolved = await _platform.resolveHost(
          rule.normalizedDestination,
          interfaceId: rule.interfaceId,
        );
        next.add(
          rule.copyWith(
            resolvedIps: resolved.ips,
            status: resolved.ips.isEmpty
                ? RuleStatus.unresolved
                : RuleStatus.pending,
            lastError: resolved.ips.isEmpty
                ? 'Could not resolve ${rule.normalizedDestination}'
                : null,
            clearLastError: resolved.ips.isNotEmpty,
            updatedAt: DateTime.now(),
          ),
        );
      } else {
        next.add(rule);
      }
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
              i?.interfaceName == rule.interfaceId || i?.id == rule.interfaceId,
          orElse: () => null,
        );
        return iface?.gateway ?? '';
      }

      final desired = _reconciler
          .desiredFromRules(
            _rules,
            gatewayFor: (rule) {
              final g = gatewayFor(rule);
              return g.isEmpty ? '' : g;
            },
          )
          .map((r) {
            // Empty gateway → null for native
            if (r.gateway == null || r.gateway!.isEmpty) {
              return DesiredRoute(
                destinationCidr: r.destinationCidr,
                interfaceName: r.interfaceName,
                ruleId: r.ruleId,
              );
            }
            return r;
          })
          .toList();

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
      final byRule = <String, List<String>>{};
      for (final d in desired) {
        byRule.putIfAbsent(d.ruleId, () => []).add(d.destinationCidr);
      }

      _rules = _rules.map((rule) {
        if (!rule.enabled) {
          return rule.copyWith(
            status: RuleStatus.pending,
            clearLastError: true,
          );
        }
        if (rule.kind == DestinationKind.hostname ||
            rule.kind == DestinationKind.url) {
          if (rule.resolvedIps.isEmpty) {
            return rule.copyWith(status: RuleStatus.unresolved);
          }
        }
        if (!result.ok) {
          return rule.copyWith(
            status: RuleStatus.error,
            lastError: result.errors.isEmpty
                ? 'Failed to reconcile routes'
                : result.errors.join('; '),
          );
        }
        return rule.copyWith(status: RuleStatus.applied, clearLastError: true);
      }).toList();
      await _rulesRepository.save(_rules);
      _bannerError = result.ok
          ? null
          : (result.errors.isEmpty
                ? 'Failed to apply routes'
                : result.errors.join('; '));
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
                  )
                : r,
          )
          .toList();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
