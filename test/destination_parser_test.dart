import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/utils/destination_parser.dart';

void main() {
  const parser = DestinationParser();

  test('parses IPv4', () {
    final p = parser.parse('10.1.2.3');
    expect(p.kind.name, 'ipv4');
    expect(p.normalized, '10.1.2.3');
  });

  test('parses CIDR', () {
    final p = parser.parse('10.0.0.0/8');
    expect(p.kind.name, 'cidr');
    expect(p.normalized, '10.0.0.0/8');
  });

  test('rejects bad CIDR prefix', () {
    expect(() => parser.parse('10.0.0.0/99'), throwsA(isA<DestinationParseException>()));
  });

  test('parses hostname', () {
    final p = parser.parse('intranet.company.local');
    expect(p.kind.name, 'hostname');
    expect(p.normalized, 'intranet.company.local');
  });

  test('URL uses hostname only', () {
    final p = parser.parse('https://intranet.company.local/path?x=1');
    expect(p.kind.name, 'url');
    expect(p.normalized, 'intranet.company.local');
  });

  test('rejects path without scheme', () {
    expect(
      () => parser.parse('intranet.company.local/admin'),
      throwsA(isA<DestinationParseException>()),
    );
  });

  test('toRouteCidr for IP and hostname', () {
    final ip = parser.parse('1.2.3.4');
    expect(parser.toRouteCidr(ip), '1.2.3.4/32');
    final host = parser.parse('foo.bar');
    expect(parser.toRouteCidr(host, resolvedIp: '9.9.9.9'), '9.9.9.9/32');
  });
}
