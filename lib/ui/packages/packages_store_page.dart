/// **Packages Store** — the new top-level surface that replaces the
/// flat list. Three tabs:
///
///   1. **Discover** — featured + browseable hub catalogue. When
///      the daemon's hub source is stubbed (501) we fall back to a
///      curated catalogue so the demo still feels alive.
///   2. **Library** — installed packages with source badges and a
///      contextual menu (detail / upgrade / uninstall).
///   3. **Updates** — packages with `update_available` set, plus an
///      "Upgrade all" CTA.
///
/// Visual reference: macOS App Store + Microsoft Store. Hero
/// featured banner, category chips, search, grid cards.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../models/app_package.dart';
import '../../models/app_summary.dart';
import '../../services/apps_service.dart';
import '../../services/auth_service.dart';
import '../../services/hub_install_controller.dart';
import '../../services/package_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../common/pill_tab_bar.dart';
import '../hub/hub_discover_view.dart';
import '../hub/hub_package_detail_page.dart';
import 'disabled_apps_section.dart';
import 'featured_catalogue.dart';
import 'install_flow.dart';
import 'lifecycle_dialogs.dart';
import 'modules_view.dart';
import 'package_card.dart';
import 'scope_badge.dart';
import 'package_detail_page.dart';

/// Shared responsive grid used by every store tab so Discover,
/// Library and Updates always look identical. Tweak the constants
/// here once and every surface follows.
Widget buildPackageGrid({
  required List<Widget> children,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final w = constraints.maxWidth;
      final cols = w >= 1400 ? 6
          : (w >= 1100 ? 5
          : (w >= 820 ? 4
          : (w >= 580 ? 3
          : (w >= 380 ? 2 : 1))));
      final ratio = w >= 820 ? 1.55
          : (w >= 580 ? 1.4
          : (w >= 380 ? 1.2 : 1.3));
      return GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: cols,
        childAspectRatio: ratio,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: children,
      );
    },
  );
}

class PackagesStorePage extends StatefulWidget {
  /// When true, the page is hosted inside the Settings shell — we
  /// drop the standalone scaffold chrome.
  final bool embedded;

  /// When true, the "Modules" sub-tab is hidden. Set by the Hub page
  /// which already surfaces Modules as its own top-level tab — we
  /// don't want to render it twice.
  final bool hideModulesTab;

  /// When true, the page hides its own title/subtitle/tabs header
  /// because its parent (the Hub) is already providing one. Only
  /// the tab content area gets rendered. Avoids the "double header"
  /// look when the page is embedded inside another tabbed shell.
  final bool hideHeader;

  const PackagesStorePage({
    super.key,
    this.embedded = false,
    this.hideModulesTab = false,
    this.hideHeader = false,
  });

  @override
  State<PackagesStorePage> createState() => _PackagesStorePageState();
}

class _PackagesStorePageState extends State<PackagesStorePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: widget.hideModulesTab ? 3 : 4,
    vsync: this,
  );
  final _svc = PackageService();

  bool _loading = true;
  String? _error;
  List<AppPackage> _installed = const [];

  @override
  void initState() {
    super.initState();
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
      // Refresh AppsService in parallel so its cache is warm when
      // the per-card admin menu fires lifecycle actions. We don't
      // filter the installed list against it though — the daemon
      // doesn't uniformly populate `deployed_app_id` on every
      // package, and a strict filter hides legitimate apps.
      final installed = await _svc.list().catchError((_) => <AppPackage>[]);
      // Warm the AppsService cache in the background — the per-card
      // admin menu fires lifecycle actions that rely on it.
      // ignore: discarded_futures
      AppsService().refresh().catchError((_) {});
      if (!mounted) return;
      setState(() {
        _installed = installed;
        _loading = false;
      });
      // Kick off the per-app update probe in the background. The
      // unified API dropped the bulk `/check-updates` endpoint in
      // favour of one call per app, so we fan out here and stamp
      // `updateAvailable` back into the cached rows as they return.
      // Fire-and-forget by design: the main list paints immediately
      // and the Updates tab badge fills in a few hundred ms later.
      // ignore: discarded_futures
      _refreshUpdateBadges();
    } on PackageException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Probe each installed app's `/check-update` endpoint and fold
  /// the result back into `_installed` so [AppPackage.hasUpdate]
  /// starts returning `true` where appropriate and the Updates tab
  /// renders its cards.
  Future<void> _refreshUpdateBadges() async {
    if (_installed.isEmpty) return;
    final List<({String packageId, String current, String latest})> probes;
    try {
      probes = await _svc.checkUpdates();
    } catch (_) {
      return;
    }
    if (!mounted || probes.isEmpty) return;
    final byId = {for (final p in probes) p.packageId: p.latest};
    setState(() {
      _installed = [
        for (final pkg in _installed)
          byId.containsKey(pkg.packageId)
              ? pkg.copyWith(updateAvailable: byId[pkg.packageId])
              : pkg,
      ];
    });
  }

  bool _isInstalled(String packageId) =>
      _installed.any((p) => p.packageId == packageId);

  int get _updatesCount =>
      _installed.where((p) => p.hasUpdate).length;

  void _openDetail(AppPackage pkg) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PackageDetailPage(
        pkg: pkg,
        installed: _isInstalled(pkg.packageId),
      ),
    ));
  }

  Future<void> _quickUpgrade(AppPackage pkg) async {
    final upgraded = await PackageInstallFlow.upgrade(context, pkg);
    if (upgraded != null) _load();
  }

  Future<void> _quickUninstall(AppPackage pkg) async {
    // Built-in apps can't be uninstalled — the daemon rejects them
    // outright. Show a short toast and bail.
    if (pkg.sourceType == 'builtin') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Built-in apps cannot be uninstalled",
            style: GoogleFonts.inter(fontSize: 12.5)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
      return;
    }

    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    final isSystem = pkg.isSystemScope;

    // Non-admins can't touch system installs at all — show a
    // blocking dialog explaining why, skip the chooser entirely.
    if (isSystem && !isAdmin) {
      await _showSystemBlockedDialog(pkg);
      return;
    }

    final choice = await _pickLifecycleAction(pkg, isAdmin: isAdmin);
    if (!mounted || choice == null) return;
    final appId = pkg.deployedAppId ?? pkg.packageId;
    // For admin-on-system we explicitly pass scope=system so the
    // daemon doesn't fall back to the admin's private install (if
    // any). For user installs we leave scope null — the daemon
    // targets the caller's install via JWT.
    final scope = isSystem ? 'system' : null;
    var ok = false;
    switch (choice) {
      case _LifecycleChoice.disable:
        ok = await AppLifecycleDialogs.disable(
            context, appId: appId, appName: pkg.name, scope: scope);
      case _LifecycleChoice.deleteKeep:
        ok = await AppLifecycleDialogs.deleteKeep(
            context, appId: appId, appName: pkg.name, scope: scope);
      case _LifecycleChoice.deletePermanent:
        ok = await AppLifecycleDialogs.deletePermanent(
            context, appId: appId, appName: pkg.name, scope: scope);
    }
    if (ok) _load();
  }

  Future<void> _showSystemBlockedDialog(AppPackage pkg) async {
    await showDialog<void>(
      context: context,
      builder: (dctx) {
        final c = dctx.colors;
        return AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: [
              Icon(Icons.admin_panel_settings_rounded,
                  color: c.orange, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Administrator action required',
                    style: GoogleFonts.inter(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '"${pkg.name}" is a system-wide install — only an '
                  'administrator can disable or delete it.',
                  style: GoogleFonts.inter(
                      fontSize: 13, color: c.textMuted, height: 1.5),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.accentPrimary.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: c.accentPrimary.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.lightbulb_outline_rounded,
                          size: 14, color: c.accentPrimary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "You can install it privately for yourself "
                          "via the marketplace — that private copy is "
                          "yours to manage.",
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.text, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: Text('common.close'.tr(),
                  style: GoogleFonts.inter(color: c.textMuted)),
            ),
          ],
        );
      },
    );
  }

  Future<_LifecycleChoice?> _pickLifecycleAction(
    AppPackage pkg, {
    required bool isAdmin,
  }) async {
    final isSystem = pkg.isSystemScope;
    // Different copy when the admin is about to hit a system install:
    // every user will lose access, so we name that out loud.
    final scopeSuffix = isSystem ? ' — affects all users' : '';
    return showDialog<_LifecycleChoice>(
      context: context,
      builder: (dctx) {
        final c = dctx.colors;
        return AlertDialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          title: Row(
            children: [
              Text('Manage "${pkg.name}"',
                  style: GoogleFonts.inter(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              ScopeBadge(
                  isSystem: isSystem,
                  ownerUserId: pkg.ownerUserId ?? ''),
            ],
          ),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSystem && isAdmin) ...[
                  Container(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: c.red.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: c.red.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 14, color: c.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Admin action — every user will be '
                            'impacted by these changes.',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: c.red,
                                height: 1.45,
                                fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                _LifecycleOption(
                  icon: Icons.pause_circle_outline_rounded,
                  color: c.orange,
                  label: 'Disable$scopeSuffix',
                  description: isSystem
                      ? 'Hide the app from everyone. An admin can '
                          're-enable it later.'
                      : 'Hide the app. Reversible by an admin — '
                          'nothing is deleted.',
                  onTap: () => Navigator.of(dctx)
                      .pop(_LifecycleChoice.disable),
                ),
                _LifecycleOption(
                  icon: Icons.delete_outline_rounded,
                  color: c.red,
                  label: 'Delete (keep history)$scopeSuffix',
                  description:
                      'Wipe the code + secrets. Sessions and logs '
                      'stay for audit. Bundle cannot be recovered.',
                  onTap: () => Navigator.of(dctx)
                      .pop(_LifecycleChoice.deleteKeep),
                ),
                _LifecycleOption(
                  icon: Icons.delete_forever_rounded,
                  color: c.red,
                  label: 'Delete permanently$scopeSuffix',
                  description:
                      'Erase everything — bundle, sessions, logs, '
                      'secrets. Typed confirmation required.',
                  accent: true,
                  onTap: () => Navigator.of(dctx)
                      .pop(_LifecycleChoice.deletePermanent),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: Text('common.cancel'.tr(),
                  style: GoogleFonts.inter(color: c.textMuted)),
            ),
          ],
        );
      },
    );
  }

  /// Launch an installed package — find the matching deployed app
  /// in [AppsService], make it active, and switch the panel to
  /// chat (or background dashboard, the chat panel renders the
  /// right shell automatically based on `app.mode`).
  Future<void> _quickLaunch(AppPackage pkg) async {
    final state = Provider.of<AppState>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    // The daemon may name the deployed app slightly differently
    // from the package id — `deployed_app_id` carries the canonical
    // mapping. Fall back to package id for legacy responses.
    final targetId = pkg.deployedAppId ?? pkg.packageId;
    AppSummary? app;
    for (final a in AppsService().apps) {
      if (a.appId == targetId) {
        app = a;
        break;
      }
    }
    // If the apps cache is empty (we just got here without hitting
    // the dashboard), refresh once and retry.
    if (app == null) {
      try {
        await AppsService().refresh();
      } catch (_) {}
      for (final a in AppsService().apps) {
        if (a.appId == targetId) {
          app = a;
          break;
        }
      }
    }
    if (app == null) {
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Could not find a deployed app for ${pkg.name}.',
          style: GoogleFonts.inter(fontSize: 12),
        ),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    if (!mounted) return;
    await state.setApp(app);
    SessionService().loadSessions(app.appId);
    state.setPanel(ActivePanel.chat);
  }

  Future<void> _installFromUri() async {
    final result = await showDialog<AppPackage>(
      context: context,
      builder: (_) => const _InstallFromUriDialog(),
    );
    if (result != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DefaultTabController(
      length: widget.hideModulesTab ? 3 : 4,
      child: Container(
        color: c.bg,
        child: Column(
          children: [
            // When inside the Hub the outer page already shows a
            // big title — render only the slim toolbar + sub-tabs
            // so we don't double-stack headers.
            if (widget.hideHeader) _buildCompactBar(c) else _buildHeader(c),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  HubDiscoverView(
                    installed: _installed,
                    onCardTap: (hit) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => HubPackageDetailPage(
                            publisher: hit.publisherSlug,
                            packageId: hit.packageId,
                            installed: _isInstalled(hit.packageId),
                            onInstall: (pkg) => HubInstallController
                                .instance
                                .install(
                              context: context,
                              publisher: pkg.publisherSlug,
                              packageId: pkg.packageId,
                              packageName: pkg.name,
                              onSuccess: _load,
                            ),
                          ),
                        ),
                      );
                    },
                    onInstallHit: (hit) =>
                        HubInstallController.instance.install(
                      context: context,
                      publisher: hit.publisherSlug,
                      packageId: hit.packageId,
                      packageName: hit.name,
                      onSuccess: _load,
                    ),
                  ),
                  _LibraryView(
                    packages: _installed,
                    loading: _loading,
                    error: _error,
                    onCardTap: _openDetail,
                    onUninstall: _quickUninstall,
                    onUpgrade: _quickUpgrade,
                    onLaunch: _quickLaunch,
                    onReload: _load,
                  ),
                  _UpdatesView(
                    packages: _installed,
                    onCardTap: _openDetail,
                    onUpgrade: _quickUpgrade,
                    onUpgradeAll: () async {
                      for (final p in _installed.where((p) => p.hasUpdate)) {
                        await _quickUpgrade(p);
                      }
                    },
                  ),
                  if (!widget.hideModulesTab) const ModulesView(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Slim compact bar used when the page is embedded inside the Hub.
  /// Pill-style sub-tabs that look visually distinct from the Hub's
  /// underline-style top tabs — no double-underline, no divider line.
  Widget _buildCompactBar(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 8),
      child: Row(
        children: [
          PillTabBar(
            controller: _tabs,
            tabs: [
              PillTabData(label: 'hub.discover'.tr()),
              PillTabData(
                  label: 'Installed', badge: '${_installed.length}'),
              PillTabData(
                label: 'hub.updates'.tr(),
                badge: _updatesCount > 0 ? '$_updatesCount' : null,
                badgeIsAccent: true,
              ),
              if (!widget.hideModulesTab)
                PillTabData(label: 'hub.tab_modules'.tr()),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: 'common.refresh'.tr(),
            iconSize: 16,
            icon: Icon(Icons.refresh_rounded, color: c.textMuted),
            onPressed: _loading ? null : _load,
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: _installFromUri,
            icon: Icon(Icons.add_link_rounded, size: 13, color: c.text),
            label: Text('Install from URI',
                style: GoogleFonts.inter(fontSize: 11, color: c.text)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.border),
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [c.accentPrimary, c.purple],
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: c.accentPrimary.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(Icons.storefront_rounded,
                      size: 20, color: c.onAccent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Store',
                          style: GoogleFonts.inter(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: c.textBright,
                              letterSpacing: -0.5)),
                      const SizedBox(height: 2),
                      Text(
                        'Discover, install, and manage Digitorn apps.',
                        style: GoogleFonts.inter(
                            fontSize: 13, color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'common.refresh'.tr(),
                  icon: Icon(Icons.refresh_rounded,
                      size: 18, color: c.textMuted),
                  onPressed: _loading ? null : _load,
                ),
                const SizedBox(width: 4),
                OutlinedButton.icon(
                  onPressed: _installFromUri,
                  icon: Icon(Icons.add_link_rounded,
                      size: 14, color: c.text),
                  label: Text('Install from URI',
                      style:
                          GoogleFonts.inter(fontSize: 12, color: c.text)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: c.border),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              indicatorColor: c.accentPrimary,
              indicatorWeight: 2,
              labelColor: c.accentPrimary,
              unselectedLabelColor: c.textMuted,
              labelStyle: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w600),
              unselectedLabelStyle: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w500),
              tabs: [
                const Tab(text: 'Discover'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Installed'),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${_installed.length}',
                            style: GoogleFonts.firaCode(
                                fontSize: 9.5,
                                color: c.textMuted,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Updates'),
                      if (_updatesCount > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: c.accentPrimary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('$_updatesCount',
                              style: GoogleFonts.firaCode(
                                  fontSize: 9.5,
                                  color: c.onAccent,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!widget.hideModulesTab) const Tab(text: 'Modules'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Discover view ───────────────────────────────────────────────

class _DiscoverView extends StatefulWidget {
  final List<AppPackage> available;
  final bool Function(String) isInstalled;
  final bool hubStubbed;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final void Function(AppPackage) onCardTap;
  final Future<void> Function(AppPackage) onInstall;

  const _DiscoverView({
    required this.available,
    required this.isInstalled,
    required this.hubStubbed,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onCardTap,
    required this.onInstall,
  });

  @override
  State<_DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends State<_DiscoverView> {
  String _category = 'all';
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<AppPackage> get _filtered {
    final list = widget.available.where((p) {
      if (_category != 'all' && p.category != _category) return false;
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        return p.name.toLowerCase().contains(q) ||
            p.description.toLowerCase().contains(q) ||
            p.author.toLowerCase().contains(q) ||
            p.manifest.tags.any((t) => t.toLowerCase().contains(q));
      }
      return true;
    }).toList();
    list.sort((a, b) {
      final fa = FeaturedCatalogue.statsFor(a).featured ? 1 : 0;
      final fb = FeaturedCatalogue.statsFor(b).featured ? 1 : 0;
      if (fa != fb) return fb - fa;
      final da = FeaturedCatalogue.statsFor(a).downloads;
      final db = FeaturedCatalogue.statsFor(b).downloads;
      return db - da;
    });
    return list;
  }

  AppPackage? get _featured {
    for (final p in widget.available) {
      if (FeaturedCatalogue.statsFor(p).featured) return p;
    }
    return widget.available.isEmpty ? null : widget.available.first;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.loading) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.textMuted),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        if (widget.hubStubbed) _hubBanner(c),
        if (widget.hubStubbed) const SizedBox(height: 20),
        if (_featured != null && _query.isEmpty && _category == 'all') ...[
          _HeroFeatured(
            pkg: _featured!,
            installed: widget.isInstalled(_featured!.packageId),
            onTap: () => widget.onCardTap(_featured!),
            onInstall: () => widget.onInstall(_featured!),
          ),
          const SizedBox(height: 28),
        ],
        _searchBar(c),
        const SizedBox(height: 14),
        _categoryChips(c),
        const SizedBox(height: 22),
        if (_filtered.isEmpty)
          _emptyState(c)
        else
          _grid(_filtered),
      ],
    );
  }

  Widget _hubBanner(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.accentPrimary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.accentPrimary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined, size: 16, color: c.accentPrimary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Digitorn Hub launching soon',
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: c.accentPrimary,
                    )),
                const SizedBox(height: 2),
                Text(
                  'These are highlights from the upcoming community store. Install from local path or git URL works today.',
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.text, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchBar(AppColors c) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 16, color: c.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v.trim()),
              style: GoogleFonts.inter(fontSize: 13, color: c.textBright),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'hub.filter_apps'.tr(),
                hintStyle: GoogleFonts.inter(
                    fontSize: 13, color: c.textMuted),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() {
                _query = '';
                _searchCtrl.clear();
              }),
              child: Icon(Icons.close_rounded,
                  size: 14, color: c.textMuted),
            ),
        ],
      ),
    );
  }

  Widget _categoryChips(AppColors c) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: FeaturedCatalogue.categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final entry = FeaturedCatalogue.categories[i];
          final selected = _category == entry.$1;
          return GestureDetector(
            onTap: () => setState(() => _category = entry.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? c.accentPrimary.withValues(alpha: 0.12)
                    : c.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected
                      ? c.accentPrimary.withValues(alpha: 0.5)
                      : c.border,
                  width: selected ? 1.4 : 1,
                ),
              ),
              child: Text(
                entry.$2,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: selected ? c.accentPrimary : c.text,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _grid(List<AppPackage> packages) {
    return buildPackageGrid(
      children: [
        for (final p in packages)
          PackageCard(
            pkg: p,
            installed: widget.isInstalled(p.packageId),
            onTap: () => widget.onCardTap(p),
            onInstall: () => widget.onInstall(p),
          ),
      ],
    );
  }

  Widget _emptyState(AppColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.search_off_rounded, size: 36, color: c.textDim),
            const SizedBox(height: 10),
            Text(
              _query.isNotEmpty
                  ? 'No app matches "$_query"'
                  : 'No app in this category yet',
              style: GoogleFonts.inter(fontSize: 13, color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hero Featured ────────────────────────────────────────────────

class _HeroFeatured extends StatelessWidget {
  final AppPackage pkg;
  final bool installed;
  final VoidCallback onTap;
  final VoidCallback onInstall;
  const _HeroFeatured({
    required this.pkg,
    required this.installed,
    required this.onTap,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hash = pkg.name.hashCode;
    final c1 = HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.6, 0.5)
        .toColor();
    final c2 = HSLColor.fromAHSL(
            1, ((hash ~/ 7) % 360).toDouble(), 0.55, 0.35)
        .toColor();
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          constraints: const BoxConstraints(minHeight: 220),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [c1, c2],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: c1.withValues(alpha: 0.4),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          padding: const EdgeInsets.all(28),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 110,
                height: 110,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.onAccent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                      color: c.onAccent.withValues(alpha: 0.4),
                      width: 1.5),
                ),
                child: pkg.icon != null && pkg.icon!.isNotEmpty
                    ? Text(pkg.icon!, style: const TextStyle(fontSize: 56))
                    : Icon(Icons.bolt_rounded,
                        size: 50, color: c.onAccent),
              ),
              const SizedBox(width: 28),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.shadow.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: c.onAccent.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        '★ FEATURED',
                        style: GoogleFonts.firaCode(
                          fontSize: 10,
                          color: c.orange,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      pkg.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: c.onAccent,
                        letterSpacing: -0.5,
                        shadows: [
                          Shadow(
                            color: c.shadow.withValues(alpha: 0.4),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      pkg.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: c.onAccent.withValues(alpha: 0.9),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        if (installed)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: c.onAccent.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: c.onAccent
                                      .withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.check_rounded,
                                    size: 14, color: c.onAccent),
                                const SizedBox(width: 6),
                                Text('Installed',
                                    style: GoogleFonts.inter(
                                        fontSize: 12,
                                        color: c.onAccent,
                                        fontWeight: FontWeight.w700)),
                              ],
                            ),
                          )
                        else
                          ElevatedButton.icon(
                            onPressed: onInstall,
                            icon: const Icon(Icons.download_rounded,
                                size: 16),
                            label: Text(
                              'Install',
                              style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: c.onAccent,
                              foregroundColor: c1,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(8)),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Text(
                          '${pkg.author} · v${pkg.version}',
                          style: GoogleFonts.firaCode(
                            fontSize: 11,
                            color: c.onAccent.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Library view ────────────────────────────────────────────────

class _LibraryView extends StatefulWidget {
  final List<AppPackage> packages;
  final bool loading;
  final String? error;
  final void Function(AppPackage) onCardTap;
  final Future<void> Function(AppPackage) onUninstall;
  final Future<void> Function(AppPackage) onUpgrade;
  final Future<void> Function(AppPackage) onLaunch;
  /// Called after an admin enables / purges an app from the
  /// disabled-apps strip so the main list refreshes.
  final VoidCallback onReload;
  const _LibraryView({
    required this.packages,
    required this.loading,
    required this.error,
    required this.onCardTap,
    required this.onUninstall,
    required this.onUpgrade,
    required this.onLaunch,
    required this.onReload,
  });

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView> {
  /// Source filter keyed by `sourceType`. `"all"` matches every source.
  /// Runtime-state grouping (running / broken / paused) is a parallel
  /// axis — this chip just narrows the pool those sections pull from.
  String _filter = 'all';
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matchesQuery(AppPackage p) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return p.name.toLowerCase().contains(q) ||
        p.packageId.toLowerCase().contains(q) ||
        p.description.toLowerCase().contains(q);
  }

  bool _matchesFilter(AppPackage p) {
    if (_filter == 'all') return true;
    return p.sourceType == _filter;
  }

  /// Bucket apps by their daemon-authoritative `runtime_status`.
  /// Order matches the spec's section priority: Needs attention → Running
  /// → Paused. Disabled rows are admin-only and live in the
  /// dedicated [DisabledAppsSection] at the top of the page, not here.
  ({List<AppPackage> broken, List<AppPackage> running, List<AppPackage> paused})
      _bucketed() {
    final broken = <AppPackage>[];
    final running = <AppPackage>[];
    final paused = <AppPackage>[];
    for (final p in widget.packages) {
      if (!_matchesFilter(p)) continue;
      if (!_matchesQuery(p)) continue;
      if (p.isBroken) {
        broken.add(p);
      } else if (p.isNotDeployed) {
        paused.add(p);
      } else {
        running.add(p);
      }
    }
    int cmp(AppPackage a, AppPackage b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    broken.sort(cmp);
    running.sort(cmp);
    paused.sort(cmp);
    return (broken: broken, running: running, paused: paused);
  }

  int _countBySource(String sourceType) => sourceType == 'all'
      ? widget.packages.length
      : widget.packages.where((p) => p.sourceType == sourceType).length;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (widget.loading) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.textMuted),
        ),
      );
    }
    final buckets = _bucketed();
    final totalVisible =
        buckets.broken.length + buckets.running.length + buckets.paused.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        // Admin-only — disabled apps need re-enabling or purging.
        DisabledAppsSection(onChanged: widget.onReload),
        // Search bar + source-filter chips. The runtime-state
        // sections below (Needs attention / Running / Paused) are a
        // separate axis — the chips here narrow the pool those
        // sections pull from, so users can still scope the list by
        // origin (e.g. "only my local imports") without losing the
        // broken/running/paused grouping.
        Row(
          children: [
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded, size: 14, color: c.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) =>
                            setState(() => _query = v.trim()),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textBright),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'hub.filter_apps'.tr(),
                          hintStyle: GoogleFonts.inter(
                              fontSize: 12, color: c.textMuted),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            _filterChip(c, 'all', 'All', _countBySource('all')),
            _filterChip(c, 'builtin', 'Built-in', _countBySource('builtin')),
            _filterChip(c, 'local', 'Local', _countBySource('local')),
            _filterChip(c, 'hub', 'Hub', _countBySource('hub')),
            _filterChip(c, 'git', 'Git', _countBySource('git')),
          ],
        ),
        const SizedBox(height: 22),

        if (totalVisible == 0)
          Container(
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.apps_rounded, size: 36, color: c.textDim),
                  const SizedBox(height: 12),
                  Text(
                    widget.packages.isEmpty
                        ? 'No apps installed yet'
                        : 'No app matches your search',
                    style:
                        GoogleFonts.inter(fontSize: 13, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),

        // ── Needs attention ────────────────────────────────────────
        // Broken apps first because they're actionable. Each card
        // renders with the deploy error inline and a Reinstall /
        // Delete affordance directly on it.
        if (buckets.broken.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.error_outline_rounded,
            title: 'Needs attention',
            subtitle:
                'These apps installed but the daemon failed to deploy them.',
            count: buckets.broken.length,
            color: c.red,
          ),
          const SizedBox(height: 12),
          for (final p in buckets.broken) ...[
            _BrokenCard(
              pkg: p,
              onOpenDetails: () => widget.onCardTap(p),
              onReinstall:
                  p.sourceUri != null ? () => widget.onUpgrade(p) : null,
              onDelete: () => widget.onUninstall(p),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 18),
        ],

        // ── Running ────────────────────────────────────────────────
        if (buckets.running.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.play_circle_outline_rounded,
            title: 'Running',
            subtitle: 'Deployed and ready to open.',
            count: buckets.running.length,
            color: c.green,
          ),
          const SizedBox(height: 12),
          buildPackageGrid(
            children: [
              for (final p in buckets.running)
                PackageCard(
                  pkg: p,
                  installed: true,
                  onTap: () => widget.onCardTap(p),
                  onInstall: () {},
                  onUpgrade:
                      p.hasUpdate ? () => widget.onUpgrade(p) : null,
                  onUninstall: () => widget.onUninstall(p),
                  onLaunch: () => widget.onLaunch(p),
                  onLifecycleChanged: widget.onReload,
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],

        // ── Paused / Not deployed ─────────────────────────────────
        if (buckets.paused.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.pause_circle_outline_rounded,
            title: 'Paused',
            subtitle: "Installed on disk but not currently deployed.",
            count: buckets.paused.length,
            color: c.orange,
          ),
          const SizedBox(height: 12),
          buildPackageGrid(
            children: [
              for (final p in buckets.paused)
                PackageCard(
                  pkg: p,
                  installed: true,
                  onTap: () => widget.onCardTap(p),
                  onInstall: () {},
                  onUpgrade: null,
                  onUninstall: () => widget.onUninstall(p),
                  onLaunch: () => widget.onLaunch(p),
                  onLifecycleChanged: widget.onReload,
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Source-filter chip. `_filter` holds the selected `sourceType`
  /// (`"all"` for no filter). Each chip carries its own bucket
  /// count so the user sees how many apps come from each source at
  /// a glance, independent of the runtime-state sections below.
  Widget _filterChip(AppColors c, String value, String label, int count) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: GestureDetector(
        onTap: () => setState(() => _filter = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? c.accentPrimary.withValues(alpha: 0.12)
                : c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? c.accentPrimary.withValues(alpha: 0.5)
                  : c.border,
            ),
          ),
          child: Row(
            children: [
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      color: selected ? c.accentPrimary : c.text,
                      fontWeight: selected
                          ? FontWeight.w700
                          : FontWeight.w500)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: selected ? c.accentPrimary : c.surfaceAlt,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('$count',
                    style: GoogleFonts.firaCode(
                      fontSize: 9.5,
                      color: selected ? c.onAccent : c.textMuted,
                      fontWeight: FontWeight.w700,
                    )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact header row shared by the Installed-tab sections (Needs
/// attention / Running / Paused). Renders a coloured icon, title,
/// optional subtitle, and a count pill keyed to the same accent so
/// the grouping is scannable at a glance.
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final int count;
  final Color color;
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(title,
            style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: c.textBright)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text('$count',
              style: GoogleFonts.firaCode(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: color)),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(subtitle!,
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ],
    );
  }
}

/// Full-width card for a broken install. Shows the deploy error
/// inline (so the user knows why it's broken without opening a
/// dialog) plus the two actions the spec lists for this bucket:
/// Reinstall (re-runs `/upgrade` with the stored source) and
/// Delete (wipes the install from disk + DB).
class _BrokenCard extends StatelessWidget {
  final AppPackage pkg;
  final VoidCallback onOpenDetails;
  final VoidCallback? onReinstall;
  final VoidCallback onDelete;
  const _BrokenCard({
    required this.pkg,
    required this.onOpenDetails,
    required this.onReinstall,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final err = pkg.deployError;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.red.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.red.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: c.red),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pkg.name,
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: c.textBright)),
                    const SizedBox(height: 2),
                    Text(
                      '${pkg.packageId} · v${pkg.version}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.textDim),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onOpenDetails,
                child: Text('common.open'.tr(),
                    style: GoogleFonts.inter(fontSize: 12, color: c.red)),
              ),
            ],
          ),
          if (err != null && err.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: Text(
                err,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.text, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 14),
                label: Text('Delete',
                    style: GoogleFonts.inter(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.red,
                  side: BorderSide(
                      color: c.red.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                ),
              ),
              const SizedBox(width: 8),
              if (onReinstall != null)
                ElevatedButton.icon(
                  onPressed: onReinstall,
                  icon: const Icon(Icons.refresh_rounded,
                      size: 14, color: Colors.white),
                  label: Text('Reinstall',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.red,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Updates view ────────────────────────────────────────────────

class _UpdatesView extends StatelessWidget {
  final List<AppPackage> packages;
  final void Function(AppPackage) onCardTap;
  final Future<void> Function(AppPackage) onUpgrade;
  final Future<void> Function() onUpgradeAll;
  const _UpdatesView({
    required this.packages,
    required this.onCardTap,
    required this.onUpgrade,
    required this.onUpgradeAll,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final updates = packages.where((p) => p.hasUpdate).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        if (updates.isEmpty)
          Container(
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.border),
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 36, color: c.green),
                  const SizedBox(height: 12),
                  Text("You're all caught up",
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.textBright)),
                  const SizedBox(height: 4),
                  Text('No package updates available right now.',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: c.textMuted)),
                ],
              ),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.accentPrimary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.accentPrimary.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(Icons.system_update_alt_rounded,
                    size: 22, color: c.accentPrimary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${updates.length} update${updates.length == 1 ? '' : 's'} available',
                          style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: c.accentPrimary)),
                      const SizedBox(height: 2),
                      Text(
                          'New versions of your installed packages are ready.',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.text)),
                    ],
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: onUpgradeAll,
                  icon: Icon(Icons.upgrade_rounded,
                      size: 16, color: c.onAccent),
                  label: Text('Upgrade all',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: c.onAccent)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.accentPrimary,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          buildPackageGrid(
            children: [
              for (final pkg in updates)
                PackageCard(
                  pkg: pkg,
                  installed: true,
                  onTap: () => onCardTap(pkg),
                  onInstall: () {},
                  onUpgrade: () => onUpgrade(pkg),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ─── Install from URI dialog ──────────────────────────────────────

class _InstallFromUriDialog extends StatefulWidget {
  const _InstallFromUriDialog();
  @override
  State<_InstallFromUriDialog> createState() =>
      _InstallFromUriDialogState();
}

class _InstallFromUriDialogState extends State<_InstallFromUriDialog> {
  String _sourceType = 'local';
  final _uriCtrl = TextEditingController();
  final _versionCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _uriCtrl.dispose();
    _versionCtrl.dispose();
    super.dispose();
  }

  Future<void> _doInstall() async {
    setState(() => _busy = true);
    final pkg = await PackageInstallFlow.install(
      context,
      sourceType: _sourceType,
      sourceUri: _uriCtrl.text.trim(),
      version: _versionCtrl.text.trim().isEmpty
          ? null
          : _versionCtrl.text.trim(),
    );
    if (mounted) {
      setState(() => _busy = false);
      if (pkg != null) Navigator.pop(context, pkg);
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
              Text('Install from URI',
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
              const SizedBox(height: 4),
              Text(
                'Point at a local directory, a hub package, or a git repo.',
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
              ),
              const SizedBox(height: 16),
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
                    label: Text('Hub',
                        style: GoogleFonts.inter(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: 'git',
                    label: Text('Git',
                        style: GoogleFonts.inter(fontSize: 11)),
                  ),
                ],
                selected: {_sourceType},
                onSelectionChanged: (s) =>
                    setState(() => _sourceType = s.first),
              ),
              const SizedBox(height: 14),
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
                TextField(
                  controller: _versionCtrl,
                  style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: c.bg,
                    hintText: 'version (optional)',
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
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.pop(context),
                    child: Text('common.cancel'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textMuted)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed:
                        _busy || _uriCtrl.text.trim().isEmpty
                            ? null
                            : _doInstall,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.accentPrimary,
                      foregroundColor: c.onAccent,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
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
                                fontWeight: FontWeight.w700)),
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

/// Action picked by the user in the "Manage" dialog — maps 1:1 to
/// the three lifecycle operations the daemon supports.
enum _LifecycleChoice { disable, deleteKeep, deletePermanent }

/// One row in the lifecycle chooser. Visually differentiates the
/// "nuclear" option (permanent delete) from the reversible /
/// history-preserving ones via the `accent` flag.
class _LifecycleOption extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String description;
  final bool accent;
  final VoidCallback onTap;
  const _LifecycleOption({
    required this.icon,
    required this.color,
    required this.label,
    required this.description,
    required this.onTap,
    this.accent = false,
  });

  @override
  State<_LifecycleOption> createState() => _LifecycleOptionState();
}

class _LifecycleOptionState extends State<_LifecycleOption> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      onEnter: (_) {
        if (!_h && mounted) setState(() => _h = true);
      },
      onExit: (_) {
        if (_h && mounted) setState(() => _h = false);
      },
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _h
                ? widget.color.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _h
                  ? widget.color.withValues(alpha: 0.4)
                  : (widget.accent
                      ? widget.color.withValues(alpha: 0.3)
                      : c.border),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(widget.icon, size: 16, color: widget.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: c.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.description,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: c.textMuted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: c.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
