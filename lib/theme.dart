import 'package:flutter/material.dart';

/// Visual theme inspired by the official *Magic: The Gathering Companion* app:
/// a dark, slate-and-ink background with warm "mana orange" accents, rounded
/// card surfaces, and a serif display face for headings. (Beleren is
/// proprietary, so we use the platform serif for that flavor.)
abstract final class AppTheme {
  static const Color _manaOrange = Color(0xFFF2A007);
  static const Color _ink = Color(0xFF0F1218);
  static const Color _surface = Color(0xFF181C25);
  static const Color _surfaceHi = Color(0xFF222734);

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _manaOrange,
          brightness: Brightness.dark,
        ).copyWith(
          surface: _surface,
          surfaceContainerHighest: _surfaceHi,
          primary: _manaOrange,
          onPrimary: Colors.black,
        );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: _ink,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: _ink,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // Min height only; a finite min width so buttons placed in a Row
          // (e.g. the join-by-code field) don't get infinite-width constraints.
          minimumSize: const Size(88, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _surfaceHi,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _surface,
        indicatorColor: _manaOrange.withValues(alpha: 0.18),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: base.textTheme.copyWith(
        headlineMedium: const TextStyle(
          fontFamily: 'serif',
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        titleLarge: const TextStyle(
          fontFamily: 'serif',
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
