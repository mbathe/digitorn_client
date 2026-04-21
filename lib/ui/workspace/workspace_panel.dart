import 'package:digitorn_client/theme/app_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../services/workspace_service.dart';
import '../../services/session_service.dart';
import '../../services/database_service.dart';
import '../../main.dart';
import 'search/search_panel.dart';
import 'changes/changes_panel.dart';
import '../database/database_panel.dart';
import '../../widgets_v1/dispatcher.dart' as widgets_disp;
import '../../widgets_v1/service.dart' as widgets_service;
import '../../widgets_v1/zones.dart' as widgets_zones;
import 'ide/ide_layout.dart';
import 'ws_preview_router.dart';
import '../../services/workspace_module.dart';

class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const _WorkspacePanelInner();
  }
}

class _WorkspacePanelInner extends StatefulWidget {
  const _WorkspacePanelInner();

  @override
  State<_WorkspacePanelInner> createState() => _WorkspacePanelInnerState();
}

class _WorkspacePanelInnerState extends State<_WorkspacePanelInner>
    with TickerProviderStateMixin {
  TabController? _tabs;
  final FocusNode _searchInputFocus = FocusNode();
  int _lastTabCount = 0;

  @override
  void dispose() {
    _tabs?.dispose();
    _searchInputFocus.dispose();
    super.dispose();
  }

  void _openSearch(WorkspaceService ws) {
    ws.setActiveTab('files');
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchInputFocus.requestFocus(),
    );
  }

  /// Build the ordered list of (key, tabWidget, contentWidget) based
  /// on which modules the active app declares.
  List<(String, Widget, Widget)> _buildTabs(
      WorkspaceService ws, AppState appState, AppColors c) {
    final app = appState.activeApp;
    final modules = app?.modules ?? [];
    final tabs = <(String, Widget, Widget)>[];

    // Files — always present
    tabs.add((
      'files',
      Tab(
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 12, color: c.textMuted),
            const SizedBox(width: 5),
            Text('workspace.files'.tr()),
            if (ws.buffers.isNotEmpty) ...[
              const SizedBox(width: 4),
              _TabBadge('${ws.buffers.length}', color: c.textDim),
            ],
            if (ws.errorCount > 0) ...[
              const SizedBox(width: 4),
              _TabBadge('${ws.errorCount}',
                  color: c.red.withValues(alpha: 0.15), fg: c.red),
            ],
          ],
        ),
      ),
      _FilesTab(ws: ws, searchFocus: _searchInputFocus),
    ));

    // Database — only if app has database module
    if (modules.contains('database')) {
      tabs.add((
        'database',
        Tab(
          height: 44,
          child: Consumer<DatabaseService>(
            builder: (_, db, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.storage_rounded, size: 12,
                    color: db.runningCount > 0
                        ? c.orange
                        : (db.errorCount > 0 ? c.red : c.textMuted)),
                const SizedBox(width: 5),
                Text('workspace.database'.tr()),
                if (db.calls.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _TabBadge('${db.calls.length}',
                      color: db.errorCount > 0
                          ? c.red.withValues(alpha: 0.15)
                          : c.green.withValues(alpha: 0.12),
                      fg: db.errorCount > 0 ? c.red : c.green),
                ],
              ],
            ),
          ),
        ),
        const DatabasePanel(),
      ));
    }

    // Widgets — only if app has workspace tabs
    if (appState.activeAppWidgets.hasWorkspaceTabs) {
      tabs.add((
        'widgets',
        Tab(
          height: 44,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.widgets_outlined, size: 12, color: c.purple),
              const SizedBox(width: 5),
              Text('workspace.widgets'.tr()),
              const SizedBox(width: 4),
              _TabBadge(
                '${appState.activeAppWidgets.workspaceTabs.length}',
                color: c.purple.withValues(alpha: 0.15),
                fg: c.purple,
              ),
            ],
          ),
        ),
        _WidgetsTab(appState: appState),
      ));
    }

    return tabs;
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceService>();
    final appState = context.watch<AppState>();
    final c = context.colors;

    final tabDefs = _buildTabs(ws, appState, c);

    // Rebuild TabController when tab count changes
    if (tabDefs.length != _lastTabCount) {
      _tabs?.dispose();
      _tabs = TabController(length: tabDefs.length, vsync: this);
      _lastTabCount = tabDefs.length;
    }

    // Sync tab index with activeTab from service
    final activeKey = ws.activeTab;
    final idx = tabDefs.indexWhere((t) => t.$1 == activeKey);
    final targetIndex = idx >= 0 ? idx : 0;
    if (_tabs!.index != targetIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) {
          if (_tabs != null && _tabs!.index != targetIndex) {
            _tabs!.animateTo(targetIndex);
          }
        },
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF,
            control: true, shift: true): () => _openSearch(ws),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          ws.setActiveTab('files');
        },
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: c.bg,
          child: Column(
            children: [
              // ── Header ──────────────────────────────────────────────
              // Height matches the chat header (52 px) so the two
              // columns line up on the same horizontal baseline when
              // the workspace is docked next to the chat.
              Container(
                height: 52,
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(bottom: BorderSide(color: c.border)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        controller: _tabs,
                        onTap: (i) => ws.setActiveTab(tabDefs[i].$1),
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        labelStyle: GoogleFonts.inter(
                            fontSize: 11, fontWeight: FontWeight.w500),
                        unselectedLabelStyle: GoogleFonts.inter(fontSize: 11),
                        labelColor: c.text,
                        unselectedLabelColor: c.textMuted,
                        indicatorColor: c.textMuted,
                        indicatorWeight: 1,
                        indicatorSize: TabBarIndicatorSize.tab,
                        dividerColor: Colors.transparent,
                        padding: EdgeInsets.zero,
                        tabs: tabDefs.map((t) => t.$2).toList(),
                      ),
                    ),
                    // Close button
                    Tooltip(
                      message: 'Close workspace',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => appState.closeWorkspace(),
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close_rounded,
                              size: 14, color: c.textMuted),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Content ─────────────────────────────────────────────
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  physics: const NeverScrollableScrollPhysics(),
                  children: tabDefs.map((t) => t.$3).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _TabBar removed — tabs are now inline in _PanelHeader
// _GitBadge removed — unused, superseded by header-inline rendering.

class _TabBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color? fg;
  const _TabBadge(this.label, {required this.color, this.fg});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: GoogleFonts.firaCode(fontSize: 9, color: fg ?? context.colors.textMuted)),
      );
}

// ─── Files Tab ────────────────────────────────────────────────────────────────

class _FilesTab extends StatefulWidget {
  final WorkspaceService ws;
  final FocusNode? searchFocus;
  const _FilesTab({required this.ws, this.searchFocus});

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  bool _showSearch = false;
  bool _showChanges = false;
  bool _showPreview = false;
  bool _previewAutoShown = false;

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    final wsModule = context.watch<WorkspaceModule>();
    final hasPreview = wsModule.hasMeta && wsModule.meta.renderMode != 'code';

    // Auto-show preview ONCE when it first becomes available.
    if (hasPreview && !_previewAutoShown && wsModule.hasFiles) {
      _previewAutoShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showPreview = true);
      });
    }
    final showPreview = _showPreview && hasPreview;

    if (!wsModule.hasFiles && !wsModule.hasMeta) {
      return const _EmptyPane(
        icon: Icons.folder_open_outlined,
        title: 'No files yet',
        subtitle: 'Send a message — the agent writes files here.',
      );
    }

    final c = context.colors;

    return Column(
      children: [
        // ── Toolbar ──────────────────────────────────────────────────
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              _ToolbarButton(
                icon: Icons.folder_open_rounded,
                active: !showPreview && !_showChanges && !_showSearch,
                onTap: () => setState(() {
                  _showPreview = false;
                  _showChanges = false;
                  _showSearch = false;
                }),
              ),
              const SizedBox(width: 4),
              _ToolbarButton(
                icon: Icons.search_rounded,
                active: _showSearch && !showPreview,
                onTap: () => setState(() {
                  _showPreview = false;
                  _showSearch = !_showSearch;
                  if (_showSearch) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => widget.searchFocus?.requestFocus());
                  }
                }),
              ),
              const SizedBox(width: 4),
              _ToolbarButton(
                icon: Icons.difference_rounded,
                active: _showChanges && !showPreview,
                badge: wsModule.pendingCount,
                badgeColor: c.green,
                onTap: () => setState(() {
                  _showPreview = false;
                  _showChanges = !_showChanges;
                }),
              ),
              if (hasPreview) ...[
                const SizedBox(width: 4),
                _ToolbarButton(
                  icon: Icons.visibility_rounded,
                  active: showPreview,
                  onTap: () => setState(() => _showPreview = !showPreview),
                ),
                if (showPreview) ...[
                  const SizedBox(width: 4),
                  _ToolbarButton(
                    icon: Icons.refresh_rounded,
                    onTap: () {
                      final session = SessionService().activeSession;
                      if (session != null) {
                        SessionService().rejoinSessionRoom();
                      }
                      setState(() {});
                    },
                  ),
                ],
              ],
              const Spacer(),
              if (wsModule.hasFiles)
                Flexible(
                  child: Text(wsModule.globalSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5, color: c.textDim)),
                ),
            ],
          ),
        ),
        // ── Search panel (inline, collapsible) ────────────────────────
        if (_showSearch)
          SearchPanel(ws: ws, inputFocus: widget.searchFocus),
        // ── Main content ─────────────────────────────────────────────
        Expanded(
          child: hasPreview
              ? IndexedStack(
                  index: showPreview ? 0 : 1,
                  children: [
                    const WsPreviewRouter(),
                    _buildFilesContent(ws),
                  ],
                )
              : _buildFilesContent(ws),
        ),
      ],
    );
  }

  Widget _buildFilesContent(WorkspaceService ws) {
    if (_showChanges) return ChangesPanel(ws: ws);
    // Preview-driven IDE layout is the only path now — explorer +
    // editor (Monaco) + preview + problems panel, all listening to
    // [WorkspaceModule]. Legacy Row / tabs / tree have been removed.
    return const IdeLayout();
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final int badge;
  final Color? badgeColor;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    this.active = false,
    this.badge = 0,
    this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: active ? c.green.withValues(alpha: 0.1) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: active ? c.green : c.textMuted),
            if (badge > 0) ...[
              const SizedBox(width: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                decoration: BoxDecoration(
                  color: (badgeColor ?? c.textMuted).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text('$badge',
                    style: GoogleFonts.firaCode(
                        fontSize: 8.5,
                        color: badgeColor ?? c.textMuted,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Shared widgets ───────────────────────────────────────────────────────────

class _EmptyPane extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyPane(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: context.colors.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.colors.border),
              ),
              child: Icon(icon, color: context.colors.borderHover, size: 22),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: GoogleFonts.inter(
                    fontSize: 13,
                    color: context.colors.textMuted,
                    fontWeight: FontWeight.w500)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: context.colors.textDim,
                      height: 1.5)),
            ],
          ],
        ),
      );
}

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon,
      required this.tooltip,
      required this.onTap});

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _h = true),
          onExit: (_) => setState(() => _h = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _h
                    ? context.colors.surfaceAlt
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(widget.icon,
                  size: 14,
                  color: _h
                      ? context.colors.text
                      : context.colors.textMuted),
            ),
          ),
        ),
      );
}

/// Preview tab inside the workspace panel. When the active app has a
/// preview dev-server, render the live iframe + toolbar. Otherwise
/// show an empty-state explaining how to enable preview.

/// Z3 — "Widgets" tab: mounts the app's declared workspace_tabs via
/// the widgets_v1 runtime. Shows a guidance message when the active
/// app has no widgets declared.
class _WidgetsTab extends StatelessWidget {
  final AppState appState;
  const _WidgetsTab({required this.appState});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final app = appState.activeApp;
    if (app == null) {
      return _empty(
        c,
        Icons.apps_outlined,
        'No app selected',
        'Open an app from the sidebar to see its widgets here.',
      );
    }
    final tabs = appState.activeAppWidgets.workspaceTabs;
    if (tabs.isEmpty) {
      return _empty(
        c,
        Icons.widgets_outlined,
        'No widgets declared',
        'This app has no `widgets.workspace_tabs:` block in its app.yaml.',
      );
    }
    return widgets_zones.WorkspaceWidgetsTabZ3(
      key: ValueKey('z3-${app.appId}'),
      appId: app.appId,
      tabs: tabs,
      hooks: _hooks(context),
    );
  }

  widgets_disp.ActionHooks _hooks(BuildContext ctx) {
    // Minimal hooks for the workspace tab — uses the same chat/tool
    // routing as main.dart. Modal/workspace openers intentionally
    // omitted here because the workspace tab already IS the target.
    return widgets_disp.ActionHooks(
      chatSender: (msg,
          {bool silent = false, Map<String, dynamic>? context}) async {
        if (silent) return;
        appState.injectChatMessage(msg);
      },
      toolRunner: (tool, args) async {
        final resp = await widgets_service.WidgetsService().postAction(
          appState.activeApp?.appId ?? '',
          payload: {
            'type': 'tool',
            'payload': {'tool': tool, 'args': args},
          },
        );
        if (resp == null) return null;
        return resp['result'] ?? resp['data'] ?? resp;
      },
    );
  }

  Widget _empty(AppColors c, IconData icon, String title, String detail) =>
      Container(
        color: c.bg,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: c.textMuted),
              const SizedBox(height: 14),
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: c.textBright,
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 280,
                child: Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.textMuted,
                    height: 1.55,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
