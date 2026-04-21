/// Bell icon that lives in the activity bar + the dropdown overlay
/// it opens. Reads from [ActivityInboxService] and renders one row
/// per derived event (failed run, missing credential, expired
/// token…). Every row has an action affordance that routes the user
/// straight to the place they'd fix it.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../models/app_summary.dart';
import '../../services/activity_inbox_service.dart';
import '../../services/apps_service.dart';
import '../../services/session_service.dart';
import '../../theme/app_theme.dart';
import '../credentials/credentials_form.dart';

class InboxBell extends StatefulWidget {
  const InboxBell({super.key});

  @override
  State<InboxBell> createState() => _InboxBellState();
}

class _InboxBellState extends State<InboxBell> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final inbox = context.watch<ActivityInboxService>();
    final state = context.watch<AppState>();
    final excludeAppId =
        state.panel == ActivePanel.chat ? state.activeApp?.appId : null;
    final excludeSessionId = state.panel == ActivePanel.chat
        ? SessionService().activeSession?.sessionId
        : null;
    final unread = inbox.unreadCountFiltered(
      excludeAppId: excludeAppId,
      excludeSessionId: excludeSessionId,
    );
    final running = inbox.runningCount;
    return Tooltip(
      message: running > 0
          ? 'Inbox · $unread unread · $running running'
          : 'Inbox · $unread unread',
      child: MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _openDropdown(context),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _h ? c.surfaceAlt : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _h ? c.border : Colors.transparent,
                  ),
                ),
                child: Icon(
                  unread > 0
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_none_rounded,
                  size: 24,
                  color: unread > 0 ? c.blue : c.textMuted,
                ),
              ),
              if (unread > 0)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(
                        minWidth: 16, minHeight: 16),
                    decoration: BoxDecoration(
                      color: c.red,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.surface, width: 1.5),
                    ),
                    child: Text(
                      unread > 9 ? '9+' : '$unread',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.firaCode(
                        fontSize: 9,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDropdown(BuildContext context) async {
    final inbox = ActivityInboxService();
    // Hydrate from the daemon then fetch the authoritative unread
    // count — the two calls run in parallel so the dropdown opens
    // with fresh data in one round trip.
    await Future.wait([
      inbox.refresh(),
      inbox.fetchUnreadCountFromServer(),
    ]);
    if (!context.mounted) return;
    await showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => const _InboxDialog(),
    );
    inbox.markAllRead();
  }
}

class _InboxDialog extends StatelessWidget {
  const _InboxDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final inbox = context.watch<ActivityInboxService>();
    final state = context.watch<AppState>();
    final excludeAppId =
        state.panel == ActivePanel.chat ? state.activeApp?.appId : null;
    final excludeSessionId = state.panel == ActivePanel.chat
        ? SessionService().activeSession?.sessionId
        : null;
    final items = inbox.itemsFiltered(
      excludeAppId: excludeAppId,
      excludeSessionId: excludeSessionId,
    );
    final hiddenCount = inbox.items.length - items.length;
    final rawUnread = inbox.unreadCount;
    final showCountMismatch = items.isEmpty && rawUnread > 0;
    final screen = MediaQuery.sizeOf(context);
    final isNarrow = screen.width < 560;
    final maxW = isNarrow ? screen.width - 24 : 460.0;
    final maxH = screen.height < 620 ? screen.height - 96 : 540.0;
    return Dialog(
      alignment: isNarrow ? Alignment.topCenter : Alignment.topLeft,
      insetPadding: isNarrow
          ? const EdgeInsets.only(top: 60, left: 12, right: 12)
          : const EdgeInsets.only(top: 60, left: 60),
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.notifications_active_outlined,
                      size: 16, color: c.text),
                  const SizedBox(width: 8),
                  Text('inbox.title'.tr(),
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: c.textBright)),
                  const Spacer(),
                  TextButton(
                    onPressed: items.isEmpty
                        ? null
                        : () => inbox.markAllRead(),
                    child: Text('inbox.mark_all_read'.tr(),
                        style: GoogleFonts.inter(
                            fontSize: 11, color: c.textMuted)),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.refresh_rounded, color: c.textMuted),
                    onPressed: () => inbox.refresh(),
                  ),
                  IconButton(
                    iconSize: 16,
                    icon: Icon(Icons.close_rounded, color: c.textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            // Body
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              showCountMismatch
                                  ? Icons.sync_problem_rounded
                                  : Icons.check_circle_outline_rounded,
                              size: 36,
                              color:
                                  showCountMismatch ? c.orange : c.green,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              showCountMismatch
                                  ? 'Items missing'
                                  : hiddenCount > 0
                                      ? 'You\'re all caught up here'
                                      : 'All clear',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: c.textBright,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              showCountMismatch
                                  ? 'The daemon reports $rawUnread unread but returned no items. Try refresh.'
                                  : hiddenCount > 0
                                      ? '$hiddenCount notification${hiddenCount > 1 ? 's' : ''} hidden for the current chat.'
                                      : 'Nothing needs your attention right now.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: c.textMuted),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: c.border),
                      itemBuilder: (_, i) => _InboxRow(item: items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxRow extends StatefulWidget {
  final InboxItem item;
  const _InboxRow({required this.item});
  @override
  State<_InboxRow> createState() => _InboxRowState();
}

class _InboxRowState extends State<_InboxRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final i = widget.item;
    final read = ActivityInboxService().isRead(i.id);
    final (icon, tint) = switch (i.kind) {
      InboxItemKind.failure => (Icons.error_outline_rounded, c.red),
      InboxItemKind.credentialExpired => (Icons.lock_clock_outlined, c.orange),
      InboxItemKind.credentialMissing => (Icons.lock_outline_rounded, c.red),
      InboxItemKind.info => (Icons.info_outline_rounded, c.blue),
      InboxItemKind.sessionRunning =>
        (Icons.autorenew_rounded, c.blue),
      InboxItemKind.sessionCompleted =>
        (Icons.check_circle_outline_rounded, c.green),
      InboxItemKind.sessionFailed =>
        (Icons.error_outline_rounded, c.red),
      InboxItemKind.awaitingApproval =>
        (Icons.front_hand_outlined, c.purple),
      InboxItemKind.bgActivationFinished =>
        (Icons.bolt_outlined, c.green),
    };
    return MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _open(context, i),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!read)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(top: 6, right: 8),
                  decoration:
                      BoxDecoration(color: c.blue, shape: BoxShape.circle),
                )
              else
                const SizedBox(width: 14),
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: tint.withValues(alpha: 0.35)),
                ),
                child: Icon(icon, size: 13, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(i.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: c.textBright)),
                    const SizedBox(height: 2),
                    Text(i.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                            fontSize: 10.5,
                            color: c.textMuted,
                            height: 1.4)),
                    const SizedBox(height: 3),
                    Text(_timeAgo(i.when),
                        style: GoogleFonts.firaCode(
                            fontSize: 9.5, color: c.textDim)),
                  ],
                ),
              ),
              if (_h)
                IconButton(
                  tooltip: 'inbox.archive'.tr(),
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: Icon(Icons.archive_outlined, color: c.textMuted),
                  onPressed: () => ActivityInboxService().archive(i.id),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, InboxItem i) {
    ActivityInboxService().markRead(i.id);
    final navigator = Navigator.of(context);
    final state = Provider.of<AppState>(context, listen: false);
    Navigator.pop(context);
    if (i.appId == null) return;

    // Credentials issues → push the per-app form on the navigator.
    if (i.kind == InboxItemKind.credentialMissing ||
        i.kind == InboxItemKind.credentialExpired) {
      navigator.push(MaterialPageRoute(
        builder: (_) => CredentialsFormPage(appId: i.appId!),
      ));
      return;
    }

    // Session-scoped events → switch to the right app, then to the
    // right session. The chat panel will reload history + replay any
    // pending events thanks to `?since=`.
    if (i.kind == InboxItemKind.sessionRunning ||
        i.kind == InboxItemKind.sessionCompleted ||
        i.kind == InboxItemKind.sessionFailed ||
        i.kind == InboxItemKind.awaitingApproval ||
        i.kind == InboxItemKind.failure) {
      _navigateToSession(state, i.appId!, i.sessionId);
      return;
    }
  }

  /// Switch the global AppState to the right app, then ask
  /// SessionService to make the right session active. If we don't
  /// have an AppSummary cached for [appId] we fetch the apps list
  /// once before deciding what to do.
  Future<void> _navigateToSession(
    AppState state,
    String appId,
    String? sessionId,
  ) async {
    AppSummary? app;
    for (final a in AppsService().apps) {
      if (a.appId == appId) {
        app = a;
        break;
      }
    }
    if (app == null) {
      try {
        await AppsService().refresh();
        for (final a in AppsService().apps) {
          if (a.appId == appId) {
            app = a;
            break;
          }
        }
      } catch (_) {}
    }
    if (app == null) return;
    await state.setApp(app);
    if (sessionId != null && sessionId.isNotEmpty) {
      // Best-effort: fetch the AppSession from the service if it's
      // already in memory; otherwise just request it by id.
      AppSession? target;
      for (final s in SessionService().sessions) {
        if (s.sessionId == sessionId) {
          target = s;
          break;
        }
      }
      target ??= AppSession(sessionId: sessionId, appId: appId);
      SessionService().setActiveSession(target);
    }
    state.setPanel(ActivePanel.chat);
  }

  static String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 30) return 'just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
