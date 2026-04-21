/// Three-pane Lovable-style IDE layout:
///
/// ┌─────────────────────────────────────────────────────────┐
/// │  Files (220px) │  Editor / Diff (flex)  │  Preview (flex)│
/// └─────────────────────────────────────────────────────────┘
///
/// The chat panel lives outside this widget — the caller decides
/// whether to mount it side-by-side or above/below. For the Lovable
/// experience we stack: [chat, this] in a vertical split where the
/// chat is collapsible.
///
/// Responsive degradation:
///   • width ≥ 1100 → three panes
///   • width ≥ 720  → files + editor, preview on a separate tab
///   • width  < 720 → single column with a segmented picker
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../main.dart';
import '../../../services/preview_availability_service.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';
import '../ws_preview_router.dart';
import 'code_explorer.dart';
import 'conflict_pane.dart';
import 'editor_pane.dart';
import 'problems_panel.dart';

class IdeLayout extends StatefulWidget {
  const IdeLayout({super.key});

  @override
  State<IdeLayout> createState() => _IdeLayoutState();
}

class _IdeLayoutState extends State<IdeLayout> {
  String? _selected;
  /// Narrow-screen segmented picker: 'files' | 'editor' | 'preview'.
  String _pane = 'files';

  // ── File-explorer column width, user-resizable ─────────────────
  //
  // Pixel width of the Files / CodeExplorer column on desktop and
  // tablet layouts. The user drags the vertical divider to adjust;
  // we clamp within [min, max] and persist to SharedPreferences so
  // the choice survives app restarts.
  static const double _explorerMinWidth = 180.0;
  static const double _explorerMaxWidth = 640.0;
  static const double _explorerDefaultWidth = 280.0;
  static const String _explorerWidthPrefKey = 'ide_explorer_width_px';
  double _explorerWidth = _explorerDefaultWidth;

  // ── Multi-file tabs (VS Code / Cursor style) ──────────────────
  //
  // Ordered list of open file paths. Clicking a file in the
  // explorer ADDS it to the tabs instead of replacing the current
  // model — Monaco caches each model internally so tab switching is
  // instant (no re-fetch, scroll/cursor preserved per file).
  //
  // `_selected` continues to track the ACTIVE tab (null = none).
  // Tabs are pruned automatically in `_ensureSelection` when files
  // disappear from the workspace (e.g. agent deletes them).
  final List<String> _openTabs = [];

  // Manual subscription bookkeeping — avoids `ListenableBuilder` and
  // `Listenable.merge` here. Both re-subscribe eagerly during rebuilds,
  // and combined with the global `_chatKey` in the shell (main.dart
  // §2456) they trigger re-entrant retakes of inactive elements
  // (framework assertions at 2168/4735/6417). Manual listeners +
  // scheduled `setState` keep the pane swap strictly single-frame.
  @override
  void initState() {
    super.initState();
    WorkspaceModule().addListener(_onSourceChanged);
    PreviewAvailabilityService().addListener(_onSourceChanged);
    _loadExplorerWidth();
  }

  Future<void> _loadExplorerWidth() async {
    try {
      final p = await SharedPreferences.getInstance();
      final stored = p.getDouble(_explorerWidthPrefKey);
      if (!mounted || stored == null) return;
      setState(() {
        _explorerWidth =
            stored.clamp(_explorerMinWidth, _explorerMaxWidth);
      });
    } catch (_) {
      // SharedPreferences unavailable (tests, first launch) — stick
      // with the default width.
    }
  }

  Future<void> _saveExplorerWidth() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_explorerWidthPrefKey, _explorerWidth);
    } catch (_) {
      // Best-effort — persistence is not critical for correctness.
    }
  }

  void _onExplorerDrag(double dx) {
    setState(() {
      _explorerWidth = (_explorerWidth + dx)
          .clamp(_explorerMinWidth, _explorerMaxWidth);
    });
  }

  @override
  void dispose() {
    WorkspaceModule().removeListener(_onSourceChanged);
    PreviewAvailabilityService().removeListener(_onSourceChanged);
    super.dispose();
  }

  void _onSourceChanged() {
    if (!mounted) return;
    // Defer to the next microtask so the notifyListeners chain that
    // originated inside another build pass (e.g. a tool_call ingestion
    // toggling file availability while the chat panel is mid-rebuild)
    // has fully unwound before we request our own rebuild.
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  void _select(String path) {
    setState(() {
      if (!_openTabs.contains(path)) {
        _openTabs.add(path);
      }
      _selected = path;
      _pane = 'editor';
    });
  }

  /// Close a tab. If it was the active one, jumps to the neighbour
  /// on the right (or left if it was the last tab). When no tabs
  /// remain, `_selected` falls back to the workspace entry file so
  /// the editor shows something instead of the empty placeholder.
  void _closeTab(String path) {
    setState(() {
      final idx = _openTabs.indexOf(path);
      if (idx == -1) return;
      _openTabs.removeAt(idx);
      if (_selected != path) return;
      if (_openTabs.isEmpty) {
        _selected = null;
        return;
      }
      // Prefer the neighbour on the right; fall back to the new last
      // tab (which is the left neighbour of the closed one).
      final nextIdx = idx.clamp(0, _openTabs.length - 1);
      _selected = _openTabs[nextIdx];
    });
  }

  /// If the selected file drops out of the module (deleted by agent)
  /// auto-pick another one, and prune any open tabs that no longer
  /// correspond to live files.
  void _ensureSelection() {
    final files = WorkspaceModule().files;
    // Prune tabs that reference files the agent has deleted.
    _openTabs.removeWhere((p) => !files.containsKey(p));
    if (_selected != null && files.containsKey(_selected)) return;
    // Active file is stale — prefer another OPEN tab before picking a
    // random file so the user's recent workspace isn't overridden.
    if (_openTabs.isNotEmpty) {
      _selected = _openTabs.first;
      return;
    }
    final meta = WorkspaceModule().meta;
    final entry = meta.entryFile;
    if (entry != null && files.containsKey(entry)) {
      _selected = entry;
      _openTabs.add(entry);
    } else if (files.isNotEmpty) {
      _selected = files.keys.first;
      _openTabs.add(_selected!);
    } else {
      _selected = null;
    }
  }

  /// True when the active app's render_mode needs the static preview
  /// endpoint (`GET /api/apps/{id}/preview/`) AND the probe confirmed
  /// it returns 404. In that case we hide the preview column / tab
  /// entirely rather than render a raw JSON error in an iframe.
  ///
  /// render_mode 'code' / 'html' / 'markdown' / 'slides' render files
  /// natively without hitting the endpoint — they never need hiding.
  /// `builder` (and any other [CanvasRegistry] mode) also renders
  /// client-side from workspace files — no static bundle required.
  /// Only `react` truly needs the iframe served by the daemon.
  ///
  /// Reads both singletons directly (no `context.watch`) — the outer
  /// `ListenableBuilder` in [build] merges them and triggers the
  /// rebuild, which keeps this method side-effect free and dodges the
  /// dependent-registration assertion that fires when watch is called
  /// inside a method on a context that's being torn down mid-swap.
  bool _previewUnavailable(BuildContext context) {
    final mode = WorkspaceModule().meta.renderMode;
    final needsIframe = mode == 'react';
    if (!needsIframe) return false;
    final appId = context.read<AppState>().activeApp?.appId;
    if (appId == null || appId.isEmpty) return false;
    return PreviewAvailabilityService().isAvailable(appId) == false;
  }

  @override
  Widget build(BuildContext context) {
    _ensureSelection();
    final noPreview = _previewUnavailable(context);
    final w = MediaQuery.of(context).size.width;
    if (w >= 1100) return _buildThreePane(noPreview: noPreview);
    if (w >= 720) return _buildTwoPane(noPreview: noPreview);
    return _buildMobile(noPreview: noPreview);
  }

  // ── Desktop — files + Monaco (full width) ──────────────────────
  //
  // Preview toggle lives up in `workspace_panel.dart`'s toolbar
  // (Search / Changes / Preview icons), which swaps the whole IDE
  // layout for `WsPreviewRouter` via an `IndexedStack`. No local
  // toggle here, no split — Monaco always gets the full width
  // beside the explorer. `noPreview` is kept as a parameter for
  // narrow-screen layouts below.

  Widget _buildThreePane({required bool noPreview}) {
    return Row(
      children: [
        SizedBox(width: _explorerWidth, child: _explorer()),
        _ResizableDivider(
          onDrag: _onExplorerDrag,
          onDragEnd: _saveExplorerWidth,
        ),
        Expanded(child: _editorOrConflict()),
      ],
    );
  }

  // ── Tablet — files + (editor | preview with tab picker) ────────

  Widget _buildTwoPane({required bool noPreview}) {
    // When the preview endpoint 404s, drop the preview tab entirely
    // — the tab bar would be a lone "Editor" pill, so we skip it too.
    if (noPreview) {
      return Row(
        children: [
          SizedBox(width: _explorerWidth, child: _explorer()),
          _ResizableDivider(
            onDrag: _onExplorerDrag,
            onDragEnd: _saveExplorerWidth,
          ),
          Expanded(child: _editorOrConflict()),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: _explorerWidth, child: _explorer()),
        _ResizableDivider(
          onDrag: _onExplorerDrag,
          onDragEnd: _saveExplorerWidth,
        ),
        Expanded(
          child: Column(
            children: [
              _TabBar(
                tabs: const [
                  ('editor', 'Editor', Icons.code_rounded),
                  ('preview', 'Preview', Icons.visibility_outlined),
                ],
                active: _pane == 'editor' ? 'editor' : 'preview',
                onTap: (v) => setState(() => _pane = v),
              ),
              Expanded(
                child: _pane == 'preview'
                    ? const WsPreviewRouter()
                    : _editorOrConflict(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Mobile — single column, 3-way segmented picker ─────────────

  Widget _buildMobile({required bool noPreview}) {
    // If preview isn't available, fall back to a 2-way picker
    // (Files + Editor). Default to the Files pane when the preview
    // was what the user was viewing — the user asked for the file
    // zone to take focus when preview is hidden, and Files is more
    // useful than an empty editor if nothing is selected yet.
    if (noPreview && _pane == 'preview') {
      _pane = _selected == null ? 'files' : 'editor';
    }
    return Column(
      children: [
        _TabBar(
          tabs: noPreview
              ? const [
                  ('files', 'Files', Icons.folder_open_rounded),
                  ('editor', 'Editor', Icons.code_rounded),
                ]
              : const [
                  ('files', 'Files', Icons.folder_open_rounded),
                  ('editor', 'Editor', Icons.code_rounded),
                  ('preview', 'Preview', Icons.visibility_outlined),
                ],
          active: _pane,
          onTap: (v) => setState(() => _pane = v),
        ),
        Expanded(
          child: switch (_pane) {
            'files' => _explorer(),
            'preview' => const WsPreviewRouter(),
            _ => _editorOrConflict(),
          },
        ),
      ],
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────

  Widget _explorer() => CodeExplorer(
        selectedPath: _selected,
        onSelect: _select,
      );

  Widget _editorOrConflict() {
    final path = _selected;
    final Widget body;
    if (path == null) {
      body = _EmptyEditor();
    } else {
      final file = WorkspaceModule().files[path];
      if (file != null && file.isConflict) {
        body = ConflictPane(path: path);
      } else {
        body = EditorPane(path: path);
      }
    }
    return Column(
      children: [
        if (_openTabs.isNotEmpty)
          _EditorTabBar(
            openTabs: _openTabs,
            activePath: _selected,
            onSelect: (p) => setState(() => _selected = p),
            onClose: _closeTab,
          ),
        Expanded(child: body),
        ProblemsPanel(onReveal: _onProblemReveal),
      ],
    );
  }

  /// Called by the Problems panel. Selects the target file and asks
  /// the workspace module to ferry the reveal coordinates to the
  /// Monaco pane via its revealTarget stream.
  void _onProblemReveal(String path, int line, int column) {
    setState(() {
      _selected = path;
      _pane = 'editor';
    });
    WorkspaceModule().revealAt(path, line, column: column);
  }

}

// ── Multi-file tab bar ────────────────────────────────────────────
//
// VS Code / Cursor-style horizontal tab strip sitting at the top
// of the editor area. Each tab is a pill with a language-tinted
// filename + an inline close button. The active tab is marked with
// a 2 px coral bottom border. The strip scrolls horizontally when
// there are too many tabs to fit.

class _EditorTabBar extends StatefulWidget {
  final List<String> openTabs;
  final String? activePath;
  final void Function(String path) onSelect;
  final void Function(String path) onClose;

  const _EditorTabBar({
    required this.openTabs,
    required this.activePath,
    required this.onSelect,
    required this.onClose,
  });

  @override
  State<_EditorTabBar> createState() => _EditorTabBarState();
}

class _EditorTabBarState extends State<_EditorTabBar> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_EditorTabBar old) {
    super.didUpdateWidget(old);
    // Auto-scroll to make the active tab visible when it changes.
    if (old.activePath != widget.activePath && widget.activePath != null) {
      final idx = widget.openTabs.indexOf(widget.activePath!);
      if (idx >= 0 && _scroll.hasClients) {
        // Rough estimate: tabs ~140 px each.
        final target = (idx * 140.0)
            .clamp(0.0, _scroll.position.maxScrollExtent);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.animateTo(
              target,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Listener(
        onPointerSignal: (signal) {
          // Shift+scroll or horizontal wheel support — redirect
          // vertical mouse wheel to horizontal scroll so users on
          // trackpads can swipe through many tabs naturally.
          if (signal is PointerScrollEvent && _scroll.hasClients) {
            final dy = signal.scrollDelta.dy;
            final dx = signal.scrollDelta.dx;
            final delta = dx != 0 ? dx : dy;
            _scroll.jumpTo(
              (_scroll.offset + delta)
                  .clamp(0.0, _scroll.position.maxScrollExtent),
            );
          }
        },
        child: ListView.builder(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          itemCount: widget.openTabs.length,
          itemBuilder: (_, i) {
            final path = widget.openTabs[i];
            return _EditorTab(
              path: path,
              active: path == widget.activePath,
              onSelect: () => widget.onSelect(path),
              onClose: () => widget.onClose(path),
            );
          },
        ),
      ),
    );
  }
}

class _EditorTab extends StatefulWidget {
  final String path;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  const _EditorTab({
    required this.path,
    required this.active,
    required this.onSelect,
    required this.onClose,
  });

  @override
  State<_EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<_EditorTab> {
  bool _hover = false;

  String get _filename {
    final norm = widget.path.replaceAll('\\', '/');
    return norm.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final file = WorkspaceModule().files[widget.path];
    final isDirty = file?.isPending ?? false;
    final showClose = _hover || widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        // Middle-click to close — standard tab UX.
        onTertiaryTapUp: (_) => widget.onClose(),
        child: Container(
          padding: const EdgeInsets.only(left: 10, right: 6),
          decoration: BoxDecoration(
            color: widget.active
                ? c.surface
                : (_hover ? c.surface.withValues(alpha: 0.5) : c.bg),
            border: Border(
              right: BorderSide(color: c.border),
              bottom: BorderSide(
                color: widget.active
                    ? c.accentPrimary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconForExtension(widget.path),
                size: 11,
                color: widget.active ? c.text : c.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                _filename,
                style: GoogleFonts.firaCode(
                  fontSize: 11.5,
                  color: widget.active ? c.text : c.textMuted,
                  fontWeight: widget.active
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 16,
                height: 16,
                child: isDirty && !showClose
                    ? Center(
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.orange,
                          ),
                        ),
                      )
                    : (showClose
                        ? _CloseButton(onTap: widget.onClose)
                        : const SizedBox.shrink()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});
  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: _hover ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 11,
            color: _hover ? c.text : c.textDim,
          ),
        ),
      ),
    );
  }
}

IconData _iconForExtension(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'dart' => Icons.flutter_dash_rounded,
    'py' => Icons.code_rounded,
    'ts' || 'tsx' || 'js' || 'jsx' || 'mjs' => Icons.javascript_rounded,
    'json' || 'yaml' || 'yml' || 'toml' || 'xml' || 'ini' =>
      Icons.data_object_rounded,
    'md' || 'markdown' => Icons.article_outlined,
    'html' || 'htm' => Icons.html_rounded,
    'css' || 'scss' || 'sass' => Icons.palette_outlined,
    'sh' || 'bash' || 'zsh' || 'ps1' || 'bat' => Icons.terminal_rounded,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// Resizable vertical splitter used between the file explorer and
/// the Monaco pane. Visually a 1 px line that thickens + adopts the
/// coral accent on hover to advertise that it's draggable. A 6 px
/// invisible hit zone gives the user a forgiving grab target — the
/// line itself stays 1 px so it doesn't eat layout space.
class _ResizableDivider extends StatefulWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onDragEnd;
  const _ResizableDivider({required this.onDrag, required this.onDragEnd});

  @override
  State<_ResizableDivider> createState() => _ResizableDividerState();
}

class _ResizableDividerState extends State<_ResizableDivider> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: SizedBox(
          // Wide hit zone, slim visual.
          width: 6,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: active ? 2 : 1,
              color: active
                  ? c.accentPrimary.withValues(alpha: 0.6)
                  : c.border,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.description_outlined, size: 32, color: c.textDim),
              const SizedBox(height: 12),
              Text('Select a file',
                  style: GoogleFonts.inter(
                      fontSize: 13, color: c.textMuted)),
              const SizedBox(height: 4),
              Text('Files appear in the explorer as the agent writes them.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final List<(String, String, IconData)> tabs;
  final String active;
  final void Function(String) onTap;
  const _TabBar({
    required this.tabs,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          for (final t in tabs) ...[
            _Tab(
              id: t.$1,
              label: t.$2,
              icon: t.$3,
              active: active == t.$1,
              onTap: () => onTap(t.$1),
            ),
          ],
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String id;
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _Tab({
    required this.id,
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: active ? c.green : Colors.transparent, width: 2),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 12, color: active ? c.green : c.textMuted),
              const SizedBox(width: 6),
              Text(label,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: active ? c.green : c.textMuted,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
