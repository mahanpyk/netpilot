import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_transfer.dart';
import 'package:netpilot_desktop/features/routing_rules/data/rules_transfer_file.dart';

class FakeFileSelector extends FileSelectorPlatform {
  XFile? selected;
  String? savePath;
  SaveDialogOptions? options;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => selected;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    this.options = options;
    return savePath == null ? null : FileSaveLocation(savePath!);
  }
}

void main() {
  late FakeFileSelector picker;
  late Directory temporary;
  const files = DesktopRulesTransferFile();
  setUp(() async {
    final previous = FileSelectorPlatform.instance;
    picker = FakeFileSelector();
    FileSelectorPlatform.instance = picker;
    temporary = await Directory.systemTemp.createTemp(
      'netpilot-transfer-test-',
    );
    addTearDown(() async {
      FileSelectorPlatform.instance = previous;
      await temporary.delete(recursive: true);
    });
  });
  test('canceled open/save does not access a file', () async {
    expect(await files.read(), isNull);
    expect(await files.write('test'), isFalse);
  });
  test('writes and reads UTF-8 through the chosen file', () async {
    picker.savePath = '${temporary.path}/rules.json';
    expect(await files.write('{"label":"شرکت"}'), isTrue);
    expect(picker.options!.suggestedName, 'netpilot-rules.json');
    picker.selected = XFile(picker.savePath!);
    expect(await files.read(), '{"label":"شرکت"}');
  });
  test('oversized file is rejected before decoding', () async {
    final file = File('${temporary.path}/large.json');
    await file.writeAsBytes(List.filled(RulesTransfer.maxFileBytes + 1, 32));
    picker.selected = XFile(file.path);
    await expectLater(files.read(), throwsFormatException);
  });
  test('read/write errors propagate to the UI', () async {
    picker.selected = XFile('${temporary.path}/missing.json');
    await expectLater(files.read(), throwsA(isA<FileSystemException>()));
    picker.savePath = '${temporary.path}/missing/rules.json';
    await expectLater(files.write('test'), throwsA(isA<FileSystemException>()));
  });
}
