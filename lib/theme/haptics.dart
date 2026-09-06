import 'package:flutter/services.dart';

/// Centralized, subtle haptic feedback.
///
/// Premium apps use light, consistent taps rather than heavy buzzes. Route all
/// haptics through here so the feel stays uniform and easy to tune.
class Haptics {
  Haptics._();

  /// A soft tap for primary actions (play/pause, favorite, commit).
  static Future<void> light() => HapticFeedback.lightImpact();

  /// A slightly stronger tap for mode/state changes.
  static Future<void> medium() => HapticFeedback.mediumImpact();

  /// The lightest click for selection/navigation (tabs, next, toggles).
  static Future<void> selection() => HapticFeedback.selectionClick();
}
