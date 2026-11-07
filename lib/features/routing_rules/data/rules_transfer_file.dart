import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';

import 'rules_transfer.dart';

abstract class RulesTransferFile {
  Future<String?> read();
  Future<bool> write(String text);
}

class DesktopRulesTransferFile implements RulesTransferFile {
  const DesktopRulesTransferFile();

  static const _types = [
    XTypeGroup(label: 'NetPilot backup (JSON)', extensions: ['json']),
  ];

  @override
  Future<String?> read() async {
    final file = await FileSelectorPlatform.instance.openFile(
      acceptedTypeGroups: _types,
    );
    if (file == null) return null;
    if (await file.length() > RulesTransfer.maxFileBytes) {
      throw const FormatException('Backup must be smaller than 5 MB.');
    }
    return file.readAsString();
  }

  @override
  Future<bool> write(String text) async {
    final location = await FileSelectorPlatform.instance.getSaveLocation(
      acceptedTypeGroups: _types,
      options: const SaveDialogOptions(suggestedName: 'netpilot-rules.json'),
    );
    if (location == null) return false;
    final file = XFile.fromData(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'application/json',
      name: 'netpilot-rules.json',
    );
    await file.saveTo(location.path);
    return true;
  }
}
