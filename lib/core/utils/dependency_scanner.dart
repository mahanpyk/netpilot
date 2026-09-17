import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

class DependencyScanResult {
  const DependencyScanResult({
    required this.destinations,
    required this.finalUri,
  });

  final List<String> destinations;
  final Uri finalUri;
}

class DependencyScanException implements Exception {
  const DependencyScanException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class DependencyScanner {
  Future<DependencyScanResult> scan(Uri uri);
}

class HttpDependencyScanner implements DependencyScanner {
  HttpDependencyScanner({
    this.maxRedirects = 5,
    this.maxScripts = 20,
    this.requestTimeout = const Duration(seconds: 10),
    this.maxTotalBytes = 10 * 1024 * 1024,
  });

  final int maxRedirects;
  final int maxScripts;
  final Duration requestTimeout;
  final int maxTotalBytes;

  static final _javascriptRequestPatterns = [
    RegExp(
      r'''(?:\b(?:url|endpoint|baseURL|src|href)\s*[:=]\s*|\b(?:fetch|importScripts)\s*\(\s*|\baxios\.(?:get|post|put|patch|delete|head)\s*\(\s*)["']((?:https?:)?//[^\s"'\\]+)["']''',
      caseSensitive: false,
    ),
    RegExp(
      r'''\.open\s*\(\s*["'][^"']+["']\s*,\s*["']((?:https?:)?//[^\s"'\\]+)["']''',
      caseSensitive: false,
    ),
  ];
  static final _ipv4 = RegExp(
    r'^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}'
    r'(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$',
  );
  static final _hostname = RegExp(
    r'^(?=.{1,253}$)(?!-)[A-Za-z0-9-]{1,63}(?<!-)'
    r'(?:\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*$',
  );

  @override
  Future<DependencyScanResult> scan(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const DependencyScanException(
        'Dependency scan requires an HTTP or HTTPS URL.',
      );
    }

    final client = HttpClient()
      ..connectionTimeout = requestTimeout
      ..userAgent = 'NetPilot/1.0 dependency scanner';
    var consumedBytes = 0;
    final destinations = <String>{};

    try {
      final page = await _fetch(
        client,
        uri,
        onBytes: (count) {
          consumedBytes += count;
          if (consumedBytes > maxTotalBytes) {
            throw DependencyScanException(
              'Dependency scan exceeded ${maxTotalBytes ~/ (1024 * 1024)} MB.',
            );
          }
        },
      );
      destinations.addAll(page.redirectHosts);

      final mimeType = page.contentType?.mimeType.toLowerCase();
      if (mimeType != null &&
          mimeType != 'text/html' &&
          mimeType != 'application/xhtml+xml') {
        throw DependencyScanException(
          'Expected an HTML page but received $mimeType.',
        );
      }

      final document = html_parser.parse(
        page.body,
        sourceUrl: page.uri.toString(),
      );
      final baseUri = _documentBaseUri(document, page.uri);
      final scripts = <Uri>{};

      void register(String? value, {bool script = false}) {
        final dependency = _resolveWebUri(value, baseUri);
        if (dependency == null) return;
        destinations.add(_normalizedHost(dependency));
        if (script && _sameOrigin(dependency, page.uri)) {
          scripts.add(dependency.replace(fragment: ''));
        }
      }

      for (final element in document.querySelectorAll('script')) {
        final src = element.attributes['src'];
        if (src != null && src.trim().isNotEmpty) {
          register(src, script: true);
        } else {
          _registerJavaScriptUrls(element.text, baseUri, register);
        }
      }

      const resourceAttributes = <String, String>{
        'img': 'src',
        'source': 'src',
        'video': 'src',
        'audio': 'src',
        'iframe': 'src',
        'embed': 'src',
        'object': 'data',
        'form': 'action',
      };
      for (final entry in resourceAttributes.entries) {
        for (final element in document.querySelectorAll(
          '${entry.key}[${entry.value}]',
        )) {
          register(element.attributes[entry.value]);
        }
      }

      for (final element in document.querySelectorAll(
        'img[srcset], source[srcset]',
      )) {
        for (final candidate in _srcSetUrls(element.attributes['srcset'])) {
          register(candidate);
        }
      }

      const dependencyLinkRelations = {
        'stylesheet',
        'icon',
        'preload',
        'prefetch',
        'modulepreload',
        'preconnect',
        'dns-prefetch',
      };
      for (final element in document.querySelectorAll('link[href]')) {
        final relations = (element.attributes['rel'] ?? '')
            .toLowerCase()
            .split(RegExp(r'\s+'))
            .where((value) => value.isNotEmpty)
            .toSet();
        if (relations.any(dependencyLinkRelations.contains)) {
          register(element.attributes['href']);
        }
      }

      if (scripts.length > maxScripts) {
        throw DependencyScanException(
          'Page references ${scripts.length} same-origin scripts; limit is $maxScripts.',
        );
      }
      for (final script in scripts) {
        final response = await _fetch(
          client,
          script,
          onBytes: (count) {
            consumedBytes += count;
            if (consumedBytes > maxTotalBytes) {
              throw DependencyScanException(
                'Dependency scan exceeded ${maxTotalBytes ~/ (1024 * 1024)} MB.',
              );
            }
          },
        );
        destinations.addAll(response.redirectHosts);
        _registerJavaScriptUrls(response.body, response.uri, register);
      }

      destinations.remove(_normalizedHost(uri));
      final sorted = destinations.where((host) => host.isNotEmpty).toList()
        ..sort();
      return DependencyScanResult(destinations: sorted, finalUri: page.uri);
    } on DependencyScanException {
      rethrow;
    } on TimeoutException {
      throw const DependencyScanException('Dependency scan timed out.');
    } on HandshakeException catch (error) {
      throw DependencyScanException('TLS failed: ${error.message}');
    } on SocketException catch (error) {
      throw DependencyScanException('Connection failed: ${error.message}');
    } on HttpException catch (error) {
      throw DependencyScanException(error.message);
    } catch (error) {
      throw DependencyScanException('Dependency scan failed: $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<_FetchedResource> _fetch(
    HttpClient client,
    Uri initialUri, {
    required void Function(int count) onBytes,
  }) async {
    var current = initialUri;
    final redirectHosts = <String>{};

    for (var redirectCount = 0; ; redirectCount++) {
      final request = await client.getUrl(current).timeout(requestTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close().timeout(requestTimeout);

      if (response.isRedirect) {
        if (redirectCount >= maxRedirects) {
          await response.drain<void>();
          throw DependencyScanException(
            'Dependency scan exceeded $maxRedirects redirects.',
          );
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || location.trim().isEmpty) {
          throw const DependencyScanException(
            'Redirect response did not include a location.',
          );
        }
        final next = current.resolve(location);
        if (next.scheme != 'http' && next.scheme != 'https') {
          throw DependencyScanException(
            'Redirected to unsupported scheme ${next.scheme}.',
          );
        }
        redirectHosts.add(_normalizedHost(next));
        current = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw DependencyScanException(
          'Request to $current returned HTTP ${response.statusCode}.',
        );
      }

      final bytes = <int>[];
      await for (final chunk in response.timeout(requestTimeout)) {
        onBytes(chunk.length);
        bytes.addAll(chunk);
      }
      return _FetchedResource(
        uri: current,
        body: utf8.decode(bytes, allowMalformed: true),
        contentType: response.headers.contentType,
        redirectHosts: redirectHosts,
      );
    }
  }

  Uri _documentBaseUri(Document document, Uri responseUri) {
    final value = document.querySelector('base[href]')?.attributes['href'];
    return _resolveWebUri(value, responseUri) ?? responseUri;
  }

  void _registerJavaScriptUrls(
    String source,
    Uri baseUri,
    void Function(String? value, {bool script}) register,
  ) {
    final normalized = source
        .replaceAll(r'\/', '/')
        .replaceAll(RegExp(r'\\u002[fF]'), '/');
    for (final pattern in _javascriptRequestPatterns) {
      for (final match in pattern.allMatches(normalized)) {
        register(match.group(1));
      }
    }
  }

  Iterable<String> _srcSetUrls(String? value) sync* {
    if (value == null) return;
    for (final candidate in value.split(',')) {
      final url = candidate.trim().split(RegExp(r'\s+')).firstOrNull;
      if (url != null && url.isNotEmpty) yield url;
    }
  }

  Uri? _resolveWebUri(String? value, Uri baseUri) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty || raw.startsWith('data:')) return null;
    try {
      final uri = raw.startsWith('//')
          ? Uri.parse('${baseUri.scheme}:$raw')
          : baseUri.resolve(raw);
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          !_isValidHost(uri.host)) {
        return null;
      }
      return uri;
    } on FormatException {
      return null;
    }
  }

  bool _sameOrigin(Uri a, Uri b) {
    return a.scheme == b.scheme &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
  }

  String _normalizedHost(Uri uri) {
    return uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  }

  bool _isValidHost(String value) {
    final host = value.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    return _ipv4.hasMatch(host) || _hostname.hasMatch(host);
  }
}

class _FetchedResource {
  const _FetchedResource({
    required this.uri,
    required this.body,
    required this.contentType,
    required this.redirectHosts,
  });

  final Uri uri;
  final String body;
  final ContentType? contentType;
  final Set<String> redirectHosts;
}
