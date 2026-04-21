/// Cross-app "Recent conversations" — backed by
/// `GET /api/users/me/sessions`. Lists every session the user has
/// touched across every app, newest first. Each row uses the
/// daemon-enriched `app_icon` / `app_color` / `last_message_preview`
/// so we don't need a per-row fetch.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../models/app_summary.dart';
import '../../services/apps_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../common/remote_icon.dart';

class RecentConversationsPage extends StatefulWidget {
  const RecentConversationsPage({super.key});

  @override
  State<RecentConversationsPage> createState() =>
      _RecentConversationsPageState();
}

class _RecentConversationsPageState extends State<RecentConversationsPage> {
  bool _loading = true;
  String? _error;
  List<AppSession> _sessions = const [];
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await SessionService().loadCrossAppSessions();
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<AppSession> get _filtered {
    if (_query.isEmpty) return _sessions;
    final q = _query.toLowerCase();
    return _sessions.where((s) {
      return s.title.toLowerCase().contains(q) ||
          (s.appName?.toLowerCase().contains(q) ?? false) ||
          (s.lastMessagePreview?.toLowerCase().contains(q) ?? false) ||
          s.appId.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _openSession(AppSession session) async {
    final state = Provider.of<AppState>(context, listen: false);
    AppSummary? app;
    for (final a in AppsService().apps) {
      if (a.appId == session.appId) {
        app = a;
        break;
      }
    }
    if (app == null) {
      try {
        await AppsService().refresh();
        for (final a in AppsService().apps) {
          if (a.appId == session.appId) {
            app = a;
            break;
          }
        }
      } catch (_) {}
    }
    if (app == null || !mounted) return;
    await state.setApp(app);
    SessionService().setActiveSession(session);
    state.setPanel(ActivePanel.chat);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        elevation: 0,
        foregroundColor: c.text,
        title: Text('Recent conversations',
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            )
          : _error != null
              ? _buildError(c)
              : _buildList(c),
    );
  }

  Widget _buildError(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 36, color: c.red),
              const SizedBox(height: 12),
              Text(_error!,
                  style:
                      GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _load,
                child: Text('Retry',
                    style: GoogleFonts.inter(fontSize: 12)),
              ),
            ],
          ),
        ),
      );

  Widget _buildList(AppColors c) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 28, 40, 60),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Recent conversations',
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  )),
              const SizedBox(height: 5),
              Text(
                'Sessions across every app, newest first. Tap any row to jump back into the conversation.',
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  color: c.textMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded,
                        size: 14, color: c.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) =>
                            setState(() => _query = v.trim()),
                        style: GoogleFonts.inter(
                            fontSize: 12.5, color: c.textBright),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Search by title, app, message…',
                          hintStyle: GoogleFonts.inter(
                              fontSize: 12.5, color: c.textMuted),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_filtered.isEmpty)
                Container(
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.border),
                  ),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.history_rounded,
                            size: 36, color: c.textDim),
                        const SizedBox(height: 12),
                        Text(
                          _query.isNotEmpty
                              ? 'No session matches "$_query"'
                              : 'No conversation yet',
                          style: GoogleFonts.inter(
                              fontSize: 13, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < _filtered.length; i++) ...[
                        _SessionRow(
                          session: _filtered[i],
                          onTap: () => _openSession(_filtered[i]),
                        ),
                        if (i < _filtered.length - 1)
                          Divider(height: 1, color: c.border),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SessionRow extends StatefulWidget {
  final AppSession session;
  final VoidCallback onTap;
  const _SessionRow({required this.session, required this.onTap});

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  bool _h = false;

  Color? _parseAppColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.replaceAll('#', '');
    if (cleaned.length != 6 && cleaned.length != 8) return null;
    final value = int.tryParse(
        cleaned.length == 6 ? 'FF$cleaned' : cleaned,
        radix: 16);
    if (value == null) return null;
    return Color(value);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = widget.session;
    final accent = _parseAppColor(s.appColor);
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              RemoteIcon(
                id: s.appId,
                kind: RemoteIconKind.app,
                size: 42,
                transparent: true,
                emojiFallback: s.appIcon,
                nameFallback: s.appName ?? s.appId,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: c.textBright,
                            ),
                          ),
                        ),
                        if (s.isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: c.green.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(
                                  color:
                                      c.green.withValues(alpha: 0.4)),
                            ),
                            child: Text('LIVE',
                                style: GoogleFonts.firaCode(
                                    fontSize: 8.5,
                                    color: c.green,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (s.appName != null)
                          Text(s.appName!,
                              style: GoogleFonts.firaCode(
                                  fontSize: 10.5,
                                  color: accent ?? c.textMuted,
                                  fontWeight: FontWeight.w600)),
                        if (s.appName != null) ...[
                          const SizedBox(width: 6),
                          Text('·',
                              style: GoogleFonts.firaCode(
                                  fontSize: 10.5, color: c.textMuted)),
                          const SizedBox(width: 6),
                        ],
                        Text(s.timeAgo,
                            style: GoogleFonts.firaCode(
                                fontSize: 10, color: c.textMuted)),
                        const SizedBox(width: 6),
                        Text('·',
                            style: GoogleFonts.firaCode(
                                fontSize: 10.5, color: c.textMuted)),
                        const SizedBox(width: 6),
                        Text(
                            '${s.messageCount} msg${s.messageCount == 1 ? '' : 's'}',
                            style: GoogleFonts.firaCode(
                                fontSize: 10, color: c.textMuted)),
                      ],
                    ),
                    if (s.lastMessagePreview != null &&
                        s.lastMessagePreview!.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        s.lastMessagePreview!.replaceAll('\n', ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: c.text,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: _h ? c.text : c.textDim),
            ],
          ),
        ),
      ),
    );
  }
}
