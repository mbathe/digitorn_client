/// VS Code-style file explorer for the Lovable IDE mode.
///
/// Each row shows:
///   • language icon (derived from extension)
///   • relative path
///   • validation dot (yellow = pending, green = approved, red = rejected)
///   • git badge (U / M / M! / !conflict)
///   • gutter `+N -M` when pending changes are non-zero
///   • inline Approve / Reject buttons (visible on hover)
///
/// Header actions:
///   • Approve all (badge with pending count)
///   • Refresh git status
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../main.dart';
import '../../../models/diagnostic.dart';
import '../../../services/app_ui_config_service.dart';
import '../../../services/file_actions_service.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';
import 'commit_dialog.dart';

class CodeExplorer extends StatelessWidget {
  /// Currently selected file — highlighted in the list. Null = none.
  final String? selectedPath;
  final void Function(String path) onSelect;

  const CodeExplorer({
    super.key,
    this.selectedPath,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WorkspaceModule(),
      builder: (context, _) {
        final module = WorkspaceModule();
        final paths = module.sortedPaths;
        final c = context.colors;
        return Container(
          color: c.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(module: module),
              if (paths.isEmpty)
                Expanded(child: _EmptyState())
              else
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: paths.length,
                    itemBuilder: (_, i) {
                      final file = module.files[paths[i]]!;
                      return _FileTile(
                        file: file,
                        selected: file.path == selectedPath,
                        onTap: () => onSelect(file.path),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Header ─────────────────────────────────────────────────────────

class _Header extends StatefulWidget {
  final WorkspaceModule module;
  const _Header({required this.module});

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  @override
  void initState() {
    super.initState();
    FileActionsService().addListener(_onChanged);
    AppUiConfigService().addListener(_onChanged);
  }

  @override
  void dispose() {
    FileActionsService().removeListener(_onChanged);
    AppUiConfigService().removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final actions = FileActionsService();
    final appId = context.read<AppState>().activeApp?.appId ?? '';
    final autoApprove =
        appId.isNotEmpty && AppUiConfigService().isAutoApprove(appId);
    final pending = widget.module.pendingCount;
    final conflicts = widget.module.conflictCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_open_rounded,
                  size: 13, color: c.textMuted),
              const SizedBox(width: 6),
              Text(
                'Files',
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: c.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
              if (autoApprove) ...[
                const SizedBox(width: 6),
                const _AutoApproveChip(),
              ],
              const Spacer(),
              if (widget.module.approvedCount > 0)
                Tooltip(
                  message: 'Commit approved files to git',
                  child: IconButton(
                    iconSize: 13,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 24, minHeight: 24),
                    onPressed: actions.busy
                        ? null
                        : () => showCommitDialog(context),
                    icon: Icon(Icons.commit_rounded, color: c.textDim),
                  ),
                ),
              Tooltip(
                message: 'Refresh git status',
                child: IconButton(
                  iconSize: 13,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 24, minHeight: 24),
                  onPressed:
                      actions.busy ? null : actions.refreshGitStatus,
                  icon: Icon(Icons.refresh_rounded, color: c.textDim),
                ),
              ),
            ],
          ),
          if (!autoApprove && (pending > 0 || conflicts > 0)) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (pending > 0) ...[
                  _ApproveAllButton(
                    pending: pending,
                    busy: actions.busy,
                  ),
                  const SizedBox(width: 6),
                ],
                if (conflicts > 0) _ConflictBadge(count: conflicts),
              ],
            ),
          ],
          if (widget.module.hasFiles) ...[
            const SizedBox(height: 4),
            Text(
              widget.module.globalSummary,
              style:
                  GoogleFonts.firaCode(fontSize: 9.5, color: c.textDim),
            ),
          ],
        ],
      ),
    );
  }
}

/// Gray chip shown when the active app has `auto_approve: true` —
/// tells the user the approve/reject flow is bypassed automatically
/// so they don't wonder why the approve buttons are missing.
class _AutoApproveChip extends StatelessWidget {
  const _AutoApproveChip();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Auto-approve: files are staged immediately on every write.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'AUTO',
          style: GoogleFonts.firaCode(
            fontSize: 8.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: c.textDim,
          ),
        ),
      ),
    );
  }
}

class _ApproveAllButton extends StatelessWidget {
  final int pending;
  final bool busy;
  const _ApproveAllButton({required this.pending, required this.busy});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message:
          'Approve every pending file ($pending) — resets gutter counters',
      child: MouseRegion(
        cursor: busy
            ? SystemMouseCursors.forbidden
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: busy ? null : FileActionsService().approveAll,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: c.green.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_rounded, size: 11, color: c.green),
                const SizedBox(width: 4),
                Text(
                  'Approve all ($pending)',
                  style: GoogleFonts.inter(
                      fontSize: 10.5,
                      color: c.green,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConflictBadge extends StatelessWidget {
  final int count;
  const _ConflictBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Git conflicts — resolve before committing',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: c.red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: c.red.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 11, color: c.red),
            const SizedBox(width: 4),
            Text('$count conflict${count == 1 ? '' : 's'}',
                style: GoogleFonts.inter(
                    fontSize: 10.5,
                    color: c.red,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// ─── File tile ──────────────────────────────────────────────────────

class _FileTile extends StatefulWidget {
  final WorkspaceFile file;
  final bool selected;
  final VoidCallback onTap;
  const _FileTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<_FileTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final file = widget.file;
    final isDeleted = file.isDeleted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered && mounted) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered && mounted) setState(() => _hovered = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          color: widget.selected
              ? c.green.withValues(alpha: 0.1)
              : _hovered
                  ? c.surfaceAlt
                  : Colors.transparent,
          child: Row(
            children: [
              _LanguageIcon(lang: file.language, ext: file.extension),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                    fontSize: 11.5,
                    color: isDeleted ? c.textDim : c.text,
                    decoration: isDeleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              // Gutter counters — "+N -M" when pending. Uses the
              // effective (parsed-from-unified-diff) counts rather
              // than the daemon's `insertions_pending` /
              // `deletions_pending` fields, which scout confirmed
              // are cumulative-since-session-start, not
              // pending-since-baseline.
              if (file.hasPendingChanges) ...[
                const SizedBox(width: 6),
                if (file.pendingInsertionsEffective > 0)
                  Text('+${file.pendingInsertionsEffective}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10,
                          color: c.green,
                          fontWeight: FontWeight.w600)),
                if (file.pendingInsertionsEffective > 0 &&
                    file.pendingDeletionsEffective > 0)
                  const SizedBox(width: 3),
                if (file.pendingDeletionsEffective > 0)
                  Text('-${file.pendingDeletionsEffective}',
                      style: GoogleFonts.firaCode(
                          fontSize: 10,
                          color: c.red,
                          fontWeight: FontWeight.w600)),
              ],
              const SizedBox(width: 6),
              _ValidationDot(file: file),
              _GitBadge(file: file),
              _DiagnosticsDot(path: file.path),
              if (_hovered && !widget.selected)
                _TileActions(file: file)
              else if (widget.selected)
                _TileActions(file: file),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageIcon extends StatelessWidget {
  final String lang;
  final String ext;
  const _LanguageIcon({required this.lang, required this.ext});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _colorFor(lang.isNotEmpty ? lang : ext, c);
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        _letterFor(ext),
        style: GoogleFonts.firaCode(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  static Color _colorFor(String id, AppColors c) {
    switch (id.toLowerCase()) {
      case 'tsx':
      case 'ts':
      case 'typescript':
        return c.blue;
      case 'jsx':
      case 'js':
      case 'javascript':
        return c.orange;
      case 'py':
      case 'python':
        return c.blue;
      case 'dart':
        return c.blue;
      case 'html':
        return c.orange;
      case 'css':
      case 'scss':
        return c.purple;
      case 'json':
      case 'yaml':
      case 'yml':
      case 'toml':
        return c.textMuted;
      case 'md':
      case 'markdown':
      case 'mdx':
        return c.purple;
      case 'tex':
      case 'latex':
        return c.green;
      case 'sql':
        return c.orange;
      default:
        return c.textDim;
    }
  }

  static String _letterFor(String ext) {
    if (ext.isEmpty) return '·';
    return ext.substring(0, 1).toUpperCase();
  }
}

class _ValidationDot extends StatelessWidget {
  final WorkspaceFile file;
  const _ValidationDot({required this.file});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final Color color;
    final String message;
    if (file.isApproved) {
      color = c.green;
      message = 'Approved — safe to commit';
    } else if (file.isRejected) {
      color = c.red;
      message = 'Rejected — will revert on reject()';
    } else if (file.hasPendingChanges) {
      color = c.orange;
      message = 'Pending review (${file.pendingSummary})';
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: message,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4),
                blurRadius: 3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GitBadge extends StatelessWidget {
  final WorkspaceFile file;
  const _GitBadge({required this.file});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final gs = file.gitStatus;
    if (gs == null || gs == 'committed') return const SizedBox.shrink();
    final Color color;
    final String letter;
    final String tooltip;
    switch (gs) {
      case 'untracked':
        color = c.green;
        letter = 'U';
        tooltip = 'Untracked — not in git yet';
      case 'unstaged':
        color = c.red;
        letter = 'M';
        tooltip = 'Modified — unstaged';
      case 'staged':
        color = c.orange;
        letter = 'M';
        tooltip = 'Modified — staged';
      case 'conflict':
        color = c.red;
        letter = '!';
        tooltip = 'Merge conflict';
      case 'ignored':
        color = c.textDim;
        letter = 'I';
        tooltip = 'Ignored by .gitignore';
      default:
        return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 14,
          height: 14,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: gs == 'conflict'
                ? color.withValues(alpha: 0.25)
                : color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            letter,
            style: GoogleFonts.firaCode(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagnosticsDot extends StatelessWidget {
  final String path;
  const _DiagnosticsDot({required this.path});

  @override
  Widget build(BuildContext context) {
    final entry = WorkspaceModule().diagnosticsFor(path);
    if (entry == null || entry.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final worst = entry.severityMax ?? DiagnosticSeverity.info;
    final Color color;
    final String label;
    switch (worst) {
      case DiagnosticSeverity.error:
        color = c.red;
        label = 'errors';
      case DiagnosticSeverity.warning:
        color = c.orange;
        label = 'warnings';
      case DiagnosticSeverity.info:
        color = c.blue;
        label = 'infos';
      case DiagnosticSeverity.hint:
        color = c.textDim;
        label = 'hints';
    }
    final count = entry.items.length;
    final modTag = entry.sourceModuleLabel;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: modTag.isNotEmpty
            ? '$count $label ($modTag) — click to inspect'
            : '$count $label — click to inspect',
        child: Container(
          constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 3,
                    ),
                  ],
                ),
              ),
              if (count > 1) ...[
                const SizedBox(width: 3),
                Text(
                  '$count',
                  style: GoogleFonts.firaCode(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: color,
                    height: 1,
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

class _TileActions extends StatelessWidget {
  final WorkspaceFile file;
  const _TileActions({required this.file});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Hide approve/reject completely when the active app is in
    // auto_approve mode — the daemon stages every write, so the
    // actions would be no-ops that pollute logs (per brief §1).
    final appId = context.read<AppState>().activeApp?.appId ?? '';
    final autoApprove =
        appId.isNotEmpty && AppUiConfigService().isAutoApprove(appId);
    if (autoApprove) return const SizedBox.shrink();
    final isPending = file.isPending;
    final isApproved = file.isApproved;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isPending || isApproved)
          _InlineIcon(
            icon: Icons.check_rounded,
            color: c.green,
            tooltip: 'Approve — snapshot as new baseline',
            onTap: () => FileActionsService().approve(file.path),
          ),
        const SizedBox(width: 2),
        _InlineIcon(
          icon: Icons.close_rounded,
          color: c.red,
          tooltip: 'Reject — revert to last approved',
          onTap: () => FileActionsService().reject(file.path),
        ),
      ],
    );
  }
}

class _InlineIcon extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _InlineIcon({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_InlineIcon> createState() => _InlineIconState();
}

class _InlineIconState extends State<_InlineIcon> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_h && mounted) setState(() => _h = true);
        },
        onExit: (_) {
          if (_h && mounted) setState(() => _h = false);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _h
                  ? widget.color.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(widget.icon, size: 11, color: widget.color),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 28, color: c.textDim),
            const SizedBox(height: 10),
            Text(
              'No files yet',
              style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: c.textMuted,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              'Send a message — the agent writes files here.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 11, color: c.textDim),
            ),
          ],
        ),
      ),
    );
  }
}
