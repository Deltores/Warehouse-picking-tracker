import 'package:flutter/material.dart';

class AppTheme {
  // Status Colors
  static const Color statusComplete = Color(0xFF10B981); // Vivid Emerald Green
  static const Color statusPartial = Color(0xFFF59E0B);  // Vivid Amber Yellow
  static const Color statusUnpicked = Color(0xFF64748B); // Slate Grey
  static const Color statusDanger = Color(0xFFEF4444);   // Coral Red

  // Core Theme Palette
  static const Color primaryBlue = Color(0xFF0284C7);
  static const Color accentCyan = Color(0xFF38BDF8);
  static const Color bgDark = Color(0xFF0F172A);
  static const Color cardDark = Color(0xFF1E293B);
  static const Color borderDark = Color(0xFF334155);
  static const Color textLight = Color(0xFFF8FAFC);
  static const Color textMuted = Color(0xFF94A3B8);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      primaryColor: primaryBlue,
      colorScheme: const ColorScheme.dark(
        primary: primaryBlue,
        secondary: accentCyan,
        surface: cardDark,
        error: statusDanger,
      ),
      cardTheme: CardThemeData(
        color: cardDark,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderDark, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: cardDark,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textLight,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryBlue,
          foregroundColor: Colors.white,
          minimumSize: const Size(60, 52), // Tablet thumb friendly
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textLight,
          minimumSize: const Size(60, 52),
          side: const BorderSide(color: borderDark, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(color: textLight, fontSize: 26, fontWeight: FontWeight.bold),
        headlineMedium: TextStyle(color: textLight, fontSize: 22, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: textLight, fontSize: 18, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: textLight, fontSize: 16, fontWeight: FontWeight.w500),
        bodyLarge: TextStyle(color: textLight, fontSize: 15),
        bodyMedium: TextStyle(color: textMuted, fontSize: 13),
      ),
    );
  }
}
