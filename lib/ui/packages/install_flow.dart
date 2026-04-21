/// Shared install / upgrade / uninstall orchestration. Used by every
/// surface that needs to mutate package state — discover cards,
/// library list, detail page, install dialog. Centralises the
/// permissions-consent loop and the active-sessions warning so each
/// caller is one method call away from the right UX.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_package.dart';
import '../../services/auth_service.dart';
import '../../services/background_app_service.dart';
import '../../services/package_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';

class PackageInstallFlow {
  /// Run the full install flow for [sourceType] / [sourceUri].
  /// Returns the freshly-installed package on success, null on
  /// cancellation. All errors surface as scaffold snackbars.
  ///
  /// Admin users get a pre-dialog asking whether the install is
  /// personal or system-wide. Non-admins can only install for
  /// themselves, so the pre-dialog is skipped and `scope: user`
  /// is sent automatically.
  static Future<AppPackage?> install(
    BuildContext context, {
    required String sourceType,
    required String sourceUri,
    String? version,
  }) async {
    final svc = PackageService();
    final messenger = ScaffoldMessenger.of(context);

    // ── Scope picker (admin only) ──
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    String scope = 'user';
    if (isAdmin) {
      final picked = await showDialog<String>(
        context: context,
        builder: (_) => const _InstallScopeDialog(),
      );
      if (picked == null) return null;
      scope = picked;
    }
    if (!context.mounted) return null;

    try {
      return await svc.install(
        sourceType: sourceType,
        sourceUri: sourceUri,
        version: version,
        scope: scope,
      );
    } on PermissionsRequiredException catch (e) {
      if (!context.mounted) return null;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (_) => PermissionsConsentDialog(details: e.details),
      );
      if (accepted != true) return null;
      try {
        final pkg = await svc.install(
          sourceType: sourceType,
          sourceUri: sourceUri,
          version: version,
          acceptPermissions: true,
          scope: scope,
        );
        if (context.mounted) {
          messenger.showSnackBar(SnackBar(
            content: Text('Installed ${pkg.name}'),
            backgroundColor:
                context.colors.green.withValues(alpha: 0.9),
          ));
        }
        return pkg;
      } on PackageException catch (e2) {
        if (context.mounted) {
          messenger.showSnackBar(SnackBar(
            content: Text(e2.message),
            backgroundColor: context.colors.red.withValues(alpha: 0.9),
          ));
        }
        return null;
      }
    } on PackageConflictException catch (e) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text(
              'Already installed (${e.existingSourceType} v${e.existingVersion}).'),
          backgroundColor: context.colors.orange.withValues(alpha: 0.9),
        ));
      }
      return null;
    } on PackageException catch (e) {
      if (context.mounted) {
        // 403 → admin scope required. Show a friendlier banner with
        // an "OK" action so the user knows it's a permission issue,
        // not a generic install failure.
        if (e.statusCode == 403) {
          await showDialog(
            context: context,
            builder: (_) {
              final c = context.colors;
              return AlertDialog(
                backgroundColor: c.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: c.border),
                ),
                title: Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 16, color: c.orange),
                    const SizedBox(width: 8),
                    Text('Admin only',
                        style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: c.textBright)),
                  ],
                ),
                content: Text(
                  e.message,
                  style: GoogleFonts.inter(
                      fontSize: 12, color: c.text, height: 1.5),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('OK',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                ],
              );
            },
          );
          return null;
        }
        messenger.showSnackBar(SnackBar(
          content: Text(e.message),
          backgroundColor: context.colors.red.withValues(alpha: 0.9),
        ));
      }
      return null;
    }
  }

  /// Confirm + uninstall a package. Returns true on success.
  static Future<bool> uninstall(BuildContext context, AppPackage pkg) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Row(
          children: [
            Icon(
              pkg.isBuiltin
                  ? Icons.warning_amber_rounded
                  : Icons.delete_outline_rounded,
              size: 18,
              color: pkg.isBuiltin ? c.orange : c.red,
            ),
            const SizedBox(width: 10),
            Text('Uninstall ${pkg.name}?',
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.textBright)),
          ],
        ),
        content: Text(
          pkg.isBuiltin
              ? 'This is a built-in package. The daemon will reinstall it on the next boot. Continue anyway?'
              : 'The package files will be deleted. Workspaces and credentials are preserved.',
          style: GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: c.red,
                foregroundColor: Colors.white,
                elevation: 0),
            child: Text('Uninstall',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    try {
      // Forward the pkg's known scope so the daemon targets the
      // correct install store. A missing scope defaults to `user`
      // server-side and returns "nothing_to_delete" for any app the
      // caller didn't put there themselves (built-ins + system
      // installs).
      await PackageService().uninstall(
        pkg.packageId,
        force: pkg.isBuiltin,
        scope: pkg.scope,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${pkg.name} uninstalled'),
          backgroundColor: context.colors.green.withValues(alpha: 0.9),
        ));
      }
      return true;
    } on PackageException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          backgroundColor: context.colors.red.withValues(alpha: 0.9),
        ));
      }
      return false;
    }
  }

  /// Upgrade flow with active-sessions warning + re-consent loop.
  static Future<AppPackage?> upgrade(
      BuildContext context, AppPackage pkg) async {
    if (!pkg.hasUpdate) return null;
    final svc = PackageService();
    final deployedAppId = pkg.deployedAppId ?? pkg.packageId;
    final activeCount = BackgroundAppService()
            .sessions
            .where((s) => s.appId == deployedAppId && s.isActive)
            .length +
        SessionService()
            .sessions
            .where((s) => s.appId == deployedAppId && s.isActive)
            .length;
    if (activeCount > 0) {
      final ok = await _confirmUpgradeWithActive(context, pkg, activeCount);
      if (ok != true || !context.mounted) return null;
    }
    try {
      final upgraded = await svc.upgrade(pkg.packageId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Upgraded ${upgraded.name} to ${upgraded.version}'),
          backgroundColor: context.colors.green.withValues(alpha: 0.9),
        ));
      }
      return upgraded;
    } on PermissionsRequiredException catch (e) {
      if (!context.mounted) return null;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (_) => PermissionsConsentDialog(
            details: e.details, isUpgrade: true),
      );
      if (accepted != true || !context.mounted) return null;
      try {
        final upgraded =
            await svc.upgrade(pkg.packageId, acceptPermissions: true);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Upgraded ${pkg.name}'),
            backgroundColor: context.colors.green.withValues(alpha: 0.9),
          ));
        }
        return upgraded;
      } on PackageException catch (e2) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e2.message),
            backgroundColor: context.colors.red.withValues(alpha: 0.9),
          ));
        }
        return null;
      }
    } on PackageException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          backgroundColor: context.colors.red.withValues(alpha: 0.9),
        ));
      }
      return null;
    }
  }

  static Future<bool?> _confirmUpgradeWithActive(
      BuildContext context, AppPackage pkg, int count) {
    final c = context.colors;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: c.orange),
            const SizedBox(width: 10),
            Text('Upgrade ${pkg.name}?',
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: c.textBright)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: c.orange.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 14, color: c.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This will interrupt $count active session${count == 1 ? '' : 's'}.',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          color: c.orange,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Drafts, payloads, credentials, and message history are persisted continuously. Only in-flight agent turns will be aborted.',
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.text, height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style:
                    GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: c.orange,
                foregroundColor: Colors.white,
                elevation: 0),
            child: Text('Upgrade and interrupt',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// Permissions consent dialog — extracted from the old install
/// dialog so every surface (discover, library, detail) shares one
/// implementation.
class PermissionsConsentDialog extends StatelessWidget {
  final PermissionsRequired details;
  final bool isUpgrade;
  const PermissionsConsentDialog({
    super.key,
    required this.details,
    this.isUpgrade = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = details.permissions;
    final tint = switch (p.riskLevel) {
      'high' => c.red,
      'medium' => c.orange,
      _ => c.green,
    };
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: tint.withValues(alpha: 0.35)),
                    ),
                    child: Icon(
                      p.riskLevel == 'high'
                          ? Icons.warning_amber_rounded
                          : Icons.shield_outlined,
                      size: 20,
                      color: tint,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isUpgrade
                              ? 'Upgrade requires new permissions'
                              : 'Permissions requested',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: c.textBright,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Risk level: ${p.riskLevel.toUpperCase()}',
                          style: GoogleFonts.firaCode(
                              fontSize: 11, color: tint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _row(c, Icons.public_rounded, 'Network access',
                  p.networkAccess ? 'yes' : 'no', p.networkAccess),
              if (p.filesystemAccess.isNotEmpty)
                _row(
                  c,
                  Icons.folder_outlined,
                  'Filesystem',
                  p.filesystemAccess.join(', '),
                  p.filesystemAccess.contains('write'),
                ),
              if (p.filesystemScopes.isNotEmpty)
                _row(
                  c,
                  Icons.subdirectory_arrow_right_rounded,
                  'Scopes',
                  p.filesystemScopes.join(', '),
                  false,
                ),
              if (p.requiresApproval.isNotEmpty)
                _row(
                  c,
                  Icons.front_hand_outlined,
                  'Will ask before',
                  p.requiresApproval.join(', '),
                  true,
                ),
              if (details.requiredCredentials.isNotEmpty) ...[
                const SizedBox(height: 12),
                _row(
                  c,
                  Icons.key_outlined,
                  'Required credentials',
                  details.requiredCredentials.join(', '),
                  false,
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.check_rounded,
                        size: 14, color: Colors.white),
                    label: Text('Accept and install',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tint,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    AppColors c,
    IconData icon,
    String label,
    String value,
    bool warn,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: warn ? c.orange : c.textMuted),
          const SizedBox(width: 10),
          SizedBox(
            width: 140,
            child: Text(label,
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.text)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textBright)),
          ),
        ],
      ),
    );
  }
}

/// Admin-only dialog that asks whether to install a package for the
/// current user or for every user on the daemon. Non-admins never
/// see this — the install flow skips it and sends `scope: user`.
class _InstallScopeDialog extends StatefulWidget {
  const _InstallScopeDialog();

  @override
  State<_InstallScopeDialog> createState() => _InstallScopeDialogState();
}

class _InstallScopeDialogState extends State<_InstallScopeDialog> {
  String _scope = 'user';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      title: Text(
        'Install for…',
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: c.textBright,
        ),
      ),
      content: SizedBox(
        width: MediaQuery.sizeOf(context).width < 460
            ? MediaQuery.sizeOf(context).width - 48
            : 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ScopeCard(
              icon: Icons.person_outline_rounded,
              title: 'Just me',
              body: 'Private install — only you will see this package. '
                  'Stored under your user directory.',
              selected: _scope == 'user',
              onTap: () => setState(() => _scope = 'user'),
            ),
            const SizedBox(height: 10),
            _ScopeCard(
              icon: Icons.people_outline_rounded,
              title: 'All users',
              body: 'Global install — every user on this daemon '
                  'will see it. Admin only.',
              selected: _scope == 'system',
              onTap: () => setState(() => _scope = 'system'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style:
                  GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _scope),
          style: ElevatedButton.styleFrom(
            backgroundColor: c.blue,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          child: Text(
            'Continue',
            style: GoogleFonts.inter(
                fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _ScopeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;
  const _ScopeCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? c.blue.withValues(alpha: 0.1)
              : c.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color:
                selected ? c.blue.withValues(alpha: 0.5) : c.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: (selected ? c.blue : c.textMuted)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon,
                  size: 18, color: selected ? c.blue : c.textMuted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: c.textBright)),
                  const SizedBox(height: 3),
                  Text(body,
                      style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: c.textMuted,
                          height: 1.45)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off_rounded,
              size: 16,
              color: selected ? c.blue : c.textDim,
            ),
          ],
        ),
      ),
    );
  }
}
