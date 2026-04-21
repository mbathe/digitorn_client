import 'package:flutter/widgets.dart';

/// Layered shadows — each tier stacks two shadows for realism.
/// Pass `shadowColor` from `context.colors.shadow` so the palette
/// stays coherent across dark / light themes.
class DsElevation {
  static const List<BoxShadow> flat = [];

  static List<BoxShadow> raise(Color shadow) => [
        BoxShadow(
          color: shadow.withValues(alpha: 0.14),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> float(Color shadow) => [
        BoxShadow(
          color: shadow.withValues(alpha: 0.22),
          blurRadius: 14,
          offset: const Offset(0, 6),
          spreadRadius: -4,
        ),
        BoxShadow(
          color: shadow.withValues(alpha: 0.08),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> hero(Color shadow) => [
        BoxShadow(
          color: shadow.withValues(alpha: 0.40),
          blurRadius: 48,
          offset: const Offset(0, 24),
          spreadRadius: -12,
        ),
        BoxShadow(
          color: shadow.withValues(alpha: 0.20),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  /// Colored glow around an accent element (buttons, focused
  /// inputs). `tint` should come from accentPrimary or glow.
  static List<BoxShadow> accentGlow(Color tint, {double strength = 1}) => [
        BoxShadow(
          color: tint.withValues(alpha: 0.32 * strength),
          blurRadius: 28 * strength,
          offset: const Offset(0, 10),
          spreadRadius: -6,
        ),
        BoxShadow(
          color: tint.withValues(alpha: 0.18 * strength),
          blurRadius: 8 * strength,
          offset: const Offset(0, 2),
          spreadRadius: -2,
        ),
      ];
}
