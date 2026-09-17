import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum AppRoutingFailurePolicy { block, fallback }

enum AppRoutingRuleStatus { pending, active, disabled, error }

@immutable
class AppDescriptor {
  const AppDescriptor({
    required this.displayName,
    required this.bundlePath,
    required this.bundleIdentifier,
    required this.signingIdentifier,
    required this.teamIdentifier,
    this.helperSigningIdentifiers = const [],
    this.iconPngBase64,
  });

  final String displayName;
  final String bundlePath;
  final String bundleIdentifier;
  final String signingIdentifier;
  final String teamIdentifier;
  final List<String> helperSigningIdentifiers;
  final String? iconPngBase64;

  factory AppDescriptor.fromMap(Map<Object?, Object?> map) => AppDescriptor(
    displayName: map['displayName']?.toString() ?? '',
    bundlePath: map['bundlePath']?.toString() ?? '',
    bundleIdentifier: map['bundleIdentifier']?.toString() ?? '',
    signingIdentifier: map['signingIdentifier']?.toString() ?? '',
    teamIdentifier: map['teamIdentifier']?.toString() ?? '',
    helperSigningIdentifiers: _stringList(map['helperSigningIdentifiers']),
    iconPngBase64: map['iconPngBase64']?.toString(),
  );
}

@immutable
class AppRoutingRule {
  const AppRoutingRule({
    required this.id,
    required this.displayName,
    required this.bundlePath,
    required this.bundleIdentifier,
    required this.signingIdentifier,
    required this.teamIdentifier,
    required this.interfaceId,
    required this.enabled,
    required this.failurePolicy,
    required this.updatedAt,
    this.helperSigningIdentifiers = const [],
    this.iconPngBase64,
    this.status = AppRoutingRuleStatus.pending,
    this.lastError,
  });

  final String id;
  final String displayName;
  final String bundlePath;
  final String bundleIdentifier;
  final String signingIdentifier;
  final String teamIdentifier;
  final List<String> helperSigningIdentifiers;
  final String? iconPngBase64;
  final String interfaceId;
  final bool enabled;
  final AppRoutingFailurePolicy failurePolicy;
  final AppRoutingRuleStatus status;
  final String? lastError;
  final DateTime updatedAt;

  Set<String> get allSigningIdentifiers => {
    signingIdentifier,
    ...helperSigningIdentifiers,
  }.where((value) => value.isNotEmpty).toSet();

  AppRoutingRule copyWith({
    String? displayName,
    String? bundlePath,
    String? bundleIdentifier,
    String? signingIdentifier,
    String? teamIdentifier,
    List<String>? helperSigningIdentifiers,
    String? iconPngBase64,
    String? interfaceId,
    bool? enabled,
    AppRoutingFailurePolicy? failurePolicy,
    AppRoutingRuleStatus? status,
    String? lastError,
    bool clearLastError = false,
    DateTime? updatedAt,
  }) => AppRoutingRule(
    id: id,
    displayName: displayName ?? this.displayName,
    bundlePath: bundlePath ?? this.bundlePath,
    bundleIdentifier: bundleIdentifier ?? this.bundleIdentifier,
    signingIdentifier: signingIdentifier ?? this.signingIdentifier,
    teamIdentifier: teamIdentifier ?? this.teamIdentifier,
    helperSigningIdentifiers:
        helperSigningIdentifiers ?? this.helperSigningIdentifiers,
    iconPngBase64: iconPngBase64 ?? this.iconPngBase64,
    interfaceId: interfaceId ?? this.interfaceId,
    enabled: enabled ?? this.enabled,
    failurePolicy: failurePolicy ?? this.failurePolicy,
    status: status ?? this.status,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory AppRoutingRule.fromJson(Map<String, Object?> json) {
    final policy = json['failurePolicy']?.toString();
    final status = json['status']?.toString();
    return AppRoutingRule(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? 'Application',
      bundlePath: json['bundlePath']?.toString() ?? '',
      bundleIdentifier: json['bundleIdentifier']?.toString() ?? '',
      signingIdentifier:
          json['signingIdentifier']?.toString() ??
          json['bundleIdentifier']?.toString() ??
          '',
      teamIdentifier: json['teamIdentifier']?.toString() ?? '',
      helperSigningIdentifiers: _stringList(json['helperSigningIdentifiers']),
      iconPngBase64: json['iconPngBase64']?.toString(),
      interfaceId: json['interfaceId']?.toString() ?? '',
      enabled: json['enabled'] as bool? ?? true,
      failurePolicy: policy == AppRoutingFailurePolicy.fallback.name
          ? AppRoutingFailurePolicy.fallback
          : AppRoutingFailurePolicy.block,
      status: AppRoutingRuleStatus.values.firstWhere(
        (value) => value.name == status,
        orElse: () => AppRoutingRuleStatus.pending,
      ),
      lastError: json['lastError']?.toString(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'displayName': displayName,
    'bundlePath': bundlePath,
    'bundleIdentifier': bundleIdentifier,
    'signingIdentifier': signingIdentifier,
    'teamIdentifier': teamIdentifier,
    'helperSigningIdentifiers': helperSigningIdentifiers,
    'iconPngBase64': iconPngBase64,
    'interfaceId': interfaceId,
    'enabled': enabled,
    'failurePolicy': failurePolicy.name,
    'status': status.name,
    'lastError': lastError,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> toProviderJson() => {
    'id': id,
    'displayName': displayName,
    'signingIdentifier': signingIdentifier,
    'teamIdentifier': teamIdentifier,
    'helperSigningIdentifiers': helperSigningIdentifiers,
    'interfaceId': interfaceId,
    'enabled': enabled,
    'failurePolicy': failurePolicy.name,
  };
}

@immutable
class AppRoutingConfiguration {
  const AppRoutingConfiguration({
    required this.masterEnabled,
    required this.rules,
  });

  final bool masterEnabled;
  final List<AppRoutingRule> rules;

  String get hash {
    final normalizedRules = rules.map((rule) => rule.toProviderJson()).toList()
      ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final payload = jsonEncode({
      'version': 1,
      'masterEnabled': masterEnabled,
      'rules': normalizedRules,
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.map((item) => item.toString()).toList(growable: false);
}
