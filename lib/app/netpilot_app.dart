import 'package:flutter/material.dart';

import '../features/home/home_page.dart';
import '../features/app_routing/domain/app_routing_controller.dart';
import '../features/routing_rules/domain/netpilot_controller.dart';
import '../features/routing_rules/domain/routing_mode.dart';
import 'theme.dart';

class NetPilotApp extends StatefulWidget {
  const NetPilotApp({
    super.key,
    required this.controller,
    required this.appRoutingController,
    this.onRoutingModeChanged,
  });

  final NetPilotController controller;
  final AppRoutingController appRoutingController;
  final Future<void> Function(RoutingMode mode)? onRoutingModeChanged;

  @override
  State<NetPilotApp> createState() => _NetPilotAppState();
}

class _NetPilotAppState extends State<NetPilotApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetPilot',
      debugShowCheckedModeBanner: false,
      theme: buildNetPilotTheme(brightness: Brightness.light),
      darkTheme: buildNetPilotTheme(),
      themeMode: _themeMode,
      home: HomePage(
        controller: widget.controller,
        appRoutingController: widget.appRoutingController,
        themeMode: _themeMode,
        onThemeChanged: (isDark) {
          setState(
            () => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light,
          );
        },
        onRoutingModeChanged: (mode) async {
          if (widget.onRoutingModeChanged case final callback?) {
            await callback(mode);
          } else {
            await widget.controller.setRoutingMode(mode);
            await widget.appRoutingController.setGlobalRoutingEnabled(
              mode == RoutingMode.custom,
            );
          }
        },
      ),
    );
  }
}
