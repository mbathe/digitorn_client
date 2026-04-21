import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import 'file_viewer.dart';
import 'log/log_parser.dart';

/// Log file viewer with:
/// - automatic level detection (TRACE / DEBUG / INFO / WARN / ERROR / FATAL)
/// - automatic timestamp extraction
/// - coloured gutter + level badge
/// - click-to-toggle filter buttons (per level)
/// - Ctrl+F in-content search
/// - auto-scroll-on-new-content toggle (pauses when the user scrolls up)
/// - status bar with counts per level
///
/// Performance: rows are virtualised via `ListView.builder` with a
/// fixed itemExtent, so 100k-line files stay smooth.
class LogFileViewer extends FileViewer with SearchableViewer {
  const LogFileViewer();

  @override
  String get id => 'log';

  @override
  int get priority => 90;

  @override
  Set<String> get extensions => const {'log'};

  @override
  Widget build(BuildContext context, ViewerContext vctx) {
    return _LogPane(
      key: ValueKey('log-${vctx.buffer.path}'),
      content: vctx.buffer.content,
      filename: vctx.buffer.filename,
    );
  }
}

class _LogPane extends StatefulWidget {
  final String content;
  final String filename;
  const _LogPane({super.key, required this.content, required this.filename});

  @override
  State<_LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<_LogPane> {
  // Parsed state
  List<LogEntry> _entries = const [];
  Map<LogLevel, int> _counts = const {};

  // Filters
  final Set<LogLevel> _enabledLevels = LogLevel.values.toSet();

  // Search
  bool _searching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _searchQuery = '';

  // Scroll / auto-scroll
  final ScrollController _scrollCtrl = ScrollController();
  bool _autoScroll = true;
  bool _userScrolled = false;

  // Cached visible list (filters + search applied)
  List<LogEntry> _visible = const [];

  @override
  void initState() {
    super.initState();
    _reparse();
    _scrollCtrl.addListener(_onUserScroll);
  }

  @override
  void didUpdateWidget(_LogPane old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content) {
      _reparse();
      // Auto-scroll to bottom on new content (if allowed).
      if (_autoScroll && !_userScrolled) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _scrollToBottom());
      }
    }
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onUserScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _reparse() {
    _entries = parseLog(widget.content);
    final counts = <LogLevel, int>{
      for (final l in LogLevel.values) l: 0,
    };
    for (final e in _entries) {
      counts[e.level] = (counts[e.level] ?? 0) + 1;
    }
    _counts = counts;
    _recomputeVisible();
  }

  void _recomputeVisible() {
    final q = _searchQuery;
    final filters = _enabledLevels;
    final visible = <LogEntry>[];
    for (final e in _entries) {
      if (!filters.contains(e.level)) continue;
      if (q.isNotEmpty && !e.rawLine.toLowerCase().contains(q)) continue;
      visible.add(e);
    }
    _visible = visible;
  }

  void _toggleLevel(LogLevel l) {
    setState(() {
      if (_enabledLevels.contains(l)) {
        _enabledLevels.remove(l);
      } else {
        _enabledLevels.add(l);
      }
      _recomputeVisible();
    });
  }

  void _setAllLevels(bool enabled) {
    setState(() {
      _enabledLevels.clear();
      if (enabled) _enabledLevels.addAll(LogLevel.values);
      _recomputeVisible();
    });
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
  }

  void _onUserScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    // Anything further than one viewport from the bottom counts as
    // "user scrolled up" — we pause auto-scroll in that case.
    final atBottom = pos.pixels >= pos.maxScrollExtent - 40;
    if (_userScrolled != !atBottom) {
      setState(() => _userScrolled = !atBottom);
    }
  }

  // ── Search ────────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (_searching) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _searchFocus.requestFocus());
      } else {
        _searchCtrl.clear();
        _searchQuery = '';
        _recomputeVisible();
      }
    });
  }

  void _onSearchChanged(String v) {
    setState(() {
      _searchQuery = v.trim().toLowerCase();
      _recomputeVisible();
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _toggleSearch,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searching) _toggleSearch();
        },
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: c.bg,
          child: Column(
            children: [
              _buildHeader(c),
              Container(height: 1, color: c.border),
              _buildFilterRow(c),
              Container(height: 1, color: c.border),
              Expanded(child: _buildList(c)),
              _buildStatusBar(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.surface,
      child: _searching ? _buildSearchBar(c) : _buildHeaderRow(c),
    );
  }

  Widget _buildHeaderRow(AppColors c) {
    return Row(
      children: [
        Icon(Icons.receipt_long_rounded, size: 14, color: c.orange),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.filename,
            style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: c.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.orange.withValues(alpha: 0.3)),
          ),
          child: Text('LOG',
              style: GoogleFonts.firaCode(
                  fontSize: 9, color: c.orange, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 12),
        _LogIconBtn(
          icon: Icons.search_rounded,
          tooltip: 'Search (Ctrl+F)',
          onTap: _toggleSearch,
        ),
        _LogIconBtn(
          icon: _autoScroll
              ? Icons.vertical_align_bottom_rounded
              : Icons.pause_circle_outline_rounded,
          tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll paused',
          onTap: () {
            setState(() {
              _autoScroll = !_autoScroll;
              if (_autoScroll) {
                _userScrolled = false;
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _scrollToBottom());
              }
            });
          },
          active: _autoScroll,
        ),
      ],
    );
  }

  Widget _buildSearchBar(AppColors c) {
    return Row(
      children: [
        Icon(Icons.search_rounded, size: 14, color: c.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            onChanged: _onSearchChanged,
            style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'Search in visible lines…',
              hintStyle:
                  GoogleFonts.firaCode(fontSize: 12, color: c.textMuted),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        Text(
          _searchQuery.isEmpty
              ? ''
              : '${_visible.length} matches',
          style: GoogleFonts.firaCode(
              fontSize: 11, color: c.textMuted),
        ),
        const SizedBox(width: 6),
        _LogIconBtn(
          icon: Icons.close_rounded,
          tooltip: 'Close search (Esc)',
          onTap: _toggleSearch,
        ),
      ],
    );
  }

  Widget _buildFilterRow(AppColors c) {
    final levels = const [
      LogLevel.trace,
      LogLevel.debug,
      LogLevel.info,
      LogLevel.warn,
      LogLevel.error,
      LogLevel.fatal,
      LogLevel.unknown,
    ];
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: c.bg,
      child: Row(
        children: [
          for (final level in levels) ...[
            _LevelChip(
              level: level,
              enabled: _enabledLevels.contains(level),
              count: _counts[level] ?? 0,
              onTap: () => _toggleLevel(level),
            ),
            const SizedBox(width: 6),
          ],
          const Spacer(),
          _LogTextBtn(
            label: 'All',
            onTap: () => _setAllLevels(true),
          ),
          const SizedBox(width: 8),
          _LogTextBtn(
            label: 'None',
            onTap: () => _setAllLevels(false),
          ),
        ],
      ),
    );
  }

  Widget _buildList(AppColors c) {
    if (_entries.isEmpty) {
      return _buildEmpty(c, 'Empty log file');
    }
    if (_visible.isEmpty) {
      return _buildEmpty(
        c,
        _searchQuery.isNotEmpty ? 'No matches' : 'All levels hidden',
      );
    }
    return Scrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _visible.length,
        itemExtent: 22,
        itemBuilder: (_, i) {
          final entry = _visible[i];
          return _LogRow(
            entry: entry,
            searchQuery: _searchQuery,
          );
        },
      ),
    );
  }

  Widget _buildStatusBar(AppColors c) {
    final total = _entries.length;
    final shown = _visible.length;
    final errors = _counts[LogLevel.error] ?? 0;
    final warns = _counts[LogLevel.warn] ?? 0;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Text(
            shown == total
                ? '$total lines'
                : '$shown / $total lines',
            style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted),
          ),
          if (errors > 0) ...[
            const SizedBox(width: 12),
            Icon(Icons.error_outline_rounded, size: 10, color: c.red),
            const SizedBox(width: 3),
            Text('$errors',
                style: GoogleFonts.firaCode(fontSize: 10, color: c.red)),
          ],
          if (warns > 0) ...[
            const SizedBox(width: 10),
            Icon(Icons.warning_amber_rounded, size: 10, color: c.orange),
            const SizedBox(width: 3),
            Text('$warns',
                style: GoogleFonts.firaCode(fontSize: 10, color: c.orange)),
          ],
          const Spacer(),
          if (_userScrolled && _autoScroll)
            Text('auto-scroll paused',
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.orange)),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppColors c, String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.receipt_long_outlined, size: 32, color: c.textMuted),
          const SizedBox(height: 10),
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.textMuted)),
        ],
      ),
    );
  }
}

// ─── Single row ────────────────────────────────────────────────────────────

class _LogRow extends StatelessWidget {
  final LogEntry entry;
  final String searchQuery;
  const _LogRow({required this.entry, required this.searchQuery});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _levelColor(c, entry.level);
    final message = entry.message;

    // Build the main text with search highlight.
    Widget messageWidget;
    final q = searchQuery;
    if (q.isNotEmpty) {
      final lower = message.toLowerCase();
      final idx = lower.indexOf(q);
      if (idx >= 0) {
        final base = GoogleFonts.firaCode(
            fontSize: 11, color: color, height: 1.5);
        messageWidget = RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(children: [
            TextSpan(text: message.substring(0, idx), style: base),
            TextSpan(
              text: message.substring(idx, idx + q.length),
              style: base.copyWith(
                backgroundColor: c.orange.withValues(alpha: 0.4),
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(text: message.substring(idx + q.length), style: base),
          ]),
        );
      } else {
        messageWidget = Text(
          message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.firaCode(
              fontSize: 11, color: color, height: 1.5),
        );
      }
    } else {
      messageWidget = Text(
        message,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.firaCode(
            fontSize: 11, color: color, height: 1.5),
      );
    }

    return Tooltip(
      message: entry.rawLine,
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            // Line number gutter
            SizedBox(
              width: 42,
              child: Text(
                '${entry.lineNumber}',
                textAlign: TextAlign.right,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textDim),
              ),
            ),
            const SizedBox(width: 8),
            // Level badge
            Container(
              width: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: color.withValues(alpha: 0.3)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                entry.level.shortLabel,
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Timestamp
            if (entry.timestampText != null) ...[
              Text(
                entry.timestampText!,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textDim),
              ),
              const SizedBox(width: 8),
            ],
            // Message
            Expanded(child: messageWidget),
          ],
        ),
      ),
    );
  }
}

Color _levelColor(AppColors c, LogLevel l) => switch (l) {
      LogLevel.fatal => c.red,
      LogLevel.error => c.red,
      LogLevel.warn => c.orange,
      LogLevel.info => c.cyan,
      LogLevel.debug => c.textMuted,
      LogLevel.trace => c.textDim,
      LogLevel.unknown => c.text,
    };

// ─── Widgets ───────────────────────────────────────────────────────────────

class _LevelChip extends StatefulWidget {
  final LogLevel level;
  final bool enabled;
  final int count;
  final VoidCallback onTap;
  const _LevelChip({
    required this.level,
    required this.enabled,
    required this.count,
    required this.onTap,
  });

  @override
  State<_LevelChip> createState() => _LevelChipState();
}

class _LevelChipState extends State<_LevelChip> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _levelColor(c, widget.level);
    final enabled = widget.enabled;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: enabled
                ? color.withValues(alpha: _h ? 0.20 : 0.14)
                : c.surface,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: enabled
                  ? color.withValues(alpha: 0.35)
                  : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.level.label,
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: enabled ? color : c.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${widget.count}',
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: enabled ? color : c.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogTextBtn extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _LogTextBtn({required this.label, required this.onTap});

  @override
  State<_LogTextBtn> createState() => _LogTextBtnState();
}

class _LogTextBtnState extends State<_LogTextBtn> {
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
        child: Text(
          widget.label,
          style: GoogleFonts.firaCode(
            fontSize: 10,
            color: _h ? c.text : c.textMuted,
            fontWeight: FontWeight.w600,
            decoration: _h ? TextDecoration.underline : null,
            decorationColor: c.text,
          ),
        ),
      ),
    );
  }
}

class _LogIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  const _LogIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  State<_LogIconBtn> createState() => _LogIconBtnState();
}

class _LogIconBtnState extends State<_LogIconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _h || widget.active ? c.text : c.textMuted;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: widget.active
                  ? c.green.withValues(alpha: 0.15)
                  : (_h ? c.surfaceAlt : Colors.transparent),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: widget.active
                    ? c.green.withValues(alpha: 0.3)
                    : Colors.transparent,
              ),
            ),
            child: Icon(widget.icon, size: 14, color: color),
          ),
        ),
      ),
    );
  }
}
