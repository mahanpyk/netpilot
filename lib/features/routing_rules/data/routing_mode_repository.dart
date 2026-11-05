import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/routing_mode.dart';

abstract class RoutingModeRepository {
  Future<RoutingMode> load();
  Future<void> save(RoutingMode mode);
}

class FileRoutingModeRepository implements RoutingModeRepository {
  FileRoutingModeRepository({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;
  static const _fileName = 'netpilot_routing_mode.json';

  Future<File> _file() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}/$_fileName');
  }

  @override
  Future<RoutingMode> load() async {
    final file = await _file();
    if (!await file.exists()) return RoutingMode.custom;
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) return RoutingMode.custom;
    Object? data;
    try {
      data = jsonDecode(contents);
    } on FormatException catch (error) {
      stderr.writeln('[NetPilot] Invalid routing mode preferences: $error');
      return RoutingMode.custom;
    }
    if (data is! Map) return RoutingMode.custom;
    final value = data['routingMode'];
    return RoutingMode.values.where((mode) => mode.name == value).firstOrNull ??
        RoutingMode.custom;
  }

  @override
  Future<void> save(RoutingMode mode) async {
    final file = await _file();
    final stagingDirectory = await file.parent.createTemp('.netpilot-mode-');
    try {
      final stagingFile = File('${stagingDirectory.path}/routing_mode.json');
      await stagingFile.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'schemaVersion': 1, 'routingMode': mode.name}),
        flush: true,
      );
      await stagingFile.rename(file.path);
    } finally {
      await stagingDirectory.delete(recursive: true);
    }
  }
}

class MemoryRoutingModeRepository implements RoutingModeRepository {
  RoutingMode _mode = RoutingMode.custom;

  @override
  Future<RoutingMode> load() async => _mode;

  @override
  Future<void> save(RoutingMode mode) async {
    _mode = mode;
  }
}
