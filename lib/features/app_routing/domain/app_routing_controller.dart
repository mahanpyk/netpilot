import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/app_routing_rule.dart';
import '../../../core/models/network_interface_info.dart';
import '../../../core/platform/app_routing_platform.dart';
import '../data/app_rules_repository.dart';

// Named public constructor parameters cannot use private initializing formals.
// ignore_for_file: prefer_initializing_formals

class AppRoutingController extends ChangeNotifier {
  AppRoutingController({
    required AppRoutingPlatform platform,
    required AppRulesRepository repository,
    required List<NetworkInterfaceInfo> Function() interfacesProvider,
    this.hostPlatform = AppRoutingHostPlatform.macos,
    Uuid? uuid,
  }) : _platform = platform,
       _repository = repository,
       _interfacesProvider = interfacesProvider,
       _uuid = uuid ?? const Uuid();

  final AppRoutingPlatform _platform;
  final AppRulesRepository _repository;
  final List<NetworkInterfaceInfo> Function() _interfacesProvider;
  final Uuid _uuid;
  final AppRoutingHostPlatform hostPlatform;

  List<AppRoutingRule> _rules = [];
  bool _masterEnabled = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<String> _diagnostics = [];
  AppRoutingStatus _status = const AppRoutingStatus(
    extensionStatus: 'unknown',
    proxyStatus: 'stopped',
  );
  StreamSubscription<Map<String, Object?>>? _eventsSubscription;

  List<AppRoutingRule> get rules => List.unmodifiable(_rules);
  bool get masterEnabled => _masterEnabled;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get error => _error;
  List<String> get diagnostics => List.unmodifiable(_diagnostics);
  AppRoutingStatus get status => _status;
  AppRoutingConfiguration get configuration =>
      AppRoutingConfiguration(masterEnabled: _masterEnabled, rules: _rules);
  bool get hasPendingChanges => configuration.hash != _status.appliedHash;

  List<NetworkInterfaceInfo> get physicalInterfaces => _interfacesProvider()
      .where(
        (item) =>
            item.isActive &&
            (item.kind == NetworkInterfaceKind.wifi ||
                item.kind == NetworkInterfaceKind.ethernet),
      )
      .toList();

  Future<void> start() async {
    _loading = true;
    notifyListeners();
    try {
      final stored = await _repository.load();
      _rules = stored.rules;
      _masterEnabled = stored.masterEnabled;
      _status = await _platform.getStatus();
      _diagnostics = await _platform.getDiagnostics();
      _eventsSubscription ??= _platform.events.listen((event) async {
        debugPrint('[NetPilot App Routing] event=$event');
        if (event.containsKey('extensionStatus')) {
          _status = AppRoutingStatus.fromMap(event);
          notifyListeners();
        } else {
          await refreshStatus();
        }
      });
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    super.dispose();
  }

  Future<AppDescriptor?> selectApplication() async {
    try {
      return await _platform.pickApplication();
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
      return null;
    }
  }

  Future<void> upsertRule({
    String? id,
    required AppDescriptor app,
    required String interfaceId,
    required AppRoutingFailurePolicy failurePolicy,
    bool enabled = true,
    List<AppExecutableIdentity>? helperExecutables,
  }) async {
    final index = id == null ? -1 : _rules.indexWhere((rule) => rule.id == id);
    final rule = AppRoutingRule(
      id: id ?? _uuid.v4(),
      displayName: app.displayName,
      bundlePath: app.bundlePath,
      bundleIdentifier: app.bundleIdentifier,
      signingIdentifier: app.signingIdentifier,
      teamIdentifier: app.teamIdentifier,
      helperSigningIdentifiers: app.helperSigningIdentifiers,
      platform: app.platform,
      executablePath: app.executablePath,
      wfpAppId: app.wfpAppId,
      publisher: app.publisher,
      isSigned: app.isSigned,
      helperExecutables: helperExecutables ?? app.helperExecutables,
      iconPngBase64: app.iconPngBase64,
      interfaceId: interfaceId,
      enabled: enabled,
      failurePolicy: failurePolicy,
      status: AppRoutingRuleStatus.pending,
      updatedAt: DateTime.now(),
    );
    _rules = List.of(_rules);
    if (index < 0) {
      _rules.add(rule);
    } else {
      _rules[index] = rule;
    }
    await _persist();
  }

  Future<void> updateRule({
    required AppRoutingRule rule,
    required String interfaceId,
    required AppRoutingFailurePolicy failurePolicy,
    List<AppExecutableIdentity>? helperExecutables,
  }) async {
    final index = _rules.indexWhere((item) => item.id == rule.id);
    if (index < 0) return;
    _rules = List.of(_rules)
      ..[index] = rule.copyWith(
        interfaceId: interfaceId,
        failurePolicy: failurePolicy,
        helperExecutables: helperExecutables,
        status: AppRoutingRuleStatus.pending,
        clearLastError: true,
        updatedAt: DateTime.now(),
      );
    await _persist();
  }

  Future<void> setRuleEnabled(String id, bool enabled) async {
    final index = _rules.indexWhere((rule) => rule.id == id);
    if (index < 0) return;
    _rules = List.of(_rules)
      ..[index] = _rules[index].copyWith(
        enabled: enabled,
        status: AppRoutingRuleStatus.pending,
        clearLastError: true,
        updatedAt: DateTime.now(),
      );
    await _persist();
  }

  Future<void> deleteRule(String id) async {
    _rules = _rules.where((rule) => rule.id != id).toList();
    await _persist();
  }

  Future<void> setMasterEnabled(bool enabled) async {
    _masterEnabled = enabled;
    await _persist();
  }

  Future<void> installExtension() async {
    await _runBusy(() async {
      _status = await _platform.installExtension();
      if (!_status.routingEngineReady) {
        _error =
            _status.message ??
            (hostPlatform == AppRoutingHostPlatform.windows
                ? 'Windows Routing Engine is not ready yet.'
                : 'System Extension is not installed yet.');
      }
    });
  }

  Future<void> applyAndRestart() async {
    final validationError = validate();
    if (validationError != null) {
      _error = validationError;
      debugPrint('[NetPilot App Routing] validation failed: $validationError');
      notifyListeners();
      return;
    }
    await _runBusy(() async {
      final current = configuration;
      debugPrint(
        '[NetPilot App Routing] restarting proxy rules=${_rules.length} '
        'master=$_masterEnabled hash=${current.hash}',
      );
      _status = await _platform.applyAndRestart(
        masterEnabled: _masterEnabled,
        rules: _rules,
        configurationHash: current.hash,
      );
      final applyError =
          _masterEnabled &&
              !_status.proxyRunning &&
              _status.proxyStatus != 'reconnecting'
          ? (_status.message ??
                'Transparent Proxy did not start (status: ${_status.proxyStatus}).')
          : null;
      if (applyError != null) _error = applyError;
      _diagnostics = await _platform.getDiagnostics();
      _rules = _rules
          .map(
            (rule) => rule.copyWith(
              status: applyError != null
                  ? AppRoutingRuleStatus.error
                  : rule.enabled && _masterEnabled
                  ? AppRoutingRuleStatus.active
                  : AppRoutingRuleStatus.disabled,
              lastError: applyError,
              clearLastError: applyError == null,
            ),
          )
          .toList();
      await _persist(notify: false);
    });
  }

  String? validate() {
    final interfaces = physicalInterfaces.map((item) => item.nativeId).toSet()
      ..addAll(physicalInterfaces.map((item) => item.interfaceName))
      ..addAll(physicalInterfaces.map((item) => item.id));
    final owners = <String, AppRoutingRule>{};
    for (final rule in _rules.where((item) => item.enabled)) {
      if (rule.platform == AppRoutingHostPlatform.macos &&
          (rule.signingIdentifier.isEmpty || rule.teamIdentifier.isEmpty)) {
        return '${rule.displayName} does not have a verifiable signing identifier and Team ID.';
      }
      if (rule.platform == AppRoutingHostPlatform.windows &&
          ((rule.executablePath ?? '').isEmpty ||
              (rule.wfpAppId ?? '').isEmpty)) {
        return '${rule.displayName} does not have a canonical EXE path and WFP App ID.';
      }
      if (!interfaces.contains(rule.interfaceId)) {
        return '${rule.displayName} uses unavailable physical interface ${rule.interfaceId}.';
      }
      for (final identifier in rule.allIdentityKeys) {
        final previous = owners[identifier];
        if (previous != null && previous.interfaceId != rule.interfaceId) {
          return 'Signing identifier $identifier conflicts between '
              '${previous.displayName} (${previous.interfaceId}) and '
              '${rule.displayName} (${rule.interfaceId}).';
        }
        owners[identifier] = rule;
      }
    }
    return null;
  }

  Future<void> refreshStatus() async {
    try {
      _status = await _platform.getStatus();
      _diagnostics = await _platform.getDiagnostics();
      notifyListeners();
    } catch (error, stackTrace) {
      _setError(error, stackTrace);
    }
  }

  Future<void> _persist({bool notify = true}) async {
    await _repository.save(
      StoredAppRoutingState(masterEnabled: _masterEnabled, rules: _rules),
    );
    if (notify) notifyListeners();
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await action();
    } catch (error, stackTrace) {
      _setError(error, stackTrace, notify: false);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _setError(Object error, StackTrace stackTrace, {bool notify = true}) {
    _error = error.toString();
    debugPrint('[NetPilot App Routing] error=$_error');
    debugPrintStack(stackTrace: stackTrace);
    if (notify) notifyListeners();
  }
}
