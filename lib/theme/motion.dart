import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

/// Single source of truth for motion, the kinetic counterpart to [AppColors].
///
/// The house style is "decelerate into place": every entrance covers most of
/// its distance early and settles gently, so the app feels responsive without
/// ever being abrupt. Exits are the mirror image. Springs are reserved for the
/// one element the user's eye is always on — the album art — where a touch of
/// physical overshoot reads as life rather than decoration.
///
/// Route all durations and curves through here so the feel stays uniform and
/// easy to retune in one place.
class AppMotion {
  AppMotion._();

  // --- Durations -----------------------------------------------------------

  /// Micro-feedback: icon swaps, pressed states.
  static const Duration instant = Duration(milliseconds: 140);

  /// Quick responses: highlights, toggles, small fades, cover loads.
  static const Duration fast = Duration(milliseconds: 220);

  /// Standard content transitions: panels, switches, tab swipes, reveals.
  static const Duration base = Duration(milliseconds: 320);

  /// Larger spatial moves: sheet morphs, page pushes, the lyric scroll.
  static const Duration slow = Duration(milliseconds: 420);

  /// Slow ambient drift: backdrop colour, anything peripheral that should be
  /// felt rather than watched.
  static const Duration ambient = Duration(milliseconds: 600);

  // --- Curves --------------------------------------------------------------

  /// The signature deceleration: arrive fast, settle gently.
  static const Curve standard = Curves.easeOutCubic;

  /// Its mirror, for exits and reversals.
  static const Curve standardReverse = Curves.easeInCubic;

  /// A stronger deceleration for larger moves — more distance is covered
  /// early, so big transitions read as quick without landing hard.
  static const Curve emphasized = Curves.easeOutQuint;
  static const Curve emphasizedReverse = Curves.easeInQuint;

  // --- Springs -------------------------------------------------------------

  /// A confident spring with a small, tasteful overshoot (~10%). Reserved for
  /// the focal interactive element — the album art breathing on play/pause —
  /// where a touch of physical life reads as premium rather than decorative.
  static final Curve springBouncy =
      SpringCurve(stiffness: 210, damping: 16);
}

/// A [Curve] backed by a real damped-spring simulation, so implicit animations
/// ([AnimatedScale], [AnimatedPositioned], …) can overshoot and settle like a
/// physical object instead of stopping dead at the end of a bezier.
///
/// The simulation runs from 0 to 1; its natural settling time is derived from
/// the damping envelope and used to normalise the curve's unit interval, so it
/// composes with any animation [Duration].
class SpringCurve extends Curve {
  final SpringSimulation _simulation;

  /// Seconds the spring effectively takes to come to rest.
  final double _settleSeconds;

  // Not const: it carries a live [SpringSimulation], which is never const.
  // ignore: prefer_const_constructors_in_immutables
  SpringCurve._(this._simulation, this._settleSeconds);

  factory SpringCurve({
    double mass = 1.0,
    required double stiffness,
    required double damping,
  }) {
    final simulation = SpringSimulation(
      SpringDescription(mass: mass, stiffness: stiffness, damping: damping),
      0.0, // start
      1.0, // end
      0.0, // initial velocity
    );
    // Underdamped envelope decays as e^(-(damping / 2·mass)·t); solve for the
    // time it drops below a thousandth of the travel.
    final decay = damping / (2 * mass);
    final settle = decay > 0 ? math.log(1000) / decay : 1.0;
    return SpringCurve._(simulation, settle.clamp(0.2, 2.0));
  }

  @override
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return _simulation.x(t * _settleSeconds);
  }
}
