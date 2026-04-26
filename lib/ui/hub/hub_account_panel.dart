/// Compact inline panel that surfaces the user's connection state with
/// the Digitorn Hub. Three modes:
///
///   - bridge enabled + connected     → Verified pill + email
///   - bridge enabled + connecting    → spinner ("Connecting…")
///   - bridge disabled (no daemon)    → muted notice ("Hub login disabled
///                                      on this daemon"), no manual form
///
/// Hub auth is now exclusively daemon-bridged. The local manual login
/// form was removed when the daemon-bridge auth shipped — see
/// `digitorn-bridge/packages/hub/src/digitorn_hub/routers/daemon_bridge.py`.
///
/// Mirror of web `HubAccountPanel`
/// (`digitorn_web/src/components/hub/hub-account-panel.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/hub_session_service.dart';
import '../../theme/app_theme.dart';

class HubAccountPanel extends StatefulWidget {
  /// Kept for backwards compat with call sites that previously toggled
  /// the dense layout — the panel is now compact-only.
  final bool compact;
  const HubAccountPanel({super.key, this.compact = false});

  @override
  State<HubAccountPanel> createState() => _HubAccountPanelState();
}

class _HubAccountPanelState extends State<HubAccountPanel> {
  late final HubSessionService _svc;

  @override
  void initState() {
    super.initState();
    _svc = HubSessionService();
    _svc.addListener(_onChange);
    if (_svc.session == null) {
      _svc.refresh();
    }
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final session = _svc.session;
    final bridgeEnabled = session?.bridgeEnabled == true;

    if (_svc.loading && session == null) {
      return _Surface(
        c: c,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
          ),
          const SizedBox(width: 10),
          Text(
            'Loading hub session…',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
        ],
      );
    }

    // Bridge OFF — daemon isn't configured to mint Hub sessions. Surface
    // a neutral disabled state instead of a sign-in form.
    if (!bridgeEnabled) {
      return _Surface(
        c: c,
        children: [
          Icon(Icons.shield_outlined, size: 14, color: c.textDim),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hub login disabled on this daemon',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.text,
                  ),
                ),
                Text(
                  'Browsing only — install / review / report require a daemon '
                  'with hub.daemon_bridge.enabled = true.',
                  style: TextStyle(fontSize: 11, color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (!_svc.isLoggedIn) {
      return _Surface(
        c: c,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: c.blue),
          ),
          const SizedBox(width: 10),
          Text(
            'Connecting to Hub via your daemon account…',
            style: TextStyle(fontSize: 13, color: c.textMuted),
          ),
        ],
      );
    }

    final user = session?.hubUser;
    return _Surface(
      c: c,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: c.green.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.check_circle_rounded, size: 16, color: c.green),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.verified_user_rounded, size: 12, color: c.green),
                  const SizedBox(width: 4),
                  Text(
                    'Connected to Hub',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.green,
                    ),
                  ),
                ],
              ),
              Text(
                user?.email ?? user?.id ?? 'Hub member',
                style: GoogleFonts.inter(fontSize: 13, color: c.text),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Surface extends StatelessWidget {
  final AppColors c;
  final List<Widget> children;
  const _Surface({required this.c, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Row(children: children),
    );
  }
}
