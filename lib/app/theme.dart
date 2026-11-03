import 'package:flutter/material.dart';

import '../features/settings/domain/app_settings.dart';
import '../shared/ui/video_card_surface.dart';

abstract final class BiliTheme {
  static const accent = Color(0xFFD94B68);
  static const canvas = Colors.white;
  static const ink = Color(0xFF253343);

  static ThemeData light({
    AppFontPreference font = AppFontPreference.harmonyOsSans,
    String systemFontFamily = '',
    bool liquidVideoCards = true,
  }) => _build(
    Brightness.light,
    font.resolveFamily(systemFontFamily),
    liquidVideoCards,
  );
  static ThemeData dark({
    AppFontPreference font = AppFontPreference.harmonyOsSans,
    String systemFontFamily = '',
    bool liquidVideoCards = true,
  }) => _build(
    Brightness.dark,
    font.resolveFamily(systemFontFamily),
    liquidVideoCards,
  );

  static ThemeData _build(
    Brightness brightness,
    String? fontFamily,
    bool liquidVideoCards,
  ) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF1C2530) : canvas;
    final foreground = dark ? const Color(0xFFEAEAEA) : ink;
    final muted = dark ? const Color(0xFFACB8C7) : const Color(0xFF66778A);
    final panel = dark ? const Color(0xFF232F3D) : const Color(0xFFF2F6FA);
    final border = dark ? const Color(0xFF384657) : const Color(0xFFE1E9F1);
    final primary = dark ? const Color(0xFFEF8399) : accent;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: dark ? const Color(0xFF35131C) : Colors.white,
          primaryContainer: dark
              ? const Color(0xFF442730)
              : const Color(0xFFFFEFF2),
          onPrimaryContainer: primary,
          secondary: primary,
          surface: surface,
          onSurface: foreground,
          onSurfaceVariant: muted,
          surfaceContainerLowest: surface,
          surfaceContainerLow: panel,
          surfaceContainer: panel,
          surfaceContainerHigh: dark
              ? const Color(0xFF2C3948)
              : const Color(0xFFEAF1F7),
          surfaceContainerHighest: dark
              ? const Color(0xFF334252)
              : const Color(0xFFE3EDF5),
          outline: muted,
          outlineVariant: border,
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF141D27)
          : const Color(0xFFEDF3F9),
      dividerColor: border,
      hoverColor: primary.withValues(alpha: 0.045),
      focusColor: primary.withValues(alpha: 0.1),
      splashColor: primary.withValues(alpha: 0.08),
    );
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: primary),
        unselectedIconTheme: IconThemeData(color: muted),
        selectedLabelTextStyle: TextStyle(color: primary),
        unselectedLabelTextStyle: TextStyle(color: muted),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: panel,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
      ),
      extensions: [
        liquidVideoCards
            ? VideoCardSurface(
                enabled: true,
                cardRadius: 16,
                // The cover sits inside `inset`, so board 16 - inset 8 = cover 8
                // keeps the two curves concentric instead of fighting.
                coverRadius: 8,
                inset: 8,
                titleGap: 8,
                metaGap: 5,
                bottomGap: 9,
                bodyTop: dark
                    ? const Color(0x1FFFFFFF)
                    : const Color(0xCCFFFFFF),
                bodyBottom: dark
                    ? const Color(0x0FFFFFFF)
                    : const Color(0xA8FFFFFF),
                rim: dark ? const Color(0x30FFFFFF) : const Color(0xE6FFFFFF),
                rimHover: dark ? const Color(0x50FFFFFF) : Colors.white,
                shadowColor: dark
                    ? const Color(0x80000000)
                    : const Color(0x2610243A),
                shadowBlur: dark ? 16 : 14,
                shadowOffset: Offset(0, dark ? 8 : 6),
                backdropTop: dark
                    ? const Color(0xFF223141)
                    : const Color(0xFFF1F6FB),
                backdropBottom: dark
                    ? const Color(0xFF131C26)
                    : const Color(0xFFDFE9F3),
                titleSizes: const (compact: 13, medium: 14, regular: 15),
                metaSizes: const (compact: 10, medium: 11, regular: 12),
              )
            : VideoCardSurface.flat,
      ],
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: primary),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: controlShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: controlShape,
          side: BorderSide(color: border),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: controlShape),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: controlShape,
        side: BorderSide(color: border),
      ),
      textTheme: base.textTheme.copyWith(
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w500,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: muted,
        ),
      ),
    );
  }
}
