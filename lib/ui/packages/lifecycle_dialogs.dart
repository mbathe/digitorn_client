/// Confirmation dialogs for the three destructive / reversible
/// operations the daemon exposes on an app:
///
///   * [AppLifecycleDialogs.disable]       — hides the app, reversible
///   * [AppLifecycleDialogs.deleteKeep]    — wipes the bundle, keeps audit
///   * [AppLifecycleDialogs.deletePermanent] — total wipe, typed confirm
///
/// Every dialog is self-contained: it calls the [AppsService] itself,
/// surfaces success / failure toasts, and returns `true` when the
/// daemon confirmed the operation. Callers just refresh their UI on
/// a true result.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/apps_service.dart';
import '../../theme/app_theme.dart';

class AppLifecycleDialogs {
  AppLifecycleDialogs._();

  // ── Disable ─────────────────────────────────────────────────────

  static Future<bool> disable(
    BuildContext context, {
    required String appId,
    required String appName,
    /// `"system"` | `"user"` | null (daemon decides). Only admins
    /// should ever pass `"system"`; the dialog itself doesn't gate
    /// — that's the caller's responsibility.
    String? scope,
  }) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) {
        final c = dctx.colors;
        return StatefulBuilder(builder: (dctx, setState) {
          return AlertDialog(
            backgroundColor: c.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            title: Row(
              children: [
                Icon(Icons.pause_circle_filled_rounded,
                    color: c.orange, size: 20),
                const SizedBox(width: 8),
                Text('Disable "$appName"?',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The app will be hidden and unusable until an '
                    'administrator re-enables it. Sessions, messages '
                    'and secrets are preserved.',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: c.textMuted, height: 1.55),
                  ),
                  const SizedBox(height: 16),
                  Text('Reason (optional)',
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: c.textDim)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonCtrl,
                    maxLength: 200,
                    style: GoogleFonts.inter(fontSize: 13),
                    decoration: InputDecoration(
                      counterText: '',
                      filled: true,
                      fillColor: c.inputBg,
                      hintText: 'e.g. rotating API key',
                      hintStyle: GoogleFonts.inter(
                          fontSize: 13, color: c.textMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: c.inputBorder),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: Text('Cancel',
                    style: GoogleFonts.inter(color: c.textMuted)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: c.orange,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(dctx).pop(true),
                child: const Text('Disable'),
              ),
            ],
          );
        });
      },
    );
    if (ok != true) return false;

    try {
      final result = await AppsService().disableApp(
        appId,
        reason: reasonCtrl.text.trim(),
        scope: scope,
      );
      if (context.mounted) {
        _showSuccess(context, result.message.isNotEmpty
            ? result.message
            : 'App disabled. An administrator can re-enable it.');
      }
      return true;
    } catch (e) {
      if (context.mounted) _showError(context, e);
      return false;
    }
  }

  // ── Delete, keep history ────────────────────────────────────────

  static Future<bool> deleteKeep(
    BuildContext context, {
    required String appId,
    required String appName,
    String? scope,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) {
        final c = dctx.colors;
        return AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: c.orange, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Delete "$appName"? (keeps history)',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                    label: 'Will be removed', color: c.red),
                _BulletLine('Bundles (code, YAML, assets)'),
                _BulletLine('Modules and configuration'),
                _BulletLine('Secrets'),
                const SizedBox(height: 12),
                _SectionHeader(
                    label: 'Will be kept (audit)', color: c.green),
                _BulletLine('Sessions and messages'),
                _BulletLine('Activations and logs'),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: c.red.withValues(alpha: 0.25)),
                  ),
                  child: Text(
                    'This action is IRREVERSIBLE — even an admin '
                    "cannot re-enable it (the bundle is gone).",
                    style: GoogleFonts.inter(
                        fontSize: 12, color: c.red, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: Text('Cancel',
                  style: GoogleFonts.inter(color: c.textMuted)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: c.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (ok != true) return false;

    try {
      final result = await AppsService().deleteApp(
        appId,
        deleteHistory: false,
        scope: scope,
      );
      if (context.mounted) {
        _showSuccess(context, result.message.isNotEmpty
            ? result.message
            : 'App deleted. History preserved for audit.');
      }
      return true;
    } catch (e) {
      if (context.mounted) _showError(context, e);
      return false;
    }
  }

  // ── Delete permanently ──────────────────────────────────────────

  static Future<bool> deletePermanent(
    BuildContext context, {
    required String appId,
    required String appName,
    String? scope,
  }) async {
    final typeCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) {
        return StatefulBuilder(builder: (dctx, setState) {
          final c = dctx.colors;
          final matches = typeCtrl.text.trim() == appId;
          return AlertDialog(
            backgroundColor: c.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            title: Row(
              children: [
                Text('💣', style: GoogleFonts.inter(fontSize: 18)),
                const SizedBox(width: 8),
                Text('Permanent deletion',
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.red)),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Everything will be erased:',
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.text)),
                  const SizedBox(height: 6),
                  _BulletLine('Bundles, modules and configurations'),
                  _BulletLine('All sessions, messages, activations'),
                  _BulletLine('Secrets and history'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: c.red.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 14, color: c.red),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'No recovery possible.',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: c.red),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Type the app id to confirm:',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: c.textMuted),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    appId,
                    style: GoogleFonts.firaCode(
                        fontSize: 12,
                        color: c.red,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: typeCtrl,
                    autofocus: true,
                    style: GoogleFonts.firaCode(fontSize: 13),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: c.inputBg,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: c.inputBorder),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: Text('Cancel',
                    style: GoogleFonts.inter(color: c.textMuted)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: matches ? c.red : c.surfaceAlt,
                  foregroundColor:
                      matches ? Colors.white : c.textDim,
                ),
                onPressed: matches
                    ? () => Navigator.of(dctx).pop(true)
                    : null,
                child: const Text('Delete everything'),
              ),
            ],
          );
        });
      },
    );
    if (ok != true) return false;

    try {
      final result = await AppsService().deleteApp(
        appId,
        deleteHistory: true,
        scope: scope,
      );
      if (context.mounted) {
        _showSuccess(context, result.message.isNotEmpty
            ? result.message
            : 'App permanently deleted.');
      }
      return true;
    } catch (e) {
      if (context.mounted) _showError(context, e);
      return false;
    }
  }

  // ── Enable (admin) ──────────────────────────────────────────────

  static Future<bool> enable(
    BuildContext context, {
    required String appId,
    required String appName,
    /// When reactivating a disabled **user** install, both `scope`
    /// and `userId` must be set to the original owner. For system
    /// installs leave both null.
    String? scope,
    String? userId,
  }) async {
    try {
      final result = await AppsService().enableApp(
        appId,
        scope: scope,
        userId: userId,
      );
      if (context.mounted) {
        _showSuccess(context, result.message.isNotEmpty
            ? result.message
            : '$appName re-enabled.');
      }
      return true;
    } catch (e) {
      if (context.mounted) _showError(context, e);
      return false;
    }
  }

  // ── Toasts ──────────────────────────────────────────────────────

  static void _showSuccess(BuildContext context, String msg) {
    final c = context.colors;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(Icons.check_circle_rounded, size: 14, color: c.green),
          const SizedBox(width: 8),
          Expanded(
              child: Text(msg,
                  style: GoogleFonts.inter(fontSize: 12.5, color: c.text))),
        ]),
        backgroundColor: c.surfaceAlt,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
      ));
  }

  static void _showError(BuildContext context, Object error) {
    final c = context.colors;
    String msg;
    if (error is DeployException) {
      if (error.missingSecrets.contains('__admin__')) {
        msg = 'Only an administrator can perform this action.';
      } else {
        msg = error.message;
      }
    } else {
      msg = error.toString();
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(Icons.error_outline_rounded, size: 14, color: c.red),
          const SizedBox(width: 8),
          Expanded(
              child: Text(msg,
                  style: GoogleFonts.inter(fontSize: 12.5, color: c.text))),
        ]),
        backgroundColor: c.red.withValues(alpha: 0.08),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: c.red.withValues(alpha: 0.3))),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 5),
      ));
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionHeader({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label.toUpperCase(),
        style: GoogleFonts.firaCode(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: color,
        ),
      ),
    );
  }
}

class _BulletLine extends StatelessWidget {
  final String text;
  const _BulletLine(this.text);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ',
              style: GoogleFonts.inter(fontSize: 13, color: c.textMuted)),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                  fontSize: 12.5, color: c.text, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
