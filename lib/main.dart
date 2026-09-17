import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/netpilot_app.dart';
import 'core/platform/network_platform.dart';
import 'core/platform/app_routing_platform.dart';
import 'features/app_routing/data/app_rules_repository.dart';
import 'features/app_routing/domain/app_routing_controller.dart';
import 'features/routing_rules/data/rules_repository.dart';
import 'features/routing_rules/domain/netpilot_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final platform = (!kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS))
      ? MethodChannelNetworkPlatform()
      : FakeNetworkPlatform();

  final controller = NetPilotController(
    platform: platform,
    rulesRepository: FileRulesRepository(),
  );
  final appPlatform = (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)
      ? MethodChannelAppRoutingPlatform()
      : FakeAppRoutingPlatform();
  final appRoutingController = AppRoutingController(
    platform: appPlatform,
    repository: FileAppRulesRepository(),
    interfacesProvider: () => controller.interfaces,
  );

  runApp(
    NetPilotApp(
      controller: controller,
      appRoutingController: appRoutingController,
    ),
  );
  // Kick off after first frame so UI can show loading state.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    controller.start();
    appRoutingController.start();
  });
}
