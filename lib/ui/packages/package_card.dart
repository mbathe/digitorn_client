/// Reusable card used by both the Discover grid and the Library
/// grid. Built to look like an App Store / Microsoft Store tile —
/// gradient icon block, name + author, description, action button
/// in the bottom-right.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_package.dart';
import '../../services/app_lifecycle_service.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_bubbles.dart' show showToast;
import '../common/remote_icon.dart';
import 'featured_catalogue.dart';

class PackageCard extends StatefulWidget {
  final AppPackage pkg;
  final bool installed;
  final VoidCallback onTap;
  final VoidCallback onInstall;
  final VoidCallback? onUpgrade;
  final VoidCallback? onUninstall;

  /// When provided on an installed card, the primary action becomes
  /// a "Launch" button that opens the app's chat / dashboard. Used
  /// by the Hub's Library tab — the standalone manager doesn't
  /// pass it because launching from there is ambiguous (no clear
  /// destination panel).
  final VoidCallback? onLaunch;

  /// Called after any lifecycle action on the card (reload / disable
  /// / enable / delete) so the parent can reload its list. Optional
  /// — falls back to a no-op when null.
  final VoidCallback? onLifecycleChanged;

  const PackageCard({
    super.key,
    required this.pkg,
    required this.installed,
    required this.onTap,
    required this.onInstall,
    this.onUpgrade,
    this.onUninstall,
    this.onLaunch,
    this.onLifecycleChanged,
  });

  @override
  State<PackageCard> createState() => _PackageCardState();
}

class _PackageCardState extends State<PackageCard> {
  bool _h = false;

  Color get _seedColor {
    final hash = widget.pkg.name.hashCode;
    return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.45)
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pkg = widget.pkg;
    final stats = FeaturedCatalogue.statsFor(pkg);
    final risk = pkg.manifest.permissions.riskLevel;
    final riskTint = switch (risk) {
      'high' => c.red,
      'medium' => c.orange,
      _ => c.green,
    };

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, _h ? -2.0 : 0.0, 0.0, 1.0),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _h ? c.borderHover : c.border,
              width: _h ? 1.3 : 1,
            ),
            boxShadow: _h
                ? [
                    BoxShadow(
                      color: _seedColor.withValues(alpha: 0.22),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [],
          ),
          padding: const EdgeInsets.all(9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  RemoteIcon(
                    id: pkg.deployedAppId ?? pkg.packageId,
                    kind: widget.installed
                        ? RemoteIconKind.app
                        : RemoteIconKind.package,
                    size: 32,
                    transparent: true,
                    emojiFallback: pkg.icon,
                    nameFallback: pkg.name,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                pkg.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: c.textBright,
                                  letterSpacing: -0.2,
                                  height: 1.15,
                                ),
                              ),
                            ),
                            if (stats.featured) ...[
                              const SizedBox(width: 3),
                              Icon(Icons.star_rounded,
                                  size: 11,
                                  color: Colors.amber.shade600),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          pkg.author.isNotEmpty
                              ? pkg.author
                              : pkg.packageId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.firaCode(
                            fontSize: 9.5,
                            color: c.textMuted,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  pkg.description.isNotEmpty
                      ? pkg.description
                      : pkg.packageId,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.text,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 3,
                runSpacing: 3,
                children: [
                  _Tag(
                    label: pkg.sourceType.toUpperCase(),
                    tint: _sourceTint(c, pkg.sourceType),
                  ),
                  if (widget.installed && pkg.scope != null)
                    _Tag(
                      label: pkg.isSystemScope ? 'SYSTEM' : 'PERSONAL',
                      tint: pkg.isSystemScope ? c.blue : c.green,
                    ),
                  _Tag(
                    label: '$risk risk',
                    tint: riskTint,
                  ),
                  if (stats.rating > 0)
                    _Tag(
                      label: '★ ${stats.rating.toStringAsFixed(1)}',
                      tint: c.orange,
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  if (stats.downloads > 0)
                    Row(
                      children: [
                        Icon(Icons.download_done_rounded,
                            size: 11, color: c.textMuted),
                        const SizedBox(width: 3),
                        Text(_formatDownloads(stats.downloads),
                            style: GoogleFonts.firaCode(
                                fontSize: 9.5,
                                color: c.textMuted,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  const Spacer(),
                  if (widget.installed) ...[
                    if (widget.pkg.hasUpdate &&
                        widget.onUpgrade != null) ...[
                      _PrimaryActionButton(
                        label: 'Update',
                        icon: Icons.upgrade_rounded,
                        onTap: widget.onUpgrade!,
                        tint: c.blue,
                      ),
                      const SizedBox(width: 5),
                    ],
                    // Only show "Launch" for apps whose daemon
                    // `runtime_status == "running"`. Broken and
                    // not-deployed installs surface through the
                    // Hub's dedicated sections with their own
                    // remediation actions — letting the user tap
                    // Launch on a paused app just throws the "could
                    // not find a deployed app" snackbar, which is
                    // worse UX than hiding the affordance.
                    if (widget.onLaunch != null && widget.pkg.isRunning) ...[
                      _PrimaryActionButton(
                        label: 'Launch',
                        icon: Icons.play_arrow_rounded,
                        onTap: widget.onLaunch!,
                        tint: c.green,
                      ),
                      const SizedBox(width: 5),
                      _AdminMenuButton(
                        pkg: widget.pkg,
                        onDetails: widget.onTap,
                        onLifecycleChanged: widget.onLifecycleChanged,
                      ),
                    ] else
                      _AdminMenuButton(
                        pkg: widget.pkg,
                        onDetails: widget.onTap,
                        onLifecycleChanged: widget.onLifecycleChanged,
                        fallbackLabel:
                            widget.pkg.hasUpdate ? '' : 'Installed',
                      ),
                  ] else
                    _PrimaryActionButton(
                      label: 'Install',
                      icon: Icons.download_rounded,
                      onTap: widget.onInstall,
                      tint: c.blue,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _sourceTint(AppColors c, String source) {
    return switch (source) {
      'builtin' => c.purple,
      'local' => c.cyan,
      'hub' => c.blue,
      'git' => c.orange,
      _ => c.textMuted,
    };
  }

  String _formatDownloads(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color tint;
  const _Tag({required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 8.5,
          color: tint,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color tint;
  const _PrimaryActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 13, color: Colors.white),
      label: Text(
        label,
        style: GoogleFonts.inter(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: Colors.white),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: tint,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 30),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}

/// Per-app admin chip. On tap, shows a popup menu with:
///   • Details — opens the package detail page (same as the old ⋮)
///   • Reload  — re-reads app.yaml via `AppLifecycleService.reload`
///   • Disable — pauses the app (non-admin triggers disabled for
///               system-scope installs, handled server-side)
///   • Enable  — reverse of Disable (shown only when app appears
///               to be disabled in the package status)
///   • Delete  — destructive, admin-scope undeploy
///
/// Uses the package's `deployedAppId` so the action targets the
/// running app, not a different deployment.
class _AdminMenuButton extends StatefulWidget {
  final AppPackage pkg;
  final VoidCallback onDetails;
  final VoidCallback? onLifecycleChanged;
  final String? fallbackLabel;

  const _AdminMenuButton({
    required this.pkg,
    required this.onDetails,
    this.onLifecycleChanged,
    this.fallbackLabel,
  });

  @override
  State<_AdminMenuButton> createState() => _AdminMenuButtonState();
}

class _AdminMenuButtonState extends State<_AdminMenuButton> {
  bool _busy = false;

  String get _appId =>
      (widget.pkg.deployedAppId ?? widget.pkg.packageId);

  Future<void> _runAndRefresh(
      Future<bool> Function() action, String label) async {
    debugPrint('AdminMenu.$label → firing for app=$_appId');
    setState(() => _busy = true);
    bool ok = false;
    String? errorMessage;
    try {
      ok = await action();
      debugPrint('AdminMenu.$label ← ok=$ok');
    } catch (e) {
      debugPrint('AdminMenu.$label ← exception: $e');
      errorMessage = e.toString();
      final match = RegExp(r'AppCatalogException\([^)]*\):\s*(.*)')
          .firstMatch(errorMessage);
      if (match != null) errorMessage = match.group(1);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, '$label: OK');
      widget.onLifecycleChanged?.call();
      return;
    }
    // Show the failure via an AlertDialog instead of a toast — if
    // there's no ScaffoldMessenger ancestor (which was the cause of
    // the "nothing happens when I click" report), the toast is
    // silently dropped. A dialog always surfaces because it hangs
    // off the root navigator.
    await _showErrorDialog(label, errorMessage);
  }

  Future<void> _showErrorDialog(String action, String? message) async {
    if (!mounted) return;
    final c = context.colors;
    await showDialog<void>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: c.red),
            const SizedBox(width: 8),
            Text('$action failed',
                style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.textBright)),
          ],
        ),
        content: Text(
          message?.isNotEmpty == true
              ? message!
              : 'The daemon returned an unexpected response. Check the '
                  'console (flutter logs) for the request + response pair.',
          style: GoogleFonts.inter(fontSize: 12.5, color: c.text, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(),
            child: Text('OK',
                style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndRun({
    required String title,
    required String body,
    required Future<bool> Function() action,
    required String label,
    bool danger = false,
  }) async {
    debugPrint('AdminMenu: opening confirm dialog for "$label"');
    final c = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text(title,
            style: GoogleFonts.inter(
                fontSize: 15, fontWeight: FontWeight.w700)),
        content: Text(body,
            style: GoogleFonts.inter(fontSize: 13, color: c.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: c.red)
                : null,
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: Text(label),
          ),
        ],
      ),
    );
    debugPrint('AdminMenu: confirm dialog closed, confirmed=$confirmed');
    if (confirmed == true) await _runAndRefresh(action, label);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Built-ins can't be deleted server-side; we still show the
    // menu but flag the destructive entry with a hint.
    final isBuiltin = widget.pkg.sourceType == 'builtin';
    return PopupMenuButton<String>(
      tooltip: 'Manage app',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.border),
      ),
      onSelected: (v) {
        // Forward the pkg's known scope to every write endpoint.
        // Without this, each call defaults to `scope=user` on the
        // daemon and returns "not found in DB" for any install the
        // caller didn't put there themselves (every built-in, every
        // `system`-scoped install — 39/46 on a typical daemon).
        final scope = widget.pkg.scope;
        switch (v) {
          case 'details':
            widget.onDetails();
          case 'reload':
            _runAndRefresh(
                () => AppLifecycleService().reload(_appId), 'Reload');
          case 'disable':
            _confirmAndRun(
              title: 'Disable ${widget.pkg.name}?',
              body: 'The app is paused — triggers stop firing and '
                  'new messages are refused. Existing sessions '
                  'keep their state. You can re-enable anytime.',
              action: () =>
                  AppLifecycleService().disable(_appId, scope: scope),
              label: 'Disable',
            );
          case 'enable':
            _runAndRefresh(
                () =>
                    AppLifecycleService().enable(_appId, scope: scope),
                'Enable');
          case 'delete':
            _confirmAndRun(
              title: 'Delete ${widget.pkg.name}?',
              body: 'Removes the app and its files on disk. '
                  'Sessions and history are preserved.',
              action: () => AppLifecycleService().deleteApp(
                _appId,
                scope: scope,
                force: isBuiltin,
              ),
              label: 'Delete',
              danger: true,
            );
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'details',
          height: 34,
          child: _menuRow(c, Icons.info_outline_rounded, 'Details'),
        ),
        PopupMenuItem(
          value: 'reload',
          height: 34,
          child: _menuRow(c, Icons.refresh_rounded, 'Reload'),
        ),
        PopupMenuItem(
          value: 'disable',
          height: 34,
          child: _menuRow(c, Icons.pause_rounded, 'Disable',
              tint: c.orange),
        ),
        PopupMenuItem(
          value: 'enable',
          height: 34,
          child: _menuRow(c, Icons.play_arrow_rounded, 'Enable',
              tint: c.green),
        ),
        const PopupMenuDivider(height: 4),
        PopupMenuItem(
          value: 'delete',
          height: 34,
          enabled: !isBuiltin,
          child: _menuRow(c, Icons.delete_outline_rounded,
              isBuiltin ? 'Delete (built-in protected)' : 'Delete',
              tint: isBuiltin ? c.textDim : c.red),
        ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: widget.fallbackLabel?.isNotEmpty == true
                ? 11
                : 7,
            vertical: 8),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(6),
        ),
        constraints: const BoxConstraints(minHeight: 30),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              )
            else
              Icon(Icons.more_horiz_rounded, size: 13, color: c.text),
            if (widget.fallbackLabel?.isNotEmpty == true) ...[
              const SizedBox(width: 6),
              Text(
                widget.fallbackLabel!,
                style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: c.text),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _menuRow(AppColors c, IconData icon, String label, {Color? tint}) {
    return Row(
      children: [
        Icon(icon, size: 14, color: tint ?? c.text),
        const SizedBox(width: 10),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 12.5,
                color: tint ?? c.text,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
}
