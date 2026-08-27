import 'package:flutter/material.dart';

/// Single source of truth for color. The brand accent stays the signature
/// bilibeat pink; everything else is a calm, cool neutral ramp so the accent
/// (and the album art) are the only saturated things on screen — the core of a
/// "premium" feel.
class AppColors {
  // Brand
  static const Color accent = Color(0xFFFF3366);
  static const Color pinkStart = Color(0xFFFF6699);
  static const Color pinkEnd = Color(0xFFFF3366);
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [pinkStart, pinkEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Precomputed opacity colors (avoids runtime Color allocations)
  static const Color accent14 = Color(0x24FF3366);   // accent 14%
  static const Color accent30 = Color(0x4DFF3366);   // accent 30%
  static const Color accent22 = Color(0x38FF3366);   // accent 22%
  static const Color accent04 = Color(0x0AFF3366);   // accent 4%
  static const Color accent12 = Color(0x1FFF3366);   // accent 12%
  static const Color accent50 = Color(0x80FF3366);   // accent 50%
  static const Color success12 = Color(0x1F34C77B);  // success 12%
  static const Color success50 = Color(0x8034C77B);  // success 50%
  static const Color black45 = Color(0x73000000);     // black 45%
  static const Color black50 = Color(0x80000000);     // black 50%
  static const Color black55 = Color(0x8C000000);     // black 55%
  static const Color white05 = Color(0x0DFFFFFF);     // white 5%
  static const Color white06 = Color(0x0FFFFFFF);     // white 6%
  static const Color white10 = Color(0x1AFFFFFF);     // white 10%
  static const Color white12 = Color(0x1FFFFFFF);     // white 12%
  static const Color white24 = Color(0x3DFFFFFF);     // white 24%

  // Neutral ramp (cool near-black, not pure #000 — reads more refined).
  static const Color background = Color(0xFF08080A);
  static const Color backgroundElevated = Color(0xFF101014);
  /// One step deeper than [backgroundElevated]: nested surfaces and the cover
  /// placeholder read as "card on card" instead of fighting for the same tone.
  static const Color surfaceDeep = Color(0xFF141416);
  static const Color surfaceCard = Color(0x0AFFFFFF); // ~4% white
  static const Color hairline = Color(0x14FFFFFF); // subtle borders
  static const Color hairlineStrong = Color(0x26FFFFFF);
  /// Neutral pair for muted two-stop gradients (track-placeholder art, etc.).
  static const Color surfaceNeutral = Color(0xFF3A3A40);
  static const Color surfaceNeutralDeep = Color(0xFF232327);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF); // 70%
  static const Color textMuted = Color(0x8CFFFFFF); // 55%
  static const Color textFaint = Color(0x59FFFFFF); // 35%

  // Semantic
  static const Color success = Color(0xFF34C77B);
  static const Color danger = Color(0xFFFF453A);
}

/// Runtime palette used by widgets.  Unlike the legacy constants above this
/// palette follows both the selected brightness and the user's accent color.
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.accent,
    required this.accentSoft,
    required this.background,
    required this.backgroundElevated,
    required this.surfaceDeep,
    required this.surfaceCard,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.hairline,
    required this.danger,
    required this.success,
  });

  final Color accent, accentSoft, background, backgroundElevated, surfaceDeep;
  final Color surfaceCard, textPrimary, textSecondary, textMuted, textFaint;
  final Color hairline, danger, success;

  LinearGradient get primaryGradient => LinearGradient(colors: [accentSoft, accent]);
  Color get accent14 => accent.withValues(alpha: 0.14);
  Color get accent30 => accent.withValues(alpha: 0.30);
  Color get accent50 => accent.withValues(alpha: 0.50);
  Color get accent12 => accent.withValues(alpha: 0.12);
  Color get accent04 => accent.withValues(alpha: 0.04);

  factory AppPalette.from(ThemeMode mode, Color accent) {
    final dark = mode != ThemeMode.light;
    return AppPalette(
      accent: accent,
      accentSoft: accent.withValues(alpha: dark ? .14 : .12),
      background: dark ? AppColors.background : const Color(0xFFF7F7F9),
      backgroundElevated: dark ? AppColors.backgroundElevated : Colors.white,
      surfaceDeep: dark ? AppColors.surfaceDeep : const Color(0xFFEDEDF2),
      surfaceCard: dark ? AppColors.surfaceCard : const Color(0x12000000),
      textPrimary: dark ? AppColors.textPrimary : const Color(0xFF15151A),
      textSecondary: dark ? AppColors.textSecondary : const Color(0xB315151A),
      textMuted: dark ? AppColors.textMuted : const Color(0x9915151A),
      textFaint: dark ? AppColors.textFaint : const Color(0x5915151A),
      hairline: dark ? AppColors.hairline : const Color(0x1F000000),
      danger: AppColors.danger,
      success: AppColors.success,
    );
  }

  @override
  AppPalette copyWith({Color? accent, Color? background}) => AppPalette(
        accent: accent ?? this.accent,
        accentSoft: accentSoft,
        background: background ?? this.background,
        backgroundElevated: backgroundElevated,
        surfaceDeep: surfaceDeep,
        surfaceCard: surfaceCard,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
        textMuted: textMuted,
        textFaint: textFaint,
        hairline: hairline,
        danger: danger,
        success: success,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) => this;
}

extension AppPaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}

/// Corner-radius scale.
class AppRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double xl = 28;
  static const double pill = 999;
}

/// A tuned system-font type scale. We deliberately do NOT declare a custom
/// fontFamily that isn't bundled (that silently falls back anyway); instead we
/// get a premium look from weight contrast, tight tracking on large text, and
/// generous line heights. SF Pro (iOS) / Roboto (Android) are high-quality.
class AppTypography {
  static const TextStyle display = TextStyle(
    fontSize: 32,
    height: 1.1,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.0,
  );
  static const TextStyle titleLarge = TextStyle(
    fontSize: 24,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
  );
  static const TextStyle title = TextStyle(
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );
  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );
  static const TextStyle overline = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.4,
  );
}

class AppTheme {
  static ThemeData build(ThemeMode mode, Color accent) {
    final brightness = mode == ThemeMode.light ? Brightness.light : Brightness.dark;
    final base = ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.dark ? AppColors.background : const Color(0xFFF7F7F9),
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: brightness),
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      extensions: [AppPalette.from(mode, accent)],
      textTheme: base.textTheme.copyWith(
        displayLarge: AppTypography.display, displayMedium: AppTypography.titleLarge,
        titleLarge: AppTypography.title, titleMedium: AppTypography.headline,
        bodyLarge: AppTypography.body, bodyMedium: AppTypography.bodyMedium,
        bodySmall: AppTypography.caption, labelSmall: AppTypography.overline,
      ),
      sliderTheme: SliderThemeData(activeTrackColor: accent, thumbColor: accent, overlayColor: accent.withValues(alpha: .14)),
    );
  }
  static ThemeData get darkTheme {
    return build(ThemeMode.dark, AppColors.accent);
  }
}
