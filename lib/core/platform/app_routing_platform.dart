import 'dart:async';

import 'package:flutter/services.dart';

import '../models/app_routing_rule.dart';

class AppRoutingStatus {
  const AppRoutingStatus({
    required this.extensionStatus,
    required this.proxyStatus,
    this.appliedHash,
    this.approvalRequired = false,
    this.message,
    this.activeFlows = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.ruleMetrics = const {},
  });

  final String extensionStatus;
  final String proxyStatus;
  final String? appliedHash;
  final bool approvalRequired;
  final String? message;
  final int activeFlows;
  final int bytesIn;
  final int bytesOut;
  final Map<String, AppRoutingRuleMetrics> ruleMetrics;

  bool get extensionReady => extensionStatus == 'installed';
  bool get proxyRunning => proxyStatus == 'running';

  factory AppRoutingStatus.fromMap(Map<Object?, Object?> map) =>
      AppRoutingStatus(
        extensionStatus: map['extensionStatus']?.toString() ?? 'unknown',
        proxyStatus: map['proxyStatus']?.toString() ?? 'stopped',
        appliedHash: map['appliedHash']?.toString(),
        approvalRequired: map['approvalRequired'] as bool? ?? false,
        message: map['message']?.toString(),
        activeFlows: map['activeFlows'] as int? ?? 0,
        bytesIn: map['bytesIn'] as int? ?? 0,
        bytesOut: map['bytesOut'] as int? ?? 0,
        ruleMetrics: _metricsMap(map['ruleMetrics']),
      );
}

class AppRoutingRuleMetrics {
  const AppRoutingRuleMetrics({
    this.activeFlows = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.lastError,
  });

  final int activeFlows;
  final int bytesIn;
  final int bytesOut;
  final String? lastError;
}

Map<String, AppRoutingRuleMetrics> _metricsMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.value is Map)
        entry.key.toString(): AppRoutingRuleMetrics(
          activeFlows: (entry.value as Map)['activeFlows'] as int? ?? 0,
          bytesIn: (entry.value as Map)['bytesIn'] as int? ?? 0,
          bytesOut: (entry.value as Map)['bytesOut'] as int? ?? 0,
          lastError: (entry.value as Map)['lastError']?.toString(),
        ),
  };
}

abstract class AppRoutingPlatform {
  Future<AppDescriptor?> pickApplication();
  Future<AppRoutingStatus> getStatus();
  Future<AppRoutingStatus> installExtension();
  Future<AppRoutingStatus> applyAndRestart({
    required bool masterEnabled,
    required List<AppRoutingRule> rules,
    required String configurationHash,
  });
  Future<List<String>> getDiagnostics();
  Stream<Map<String, Object?>> get events;
}

class MethodChannelAppRoutingPlatform implements AppRoutingPlatform {
  MethodChannelAppRoutingPlatform({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method =
           methodChannel ??
           const MethodChannel('com.netpilot.netpilotDesktop/appRouting'),
       _events =
           eventChannel ??
           const EventChannel('com.netpilot.netpilotDesktop/appRoutingEvents');

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Future<AppDescriptor?> pickApplication() async {
    final map = await _method.invokeMethod<Map<Object?, Object?>>(
      'selectApplication',
    );
    return map == null ? null : AppDescriptor.fromMap(map);
  }

  @override
  Future<AppRoutingStatus> getStatus() async => _status('getStatus');

  @override
  Future<AppRoutingStatus> installExtension() async =>
      _status('requestExtensionActivation');

  @override
  Future<AppRoutingStatus> applyAndRestart({
    required bool masterEnabled,
    required List<AppRoutingRule> rules,
    required String configurationHash,
  }) async {
    final map = await _method.invokeMethod<Map<Object?, Object?>>(
      'applyAndRestart',
      {
        'masterEnabled': masterEnabled,
        'rules': rules.map((rule) => rule.toProviderJson()).toList(),
        'configurationHash': configurationHash,
      },
    );
    return AppRoutingStatus.fromMap(map ?? const {});
  }

  Future<AppRoutingStatus> _status(String method) async {
    final map = await _method.invokeMethod<Map<Object?, Object?>>(method);
    return AppRoutingStatus.fromMap(map ?? const {});
  }

  @override
  Future<List<String>> getDiagnostics() async {
    final values = await _method.invokeMethod<List<Object?>>('getDiagnostics');
    return (values ?? const []).map((value) => value.toString()).toList();
  }

  @override
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((value) => value is Map)
      .map((value) => Map<String, Object?>.from(value as Map));
}

class FakeAppRoutingPlatform implements AppRoutingPlatform {
  FakeAppRoutingPlatform({
    this.selectedApplication,
    this.status = const AppRoutingStatus(
      extensionStatus: 'installed',
      proxyStatus: 'stopped',
    ),
  });

  AppDescriptor? selectedApplication;
  AppRoutingStatus status;
  int applyCount = 0;
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Future<AppDescriptor?> pickApplication() async => selectedApplication;

  @override
  Future<AppRoutingStatus> getStatus() async => status;

  @override
  Future<AppRoutingStatus> installExtension() async {
    status = AppRoutingStatus(
      extensionStatus: 'installed',
      proxyStatus: status.proxyStatus,
      appliedHash: status.appliedHash,
    );
    return status;
  }

  @override
  Future<AppRoutingStatus> applyAndRestart({
    required bool masterEnabled,
    required List<AppRoutingRule> rules,
    required String configurationHash,
  }) async {
    applyCount++;
    status = AppRoutingStatus(
      extensionStatus: 'installed',
      proxyStatus: masterEnabled ? 'running' : 'stopped',
      appliedHash: configurationHash,
    );
    return status;
  }

  @override
  Future<List<String>> getDiagnostics() async => const [];

  @override
  Stream<Map<String, Object?>> get events => _events.stream;
}
