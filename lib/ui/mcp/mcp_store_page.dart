/// MCP Servers store — same UX language as the packages store but
/// scoped to Model Context Protocol servers. Three tabs:
///
///   1. Discover  — browse the catalogue (real or hardcoded fallback)
///   2. Installed — list of installed servers with start/stop/uninstall
///   3. Running   — currently-running servers with tool counts
///
/// All MCP routes are gracefully wrapped — when the daemon hasn't
/// shipped them, the page falls back to the hardcoded catalogue
/// and disables the install action with a soft "MCP API not yet
/// implemented" banner.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/mcp_server.dart';
import '../../services/auth_service.dart';
import '../../services/mcp_service.dart';
import '../../theme/app_theme.dart';
import '../common/pill_tab_bar.dart';
import 'mcp_card.dart';
import 'mcp_catalogue.dart';
import 'mcp_install_dialog.dart';
import 'mcp_oauth_dialog.dart';

/// Shared responsive grid — copy of `buildPackageGrid` so the MCP
/// store stays visually identical to the package store. Tighter
/// breakpoints + slimmer aspect ratio → smaller, denser cards.
Widget buildMcpGrid({required List<Widget> children}) {
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

class McpStorePage extends StatefulWidget {
  final bool embedded;

  /// When true, the page hides its own title/subtitle/tabs header
  /// because its parent (the Hub) is already showing one. Only
  /// the slim sub-tab bar + tab content gets rendered.
  final bool hideHeader;

  const McpStorePage({
    super.key,
    this.embedded = false,
    this.hideHeader = false,
  });

  @override
  State<McpStorePage> createState() => _McpStorePageState();
}

class _McpStorePageState extends State<McpStorePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _svc = McpService();

  bool _loading = true;
  List<McpCatalogueEntry> _catalogue = const [];
  List<McpServer> _installed = const [];
  bool _stubbed = false;

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
    setState(() => _loading = true);
    final results = await Future.wait([
      _svc.listCatalog(),
      _svc.listServers(),
    ]);
    if (!mounted) return;
    final daemonCat = results[0] as List<McpCatalogueEntry>;
    setState(() {
      _stubbed = _svc.stubbed || daemonCat.isEmpty;
      _catalogue = daemonCat.isNotEmpty ? daemonCat : McpCatalogue.all();
      _installed = results[1] as List<McpServer>;
      _loading = false;
    });
  }

  bool _isInstalled(String name) =>
      _installed.any((s) => s.name == name || s.id == name);

  int get _runningCount => _installed.where((s) => s.isRunning).length;

  void _openDetail(McpCatalogueEntry? entry, McpServer? server) {
    showDialog(
      context: context,
      builder: (_) =>
          _McpDetailDialog(entry: entry, server: server),
    );
  }

  Future<void> _install(McpCatalogueEntry entry) async {
    // Detail-before-install: fetch the full catalog entry so the
    // install form sees README, OAuth provider, env mapping, and
    // per-key descriptions — not just the sparse listing row.
    McpCatalogueEntry detail = entry;
    try {
      final fetched = await _svc.getCatalogEntry(entry.name);
      if (fetched != null) detail = fetched;
    } on McpException {
      // Daemon detail route missing — carry on with the listing row.
    }
    if (!mounted) return;

    // OAuth path — skip the env form entirely; the daemon handles
    // the exchange and drops the resulting token into the vault.
    if (detail.usesOAuth) {
      await _startOAuth(detail);
      return;
    }

    final installed = await McpInstallDialog.show(context, entry: detail);
    if (installed != null) _load();
  }

  Future<void> _startOAuth(McpCatalogueEntry entry) async {
    // Delegate the full 8-step client-orchestrated flow to the
    // dedicated dialog. It handles browser launch, polling, success
    // and retry states inline — all we do here is refresh on
    // success so the new server shows up in the Installed tab.
    final ok = await showMcpOauthDialog(context, entry: entry);
    if (ok) {
      _toast('${entry.label} connected');
      _load();
    }
  }

  Future<void> _start(McpServer server) async {
    try {
      await _svc.start(server.id);
      _load();
    } on McpException catch (e) {
      _toast(e.message, err: true);
    }
  }

  Future<void> _stop(McpServer server) async {
    try {
      await _svc.stop(server.id);
      _load();
    } on McpException catch (e) {
      _toast(e.message, err: true);
    }
  }

  Future<void> _test(McpServer server) async {
    try {
      _toast('Probing ${server.name}…');
      final tools = await _svc.testServer(server.id);
      if (!mounted) return;
      _toast(tools.isEmpty
          ? '${server.name}: 0 tools exposed'
          : '${server.name}: ${tools.length} tool${tools.length == 1 ? '' : 's'} exposed');
      _load();
    } on McpException catch (e) {
      _toast(e.message, err: true);
    }
  }

  Future<void> _uninstall(McpServer server) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('Uninstall ${server.name}?',
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: Text(
            'Stops the server and removes its config from the daemon.',
            style: GoogleFonts.inter(
                fontSize: 12, color: c.text, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('common.cancel'.tr(),
                style:
                    GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: c.red,
                foregroundColor: c.onAccent,
                elevation: 0),
            child: Text('hub.uninstall'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _svc.uninstall(server.id);
      _load();
    } on McpException catch (e) {
      _toast(e.message, err: true);
    }
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
    // MCP install / uninstall / configure / test / pool-connect are
    // all admin-only server-side (403 otherwise). Hide the action
    // buttons entirely for non-admin users so they don't get the
    // impression something's broken; they can still browse and
    // connect their credentials to already-installed servers.
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          if (!isAdmin) _buildAdminNotice(c),
          if (widget.hideHeader) _buildCompactBar(c) else _buildHeader(c),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _DiscoverTab(
                  catalogue: _catalogue,
                  loading: _loading,
                  stubbed: _stubbed,
                  isInstalled: _isInstalled,
                  isAdmin: isAdmin,
                  onInstall: _install,
                  onCardTap: (e) => _openDetail(e, null),
                ),
                _InstalledTab(
                  servers: _installed,
                  loading: _loading,
                  isAdmin: isAdmin,
                  onCardTap: (s) => _openDetail(null, s),
                  onStart: _start,
                  onStop: _stop,
                  onTest: _test,
                  onUninstall: _uninstall,
                ),
                _RunningTab(
                  servers: _installed.where((s) => s.isRunning).toList(),
                  onCardTap: (s) => _openDetail(null, s),
                  onStop: _stop,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdminNotice(AppColors c) {
    return Container(
      color: c.orange.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 14, color: c.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Only your admin can install, remove or configure MCP servers. '
              'You can still browse the catalogue and connect your own '
              'credentials to servers already installed.',
              style: GoogleFonts.inter(
                  fontSize: 11, color: c.text, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  /// Slim compact bar used when this page is embedded inside the
  /// Hub. Pill-style sub-tabs visually distinct from the Hub's
  /// underline-style top tabs.
  Widget _buildCompactBar(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 14, 28, 8),
      child: Row(
        children: [
          PillTabBar(
            controller: _tabs,
            tabs: [
              const PillTabData(label: 'Discover'),
              PillTabData(
                  label: 'Installed', badge: '${_installed.length}'),
              PillTabData(
                label: 'Running',
                badge: _runningCount > 0 ? '$_runningCount' : null,
                badgeIsAccent: true,
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: 'common.refresh'.tr(),
            iconSize: 16,
            icon: Icon(Icons.refresh_rounded, color: c.textMuted),
            onPressed: _loading ? null : _load,
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
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        colors: [c.purple, c.accentPrimary]),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: c.purple.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                      Icons.electrical_services_rounded,
                      size: 20,
                      color: c.onAccent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('MCP Servers',
                          style: GoogleFonts.inter(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: c.textBright,
                              letterSpacing: -0.5)),
                      const SizedBox(height: 2),
                      Text(
                        'Plug Model Context Protocol servers into your agents.',
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
              ],
            ),
            const SizedBox(height: 18),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              indicatorColor: c.purple,
              indicatorWeight: 2,
              labelColor: c.purple,
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
                      const Text('Running'),
                      if (_runningCount > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: c.green,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('$_runningCount',
                              style: GoogleFonts.firaCode(
                                  fontSize: 9.5,
                                  color: c.onAccent,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Discover tab ────────────────────────────────────────────────

class _DiscoverTab extends StatefulWidget {
  final List<McpCatalogueEntry> catalogue;
  final bool loading;
  final bool stubbed;
  final bool isAdmin;
  final bool Function(String) isInstalled;
  final Future<void> Function(McpCatalogueEntry) onInstall;
  final void Function(McpCatalogueEntry) onCardTap;

  const _DiscoverTab({
    required this.catalogue,
    required this.loading,
    required this.stubbed,
    required this.isAdmin,
    required this.isInstalled,
    required this.onInstall,
    required this.onCardTap,
  });

  @override
  State<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<_DiscoverTab> {
  String _category = 'all';
  String _query = '';
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  /// Server-side search results from `/api/mcp/search`. When empty
  /// and [_query] is not, fall back to local filter on the full
  /// catalogue so the UI keeps showing something even if the
  /// search endpoint isn't deployed yet.
  List<McpCatalogueEntry>? _serverResults;
  bool _searching = false;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Debounce server-side search so keypresses don't hammer the
  /// daemon. 350ms is short enough to feel live, long enough to
  /// skip most intermediate strokes.
  void _onQueryChanged(String v) {
    setState(() => _query = v.trim());
    _searchDebounce?.cancel();
    if (_query.length < 2) {
      setState(() {
        _serverResults = null;
        _searching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    if (!mounted) return;
    setState(() => _searching = true);
    final results = await McpService().searchCatalog(_query);
    if (!mounted) return;
    setState(() {
      _serverResults = results;
      _searching = false;
    });
  }

  List<McpCatalogueEntry> get _filtered {
    // When the server returned something for the current query,
    // trust it — the daemon also knows about the registry distant
    // we don't carry locally.
    final base = (_serverResults != null && _query.isNotEmpty)
        ? _serverResults!
        : widget.catalogue;
    final list = base.where((e) {
      if (_category != 'all' && e.category != _category) return false;
      // Local filter stays active as a fallback when the server
      // didn't match our category filter for us.
      if (_serverResults == null && _query.isNotEmpty) {
        final q = _query.toLowerCase();
        return e.label.toLowerCase().contains(q) ||
            e.name.toLowerCase().contains(q) ||
            e.description.toLowerCase().contains(q) ||
            e.tags.any((t) => t.toLowerCase().contains(q));
      }
      return true;
    }).toList();
    list.sort((a, b) {
      if (a.featured != b.featured) return b.featured ? 1 : -1;
      return b.popularity - a.popularity;
    });
    return list;
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
        if (widget.stubbed) ...[
          _stubbedBanner(c),
          const SizedBox(height: 18),
        ],
        _searchBar(c),
        const SizedBox(height: 14),
        _categoryChips(c),
        const SizedBox(height: 22),
        if (_filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.search_off_rounded, size: 36, color: c.textDim),
                  const SizedBox(height: 10),
                  Text(
                    _query.isNotEmpty
                        ? 'No MCP server matches "$_query"'
                        : 'No server in this category yet',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: c.textMuted),
                  ),
                ],
              ),
            ),
          )
        else
          buildMcpGrid(
            children: [
              for (final e in _filtered)
                McpCard(
                  entry: e,
                  installed: widget.isInstalled(e.name),
                  onTap: () => widget.onCardTap(e),
                  // Install is admin-only; non-admin users just get
                  // a tap-to-view card with no install affordance.
                  onInstall: widget.isAdmin
                      ? () => widget.onInstall(e)
                      : null,
                ),
            ],
          ),
      ],
    );
  }

  Widget _stubbedBanner(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.purple.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.purple.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined, size: 16, color: c.purple),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('MCP catalogue served locally',
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: c.purple,
                    )),
                const SizedBox(height: 2),
                Text(
                  'Your daemon hasn\'t exposed /api/mcp/catalogue yet — these are highlights from the modelcontextprotocol reference repo. Install actions wire up the moment the daemon ships the routes.',
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
              onChanged: _onQueryChanged,
              style: GoogleFonts.inter(fontSize: 13, color: c.textBright),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'hub.filter_mcp'.tr(),
                hintStyle:
                    GoogleFonts.inter(fontSize: 13, color: c.textMuted),
              ),
            ),
          ),
          if (_searching) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.2, color: c.textMuted),
            ),
            const SizedBox(width: 8),
          ],
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchDebounce?.cancel();
                setState(() {
                  _query = '';
                  _searchCtrl.clear();
                  _serverResults = null;
                });
              },
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
        itemCount: McpCatalogue.categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final entry = McpCatalogue.categories[i];
          final selected = _category == entry.$1;
          return GestureDetector(
            onTap: () => setState(() => _category = entry.$1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? c.purple.withValues(alpha: 0.12)
                    : c.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected
                      ? c.purple.withValues(alpha: 0.5)
                      : c.border,
                  width: selected ? 1.4 : 1,
                ),
              ),
              child: Text(
                entry.$2,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: selected ? c.purple : c.text,
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
}

// ─── Installed tab ───────────────────────────────────────────────

class _InstalledTab extends StatelessWidget {
  final List<McpServer> servers;
  final bool loading;
  final bool isAdmin;
  final void Function(McpServer) onCardTap;
  final Future<void> Function(McpServer) onStart;
  final Future<void> Function(McpServer) onStop;
  final Future<void> Function(McpServer) onTest;
  final Future<void> Function(McpServer) onUninstall;
  const _InstalledTab({
    required this.servers,
    required this.loading,
    required this.isAdmin,
    required this.onCardTap,
    required this.onStart,
    required this.onStop,
    required this.onTest,
    required this.onUninstall,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (loading) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: c.textMuted),
        ),
      );
    }
    if (servers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.electrical_services_rounded,
                  size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text('No MCP server installed yet',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(
                'Pick one in the Discover tab to plug it into your agents.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        buildMcpGrid(
          children: [
            for (final s in servers)
              McpCard(
                server: s,
                onTap: () => onCardTap(s),
                // start/stop/test/uninstall are all admin-only on
                // the server. Hide the buttons entirely so non-admins
                // only see a read-only card.
                onStart: isAdmin && !s.isRunning
                    ? () => onStart(s)
                    : null,
                onStop: isAdmin && s.isRunning ? () => onStop(s) : null,
                onTest: isAdmin && s.isRunning ? () => onTest(s) : null,
                onUninstall: isAdmin ? () => onUninstall(s) : null,
              ),
          ],
        ),
      ],
    );
  }
}

// ─── Running tab ─────────────────────────────────────────────────

class _RunningTab extends StatelessWidget {
  final List<McpServer> servers;
  final void Function(McpServer) onCardTap;
  final Future<void> Function(McpServer) onStop;
  const _RunningTab({
    required this.servers,
    required this.onCardTap,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (servers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.power_off_rounded, size: 36, color: c.textMuted),
              const SizedBox(height: 12),
              Text('No MCP server running',
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.textBright)),
              const SizedBox(height: 6),
              Text(
                'Open the Installed tab and click Start on any of your servers.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.green.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.green.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Icon(Icons.power_rounded, size: 18, color: c.green),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    '${servers.length} MCP server${servers.length == 1 ? '' : 's'} currently running',
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.green)),
              ),
              Text(
                  '${servers.fold<int>(0, (n, s) => n + s.toolsCount)} tools exposed',
                  style: GoogleFonts.firaCode(
                      fontSize: 11, color: c.text)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        buildMcpGrid(
          children: [
            for (final s in servers)
              McpCard(
                server: s,
                onTap: () => onCardTap(s),
                onStop: () => onStop(s),
              ),
          ],
        ),
      ],
    );
  }
}

// ─── Detail dialog ───────────────────────────────────────────────

class _McpDetailDialog extends StatelessWidget {
  final McpCatalogueEntry? entry;
  final McpServer? server;
  const _McpDetailDialog({this.entry, this.server});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = entry?.label ?? server?.name ?? '';
    final description = entry?.description ?? server?.description ?? '';
    final author = entry?.author ?? server?.author ?? 'unknown';
    final transport = entry?.transport ?? server?.transport ?? 'stdio';
    final command = entry?.defaultCommand ?? server?.command ?? '';
    final args = entry?.defaultArgs ?? server?.args ?? const [];
    final repo = entry?.repoUrl;
    final reqEnv = entry?.requiredEnv ?? const [];
    final maskedEnv = server?.env ?? const {};
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.purple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                          color: c.purple.withValues(alpha: 0.35)),
                    ),
                    child: Text(entry?.icon ?? server?.icon ?? '🔌',
                        style: const TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: c.textBright)),
                        const SizedBox(height: 2),
                        Text('$transport · $author',
                            style: GoogleFonts.firaCode(
                                fontSize: 10.5, color: c.textMuted)),
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
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (description.isNotEmpty)
                        Text(description,
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: c.text,
                                height: 1.5)),
                      const SizedBox(height: 14),
                      _section(c, 'COMMAND'),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: c.bg,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: c.border),
                        ),
                        child: SelectableText(
                          '$command ${args.join(" ")}',
                          style: GoogleFonts.firaCode(
                              fontSize: 11,
                              color: c.textBright,
                              height: 1.5),
                        ),
                      ),
                      if (reqEnv.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _section(c, 'REQUIRED ENVIRONMENT'),
                        const SizedBox(height: 6),
                        for (final v in reqEnv)
                          _envRow(c, v.name, v.label,
                              isSecret: v.isSecret),
                      ],
                      if (maskedEnv.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _section(c, 'CONFIGURED VALUES'),
                        const SizedBox(height: 6),
                        for (final entry in maskedEnv.entries)
                          _envRow(c, entry.key, entry.value),
                      ],
                      if (repo != null) ...[
                        const SizedBox(height: 14),
                        _section(c, 'SOURCE'),
                        const SizedBox(height: 6),
                        SelectableText(repo,
                            style: GoogleFonts.firaCode(
                                fontSize: 11, color: c.accentPrimary)),
                      ],
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

  Widget _section(AppColors c, String label) => Text(
        label,
        style: GoogleFonts.firaCode(
          fontSize: 10,
          color: c.textMuted,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      );

  Widget _envRow(AppColors c, String k, String v, {bool isSecret = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSecret)
            Icon(Icons.lock_outline_rounded, size: 12, color: c.orange)
          else
            Icon(Icons.key_outlined, size: 12, color: c.textMuted),
          const SizedBox(width: 8),
          SizedBox(
            width: 200,
            child: Text(k,
                style:
                    GoogleFonts.firaCode(fontSize: 11, color: c.text)),
          ),
          Expanded(
            child: SelectableText(v,
                style: GoogleFonts.firaCode(
                    fontSize: 11, color: c.textMuted)),
          ),
        ],
      ),
    );
  }
}
