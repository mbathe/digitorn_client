/// Global fuzzy search overlay — the spiritual cousin of the command
/// palette but with a much wider index. Powers two key bindings:
///
///   * Ctrl+P — full search across **everything** (apps, sessions,
///     activations, credentials, settings sections, commands)
///   * Ctrl+T — quick switcher restricted to **apps + sessions**
///     so the user can jump between work in 3 keystrokes
///
/// One overlay class, two entry points. The mode controls which
/// indexers run. Indexes are rebuilt every time the overlay opens —
/// cheap because every source is already in memory.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/apps_service.dart';
import '../services/background_app_service.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';
import 'credentials/credentials_form.dart';
import 'credentials/my_credentials_page.dart';
import 'settings/diagnostics_page.dart';

enum SearchMode { full, quickSwitcher }

class GlobalSearch {
  static Future<void> show(
    BuildContext context, {
    SearchMode mode = SearchMode.full,
  }) async {
    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _SearchOverlay(mode: mode),
    );
  }
}

class SearchHit {
  final String title;
  final String subtitle;
  final IconData icon;
  final String groupLabel;
  final Future<void> Function(BuildContext) onSelect;
  /// Substring used for matching. Lowercased once at index time so
  /// each filter pass is a cheap `contains`.
  final String haystack;

  SearchHit({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.groupLabel,
    required this.onSelect,
    String? haystack,
  }) : haystack = (haystack ?? '$title $subtitle').toLowerCase();
}

class _SearchOverlay extends StatefulWidget {
  final SearchMode mode;
  const _SearchOverlay({required this.mode});
  @override
  State<_SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends State<_SearchOverlay> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  String _q = '';
  int _highlight = 0;
  late List<SearchHit> _index;

  @override
  void initState() {
    super.initState();
    _index = _buildIndex();
    _ctrl.addListener(() {
      setState(() {
        _q = _ctrl.text.trim().toLowerCase();
        _highlight = 0;
      });
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Compose hits from every in-memory source. Network calls stay
  /// out of this hot path — we read whatever each service has
  /// already cached.
  List<SearchHit> _buildIndex() {
    final out = <SearchHit>[];
    final apps = AppsService().apps;
    final isFull = widget.mode == SearchMode.full;

    // ── Apps ──────────────────────────────────────────────────
    for (final app in apps) {
      out.add(SearchHit(
        title: app.name,
        subtitle: app.description.isNotEmpty ? app.description : app.appId,
        icon: app.mode == 'background'
            ? Icons.bolt_rounded
            : Icons.chat_bubble_outline_rounded,
        groupLabel: 'APP',
        onSelect: (ctx) async {
          final state = AppStateAccess.of(ctx);
          state.setApp(app);
        },
        haystack: '${app.name} ${app.appId} ${app.description} '
            '${app.tags.join(" ")}',
      ));
    }

    // ── Sessions of the active conversation app (cheap) ──────
    final sessions = SessionService().sessions;
    for (final s in sessions) {
      out.add(SearchHit(
        title: s.displayTitle,
        subtitle:
            '${s.messageCount} messages · ${s.timeAgo.isNotEmpty ? s.timeAgo : "no activity"}',
        icon: Icons.history_rounded,
        groupLabel: 'SESSION',
        onSelect: (ctx) async {
          SessionService().setActiveSession(s);
        },
        haystack: '${s.title} ${s.sessionId}',
      ));
    }

    // Quick switcher stops here.
    if (!isFull) return out;

    // ── Recent activations (memory-cached per app) ───────────
    final acts = BackgroundAppService().activations;
    for (final a in acts) {
      out.add(SearchHit(
        title: '${a.triggerType.isNotEmpty ? a.triggerType : "manual"} · ${a.status}',
        subtitle: a.message.isNotEmpty
            ? a.message.split('\n').first
            : (a.error?.split('\n').first ?? a.id),
        icon: a.status == 'failed'
            ? Icons.error_outline_rounded
            : Icons.bolt_outlined,
        groupLabel: 'ACTIVATION',
        onSelect: (ctx) async {},
        haystack:
            '${a.triggerType} ${a.status} ${a.message} ${a.response} ${a.error ?? ""}',
      ));
    }

    // ── Settings sections + tools ────────────────────────────
    out.addAll([
      SearchHit(
        title: 'Settings · Usage & quotas',
        subtitle: 'Per-app token consumption, charts, forecast',
        icon: Icons.bar_chart_rounded,
        groupLabel: 'SETTINGS',
        onSelect: (ctx) async {
          AppStateAccess.of(ctx).setPanel(ActivePanel.settings);
        },
      ),
      SearchHit(
        title: 'Settings · Credentials',
        subtitle: 'Workspace-wide credentials view',
        icon: Icons.key_outlined,
        groupLabel: 'SETTINGS',
        onSelect: (ctx) async {
          AppStateAccess.of(ctx).setPanel(ActivePanel.settings);
        },
      ),
      SearchHit(
        title: 'Settings · Notifications',
        subtitle: 'Toggles, quiet hours',
        icon: Icons.notifications_none_rounded,
        groupLabel: 'SETTINGS',
        onSelect: (ctx) async {
          AppStateAccess.of(ctx).setPanel(ActivePanel.settings);
        },
      ),
      SearchHit(
        title: 'Settings · Appearance',
        subtitle: 'Theme, accent, density',
        icon: Icons.palette_outlined,
        groupLabel: 'SETTINGS',
        onSelect: (ctx) async {
          AppStateAccess.of(ctx).setPanel(ActivePanel.settings);
        },
      ),
      SearchHit(
        title: 'My Credentials',
        subtitle: 'Cross-app credentials dashboard',
        icon: Icons.vpn_key_outlined,
        groupLabel: 'TOOL',
        onSelect: (ctx) async {
          Navigator.of(ctx).push(
              MaterialPageRoute(builder: (_) => const MyCredentialsPage()));
        },
      ),
      SearchHit(
        title: 'Diagnostics',
        subtitle: 'Probe daemon health, latency, errors',
        icon: Icons.network_check_rounded,
        groupLabel: 'TOOL',
        onSelect: (ctx) async {
          Navigator.of(ctx).push(
              MaterialPageRoute(builder: (_) => const DiagnosticsPage()));
        },
      ),
    ]);

    // ── Per-app credentials shortcut for every deployed app ──
    for (final app in apps) {
      out.add(SearchHit(
        title: 'Configure ${app.name}',
        subtitle: 'Open this app\'s credentials form',
        icon: Icons.key_rounded,
        groupLabel: 'CREDENTIALS',
        onSelect: (ctx) async {
          Navigator.of(ctx).push(MaterialPageRoute(
            builder: (_) => CredentialsFormPage(
              appId: app.appId,
              appName: app.name,
            ),
          ));
        },
        haystack: 'configure credentials ${app.name} ${app.appId}',
      ));
    }

    return out;
  }

  List<SearchHit> get _filtered {
    if (_q.isEmpty) {
      // Quick switcher: surface apps first, sessions next.
      // Full mode: same default ordering; user types to refine.
      return _index;
    }
    final tokens = _q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    return _index.where((h) {
      for (final t in tokens) {
        if (!h.haystack.contains(t)) return false;
      }
      return true;
    }).toList();
  }

  void _execute(SearchHit hit) {
    // Capture the root context (still mounted at this point) before
    // we pop the dialog — we'll need it for the navigation callback.
    final rootCtx = Navigator.of(context).context;
    Navigator.pop(context);
    Future.microtask(() async {
      try {
        if (rootCtx.mounted) await hit.onSelect(rootCtx);
      } catch (_) {}
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hits = _filtered;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1).clamp(0, hits.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = (_highlight - 1).clamp(0, hits.length - 1));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (hits.isNotEmpty) _execute(hits[_highlight]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hits = _filtered;
    final isFull = widget.mode == SearchMode.full;

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 40, right: 40),
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: Builder(builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final w = size.width < 660 ? size.width - 32 : 620.0;
        final h = size.height < 560 ? size.height - 100 : 520.0;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: w, maxHeight: h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search input
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 10),
              child: Row(
                children: [
                  Icon(
                    isFull ? Icons.search_rounded : Icons.swap_horiz_rounded,
                    size: 17,
                    color: c.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focus,
                        autofocus: true,
                        style: GoogleFonts.inter(fontSize: 14, color: c.text),
                        decoration: InputDecoration(
                          hintText: isFull
                              ? 'Search apps, sessions, credentials, settings…'
                              : 'Switch to app or session…',
                          hintStyle: GoogleFonts.inter(
                              fontSize: 14, color: c.textMuted),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: c.border),
                    ),
                    child: Text(
                      isFull ? 'Ctrl+P' : 'Ctrl+T',
                      style: GoogleFonts.firaCode(
                        fontSize: 9.5,
                        color: c.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            // Results
            Flexible(
              child: hits.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(
                        child: Text(
                          'No match for "$_q"',
                          style: GoogleFonts.inter(
                              fontSize: 12, color: c.textMuted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      itemCount: hits.length,
                      itemBuilder: (_, i) => _ResultRow(
                        hit: hits[i],
                        highlighted: i == _highlight,
                        onTap: () => _execute(hits[i]),
                      ),
                    ),
            ),
            // Footer hint
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  _kbHint(c, '↑↓', 'navigate'),
                  const SizedBox(width: 14),
                  _kbHint(c, '↵', 'open'),
                  const SizedBox(width: 14),
                  _kbHint(c, 'Esc', 'close'),
                  const Spacer(),
                  Text('${hits.length} result${hits.length == 1 ? "" : "s"}',
                      style: GoogleFonts.firaCode(
                          fontSize: 9.5, color: c.textMuted)),
                ],
              ),
            ),
          ],
        ),
      );
      }),
    );
  }

  Widget _kbHint(AppColors c, String key, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: c.border),
          ),
          child: Text(key,
              style: GoogleFonts.firaCode(
                  fontSize: 9, color: c.textBright,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: GoogleFonts.inter(fontSize: 10, color: c.textMuted)),
      ],
    );
  }
}

class _ResultRow extends StatefulWidget {
  final SearchHit hit;
  final bool highlighted;
  final VoidCallback onTap;
  const _ResultRow({
    required this.hit,
    required this.highlighted,
    required this.onTap,
  });
  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isActive = widget.highlighted || _h;
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          color: isActive ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: c.border),
                ),
                child: Icon(widget.hit.icon, size: 13, color: c.text),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.textBright,
                      ),
                    ),
                    if (widget.hit.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.hit.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  widget.hit.groupLabel,
                  style: GoogleFonts.firaCode(
                    fontSize: 8.5,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny convenience to grab AppState from anywhere.
class AppStateAccess {
  static AppState of(BuildContext context) =>
      Provider.of<AppState>(context, listen: false);
}
