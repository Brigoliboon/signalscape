import 'package:flutter/material.dart';

import 'core/levels.dart';

/// The whole look of the app lives here: a dark "signal scanner" theme.
/// Change a colour or the type scale in this file and every screen follows.
abstract final class AppColors {
  // Surfaces, from the page background up to raised cards.
  static const background = Color(0xFF060A12);
  static const surface = Color(0xFF0D1524);
  static const surfaceHigh = Color(0xFF142036);
  static const outline = Color(0xFF263754);

  // Text. Both pass WCAG AA (4.5:1) on every surface above.
  static const textPrimary = Color(0xFFEAF1FB);
  static const textMuted = Color(0xFF9DB0CC);

  // Brand. The button fill is #1D4ED8; white text on it is 6.7:1.
  static const primary = Color(0xFF1D4ED8);
  static const onPrimary = Color(0xFFFFFFFF);
  static const accent = Color(0xFF38BDF8); // links, focus, radar sweep

  // Signal levels. Always shown together with a text label.
  static const good = Color(0xFF22C55E);
  static const fair = Color(0xFFFBBF24);
  static const dead = Color(0xFFFB7185);

  // Destructive action (End survey). White text on it is 5.9:1.
  static const danger = Color(0xFFB91C1C);
}

/// Monospace for dBm values, counters and other live numbers.
const String monoFamily = 'monospace';

TextStyle mono({
  double size = 14,
  FontWeight weight = FontWeight.w600,
  Color color = AppColors.textPrimary,
}) => TextStyle(
  fontFamily: monoFamily,
  fontFamilyFallback: const ['Roboto Mono', 'Courier New'],
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.1,
  letterSpacing: -0.5,
);

Color levelColor(SignalLevel level) => switch (level) {
  SignalLevel.good => AppColors.good,
  SignalLevel.fair => AppColors.fair,
  SignalLevel.dead => AppColors.dead,
};

/// Minimum touch target, in dp.
const double kTarget = 48;

/// A rounded card with a faint glow in [glow] (or the accent colour).
BoxDecoration glowCard({
  Color glow = AppColors.accent,
  double strength = 0.10,
}) => BoxDecoration(
  color: AppColors.surface,
  borderRadius: BorderRadius.circular(20),
  border: Border.all(color: AppColors.outline),
  boxShadow: [
    BoxShadow(
      color: glow.withValues(alpha: strength),
      blurRadius: 24,
      spreadRadius: -4,
    ),
  ],
);

ThemeData buildTheme() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        secondary: AppColors.accent,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        error: AppColors.dead,
        outline: AppColors.outline,
      );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  const buttonSize = Size.fromHeight(kTarget);
  const labelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: c, width: w),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.surface,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: ThemeData.dark().textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: AppColors.textPrimary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        shape: shape,
        textStyle: labelStyle,
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
        disabledBackgroundColor: AppColors.surfaceHigh,
        disabledForegroundColor: AppColors.textMuted,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        shape: shape,
        textStyle: labelStyle,
        foregroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.accent, width: 1.5),
        disabledForegroundColor: AppColors.textMuted,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(kTarget, kTarget),
        foregroundColor: AppColors.accent,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: const TextStyle(color: AppColors.textMuted),
      hintStyle: const TextStyle(color: AppColors.textMuted),
      border: border(AppColors.outline),
      enabledBorder: border(AppColors.outline),
      focusedBorder: border(AppColors.accent, 2),
      errorBorder: border(AppColors.dead),
      focusedErrorBorder: border(AppColors.dead, 2),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? AppColors.primary : null,
      ),
      checkColor: const WidgetStatePropertyAll(AppColors.onPrimary),
      side: const BorderSide(color: AppColors.textMuted, width: 2),
    ),
    dividerColor: AppColors.outline,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: TextStyle(color: AppColors.textPrimary, fontSize: 15),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
