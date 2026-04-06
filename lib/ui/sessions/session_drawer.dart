import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../services/session_service.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';

class SessionDrawer extends StatefulWidget {
  final String appId;
  final VoidCallback onClose;

  const SessionDrawer({super.key, required this.appId, required this.onClose});

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<SessionDrawer> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SessionService().loadSessions(widget.appId);
    });
  }

  void _onSearchChanged() {
    setState(() {});
    _debounce?.cancel();
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) {
      // Clear search results immediately
      SessionService().searchResults = [];
      SessionService().isSearching = false;
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () {
      SessionService().searchSessions(widget.appId, query);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final isMobile = screenW < 600;
    final drawerWidth = isMobile ? screenW - 56 : 300.0;

    return GestureDetector(
      onHorizontalDragUpdate: isMobile
          ? (d) { if (d.delta.dx < -8) widget.onClose(); }
          : null,
      child: Container(
        width: drawerWidth,
        color: context.colors.bg,
        child: Column(
          children: [
            _DrawerHeader(
              searchCtrl: _searchCtrl,
              onNewSession: () {
                SessionService().createAndSetSession(widget.appId);
                widget.onClose();
              },
              onClose: widget.onClose,
            ),
            Expanded(child: _SessionList(
              appId: widget.appId,
              onSelect: widget.onClose,
              searchQuery: _searchCtrl.text,
            )),
            const _UserFooter(),
          ],
        ),
      ),
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

class _DrawerHeader extends StatelessWidget {
  final VoidCallback onNewSession;
  final VoidCallback onClose;
  final TextEditingController searchCtrl;
  const _DrawerHeader({
    required this.onNewSession,
    required this.onClose,
    required this.searchCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title row
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Icon(Icons.forum_outlined, color: context.colors.textMuted, size: 14),
                const SizedBox(width: 8),
                Text('Conversations',
                  style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w600, color: context.colors.text,
                  ),
                ),
                const Spacer(),
                _TinyBtn(icon: Icons.add_rounded, tooltip: 'New', onTap: onNewSession),
                const SizedBox(width: 2),
                _TinyBtn(icon: Icons.close_rounded, tooltip: 'Close', onTap: onClose),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: searchCtrl,
                style: GoogleFonts.inter(fontSize: 12, color: context.colors.text),
                decoration: InputDecoration(
                  hintText: 'Search…',
                  hintStyle: GoogleFonts.inter(fontSize: 12, color: context.colors.textDim),
                  prefixIcon: Icon(Icons.search_rounded, size: 14, color: context.colors.textDim),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32),
                  filled: true,
                  fillColor: context.colors.bg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: context.colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: context.colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: context.colors.borderHover),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Session list ────────────────────────────────────────────────────────────

class _SessionList extends StatelessWidget {
  final String appId;
  final VoidCallback onSelect;
  final String searchQuery;
  const _SessionList({required this.appId, required this.onSelect, this.searchQuery = ''});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: SessionService(),
      builder: (ctx, __) {
        final svc = SessionService();
        final query = searchQuery.trim();
        final isSearchMode = query.isNotEmpty;

        // ── Loading state ─────────────────────────────────────────
        if (svc.isLoading && !isSearchMode) {
          return Center(
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: c.textMuted),
          );
        }

        // ── Empty state (no sessions at all) ──────────────────────
        if (svc.sessions.isEmpty && !isSearchMode) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.chat_outlined, color: c.textDim, size: 32),
                const SizedBox(height: 12),
                Text('No conversations yet',
                    style: GoogleFonts.inter(color: c.textMuted, fontSize: 13)),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () {
                    SessionService().createAndSetSession(appId);
                    onSelect();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: c.border),
                    ),
                    child: Text('+ Start new',
                      style: GoogleFonts.inter(
                          color: c.textMuted, fontSize: 12, fontWeight: FontWeight.w500)),
                  ),
                ),
              ],
            ),
          );
        }

        // ── Search mode: show server results ──────────────────────
        if (isSearchMode) {
          if (svc.isSearching) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
              ),
            );
          }

          final results = svc.searchResults;
          if (results.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.search_off_rounded, size: 28, color: c.textDim),
                  const SizedBox(height: 8),
                  Text('No results for "$query"',
                    style: GoogleFonts.inter(color: c.textMuted, fontSize: 12)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            itemCount: results.length,
            itemBuilder: (_, i) => _SearchResultTile(
              result: results[i],
              isActive: results[i].sessionId == svc.activeSession?.sessionId,
              onTap: () {
                // Convert search result to AppSession and activate
                final r = results[i];
                final session = AppSession(
                  sessionId: r.sessionId,
                  appId: appId,
                  title: r.title,
                  messageCount: r.messageCount,
                  createdAt: r.createdAt,
                  lastActive: r.lastActive,
                );
                svc.setActiveSession(session);
                onSelect();
              },
            ),
          );
        }

        // ── Normal mode: grouped by time ──���───────────────────────
        final now = DateTime.now();
        final today = <AppSession>[];
        final yesterday = <AppSession>[];
        final older = <AppSession>[];

        for (final s in svc.sessions) {
          final dt = s.lastActive ?? s.createdAt;
          if (dt == null) { older.add(s); continue; }
          final diff = now.difference(dt).inDays;
          if (diff == 0 && dt.day == now.day) {
            today.add(s);
          } else if (diff <= 1) {
            yesterday.add(s);
          } else {
            older.add(s);
          }
        }

        return ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          children: [
            if (today.isNotEmpty) ...[
              _SectionLabel(label: 'Today'),
              for (final s in today) _buildTile(ctx, s, svc),
            ],
            if (yesterday.isNotEmpty) ...[
              _SectionLabel(label: 'Yesterday'),
              for (final s in yesterday) _buildTile(ctx, s, svc),
            ],
            if (older.isNotEmpty) ...[
              _SectionLabel(label: 'Previous'),
              for (final s in older) _buildTile(ctx, s, svc),
            ],
          ],
        );
      },
    );
  }

  Widget _buildTile(BuildContext context, AppSession s, SessionService svc) {
    final c = context.colors;
    final isActive = s.sessionId == svc.activeSession?.sessionId;
    return _SessionTile(
      session: s,
      isActive: isActive,
      onTap: () {
        svc.setActiveSession(s);
        onSelect();
      },
      onDelete: () {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: c.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            title: Text('Delete conversation?',
              style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: c.text)),
            content: Text('Session ${s.shortId} will be permanently deleted.',
              style: GoogleFonts.inter(fontSize: 13, color: c.textMuted)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: GoogleFonts.inter(color: c.textMuted)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  svc.deleteSession(appId, s.sessionId);
                },
                child: Text('Delete', style: GoogleFonts.inter(color: c.red)),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Section label ───────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: context.colors.textDim,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ─── Search result tile ─────────────────────────────────────────────────────

class _SearchResultTile extends StatefulWidget {
  final SessionSearchResult result;
  final bool isActive;
  final VoidCallback onTap;
  const _SearchResultTile({
    required this.result,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_SearchResultTile> createState() => _SearchResultTileState();
}

class _SearchResultTileState extends State<_SearchResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = widget.result;
    final snippet = r.snippets.isNotEmpty ? r.snippets.first : '';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isActive
                ? c.surfaceAlt
                : _hovered ? c.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.isActive ? c.borderHover : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Row(
                children: [
                  Icon(Icons.search_rounded, size: 12, color: c.textDim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.title.isNotEmpty ? r.title : r.shortId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: c.text,
                      ),
                    ),
                  ),
                  if (r.messageCount > 0)
                    Text('${r.messageCount} msg',
                      style: GoogleFonts.firaCode(fontSize: 9, color: c.textDim)),
                ],
              ),
              // Snippet preview
              if (snippet.isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: Text(
                    snippet.replaceFirst(RegExp(r'^(title|message\[\d+\]):\s*'), ''),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: c.textMuted,
                      height: 1.4,
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

// ─── Session tile ────────────────────────────────────────────────────────────

class _SessionTile extends StatefulWidget {
  final AppSession session;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionTile({
    required this.session,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isActive
                ? context.colors.surfaceAlt
                : _hovered
                    ? context.colors.surfaceAlt
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.isActive
                  ? context.colors.borderHover
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              // Left icon
              Icon(
                widget.isActive
                    ? Icons.chat_bubble_rounded
                    : Icons.chat_bubble_outline_rounded,
                size: 13,
                color: widget.isActive
                    ? context.colors.green
                    : context.colors.textDim,
              ),
              const SizedBox(width: 10),

              // Title + meta
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: widget.isActive
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: widget.isActive ? context.colors.text : context.colors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (s.messageCount > 0) ...[
                          Text(
                            '${s.messageCount} msg',
                            style: GoogleFonts.inter(
                                fontSize: 10, color: context.colors.textDim),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (s.timeAgo.isNotEmpty)
                          Text(
                            s.timeAgo,
                            style: GoogleFonts.inter(
                                fontSize: 10, color: context.colors.textDim),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              // Delete button (visible on hover or active)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 100),
                opacity: (_hovered || widget.isActive) ? 1 : 0,
                child: GestureDetector(
                  onTap: widget.onDelete,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.close_rounded,
                        size: 13, color: context.colors.textDim),
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

// ─── User footer ─────────────────────────────────────────────────────────────

class _UserFooter extends StatelessWidget {
  const _UserFooter();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthService(),
      builder: (_, __) {
        final user = AuthService().currentUser;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.colors.border)),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.colors.border),
                ),
                child: Icon(Icons.person_outline_rounded,
                    size: 14, color: context.colors.textMuted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.displayName ?? user?.userId ?? 'Guest',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: context.colors.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (user?.email != null)
                      Text(
                        user!.email!,
                        style: GoogleFonts.inter(
                            fontSize: 10, color: context.colors.textDim),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              _TinyBtn(
                icon: Icons.logout_rounded,
                tooltip: 'Logout',
                onTap: () => AuthService().logout(),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Tiny icon button ───────────────────────────────────────────��────────────

class _TinyBtn extends StatefulWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback onTap;

  const _TinyBtn({required this.icon, this.tooltip, required this.onTap});

  @override
  State<_TinyBtn> createState() => _TinyBtnState();
}

class _TinyBtnState extends State<_TinyBtn> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final btn = MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _h ? context.colors.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(widget.icon,
              size: 14, color: _h ? context.colors.text : context.colors.textMuted),
        ),
      ),
    );
    return widget.tooltip != null
        ? Tooltip(message: widget.tooltip!, child: btn)
        : btn;
  }
}
