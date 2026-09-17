import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../core/models/routing_rule.dart';

abstract class RulesRepository {
  Future<List<RoutingRule>> load();
  Future<void> save(List<RoutingRule> rules);
}

class FileRulesRepository implements RulesRepository {
  FileRulesRepository({Future<Directory> Function()? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  static const _fileName = 'netpilot_rules.json';

  Future<File> _file() async {
    final dir = await _directoryProvider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_fileName');
  }

  @override
  Future<List<RoutingRule>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final text = await file.readAsString();
    if (text.trim().isEmpty) return [];
    final decoded = jsonDecode(text);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => RoutingRule.fromJson(Map<String, Object?>.from(e)))
        .toList();
  }

  @override
  Future<void> save(List<RoutingRule> rules) async {
    final file = await _file();
    final payload = rules.map((r) => r.toJson()).toList();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }
}

/// In-memory repo for tests.
class MemoryRulesRepository implements RulesRepository {
  List<RoutingRule> _rules = [];

  @override
  Future<List<RoutingRule>> load() async => List.of(_rules);

  @override
  Future<void> save(List<RoutingRule> rules) async {
    _rules = List.of(rules);
  }
}
