import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A polished empty-state placeholder: an icon medallion over a soft accent
/// glow, plus a title and optional subtitle. Used wherever a list can be empty.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  static const double _medallion = 84;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: _medallion,
            height: _medallion,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [
                  AppColors.accent22,
                  AppColors.accent04,
                ],
              ),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Icon(
              icon,
              size: _medallion * 0.42,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.headline,
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: AppTypography.caption,
            ),
          ],
        ],
      ),
    );
  }
}
