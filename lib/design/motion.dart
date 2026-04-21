import 'package:flutter/animation.dart';

/// Motion language. Custom cubic-beziers — no Material defaults.
class DsCurve {
  /// Entries, expansions — gentle decel, no overshoot.
  static const Cubic decelSoft = Cubic(0.16, 1.0, 0.3, 1.0);

  /// Snappy — small UI toggles, hover states.
  static const Cubic decelSnap = Cubic(0.2, 0.9, 0.2, 1.0);

  /// Exits — accel into nothing.
  static const Cubic accelSoft = Cubic(0.4, 0.0, 0.9, 0.5);

  /// Slight overshoot — use sparingly (chips, confirmations).
  static const Cubic spring = Cubic(0.34, 1.56, 0.64, 1.0);

  /// Standard ease for everything else.
  static const Cubic standard = Cubic(0.4, 0.0, 0.2, 1.0);
}
