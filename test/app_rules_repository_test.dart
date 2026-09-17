import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/features/app_routing/data/app_rules_repository.dart';

void main() {
  test('loads legacy list and writes versioned app routing state', () async {
    final directory = await Directory.systemTemp.createTemp(
      'netpilot-app-rules',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/netpilot_app_rules.json');
    await file.writeAsString(
      jsonEncode([
        {
          'id': 'legacy',
          'displayName': 'Legacy',
          'bundleIdentifier': 'example.legacy',
          'interfaceId': 'en0',
        },
      ]),
    );
    final repository = FileAppRulesRepository(
      directoryProvider: () async => directory,
    );

    final loaded = await repository.load();
    expect(loaded.masterEnabled, isFalse);
    expect(loaded.rules.single.signingIdentifier, 'example.legacy');

    await repository.save(
      StoredAppRoutingState(masterEnabled: true, rules: loaded.rules),
    );
    final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(saved['version'], 1);
    expect(saved['masterEnabled'], true);
    expect((saved['rules'] as List).single['failurePolicy'], 'block');
  });
}
