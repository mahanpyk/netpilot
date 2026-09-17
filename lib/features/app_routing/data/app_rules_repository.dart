import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../../core/models/app_routing_rule.dart';

class StoredAppRoutingState {
  const StoredAppRoutingState({
    required this.masterEnabled,
    required this.rules,
  });

  final bool masterEnabled;
  final List<AppRoutingRule> rules;
}

abstract class AppRulesRepository {
  Future<StoredAppRoutingState> load();
  Future<void> save(StoredAppRoutingState state);
}

class FileAppRulesRepository implements AppRulesRepository {
  FileAppRulesRepository({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  static const _fileName = 'netpilot_app_rules.json';

  Future<File> _file() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return File('${directory.path}/$_fileName');
  }

  @override
  Future<StoredAppRoutingState> load() async {
    final file = await _file();
    if (!await file.exists()) {
      return const StoredAppRoutingState(masterEnabled: false, rules: []);
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is List) {
      return StoredAppRoutingState(
        masterEnabled: false,
        rules: decoded
            .whereType<Map>()
            .map(
              (item) =>
                  AppRoutingRule.fromJson(Map<String, Object?>.from(item)),
            )
            .toList(),
      );
    }
    if (decoded is! Map) {
      return const StoredAppRoutingState(masterEnabled: false, rules: []);
    }
    final map = Map<String, Object?>.from(decoded);
    final rawRules = map['rules'];
    return StoredAppRoutingState(
      masterEnabled: map['masterEnabled'] as bool? ?? false,
      rules: rawRules is List
          ? rawRules
                .whereType<Map>()
                .map(
                  (item) =>
                      AppRoutingRule.fromJson(Map<String, Object?>.from(item)),
                )
                .toList()
          : const [],
    );
  }

  @override
  Future<void> save(StoredAppRoutingState state) async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'masterEnabled': state.masterEnabled,
        'rules': state.rules.map((rule) => rule.toJson()).toList(),
      }),
    );
  }
}

class MemoryAppRulesRepository implements AppRulesRepository {
  StoredAppRoutingState state = const StoredAppRoutingState(
    masterEnabled: false,
    rules: [],
  );

  @override
  Future<StoredAppRoutingState> load() async => state;

  @override
  Future<void> save(StoredAppRoutingState state) async {
    this.state = StoredAppRoutingState(
      masterEnabled: state.masterEnabled,
      rules: List.of(state.rules),
    );
  }
}
