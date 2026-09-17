import 'package:flutter/material.dart';

import '../features/home/home_page.dart';
import '../features/routing_rules/domain/netpilot_controller.dart';
import 'theme.dart';

class NetPilotApp extends StatefulWidget {
  const NetPilotApp({super.key, required this.controller});

  final NetPilotController controller;

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
        themeMode: _themeMode,
        onThemeChanged: (isDark) {
          setState(
            () => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light,
          );
        },
      ),
    );
  }
}
