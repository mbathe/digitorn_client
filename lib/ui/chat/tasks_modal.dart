import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../design/tokens.dart';
import '../../main.dart';
import '../../services/background_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';

enum _TaskFilter { all, running, done, failed }

extension _TaskFilterX on _TaskFilter {
  String get label => switch (this) {
        _TaskFilter.all => 'All',
        _TaskFilter.running => 'Running',
        _TaskFilter.done => 'Done',
        _TaskFilter.failed => 'Failed',
      };
}

/// Premium inline background-tasks panel. Keeps the composer width,
/// same card chrome as the Tools / Context / Snippets panels.
///
/// Adds over the previous version:
///   * filter tabs (All / Running / Done / Failed) with live counts
///   * sort: running first, then newest. Stable within each bucket.
///   * tap a row to expand its full output in place — no 200-char
///     truncation.
///   * premium coral/accent chrome aligned with the rest of the
///     composer surface.
class TasksPanel extends StatefulWidget {
  final VoidCallback onClose;
  const TasksPanel({super.key, required this.onClose});

  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel> {
  _TaskFilter _filter = _TaskFilter.all;
  final Set<String> _expanded = <String>{};

  int _countFor(_TaskFilter f, List<BackgroundTask> all) {
    switch (f) {
      case _TaskFilter.all:
        return all.length;
      case _TaskFilter.running:
        return all.where((t) => t.isRunning).length;
      case _TaskFilter.done:
        return all.where((t) => t.status == 'completed').length;
      case _TaskFilter.failed:
        return all
            .where((t) =>
                t.status == 'failed' || t.status == 'cancelled')
            .length;
    }
  }

  List<BackgroundTask> _apply(_TaskFilter f, List<BackgroundTask> all) {
    final filtered = switch (f) {
      _TaskFilter.all => all.toList(),
      _TaskFilter.running => all.where((t) => t.isRunning).toList(),
      _TaskFilter.done =>
        all.where((t) => t.status == 'completed').toList(),
      _TaskFilter.failed => all
          .where((t) =>
              t.status == 'failed' || t.status == 'cancelled')
          .toList(),
    };
    // Running first, then newest by elapsed (approx). Stable when
    // tasks don't carry a real timestamp — bucket by running state.
    filtered.sort((a, b) {
      if (a.isRunning != b.isRunning) return a.isRunning ? -1 : 1;
      final ae = a.elapsed ?? 0;
      final be = b.elapsed ?? 0;
      return be.compareTo(ae);
    });
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = context.watch<BackgroundService>();
    final tasks = bg.tasks;
    final list = _apply(_filter, tasks);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(DsRadius.card),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: c.shadow,
            blurRadius: 20,
            spreadRadius: -4,
            offset: const Offset(0, -4),
          ),
          BoxShadow(
            color: c.accentPrimary.withValues(alpha: 0.05),
            blurRadius: 30,
            spreadRadius: -10,
          ),
        ],
      ),
      // Content-driven height: no tasks → tiny panel with just the
      // empty-state hint. A dozen tasks → panel grows naturally.
      // Beyond _maxListHeight, the list scrolls inside the panel so
      // the composer never gets pushed off the screen.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            total: tasks.length,
            runningCount: bg.activeCount,
            onClose: widget.onClose,
            onClearDone: tasks.any((t) => t.isDone) ? bg.clearCompleted : null,
          ),
          _FilterBar(
            current: _filter,
            counts: {
              for (final f in _TaskFilter.values) f: _countFor(f, tasks),
            },
            onChange: (f) => setState(() => _filter = f),
          ),
          Container(height: 1, color: c.border),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: list.isEmpty
                ? _EmptyState(filter: _filter, colors: c)
                : SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < list.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              indent: 12,
                              endIndent: 12,
                              color:
                                  c.border.withValues(alpha: 0.5),
                            ),
                          _TaskRow(
                            task: list[i],
                            expanded: _expanded.contains(list[i].id),
                            onToggle: () {
                              setState(() {
                                final id = list[i].id;
                                if (!_expanded.remove(id)) {
                                  _expanded.add(id);
                                }
                              });
                            },
                          ),
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

// ═══════════════════════════════════════════════════════════════════════════
// HEADER
// ═══════════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final int total;
  final int runningCount;
  final VoidCallback onClose;
  final VoidCallback? onClearDone;
  const _Header({
    required this.total,
    required this.runningCount,
    required this.onClose,
    this.onClearDone,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  c.accentPrimary,
                  Color.lerp(c.accentPrimary, c.accentSecondary, 0.55) ??
                      c.accentPrimary,
                ],
              ),
              borderRadius: BorderRadius.circular(DsRadius.xs),
            ),
            child: Icon(Icons.terminal_rounded, size: 14, color: c.onAccent),
          ),
          const SizedBox(width: 10),
          Text(
            'Background tasks',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: c.textBright,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(width: 8),
          if (runningCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.accentPrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(DsRadius.pill),
                border: Border.all(
                    color: c.accentPrimary.withValues(alpha: 0.3)),
              ),
              child: Text(
                '$runningCount running',
                style: GoogleFonts.firaCode(
                  fontSize: 9.5,
                  color: c.accentPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(DsRadius.pill),
                border: Border.all(color: c.border),
              ),
              child: Text(
                '$total',
                style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: c.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const Spacer(),
          if (onClearDone != null)
            _TextBtn(
              icon: Icons.clear_all_rounded,
              label: 'Clear done',
              onTap: onClearDone!,
            ),
          const SizedBox(width: 4),
          _TinyBtn(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// FILTER BAR
// ═══════════════════════════════════════════════════════════════════════════

class _FilterBar extends StatelessWidget {
  final _TaskFilter current;
  final Map<_TaskFilter, int> counts;
  final ValueChanged<_TaskFilter> onChange;
  const _FilterBar({
    required this.current,
    required this.counts,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(DsRadius.input),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            for (final f in _TaskFilter.values)
              Expanded(
                child: _FilterTab(
                  label: f.label,
                  count: counts[f] ?? 0,
                  selected: current == f,
                  onTap: () => onChange(f),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterTab extends StatefulWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const _FilterTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_FilterTab> createState() => _FilterTabState();
}

class _FilterTabState extends State<_FilterTab> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? c.surface
                : _h
                    ? c.surfaceAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs - 2),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: c.shadow,
                      blurRadius: 6,
                      spreadRadius: -2,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? c.textBright : c.textMuted,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${widget.count}',
                style: GoogleFonts.firaCode(
                  fontSize: 9.5,
                  color: active ? c.accentPrimary : c.textDim,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TASK ROW
// ═══════════════════════════════════════════════════════════════════════════

class _TaskRow extends StatelessWidget {
  final BackgroundTask task;
  final bool expanded;
  final VoidCallback onToggle;
  const _TaskRow({
    required this.task,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (IconData icon, Color color, String statusLabel) =
        switch (task.status) {
      'running' || 'progress' =>
        (Icons.sync_rounded, c.accentPrimary, 'Running'),
      'completed' => (Icons.check_circle_rounded, c.green, 'Done'),
      'failed' => (Icons.error_rounded, c.red, 'Failed'),
      'cancelled' => (Icons.cancel_rounded, c.textMuted, 'Cancelled'),
      _ => (Icons.schedule_rounded, c.textMuted, task.status),
    };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: task.isRunning
                        ? CircularProgressIndicator(
                            strokeWidth: 1.5,
                            valueColor: AlwaysStoppedAnimation(color),
                          )
                        : Icon(icon, size: 14, color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      task.command.isNotEmpty ? task.command : task.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                        fontSize: 11.5,
                        color: c.textBright,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (task.elapsed != null && task.elapsed! > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      task.elapsedLabel,
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textDim),
                    ),
                  ],
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: DsDuration.fast,
                    child: Icon(Icons.expand_more_rounded,
                        size: 15, color: c.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const SizedBox(width: 26),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: color.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      statusLabel.toUpperCase(),
                      style: GoogleFonts.firaCode(
                        fontSize: 8.5,
                        color: color,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  if (task.exitCode != null && task.exitCode != 0) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Exit code ${task.exitCode}',
                      child: Text('exit ${task.exitCode}',
                          style: GoogleFonts.firaCode(
                              fontSize: 9.5, color: c.red)),
                    ),
                  ],
                  if (task.pid != null) ...[
                    const SizedBox(width: 6),
                    Text('PID ${task.pid}',
                        style: GoogleFonts.firaCode(
                            fontSize: 9.5, color: c.textDim)),
                  ],
                  const Spacer(),
                  if (task.isRunning) _CancelButton(task: task),
                  if (task.isDone) _CopyIdButton(taskId: task.id),
                ],
              ),
              AnimatedSize(
                duration: DsDuration.base,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topLeft,
                child: expanded
                    ? _ExpandedBody(task: task, colors: c)
                    : _CollapsedPreview(task: task, colors: c),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollapsedPreview extends StatelessWidget {
  final BackgroundTask task;
  final AppColors colors;
  const _CollapsedPreview({required this.task, required this.colors});

  @override
  Widget build(BuildContext context) {
    final raw = task.error?.isNotEmpty == true
        ? task.error!
        : (task.preview ?? '');
    if (raw.isEmpty) return const SizedBox.shrink();
    final oneLine = raw.replaceAll('\n', ' ');
    final short = oneLine.length > 160 ? '${oneLine.substring(0, 160)}…' : oneLine;
    final isError = task.error?.isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.only(left: 26, top: 6),
      child: Text(
        short,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.firaCode(
          fontSize: 10,
          color: isError ? colors.red : colors.textMuted,
        ),
      ),
    );
  }
}

class _ExpandedBody extends StatelessWidget {
  final BackgroundTask task;
  final AppColors colors;
  const _ExpandedBody({required this.task, required this.colors});

  @override
  Widget build(BuildContext context) {
    final hasOutput = task.preview?.isNotEmpty == true;
    final hasError = task.error?.isNotEmpty == true;
    return Padding(
      padding: const EdgeInsets.only(left: 26, top: 10, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasOutput)
            _OutputBlock(
              label: 'Output',
              content: task.preview!,
              accent: colors.accentPrimary,
              colors: colors,
            ),
          if (hasError) ...[
            if (hasOutput) const SizedBox(height: 8),
            _OutputBlock(
              label: 'Error',
              content: task.error!,
              accent: colors.red,
              colors: colors,
            ),
          ],
          if (!hasOutput && !hasError)
            Text(
              'No output captured yet.',
              style: GoogleFonts.inter(fontSize: 11, color: colors.textDim),
            ),
        ],
      ),
    );
  }
}

class _OutputBlock extends StatelessWidget {
  final String label;
  final String content;
  final Color accent;
  final AppColors colors;
  const _OutputBlock({
    required this.label,
    required this.content,
    required this.accent,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                label.toUpperCase(),
                style: GoogleFonts.firaCode(
                  fontSize: 8.5,
                  color: accent,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            const Spacer(),
            _CopyContentButton(content: content),
          ],
        ),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
            color: colors.codeBlockBg,
            borderRadius: BorderRadius.circular(DsRadius.xs),
            border: Border.all(
              color: label == 'Error'
                  ? accent.withValues(alpha: 0.3)
                  : colors.border,
            ),
          ),
          child: Scrollbar(
            thumbVisibility: false,
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: GoogleFonts.firaCode(
                  fontSize: 10.5,
                  color: label == 'Error'
                      ? accent
                      : colors.text,
                  height: 1.5,
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
// ACTIONS
// ═══════════════════════════════════════════════════════════════════════════

class _CancelButton extends StatefulWidget {
  final BackgroundTask task;
  const _CancelButton({required this.task});

  @override
  State<_CancelButton> createState() => _CancelButtonState();
}

class _CancelButtonState extends State<_CancelButton> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Cancel task',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _cancelling ? null : _cancel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: c.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(DsRadius.xs - 2),
              border: Border.all(color: c.red.withValues(alpha: 0.28)),
            ),
            child: _cancelling
                ? SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1,
                      valueColor: AlwaysStoppedAnimation(c.red),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.stop_rounded, size: 11, color: c.red),
                      const SizedBox(width: 4),
                      Text(
                        'Cancel',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: c.red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    final appId = context.read<AppState>().activeApp?.appId ?? '';
    final sessionId = SessionService().activeSession?.sessionId ?? '';
    await BackgroundService().cancelTask(appId, sessionId, widget.task.id);
    if (mounted) setState(() => _cancelling = false);
  }
}

class _CopyIdButton extends StatelessWidget {
  final String taskId;
  const _CopyIdButton({required this.taskId});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Copy task ID',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Clipboard.setData(ClipboardData(text: taskId));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Task ID copied'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.content_copy_rounded,
                size: 12, color: c.textDim),
          ),
        ),
      ),
    );
  }
}

class _CopyContentButton extends StatelessWidget {
  final String content;
  const _CopyContentButton({required this.content});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: 'Copy full content',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Clipboard.setData(ClipboardData(text: content));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('Copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.content_copy_rounded,
                size: 12, color: c.textDim),
          ),
        ),
      ),
    );
  }
}

class _TextBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _TextBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_TextBtn> createState() => _TextBtnState();
}

class _TextBtnState extends State<_TextBtn> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs - 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 12,
                  color: _h ? c.textBright : c.textDim),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: _h ? c.textBright : c.textDim,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TinyBtn extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;
  const _TinyBtn({
    required this.icon,
    this.tooltip,
    required this.onTap,
  });

  @override
  State<_TinyBtn> createState() => _TinyBtnState();
}

class _TinyBtnState extends State<_TinyBtn> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final btn = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Icon(
            widget.icon,
            size: 13,
            color: _h ? c.textBright : c.textMuted,
          ),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// EMPTY STATE
// ═══════════════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  final _TaskFilter filter;
  final AppColors colors;
  const _EmptyState({required this.filter, required this.colors});

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle) = switch (filter) {
      _TaskFilter.all => (
          Icons.check_circle_outline_rounded,
          'No background tasks',
          'Tasks appear here when the agent runs commands in the background.'
        ),
      _TaskFilter.running => (
          Icons.play_circle_outline_rounded,
          'Nothing running',
          'When the agent launches a background command, it shows up here live.'
        ),
      _TaskFilter.done => (
          Icons.task_alt_rounded,
          'No completed tasks',
          'Finished tasks will land here — keep an eye on the output for review.'
        ),
      _TaskFilter.failed => (
          Icons.sentiment_satisfied_rounded,
          'No failures',
          'Anything that errors out or gets cancelled will show up here.'
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accentPrimary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
              border: Border.all(
                color: colors.accentPrimary.withValues(alpha: 0.25),
              ),
            ),
            child: Icon(icon, size: 20, color: colors.accentPrimary),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colors.textBright,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
