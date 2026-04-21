import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../services/workspace_module.dart';
import '../../../services/workspace_service.dart';
import '../../../theme/app_theme.dart';
import 'search_engine.dart';

/// Cross-buffer search panel rendered in the workspace as a third tab,
/// alongside Files and Diagnostics. Searches every currently open
/// buffer (no daemon round-trip), groups results by file, and dispatches
/// clicks to [WorkspaceService.revealLine] which switches the active
/// buffer and scrolls the editor to the right line.
class SearchPanel extends StatefulWidget {
  final WorkspaceService ws;
  /// Externally-provided focus node so the parent (workspace panel) can
  /// request focus when Ctrl+Shift+F is pressed.
  final FocusNode? inputFocus;

  const SearchPanel({
    super.key,
    required this.ws,
    this.inputFocus,
  });

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  final TextEditingController _ctrl = TextEditingController();
  late final FocusNode _focus;

  SearchOptions _opts = const SearchOptions(query: '');
  SearchResults _results = SearchResults.empty;
  Timer? _debounce;

  // Collapsed file paths in the result list.
  final Set<String> _collapsedFiles = {};

  @override
  void initState() {
    super.initState();
    _focus = widget.inputFocus ?? FocusNode();
    widget.ws.addListener(_onWsChanged);
    WorkspaceModule().addListener(_onWsChanged);
  }

  @override
  void dispose() {
    widget.ws.removeListener(_onWsChanged);
    WorkspaceModule().removeListener(_onWsChanged);
    _debounce?.cancel();
    _ctrl.dispose();
    if (widget.inputFocus == null) _focus.dispose();
    super.dispose();
  }

  void _onWsChanged() {
    // If files come or go we may need to re-run the search.
    if (_opts.query.isNotEmpty && mounted) _runSearch();
  }

  void _runSearch() {
    // Post-consolidation: [WorkspaceModule.files] is the single source
    // of truth. `ws.buffers` is a compat view over the same files and
    // would double-count if passed here too.
    final files = collectSearchableFiles(
      buffers: const [],
      moduleFiles: WorkspaceModule().files.values,
    );
    setState(() {
      _results = searchFiles(files: files, options: _opts);
    });
  }

  void _onQueryChanged(String q) {
    _opts = _opts.copyWith(query: q);
    // Debounce so large file sets don't lag on each keystroke. 180ms
    // is short enough to feel instant but long enough to coalesce
    // fast typing into a single search pass.
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() => _results = SearchResults.empty);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 180), _runSearch);
  }

  void _toggleCase() {
    _opts = _opts.copyWith(caseSensitive: !_opts.caseSensitive);
    _runSearch();
  }

  void _toggleWord() {
    _opts = _opts.copyWith(wholeWord: !_opts.wholeWord);
    _runSearch();
  }

  void _toggleRegex() {
    _opts = _opts.copyWith(regex: !_opts.regex);
    _runSearch();
  }

  void _onHitTap(SearchHit hit) {
    // Filename-only hits carry `line: 0` — open the file at the top.
    final line = hit.line > 0 ? hit.line : 1;
    if (WorkspaceModule().files.containsKey(hit.path)) {
      WorkspaceModule().revealAt(hit.path, line, column: hit.column);
    } else {
      widget.ws.revealLine(hit.path, line, column: hit.column);
    }
  }

  void _toggleFile(String path) {
    setState(() {
      if (_collapsedFiles.contains(path)) {
        _collapsedFiles.remove(path);
      } else {
        _collapsedFiles.add(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // The parent column in `_FilesTab` does not bound our height, so
    // an outright `Expanded` would blow up the layout. Cap the panel
    // at 360px and let the results list scroll inside — matches VS
    // Code's inline search sidebar feel.
    return Container(
      color: c.bg,
      constraints: const BoxConstraints(maxHeight: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildInput(c),
          Container(height: 1, color: c.border),
          _buildSummary(c),
          if (_results.fileCount > 0) Container(height: 1, color: c.border),
          Flexible(child: _buildResults(c)),
        ],
      ),
    );
  }

  // ── Input row ─────────────────────────────────────────────────────────

  Widget _buildInput(AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: _focus.hasFocus ? c.green : c.border,
                  width: _focus.hasFocus ? 1.2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 14, color: c.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      onChanged: _onQueryChanged,
                      style: GoogleFonts.firaCode(
                          fontSize: 12, color: c.text),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Search across open files…',
                        hintStyle: GoogleFonts.firaCode(
                            fontSize: 12, color: c.textMuted),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_opts.query.isNotEmpty)
                    _SearchOptionBtn(
                      label: 'Aa',
                      tooltip: 'Match case',
                      active: _opts.caseSensitive,
                      onTap: _toggleCase,
                    ),
                  if (_opts.query.isNotEmpty) const SizedBox(width: 2),
                  if (_opts.query.isNotEmpty)
                    _SearchOptionBtn(
                      label: 'ab',
                      tooltip: 'Match whole word',
                      active: _opts.wholeWord,
                      underline: true,
                      onTap: _toggleWord,
                    ),
                  if (_opts.query.isNotEmpty) const SizedBox(width: 2),
                  if (_opts.query.isNotEmpty)
                    _SearchOptionBtn(
                      label: '.*',
                      tooltip: 'Use regular expression',
                      active: _opts.regex,
                      onTap: _toggleRegex,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Summary line ──────────────────────────────────────────────────────

  Widget _buildSummary(AppColors c) {
    String text;
    Color color = c.textMuted;
    if (_results.hasError) {
      text = 'Invalid regex: ${_results.regexError}';
      color = c.red;
    } else if (_opts.query.isEmpty) {
      final total = WorkspaceModule().files.length;
      text = '$total file${total == 1 ? '' : 's'} ready to search';
    } else if (_results.totalHits == 0) {
      text = 'No results';
    } else {
      text = '${_results.totalHits} '
          '${_results.totalHits == 1 ? "result" : "results"} '
          'in ${_results.fileCount} '
          '${_results.fileCount == 1 ? "file" : "files"}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: GoogleFonts.firaCode(fontSize: 10, color: color),
      ),
    );
  }

  // ── Results list ──────────────────────────────────────────────────────

  Widget _buildResults(AppColors c) {
    if (_opts.query.isEmpty) {
      return _buildEmptyState(
        c,
        Icons.search_rounded,
        'Type to search across all open files',
      );
    }
    if (_results.hasError) {
      return _buildEmptyState(
        c,
        Icons.error_outline_rounded,
        _results.regexError ?? 'Invalid pattern',
        color: c.red,
      );
    }
    if (_results.totalHits == 0) {
      final total = WorkspaceModule().files.length;
      return _buildEmptyState(
        c,
        Icons.search_off_rounded,
        'No matches in $total file${total == 1 ? '' : 's'}',
      );
    }

    final files = _results.byFile.keys.toList();
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      itemCount: files.length,
      itemBuilder: (_, i) {
        final path = files[i];
        final hits = _results.byFile[path]!;
        final collapsed = _collapsedFiles.contains(path);
        return _FileGroup(
          path: path,
          hits: hits,
          collapsed: collapsed,
          onToggle: () => _toggleFile(path),
          onHitTap: _onHitTap,
        );
      },
    );
  }

  Widget _buildEmptyState(AppColors c, IconData icon, String label,
      {Color? color}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: color ?? c.textMuted),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                  fontSize: 12, color: color ?? c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── File group + hit row ──────────────────────────────────────────────────

class _FileGroup extends StatelessWidget {
  final String path;
  final List<SearchHit> hits;
  final bool collapsed;
  final VoidCallback onToggle;
  final void Function(SearchHit) onHitTap;

  const _FileGroup({
    required this.path,
    required this.hits,
    required this.collapsed,
    required this.onToggle,
    required this.onHitTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final filename = hits.first.filename;
    final dir = _directoryOf(path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── File header ────────────────────────────────────────────────
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onToggle,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_right_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: c.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.insert_drive_file_outlined,
                      size: 12, color: c.textMuted),
                  const SizedBox(width: 6),
                  Text(
                    filename,
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color: c.text,
                        fontWeight: FontWeight.w600),
                  ),
                  if (dir.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        dir,
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textDim),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '${hits.length}',
                      style: GoogleFonts.firaCode(
                          fontSize: 9,
                          color: c.textMuted,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // ── Hits ──────────────────────────────────────────────────────
        if (!collapsed)
          for (final hit in hits) _HitRow(hit: hit, onTap: () => onHitTap(hit)),
      ],
    );
  }

  static String _directoryOf(String path) {
    final p = path.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i > 0 ? p.substring(0, i) : '';
  }
}

class _HitRow extends StatefulWidget {
  final SearchHit hit;
  final VoidCallback onTap;
  const _HitRow({required this.hit, required this.onTap});

  @override
  State<_HitRow> createState() => _HitRowState();
}

class _HitRowState extends State<_HitRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hit = widget.hit;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? c.surfaceAlt.withValues(alpha: 0.5) : null,
          padding: const EdgeInsets.fromLTRB(28, 2, 8, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  '${hit.line}',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textDim,
                      fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _highlightedLine(c),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _highlightedLine(AppColors c) {
    final hit = widget.hit;
    // Trim leading whitespace for compactness while preserving the
    // match offset relative to the original line.
    final line = hit.lineContent;
    final leadTrim = _leadingWs(line);
    final trimmedStart = leadTrim;
    final trimmedLine = line.substring(trimmedStart);
    final adjustedStart = (hit.matchStart - trimmedStart).clamp(0, trimmedLine.length);
    final adjustedEnd =
        (hit.matchEnd - trimmedStart).clamp(0, trimmedLine.length);

    final base = GoogleFonts.firaCode(
        fontSize: 11, color: c.text, height: 1.4);
    final highlight = base.copyWith(
      backgroundColor: c.orange.withValues(alpha: 0.35),
      fontWeight: FontWeight.w700,
    );

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(children: [
        TextSpan(
            text: trimmedLine.substring(0, adjustedStart), style: base),
        TextSpan(
          text: trimmedLine.substring(adjustedStart, adjustedEnd),
          style: highlight,
        ),
        TextSpan(text: trimmedLine.substring(adjustedEnd), style: base),
      ]),
    );
  }

  int _leadingWs(String s) {
    var i = 0;
    while (i < s.length && (s.codeUnitAt(i) == 0x20 || s.codeUnitAt(i) == 0x09)) {
      i++;
    }
    return i;
  }
}

// ─── Tiny themed toggle ────────────────────────────────────────────────────

class _SearchOptionBtn extends StatefulWidget {
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final bool underline;
  const _SearchOptionBtn({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    this.underline = false,
  });
  @override
  State<_SearchOptionBtn> createState() => _SearchOptionBtnState();
}

class _SearchOptionBtnState extends State<_SearchOptionBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = widget.active ? c.text : (_h ? c.text : c.textMuted);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? c.green.withValues(alpha: 0.18)
                  : (_h ? c.surfaceAlt : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: widget.active
                    ? c.green.withValues(alpha: 0.4)
                    : Colors.transparent,
              ),
            ),
            child: Text(
              widget.label,
              style: GoogleFonts.firaCode(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w700,
                decoration:
                    widget.underline ? TextDecoration.underline : null,
                decorationColor: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
