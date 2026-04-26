/// Hub package detail page — full-screen 5-tab layout
/// (Overview / Versions / Reviews / Stats / Manifest) with a hero
/// header carrying the install + report actions.
///
/// Mirror of web `HubPackageDetail`
/// (`digitorn_web/src/components/hub/package-detail.tsx`).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/hub/hub_models.dart';
import '../../services/hub_service.dart';
import '../../theme/app_theme.dart';
import 'widgets/report_dialog.dart';
import 'widgets/review_list.dart';
import 'widgets/risk_pill.dart';
import 'widgets/star_rating.dart';
import 'widgets/stats_chart.dart';
import 'widgets/verified_badge.dart';

class HubPackageDetailPage extends StatefulWidget {
  final String publisher;
  final String packageId;
  final bool installed;

  /// Returns true on success.
  final Future<bool> Function(HubPackageDetail pkg)? onInstall;

  const HubPackageDetailPage({
    super.key,
    required this.publisher,
    required this.packageId,
    required this.installed,
    this.onInstall,
  });

  @override
  State<HubPackageDetailPage> createState() => _HubPackageDetailPageState();
}

class _HubPackageDetailPageState extends State<HubPackageDetailPage>
    with SingleTickerProviderStateMixin {
  HubPackageDetail? _data;
  bool _loading = true;
  String? _error;
  bool _installing = false;
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await HubService().packageDetail(
        widget.publisher,
        widget.packageId,
      );
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    if (widget.onInstall == null || _installing || _data == null) return;
    setState(() => _installing = true);
    try {
      await widget.onInstall!(_data!);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _report() async {
    if (_data == null) return;
    await showReportDialog(
      context: context,
      publisher: widget.publisher,
      packageId: widget.packageId,
      packageName: _data!.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_loading && _data == null) {
      return Scaffold(
        backgroundColor: c.bg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null || _data == null) {
      return Scaffold(
        backgroundColor: c.bg,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined, size: 36, color: c.textDim),
              const SizedBox(height: 10),
              Text(
                _error ??
                    'Package ${widget.publisher}/${widget.packageId} not found',
                style: TextStyle(fontSize: 13, color: c.textMuted),
              ),
            ],
          ),
        ),
      );
    }

    final pkg = _data!;
    return Scaffold(
      backgroundColor: c.bg,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Hero(pkg: pkg),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 20, 40, 60),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ActionRow(
                      installed: widget.installed,
                      installing: _installing,
                      canInstall: widget.onInstall != null,
                      onInstall: _install,
                      onReport: _report,
                    ),
                    const SizedBox(height: 16),
                    _TabsBar(controller: _tabs, pkg: pkg),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 800,
                      child: TabBarView(
                        controller: _tabs,
                        children: [
                          _OverviewTab(pkg: pkg),
                          _VersionsTab(versions: pkg.versions),
                          ReviewList(
                            publisher: widget.publisher,
                            packageId: widget.packageId,
                          ),
                          StatsChart(
                            publisher: widget.publisher,
                            packageId: widget.packageId,
                          ),
                          _ManifestTab(manifest: pkg.manifest),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hero ────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final HubPackageDetail pkg;
  const _Hero({required this.pkg});

  @override
  Widget build(BuildContext context) {
    final hash = _hash(pkg.name);
    final c1 = HSLColor.fromAHSL(
      1,
      (hash % 360).toDouble(),
      0.55,
      0.45,
    ).toColor();
    final c2 = HSLColor.fromAHSL(
      1,
      ((hash ~/ 7) % 360).toDouble(),
      0.55,
      0.32,
    ).toColor();

    return Container(
      height: 240,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c1, c2],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 24,
            top: 24,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                tooltip: 'Back to Hub',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          Positioned(
            left: 40,
            right: 40,
            bottom: 24,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _IconTile(pkg: pkg),
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
                          letterSpacing: -0.5,
                          color: Colors.white,
                          height: 1.1,
                          shadows: [
                            Shadow(
                              blurRadius: 12,
                              color: Colors.black.withValues(alpha: 0.4),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${pkg.publisherSlug.isEmpty ? "anonymous" : pkg.publisherSlug} · v${pkg.latestVersion.isEmpty ? "?" : pkg.latestVersion}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          VerifiedBadge(verified: pkg.publisherVerified),
                          RiskPill(level: pkg.riskLevel),
                          if (pkg.avgRating != null)
                            StarRating(
                              value: pkg.avgRating!,
                              size: 14,
                              count: pkg.reviewCount,
                              showValue: true,
                            ),
                        ],
                      ),
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
}

class _IconTile extends StatelessWidget {
  final HubPackageDetail pkg;
  const _IconTile({required this.pkg});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: pkg.iconUrl != null && pkg.iconUrl!.isNotEmpty
          ? Image.network(
              pkg.iconUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.inventory_2_rounded,
                      size: 44, color: Colors.white),
            )
          : const Icon(Icons.inventory_2_rounded,
              size: 44, color: Colors.white),
    );
  }
}

// ─── Action row ──────────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final bool installed;
  final bool installing;
  final bool canInstall;
  final VoidCallback onInstall;
  final VoidCallback onReport;

  const _ActionRow({
    required this.installed,
    required this.installing,
    required this.canInstall,
    required this.onInstall,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  installed ? 'ALREADY INSTALLED' : 'AVAILABLE FROM HUB',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: c.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  installed
                      ? 'Manage this package from the Library tab.'
                      : 'Install through your daemon — credentials stay local.',
                  style: TextStyle(fontSize: 13, color: c.textBright),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onReport,
            icon: Icon(Icons.flag_outlined, size: 14, color: c.textMuted),
            label: Text(
              'Report',
              style: TextStyle(color: c.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          if (installed)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: c.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 14, color: c.green),
                  const SizedBox(width: 6),
                  Text(
                    'Installed',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.green,
                    ),
                  ),
                ],
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: !canInstall || installing ? null : onInstall,
              icon: installing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.download_rounded, size: 16),
              label: Text(installing ? 'Installing…' : 'Install'),
              style: ElevatedButton.styleFrom(
                backgroundColor: c.accentPrimary,
                foregroundColor: c.onAccent,
                disabledBackgroundColor:
                    c.accentPrimary.withValues(alpha: 0.4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                textStyle: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Tabs bar ────────────────────────────────────────────────────────

class _TabsBar extends StatelessWidget {
  final TabController controller;
  final HubPackageDetail pkg;
  const _TabsBar({required this.controller, required this.pkg});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicator: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(7),
        ),
        indicatorPadding: const EdgeInsets.all(0),
        dividerHeight: 0,
        labelColor: c.textBright,
        unselectedLabelColor: c.textMuted,
        labelStyle: GoogleFonts.inter(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: GoogleFonts.inter(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
        labelPadding: EdgeInsets.zero,
        padding: EdgeInsets.zero,
        tabs: [
          _tab('Overview'),
          _tab('Versions (${pkg.versions.length})'),
          _tab('Reviews (${pkg.reviewCount})'),
          _tab('Stats'),
          _tab('Manifest'),
        ],
      ),
    );
  }

  Widget _tab(String label) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(label),
      );
}

// ─── Tabs ────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final HubPackageDetail pkg;
  const _OverviewTab({required this.pkg});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Section(
            title: 'About',
            child: Text(
              pkg.description.isEmpty
                  ? 'No description provided.'
                  : pkg.description,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: c.text,
                height: 1.6,
              ),
            ),
          ),
          if (pkg.tags.isNotEmpty) ...[
            const SizedBox(height: 18),
            _Section(
              title: 'Tags',
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in pkg.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        t,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 11,
                          color: c.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'Downloads',
                  value: pkg.totalDownloads.toString(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Stat(
                  label: 'Reviews',
                  value: pkg.reviewCount.toString(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Stat(
                  label: 'Updated',
                  value: _formatDate(pkg.updatedAt),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VersionsTab extends StatelessWidget {
  final List<HubPackageVersion> versions;
  const _VersionsTab({required this.versions});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (versions.isEmpty) {
      return _EmptyMessage(
          c: c, text: 'No versions published yet.');
    }
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        itemCount: versions.length,
        separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
        itemBuilder: (_, i) {
          final v = versions[i];
          return Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Row(
                    children: [
                      Text(
                        v.version,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: c.textBright,
                        ),
                      ),
                      if (v.yanked) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: c.red.withValues(alpha: 0.35),
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            'YANKED',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: c.red,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: Tooltip(
                    message: v.archiveSha256,
                    child: Text(
                      v.archiveSha256.length >= 16
                          ? '${v.archiveSha256.substring(0, 16)}…'
                          : v.archiveSha256,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10.5,
                        color: c.textMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: Text(
                    _formatBytes(v.archiveSize),
                    textAlign: TextAlign.right,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      color: c.textMuted,
                    ),
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(
                    v.downloads.toString(),
                    textAlign: TextAlign.right,
                    style: GoogleFonts.jetBrainsMono(
                      fontSize: 12,
                      color: c.textMuted,
                    ),
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Text(
                    _formatDate(v.releasedAt),
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ManifestTab extends StatelessWidget {
  final Map<String, dynamic> manifest;
  const _ManifestTab({required this.manifest});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (manifest.isEmpty) {
      return _EmptyMessage(
          c: c, text: 'No manifest exposed for this package.');
    }
    final json = const JsonEncoder.withIndent('  ').convert(manifest);
    return SingleChildScrollView(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          json,
          style: GoogleFonts.jetBrainsMono(
            fontSize: 11.5,
            color: c.text,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          style: GoogleFonts.jetBrainsMono(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: c.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
              color: c.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
              color: c.textBright,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyMessage extends StatelessWidget {
  final AppColors c;
  final String text;
  const _EmptyMessage({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

int _hash(String s) {
  var h = 0;
  for (var i = 0; i < s.length; i++) {
    h = (h * 31 + s.codeUnitAt(i)) & 0x7fffffff;
  }
  return h;
}

String _formatBytes(int n) {
  if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MiB';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KiB';
  return '$n B';
}

String _formatDate(String iso) {
  if (iso.isEmpty) return '—';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}
