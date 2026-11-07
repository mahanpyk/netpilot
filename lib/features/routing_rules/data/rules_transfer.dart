import 'dart:convert';

import '../../../core/models/routing_rule.dart';
import '../../../core/utils/destination_parser.dart';

class RulesTransfer {
  const RulesTransfer();

  static const maxFileBytes = 5 * 1024 * 1024;
  static const _parser = DestinationParser();

  String encode(List<RoutingRule> rules) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': 'netpilot-destination-rules',
        'version': 1,
        'rules': [
          for (final rule in rules)
            {
              'destination': rule.rawDestination,
              'label': rule.label,
              'interface': rule.interfaceId,
              'enabled': rule.enabled,
              'hostIpv4': rule.hostIpv4,
              'dependencies': [
                for (final child in rule.subRules)
                  {'destination': child.destination, 'enabled': child.enabled},
              ],
            },
        ],
      });

  List<RoutingRule> decode(String text) {
    try {
      if (utf8.encode(text).length > maxFileBytes) {
        throw const FormatException('Backup must be smaller than 5 MB.');
      }
      final value = jsonDecode(text);
      if (value is! Map ||
          value['format'] != 'netpilot-destination-rules' ||
          value['version'] != 1) {
        throw const FormatException(
          'Unsupported NetPilot backup format or version.',
        );
      }
      final entries = value['rules'];
      if (entries is! List || entries.length > 1000) {
        throw const FormatException('Backup must contain at most 1000 rules.');
      }
      var dependencyCount = 0;
      final result = <RoutingRule>[];
      for (final entry in entries) {
        if (entry is! Map) throw const FormatException('Invalid rule.');
        final parsed = _parser.parse(_string(entry['destination']));
        final interface = _string(entry['interface']);
        final label = entry['label'];
        if (label != null && (label is! String || label.length > 4096)) {
          throw const FormatException('Invalid rule name.');
        }
        final pin = entry['hostIpv4'];
        if (pin != null &&
            (pin is! String ||
                !_parser.isIpv4(pin) ||
                _parser.isIpv4(parsed.normalized) ||
                (parsed.kind != DestinationKind.hostname &&
                    parsed.kind != DestinationKind.url))) {
          throw const FormatException('Invalid hostname IPv4 mapping.');
        }
        final children = entry['dependencies'];
        if (children is! List ||
            children.length > 256 ||
            (dependencyCount += children.length) > 10000) {
          throw const FormatException('Too many or invalid dependencies.');
        }
        final subRules = <RoutingSubRule>[];
        final seen = <String>{};
        for (final child in children) {
          if (child is! Map) throw const FormatException('Invalid dependency.');
          final destination = _parser.parse(_string(child['destination']));
          if (destination.kind != DestinationKind.hostname &&
              destination.kind != DestinationKind.ipv4) {
            throw const FormatException(
              'Dependencies must be hostnames or IPv4 addresses.',
            );
          }
          if (!seen.add(destination.normalized)) {
            throw const FormatException('Duplicate dependency.');
          }
          subRules.add(
            RoutingSubRule(
              id: 'import-child-${subRules.length}',
              destination: destination.normalized,
              kind: destination.kind,
              enabled: _bool(child['enabled']),
              resolvedIps: const [],
              status: RuleStatus.pending,
            ),
          );
        }
        result.add(
          RoutingRule(
            id: 'import-${result.length}',
            label: label as String?,
            rawDestination: parsed.raw,
            normalizedDestination: parsed.normalized,
            kind: parsed.kind,
            interfaceId: interface,
            enabled: _bool(entry['enabled']),
            hostIpv4: pin as String?,
            resolvedIps: const [],
            status: RuleStatus.pending,
            updatedAt: DateTime.now(),
            subRules: subRules,
            dependencyScanStatus: subRules.isEmpty
                ? DependencyScanStatus.notApplicable
                : DependencyScanStatus.succeeded,
          ),
        );
      }
      return result;
    } on DestinationParseException catch (error) {
      throw FormatException(error.message);
    }
  }

  String _string(Object? value) {
    if (value is! String || value.trim().isEmpty || value.length > 4096) {
      throw const FormatException('Missing or invalid destination/network.');
    }
    return value;
  }

  bool _bool(Object? value) {
    if (value is! bool) throw const FormatException('Invalid enabled setting.');
    return value;
  }
}
