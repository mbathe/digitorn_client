import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../design/tokens.dart';
import '../../main.dart' show AppState;
import '../../models/app_manifest.dart';
import '../../services/auth_service.dart';
import '../../services/session_actions_service.dart';
import '../../services/session_prefs_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../chat/chat_bubbles.dart' show showToast;
import '../chat/chat_export_bridge.dart';
import '../chat/workspace_snapshot_actions.dart';
import '../common/remote_icon.dart';
import '../common/themed_dialogs.dart';
import '../credentials/credentials_form.dart';
import '../workspace/workspace_picker.dart';

/// Premium session drawer — the "heart" of the history UX.
///
/// Two display modes driven by the manifest:
///
///   * **Tree** (when `manifest.workspaceMode == required` OR when
///     any session under this app is bound to a workspace path) —
///     sessions grouped by project folder, Claude-Code-style.
///     Top-level "+ Add project" opens the workspace picker and
///     creates a session bound to it. Per-project "+ New chat"
///     reuses the project path without prompting.
///
///   * **Flat** (workspaceMode == none / optional with no bindings)
///     — time-bucketed list (Pinned · Today · Yesterday · Last 7 ·
///     Last 30 · Older · Archived) with the same rich tiles.
///
/// Every tile carries: preview, meta row, active coral bar, pin
/// star, per-item `⋮` menu (Rename · Pin · Fork · Save snapshot ·
/// Import · Archive · Delete). Pin / archive / rename persist
/// locally via [SessionPrefsService]; fork / save / import hit
/// the daemon through [WorkspaceSnapshotActions].
class SessionDrawer extends StatefulWidget {
  final String appId;
  final VoidCallback onClose;

  const SessionDrawer({
    super.key,
    required this.appId,
    required this.onClose,
  });

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<SessionDrawer>
    with TickerProviderStateMixin {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _keyFocus = FocusNode(debugLabel: 'session_drawer_keys');
  Timer? _debounce;
  String _query = '';
  bool _showArchived = false;

  late final AnimationController _entry;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: DsDuration.slow,
    )..forward();
    _searchCtrl.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SessionService().loadSessions(widget.appId);
      if (mounted) _keyFocus.requestFocus();
    });
  }

  void _onSearchChanged() {
    final q = _searchCtrl.text.trim();
    setState(() => _query = q);
    _debounce?.cancel();
    if (q.isEmpty) {
      SessionService().clearSearch();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () {
      SessionService().searchSessions(widget.appId, q);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _keyFocus.dispose();
    _entry.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.slash && !_searchFocus.hasFocus) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_searchFocus.hasFocus) {
        _searchFocus.unfocus();
        _searchCtrl.clear();
        return KeyEventResult.handled;
      }
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _newChat({String? workspacePath}) async {
    final state = Provider.of<AppState>(context, listen: false);
    final mode = state.manifest.workspaceMode;
    var path = workspacePath;
    if (path == null && mode == WorkspaceMode.required) {
      path = await pickWorkspace(context);
      if (path == null || path.isEmpty) return;
    }
    final ok = await SessionService().createAndSetSession(
      widget.appId,
      workspacePath: path,
    );
    if (ok && mounted) widget.onClose();
  }

  Future<void> _addProject() async {
    final path = await pickWorkspace(context);
    if (path == null || path.isEmpty) return;
    final ok = await SessionService().createAndSetSession(
      widget.appId,
      workspacePath: path,
    );
    if (ok && mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final screenW = MediaQuery.of(context).size.width;
    final isMobile = screenW < DsBreakpoint.md;
    final width = isMobile ? screenW - 48 : 320.0;

    return Focus(
      focusNode: _keyFocus,
      onKeyEvent: _handleKey,
      child: GestureDetector(
        onHorizontalDragUpdate: isMobile
            ? (d) {
                if (d.delta.dx < -8) widget.onClose();
              }
            : null,
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _entry, curve: Curves.easeOut),
          child: Container(
            width: width,
            decoration: BoxDecoration(
              color: c.bg,
              border: Border(right: BorderSide(color: c.border)),
            ),
            child: Column(
              children: [
                _DrawerHeader(
                  appId: widget.appId,
                  searchCtrl: _searchCtrl,
                  searchFocus: _searchFocus,
                  onClose: widget.onClose,
                  onNewChat: () => _newChat(),
                  onAddProject: _addProject,
                  showArchived: _showArchived,
                  onToggleArchived: () =>
                      setState(() => _showArchived = !_showArchived),
                ),
                Expanded(
                  child: _DrawerBody(
                    appId: widget.appId,
                    searchQuery: _query,
                    showArchived: _showArchived,
                    onPickedSession: widget.onClose,
                    onNewChatInProject: (path) => _newChat(workspacePath: path),
                  ),
                ),
                const _UserFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HEADER
// ═══════════════════════════════════════════════════════════════════════════

class _DrawerHeader extends StatelessWidget {
  final String appId;
  final TextEditingController searchCtrl;
  final FocusNode searchFocus;
  final VoidCallback onClose;
  final VoidCallback onNewChat;
  final VoidCallback onAddProject;
  final bool showArchived;
  final VoidCallback onToggleArchived;

  const _DrawerHeader({
    required this.appId,
    required this.searchCtrl,
    required this.searchFocus,
    required this.onClose,
    required this.onNewChat,
    required this.onAddProject,
    required this.showArchived,
    required this.onToggleArchived,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<AppState>();
    final manifest = state.manifest;
    final showProject = manifest.workspaceMode == WorkspaceMode.required;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          DsSpacing.x4, DsSpacing.x4, DsSpacing.x3, DsSpacing.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              RemoteIcon(
                id: appId,
                kind: RemoteIconKind.app,
                size: 26,
                borderRadius: DsRadius.xs,
                emojiFallback: manifest.icon.isNotEmpty ? manifest.icon : null,
                nameFallback:
                    manifest.name.isNotEmpty ? manifest.name : appId,
              ),
              const SizedBox(width: DsSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      manifest.name.isNotEmpty ? manifest.name : 'Chat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.textBright,
                        letterSpacing: -0.1,
                      ),
                    ),
                    Text(
                      'History',
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              _TinyBtn(
                icon: Icons.key_rounded,
                tooltip: 'chat.credentials'.tr(),
                onTap: () {
                  final app = state.activeApp;
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CredentialsFormPage(
                      appId: appId,
                      appName: app?.name ?? manifest.name,
                    ),
                  ));
                },
              ),
              const SizedBox(width: DsSpacing.x1),
              _TinyBtn(
                icon: showArchived
                    ? Icons.inbox_rounded
                    : Icons.inventory_2_outlined,
                tooltip: showArchived ? 'Show active' : 'Show archived',
                onTap: onToggleArchived,
                active: showArchived,
              ),
              const SizedBox(width: DsSpacing.x1),
              _TinyBtn(
                icon: Icons.chevron_left_rounded,
                tooltip: 'sessions.close_esc'.tr(),
                onTap: onClose,
              ),
            ],
          ),
          const SizedBox(height: DsSpacing.x4),
          if (showProject)
            _PrimaryCta(
              icon: Icons.create_new_folder_rounded,
              label: 'sessions.add_project'.tr(),
              onTap: onAddProject,
            )
          else
            _PrimaryCta(
              icon: Icons.add_rounded,
              label: 'sessions.new_chat'.tr(),
              onTap: onNewChat,
            ),
          const SizedBox(height: DsSpacing.x4),
          _SearchBar(controller: searchCtrl, focusNode: searchFocus),
        ],
      ),
    );
  }
}

class _PrimaryCta extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _PrimaryCta({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_PrimaryCta> createState() => _PrimaryCtaState();
}

class _PrimaryCtaState extends State<_PrimaryCta> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          height: 38,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _h
                  ? [c.accentPrimary, c.accentSecondary]
                  : [
                      c.accentPrimary.withValues(alpha: 0.96),
                      c.accentPrimary.withValues(alpha: 0.86),
                    ],
            ),
            borderRadius: BorderRadius.circular(DsRadius.input),
            boxShadow: [
              BoxShadow(
                color: c.glow.withValues(alpha: _h ? 0.35 : 0.18),
                blurRadius: _h ? 18 : 10,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 16, color: c.onAccent),
              const SizedBox(width: DsSpacing.x2),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.onAccent,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  const _SearchBar({required this.controller, required this.focusNode});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onFocus() => setState(() {});
  void _onText() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final focused = widget.focusNode.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;
    return AnimatedContainer(
      duration: DsDuration.fast,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: DsSpacing.x3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(DsRadius.input),
        border: Border.all(
          color: focused ? c.accentPrimary.withValues(alpha: 0.55) : c.border,
          width: focused ? 1.2 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 13,
            color: focused ? c.accentPrimary : c.textDim,
          ),
          const SizedBox(width: DsSpacing.x2),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: c.textBright,
                height: 1.2,
              ),
              cursorColor: c.accentPrimary,
              cursorWidth: 1.2,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: InputBorder.none,
                hintText: 'sessions.search_history'.tr(),
                hintStyle: GoogleFonts.inter(fontSize: 12.5, color: c.textDim),
              ),
            ),
          ),
          if (hasText)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.controller.clear();
                widget.focusNode.unfocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpacing.x1),
                child: Icon(Icons.close_rounded, size: 12, color: c.textDim),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(DsRadius.xs),
                border: Border.all(color: c.border),
              ),
              child: Text(
                '/',
                style: GoogleFonts.firaCode(
                  fontSize: 9.5,
                  color: c.textDim,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BODY
// ═══════════════════════════════════════════════════════════════════════════

class _DrawerBody extends StatelessWidget {
  final String appId;
  final String searchQuery;
  final bool showArchived;
  final VoidCallback onPickedSession;
  final ValueChanged<String> onNewChatInProject;

  const _DrawerBody({
    required this.appId,
    required this.searchQuery,
    required this.showArchived,
    required this.onPickedSession,
    required this.onNewChatInProject,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([SessionService(), SessionPrefsService()]),
      builder: (ctx, _) {
        final c = ctx.colors;
        final svc = SessionService();
        final prefs = SessionPrefsService();
        final query = searchQuery.trim();
        final isSearching = query.isNotEmpty;

        // ── Server search mode ─────────────────────────────────────
        if (isSearching) {
          if (svc.isSearching) {
            return _LoadingSpinner(color: c.textMuted);
          }
          final results = svc.searchResults;
          if (results.isEmpty) {
            return _EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matches',
              subtitle: 'Nothing matches "$query"',
            );
          }
          return Scrollbar(
            thumbVisibility: false,
            child: ListView.builder(
              padding: const EdgeInsets.only(
                  top: DsSpacing.x3, bottom: DsSpacing.x4),
              itemCount: results.length,
              itemBuilder: (_, i) => _SearchResultTile(
                result: results[i],
                isActive:
                    results[i].sessionId == svc.activeSession?.sessionId,
                onTap: () {
                  final r = results[i];
                  final existing = svc.sessions.firstWhere(
                    (s) => s.sessionId == r.sessionId,
                    orElse: () => AppSession(
                      sessionId: r.sessionId,
                      appId: appId,
                      title: r.title,
                      messageCount: r.messageCount,
                      createdAt: r.createdAt,
                      lastActive: r.lastActive,
                    ),
                  );
                  svc.setActiveSession(existing);
                  onPickedSession();
                },
              ),
            ),
          );
        }

        // ── Loading state ──────────────────────────────────────────
        if (svc.isLoading) return _LoadingSpinner(color: c.textMuted);

        // ── Empty state ────────────────────────────────────────────
        if (svc.sessions.isEmpty) {
          return _EmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'No conversation yet',
            subtitle: 'Tap + to start your first chat.',
          );
        }

        // Split pinned / archived out first — applies to both modes.
        final visible = <AppSession>[];
        final pinned = <AppSession>[];
        final archived = <AppSession>[];
        for (final s in svc.sessions) {
          if (prefs.isArchived(s.sessionId)) {
            archived.add(s);
          } else if (prefs.isPinned(s.sessionId)) {
            pinned.add(s);
          } else {
            visible.add(s);
          }
        }

        final state = ctx.watch<AppState>();
        final usesProjects = _shouldUseTreeMode(
          visible + pinned,
          state.manifest.workspaceMode,
        );

        final sections = <Widget>[];

        if (showArchived) {
          sections.add(_SectionLabel(label: 'sessions.archived'.tr(),
              count: archived.length));
          if (archived.isEmpty) {
            sections.add(_InlineEmpty(
                label: 'sessions.nothing_archived'.tr()));
          } else {
            for (final s in archived) {
              sections.add(_buildTile(ctx, s, svc, prefs));
            }
          }
        } else {
          if (pinned.isNotEmpty) {
            sections.add(_SectionLabel(
              label: 'sessions.pinned'.tr(),
              icon: Icons.push_pin_rounded,
              count: pinned.length,
            ));
            for (final s in pinned) {
              sections.add(_buildTile(ctx, s, svc, prefs));
            }
          }

          if (usesProjects) {
            sections.addAll(_buildProjectSections(
              ctx, visible, svc, prefs, onNewChatInProject,
            ));
          } else {
            sections.addAll(_buildFlatTimeSections(ctx, visible, svc, prefs));
          }

          if (archived.isNotEmpty) {
            sections.add(const SizedBox(height: DsSpacing.x3));
            sections.add(_ArchiveFooter(
              count: archived.length,
              onTap: () {
                // Let the parent flip the toggle via event bus. The
                // toggle lives on the header; a simple approach is to
                // expose a callback, but for now we just tap the
                // archive icon — this footer is advisory.
              },
            ));
          }
        }

        return Scrollbar(
          thumbVisibility: false,
          radius: const Radius.circular(2),
          thickness: 6,
          child: ListView(
            padding: const EdgeInsets.only(
                top: DsSpacing.x3, bottom: DsSpacing.x7),
            children: sections,
          ),
        );
      },
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static bool _shouldUseTreeMode(
      List<AppSession> sessions, WorkspaceMode mode) {
    if (mode == WorkspaceMode.required) return true;
    if (mode == WorkspaceMode.optional) {
      return sessions.any((s) =>
          s.workspacePath != null && s.workspacePath!.isNotEmpty);
    }
    return false;
  }

  List<Widget> _buildProjectSections(
    BuildContext ctx,
    List<AppSession> sessions,
    SessionService svc,
    SessionPrefsService prefs,
    ValueChanged<String> onNewChatInProject,
  ) {
    final byProject = <String, List<AppSession>>{};
    final quick = <AppSession>[];
    for (final s in sessions) {
      final p = (s.workspacePath ?? '').trim();
      if (p.isEmpty) {
        quick.add(s);
      } else {
        byProject.putIfAbsent(p, () => []).add(s);
      }
    }

    // Project order: project with most-recent session first.
    DateTime? maxDate(List<AppSession> list) {
      DateTime? best;
      for (final s in list) {
        final dt = s.lastActive ?? s.createdAt;
        if (dt != null && (best == null || dt.isAfter(best))) best = dt;
      }
      return best;
    }

    final projects = byProject.entries.toList()
      ..sort((a, b) {
        final da = maxDate(a.value);
        final db = maxDate(b.value);
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });

    final out = <Widget>[
      _SectionLabel(
        label: 'sessions.projects'.tr(),
        icon: Icons.folder_outlined,
        count: projects.length,
      ),
    ];

    for (final entry in projects) {
      final path = entry.key;
      if (prefs.isProjectArchived(path)) continue;
      final list = entry.value
        ..sort((a, b) {
          final da = (a.lastActive ?? a.createdAt) ?? DateTime(0);
          final db = (b.lastActive ?? b.createdAt) ?? DateTime(0);
          return db.compareTo(da);
        });
      out.add(_ProjectGroup(
        path: path,
        sessions: list,
        onNewChat: () => onNewChatInProject(path),
        buildTile: (s) => _buildTile(ctx, s, svc, prefs),
      ));
    }

    if (quick.isNotEmpty) {
      out.add(const SizedBox(height: DsSpacing.x3));
      out.add(_SectionLabel(
        label: 'sessions.quick_chats'.tr(),
        icon: Icons.bolt_rounded,
        count: quick.length,
      ));
      for (final s in quick) {
        out.add(_buildTile(ctx, s, svc, prefs));
      }
    }

    return out;
  }

  List<Widget> _buildFlatTimeSections(
    BuildContext ctx,
    List<AppSession> sessions,
    SessionService svc,
    SessionPrefsService prefs,
  ) {
    final now = DateTime.now();
    final today = <AppSession>[];
    final yesterday = <AppSession>[];
    final last7 = <AppSession>[];
    final last30 = <AppSession>[];
    final older = <AppSession>[];

    for (final s in sessions) {
      final dt = s.lastActive ?? s.createdAt;
      if (dt == null) {
        older.add(s);
        continue;
      }
      final startOfToday = DateTime(now.year, now.month, now.day);
      final startOfYday = startOfToday.subtract(const Duration(days: 1));
      if (!dt.isBefore(startOfToday)) {
        today.add(s);
      } else if (!dt.isBefore(startOfYday)) {
        yesterday.add(s);
      } else if (now.difference(dt).inDays <= 7) {
        last7.add(s);
      } else if (now.difference(dt).inDays <= 30) {
        last30.add(s);
      } else {
        older.add(s);
      }
    }

    final out = <Widget>[];
    void addBucket(String label, List<AppSession> list) {
      if (list.isEmpty) return;
      out.add(_SectionLabel(label: label, count: list.length));
      for (final s in list) {
        out.add(_buildTile(ctx, s, svc, prefs));
      }
    }

    addBucket('Today', today);
    addBucket('Yesterday', yesterday);
    addBucket('Last 7 days', last7);
    addBucket('Last 30 days', last30);
    addBucket('Older', older);
    return out;
  }

  Widget _buildTile(
    BuildContext ctx,
    AppSession s,
    SessionService svc,
    SessionPrefsService prefs,
  ) {
    final isActive = s.sessionId == svc.activeSession?.sessionId;
    return _SessionTile(
      key: ValueKey('tile-${s.sessionId}'),
      session: s,
      isActive: isActive,
      isPinned: prefs.isPinned(s.sessionId),
      isArchived: prefs.isArchived(s.sessionId),
      localTitle: prefs.localTitle(s.sessionId),
      onTap: () {
        svc.setActiveSession(s);
        onPickedSession();
      },
      onPinToggle: () => prefs.togglePin(s.sessionId),
      onArchiveToggle: () =>
          prefs.setArchived(s.sessionId, !prefs.isArchived(s.sessionId)),
      onRename: () async {
        final current = prefs.localTitle(s.sessionId) ?? s.title;
        final next = await showThemedPromptDialog(
          ctx,
          title: 'Rename conversation',
          hint: 'New title',
          initial: current,
          confirmLabel: 'Save',
        );
        if (next != null) prefs.setLocalTitle(s.sessionId, next);
      },
      onDelete: () => _confirmDelete(ctx, s, svc, prefs),
      onCompact: () => _compactSession(ctx, s),
      onUndoLastTurn: () => _undoSession(ctx, s),
      onExportEnvelope: () => _exportEnvelope(ctx, s),
      onResume: () => _resumeSession(ctx, s),
    );
  }

  // ── New session actions wired against SessionActionsService ──

  Future<void> _compactSession(BuildContext ctx, AppSession s) async {
    final res =
        await SessionActionsService().compact(appId, s.sessionId);
    if (!ctx.mounted) return;
    if (res == null) {
      showToast(ctx, 'Compact failed — see daemon logs.');
    } else {
      final reduced = (res['tokens_reduced'] as num?)?.toInt() ?? 0;
      showToast(ctx,
          'Compacted — saved $reduced tokens. '
          'Live hook event will refresh the context meter.');
    }
  }

  Future<void> _undoSession(BuildContext ctx, AppSession s) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => themedAlertDialog(
        dCtx,
        title: 'Undo last turn?',
        content: const Text(
          'Removes the last user + assistant messages from this '
          "session. This can't be reverted.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final newCount =
        await SessionActionsService().undo(appId, s.sessionId);
    if (!ctx.mounted) return;
    if (newCount == null) {
      showToast(ctx, 'Undo failed.');
    } else {
      showToast(ctx, 'Undone — session now has $newCount message(s).');
      SessionService().loadSessions(appId);
    }
  }

  Future<void> _exportEnvelope(BuildContext ctx, AppSession s) async {
    final data =
        await SessionActionsService().exportSession(appId, s.sessionId);
    if (!ctx.mounted) return;
    if (data == null) {
      showToast(ctx, 'Export failed.');
      return;
    }
    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    await Clipboard.setData(ClipboardData(text: pretty));
    if (!ctx.mounted) return;
    showToast(ctx,
        'Session envelope copied to clipboard (${pretty.length} chars).');
  }

  Future<void> _resumeSession(BuildContext ctx, AppSession s) async {
    final ok =
        await SessionActionsService().resume(appId, s.sessionId);
    if (!ctx.mounted) return;
    showToast(ctx,
        ok ? 'Resume requested.' : 'Resume rejected by daemon.');
  }

  Future<void> _confirmDelete(
    BuildContext ctx,
    AppSession s,
    SessionService svc,
    SessionPrefsService prefs,
  ) async {
    final c = ctx.colors;
    final title = prefs.localTitle(s.sessionId) ?? s.displayTitle;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (_) => themedAlertDialog(
        ctx,
        title: 'Delete conversation?',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"$title" will be permanently removed from the daemon.',
                style: dialogBodyStyle(ctx)),
            const SizedBox(height: DsSpacing.x3),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.x3, vertical: DsSpacing.x2),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(DsRadius.xs),
                border: Border.all(color: c.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14, color: c.textDim),
                  const SizedBox(width: DsSpacing.x2),
                  Flexible(
                    child: Text(
                      'Tip: archive instead if you may want it back.',
                      style: GoogleFonts.inter(
                          fontSize: 11.5, color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('common.cancel'.tr(),
                style: GoogleFonts.inter(color: c.textMuted, fontSize: 12)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: c.red,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: Text('common.delete'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await svc.deleteSession(appId, s.sessionId);
      await prefs.forgetSession(s.sessionId);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PROJECT GROUP (tree mode)
// ═══════════════════════════════════════════════════════════════════════════

class _ProjectGroup extends StatefulWidget {
  final String path;
  final List<AppSession> sessions;
  final VoidCallback onNewChat;
  final Widget Function(AppSession) buildTile;

  const _ProjectGroup({
    required this.path,
    required this.sessions,
    required this.onNewChat,
    required this.buildTile,
  });

  @override
  State<_ProjectGroup> createState() => _ProjectGroupState();
}

class _ProjectGroupState extends State<_ProjectGroup>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _size;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    final collapsed = SessionPrefsService().isProjectCollapsed(widget.path);
    _ctrl = AnimationController(
      vsync: this,
      duration: DsDuration.base,
      value: collapsed ? 0.0 : 1.0,
    );
    _size = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggle() {
    final collapsed = _ctrl.value > 0.5;
    if (collapsed) {
      _ctrl.reverse();
    } else {
      _ctrl.forward();
    }
    SessionPrefsService().toggleProjectCollapsed(widget.path);
  }

  String get _name {
    final n = widget.path.replaceAll('\\', '/');
    final i = n.lastIndexOf('/');
    return (i < 0 || i == n.length - 1) ? n : n.substring(i + 1);
  }

  String get _parent {
    final n = widget.path.replaceAll('\\', '/');
    final i = n.lastIndexOf('/');
    return i <= 0 ? '' : n.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final count = widget.sessions.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: _toggle,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: DsDuration.fast,
              margin: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.x3, vertical: DsSpacing.x1),
              padding: const EdgeInsets.symmetric(
                  horizontal: DsSpacing.x3, vertical: DsSpacing.x2),
              decoration: BoxDecoration(
                color: _hover
                    ? c.accentPrimary.withValues(alpha: 0.04)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(DsRadius.xs),
              ),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _ctrl.value > 0.5 ? 0.25 : 0.0,
                    duration: DsDuration.base,
                    child: Icon(Icons.chevron_right_rounded,
                        size: 15, color: c.textMuted),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.folder_rounded,
                      size: 14,
                      color: _hover ? c.accentPrimary : c.accentSecondary),
                  const SizedBox(width: DsSpacing.x2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: c.textBright,
                              letterSpacing: -0.1,
                            )),
                        if (_parent.isNotEmpty)
                          Text(_parent,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.firaCode(
                                fontSize: 9.5,
                                color: c.textDim,
                              )),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(DsRadius.pill),
                      border: Border.all(color: c.border),
                    ),
                    child: Text('$count',
                        style: GoogleFonts.firaCode(
                            fontSize: 9.5,
                            color: c.textMuted,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: DsSpacing.x2),
                  if (_hover)
                    _TinyBtn(
                      icon: Icons.add_rounded,
                      tooltip: 'sessions.new_chat_in'
                          .tr(namedArgs: {'app': _name}),
                      onTap: widget.onNewChat,
                      accent: true,
                    )
                  else
                    const SizedBox(width: 26),
                ],
              ),
            ),
          ),
        ),
        ClipRect(
          child: SizeTransition(
            sizeFactor: _size,
            axisAlignment: -1,
            child: FadeTransition(
              opacity: _size,
              child: Padding(
                padding: const EdgeInsets.only(left: DsSpacing.x4),
                child: Column(
                  children: [
                    for (final s in widget.sessions) widget.buildTile(s),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SECTION LABEL + EMPTY STATES
// ═══════════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String label;
  final IconData? icon;
  final int? count;
  const _SectionLabel({required this.label, this.icon, this.count});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          DsSpacing.x6, DsSpacing.x4, DsSpacing.x5, DsSpacing.x2),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: c.textDim),
            const SizedBox(width: DsSpacing.x2),
          ],
          Text(
            label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: c.textDim,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: DsSpacing.x2),
            Text('·',
                style:
                    GoogleFonts.inter(fontSize: 10, color: c.textDim)),
            const SizedBox(width: DsSpacing.x2),
            Text('$count',
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textDim, fontWeight: FontWeight.w600)),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  final String label;
  const _InlineEmpty({required this.label});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          DsSpacing.x6, DsSpacing.x2, DsSpacing.x6, DsSpacing.x4),
      child: Text(label,
          style: GoogleFonts.inter(fontSize: 11.5, color: c.textDim)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DsSpacing.x7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: c.accentPrimary.withValues(alpha: 0.07),
                shape: BoxShape.circle,
                border: Border.all(
                    color: c.accentPrimary.withValues(alpha: 0.2)),
              ),
              child: Icon(icon, size: 22, color: c.accentPrimary),
            ),
            const SizedBox(height: DsSpacing.x4),
            Text(title,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 13.5,
                    color: c.textBright,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: DsSpacing.x2),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted, height: 1.4)),
          ],
        ),
      ),
    );
  }
}

class _LoadingSpinner extends StatelessWidget {
  final Color color;
  const _LoadingSpinner({required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 1.4, color: color),
      ),
    );
  }
}

class _ArchiveFooter extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ArchiveFooter({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.x6, vertical: DsSpacing.x2),
      child: Row(
        children: [
          Icon(Icons.archive_outlined, size: 12, color: c.textDim),
          const SizedBox(width: DsSpacing.x2),
          Text('$count archived',
              style: GoogleFonts.inter(fontSize: 11, color: c.textDim)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SESSION TILE
// ═══════════════════════════════════════════════════════════════════════════

class _SessionTile extends StatefulWidget {
  final AppSession session;
  final bool isActive;
  final bool isPinned;
  final bool isArchived;
  final String? localTitle;
  final VoidCallback onTap;
  final VoidCallback onPinToggle;
  final VoidCallback onArchiveToggle;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  /// Trigger a manual context compaction for this session.
  final VoidCallback onCompact;
  /// Drop the last user+assistant pair from this session's history.
  final VoidCallback onUndoLastTurn;
  /// Copy a portable session envelope (JSON) to the clipboard.
  final VoidCallback onExportEnvelope;
  /// Ask the daemon to resume a turn that got interrupted.
  final VoidCallback onResume;

  const _SessionTile({
    super.key,
    required this.session,
    required this.isActive,
    required this.isPinned,
    required this.isArchived,
    required this.localTitle,
    required this.onTap,
    required this.onPinToggle,
    required this.onArchiveToggle,
    required this.onRename,
    required this.onDelete,
    required this.onCompact,
    required this.onUndoLastTurn,
    required this.onExportEnvelope,
    required this.onResume,
  });

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = widget.session;
    final svc = SessionService();
    final isRunning = svc.runningSessions.contains(s.sessionId) || s.isRunning;
    final isInterrupted = s.interrupted;
    // Commit-on-first-success: the server hasn't persisted this
    // session yet — the first turn's `message_done` will trigger a
    // refetch that replaces our optimistic row with the canonical
    // one (including the LLM-generated title).
    final isDraft = svc.isDraft(s.sessionId);
    // History fetch feedback lives HERE (not in the chat area) so the
    // chat never renders a fake-conversation shimmer on session open.
    // Only the currently-active tile shows the loading dot, and only
    // while `SessionService.isLoadingHistory` is true.
    final isLoadingThisSession = widget.isActive && svc.isLoadingHistory;
    // Use `displayTitle` for the 3-tier fallback (daemon title →
    // last_message_preview → shortId). The previous inline
    // `title.isEmpty ? shortId` shortcut skipped the preview
    // layer, so any session whose daemon `title` was empty
    // (common on pre-migration sessions the server hasn't given
    // a semantic title yet) rendered as a useless random id.
    final title = widget.localTitle ?? s.displayTitle;

    // Keep the secondary preview line distinct from the primary
    // title — when the title is already derived from the preview
    // (displayTitle tier-2 fallback), duplicating it below looks
    // like a bug. Skip the preview row in that case.
    final rawPreview =
        (s.lastMessagePreview ?? '').replaceAll('\n', ' ').trim();
    final preview =
        s.title.isEmpty && rawPreview.isNotEmpty ? '' : rawPreview;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hover && mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover && mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(
              horizontal: DsSpacing.x3, vertical: 1.5),
          decoration: BoxDecoration(
            color: widget.isActive
                ? c.accentPrimary.withValues(alpha: 0.09)
                : _hover
                    ? c.surfaceAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.input),
            border: Border.all(
              color: widget.isActive
                  ? c.accentPrimary.withValues(alpha: 0.28)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 3,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: widget.isActive
                        ? c.accentPrimary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        DsSpacing.x3,
                        DsSpacing.x3,
                        DsSpacing.x2,
                        DsSpacing.x3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (widget.isPinned) ...[
                              Icon(Icons.push_pin_rounded,
                                  size: 10, color: c.accentSecondary),
                              const SizedBox(width: DsSpacing.x1),
                            ],
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 12.5,
                                  fontWeight: widget.isActive
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  color: widget.isActive
                                      ? c.textBright
                                      : c.text,
                                  letterSpacing: -0.05,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            const SizedBox(width: DsSpacing.x2),
                            if (isLoadingThisSession)
                              Tooltip(
                                message: 'Loading history…',
                                child: SizedBox(
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.4,
                                    valueColor: AlwaysStoppedAnimation(
                                      c.textMuted.withValues(alpha: 0.85),
                                    ),
                                  ),
                                ),
                              )
                            else if (isRunning)
                              const _RunningDot()
                            else if (isDraft)
                              Tooltip(
                                message:
                                    'Draft — will be saved after the first reply',
                                child: Icon(
                                  Icons.edit_outlined,
                                  size: 11,
                                  color: c.textDim,
                                ),
                              )
                            else if (isInterrupted)
                              Tooltip(
                                message:
                                    'Interrupted — send a message to resume',
                                child: Icon(
                                  Icons.pause_circle_filled_rounded,
                                  size: 11,
                                  color: c.red.withValues(alpha: 0.85),
                                ),
                              ),
                          ],
                        ),
                        if (preview.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: c.textMuted,
                              height: 1.4,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        _MetaRow(session: s),
                      ],
                    ),
                  ),
                ),
                _TileActions(
                  visible: _hover || widget.isActive,
                  isPinned: widget.isPinned,
                  isArchived: widget.isArchived,
                  canExport: widget.isActive,
                  sessionTitle: title,
                  onPin: widget.onPinToggle,
                  onArchive: widget.onArchiveToggle,
                  onRename: widget.onRename,
                  onDelete: widget.onDelete,
                  onFork: () => WorkspaceSnapshotActions.fork(context),
                  onSave: () => WorkspaceSnapshotActions.saveCopy(context),
                  onImport: () =>
                      WorkspaceSnapshotActions.importFromFile(context),
                  onCompact: widget.onCompact,
                  onUndoLastTurn: widget.onUndoLastTurn,
                  onExportEnvelope: widget.onExportEnvelope,
                  onResume: widget.onResume,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final AppSession session;
  const _MetaRow({required this.session});

  String _formatTokens(int n) {
    if (n <= 0) return '';
    if (n < 1000) return '${n}t';
    if (n < 1_000_000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
    return '${(n / 1_000_000).toStringAsFixed(1)}M';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = session;
    final parts = <Widget>[];
    void addText(String t) {
      if (parts.isNotEmpty) {
        parts.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(
            width: 2,
            height: 2,
            decoration: BoxDecoration(color: c.textDim, shape: BoxShape.circle),
          ),
        ));
      }
      parts.add(Text(t,
          style: GoogleFonts.firaCode(
              fontSize: 9.5, color: c.textDim, fontWeight: FontWeight.w500)));
    }

    final time = s.timeAgo;
    if (time.isNotEmpty) addText(time);
    if (s.messageCount > 0) {
      addText('${s.messageCount} msg${s.messageCount == 1 ? '' : 's'}');
    }
    final tk = _formatTokens(s.tokens);
    if (tk.isNotEmpty) addText(tk);

    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(children: parts);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TILE ACTIONS (3-dot menu)
// ═══════════════════════════════════════════════════════════════════════════

class _TileActions extends StatelessWidget {
  final bool visible;
  final bool isPinned;
  final bool isArchived;
  final bool canExport;
  final String sessionTitle;
  final VoidCallback onPin;
  final VoidCallback onArchive;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onFork;
  final VoidCallback onSave;
  final VoidCallback onImport;
  final VoidCallback onCompact;
  final VoidCallback onUndoLastTurn;
  final VoidCallback onExportEnvelope;
  final VoidCallback onResume;

  const _TileActions({
    required this.visible,
    required this.isPinned,
    required this.isArchived,
    required this.canExport,
    required this.sessionTitle,
    required this.onPin,
    required this.onArchive,
    required this.onRename,
    required this.onDelete,
    required this.onFork,
    required this.onSave,
    required this.onImport,
    required this.onCompact,
    required this.onUndoLastTurn,
    required this.onExportEnvelope,
    required this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedOpacity(
      duration: DsDuration.fast,
      opacity: visible ? 1.0 : 0.0,
      child: IgnorePointer(
        ignoring: !visible,
        child: Padding(
          padding: const EdgeInsets.only(right: DsSpacing.x2, top: 4),
          child: PopupMenuButton<String>(
            tooltip: 'sessions.more'.tr(),
            padding: EdgeInsets.zero,
            iconSize: 14,
            offset: const Offset(0, 24),
            color: c.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(DsRadius.input),
              side: BorderSide(color: c.border),
            ),
            elevation: 16,
            shadowColor: c.shadow,
            icon: Icon(Icons.more_vert_rounded, size: 14, color: c.textMuted),
            onSelected: (v) {
              switch (v) {
                case 'pin':
                  onPin();
                case 'rename':
                  onRename();
                case 'copy':
                  ChatExportBridge()
                      .export('clipboard', sessionTitle: sessionTitle);
                case 'markdown':
                  ChatExportBridge()
                      .export('markdown', sessionTitle: sessionTitle);
                case 'fork':
                  onFork();
                case 'save':
                  onSave();
                case 'import':
                  onImport();
                case 'compact':
                  onCompact();
                case 'undo':
                  onUndoLastTurn();
                case 'export_envelope':
                  onExportEnvelope();
                case 'resume':
                  onResume();
                case 'archive':
                  onArchive();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (_) => [
              _menuItem(context,
                  value: 'pin',
                  icon: isPinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  label: isPinned ? 'Unpin' : 'Pin to top'),
              _menuItem(context,
                  value: 'rename',
                  icon: Icons.edit_outlined,
                  label: 'sessions.rename'.tr()),
              if (canExport) ...[
                const PopupMenuDivider(height: 6),
                _menuItem(context,
                    value: 'copy',
                    icon: Icons.copy_rounded,
                    label: 'sessions.copy_conversation'.tr()),
                _menuItem(context,
                    value: 'markdown',
                    icon: Icons.save_alt_rounded,
                    label: 'sessions.export_markdown'.tr()),
              ],
              const PopupMenuDivider(height: 6),
              // ── Session lifecycle (scout-wired via
              //   SessionActionsService) ─────────────────────
              _menuItem(context,
                  value: 'compact',
                  icon: Icons.compress_rounded,
                  label: 'Compact context'),
              _menuItem(context,
                  value: 'undo',
                  icon: Icons.undo_rounded,
                  label: 'Undo last turn'),
              _menuItem(context,
                  value: 'resume',
                  icon: Icons.play_arrow_rounded,
                  label: 'Resume interrupted'),
              _menuItem(context,
                  value: 'export_envelope',
                  icon: Icons.code_rounded,
                  label: 'Copy envelope (JSON)'),
              const PopupMenuDivider(height: 6),
              _menuItem(context,
                  value: 'fork',
                  icon: Icons.call_split_rounded,
                  label: 'chat.fork_workspace'.tr()),
              _menuItem(context,
                  value: 'save',
                  icon: Icons.file_download_outlined,
                  label: 'workspace.save_snapshot'.tr()),
              _menuItem(context,
                  value: 'import',
                  icon: Icons.file_upload_outlined,
                  label: 'chat.import_snapshot'.tr()),
              const PopupMenuDivider(height: 6),
              _menuItem(context,
                  value: 'archive',
                  icon: isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                  label: isArchived ? 'Unarchive' : 'Archive'),
              _menuItem(context,
                  value: 'delete',
                  icon: Icons.delete_outline_rounded,
                  label: 'common.delete'.tr(),
                  danger: true),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    BuildContext context, {
    required String value,
    required IconData icon,
    required String label,
    bool danger = false,
  }) {
    final c = context.colors;
    final color = danger ? c.red : c.text;
    return PopupMenuItem<String>(
      value: value,
      height: 34,
      padding: const EdgeInsets.symmetric(
          horizontal: DsSpacing.x4, vertical: DsSpacing.x2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: DsSpacing.x3),
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SEARCH RESULT TILE
// ═══════════════════════════════════════════════════════════════════════════

class _SearchResultTile extends StatefulWidget {
  final SessionSearchResult result;
  final bool isActive;
  final VoidCallback onTap;
  const _SearchResultTile({
    required this.result,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_SearchResultTile> createState() => _SearchResultTileState();
}

class _SearchResultTileState extends State<_SearchResultTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = widget.result;
    final snippet = r.snippets.isNotEmpty
        ? r.snippets.first
            .replaceFirst(RegExp(r'^(title|message\[\d+\]):\s*'), '')
        : '';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          margin: const EdgeInsets.symmetric(
              horizontal: DsSpacing.x3, vertical: 2),
          padding: const EdgeInsets.symmetric(
              horizontal: DsSpacing.x4, vertical: DsSpacing.x3),
          decoration: BoxDecoration(
            color: widget.isActive
                ? c.accentPrimary.withValues(alpha: 0.09)
                : _hover
                    ? c.surfaceAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.input),
            border: Border.all(
              color: widget.isActive
                  ? c.accentPrimary.withValues(alpha: 0.28)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_outlined,
                      size: 11, color: c.accentPrimary),
                  const SizedBox(width: DsSpacing.x2),
                  Expanded(
                    child: Text(
                      r.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                  ),
                  if (r.messageCount > 0)
                    Text('${r.messageCount}',
                        style: GoogleFonts.firaCode(
                            fontSize: 9.5,
                            color: c.textDim,
                            fontWeight: FontWeight.w600)),
                ],
              ),
              if (snippet.isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: DsSpacing.x5),
                  child: Text(
                    snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: c.textMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// RUNNING DOT
// ═══════════════════════════════════════════════════════════════════════════

class _RunningDot extends StatefulWidget {
  const _RunningDot();

  @override
  State<_RunningDot> createState() => _RunningDotState();
}

class _RunningDotState extends State<_RunningDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Turn in progress',
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final alpha = 0.45 + (0.45 * _ctrl.value);
          return Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: c.accentPrimary.withValues(alpha: alpha),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: c.accentPrimary.withValues(alpha: alpha * 0.55),
                  blurRadius: 5,
                  spreadRadius: 1,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FOOTER
// ═══════════════════════════════════════════════════════════════════════════

class _UserFooter extends StatelessWidget {
  const _UserFooter();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService(),
      builder: (_, _) {
        final c = context.colors;
        final user = AuthService().currentUser;
        final display = user?.displayName?.trim().isNotEmpty == true
            ? user!.displayName!
            : (user?.userId ?? 'Guest');
        final initial = display.isNotEmpty ? display[0].toUpperCase() : '?';

        return Container(
          padding: const EdgeInsets.fromLTRB(
              DsSpacing.x4, DsSpacing.x3, DsSpacing.x3, DsSpacing.x3),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              _UserAvatar(initial: initial),
              const SizedBox(width: DsSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      display,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (user?.email?.isNotEmpty == true)
                      Text(
                        user!.email!,
                        style: GoogleFonts.inter(
                            fontSize: 10, color: c.textDim, height: 1.25),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              _TinyBtn(
                icon: Icons.logout_rounded,
                tooltip: 'dashboard.logout'.tr(),
                onTap: () => AuthService().logout(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final String initial;
  const _UserAvatar({required this.initial});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.accentPrimary.withValues(alpha: 0.28),
            c.accentSecondary.withValues(alpha: 0.22),
          ],
        ),
        shape: BoxShape.circle,
        border: Border.all(color: c.accentPrimary.withValues(alpha: 0.35)),
      ),
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: c.textBright,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TINY BUTTON
// ═══════════════════════════════════════════════════════════════════════════

class _TinyBtn extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;
  final bool accent;
  final bool active;

  const _TinyBtn({
    required this.icon,
    this.tooltip,
    required this.onTap,
    this.accent = false,
    this.active = false,
  });

  @override
  State<_TinyBtn> createState() => _TinyBtnState();
}

class _TinyBtnState extends State<_TinyBtn> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hoverBg = widget.accent
        ? c.accentPrimary.withValues(alpha: 0.15)
        : c.surfaceAlt;
    final fg = widget.active
        ? c.accentPrimary
        : (_h ? (widget.accent ? c.accentPrimary : c.textBright) : c.textMuted);
    final child = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _h || widget.active ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Icon(widget.icon, size: 13, color: fg),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: child)
        : child;
  }
}
