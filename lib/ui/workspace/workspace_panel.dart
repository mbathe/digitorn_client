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

    // Build the Files tab last (after we know how many siblings it has),
    // so we only pass `onClose` when it's the SOLE tab — otherwise the
    // 52px tab header carries the close button and we'd duplicate it.
    (String, Widget, Widget) buildFilesTab(bool isSole) => (
          'files',
          Tab(
            height: 44,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder_open_outlined,
                    size: 12, color: c.textMuted),
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
          _FilesTab(
            ws: ws,
            searchFocus: _searchInputFocus,
            onClose: isSole ? () => appState.closeWorkspace() : null,
          ),
        );

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

    // Insert Files first, with onClose only when it's the sole tab.
    tabs.insert(0, buildFilesTab(tabs.isEmpty));
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
              // ── Header (only when 2+ tabs) ──────────────────────────
              // When there's a single tab (Files) the 52px tab header
              // would just show one label — wasted real-estate. We
              // hide it and let the inner ``_FilesTab`` toolbar carry
              // the close button instead.
              if (tabDefs.length > 1)
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
                          unselectedLabelStyle:
                              GoogleFonts.inter(fontSize: 11),
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
  /// When set, a small close-workspace button is rendered at the
  /// right edge of the toolbar — used when this tab is the only one
  /// (the outer 52px tab header is hidden in that case).
  final VoidCallback? onClose;
  const _FilesTab({required this.ws, this.searchFocus, this.onClose});

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

    // Empty state used to short-circuit before the toolbar — but the
    // user wants the mode dropdown visible even before any file is
    // written, so we let the unified render below handle it. The
    // EmptyPane is rendered as the main content area when nothing
    // is there.
    final isEmpty = !wsModule.hasFiles && !wsModule.hasMeta;

    final c = context.colors;

    return Column(
      children: [
        // ── Toolbar (30px, NO border) ────────────────────────────────
        // Mode dropdown at the LEFT, then Search + Refresh, spacer,
        // summary, and Close at the right. No border-bottom — keeps
        // the top visually clear.
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: c.bg,
          child: Row(
            children: [
              _WorkspaceModeMenu(
                mode: _showChanges
                    ? _WsMode.changes
                    : (showPreview ? _WsMode.preview : _WsMode.code),
                hasPreview: hasPreview,
                onSelect: (m) => setState(() {
                  switch (m) {
                    case _WsMode.code:
                      _showChanges = false;
                      _showPreview = false;
                      _showSearch = false;
                    case _WsMode.preview:
                      _showChanges = false;
                      _showSearch = false;
                      _showPreview = true;
                    case _WsMode.changes:
                      _showPreview = false;
                      _showSearch = false;
                      _showChanges = true;
                  }
                }),
              ),
              const SizedBox(width: 4),
              _WsToolbarBtn(
                icon: Icons.search_rounded,
                active: _showSearch && !showPreview,
                tooltip: 'Search (Ctrl+Shift+F)',
                onTap: () => setState(() {
                  _showPreview = false;
                  _showSearch = !_showSearch;
                  if (_showSearch) {
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => widget.searchFocus?.requestFocus());
                  }
                }),
              ),
              if (hasPreview && showPreview) ...[
                const SizedBox(width: 4),
                _WsToolbarBtn(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Refresh preview',
                  onTap: () {
                    final session = SessionService().activeSession;
                    if (session != null) {
                      SessionService().rejoinSessionRoom();
                    }
                    setState(() {});
                  },
                ),
              ],
              // globalSummary placed BEFORE the Spacer so the close X
              // stays pinned to the far right. With the previous order
              // (Spacer → summary → close) the X visibly slid left every
              // time the summary widened.
              if (wsModule.hasFiles) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(wsModule.globalSummary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5, color: c.textDim)),
                ),
              ],
              const Spacer(),
              if (widget.onClose != null)
                Tooltip(
                  message: 'Close workspace',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: widget.onClose,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 13, color: c.textMuted),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // ── Search panel (inline, collapsible) ────────────────────────
        if (_showSearch)
          SearchPanel(ws: ws, inputFocus: widget.searchFocus),
        // ── Main content ─────────────────────────────────────────────
        Expanded(
          child: isEmpty
              ? const _EmptyPane(
                  icon: Icons.folder_open_outlined,
                  title: 'No files yet',
                  subtitle:
                      'Send a message — the agent writes files here.',
                )
              : hasPreview
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

// ─── Toolbar icon button ─────────────────────────────────────────────────────

class _WsToolbarBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String? tooltip;
  final VoidCallback onTap;
  const _WsToolbarBtn({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final btn = InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: active ? c.green.withValues(alpha: 0.1) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 13, color: active ? c.green : c.textMuted),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}

// ─── Workspace mode menu (right edge of toolbar) ─────────────────────────────

enum _WsMode { code, preview, changes }

/// "Code ▾" / "Preview ▾" / "Changes ▾" affordance — mirrors the
/// app-name menu in the chat header.
///
/// Uses `MenuAnchor` (Material 3) instead of `PopupMenuButton` to
/// keep the popup attached to the trigger AND aligned with its left
/// edge — the legacy popup floated visually detached and could
/// flip-anchor to the right which pushed it under the chat panel.
class _WorkspaceModeMenu extends StatefulWidget {
  final _WsMode mode;
  final bool hasPreview;
  final ValueChanged<_WsMode> onSelect;
  const _WorkspaceModeMenu({
    required this.mode,
    required this.hasPreview,
    required this.onSelect,
  });

  @override
  State<_WorkspaceModeMenu> createState() => _WorkspaceModeMenuState();
}

class _WorkspaceModeMenuState extends State<_WorkspaceModeMenu> {
  final MenuController _controller = MenuController();
  bool _hover = false;

  String _label(_WsMode m) => switch (m) {
        _WsMode.code => 'Code',
        _WsMode.preview => 'Preview',
        _WsMode.changes => 'Changes',
      };

  IconData _icon(_WsMode m) => switch (m) {
        _WsMode.code => Icons.folder_open_rounded,
        _WsMode.preview => Icons.visibility_rounded,
        _WsMode.changes => Icons.difference_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final modes = <_WsMode>[
      _WsMode.code,
      if (widget.hasPreview) _WsMode.preview,
      _WsMode.changes,
    ];

    return MenuAnchor(
      controller: _controller,
      // Align under the trigger, anchored to its LEFT edge so the
      // menu opens INTO the workspace (rightwards) — never under
      // the chat panel.
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        elevation: const WidgetStatePropertyAll(6),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        )),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
      ),
      menuChildren: [
        for (final m in modes)
          MenuItemButton(
            onPressed: () => widget.onSelect(m),
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              minimumSize: const WidgetStatePropertyAll(Size(140, 30)),
              backgroundColor: WidgetStatePropertyAll(
                m == widget.mode
                    ? c.accentPrimary.withValues(alpha: 0.08)
                    : Colors.transparent,
              ),
              shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              )),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _icon(m),
                  size: 13,
                  color: m == widget.mode ? c.accentPrimary : c.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  _label(m),
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: m == widget.mode
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: m == widget.mode ? c.accentPrimary : c.text,
                  ),
                ),
              ],
            ),
          ),
      ],
      builder: (context, controller, _) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _hover || controller.isOpen
                    ? c.surfaceAlt
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _label(widget.mode),
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: c.textBright,
                      letterSpacing: -0.1,
                    ),
                  ),
                  const SizedBox(width: 3),
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 140),
                    turns: controller.isOpen ? 0.5 : 0,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 14,
                      color: c.textMuted
                          .withValues(alpha: _hover ? 1.0 : 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
