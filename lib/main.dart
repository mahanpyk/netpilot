import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/netpilot_app.dart';
import 'core/models/app_routing_rule.dart';
import 'core/platform/network_platform.dart';
import 'core/platform/app_routing_platform.dart';
import 'features/app_routing/data/app_rules_repository.dart';
import 'features/app_routing/domain/app_routing_controller.dart';
import 'features/routing_rules/data/rules_repository.dart';
import 'features/routing_rules/data/routing_mode_repository.dart';
import 'features/routing_rules/domain/netpilot_controller.dart';
import 'features/routing_rules/domain/routing_mode.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final usesNativeDesktopBridge =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);
  final platform = usesNativeDesktopBridge
      ? MethodChannelNetworkPlatform()
      : FakeNetworkPlatform();

  final controller = NetPilotController(
    platform: platform,
    rulesRepository: FileRulesRepository(),
    routingModeRepository: FileRoutingModeRepository(),
  );
  final appPlatform = usesNativeDesktopBridge
      ? MethodChannelAppRoutingPlatform()
      : FakeAppRoutingPlatform();
  final appRoutingController = AppRoutingController(
    platform: appPlatform,
    repository: FileAppRulesRepository(),
    interfacesProvider: () => controller.interfaces,
    hostPlatform: defaultTargetPlatform == TargetPlatform.windows
        ? AppRoutingHostPlatform.windows
        : AppRoutingHostPlatform.macos,
  );

  Future<void>? startup;
  Future<void> startControllers() async {
    await controller.start();
    await appRoutingController.start();
    await appRoutingController.setGlobalRoutingEnabled(
      controller.routingMode == RoutingMode.custom,
    );
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await platform.setRoutingModeStatus(controller.routingMode.name);
    }
  }

  Future<void> modeChangeChain = Future<void>.value();
  Future<void> changeRoutingMode(RoutingMode mode) {
    final operation = modeChangeChain.then((_) async {
      await (startup ??= startControllers());
      if (mode == RoutingMode.systemDefault) {
        await appRoutingController.setGlobalRoutingEnabled(false);
        await controller.setRoutingMode(mode);
      } else {
        await controller.setRoutingMode(mode);
        await appRoutingController.setGlobalRoutingEnabled(true);
      }
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await platform.setRoutingModeStatus(controller.routingMode.name);
      }
    });
    modeChangeChain = operation.catchError((Object error) {
      debugPrint('[NetPilot] Routing mode change failed: $error');
    });
    return operation;
  }

  platform.lifecycleEvents.listen((event) {
    switch (event['type']) {
      case 'routingModeRequested':
        final mode = switch (event['mode']) {
          'systemDefault' => RoutingMode.systemDefault,
          'custom' => RoutingMode.custom,
          _ => null,
        };
        if (mode == null) {
          debugPrint('[NetPilot] Ignored invalid menu routing mode: $event');
          return;
        }
        unawaited(
          changeRoutingMode(mode).catchError((Object error) {
            debugPrint('[NetPilot] Menu routing mode failed: $error');
          }),
        );
      case 'quitRequested':
        unawaited(
          (() async {
            if (startup case final pendingStartup?) await pendingStartup;
            await modeChangeChain;
            await platform.completeQuit();
          })().catchError((Object error) {
            debugPrint('[NetPilot] Quit failed: $error');
          }),
        );
    }
  });
  runApp(
    NetPilotApp(
      controller: controller,
      appRoutingController: appRoutingController,
      onRoutingModeChanged: changeRoutingMode,
    ),
  );
  // Kick off after first frame so UI can show loading state.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    startup ??= startControllers();
  });
}
