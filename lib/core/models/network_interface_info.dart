import 'package:flutter/foundation.dart';

enum NetworkInterfaceKind { wifi, ethernet, other }

@immutable
class NetworkInterfaceInfo {
  const NetworkInterfaceInfo({
    required this.id,
    required this.name,
    required this.interfaceName,
    required this.kind,
    required this.ipv4Addresses,
    required this.dnsServers,
    required this.isDefaultRoute,
    required this.isActive,
    this.gateway,
  });

  final String id;
  final String name;
  final String interfaceName;
  final NetworkInterfaceKind kind;
  final List<String> ipv4Addresses;
  final String? gateway;
  final List<String> dnsServers;
  final bool isDefaultRoute;
  final bool isActive;

  factory NetworkInterfaceInfo.fromMap(Map<Object?, Object?> map) {
    final kindRaw = (map['kind'] as String?) ?? 'other';
    return NetworkInterfaceInfo(
      id: (map['id'] as String?) ?? (map['interfaceName'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      interfaceName: (map['interfaceName'] as String?) ?? '',
      kind: switch (kindRaw) {
        'wifi' => NetworkInterfaceKind.wifi,
        'ethernet' => NetworkInterfaceKind.ethernet,
        _ => NetworkInterfaceKind.other,
      },
      ipv4Addresses: _stringList(map['ipv4Addresses']),
      gateway: map['gateway'] as String?,
      dnsServers: _stringList(map['dnsServers']),
      isDefaultRoute: map['isDefaultRoute'] as bool? ?? false,
      isActive: map['isActive'] as bool? ?? false,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'interfaceName': interfaceName,
        'kind': kind.name,
        'ipv4Addresses': ipv4Addresses,
        'gateway': gateway,
        'dnsServers': dnsServers,
        'isDefaultRoute': isDefaultRoute,
        'isActive': isActive,
      };

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value.map((e) => e.toString()).toList();
  }
}
