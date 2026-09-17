import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum AppRoutingFailurePolicy { block, fallback }

enum AppRoutingRuleStatus { pending, active, disabled, error }

enum AppRoutingHostPlatform { macos, windows }

@immutable
class AppExecutableIdentity {
  const AppExecutableIdentity({
    required this.path,
    required this.wfpAppId,
    this.displayName,
    this.publisher,
    this.isSigned = false,
    this.enabled = true,
  });

  final String path;
  final String wfpAppId;
  final String? displayName;
  final String? publisher;
  final bool isSigned;
  final bool enabled;

  AppExecutableIdentity copyWith({bool? enabled}) => AppExecutableIdentity(
    path: path,
    wfpAppId: wfpAppId,
    displayName: displayName,
    publisher: publisher,
    isSigned: isSigned,
    enabled: enabled ?? this.enabled,
  );

  factory AppExecutableIdentity.fromMap(Map<Object?, Object?> map) =>
      AppExecutableIdentity(
        path: map['path']?.toString() ?? '',
        wfpAppId: map['wfpAppId']?.toString() ?? map['path']?.toString() ?? '',
        displayName: map['displayName']?.toString(),
        publisher: map['publisher']?.toString(),
        isSigned: map['isSigned'] as bool? ?? false,
        enabled: map['enabled'] as bool? ?? true,
      );

  Map<String, Object?> toJson() => {
    'path': path,
    'wfpAppId': wfpAppId,
    'displayName': displayName,
    'publisher': publisher,
    'isSigned': isSigned,
    'enabled': enabled,
  };
}

@immutable
class AppDescriptor {
  const AppDescriptor({
    required this.displayName,
    required this.bundlePath,
    required this.bundleIdentifier,
    required this.signingIdentifier,
    required this.teamIdentifier,
    this.helperSigningIdentifiers = const [],
    this.platform = AppRoutingHostPlatform.macos,
    this.executablePath,
    this.wfpAppId,
    this.publisher,
    this.isSigned = true,
    this.helperExecutables = const [],
    this.iconPngBase64,
  });

  final String displayName;
  final String bundlePath;
  final String bundleIdentifier;
  final String signingIdentifier;
  final String teamIdentifier;
  final List<String> helperSigningIdentifiers;
  final AppRoutingHostPlatform platform;
  final String? executablePath;
  final String? wfpAppId;
  final String? publisher;
  final bool isSigned;
  final List<AppExecutableIdentity> helperExecutables;
  final String? iconPngBase64;

  factory AppDescriptor.fromMap(Map<Object?, Object?> map) => AppDescriptor(
    displayName: map['displayName']?.toString() ?? '',
    bundlePath: map['bundlePath']?.toString() ?? '',
    bundleIdentifier: map['bundleIdentifier']?.toString() ?? '',
    signingIdentifier: map['signingIdentifier']?.toString() ?? '',
    teamIdentifier: map['teamIdentifier']?.toString() ?? '',
    helperSigningIdentifiers: _stringList(map['helperSigningIdentifiers']),
    platform: _platform(map['platform']),
    executablePath: map['executablePath']?.toString(),
    wfpAppId: map['wfpAppId']?.toString(),
    publisher: map['publisher']?.toString(),
    isSigned: map['isSigned'] as bool? ?? true,
    helperExecutables: _executableList(map['helperExecutables']),
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
    this.platform = AppRoutingHostPlatform.macos,
    this.executablePath,
    this.wfpAppId,
    this.publisher,
    this.isSigned = true,
    this.helperExecutables = const [],
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
  final AppRoutingHostPlatform platform;
  final String? executablePath;
  final String? wfpAppId;
  final String? publisher;
  final bool isSigned;
  final List<AppExecutableIdentity> helperExecutables;
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

  Set<String> get allWindowsAppIds => {
    if ((wfpAppId ?? '').isNotEmpty) wfpAppId!,
    for (final helper in helperExecutables)
      if (helper.enabled && helper.wfpAppId.isNotEmpty) helper.wfpAppId,
  };

  Set<String> get allIdentityKeys => platform == AppRoutingHostPlatform.windows
      ? allWindowsAppIds.map((value) => value.toLowerCase()).toSet()
      : allSigningIdentifiers;

  AppRoutingRule copyWith({
    String? displayName,
    String? bundlePath,
    String? bundleIdentifier,
    String? signingIdentifier,
    String? teamIdentifier,
    List<String>? helperSigningIdentifiers,
    AppRoutingHostPlatform? platform,
    String? executablePath,
    String? wfpAppId,
    String? publisher,
    bool? isSigned,
    List<AppExecutableIdentity>? helperExecutables,
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
    platform: platform ?? this.platform,
    executablePath: executablePath ?? this.executablePath,
    wfpAppId: wfpAppId ?? this.wfpAppId,
    publisher: publisher ?? this.publisher,
    isSigned: isSigned ?? this.isSigned,
    helperExecutables: helperExecutables ?? this.helperExecutables,
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
      platform: _platform(json['platform']),
      executablePath: json['executablePath']?.toString(),
      wfpAppId: json['wfpAppId']?.toString(),
      publisher: json['publisher']?.toString(),
      isSigned: json['isSigned'] as bool? ?? true,
      helperExecutables: _executableList(json['helperExecutables']),
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
    'platform': platform.name,
    'executablePath': executablePath,
    'wfpAppId': wfpAppId,
    'publisher': publisher,
    'isSigned': isSigned,
    'helperExecutables': helperExecutables
        .map((item) => item.toJson())
        .toList(),
    'iconPngBase64': iconPngBase64,
    'interfaceId': interfaceId,
    'enabled': enabled,
    'failurePolicy': failurePolicy.name,
    'status': status.name,
    'lastError': lastError,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> toProviderJson() {
    final signingHelpers = List<String>.of(helperSigningIdentifiers)..sort();
    final executableHelpers =
        helperExecutables
            .where((item) => item.enabled)
            .map((item) => item.toJson())
            .toList()
          ..sort(
            (left, right) => (left['path'] as String).toLowerCase().compareTo(
              (right['path'] as String).toLowerCase(),
            ),
          );
    return {
      'id': id,
      'displayName': displayName,
      'signingIdentifier': signingIdentifier,
      'teamIdentifier': teamIdentifier,
      'helperSigningIdentifiers': signingHelpers,
      'platform': platform.name,
      'executablePath': executablePath,
      'wfpAppId': wfpAppId,
      'publisher': publisher,
      'isSigned': isSigned,
      'helperExecutables': executableHelpers,
      'interfaceId': interfaceId,
      'enabled': enabled,
      'failurePolicy': failurePolicy.name,
    };
  }
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
      'version': 2,
      'masterEnabled': masterEnabled,
      'rules': normalizedRules,
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }
}

AppRoutingHostPlatform _platform(Object? value) =>
    value?.toString() == AppRoutingHostPlatform.windows.name
    ? AppRoutingHostPlatform.windows
    : AppRoutingHostPlatform.macos;

List<AppExecutableIdentity> _executableList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => AppExecutableIdentity.fromMap(item))
      .toList(growable: false);
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value.map((item) => item.toString()).toList(growable: false);
}
