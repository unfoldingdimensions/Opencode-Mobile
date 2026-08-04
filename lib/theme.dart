import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Material 3 theme for OpenCode Mirror.
///
/// Theme mode follows the system. Google Fonts are fetched at runtime; on
/// failure they degrade to the platform default font instead of throwing,
/// so typography never blocks startup.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4F46E5),
    brightness: brightness,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final textTheme = _googleFontsTextTheme(base.textTheme);
  return base.copyWith(textTheme: textTheme);
}

TextTheme _googleFontsTextTheme(TextTheme base) {
  try {
    return GoogleFonts.interTextTheme(base);
  } catch (_) {
    return base;
  }
}
