/// Modal shown by `HubInstallController` when the daemon returns a
/// 409 with a permission breakdown. Returns true on confirm.
///
/// Mirror of web `HubConsentDialog` (inside
/// `digitorn_web/src/components/hub/hub-install-flow.tsx`).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/hub/hub_models.dart';
import '../../../theme/app_theme.dart';

class HubConsentDialog extends StatefulWidget {
  final String packageName;
  final HubPermissionsBreakdown permissions;

  const HubConsentDialog({
    super.key,
    required this.packageName,
    required this.permissions,
  });

  @override
  State<HubConsentDialog> createState() => _HubConsentDialogState();
}

class _HubConsentDialogState extends State<HubConsentDialog> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = widget.permissions;
    final tint = _riskTint(p.riskLevel, c);
    final noPerms = !p.networkAccess &&
        p.filesystemAccess.isEmpty &&
        p.requiresApproval.isEmpty;

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    p.riskLevel == HubRiskLevel.high
                        ? Icons.gpp_bad_rounded
                        : Icons.verified_user_rounded,
                    size: 20,
                    color: tint,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Install "${widget.packageName}"?',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'This package asks for the following permissions. Review them '
                'before continuing — you can revoke any credential later from '
                'Settings → Credentials.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: c.textMuted,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Risk level:',
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12),
                      border: Border.all(
                        color: tint.withValues(alpha: 0.3),
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      hubRiskToString(p.riskLevel).toUpperCase(),
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: tint,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (p.networkAccess)
                _PermRow(
                  icon: Icons.wifi_rounded,
                  label: 'Network access',
                  sub: 'Can reach external APIs and websites.',
                ),
              if (p.filesystemAccess.isNotEmpty) ...[
                if (p.networkAccess) const SizedBox(height: 8),
                _PermRow(
                  icon: Icons.folder_open_rounded,
                  label:
                      'Filesystem access (${p.filesystemAccess.join(", ")})',
                  sub: p.filesystemScopes.isNotEmpty
                      ? 'Scopes: ${p.filesystemScopes.join(", ")}'
                      : 'Read / write inside the sandbox.',
                ),
              ],
              if (p.requiresApproval.isNotEmpty) ...[
                if (p.networkAccess || p.filesystemAccess.isNotEmpty)
                  const SizedBox(height: 8),
                _PermRow(
                  icon: Icons.vpn_key_rounded,
                  label:
                      'Approval required: ${p.requiresApproval.join(", ")}',
                  sub: "You'll be prompted before each privileged action.",
                ),
              ],
              if (noPerms)
                Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 12,
                      color: c.green,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'No elevated permissions requested.',
                      style: TextStyle(fontSize: 12, color: c.textMuted),
                    ),
                  ],
                ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() => _busy = true);
                            Navigator.of(context).pop(true);
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accentPrimary,
                      foregroundColor: c.onAccent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      textStyle: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Install'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  const _PermRow({
    required this.icon,
    required this.label,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 14, color: c.text),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: c.textBright,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(
                  fontSize: 11.5,
                  color: c.textMuted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Color _riskTint(HubRiskLevel level, AppColors c) {
  switch (level) {
    case HubRiskLevel.high:
      return c.red;
    case HubRiskLevel.medium:
      return c.orange;
    case HubRiskLevel.low:
      return c.green;
  }
}
