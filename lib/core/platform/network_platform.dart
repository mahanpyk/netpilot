import 'dart:async';

import 'package:flutter/services.dart';

import '../models/network_interface_info.dart';
import '../models/routing_rule.dart';

class HelperStatus {
  const HelperStatus({
    required this.installed,
    required this.enabled,
    required this.status,
    this.message,
  });

  final bool installed;
  final bool enabled;
  final String status;
  final String? message;

  factory HelperStatus.fromMap(Map<Object?, Object?> map) {
    return HelperStatus(
      installed: map['installed'] as bool? ?? false,
      enabled: map['enabled'] as bool? ?? false,
      status: (map['status'] as String?) ?? 'unknown',
      message: map['message'] as String?,
    );
  }
}

class ApplyRoutesResult {
  const ApplyRoutesResult({
    required this.ok,
    required this.added,
    required this.removed,
    required this.errors,
  });

  final bool ok;
  final int added;
  final int removed;
  final List<String> errors;

  factory ApplyRoutesResult.fromMap(Map<Object?, Object?> map) {
    return ApplyRoutesResult(
      ok: map['ok'] as bool? ?? false,
      added: map['added'] as int? ?? 0,
      removed: map['removed'] as int? ?? 0,
      errors: (map['errors'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

class ResolveHostResult {
  const ResolveHostResult({required this.ips, this.ttlSeconds});

  final List<String> ips;
  final int? ttlSeconds;

  factory ResolveHostResult.fromMap(Map<Object?, Object?> map) {
    return ResolveHostResult(
      ips: (map['ips'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      ttlSeconds: map['ttlSeconds'] as int?,
    );
  }
}

abstract class NetworkPlatform {
  Future<List<NetworkInterfaceInfo>> listInterfaces();
  Future<ResolveHostResult> resolveHost(String host, {String? interfaceId});
  Future<HelperStatus> getHelperStatus();
  Future<HelperStatus> installHelper();
  Future<ApplyRoutesResult> reconcileRoutes(List<DesiredRoute> desired);
  Stream<void> get interfacesChanged;
}

class MethodChannelNetworkPlatform implements NetworkPlatform {
  MethodChannelNetworkPlatform({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ??
            const MethodChannel('com.netpilot.netpilotDesktop/network'),
        _events = eventChannel ??
            const EventChannel('com.netpilot.netpilotDesktop/networkEvents');

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Future<List<NetworkInterfaceInfo>> listInterfaces() async {
    final raw = await _method.invokeMethod<List<Object?>>('listInterfaces');
    if (raw == null) return [];
    return raw
        .whereType<Map>()
        .map((e) => NetworkInterfaceInfo.fromMap(Map<Object?, Object?>.from(e)))
        .toList();
  }

  @override
  Future<ResolveHostResult> resolveHost(
    String host, {
    String? interfaceId,
  }) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>(
      'resolveHost',
      {'host': host, 'interfaceId': interfaceId},
    );
    if (raw == null) return const ResolveHostResult(ips: []);
    return ResolveHostResult.fromMap(raw);
  }

  @override
  Future<HelperStatus> getHelperStatus() async {
    final raw =
        await _method.invokeMethod<Map<Object?, Object?>>('getHelperStatus');
    if (raw == null) {
      return const HelperStatus(
        installed: false,
        enabled: false,
        status: 'unavailable',
      );
    }
    return HelperStatus.fromMap(raw);
  }

  @override
  Future<HelperStatus> installHelper() async {
    final raw =
        await _method.invokeMethod<Map<Object?, Object?>>('installHelper');
    if (raw == null) {
      return const HelperStatus(
        installed: false,
        enabled: false,
        status: 'failed',
        message: 'No response from native bridge',
      );
    }
    return HelperStatus.fromMap(raw);
  }

  @override
  Future<ApplyRoutesResult> reconcileRoutes(List<DesiredRoute> desired) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>(
      'reconcileRoutes',
      {'desired': desired.map((e) => e.toMap()).toList()},
    );
    if (raw == null) {
      return const ApplyRoutesResult(
        ok: false,
        added: 0,
        removed: 0,
        errors: ['No response from native bridge'],
      );
    }
    return ApplyRoutesResult.fromMap(raw);
  }

  @override
  Stream<void> get interfacesChanged {
    return _events.receiveBroadcastStream().map((_) {});
  }
}

/// Fake platform for widget/unit tests and unsupported hosts.
class FakeNetworkPlatform implements NetworkPlatform {
  FakeNetworkPlatform({
    List<NetworkInterfaceInfo>? interfaces,
    this.resolveMap = const {},
    HelperStatus? helperStatus,
  })  : interfaces = interfaces ??
            [
              const NetworkInterfaceInfo(
                id: 'en0',
                name: 'Wi-Fi',
                interfaceName: 'en0',
                kind: NetworkInterfaceKind.wifi,
                ipv4Addresses: ['192.168.1.10'],
                gateway: '192.168.1.1',
                dnsServers: ['8.8.8.8'],
                isDefaultRoute: true,
                isActive: true,
              ),
              const NetworkInterfaceInfo(
                id: 'en7',
                name: 'Ethernet',
                interfaceName: 'en7',
                kind: NetworkInterfaceKind.ethernet,
                ipv4Addresses: ['10.0.0.42'],
                gateway: '10.0.0.1',
                dnsServers: ['10.0.0.1'],
                isDefaultRoute: false,
                isActive: true,
              ),
            ],
        helperStatus = helperStatus ??
            const HelperStatus(
              installed: true,
              enabled: true,
              status: 'enabled',
            );

  List<NetworkInterfaceInfo> interfaces;
  Map<String, List<String>> resolveMap;
  HelperStatus helperStatus;
  final List<DesiredRoute> managed = [];
  final _interfacesChanged = StreamController<void>.broadcast();

  void notifyInterfacesChanged() => _interfacesChanged.add(null);

  @override
  Future<List<NetworkInterfaceInfo>> listInterfaces() async =>
      List.of(interfaces);

  @override
  Future<ResolveHostResult> resolveHost(
    String host, {
    String? interfaceId,
  }) async {
    return ResolveHostResult(ips: resolveMap[host] ?? const []);
  }

  @override
  Future<HelperStatus> getHelperStatus() async => helperStatus;

  @override
  Future<HelperStatus> installHelper() async {
    helperStatus = const HelperStatus(
      installed: true,
      enabled: true,
      status: 'enabled',
    );
    return helperStatus;
  }

  @override
  Future<ApplyRoutesResult> reconcileRoutes(List<DesiredRoute> desired) async {
    final next = desired.toSet();
    final prev = managed.toSet();
    final added = next.difference(prev).length;
    final removed = prev.difference(next).length;
    managed
      ..clear()
      ..addAll(desired);
    return ApplyRoutesResult(
      ok: true,
      added: added,
      removed: removed,
      errors: const [],
    );
  }

  @override
  Stream<void> get interfacesChanged => _interfacesChanged.stream;
}
