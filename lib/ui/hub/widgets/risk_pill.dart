/// Coloured risk-level pill (low = green, medium = orange, high = red).
///
/// Mirror of web `RiskPill`
/// (`digitorn_web/src/components/hub/risk-pill.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/hub/hub_models.dart';
import '../../../theme/app_theme.dart';

class RiskPill extends StatelessWidget {
  final HubRiskLevel level;
  final bool compact;

  const RiskPill({
    super.key,
    required this.level,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = switch (level) {
      HubRiskLevel.high => c.red,
      HubRiskLevel.medium => c.orange,
      HubRiskLevel.low => c.green,
    };
    final icon = switch (level) {
      HubRiskLevel.high => Icons.gpp_bad_rounded,
      HubRiskLevel.medium => Icons.shield_rounded,
      HubRiskLevel.low => Icons.verified_user_rounded,
    };
    final label = '${hubRiskToString(level)} risk';

    final iconSize = compact ? 9.0 : 10.5;
    final fontSize = compact ? 9.5 : 10.5;
    final hPad = compact ? 5.0 : 7.0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: fg),
          const SizedBox(width: 4),
          Text(
            label.toUpperCase(),
            style: GoogleFonts.jetBrainsMono(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
