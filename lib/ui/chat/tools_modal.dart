import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/tokens.dart';
import '../../services/tool_service.dart';
import '../../theme/app_theme.dart';

/// System-level tools we hide from the "browse available tools"
/// panel — they're daemon plumbing the user never calls directly.
const _hiddenTools = {
  'set_goal', 'setgoal', 'remember', 'recall', 'forget',
  'add_todo', 'update_todo', 'todoadd', 'todoupdate',
  'spawn_agent', 'agent_spawn', 'agent_wait', 'agent_wait_all',
  'agentwaitall', 'agent_result', 'agent_status', 'agent_cancel',
  'agent_list', 'search_tools', 'get_tool', 'list_categories',
  'browse_category',
};

bool _isSystemTool(String name) {
  final lower = name.toLowerCase().split(RegExp(r'[.__]')).last;
  return _hiddenTools.contains(lower) ||
      name.toLowerCase().contains('memory') ||
      name.toLowerCase().contains('agent_spawn');
}

/// Session-scoped "recently inspected" tools. Not persisted — this
/// is about what you just clicked while browsing, not cross-session
/// history.
final List<String> _sessionRecents = <String>[];

void _bumpRecent(String name) {
  _sessionRecents.remove(name);
  _sessionRecents.insert(0, name);
  if (_sessionRecents.length > 8) {
    _sessionRecents.removeRange(8, _sessionRecents.length);
  }
}

/// Virtual "category" ids — used in the left sidebar to flip between
/// a recents / all view and the real per-module categories fetched
/// from the daemon.
const String _kAllCategoryId = '__all__';
const String _kRecentCategoryId = '__recent__';

/// Premium inline tools panel — positioned above the chat composer,
/// same max width as the input column, so it always sits inside the
/// chat zone regardless of the drawer / workspace layout.
///
/// Layout:
///   * 200-px sidebar listing modules (app's YAML manifest grants)
///     with icon, name, count pill. A "Recently inspected" group
///     pins to the top when the user has clicked at least one tool
///     this session.
///   * flexible body showing the filtered tool rows for the current
///     category + search query. Tap a tool → copy its canonical
///     name to the clipboard + record in recents.
class ToolsPanel extends StatefulWidget {
  final String appId;
  final VoidCallback onClose;
  const ToolsPanel({super.key, required this.appId, required this.onClose});

  @override
  State<ToolsPanel> createState() => _ToolsPanelState();
}

class _ToolsPanelState extends State<ToolsPanel> {
  /// Search only shows up once the catalogue has more tools than this.
  /// Below it a scan-glance list is faster than typing.
  static const int _searchThreshold = 10;

  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _selectedId = _kAllCategoryId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  Future<void> _load() async {
    final svc = ToolService();
    await svc.loadCategories(widget.appId);
    for (final cat in svc.categories) {
      await svc.loadCategory(widget.appId, cat.id);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<ToolRecord> get _allTools {
    final svc = ToolService();
    final out = <ToolRecord>[];
    final seen = <String>{};
    for (final cat in svc.categories) {
      final tools = svc.categoryTools(cat.id);
      for (final t in tools) {
        if (_isSystemTool(t.name)) continue;
        if (seen.add(t.name)) out.add(t);
      }
    }
    return out;
  }

  List<ToolRecord> _toolsFor(String categoryId) {
    if (categoryId == _kAllCategoryId) return _allTools;
    if (categoryId == _kRecentCategoryId) {
      final all = _allTools;
      final byName = {for (final t in all) t.name: t};
      return _sessionRecents
          .map((n) => byName[n])
          .whereType<ToolRecord>()
          .toList();
    }
    return ToolService()
        .categoryTools(categoryId)
        .where((t) => !_isSystemTool(t.name))
        .toList();
  }

  List<ToolRecord> _applyQuery(List<ToolRecord> src) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return src;
    return src
        .where((t) =>
            t.name.toLowerCase().contains(q) ||
            t.label.toLowerCase().contains(q) ||
            t.description.toLowerCase().contains(q))
        .toList();
  }

  void _onPickTool(ToolRecord t) {
    Clipboard.setData(ClipboardData(text: t.name));
    setState(() => _bumpRecent(t.name));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        content: Text('Copied ${t.name} to clipboard'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final currentTools =
        _applyQuery(_toolsFor(_selectedId))
          ..sort((a, b) =>
              a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

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
      // The panel now auto-sizes to its content: short catalogue →
      // a couple of rows tall; long catalogue → capped at _maxListHeight
      // so it never pushes the composer far down. The intrinsic sizing
      // comes from the Column + shrink-wrapped ListViews below.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            total: _allTools.length,
            loading: _loading,
            onClose: widget.onClose,
          ),
          // Hide the search bar when the catalog is small enough to
          // fit at a glance — typing on a 5-item list feels clunky
          // and eats precious vertical space inside the panel.
          if (_allTools.length > _searchThreshold)
            _SearchBar(controller: _searchCtrl, focusNode: _searchFocus)
          else
            const SizedBox(height: 6),
          Container(height: 1, color: c.border),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 1.4),
                      ),
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Sidebar(
                        selectedId: _selectedId,
                        onSelect: (id) =>
                            setState(() => _selectedId = id),
                      ),
                      Container(
                        width: 1,
                        color: c.border,
                        constraints:
                            const BoxConstraints(minHeight: 60),
                      ),
                      Expanded(
                        child: _ToolList(
                          tools: currentTools,
                          query: _searchCtrl.text,
                          onPick: _onPickTool,
                        ),
                      ),
                    ],
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
  final bool loading;
  final VoidCallback onClose;
  const _Header({
    required this.total,
    required this.loading,
    required this.onClose,
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
            child: Icon(Icons.auto_awesome_rounded,
                size: 14, color: c.onAccent),
          ),
          const SizedBox(width: 10),
          Text(
            'Tools',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: c.textBright,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(width: 8),
          if (!loading)
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
          Text(
            'Tap a tool to copy its name',
            style: GoogleFonts.inter(fontSize: 11, color: c.textDim),
          ),
          const SizedBox(width: 10),
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
// SEARCH BAR
// ═══════════════════════════════════════════════════════════════════════════

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
    widget.focusNode.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final focused = widget.focusNode.hasFocus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: AnimatedContainer(
        duration: DsDuration.fast,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(DsRadius.input),
          border: Border.all(
            color: focused
                ? c.accentPrimary.withValues(alpha: 0.5)
                : c.border,
            width: focused ? 1.2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 14,
              color: focused ? c.accentPrimary : c.textDim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                cursorColor: c.accentPrimary,
                cursorWidth: 1.2,
                style: GoogleFonts.inter(fontSize: 12.5, color: c.textBright),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  border: InputBorder.none,
                  hintText: 'Search by name or description…',
                  hintStyle:
                      GoogleFonts.inter(fontSize: 12.5, color: c.textDim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SIDEBAR (categories)
// ═══════════════════════════════════════════════════════════════════════════

class _Sidebar extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onSelect;
  const _Sidebar({required this.selectedId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cats = ToolService().categories;
    final hasRecents = _sessionRecents.isNotEmpty;
    return SizedBox(
      width: 196,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          if (hasRecents)
            _CategoryRow(
              id: _kRecentCategoryId,
              icon: Icons.history_rounded,
              label: 'Recently inspected',
              count: _sessionRecents.length,
              selected: selectedId == _kRecentCategoryId,
              onTap: () => onSelect(_kRecentCategoryId),
              accent: true,
            ),
          _CategoryRow(
            id: _kAllCategoryId,
            icon: Icons.grid_view_rounded,
            label: 'All tools',
            count: _allToolsCount(),
            selected: selectedId == _kAllCategoryId,
            onTap: () => onSelect(_kAllCategoryId),
          ),
          if (cats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 4),
              child: Text(
                'MODULES',
                style: GoogleFonts.inter(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: c.textDim,
                ),
              ),
            ),
          for (final cat in cats)
            _CategoryRow(
              id: cat.id,
              emoji: cat.icon,
              icon: Icons.folder_outlined,
              label: cat.name.isNotEmpty ? cat.name : cat.id,
              count: cat.toolCount > 0
                  ? cat.toolCount
                  : _moduleCount(cat.id),
              selected: selectedId == cat.id,
              onTap: () => onSelect(cat.id),
            ),
          ],
        ),
      ),
    );
  }

  int _allToolsCount() {
    final svc = ToolService();
    final seen = <String>{};
    for (final cat in svc.categories) {
      for (final t in svc.categoryTools(cat.id)) {
        if (_isSystemTool(t.name)) continue;
        seen.add(t.name);
      }
    }
    return seen.length;
  }

  int _moduleCount(String id) {
    return ToolService()
        .categoryTools(id)
        .where((t) => !_isSystemTool(t.name))
        .length;
  }
}

class _CategoryRow extends StatefulWidget {
  final String id;
  final IconData icon;
  final String? emoji;
  final String label;
  final int count;
  final bool selected;
  final bool accent;
  final VoidCallback onTap;

  const _CategoryRow({
    required this.id,
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.emoji,
    this.accent = false,
  });

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = widget.selected;
    final accentColor =
        widget.accent ? c.accentSecondary : c.accentPrimary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active
                ? accentColor.withValues(alpha: 0.11)
                : _h
                    ? c.surfaceAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
            border: Border.all(
              color: active
                  ? accentColor.withValues(alpha: 0.32)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: Center(
                  child: widget.emoji != null && widget.emoji!.isNotEmpty
                      ? Text(
                          widget.emoji!,
                          style: const TextStyle(fontSize: 13, height: 1),
                        )
                      : Icon(
                          widget.icon,
                          size: 13,
                          color: active ? accentColor : c.textMuted,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? c.textBright : c.text,
                  ),
                ),
              ),
              Text(
                '${widget.count}',
                style: GoogleFonts.firaCode(
                  fontSize: 10,
                  color: active ? accentColor : c.textDim,
                  fontWeight: FontWeight.w600,
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
// TOOL LIST
// ═══════════════════════════════════════════════════════════════════════════

class _ToolList extends StatelessWidget {
  final List<ToolRecord> tools;
  final String query;
  final void Function(ToolRecord) onPick;
  const _ToolList({
    required this.tools,
    required this.query,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (tools.isEmpty) {
      final trimmed = query.trim();
      return _EmptyHint(
        icon: trimmed.isEmpty
            ? Icons.build_outlined
            : Icons.search_off_rounded,
        label: trimmed.isEmpty
            ? 'Nothing in this category'
            : 'No tool matches "$trimmed"',
        colors: c,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tool in tools)
            _ToolRow(
              tool: tool,
              onTap: () => onPick(tool),
            ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatefulWidget {
  final ToolRecord tool;
  final VoidCallback onTap;
  const _ToolRow({required this.tool, required this.onTap});

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = widget.tool;
    final label = _friendlyName(t.label.isNotEmpty ? t.label : t.name);
    final risk = t.riskLevel;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DsDuration.fast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: _h
                ? c.accentPrimary.withValues(alpha: 0.07)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(DsRadius.xs),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentPrimary.withValues(alpha: _h ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(DsRadius.xs),
                ),
                child: Icon(
                  _toolIcon(t.name),
                  size: 13,
                  color: c.accentPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: c.textBright,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.firaCode(
                            fontSize: 10.5,
                            color: c.textDim,
                          ),
                        ),
                      ],
                    ),
                    if (t.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        t.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: c.textMuted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (risk.isNotEmpty) ...[
                const SizedBox(width: 10),
                _RiskBadge(level: risk),
              ],
              const SizedBox(width: 6),
              AnimatedOpacity(
                duration: DsDuration.fast,
                opacity: _h ? 1 : 0.4,
                child: Icon(
                  Icons.content_copy_rounded,
                  size: 12,
                  color: _h ? c.accentPrimary : c.textDim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _friendlyName(String raw) {
    final parts = raw.split(RegExp(r'[.__]'));
    final action = parts.length > 1 ? parts.sublist(1).join('_') : parts.last;
    return action
        .split('_')
        .where((s) => s.isNotEmpty)
        .map((s) => s[0].toUpperCase() + s.substring(1))
        .join(' ');
  }

  IconData _toolIcon(String name) {
    final l = name.toLowerCase();
    if (l.contains('read') || l.contains('glob')) {
      return Icons.visibility_outlined;
    }
    if (l.contains('write') || l.contains('edit')) {
      return Icons.edit_outlined;
    }
    if (l.contains('bash') || l.contains('shell')) {
      return Icons.terminal_rounded;
    }
    if (l.contains('git')) return Icons.call_split_rounded;
    if (l.contains('search') || l.contains('grep')) {
      return Icons.search_rounded;
    }
    if (l.contains('web') || l.contains('http')) {
      return Icons.language_rounded;
    }
    if (l.contains('db') || l.contains('sql') || l.contains('database')) {
      return Icons.storage_rounded;
    }
    if (l.contains('image') || l.contains('img') || l.contains('vision')) {
      return Icons.image_rounded;
    }
    if (l.contains('email') || l.contains('mail')) {
      return Icons.mail_outlined;
    }
    return Icons.build_outlined;
  }
}

class _RiskBadge extends StatelessWidget {
  final String level;
  const _RiskBadge({required this.level});

  (Color, String) _resolve(AppColors c) {
    switch (level.toLowerCase()) {
      case 'high':
      case 'critical':
        return (c.red, 'Needs explicit user approval — agent cannot run silently');
      case 'medium':
      case 'mid':
        return (c.orange, 'Has side-effects — surfaced to the user with context');
      case 'low':
      case 'safe':
        return (c.green, 'Read-only / safe — agent runs without prompting');
      default:
        return (c.textMuted, level);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (color, tooltip) = _resolve(c);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      preferBelow: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(DsRadius.xs - 2),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          level.toUpperCase(),
          style: GoogleFonts.firaCode(
            fontSize: 9,
            color: color,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED BITS
// ═══════════════════════════════════════════════════════════════════════════


class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String label;
  final AppColors colors;
  const _EmptyHint({
    required this.icon,
    required this.label,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 26, color: colors.textDim),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(fontSize: 12, color: colors.textMuted),
          ),
        ],
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
