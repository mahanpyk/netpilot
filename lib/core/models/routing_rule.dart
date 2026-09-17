import 'package:flutter/foundation.dart';

enum DestinationKind { hostname, url, ipv4, cidr }

enum RuleStatus { pending, applied, unresolved, error }

@immutable
class RoutingRule {
  const RoutingRule({
    required this.id,
    required this.rawDestination,
    required this.kind,
    required this.normalizedDestination,
    required this.interfaceId,
    required this.enabled,
    required this.resolvedIps,
    required this.status,
    required this.updatedAt,
    this.label,
    this.lastError,
  });

  final String id;
  final String? label;
  final String rawDestination;
  final DestinationKind kind;
  final String normalizedDestination;
  final String interfaceId;
  final bool enabled;
  final List<String> resolvedIps;
  final RuleStatus status;
  final String? lastError;
  final DateTime updatedAt;

  RoutingRule copyWith({
    String? id,
    String? label,
    String? rawDestination,
    DestinationKind? kind,
    String? normalizedDestination,
    String? interfaceId,
    bool? enabled,
    List<String>? resolvedIps,
    RuleStatus? status,
    String? lastError,
    DateTime? updatedAt,
    bool clearLastError = false,
  }) {
    return RoutingRule(
      id: id ?? this.id,
      label: label ?? this.label,
      rawDestination: rawDestination ?? this.rawDestination,
      kind: kind ?? this.kind,
      normalizedDestination:
          normalizedDestination ?? this.normalizedDestination,
      interfaceId: interfaceId ?? this.interfaceId,
      enabled: enabled ?? this.enabled,
      resolvedIps: resolvedIps ?? this.resolvedIps,
      status: status ?? this.status,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'rawDestination': rawDestination,
        'kind': kind.name,
        'normalizedDestination': normalizedDestination,
        'interfaceId': interfaceId,
        'enabled': enabled,
        'resolvedIps': resolvedIps,
        'status': status.name,
        'lastError': lastError,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory RoutingRule.fromJson(Map<String, Object?> json) {
    return RoutingRule(
      id: json['id'] as String,
      label: json['label'] as String?,
      rawDestination: json['rawDestination'] as String,
      kind: DestinationKind.values.byName(json['kind'] as String),
      normalizedDestination: json['normalizedDestination'] as String,
      interfaceId: json['interfaceId'] as String,
      enabled: json['enabled'] as bool? ?? true,
      resolvedIps: (json['resolvedIps'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      status: RuleStatus.values.byName(
        (json['status'] as String?) ?? RuleStatus.pending.name,
      ),
      lastError: json['lastError'] as String?,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

@immutable
class DesiredRoute {
  const DesiredRoute({
    required this.destinationCidr,
    required this.interfaceName,
    required this.ruleId,
    this.gateway,
  });

  final String destinationCidr;
  final String? gateway;
  final String interfaceName;
  final String ruleId;

  String get tag => 'netpilot:$ruleId';

  Map<String, Object?> toMap() => {
        'destination': destinationCidr,
        'gateway': gateway,
        'interfaceName': interfaceName,
        'tag': tag,
      };

  @override
  bool operator ==(Object other) {
    return other is DesiredRoute &&
        other.destinationCidr == destinationCidr &&
        other.gateway == gateway &&
        other.interfaceName == interfaceName &&
        other.ruleId == ruleId;
  }

  @override
  int get hashCode =>
      Object.hash(destinationCidr, gateway, interfaceName, ruleId);
}
