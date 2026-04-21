/// Packages manager — Settings → Packages.
///
/// Three responsibilities:
///   1. List installed packages with badges (source, status, update)
///   2. Install dialog with permissions consent (handles 409)
///   3. Uninstall + upgrade flows (with builtin protection)
///
/// Everything sits in this single file because the dialogs share
/// helpers and the surface area is small enough that splitting
/// adds noise.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_package.dart';
import '../../services/background_app_service.dart';
import '../../services/package_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';

class PackagesManagerPage extends StatefulWidget {
  /// When true, omit the standalone scaffold so we can host inside
  /// the Settings shell.
  final bool embedded;
  const PackagesManagerPage({super.key, this.embedded = false});

  @override
  State<PackagesManagerPage> createState() => _PackagesManagerPageState();
}

class _PackagesManagerPageState extends State<PackagesManagerPage> {
  final _svc = PackageService();
  bool _loading = true;
  String? _error;
  List<AppPackage> _packages = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _svc.list();
      if (!mounted) return;
      setState(() {
        _packages = list;
        _loading = false;
      });
    } on PackageException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _install() async {
    final installed = await showDialog<AppPackage>(
      context: context,
      builder: (_) => const _InstallDialog(),
    );
    if (installed != null) _load();
  }

  Future<void> _uninstall(AppPackage pkg) async {
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
                foregroundColor: c.onAccent,
                elevation: 0),
            child: Text('Uninstall',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _svc.uninstall(pkg.packageId, force: pkg.isBuiltin);
      _toast('${pkg.name} uninstalled');
      _load();
    } on PackageException catch (e) {
      _toast(e.message, err: true);
    }
  }

  Future<void> _upgrade(AppPackage pkg) async {
    if (!pkg.hasUpdate) return;

    // D10: warn the user when the upgrade will interrupt active
    // sessions. Sources we count from:
    //  • BackgroundAppService.sessions (currently loaded for the
    //    app whose dashboard is open, if any)
    //  • SessionService.sessions (chat sessions, only the ones for
    //    this app)
    // We can't see sessions of *other* deployed apps the client has
    // never opened — that's a daemon-side number. Worst case we
    // under-count, never over-count.
    final deployedAppId = pkg.deployedAppId ?? pkg.packageId;
    final bgActive = BackgroundAppService()
        .sessions
        .where((s) => s.appId == deployedAppId && s.isActive)
        .length;
    final chatActive = SessionService()
        .sessions
        .where((s) => s.appId == deployedAppId && s.isActive)
        .length;
    final activeCount = bgActive + chatActive;

    if (activeCount > 0) {
      final ok = await _confirmUpgradeWithActive(pkg, activeCount);
      if (ok != true || !mounted) return;
    }

    try {
      final upgraded = await _svc.upgrade(pkg.packageId);
      _toast('Upgraded ${upgraded.name} to ${upgraded.version}');
      _load();
    } on PermissionsRequiredException catch (e) {
      // New permissions in the upgrade — show consent.
      final accepted = await _showConsent(e.details, isUpgrade: true);
      if (accepted != true || !mounted) return;
      try {
        await _svc.upgrade(pkg.packageId, acceptPermissions: true);
        _toast('Upgraded ${pkg.name}');
        _load();
      } on PackageException catch (e2) {
        _toast(e2.message, err: true);
      }
    } on PackageException catch (e) {
      _toast(e.message, err: true);
    }
  }

  Future<bool?> _confirmUpgradeWithActive(AppPackage pkg, int count) {
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
                foregroundColor: c.onAccent,
                elevation: 0),
            child: Text('Upgrade and interrupt',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showConsent(PermissionsRequired details,
      {bool isUpgrade = false}) {
    return showDialog<bool>(
      context: context,
      builder: (_) => _PermissionsConsentDialog(
        details: details,
        isUpgrade: isUpgrade,
      ),
    );
  }

  void _toast(String msg, {bool err = false}) {
    if (!mounted) return;
    final c = context.colors;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          (err ? c.red : c.green).withValues(alpha: 0.9),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final body = _loading
        ? Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: c.textMuted),
            ),
          )
        : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 36, color: c.red),
                      const SizedBox(height: 12),
                      Text('Failed to load packages',
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: c.textBright)),
                      const SizedBox(height: 6),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.firaCode(
                              fontSize: 11,
                              color: c.textMuted,
                              height: 1.5)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _load,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: c.surfaceAlt,
                          foregroundColor: c.text,
                          elevation: 0,
                          side: BorderSide(color: c.border),
                        ),
                        child: Text('Retry',
                            style: GoogleFonts.inter(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              )
            : _buildList(c);

    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text('Packages',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildList(AppColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 32, 40, 48),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Packages',
                            style: GoogleFonts.inter(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: c.textBright,
                            )),
                        const SizedBox(height: 5),
                        Text(
                          'Installed apps and their source. Built-ins ship with the daemon; local ones come from your filesystem.',
                          style: GoogleFonts.inter(
                            fontSize: 13.5,
                            color: c.textMuted,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _install,
                    icon: Icon(Icons.add_rounded,
                        size: 16, color: c.onAccent),
                    label: Text(
                      'Install',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.onAccent),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accentPrimary,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              // D8: degraded packages → red banner at the top with
              // a Rollback CTA per package. Only fires when the
              // daemon flagged a package as `broken` after a runtime
              // failure post-upgrade.
              for (final pkg in _packages.where((p) => p.isBroken)) ...[
                _buildBrokenBanner(c, pkg),
                const SizedBox(height: 12),
              ],
              if (_packages.isEmpty)
                _buildEmptyState(c)
              else
                Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < _packages.length; i++) ...[
                        _PackageRow(
                          pkg: _packages[i],
                          onUninstall: () => _uninstall(_packages[i]),
                          onUpgrade: () => _upgrade(_packages[i]),
                          onShowDetail: () => _showDetail(_packages[i]),
                        ),
                        if (i < _packages.length - 1)
                          Divider(height: 1, color: c.border),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBrokenBanner(AppColors c, AppPackage pkg) {
    // Try to derive the previous version from the manifest. Daemon
    // exposes `release.upgrade_from: ["1.2.0"]` per the spec; we
    // also accept a flat string for forward-compat.
    final raw = pkg.manifest.raw['package'] as Map? ?? const {};
    final release = raw['release'] as Map? ?? const {};
    final upgradeFrom = release['upgrade_from'];
    String? previousVersion;
    if (upgradeFrom is List && upgradeFrom.isNotEmpty) {
      previousVersion = upgradeFrom.last.toString();
    } else if (upgradeFrom is String && upgradeFrom.isNotEmpty) {
      previousVersion = upgradeFrom;
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.red.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: c.red),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${pkg.name} is degraded after a recent upgrade',
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: c.red,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  previousVersion != null
                      ? 'You can roll back to v$previousVersion. Workspaces and credentials are preserved.'
                      : 'You can reinstall the previous version from your local cache. Workspaces and credentials are preserved.',
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.text, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: () => _rollback(pkg, previousVersion),
            icon: Icon(Icons.undo_rounded,
                size: 14, color: c.onAccent),
            label: Text(
              previousVersion != null
                  ? 'Rollback to $previousVersion'
                  : 'Rollback',
              style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.onAccent),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.red,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rollback(AppPackage pkg, String? previousVersion) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('Roll back ${pkg.name}?',
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: Text(
          previousVersion != null
              ? 'Reinstalls v$previousVersion over the current build. The current files will be removed once the rollback succeeds.'
              : 'The daemon will look for an older version in its cache.',
          style: GoogleFonts.inter(fontSize: 12, color: c.text, height: 1.5),
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
                backgroundColor: c.red,
                foregroundColor: c.onAccent,
                elevation: 0),
            child: Text('Rollback',
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      // Rollback is just an upgrade pinned at the previous version.
      await _svc.upgrade(
        pkg.packageId,
        version: previousVersion,
        acceptPermissions: true,
      );
      _toast('${pkg.name} rolled back');
      _load();
    } on PackageException catch (e) {
      _toast(e.message, err: true);
    }
  }

  Widget _buildEmptyState(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 36, color: c.textMuted),
            const SizedBox(height: 12),
            Text('No packages installed',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.textBright,
                )),
            const SizedBox(height: 6),
            Text(
              'Click Install to add a local package, or wait for the daemon to bootstrap its built-ins.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 11.5, color: c.textMuted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(AppPackage pkg) {
    showDialog(
      context: context,
      builder: (_) => _PackageDetailDialog(pkg: pkg),
    );
  }
}

// ─── Row ──────────────────────────────────────────────────────────

class _PackageRow extends StatefulWidget {
  final AppPackage pkg;
  final VoidCallback onUninstall;
  final VoidCallback onUpgrade;
  final VoidCallback onShowDetail;
  const _PackageRow({
    required this.pkg,
    required this.onUninstall,
    required this.onUpgrade,
    required this.onShowDetail,
  });

  @override
  State<_PackageRow> createState() => _PackageRowState();
}

class _PackageRowState extends State<_PackageRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pkg = widget.pkg;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onShowDetail,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _riskColor(c, pkg).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color:
                          _riskColor(c, pkg).withValues(alpha: 0.35)),
                ),
                child: Icon(Icons.inventory_2_outlined,
                    size: 17, color: _riskColor(c, pkg)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                              fontWeight: FontWeight.w600,
                              color: c.textBright,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _SourceBadge(sourceType: pkg.sourceType),
                        const SizedBox(width: 4),
                        if (pkg.hasUpdate)
                          _Pill(
                            label: 'UPDATE',
                            tint: c.accentPrimary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'v${pkg.version} · ${pkg.description.isNotEmpty ? pkg.description : pkg.packageId}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: c.textMuted,
                          height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (pkg.hasUpdate)
                IconButton(
                  tooltip: 'Upgrade to ${pkg.updateAvailable}',
                  iconSize: 16,
                  icon: Icon(Icons.upgrade_rounded, color: c.accentPrimary),
                  onPressed: widget.onUpgrade,
                ),
              PopupMenuButton<String>(
                tooltip: 'Actions',
                icon: Icon(Icons.more_horiz_rounded,
                    size: 18, color: c.textMuted),
                onSelected: (v) {
                  if (v == 'detail') widget.onShowDetail();
                  if (v == 'uninstall') widget.onUninstall();
                  if (v == 'upgrade') widget.onUpgrade();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'detail',
                    height: 32,
                    child: Row(children: [
                      Icon(Icons.info_outline_rounded,
                          size: 13, color: c.text),
                      const SizedBox(width: 8),
                      Text('Details',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.text)),
                    ]),
                  ),
                  if (pkg.hasUpdate)
                    PopupMenuItem(
                      value: 'upgrade',
                      height: 32,
                      child: Row(children: [
                        Icon(Icons.upgrade_rounded, size: 13, color: c.accentPrimary),
                        const SizedBox(width: 8),
                        Text('Upgrade to ${pkg.updateAvailable}',
                            style: GoogleFonts.inter(
                                fontSize: 12, color: c.accentPrimary)),
                      ]),
                    ),
                  PopupMenuItem(
                    value: 'uninstall',
                    height: 32,
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 13, color: c.red),
                      const SizedBox(width: 8),
                      Text('Uninstall',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.red)),
                    ]),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _riskColor(AppColors c, AppPackage pkg) {
    switch (pkg.manifest.permissions.riskLevel) {
      case 'high':
        return c.red;
      case 'medium':
        return c.orange;
      default:
        return c.green;
    }
  }
}

class _SourceBadge extends StatelessWidget {
  final String sourceType;
  const _SourceBadge({required this.sourceType});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (label, tint) = switch (sourceType) {
      'builtin' => ('BUILTIN', c.purple),
      'local' => ('LOCAL', c.cyan),
      'hub' => ('HUB', c.accentPrimary),
      'git' => ('GIT', c.orange),
      _ => (sourceType.toUpperCase(), c.textMuted),
    };
    return _Pill(label: label, tint: tint);
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color tint;
  const _Pill({required this.label, required this.tint});

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

// ─── Detail dialog ────────────────────────────────────────────────

class _PackageDetailDialog extends StatelessWidget {
  final AppPackage pkg;
  const _PackageDetailDialog({required this.pkg});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = pkg.manifest;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(pkg.name,
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: c.textBright)),
                        const SizedBox(height: 2),
                        Text('v${pkg.version} · ${pkg.author}',
                            style: GoogleFonts.firaCode(
                                fontSize: 11, color: c.textMuted)),
                      ],
                    ),
                  ),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (pkg.description.isNotEmpty) ...[
                        Text(pkg.description,
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: c.text,
                                height: 1.5)),
                        const SizedBox(height: 14),
                      ],
                      _section(c, 'PERMISSIONS'),
                      _kv(c, 'Risk level',
                          m.permissions.riskLevel.toUpperCase()),
                      _kv(c, 'Network',
                          m.permissions.networkAccess ? 'yes' : 'no'),
                      if (m.permissions.filesystemAccess.isNotEmpty)
                        _kv(c, 'Filesystem',
                            m.permissions.filesystemAccess.join(', ')),
                      if (m.permissions.requiresApproval.isNotEmpty)
                        _kv(c, 'Needs approval',
                            m.permissions.requiresApproval.join(', ')),
                      const SizedBox(height: 14),
                      _section(c, 'CREDENTIALS'),
                      if (m.requiredCredentials.isEmpty &&
                          m.optionalCredentials.isEmpty)
                        _kv(c, '', 'none')
                      else ...[
                        if (m.requiredCredentials.isNotEmpty)
                          _kv(c, 'Required',
                              m.requiredCredentials.join(', ')),
                        if (m.optionalCredentials.isNotEmpty)
                          _kv(c, 'Optional',
                              m.optionalCredentials.join(', ')),
                      ],
                      const SizedBox(height: 14),
                      _section(c, 'REQUIREMENTS'),
                      if (m.requirements.modules.isNotEmpty)
                        _kv(c, 'Modules', m.requirements.modules.join(', ')),
                      if (m.requirements.recommendedModels.isNotEmpty)
                        _kv(c, 'Models',
                            m.requirements.recommendedModels.join(', ')),
                      if (m.compatibility.digitornMin != null)
                        _kv(c, 'Digitorn',
                            '${m.compatibility.digitornMin} → ${m.compatibility.digitornMax ?? 'latest'}'),
                      const SizedBox(height: 14),
                      _section(c, 'INSTALL'),
                      _kv(c, 'Source', pkg.sourceType),
                      if (pkg.sourceUri != null)
                        _kv(c, 'URI', pkg.sourceUri!),
                      if (pkg.installDir != null)
                        _kv(c, 'Path', pkg.installDir!),
                      if (pkg.installedAt != null)
                        _kv(c, 'Installed',
                            pkg.installedAt!.toIso8601String()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(AppColors c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 9.5,
          color: c.textMuted,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _kv(AppColors c, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (k.isNotEmpty)
            SizedBox(
              width: 110,
              child: Text(k,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.textMuted)),
            ),
          Expanded(
            child: SelectableText(v,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textBright)),
          ),
        ],
      ),
    );
  }
}

// ─── Install dialog ────────────────────────────────────────────────

class _InstallDialog extends StatefulWidget {
  const _InstallDialog();
  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  String _sourceType = 'local';
  final _uriCtrl = TextEditingController();
  final _versionCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _uriCtrl.dispose();
    _versionCtrl.dispose();
    super.dispose();
  }

  Future<void> _doInstall({bool acceptPermissions = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pkg = await PackageService().install(
        sourceType: _sourceType,
        sourceUri: _uriCtrl.text.trim(),
        version: _versionCtrl.text.trim().isEmpty
            ? null
            : _versionCtrl.text.trim(),
        acceptPermissions: acceptPermissions,
      );
      if (mounted) Navigator.pop(context, pkg);
    } on PermissionsRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (_) => _PermissionsConsentDialog(details: e.details),
      );
      if (accepted == true && mounted) {
        await _doInstall(acceptPermissions: true);
      }
    } on PackageConflictException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Already installed (${e.existingSourceType} v${e.existingVersion}). Uninstall it first.';
        });
      }
    } on PackageException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Install package',
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 4),
              Text(
                'Point at a local directory or paste a hub / git URI.',
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 16),
              Text('Source',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: 'local',
                    label: Text('Local',
                        style: GoogleFonts.inter(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: 'hub',
                    label:
                        Text('Hub', style: GoogleFonts.inter(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: 'git',
                    label:
                        Text('Git', style: GoogleFonts.inter(fontSize: 11)),
                  ),
                ],
                selected: {_sourceType},
                onSelectionChanged: (s) =>
                    setState(() => _sourceType = s.first),
              ),
              const SizedBox(height: 14),
              Text(
                  switch (_sourceType) {
                    'local' => 'Path to package directory',
                    'hub' => 'Hub URI',
                    'git' => 'Git URL',
                    _ => 'URI',
                  },
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 4),
              TextField(
                controller: _uriCtrl,
                style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: c.bg,
                  hintText: switch (_sourceType) {
                    'local' => '/home/user/my-app',
                    'hub' => 'alice/jobhunt',
                    'git' => 'https://github.com/alice/jobhunt.git',
                    _ => '',
                  },
                  hintStyle: GoogleFonts.firaCode(
                      fontSize: 12, color: c.textDim),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border)),
                ),
              ),
              if (_sourceType != 'local') ...[
                const SizedBox(height: 12),
                Text('Version (optional)',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textBright)),
                const SizedBox(height: 4),
                TextField(
                  controller: _versionCtrl,
                  style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: c.bg,
                    hintText: '1.2.0',
                    hintStyle: GoogleFonts.firaCode(
                        fontSize: 12, color: c.textDim),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: c.border)),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.red.withValues(alpha: 0.35)),
                  ),
                  child: Text(_error!,
                      style: GoogleFonts.firaCode(
                          fontSize: 11, color: c.red, height: 1.4)),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _busy ||
                            _uriCtrl.text.trim().isEmpty
                        ? null
                        : () => _doInstall(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accentPrimary,
                      foregroundColor: c.onAccent,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                    child: _busy
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: c.onAccent),
                          )
                        : Text('Install',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
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

// ─── Permissions consent dialog ───────────────────────────────────

class _PermissionsConsentDialog extends StatelessWidget {
  final PermissionsRequired details;
  final bool isUpgrade;
  const _PermissionsConsentDialog({
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
              _permRow(c, Icons.public_rounded, 'Network access',
                  p.networkAccess ? 'yes' : 'no', p.networkAccess),
              if (p.filesystemAccess.isNotEmpty)
                _permRow(
                  c,
                  Icons.folder_outlined,
                  'Filesystem',
                  p.filesystemAccess.join(', '),
                  p.filesystemAccess.contains('write'),
                ),
              if (p.filesystemScopes.isNotEmpty)
                _permRow(
                  c,
                  Icons.subdirectory_arrow_right_rounded,
                  'Scopes',
                  p.filesystemScopes.join(', '),
                  false,
                ),
              if (p.requiresApproval.isNotEmpty)
                _permRow(
                  c,
                  Icons.front_hand_outlined,
                  'Will ask before',
                  p.requiresApproval.join(', '),
                  true,
                ),
              if (details.requiredCredentials.isNotEmpty) ...[
                const SizedBox(height: 12),
                _permRow(
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
                    icon: Icon(Icons.check_rounded,
                        size: 14, color: c.onAccent),
                    label: Text('Accept and install',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: c.onAccent)),
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

  Widget _permRow(
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
