import 'package:flutter/material.dart';

import '../../design/ds.dart';
import '../../theme/app_theme.dart';

/// Initials-on-gradient avatar. Gradient is deterministic from the
/// seed so the same name always renders the same colors. No image
/// asset required — works as a fallback everywhere.
class DsAvatar extends StatelessWidget {
  final String seed;
  final String initials;
  final double size;
  final bool showBorder;

  const DsAvatar({
    super.key,
    required this.seed,
    required this.initials,
    this.size = 48,
    this.showBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final palette = _palettes[seed.hashCode.abs() % _palettes.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette.$1, palette.$2],
        ),
        border: showBorder
            ? Border.all(color: c.border, width: DsStroke.hairline)
            : null,
        boxShadow: DsElevation.raise(c.shadow),
      ),
      alignment: Alignment.center,
      child: Text(
        initials.toUpperCase(),
        style: DsType.h3(color: Colors.white).copyWith(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

const _palettes = <(Color, Color)>[
  (Color(0xFFF26A4A), Color(0xFFE8A850)),
  (Color(0xFF5FAC87), Color(0xFF689EAC)),
  (Color(0xFFA08EA8), Color(0xFF7DB5B0)),
  (Color(0xFFE66C5B), Color(0xFFA08EA8)),
  (Color(0xFFE8A850), Color(0xFF5FAC87)),
  (Color(0xFF689EAC), Color(0xFFF26A4A)),
];
