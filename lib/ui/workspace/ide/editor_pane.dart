/// IDE-style editor + diff view for a single workspace file.
///
///   * "Edit" mode — Monaco (the real VS Code editor) embedded via a
///     platform WebView. Windows/Linux use WebView2, mobile uses
///     webview_flutter, web shows a "not supported" placeholder.
///   * "Diff" mode — side-by-side diff between the last approved
///     baseline and the current content, rendered by the shared
///     `LineDiffView`. The diff is computed from
///     `unified_diff_pending` (daemon-side) when available, else
///     reconstructed from `baseline` vs `content` via `computeLineDiff`.
///
/// Auto-reload: watches [FileContentService] — when the agent writes
/// the same path, the editor re-fetches transparently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';

import 'package:provider/provider.dart';

import '../../../main.dart';
import '../../../models/unified_diff_hunk.dart';
import '../../../services/api_client.dart';
import '../../../services/app_ui_config_service.dart';
import '../../../services/file_actions_service.dart';
import '../../../services/file_content_service.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_attach_bridge.dart';
import '../diff/line_diff.dart';
import '../diff/line_diff_view.dart';
import '../diff/unified_diff.dart';
import 'conflict_pane.dart';
import 'file_history_panel.dart';
import 'monaco_editor_pane.dart';

class EditorPane extends StatefulWidget {
  final String path;
  const EditorPane({super.key, required this.path});

  @override
  State<EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends State<EditorPane> {
  bool _diffMode = false;
  bool _conflictMode = false;
  bool _showHistory = false;
  /// When true, Monaco flips to read/write and `onSaveRequest` routes
  /// to [FileActionsService.writeback]. Default off — the agent owns
  /// writes, users opt into manual editing per file.
  bool _editMode = false;
  WorkspaceFileContent? _content;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    debugPrint('EditorPane.initState path=${widget.path}');
    FileContentService().addListener(_onContentChanged);
    AppUiConfigService().addListener(_onConfigChanged);
    _load();
  }

  @override
  void dispose() {
    debugPrint('EditorPane.dispose path=${widget.path}');
    FileContentService().removeListener(_onContentChanged);
    AppUiConfigService().removeListener(_onConfigChanged);
    super.dispose();
  }

  void _onConfigChanged() {
    if (!mounted) return;
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  /// Monaco told us the user hit Ctrl+S or blurred the editor after
  /// editing. Push the buffer back to the daemon. We leave
  /// `autoApprove: false` so the normal approve/reject flow kicks in
  /// (the module-level flag still overrides — auto_approve apps
  /// always land at validation=approved regardless of what we send).
  void _onSaveRequest(String path, String content) {
    if (!mounted) return;
    FileActionsService().writeback(path, content);
  }

  @override
  void didUpdateWidget(EditorPane old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      // DO NOT clear `_content` here — the previous file's content
      // keeps Monaco mounted while the new file loads. Wiping it
      // would flip `_body()` to a spinner (different widget type)
      // which disposes the MonacoEditorPane + its WebView, and
      // remount on load completion re-inits the WebView from
      // scratch (~500 ms) — users see the new file appear only
      // AFTER that round-trip, and any init race during dispose/
      // remount left Monaco blank permanently. Load overlay now
      // sits on top of the old content until new arrives.
      _error = null;
      _load();
    }
  }

  void _onContentChanged() {
    if (!mounted) return;
    // Something upstream invalidated our cache — re-pull.
    _load();
  }

  Future<void> _load() async {
    final target = widget.path;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await FileContentService().load(target);
      if (!mounted) return;
      // Path-guard — the user may have clicked another file while
      // our HTTP was in flight. A stale response landing after them
      // would overwrite `_content` with the old file and trigger
      // Monaco to display content from the wrong path.
      if (widget.path != target) {
        debugPrint('EditorPane._load dropped stale result for $target '
            '(current: ${widget.path})');
        return;
      }
      setState(() {
        _content = res;
        _loading = false;
        _error = res == null ? 'Could not load file content.' : null;
      });
    } catch (e) {
      if (!mounted || widget.path != target) return;
      setState(() {
        _loading = false;
        _error = 'Load failed: $e';
      });
    }
  }

  /// Reconstruct DiffLines using the daemon's unified diff when
  /// available; otherwise compare baseline to content with the local
  /// LCS so edits without a pending diff still render.
  ///
  /// The daemon exposes the same diff under two names depending on
  /// the transport (scout-confirmed on `digitorn-builder`):
  ///   * HTTP `GET …/workspace/files/{path}?include_baseline=true`
  ///     carries it as `unified_diff_pending` at the top level
  ///     (wrapped by `WorkspaceFileContent`).
  ///   * `preview:resource_set` / `preview:resource_patched` events
  ///     carry it as `unified_diff` inside the payload (wrapped by
  ///     `WorkspaceFile`).
  /// Both are byte-for-byte identical when both are present. Try the
  /// HTTP-side field first (the authoritative "pending" marker),
  /// fall through to the preview-side field, then to the local LCS.
  List<DiffLine> _buildDiff(WorkspaceFileContent c) {
    for (final diff in [c.unifiedDiffPending, c.file.unifiedDiff ?? '']) {
      if (diff.isNotEmpty && looksLikeUnifiedDiff(diff)) {
        final parsed = parseUnifiedDiff(diff);
        if (parsed.isNotEmpty) return parsed;
      }
    }
    return chooseDiff(
      previousContent: c.baseline,
      newContent: c.file.content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final content = _content;
    final moduleFile = WorkspaceModule().files[widget.path];
    final appId = context.read<AppState>().activeApp?.appId ?? '';
    final autoApprove =
        appId.isNotEmpty && AppUiConfigService().isAutoApprove(appId);
    // A file is in conflict when the daemon flagged its git_status OR
    // the content still carries `<<<<<<<` markers (e.g. from an agent
    // that didn't finish a merge). Both paths surface the Conflict
    // tab in the header; auto-open on first render.
    final currentContent =
        content?.file.content ?? moduleFile?.content ?? '';
    final hasConflictMarkers =
        currentContent.contains('<<<<<<<') &&
            currentContent.contains('=======') &&
            currentContent.contains('>>>>>>>');
    final gitConflict = moduleFile?.gitStatus == 'conflict';
    final conflictCandidate = hasConflictMarkers || gitConflict;
    return Container(
      color: c.bg,
      child: Column(
        children: [
          _EditorHeader(
            path: widget.path,
            moduleFile: moduleFile,
            content: content?.file.content ?? moduleFile?.content ?? '',
            diffMode: _diffMode,
            canToggleDiff: content != null &&
                content.baseline.isNotEmpty &&
                content.baseline != content.file.content,
            onToggle: () =>
                setState(() => _diffMode = !_diffMode),
            onReload: _load,
            loading: _loading,
            autoApprove: autoApprove,
            showHistory: _showHistory,
            onToggleHistory: () =>
                setState(() => _showHistory = !_showHistory),
            editMode: _editMode,
            onToggleEdit: () =>
                setState(() => _editMode = !_editMode),
            conflictCandidate: conflictCandidate,
            conflictMode: _conflictMode,
            onToggleConflict: () =>
                setState(() => _conflictMode = !_conflictMode),
          ),
          Expanded(
              child: _body(c, content,
                  autoApprove: autoApprove,
                  conflictMode: _conflictMode,
                  conflictSource: currentContent)),
        ],
      ),
    );
  }

  Widget _body(AppColors c, WorkspaceFileContent? content,
      {required bool autoApprove,
      required bool conflictMode,
      required String conflictSource}) {
    // _body() MUST return a Stack whose FIRST child is always the
    // MonacoEditorPane, regardless of loading / error / diff state.
    // If we ever return a different widget type (e.g. Stack vs bare
    // MonacoEditorPane), Flutter disposes the old Monaco and mounts
    // a new one — that disposal cycle is what leaves us with buffered
    // WebView messages hitting defunct States ("setState after
    // dispose" crashes) and a ~500 ms WebView2 re-init per file click.
    // Monaco stays put; everything else is an overlay on top.
    //
    // Content-path guard — if `_content` still holds the PREVIOUS
    // file's data (HTTP for the new path is in flight), pass '' so
    // Monaco clears immediately and doesn't briefly render the new
    // path with stale content from the previous file.
    final matchesCurrent = content != null && content.path == widget.path;
    final monaco = MonacoEditorPane(
      path: widget.path,
      content: matchesCurrent ? content.file.content : '',
      language: matchesCurrent ? content.file.language : '',
      readOnly: !_editMode,
      onSaveRequest: _editMode ? _onSaveRequest : null,
    );

    // Diff overlay takes over the whole surface when active.
    Widget? diffOverlay;
    if (_diffMode && content != null) {
      final diff = _buildDiff(content);
      final unified = content.unifiedDiffPending.isNotEmpty
          ? content.unifiedDiffPending
          : (content.file.unifiedDiff ?? '');
      final hunks = unified.isEmpty
          ? const <UnifiedDiffHunk>[]
          : parseUnifiedDiffHunks(unified);
      final diffView = diff.isEmpty
          ? Container(
              color: c.bg,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(14),
              child: Text(
                'No diff available — content matches the baseline.',
                style: GoogleFonts.inter(fontSize: 12, color: c.textDim),
              ),
            )
          : LineDiffView(diff: diff);
      diffOverlay = Container(
        color: c.bg,
        child: Column(
          children: [
            if (!autoApprove && hunks.isNotEmpty)
              _HunksBar(path: widget.path, hunks: hunks),
            Expanded(child: diffView),
          ],
        ),
      );
    }

    // Error overlay — full-surface card with retry.
    Widget? errorOverlay;
    if (_error != null) {
      errorOverlay = Container(
        color: c.bg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 26, color: c.red),
            const SizedBox(height: 10),
            Text(_error!,
                style: GoogleFonts.inter(fontSize: 12, color: c.text)),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // Conflict overlay — takes over the full surface when active.
    // Rendered on top of the diff overlay so switching to Conflicts
    // mode always wins, regardless of diff toggle state.
    Widget? conflictOverlay;
    if (conflictMode) {
      conflictOverlay = ConflictPane(
        path: widget.path,
        source: conflictSource,
        onResolved: () {
          if (!mounted) return;
          setState(() => _conflictMode = false);
          _load();
        },
      );
    }
    return Stack(
      children: [
        // Monaco is ALWAYS the first child — same widget type
        // across every state, so it is never disposed.
        Positioned.fill(child: monaco),
        // Full-surface overlays (diff / error / conflict) sit on top
        // when set. Conflict wins over diff — explicit user intent
        // to fix the merge supersedes the diff view.
        if (diffOverlay != null && conflictOverlay == null)
          Positioned.fill(child: diffOverlay),
        if (conflictOverlay != null)
          Positioned.fill(child: conflictOverlay),
        if (errorOverlay != null) Positioned.fill(child: errorOverlay),
        // Subtle top-strip loading indicator — overlays the edges
        // of Monaco without eating screen real-estate.
        if (_loading)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: c.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(c.accentPrimary),
            ),
          ),
        // History side-sheet — fixed-width panel pinned to the right
        // edge. Toggled from the header. Keeps the editor surface
        // visible so the user can cross-reference revisions.
        if (_showHistory)
          Positioned(
            top: 6,
            right: 6,
            bottom: 6,
            width: 300,
            child: Material(
              color: Colors.transparent,
              elevation: 4,
              borderRadius: BorderRadius.circular(6),
              child: FileHistoryPanel(path: widget.path),
            ),
          ),
      ],
    );
  }
}

// ─── Per-hunk approve/reject bar ──────────────────────────────────
//
// Shown above the diff view in manual-validation mode when there's
// at least one hunk to review. Each chip carries a stable 12-char
// sha256 hash — preferred over the 0-based index so an agent writing
// in parallel doesn't shift what the user thought they were
// approving.
class _HunksBar extends StatelessWidget {
  final String path;
  final List<UnifiedDiffHunk> hunks;
  const _HunksBar({required this.path, required this.hunks});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.view_stream_rounded, size: 12, color: c.textMuted),
          const SizedBox(width: 6),
          Text(
            '${hunks.length} hunk${hunks.length == 1 ? '' : 's'}',
            style: GoogleFonts.inter(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: c.textMuted,
                letterSpacing: 0.3),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final h in hunks) ...[
                    _HunkChip(path: path, hunk: h),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HunkChip extends StatelessWidget {
  final String path;
  final UnifiedDiffHunk hunk;
  const _HunkChip({required this.path, required this.hunk});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            hunk.header,
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
          ),
          if (hunk.insertions > 0) ...[
            const SizedBox(width: 6),
            Text('+${hunk.insertions}',
                style: GoogleFonts.firaCode(
                    fontSize: 9.5,
                    color: c.green,
                    fontWeight: FontWeight.w600)),
          ],
          if (hunk.deletions > 0) ...[
            const SizedBox(width: 3),
            Text('-${hunk.deletions}',
                style: GoogleFonts.firaCode(
                    fontSize: 9.5,
                    color: c.red,
                    fontWeight: FontWeight.w600)),
          ],
          const SizedBox(width: 6),
          _HunkActionIcon(
            icon: Icons.check_rounded,
            color: c.green,
            tooltip: 'Stage this hunk',
            onTap: () => FileActionsService()
                .approveHunks(path, [hunk.hash]),
          ),
          _HunkActionIcon(
            icon: Icons.undo_rounded,
            color: c.orange,
            tooltip: 'Revert this hunk',
            onTap: () => FileActionsService()
                .rejectHunks(path, [hunk.hash]),
          ),
        ],
      ),
    );
  }
}

class _HunkActionIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _HunkActionIcon({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 12, color: color),
        ),
      ),
    );
  }
}

// ─── Header ─────────────────────────────────────────────────────────

class _EditorHeader extends StatelessWidget {
  final String path;
  final WorkspaceFile? moduleFile;
  /// Current file content — used by the Copy and Download actions.
  /// When empty (file still loading / HTTP miss), those actions are
  /// softly disabled.
  final String content;
  final bool diffMode;
  final bool canToggleDiff;
  final VoidCallback onToggle;
  final VoidCallback onReload;
  final bool loading;
  /// Active app is in auto_approve mode — hide manual approve/reject
  /// actions in the header (they would be no-ops).
  final bool autoApprove;
  final bool showHistory;
  final VoidCallback onToggleHistory;
  final bool editMode;
  final VoidCallback onToggleEdit;
  /// Content has merge markers OR git_status==conflict. Surface the
  /// Conflicts toggle when true; hide when false to avoid noise.
  final bool conflictCandidate;
  final bool conflictMode;
  final VoidCallback onToggleConflict;

  const _EditorHeader({
    required this.path,
    required this.moduleFile,
    required this.content,
    required this.diffMode,
    required this.canToggleDiff,
    required this.onToggle,
    required this.onReload,
    required this.loading,
    required this.autoApprove,
    required this.showHistory,
    required this.onToggleHistory,
    required this.editMode,
    required this.onToggleEdit,
    required this.conflictCandidate,
    required this.conflictMode,
    required this.onToggleConflict,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final file = moduleFile;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined,
                    size: 12, color: c.textMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                      fontSize: 11.5,
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (file != null && file.hasPendingChanges) ...[
            Text(file.pendingSummary,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.orange)),
            const SizedBox(width: 8),
          ],
          // Copy content to clipboard (secondary long-press / right-
          // click falls back to copying the path — see GestureDetector
          // wrapper below).
          _CopyButton(
            path: path,
            content: content,
          ),
          // Download the current file to disk — 100 % client-side,
          // the content is already in memory. On web this triggers a
          // browser download; on desktop a native save-as dialog; on
          // mobile the platform share sheet / documents picker.
          _DownloadButton(
            path: path,
            content: content,
          ),
          // Push the current file into the chat composer as an
          // attachment. Hidden when no chat panel is mounted (e.g.
          // workspace viewed stand-alone via a deep-link route).
          _AddToChatButton(
            path: path,
            content: content,
          ),
          // Diff toggle
          if (canToggleDiff)
            _ToolbarToggle(
              label: 'Diff',
              active: diffMode,
              onTap: onToggle,
            ),
          // Edit toggle — flips Monaco to read/write. On blur or
          // Ctrl+S the buffer is PUT back to the daemon.
          _ToolbarToggle(
            label: editMode ? 'Editing' : 'Edit',
            active: editMode,
            onTap: onToggleEdit,
          ),
          // Conflicts toggle — only shown when markers are detected
          // or the daemon flagged git_status=conflict.
          if (conflictCandidate)
            _ToolbarToggle(
              label: 'Conflicts',
              active: conflictMode,
              onTap: onToggleConflict,
            ),
          // Approve / Reject — hidden in auto_approve mode (the
          // daemon stages every write automatically).
          if (!autoApprove &&
              file != null &&
              (file.isPending || file.isApproved))
            _ToolbarAction(
              icon: Icons.check_rounded,
              color: c.green,
              tooltip: 'Approve file',
              onTap: () => FileActionsService().approve(path),
            ),
          if (!autoApprove && file != null)
            _ToolbarAction(
              icon: Icons.undo_rounded,
              color: c.orange,
              tooltip: 'Reject — revert to baseline',
              onTap: () => FileActionsService().reject(path),
            ),
          // History toggle — shows per-file approval timeline.
          _ToolbarToggle(
            label: 'Hist',
            active: showHistory,
            onTap: onToggleHistory,
          ),
          // Refresh
          if (loading)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.2, color: c.textDim),
            )
          else
            Tooltip(
              message: 'Reload',
              child: IconButton(
                iconSize: 12,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 24, minHeight: 24),
                onPressed: onReload,
                icon: Icon(Icons.refresh_rounded, color: c.textDim),
              ),
            ),
        ],
      ),
    );
  }
}

/// Primary action: copies the file content. Secondary (long-press
/// / right-click) copies the path instead — power-user shortcut that
/// doesn't require a visible second button.
class _CopyButton extends StatefulWidget {
  final String path;
  final String content;
  const _CopyButton({required this.path, required this.content});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _recentlyCopied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _copyContent() {
    if (widget.content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: widget.content));
    _flashFeedback();
  }

  void _copyPath() {
    Clipboard.setData(ClipboardData(text: widget.path));
    _flashFeedback();
  }

  void _flashFeedback() {
    setState(() => _recentlyCopied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _recentlyCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final disabled = widget.content.isEmpty;
    return Tooltip(
      message: disabled
          ? 'File still loading'
          : 'Copy content (right-click → copy path)',
      child: GestureDetector(
        // Right-click / secondary tap → copy path instead.
        onSecondaryTap: _copyPath,
        // Long-press (mobile) → copy path.
        onLongPress: _copyPath,
        child: IconButton(
          iconSize: 12,
          padding: EdgeInsets.zero,
          constraints:
              const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: disabled ? null : _copyContent,
          icon: Icon(
            _recentlyCopied ? Icons.check_rounded : Icons.copy_rounded,
            color: _recentlyCopied
                ? c.green
                : (disabled ? c.textDim.withValues(alpha: 0.4) : c.textDim),
          ),
        ),
      ),
    );
  }
}

/// Download the current file to disk. 100 % client-side:
///   * desktop → native save-as dialog via `file_selector`
///   * mobile → platform share sheet / documents picker
///   * web → browser download via a blob link
///
/// No daemon round-trip — the content is already in memory from the
/// earlier `FileContentService.load` fetch.
class _DownloadButton extends StatelessWidget {
  final String path;
  final String content;
  const _DownloadButton({required this.path, required this.content});

  Future<void> _download(BuildContext context) async {
    if (content.isEmpty) return;
    final filename = path.replaceAll('\\', '/').split('/').last;
    final ext = filename.contains('.') ? filename.split('.').last : '';
    try {
      final location = await getSaveLocation(
        suggestedName: filename,
        acceptedTypeGroups: [
          if (ext.isNotEmpty)
            XTypeGroup(
              label: ext.toUpperCase(),
              extensions: [ext],
            ),
          const XTypeGroup(label: 'All files'),
        ],
      );
      if (location == null) return; // user cancelled
      final bytes = Uint8List.fromList(utf8.encode(content));
      final file = XFile.fromData(
        bytes,
        name: filename,
        mimeType: 'text/plain',
      );
      await file.saveTo(location.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to ${location.path}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final disabled = content.isEmpty;
    return Tooltip(
      message: disabled ? 'File still loading' : 'Download file',
      child: IconButton(
        iconSize: 12,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        onPressed: disabled ? null : () => _download(context),
        icon: Icon(
          Icons.download_rounded,
          color: disabled ? c.textDim.withValues(alpha: 0.4) : c.textDim,
        ),
      ),
    );
  }
}

/// @-mention style button that pushes the current file into the
/// chat composer as an attachment. The LLM then sees the file as
/// context on the next send. Writes the content to a temp file so
/// it reuses the same `_attachments → files: [...]` plumbing the
/// composer already has — no new wire format.
class _AddToChatButton extends StatefulWidget {
  final String path;
  final String content;
  const _AddToChatButton({required this.path, required this.content});

  @override
  State<_AddToChatButton> createState() => _AddToChatButtonState();
}

class _AddToChatButtonState extends State<_AddToChatButton> {
  bool _working = false;

  Future<void> _addToChat() async {
    if (widget.content.isEmpty) return;
    if (!ChatAttachBridge().hasActive) return;
    if (kIsWeb) {
      // Web can't write temp files — would need a data-URI path in
      // the attachments plumbing. Left as a TODO for the web build.
      return;
    }
    setState(() => _working = true);
    try {
      final filename = widget.path.replaceAll('\\', '/').split('/').last;
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final tmpPath =
          '${dir.path}${Platform.pathSeparator}ctx-$stamp-$filename';
      await File(tmpPath)
          .writeAsBytes(utf8.encode(widget.content), flush: true);
      ChatAttachBridge().attach(
        (
          name: filename,
          path: tmpPath,
          isImage: false,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not attach to chat: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Hide when no chat panel is listening — keeps the toolbar
    // uncluttered on the rare standalone-workspace route.
    if (!ChatAttachBridge().hasActive) return const SizedBox.shrink();
    final disabled = widget.content.isEmpty || _working;
    return Tooltip(
      message: disabled ? 'File still loading' : 'Add file to chat context',
      child: IconButton(
        iconSize: 12,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        onPressed: disabled ? null : _addToChat,
        icon: _working
            ? SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.3,
                  color: c.textDim,
                ),
              )
            : Icon(
                Icons.alternate_email_rounded,
                color: disabled
                    ? c.textDim.withValues(alpha: 0.4)
                    : c.textDim,
              ),
      ),
    );
  }
}

class _ToolbarToggle extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToolbarToggle(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: active
                  ? c.green.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                  color: active
                      ? c.green.withValues(alpha: 0.5)
                      : c.border),
            ),
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                color: active ? c.green : c.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _ToolbarAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          iconSize: 12,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: onTap,
          icon: Icon(icon, color: color),
        ),
      ),
    );
  }
}
