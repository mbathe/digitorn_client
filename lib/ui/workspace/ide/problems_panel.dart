/// VS Code-style "Problems" panel — a collapsible list of every LSP
/// diagnostic across the workspace, sorted by severity then path.
///
/// Click a row → the layout selects the file and asks Monaco to
/// reveal the offending line. Wiring goes through
/// [WorkspaceModule.revealAt] which the Monaco editor pane watches.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/diagnostic.dart';
import '../../../services/workspace_module.dart';
import '../../../theme/app_theme.dart';

class ProblemsPanel extends StatefulWidget {
  /// Called when the user clicks a row. Callers should update the
  /// file selection in the IDE and trigger [WorkspaceModule.revealAt].
  final void Function(String path, int line, int column) onReveal;
  const ProblemsPanel({super.key, required this.onReveal});

  @override
  State<ProblemsPanel> createState() => _ProblemsPanelState();
}

class _ProblemsPanelState extends State<ProblemsPanel> {
  // Default COLLAPSED — the panel stays out of the way until the
  // user explicitly asks for it (or there are problems worth
  // surfacing, see auto-open below). Avoids eating ~250 px of
  // vertical real-estate at the bottom of the editor on a clean
  // workspace.
  bool _expanded = false;
  bool _userCollapsedSinceProblems = false;
  int _lastErrCount = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WorkspaceModule(),
      builder: (context, _) {
        final module = WorkspaceModule();
        final rows = _flatten(module);
        final c = context.colors;
        final hasItems = rows.isNotEmpty;

        // Auto-open when a new error surfaces (error count grew) and
        // the user hasn't actively closed the panel since the last
        // clean state. Keeps "new problem" discoverable without
        // fighting an explicit user choice.
        final errs = module.totalErrors;
        if (errs > _lastErrCount &&
            !_expanded &&
            !_userCollapsedSinceProblems) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _expanded = true);
          });
        }
        _lastErrCount = errs;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(
                module: module,
                expanded: _expanded,
                onToggle: () => setState(() {
                  _expanded = !_expanded;
                  if (!_expanded) {
                    _userCollapsedSinceProblems = true;
                  } else {
                    // User opened — reset so future auto-open works.
                    _userCollapsedSinceProblems = false;
                  }
                }),
              ),
              if (_expanded)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: hasItems
                      ? _List(rows: rows, onReveal: widget.onReveal)
                      : _Empty(),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Flatten every (path, diagnostic) pair into a sortable list:
  /// errors first, then warnings, then infos, then hints; within a
  /// severity, alphabetical by path then by line.
  List<_Row> _flatten(WorkspaceModule module) {
    final out = <_Row>[];
    for (final entry in module.diagnostics.values) {
      final tag = entry.sourceModuleLabel;
      for (final d in entry.items) {
        out.add(_Row(
          path: entry.filePath,
          diagnostic: d,
          sourceTag: tag,
        ));
      }
    }
    out.sort((a, b) {
      final s = b.diagnostic.severity.rank.compareTo(a.diagnostic.severity.rank);
      if (s != 0) return s;
      final p = a.path.compareTo(b.path);
      if (p != 0) return p;
      return a.diagnostic.range.start.line
          .compareTo(b.diagnostic.range.start.line);
    });
    return out;
  }
}

class _Row {
  final String path;
  final Diagnostic diagnostic;
  final String sourceTag;
  const _Row({
    required this.path,
    required this.diagnostic,
    required this.sourceTag,
  });
}

// ─── Header ───────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final WorkspaceModule module;
  final bool expanded;
  final VoidCallback onToggle;
  const _Header({
    required this.module,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final errs = module.totalErrors;
    final warns = module.totalWarnings;
    final infos = module.totalInfos;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onToggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                size: 14,
                color: c.textDim,
              ),
              const SizedBox(width: 4),
              Text(
                'Problems',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: c.textMuted,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 10),
              if (errs > 0) _Chip(count: errs, color: c.red, label: 'errors'),
              if (warns > 0) ...[
                const SizedBox(width: 4),
                _Chip(count: warns, color: c.orange, label: 'warnings'),
              ],
              if (infos > 0) ...[
                const SizedBox(width: 4),
                _Chip(count: infos, color: c.blue, label: 'infos'),
              ],
              const Spacer(),
              if (errs + warns + infos == 0)
                Text(
                  'No problems',
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    color: c.textDim,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final int count;
  final Color color;
  final String label;
  const _Chip(
      {required this.count, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$count $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          '$count',
          style: GoogleFonts.firaCode(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

// ─── List ─────────────────────────────────────────────────────────

class _List extends StatelessWidget {
  final List<_Row> rows;
  final void Function(String, int, int) onReveal;
  const _List({required this.rows, required this.onReveal});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: rows.length,
      itemBuilder: (_, i) => _Tile(row: rows[i], onReveal: onReveal),
    );
  }
}

class _Tile extends StatefulWidget {
  final _Row row;
  final void Function(String, int, int) onReveal;
  const _Tile({required this.row, required this.onReveal});

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = widget.row.diagnostic;
    final path = widget.row.path;
    final Color sev;
    final IconData icon;
    switch (d.severity) {
      case DiagnosticSeverity.error:
        sev = c.red;
        icon = Icons.error_outline_rounded;
      case DiagnosticSeverity.warning:
        sev = c.orange;
        icon = Icons.warning_amber_rounded;
      case DiagnosticSeverity.info:
        sev = c.blue;
        icon = Icons.info_outline_rounded;
      case DiagnosticSeverity.hint:
        sev = c.textDim;
        icon = Icons.lightbulb_outline_rounded;
    }
    final filename = path.replaceAll('\\', '/').split('/').last;
    // LSP ranges are 0-based, users expect 1-based display.
    final line = d.range.start.line + 1;
    final col = d.range.start.character + 1;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hover && mounted) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover && mounted) setState(() => _hover = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onReveal(path, line, col),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          color: _hover ? c.surfaceAlt : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: sev),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.text,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Tooltip(
                  message: widget.row.sourceTag.isNotEmpty
                      ? '$path (${widget.row.sourceTag})'
                      : path,
                  child: Text(
                    '$filename:$line:$col',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textDim,
                    ),
                  ),
                ),
              ),
              if (d.source != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: sev.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    d.source!,
                    style: GoogleFonts.firaCode(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: sev,
                      height: 1.3,
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

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline_rounded,
              size: 18, color: c.green.withValues(alpha: 0.7)),
          const SizedBox(height: 6),
          Text(
            'All clean.',
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: c.textDim,
            ),
          ),
        ],
      ),
    );
  }
}
