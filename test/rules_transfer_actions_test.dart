import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/core/platform/network_platform.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_repository.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_transfer.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_transfer_file.dart';
import 'package:netpilot_desktop/features/routing_rules/domain/netpilot_controller.dart';
import 'package:netpilot_desktop/features/routing_rules/presentation/rules_transfer_actions.dart';

import 'rules_transfer_test.dart' show sampleRule;

class FakeTransferFile implements RulesTransferFile {
  String? contents;
  String? saved;
  @override
  Future<String?> read() async => contents;
  @override
  Future<bool> write(String text) async {
    saved = text;
    return true;
  }
}

void main() {
  Future<(NetPilotController, FakeTransferFile)> setup(
    WidgetTester tester,
  ) async {
    final controller = NetPilotController(
      platform: FakeNetworkPlatform(),
      rulesRepository: MemoryRulesRepository(),
    );
    addTearDown(controller.dispose);
    await controller.start();
    final files = FakeTransferFile();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RulesTransferActions(controller: controller, files: files),
        ),
      ),
    );
    return (controller, files);
  }

  testWidgets('import requires network selection and adds paused rules', (
    tester,
  ) async {
    final (controller, files) = await setup(tester);
    files.contents = const RulesTransfer().encode([sampleRule()]);
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(controller.rules, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Import rules'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.textContaining('(en7)').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, 'Import rules'));
    await tester.pumpAndSettle();
    expect(controller.rules.single.enabled, isFalse);
    expect(controller.rules.single.interfaceId, 'en7');
    expect(find.textContaining('Imported 1 rule'), findsOneWidget);
  });
  testWidgets('cancellation and invalid backups leave rules intact', (
    tester,
  ) async {
    final (controller, files) = await setup(tester);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.text('Import rules'), findsNothing);
    files.contents = 'invalid';
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Import failed:'), findsOneWidget);
    expect(controller.rules, isEmpty);
    files.contents = const RulesTransfer().encode([sampleRule()]);
    await tester.tap(find.text('Import'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.rules, isEmpty);
  });
  testWidgets('export writes a portable backup', (tester) async {
    final (controller, files) = await setup(tester);
    await controller.importRules(
      [sampleRule()],
      interfaceMapping: {'old-lan': 'en7'},
    );
    await tester.pump();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(const RulesTransfer().decode(files.saved!).single.label, 'Company');
    expect(find.text('Rules exported.'), findsOneWidget);
  });
}
