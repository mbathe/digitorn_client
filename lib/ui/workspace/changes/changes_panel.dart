import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../services/workspace_service.dart';
import '../../../theme/app_theme.dart';
import '../diff/line_diff.dart';
import '../diff/line_diff_view.dart';
import '../diff/unified_diff.dart';

/// "Changes" tab of the workspace — a unified view of every buffer
/// that differs from its baseline, with per-file collapsible diffs.
///
/// This is the "what did the agent just do?" panel: one card per
/// modified file, each card has a header with the filename + inline
/// stats (`+34 -12`) + action badge (A/M/D/R), and expands on click
/// to reveal the full line-based diff.
///
/// Data source is [WorkspaceService.buffers]. A buffer is considered
/// "changed" when [WorkbenchBuffer.isEdited] is true. The computation
/// of the diff itself is delegated to the shared `diff/` module so it
/// stays consistent with the single-file view in the code editor.
class ChangesPanel extends StatefulWidget {
  final WorkspaceService ws;
  const ChangesPanel({super.key, required this.ws});

  @override
  State<ChangesPanel> createState() => _ChangesPanelState();
}

enum _ChangeFilter { all, modified, added, deleted }

class _ChangesPanelState extends State<ChangesPanel> {
  _ChangeFilter _filter = _ChangeFilter.all;
  _SortMode _sort = _SortMode.byPath;

  // Per-file card expansion state, keyed by buffer.path.
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    widget.ws.addListener(_onWsChanged);
  }

  @override
  void dispose() {
    widget.ws.removeListener(_onWsChanged);
    super.dispose();
  }

  void _onWsChanged() {
    if (mounted) setState(() {});
  }

  // ── Data selection ───────────────────────────────────────────────────

  /// The list of changed buffers, filtered & sorted for display.
  /// A buffer counts as "changed" only when it has pending changes
  /// vs the last approved baseline (scout-verified BUG #1 fix).
  /// A buffer that was only ever approved — even if its session-
  /// cumulative totals are huge — no longer shows up here.
  List<WorkbenchBuffer> _changedBuffers() {
    final all = widget.ws.buffers.where(_matchesFilter).toList();
    switch (_sort) {
      case _SortMode.byPath:
        all.sort((a, b) => a.path.compareTo(b.path));
        break;
      case _SortMode.byMostChanges:
        all.sort((a, b) {
          return (b.pendingInsertions + b.pendingDeletions)
              .compareTo(a.pendingInsertions + a.pendingDeletions);
        });
        break;
    }
    return all;
  }

  bool _matchesFilter(WorkbenchBuffer b) {
    final hasPending = b.pendingInsertions > 0 ||
        b.pendingDeletions > 0 ||
        b.unifiedDiffPending.isNotEmpty;
    // Fall back to the legacy `isEdited` flag when the projection
    // hasn't been wired (still true for a few legacy call-sites).
    if (!hasPending && !b.isEdited) return false;
    final isNew = b.previousContent.isEmpty &&
        b.pendingDeletions == 0 &&
        b.unifiedDiffPending.isEmpty;
    switch (_filter) {
      case _ChangeFilter.all:
        return true;
      case _ChangeFilter.added:
        return isNew;
      case _ChangeFilter.modified:
        return !isNew;
      case _ChangeFilter.deleted:
        return false; // We don't currently track removed buffers here.
    }
  }

  // Global totals across every filtered buffer. Uses PENDING
  // counters (delta vs last-approved baseline) so the "+X -Y in N
  // files" header reflects what still needs a review / approve —
  // not the cumulative history since session start.
  ({int additions, int deletions, int files}) _totals(
      List<WorkbenchBuffer> bufs) {
    var add = 0, del = 0;
    for (final b in bufs) {
      add += b.pendingInsertions;
      del += b.pendingDeletions;
    }
    return (additions: add, deletions: del, files: bufs.length);
  }

  void _toggle(String path) {
    setState(() {
      if (_collapsed.contains(path)) {
        _collapsed.remove(path);
      } else {
        _collapsed.add(path);
      }
    });
  }

  void _expandAll(List<WorkbenchBuffer> bufs) {
    setState(_collapsed.clear);
  }

  void _collapseAll(List<WorkbenchBuffer> bufs) {
    setState(() {
      _collapsed.clear();
      _collapsed.addAll(bufs.map((b) => b.path));
    });
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bufs = _changedBuffers();
    final totals = _totals(bufs);

    return Container(
      color: c.bg,
      child: Column(
        children: [
          _buildHeader(c, totals),
          Container(height: 1, color: c.border),
          _buildFilterRow(c, bufs),
          Container(height: 1, color: c.border),
          Expanded(child: _buildList(c, bufs)),
        ],
      ),
    );
  }

  Widget _buildHeader(AppColors c, ({int additions, int deletions, int files}) t) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: c.surface,
      child: Row(
        children: [
          Icon(Icons.difference_rounded, size: 14, color: c.green),
          const SizedBox(width: 8),
          Text(
            'Changes',
            style: GoogleFonts.inter(
                fontSize: 12,
                color: c.text,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          if (t.files == 0)
            Text(
              'no changes',
              style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
            )
          else ...[
            _Stat(
              label: '+${t.additions}',
              color: c.green,
            ),
            const SizedBox(width: 6),
            _Stat(
              label: '-${t.deletions}',
              color: c.red,
            ),
            const SizedBox(width: 8),
            Text(
              'in ${t.files} ${t.files == 1 ? "file" : "files"}',
              style:
                  GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
            ),
          ],
          const Spacer(),
          _SortDropdown(
            sort: _sort,
            onChanged: (m) => setState(() => _sort = m),
          ),
          const SizedBox(width: 6),
          _ChangesIconBtn(
            icon: Icons.unfold_more_rounded,
            tooltip: 'Expand all',
            onTap: t.files == 0 ? null : () => _expandAll(_changedBuffers()),
          ),
          _ChangesIconBtn(
            icon: Icons.unfold_less_rounded,
            tooltip: 'Collapse all',
            onTap: t.files == 0 ? null : () => _collapseAll(_changedBuffers()),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(AppColors c, List<WorkbenchBuffer> bufs) {
    final added = bufs.where((b) => b.previousContent.isEmpty).length;
    final modified = bufs.length - added;

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.bg,
      child: Row(
        children: [
          _FilterChip(
            label: 'All',
            active: _filter == _ChangeFilter.all,
            count: bufs.length,
            color: c.text,
            onTap: () => setState(() => _filter = _ChangeFilter.all),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: 'Modified',
            active: _filter == _ChangeFilter.modified,
            count: modified,
            color: c.orange,
            onTap: () =>
                setState(() => _filter = _ChangeFilter.modified),
          ),
          const SizedBox(width: 6),
          _FilterChip(
            label: 'Added',
            active: _filter == _ChangeFilter.added,
            count: added,
            color: c.green,
            onTap: () =>
                setState(() => _filter = _ChangeFilter.added),
          ),
        ],
      ),
    );
  }

  Widget _buildList(AppColors c, List<WorkbenchBuffer> bufs) {
    if (bufs.isEmpty) {
      return _buildEmpty(c);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      itemCount: bufs.length,
      itemBuilder: (_, i) {
        final buf = bufs[i];
        final collapsed = _collapsed.contains(buf.path);
        return _FileChangeCard(
          buffer: buf,
          collapsed: collapsed,
          onToggle: () => _toggle(buf.path),
        );
      },
    );
  }

  Widget _buildEmpty(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.difference_outlined, size: 36, color: c.textMuted),
          const SizedBox(height: 12),
          Text(
            'No changes',
            style: GoogleFonts.inter(
                fontSize: 13,
                color: c.textMuted,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Text(
            'Files the agent modifies will appear here\nwith a per-file diff.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
                fontSize: 11, color: c.textDim, height: 1.5),
          ),
        ],
      ),
    );
  }
}

enum _SortMode { byPath, byMostChanges }

// ─── File card ─────────────────────────────────────────────────────────────

class _FileChangeCard extends StatelessWidget {
  final WorkbenchBuffer buffer;
  final bool collapsed;
  final VoidCallback onToggle;
  const _FileChangeCard({
    required this.buffer,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Per-file stats come from the PENDING counters so the card
    // header matches the diff body below (both are delta vs the
    // last approved baseline, not session-cumulative totals).
    final stats = (
      insertions: buffer.pendingInsertions,
      deletions: buffer.pendingDeletions,
    );
    final isNew = buffer.previousContent.isEmpty &&
        buffer.pendingDeletions == 0;
    final (actionLabel, actionColor) = isNew
        ? ('ADDED', c.green)
        : ('MODIFIED', c.orange);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            buffer: buffer,
            collapsed: collapsed,
            onToggle: onToggle,
            stats: stats,
            actionLabel: actionLabel,
            actionColor: actionColor,
          ),
          if (!collapsed) ...[
            Container(height: 1, color: c.border),
            _DiffBody(buffer: buffer),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatefulWidget {
  final WorkbenchBuffer buffer;
  final bool collapsed;
  final VoidCallback onToggle;
  final ({int insertions, int deletions}) stats;
  final String actionLabel;
  final Color actionColor;

  const _Header({
    required this.buffer,
    required this.collapsed,
    required this.onToggle,
    required this.stats,
    required this.actionLabel,
    required this.actionColor,
  });

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final buf = widget.buffer;
    final directory = _directoryOf(buf.path);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onToggle,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          color: _hover ? c.surfaceAlt.withValues(alpha: 0.5) : null,
          child: Row(
            children: [
              Icon(
                widget.collapsed
                    ? Icons.keyboard_arrow_right_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: c.textMuted,
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.insert_drive_file_outlined,
                size: 12,
                color: c.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                buf.filename,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    color: c.text,
                    fontWeight: FontWeight.w600),
              ),
              if (directory.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    directory,
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textDim),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(width: 10),
              _Stat(
                label: '+${widget.stats.insertions}',
                color: c.green,
              ),
              const SizedBox(width: 4),
              _Stat(
                label: '-${widget.stats.deletions}',
                color: c.red,
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: widget.actionColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                      color: widget.actionColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  widget.actionLabel,
                  style: GoogleFonts.firaCode(
                      fontSize: 9,
                      color: widget.actionColor,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _directoryOf(String path) {
    final p = path.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i > 0 ? p.substring(0, i) : '';
  }
}

class _DiffBody extends StatelessWidget {
  final WorkbenchBuffer buffer;
  const _DiffBody({required this.buffer});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // The daemon's `unified_diff_pending` is the AGGREGATE diff vs
    // the last approved baseline. It accumulates every write since
    // approve (scout-verified: 3 consecutive edits → diff shows
    // all 6 line changes, not just the last 2). Parse it with the
    // shared unified-diff helper so the view matches what the
    // editor pane shows in Diff mode.
    final pending = buffer.unifiedDiffPending;
    List<DiffLine> diff;
    if (pending.isNotEmpty && looksLikeUnifiedDiff(pending)) {
      diff = parseUnifiedDiff(pending);
    } else {
      // Legacy fallback — the daemon didn't ship a pending diff but
      // the caller still passed a previousContent anchor. Very rare
      // in practice (our projector sets previousContent=''), but
      // keeps the view robust for off-path call sites.
      diff = computeLineDiff(buffer.previousContent, buffer.content);
    }
    if (diff.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          'No textual changes detected.',
          style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 480),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: LineDiffView(diff: diff, scrollable: false),
      ),
    );
  }
}

// ─── Small widgets ─────────────────────────────────────────────────────────

class _Stat extends StatelessWidget {
  final String label;
  final Color color;
  const _Stat({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: GoogleFonts.firaCode(
          fontSize: 11, color: color, fontWeight: FontWeight.w600),
    );
  }
}

class _FilterChip extends StatefulWidget {
  final String label;
  final bool active;
  final int count;
  final Color color;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.active,
    required this.count,
    required this.color,
    required this.onTap,
  });

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? widget.color.withValues(alpha: _h ? 0.22 : 0.16)
                : (_h ? c.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active
                  ? widget.color.withValues(alpha: 0.35)
                  : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: active ? widget.color : c.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${widget.count}',
                style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: active ? widget.color : c.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  final _SortMode sort;
  final ValueChanged<_SortMode> onChanged;
  const _SortDropdown({required this.sort, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Sort by',
      child: PopupMenuButton<_SortMode>(
        initialValue: sort,
        onSelected: onChanged,
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: c.border),
        ),
        position: PopupMenuPosition.under,
        itemBuilder: (_) => [
          _sortItem(_SortMode.byPath, 'By path', Icons.sort_by_alpha_rounded),
          _sortItem(_SortMode.byMostChanges, 'Most changes',
              Icons.bar_chart_rounded),
        ],
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sort_rounded, size: 12, color: c.textMuted),
              const SizedBox(width: 4),
              Text(
                sort == _SortMode.byPath ? 'path' : 'changes',
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<_SortMode> _sortItem(
      _SortMode mode, String label, IconData icon) {
    return PopupMenuItem(
      value: mode,
      height: 32,
      child: Builder(
        builder: (ctx) {
          final c = ctx.colors;
          return Row(
            children: [
              Icon(icon, size: 12, color: c.textMuted),
              const SizedBox(width: 8),
              Text(label,
                  style: GoogleFonts.inter(fontSize: 11, color: c.text)),
            ],
          );
        },
      ),
    );
  }
}

class _ChangesIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const _ChangesIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ChangesIconBtn> createState() => _ChangesIconBtnState();
}

class _ChangesIconBtnState extends State<_ChangesIconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.onTap != null;
    final color = enabled
        ? (_h ? c.text : c.textMuted)
        : c.textDim;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _h && enabled ? c.surfaceAlt : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(widget.icon, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}
