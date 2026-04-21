/// Full-screen detail page for a single package — opened from the
/// store's Discover or Library tabs. Big hero header, manifest
/// breakdown, install / open / uninstall actions.
///
/// The page works for both **installed** packages (shows "Open"
/// + Uninstall) and **discoverable** ones (shows "Install"). It
/// figures out which mode it's in by checking the `installed`
/// boolean passed at construction.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_package.dart';
import '../../theme/app_theme.dart';
import 'featured_catalogue.dart';
import 'install_flow.dart';

class PackageDetailPage extends StatefulWidget {
  final AppPackage pkg;

  /// True when this package is already installed locally (drives
  /// the action button between Install vs Open / Uninstall).
  final bool installed;

  const PackageDetailPage({
    super.key,
    required this.pkg,
    required this.installed,
  });

  @override
  State<PackageDetailPage> createState() => _PackageDetailPageState();
}

class _PackageDetailPageState extends State<PackageDetailPage> {
  late AppPackage _pkg = widget.pkg;
  late bool _installed = widget.installed;
  bool _busy = false;

  Future<void> _install() async {
    setState(() => _busy = true);
    try {
      final installed = await PackageInstallFlow.install(
        context,
        sourceType: _pkg.sourceType,
        sourceUri: _pkg.sourceUri ?? _pkg.packageId,
        version: _pkg.version,
      );
      if (!mounted) return;
      if (installed != null) {
        setState(() {
          _pkg = installed;
          _installed = true;
          _busy = false;
        });
      } else {
        setState(() => _busy = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  Future<void> _uninstall() async {
    final ok = await PackageInstallFlow.uninstall(context, _pkg);
    if (ok && mounted) {
      setState(() => _installed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: c.surface,
            elevation: 0,
            pinned: true,
            expandedHeight: 280,
            iconTheme: IconThemeData(color: c.text),
            flexibleSpace: FlexibleSpaceBar(
              background: _Hero(pkg: _pkg),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(40, 24, 40, 60),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: Center(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _ActionRow(
                          pkg: _pkg,
                          installed: _installed,
                          busy: _busy,
                          onInstall: _install,
                          onUninstall: _uninstall,
                        ),
                        const SizedBox(height: 32),
                        if (_pkg.description.isNotEmpty) ...[
                          _section(c, 'ABOUT'),
                          const SizedBox(height: 8),
                          Text(
                            _pkg.description,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: c.text,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 28),
                        ],
                        _PermissionsCard(perms: _pkg.manifest.permissions),
                        const SizedBox(height: 28),
                        _RequirementsCard(
                          reqs: _pkg.manifest.requirements,
                          requiredCreds:
                              _pkg.manifest.requiredCredentials,
                          optionalCreds:
                              _pkg.manifest.optionalCredentials,
                        ),
                        const SizedBox(height: 28),
                        _MetadataCard(pkg: _pkg),
                      ],
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(AppColors c, String label) {
    return Text(
      label,
      style: GoogleFonts.firaCode(
        fontSize: 11,
        color: c.textMuted,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }
}

// ─── Hero header ──────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final AppPackage pkg;
  const _Hero({required this.pkg});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hash = pkg.name.hashCode;
    final c1 = HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.55, 0.45)
        .toColor();
    final c2 = HSLColor.fromAHSL(
            1, ((hash ~/ 7) % 360).toDouble(), 0.55, 0.32)
        .toColor();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c1, c2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 40,
            bottom: 24,
            right: 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.onAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: c.onAccent.withValues(alpha: 0.35),
                        width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: c.shadow.withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: pkg.icon != null && pkg.icon!.isNotEmpty
                      ? Text(pkg.icon!,
                          style: const TextStyle(fontSize: 48))
                      : Icon(Icons.inventory_2_rounded,
                          size: 44, color: c.onAccent),
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        pkg.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          color: c.onAccent,
                          letterSpacing: -0.5,
                          shadows: [
                            Shadow(
                              color: Colors.black
                                  .withValues(alpha: 0.4),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${pkg.author} · v${pkg.version}',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: c.onAccent.withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _heroChips(c, pkg),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroChips(AppColors c, AppPackage pkg) {
    final stats = FeaturedCatalogue.statsFor(pkg);
    final chips = <Widget>[];
    if (stats.featured) {
      chips.add(_chip('★ FEATURED', c.orange));
    }
    if (pkg.category != null) {
      chips.add(_chip(pkg.category!.toUpperCase(),
          c.onAccent.withValues(alpha: 0.9)));
    }
    if (stats.downloads > 0) {
      chips.add(_chip(
          '${_formatDownloads(stats.downloads)} installs',
          c.onAccent.withValues(alpha: 0.85)));
    }
    if (stats.rating > 0) {
      chips.add(_chip('★ ${stats.rating.toStringAsFixed(1)}',
          c.onAccent.withValues(alpha: 0.85)));
    }
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: GoogleFonts.firaCode(
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      );

  String _formatDownloads(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

// ─── Big action row ───────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final AppPackage pkg;
  final bool installed;
  final bool busy;
  final VoidCallback onInstall;
  final VoidCallback onUninstall;
  const _ActionRow({
    required this.pkg,
    required this.installed,
    required this.busy,
    required this.onInstall,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  installed
                      ? 'Installed on this daemon'
                      : 'Available to install',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: c.textMuted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  installed
                      ? 'You can launch the app from the apps grid.'
                      : 'Review the permissions before installing.',
                  style: GoogleFonts.inter(
                      fontSize: 13, color: c.textBright),
                ),
              ],
            ),
          ),
          if (installed)
            OutlinedButton.icon(
              onPressed: busy ? null : onUninstall,
              icon: Icon(Icons.delete_outline_rounded,
                  size: 14, color: c.red),
              label: Text('Uninstall',
                  style: GoogleFonts.inter(fontSize: 12, color: c.red)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.red.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 14),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: busy ? null : onInstall,
              icon: busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: c.onAccent),
                    )
                  : Icon(Icons.download_rounded,
                      size: 16, color: c.onAccent),
              label: Text(
                busy ? 'Installing…' : 'Install',
                style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: c.onAccent),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.accentPrimary,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                    horizontal: 22, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Permissions card ─────────────────────────────────────────────

class _PermissionsCard extends StatelessWidget {
  final PackagePermissions perms;
  const _PermissionsCard({required this.perms});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = switch (perms.riskLevel) {
      'high' => c.red,
      'medium' => c.orange,
      _ => c.green,
    };
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                perms.riskLevel == 'high'
                    ? Icons.warning_amber_rounded
                    : Icons.shield_outlined,
                size: 18,
                color: tint,
              ),
              const SizedBox(width: 10),
              Text('Permissions',
                  style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: tint.withValues(alpha: 0.4)),
                ),
                child: Text(
                  '${perms.riskLevel.toUpperCase()} RISK',
                  style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: tint,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _row(c, Icons.public_rounded, 'Network access',
              perms.networkAccess ? 'Yes — calls external APIs' : 'No'),
          if (perms.filesystemAccess.isNotEmpty)
            _row(c, Icons.folder_outlined, 'Filesystem',
                perms.filesystemAccess.join(' / ')),
          if (perms.filesystemScopes.isNotEmpty)
            _row(c, Icons.subdirectory_arrow_right_rounded, 'Scopes',
                perms.filesystemScopes.join(', ')),
          if (perms.requiresApproval.isNotEmpty)
            _row(c, Icons.front_hand_outlined, 'Will ask before',
                perms.requiresApproval.join(', ')),
        ],
      ),
    );
  }

  Widget _row(AppColors c, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: c.textMuted),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: Text(label,
                style:
                    GoogleFonts.inter(fontSize: 12.5, color: c.textMuted)),
          ),
          Expanded(
            child: Text(value,
                style: GoogleFonts.inter(
                    fontSize: 12.5, color: c.textBright)),
          ),
        ],
      ),
    );
  }
}

// ─── Requirements card ────────────────────────────────────────────

class _RequirementsCard extends StatelessWidget {
  final PackageRequirements reqs;
  final List<String> requiredCreds;
  final List<String> optionalCreds;
  const _RequirementsCard({
    required this.reqs,
    required this.requiredCreds,
    required this.optionalCreds,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 18, color: c.text),
              const SizedBox(width: 10),
              Text('Requirements',
                  style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
            ],
          ),
          const SizedBox(height: 14),
          if (reqs.modules.isNotEmpty)
            _wrapRow(c, 'Modules', reqs.modules,
                tint: c.accentPrimary),
          if (reqs.recommendedModels.isNotEmpty)
            _wrapRow(c, 'Models', reqs.recommendedModels, tint: c.purple),
          if (requiredCreds.isNotEmpty)
            _wrapRow(c, 'Required credentials', requiredCreds, tint: c.red),
          if (optionalCreds.isNotEmpty)
            _wrapRow(c, 'Optional credentials', optionalCreds, tint: c.green),
          if (reqs.externalTools.isNotEmpty)
            _wrapRow(c, 'External tools', reqs.externalTools,
                tint: c.orange),
        ],
      ),
    );
  }

  Widget _wrapRow(AppColors c, String label, List<String> items,
      {required Color tint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 170,
            child: Text(label,
                style:
                    GoogleFonts.inter(fontSize: 12.5, color: c.textMuted)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final i in items)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                      border:
                          Border.all(color: tint.withValues(alpha: 0.3)),
                    ),
                    child: Text(i,
                        style: GoogleFonts.firaCode(
                            fontSize: 10.5,
                            color: tint,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Metadata card ────────────────────────────────────────────────

class _MetadataCard extends StatelessWidget {
  final AppPackage pkg;
  const _MetadataCard({required this.pkg});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: c.text),
              const SizedBox(width: 10),
              Text('Package details',
                  style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
            ],
          ),
          const SizedBox(height: 14),
          _kv(c, 'package_id', pkg.packageId),
          _kv(c, 'version', pkg.version),
          _kv(c, 'author', pkg.author),
          _kv(c, 'source', pkg.sourceType),
          if (pkg.sourceUri != null) _kv(c, 'source_uri', pkg.sourceUri!),
          if (pkg.installDir != null) _kv(c, 'install_dir', pkg.installDir!),
          if (pkg.installedAt != null)
            _kv(c, 'installed_at', pkg.installedAt!.toIso8601String()),
          if (pkg.hash != null && pkg.hash!.isNotEmpty)
            _kv(c, 'hash', pkg.hash!),
        ],
      ),
    );
  }

  Widget _kv(AppColors c, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(k,
                style:
                    GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
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
