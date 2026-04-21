/// Settings → Security. Previously listed the user's active auth
/// sessions (devices / browsers) via `/auth/sessions*` but the
/// daemon's 2026-04 per-app sessions migration removed that family
/// of routes outright — they were really per-app chat sessions in
/// disguise, now owned by SessionService under
/// `/api/apps/{app_id}/sessions*`.
///
/// The section is kept as an informational placeholder so the
/// Settings router still has a "Security" entry; once the daemon
/// gains a real "logged-in devices" endpoint, this is the file to
/// wire it into.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/app_theme.dart';

class SecuritySessionsSection extends StatelessWidget {
  const SecuritySessionsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline_rounded, size: 20, color: c.textMuted),
                const SizedBox(width: 10),
                Text(
                  'Device sessions',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              "Listing logged-in devices isn't available in this build. "
              'The legacy endpoint was retired when chat sessions moved '
              'to the per-app registry; a replacement for true device '
              'sessions is on the server roadmap.',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: c.textMuted,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
