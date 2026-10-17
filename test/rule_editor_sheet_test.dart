import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';
import 'package:netpilot_desktop/features/routing_rules/presentation/rule_editor_sheet.dart';

void main() {
  for (final action in ['Resolve preview', 'Save & apply']) {
    testWidgets('dismiss during $action safely ignores a later DNS error', (
      tester,
    ) async {
      final platform = _DeferredDnsPlatform();
      final controller = NetPilotController(
        platform: platform,
        rulesRepository: MemoryRulesRepository(),
      );
      addTearDown(controller.dispose);
      await controller.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RuleEditorSheet(controller: controller)),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'unknown.company.local',
      );
      await tester.tap(find.text(action));
      await tester.pump();

      // The sheet can be dismissed while a lookup is still in flight.
      await tester.pumpWidget(const SizedBox.shrink());
      platform.response.completeError(StateError('DNS disconnected'));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  }
}

class _DeferredDnsPlatform extends FakeNetworkPlatform {
  final response = Completer<ResolveHostResult>();

  @override
  Future<ResolveHostResult> resolveHost(String host, {String? interfaceId}) =>
      response.future;
}
