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

class CodeExplorer extends StatefulWidget {
  /// Currently selected file — highlighted in the list. Null = none.
  final String? selectedPath;
  final void Function(String path) onSelect;

  const CodeExplorer({
    super.key,
    this.selectedPath,
    required this.onSelect,
  });

  @override
  State<CodeExplorer> createState() => _CodeExplorerState();
}

class _CodeExplorerState extends State<CodeExplorer> {
  /// Directories the user has explicitly collapsed — everything else
  /// starts expanded so the hierarchy is visible at a glance.
  final Set<String> _collapsed = <String>{};

  void _toggleDir(String path) {
    setState(() {
      if (_collapsed.contains(path)) {
        _collapsed.remove(path);
      } else {
        _collapsed.add(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WorkspaceModule(),
      builder: (context, _) {
        final module = WorkspaceModule();
        final paths = module.sortedPaths;
        final c = context.colors;
        final tree = _buildFileTree(
          module,
          paths,
          collapsed: _collapsed,
        );
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
                    itemCount: tree.rows.length,
                    itemBuilder: (_, i) {
                      final row = tree.rows[i];
                      if (row.isDir) {
                        return _DirRow(
                          name: row.name,
                          path: row.fullPath,
                          depth: row.depth,
                          expanded: !_collapsed.contains(row.fullPath),
                          onTap: () => _toggleDir(row.fullPath),
                        );
                      }
                      final file = row.file!;
                      return _FileTile(
                        file: file,
                        selected: file.path == widget.selectedPath,
                        onTap: () => widget.onSelect(file.path),
                        depth: row.depth,
                        displayName: row.name,
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

// ─── Tree model ──────────────────────────────────────────────────────
//
// We flatten the hierarchy into a list of [_ExplorerRow] entries, in
// render order, so [ListView.builder] stays trivially efficient. Each
// row knows its depth — used by [_IndentGuide] to draw VS Code-style
// vertical rails that span the whole column.

class _ExplorerRow {
  final String name;
  final String fullPath;
  final int depth;
  final bool isDir;
  final WorkspaceFile? file;
  const _ExplorerRow._({
    required this.name,
    required this.fullPath,
    required this.depth,
    required this.isDir,
    this.file,
  });

  factory _ExplorerRow.dir(String name, String fullPath, int depth) =>
      _ExplorerRow._(
          name: name, fullPath: fullPath, depth: depth, isDir: true);

  factory _ExplorerRow.file(String name, WorkspaceFile file, int depth) =>
      _ExplorerRow._(
          name: name,
          fullPath: file.path,
          depth: depth,
          isDir: false,
          file: file);
}

class _TreeLayout {
  final List<_ExplorerRow> rows;
  const _TreeLayout(this.rows);
}

_TreeLayout _buildFileTree(
  WorkspaceModule module,
  List<String> paths, {
  required Set<String> collapsed,
}) {
  if (paths.isEmpty) return const _TreeLayout([]);

  // Normalize + split once.
  final items = paths.map((p) {
    final norm = p.replaceAll('\\', '/');
    final segs = norm.split('/').where((s) => s.isNotEmpty).toList();
    return (norm: norm, segs: segs, original: p);
  }).toList();

  // Longest common directory prefix (everything but the filename).
  int common = items.first.segs.length - 1;
  if (common < 0) common = 0;
  for (final it in items.skip(1)) {
    final cap = [
      common,
      it.segs.length - 1,
      items.first.segs.length - 1,
    ].reduce((a, b) => a < b ? a : b);
    var match = 0;
    while (match < cap && it.segs[match] == items.first.segs[match]) {
      match++;
    }
    common = match;
    if (common == 0) break;
  }

  // Build a trie of directory nodes keyed by their accumulated path.
  final dirChildren = <String, List<_TreeBuildNode>>{};
  final dirOrder = <String>[];
  final rootKey = items.first.segs.take(common).join('/');

  void addDirOnce(String key) {
    if (!dirChildren.containsKey(key)) {
      dirChildren[key] = [];
      dirOrder.add(key);
    }
  }

  addDirOnce(rootKey);

  for (final it in items) {
    final rel = it.segs.sublist(common);
    if (rel.isEmpty) continue;
    var parentKey = rootKey;
    for (var i = 0; i < rel.length; i++) {
      final seg = rel[i];
      final isLast = i == rel.length - 1;
      final childKey = parentKey.isEmpty ? seg : '$parentKey/$seg';
      if (isLast) {
        final file = module.files[it.original];
        if (file != null) {
          dirChildren[parentKey]!.add(
            _TreeBuildNode(name: seg, fullPath: it.original, file: file),
          );
        }
      } else {
        addDirOnce(childKey);
        final existing = dirChildren[parentKey]!
            .firstWhere((n) => n.isDir && n.fullPath == childKey,
                orElse: () => _TreeBuildNode.empty());
        if (existing.isEmpty) {
          dirChildren[parentKey]!.add(
            _TreeBuildNode(name: seg, fullPath: childKey, isDir: true),
          );
        }
      }
      parentKey = childKey;
    }
  }

  // Sort each directory: dirs first, then files, both alpha — but only
  // within directories. The file order WITHIN the flat original
  // `sortedPaths` (recent-first) is preserved for siblings of the same
  // directory through [module.sortedPaths] seeding the walk above, and
  // we re-stabilise alphabetically at the directory level below to
  // make "parent folders on top, children nested beneath" predictable.
  for (final k in dirOrder) {
    dirChildren[k]!.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  // Walk the trie depth-first and emit rows.
  final rows = <_ExplorerRow>[];
  final rootName =
      common > 0 ? items.first.segs.take(common).last : 'workspace';
  rows.add(_ExplorerRow.dir(rootName, rootKey, 0));

  void emit(String dirKey, int depth) {
    if (collapsed.contains(dirKey)) return;
    for (final n in dirChildren[dirKey] ?? const <_TreeBuildNode>[]) {
      if (n.isDir) {
        rows.add(_ExplorerRow.dir(n.name, n.fullPath, depth));
        emit(n.fullPath, depth + 1);
      } else {
        rows.add(_ExplorerRow.file(n.name, n.file!, depth));
      }
    }
  }
  emit(rootKey, 1);

  return _TreeLayout(rows);
}

class _TreeBuildNode {
  final String name;
  final String fullPath;
  final bool isDir;
  final WorkspaceFile? file;
  final bool isEmpty;
  const _TreeBuildNode({
    required this.name,
    required this.fullPath,
    this.isDir = false,
    this.file,
  }) : isEmpty = false;
  const _TreeBuildNode.empty()
      : name = '',
        fullPath = '',
        isDir = false,
        file = null,
        isEmpty = true;
}

// ─── Indent guide ──────────────────────────────────────────────────
//
// Thin vertical line rendered once per indent level. Stacked across
// rows (all rows share the same row height) they form continuous
// rails that mimic VS Code's explorer.

class _IndentGuide extends StatelessWidget {
  const _IndentGuide();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 14,
      child: Center(
        child: SizedBox(
          width: 1,
          child: ColoredBox(color: c.border.withValues(alpha: 0.55)),
        ),
      ),
    );
  }
}

// ─── Directory row ──────────────────────────────────────────────────

class _DirRow extends StatefulWidget {
  final String name;
  final String path;
  final int depth;
  final bool expanded;
  final VoidCallback onTap;
  const _DirRow({
    required this.name,
    required this.path,
    required this.depth,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_DirRow> createState() => _DirRowState();
}

class _DirRowState extends State<_DirRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
        child: Container(
          height: 22,
          color: _hovered ? c.surfaceAlt : Colors.transparent,
          child: Row(
            children: [
              for (int i = 0; i < widget.depth; i++) const _IndentGuide(),
              const SizedBox(width: 4),
              Icon(
                widget.expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.chevron_right_rounded,
                size: 14,
                color: c.textMuted,
              ),
              Icon(
                widget.expanded
                    ? Icons.folder_open_rounded
                    : Icons.folder_rounded,
                size: 13,
                color: c.orange,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: c.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
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
  final int depth;
  final String? displayName;
  const _FileTile({
    required this.file,
    required this.selected,
    required this.onTap,
    this.depth = 0,
    this.displayName,
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
    final label = widget.displayName ?? file.path;
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
          height: 22,
          padding: const EdgeInsets.only(right: 10),
          color: widget.selected
              ? c.green.withValues(alpha: 0.1)
              : _hovered
                  ? c.surfaceAlt
                  : Colors.transparent,
          child: Row(
            children: [
              for (int i = 0; i < widget.depth; i++) const _IndentGuide(),
              // Chevron placeholder so filenames align under directory
              // expand icons.
              const SizedBox(width: 4 + 14),
              _LanguageIcon(lang: file.language, ext: file.extension),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                    fontSize: 11.5,
                    color: isDeleted ? c.textDim : c.text,
                    decoration: isDeleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              // Gutter counters — "+N -M". The WorkspaceModule
              // tracks these client-side by summing per-op
              // insertions/deletions across consecutive writes (see
              // `_updatePendingAggregate`). This replaces the
              // daemon's `insertions_pending` / `deletions_pending`
              // fields, which on several builds reset to the last
              // operation's count instead of accumulating.
              Builder(builder: (ctx) {
                final mod = WorkspaceModule();
                final ins = mod.pendingInsertionsFor(file.path);
                final del = mod.pendingDeletionsFor(file.path);
                if (ins <= 0 && del <= 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ins > 0)
                        Text('+$ins',
                            style: GoogleFonts.firaCode(
                                fontSize: 10,
                                color: c.green,
                                fontWeight: FontWeight.w600)),
                      if (ins > 0 && del > 0)
                        const SizedBox(width: 3),
                      if (del > 0)
                        Text('-$del',
                            style: GoogleFonts.firaCode(
                                fontSize: 10,
                                color: c.red,
                                fontWeight: FontWeight.w600)),
                    ],
                  ),
                );
              }),
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
    // Hide approve/reject completely when the active app is in
    // auto_approve mode — the daemon stages every write, so the
    // actions would be no-ops that pollute logs (per brief §1).
    final appId = context.read<AppState>().activeApp?.appId ?? '';
    final autoApprove =
        appId.isNotEmpty && AppUiConfigService().isAutoApprove(appId);
    if (autoApprove) return const SizedBox.shrink();

    // Hide both buttons when there's nothing to review. An already-
    // approved file with no fresh edits since the last approval is
    // "clean" — re-approving / rejecting it would be a no-op that
    // just clutters the row. We only surface the actions the moment
    // the agent introduces new pending changes.
    final needsReview = file.isPending || file.hasPendingChanges;
    if (!needsReview) return const SizedBox.shrink();

    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
