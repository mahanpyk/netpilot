import '../models/routing_rule.dart';

class ParsedDestination {
  const ParsedDestination({
    required this.kind,
    required this.normalized,
    required this.raw,
  });

  final DestinationKind kind;
  final String normalized;
  final String raw;
}

class DestinationParseException implements Exception {
  DestinationParseException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Parses hostname / URL (hostname only) / IPv4 / CIDR.
class DestinationParser {
  const DestinationParser();

  static final _ipv4 = RegExp(
    r'^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}'
    r'(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$',
  );

  static final _hostname = RegExp(
    r'^(?=.{1,253}$)(?!-)[A-Za-z0-9-]{1,63}(?<!-)'
    r'(?:\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*$',
  );

  ParsedDestination parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw DestinationParseException('Destination is empty');
    }

    // URL first — extract host only (path/query discarded)
    final lower = raw.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        raw.contains('://')) {
      final uri = Uri.tryParse(raw);
      final host = uri?.host;
      if (host == null || host.isEmpty) {
        throw DestinationParseException('URL has no hostname: $raw');
      }
      if (_ipv4.hasMatch(host)) {
        return ParsedDestination(
          kind: DestinationKind.url,
          normalized: host,
          raw: raw,
        );
      }
      if (!_hostname.hasMatch(host)) {
        throw DestinationParseException('Invalid hostname in URL: $host');
      }
      return ParsedDestination(
        kind: DestinationKind.url,
        normalized: host.toLowerCase(),
        raw: raw,
      );
    }

    // CIDR: a.b.c.d/nn
    final slash = raw.indexOf('/');
    if (slash > 0) {
      final ip = raw.substring(0, slash);
      final prefix = int.tryParse(raw.substring(slash + 1));
      if (_ipv4.hasMatch(ip) && prefix != null && prefix >= 0 && prefix <= 32) {
        return ParsedDestination(
          kind: DestinationKind.cidr,
          normalized: '$ip/$prefix',
          raw: raw,
        );
      }
      throw DestinationParseException('Invalid IPv4 CIDR: $raw');
    }

    if (_ipv4.hasMatch(raw)) {
      return ParsedDestination(
        kind: DestinationKind.ipv4,
        normalized: raw,
        raw: raw,
      );
    }

    // Bare hostname (optional trailing path accidentally pasted — reject)
    if (raw.contains('/') || raw.contains(' ')) {
      throw DestinationParseException(
        'Use a hostname, URL, IPv4, or CIDR — path routing is not supported',
      );
    }

    // Strip trailing dot
    final host = raw.endsWith('.') ? raw.substring(0, raw.length - 1) : raw;
    if (!_hostname.hasMatch(host)) {
      throw DestinationParseException('Invalid destination: $raw');
    }
    return ParsedDestination(
      kind: DestinationKind.hostname,
      normalized: host.toLowerCase(),
      raw: raw,
    );
  }

  /// Host / IP destinations become /32 CIDR for the route table.
  String toRouteCidr(ParsedDestination parsed, {String? resolvedIp}) {
    switch (parsed.kind) {
      case DestinationKind.cidr:
        return parsed.normalized;
      case DestinationKind.ipv4:
        return '${parsed.normalized}/32';
      case DestinationKind.hostname:
      case DestinationKind.url:
        if (resolvedIp == null || !_ipv4.hasMatch(resolvedIp)) {
          throw DestinationParseException(
            'Resolved IP required for ${parsed.normalized}',
          );
        }
        return '$resolvedIp/32';
    }
  }

  bool isIpv4(String value) => _ipv4.hasMatch(value);
}
