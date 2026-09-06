import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's one snackbar. Every toast previously hand-rolled a [SnackBar]
/// with slightly different — and occasionally inconsistent — backgrounds,
/// shapes and margins.
///
/// Pass [icon] for the floating rounded variant (favorite toasts, status
/// messages); without it, a plain accent-tinted bar is shown (confirmation
/// toasts like "已加入「…」").
void showAppSnackBar(
  ScaffoldMessengerState messenger, {
  required String message,
  IconData? icon,
  Color backgroundColor = AppColors.accent,
  Duration duration = const Duration(seconds: 2),
}) {
  final Widget content;
  final SnackBarBehavior? behavior;
  final EdgeInsetsGeometry? margin;
  final ShapeBorder? shape;
  if (icon == null) {
    content = Text(message);
    behavior = null;
    margin = null;
    shape = null;
  } else {
    content = Row(
      children: [
        Icon(icon, color: AppColors.accent, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
    behavior = SnackBarBehavior.floating;
    margin = const EdgeInsets.symmetric(horizontal: 20, vertical: 12);
    shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  }

  messenger.showSnackBar(SnackBar(
    content: content,
    backgroundColor: backgroundColor,
    behavior: behavior,
    margin: margin,
    shape: shape,
    duration: duration,
  ));
}
