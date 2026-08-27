import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/theme/app_theme.dart';

void main() {
  test('light palette follows the selected accent and uses light surfaces', () {
    const accent = Color(0xFF7C4DFF);
    final theme = AppTheme.build(ThemeMode.light, accent);
    final palette = theme.extension<AppPalette>()!;

    expect(palette.accent, accent);
    expect(palette.background, const Color(0xFFF7F7F9));
    expect(palette.textPrimary, isNot(AppColors.textPrimary));
  });

  test('default dark palette preserves the existing visual baseline', () {
    final theme = AppTheme.build(ThemeMode.dark, AppColors.accent);
    final palette = theme.extension<AppPalette>()!;

    expect(palette.background, AppColors.background);
    expect(palette.accent, AppColors.accent);
  });
}
