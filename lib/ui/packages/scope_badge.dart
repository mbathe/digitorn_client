/// Small badge showing whether an app install is system-wide or
/// private to a specific user. Used on marketplace cards, detail
/// page headers, lifecycle dialogs, and the admin disabled-apps
/// section.
///
/// Three rendering modes:
///   * `system`                          → 🌐 System   (neutral gray)
///   * `user` + owner == current user   → 👤 Private  (blue)
///   * `user` + owner != current user   → 👤 owner_id (blue) — admin
///     view of someone else's private install.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

class ScopeBadge extends StatelessWidget {
  final bool isSystem;
  final String ownerUserId;
  final bool compact;
  const ScopeBadge({
    super.key,
    required this.isSystem,
    this.ownerUserId = '',
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final currentUid = AuthService().currentUser?.userId ?? '';
    final isMine =
        !isSystem && ownerUserId.isNotEmpty && ownerUserId == currentUid;

    final Color fg;
    final Color bg;
    final IconData icon;
    final String label;

    if (isSystem) {
      fg = c.textMuted;
      bg = c.surfaceAlt;
      icon = Icons.public_rounded;
      label = 'System';
    } else if (isMine || ownerUserId.isEmpty) {
      fg = c.blue;
      bg = c.blue.withValues(alpha: 0.1);
      icon = Icons.person_rounded;
      label = 'Private';
    } else {
      // Admin viewing someone else's private install.
      fg = c.blue;
      bg = c.blue.withValues(alpha: 0.08);
      icon = Icons.person_outline_rounded;
      // Short-hand if the id is long.
      final shortId = ownerUserId.length > 12
          ? '${ownerUserId.substring(0, 12)}…'
          : ownerUserId;
      label = shortId;
    }

    final hPad = compact ? 5.0 : 7.0;
    final fontSize = compact ? 9.5 : 10.5;
    final iconSize = compact ? 9.0 : 10.5;
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
