/// Tiny pill that flags a publisher as Verified (✓) or Community.
///
/// Mirror of web `VerifiedBadge`
/// (`digitorn_web/src/components/hub/verified-badge.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/app_theme.dart';

class VerifiedBadge extends StatelessWidget {
  final bool verified;
  final bool compact;

  const VerifiedBadge({
    super.key,
    required this.verified,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = verified ? c.blue : c.textMuted;
    final bg = verified ? c.blue.withValues(alpha: 0.12) : c.surfaceAlt;
    final icon = verified
        ? Icons.verified_rounded
        : Icons.groups_rounded;
    final label = verified ? 'Verified' : 'Community';

    final iconSize = compact ? 9.0 : 10.5;
    final fontSize = compact ? 9.5 : 10.5;
    final hPad = compact ? 5.0 : 7.0;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: fg.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: fg,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
