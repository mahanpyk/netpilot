import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/netpilot_app.dart';
import 'core/platform/network_platform.dart';
import 'features/routing_rules/data/rules_repository.dart';
import 'features/routing_rules/domain/netpilot_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final platform = (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS))
      ? MethodChannelNetworkPlatform()
      : FakeNetworkPlatform();

  final controller = NetPilotController(
    platform: platform,
    rulesRepository: FileRulesRepository(),
  );

  runApp(NetPilotApp(controller: controller));
  // Kick off after first frame so UI can show loading state.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    controller.start();
  });
}
