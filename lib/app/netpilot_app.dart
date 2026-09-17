import 'package:flutter/material.dart';

import '../features/home/home_page.dart';
import '../features/routing_rules/domain/netpilot_controller.dart';
import 'theme.dart';

class NetPilotApp extends StatelessWidget {
  const NetPilotApp({super.key, required this.controller});

  final NetPilotController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetPilot',
      debugShowCheckedModeBanner: false,
      theme: buildNetPilotTheme(),
      home: HomePage(controller: controller),
    );
  }
}
