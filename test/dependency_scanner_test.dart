import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/utils/dependency_scanner.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test(
    'discovers redirects, HTML resources, inline JS, and same-origin JS',
    () async {
      server.listen((request) async {
        switch (request.uri.path) {
          case '/start':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${server.port}/page',
            );
            break;
          case '/page':
            request.response.headers.contentType = ContentType.html;
            request.response.write('''
            <html>
              <head>
                <link rel="stylesheet" href="https://cdn.example.test/app.css">
                <link rel="preconnect" href="//fonts.example.test">
                <script src="/app.js"></script>
                <script>
                  fetch('https://api.example.test/v1');
                  const duplicate = 'https://cdn.example.test/other';
                </script>
              </head>
              <body>
                <img src="https://images.example.test/image.png">
                <a href="https://ignored.example.test/page">ordinary link</a>
              </body>
            </html>
          ''');
            break;
          case '/app.js':
            request.response.headers.contentType = ContentType(
              'application',
              'javascript',
            );
            request.response.write(
              "const docs = 'https://docs.example.test';"
              "fetch('https://telemetry.example.test/events');",
            );
            break;
          default:
            request.response.statusCode = HttpStatus.notFound;
            break;
        }
        await request.response.close();
      });

      final scanner = HttpDependencyScanner();
      final result = await scanner.scan(
        Uri.parse('http://localhost:${server.port}/start'),
      );

      expect(result.finalUri.host, '127.0.0.1');
      expect(result.destinations, [
        '127.0.0.1',
        'api.example.test',
        'cdn.example.test',
        'fonts.example.test',
        'images.example.test',
        'telemetry.example.test',
      ]);
      expect(result.destinations, isNot(contains('ignored.example.test')));
      expect(result.destinations, isNot(contains('docs.example.test')));
    },
  );

  test('rejects a non-HTML root response', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":true}');
      await request.response.close();
    });

    final scanner = HttpDependencyScanner();
    expect(
      () => scanner.scan(Uri.parse('http://127.0.0.1:${server.port}/data')),
      throwsA(
        isA<DependencyScanException>().having(
          (error) => error.message,
          'message',
          contains('Expected an HTML page'),
        ),
      ),
    );
  });

  test('enforces redirect limit', () async {
    server.listen((request) async {
      final count = int.tryParse(request.uri.pathSegments.last) ?? 0;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        '/redirect/${count + 1}',
      );
      await request.response.close();
    });

    final scanner = HttpDependencyScanner(maxRedirects: 2);
    expect(
      () =>
          scanner.scan(Uri.parse('http://127.0.0.1:${server.port}/redirect/0')),
      throwsA(
        isA<DependencyScanException>().having(
          (error) => error.message,
          'message',
          contains('exceeded 2 redirects'),
        ),
      ),
    );
  });
}
