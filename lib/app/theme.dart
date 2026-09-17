import 'package:flutter/material.dart';

ThemeData buildNetPilotTheme({Brightness brightness = Brightness.dark}) {
  const lightSeed = Color(0xFF0B6E4F);
  const darkSeed = Color(0xFF28A96B);
  final seed = brightness == Brightness.dark ? darkSeed : lightSeed;
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.comfortable,
    scaffoldBackgroundColor: isDark
        ? const Color(0xFF0D0F12)
        : const Color(0xFFF4F7F5),
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? const Color(0xFF171A1F) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true,
      fillColor: isDark ? const Color(0xFF171A1F) : Colors.white,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: false,
    ),
  );
}
