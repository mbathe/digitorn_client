import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/app_summary.dart';
import '../../services/background_app_service.dart';
import '../../services/cron.dart';
import '../../services/payload_service.dart';
import '../../services/session_share.dart';
import '../../services/user_events_service.dart';
import '../../theme/app_theme.dart';
import '../credentials/credential_gate.dart';
import '../credentials/credentials_form.dart';
import 'activation_drawer.dart';
import 'activations_page.dart';
import 'session_payload_page.dart';
import 'widgets/sparkline.dart';

/// Full rewrite of the background-app dashboard (v2).
///
/// Layout (vertical scroll):
/// 1. Hero header — app identity + live pulse status + meta
/// 2. Hero stats card — 4 big metrics + 24h sparkline + trend
/// 3. Triggers — cards with type, status, per-trigger metrics
/// 4. Channels — live health with status dots and errors
/// 5. Sessions — user-scoped background sessions with avatars
/// 6. Recent activations — clickable → [ActivationDrawer]
class BackgroundDashboard extends StatefulWidget {
  final AppSummary app;
  final VoidCallback onBack;
  const BackgroundDashboard({
    super.key,
    required this.app,
    required this.onBack,
  });

  @override
  State<BackgroundDashboard> createState() => _BackgroundDashboardState();
}

class _BackgroundDashboardState extends State<BackgroundDashboard>
    with WidgetsBindingObserver {
  final _svc = BackgroundAppService();
  final _payloadSvc = PayloadService();
  final Map<String, SessionPayload> _sessionPayloads = {};
  final TextEditingController _sessionFilter = TextEditingController();
  bool _loading = true;
  StreamSubscription<UserEvent>? _eventSub;

  /// Derived per-session health from the recent activations list.
  /// Rebuilt every time either sessions or activations change.
  Map<String, _SessionHealth> _sessionHealth = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialLoad();
    _bindEvents();
  }

  static const _relevantEventTypes = {
    'bg.activation_completed',
    'session.completed',
    'session.failed',
    'session.started',
  };

  void _bindEvents() {
    _eventSub?.cancel();
    _eventSub = UserEventsService().events.listen((event) {
      if (!mounted) return;
      if (event.appId != null && event.appId != widget.app.appId) return;
      if (_relevantEventTypes.contains(event.type)) {
        _svc.loadStatus(widget.app.appId);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _svc.loadStatus(widget.app.appId);
    }
  }

  Future<void> _initialLoad() async {
    await Future.wait([
      _svc.loadStatus(widget.app.appId),
      _svc.loadTriggers(widget.app.appId),
      _svc.loadChannelsHealth(widget.app.appId),
      _svc.loadSessions(widget.app.appId),
      _svc.loadActivations(widget.app.appId, limit: 20),
    ]);
    await _loadSessionPayloads();
    _rebuildSessionHealth();
    if (mounted) setState(() => _loading = false);
  }

  /// Group the 20 most-recent activations by session and derive:
  /// last status, consecutive failures, response preview, last error.
  /// Pure function of `_svc.activations` + `_svc.sessions`, so it
  /// can be called whenever either changes.
  void _rebuildSessionHealth() {
    final bySession = <String, List<Activation>>{};
    for (final a in _svc.activations) {
      if (a.sessionId.isEmpty) continue;
      bySession.putIfAbsent(a.sessionId, () => []).add(a);
    }
    final out = <String, _SessionHealth>{};
    for (final entry in bySession.entries) {
      // Activations should already arrive newest-first, but sort
      // defensively by completedAt/startedAt desc in case the daemon
      // changes ordering.
      final list = entry.value
        ..sort((a, b) {
          final ta = a.completedAt ?? a.startedAt;
          final tb = b.completedAt ?? b.startedAt;
          if (ta == null && tb == null) return 0;
          if (ta == null) return 1;
          if (tb == null) return -1;
          return tb.compareTo(ta);
        });
      var consecutiveFails = 0;
      for (final a in list) {
        if (a.status == 'failed') {
          consecutiveFails++;
        } else {
          break;
        }
      }
      final lastSuccess = list.firstWhere(
        (a) => a.status == 'completed' && a.response.isNotEmpty,
        orElse: () => list.first,
      );
      final last = list.first;
      out[entry.key] = _SessionHealth(
        lastStatus: last.status,
        consecutiveFails: consecutiveFails,
        lastError: last.status == 'failed' ? last.error : null,
        responsePreview: lastSuccess.response,
      );
    }
    _sessionHealth = out;
  }

  /// Fetches each session's payload in parallel so the cards can show
  /// a live preview (prompt + file count) of what each session is
  /// configured to do. Errors per-session are swallowed silently — a
  /// missing preview just means no extra summary line on that card.
  Future<void> _loadSessionPayloads() async {
    final sessions = _svc.sessions;
    if (sessions.isEmpty) {
      _sessionPayloads.clear();
      return;
    }
    final results = await Future.wait(
      sessions.map((s) async {
        try {
          final p = await _payloadSvc.get(widget.app.appId, s.id);
          return MapEntry(s.id, p);
        } catch (_) {
          return MapEntry(s.id, SessionPayload.empty);
        }
      }),
      eagerError: false,
    );
    _sessionPayloads
      ..clear()
      ..addEntries(results);
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await _initialLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _sessionFilter.dispose();
    super.dispose();
  }

  /// Filter sessions by name or by a substring of their prompt preview.
  /// Empty query → all sessions. Case-insensitive.
  List<BackgroundSession> _filteredSessions() {
    final q = _sessionFilter.text.trim().toLowerCase();
    if (q.isEmpty) return _svc.sessions;
    return _svc.sessions.where((s) {
      if (s.name.toLowerCase().contains(q)) return true;
      final p = _sessionPayloads[s.id];
      if (p != null && p.prompt.toLowerCase().contains(q)) return true;
      return false;
    }).toList(growable: false);
  }

  Widget _buildSessionFilter(AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 14, color: c.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _sessionFilter,
                onChanged: (_) => setState(() {}),
                style: GoogleFonts.inter(fontSize: 12, color: c.textBright),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'background.filter_sessions'.tr(),
                  hintStyle:
                      GoogleFonts.inter(fontSize: 12, color: c.textMuted),
                ),
              ),
            ),
            if (_sessionFilter.text.isNotEmpty)
              GestureDetector(
                onTap: () => setState(() => _sessionFilter.clear()),
                child: Icon(Icons.close_rounded,
                    size: 14, color: c.textMuted),
              ),
          ],
        ),
      ),
    );
  }

  /// Clone a session's prompt + metadata + params into a new one.
  /// Files aren't copied (no download endpoint on the client) — we
  /// warn the user in the success toast so they can re-upload.
  Future<void> _duplicateSession(BackgroundSession source) async {
    try {
      final clone = await _svc.createSession(
        widget.app.appId,
        name: _copyName(source.name),
        params: Map<String, dynamic>.from(source.params),
        routingKeys: Map<String, dynamic>.from(source.routingKeys),
        workspace: source.workspace,
      );
      if (clone == null) {
        _toast('Failed to duplicate session', err: true);
        return;
      }
      final src = _sessionPayloads[source.id];
      if (src != null && !src.isEmpty) {
        await _payloadSvc.setPromptAndMetadata(
          widget.app.appId,
          clone.id,
          prompt: src.prompt,
          metadata: src.metadata,
        );
      }
      await _loadSessionPayloads();
      if (!mounted) return;
      setState(() {});
      _toast(src != null && src.files.isNotEmpty
          ? 'Duplicated — files were NOT copied, re-upload manually'
          : 'Session duplicated');
    } catch (e) {
      _toast('Duplicate failed: $e', err: true);
    }
  }

  void _openSessionRuns(BackgroundSession s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ActivationsPage(
        appId: widget.app.appId,
        appName: widget.app.name,
        triggers: _svc.triggerInfo?.triggers ?? const [],
        sessionId: s.id,
        sessionName: s.name.isNotEmpty ? s.name : null,
      ),
    ));
  }

  /// Build a `digitorn://session?d=…` link from a session's config
  /// + payload and copy it to the clipboard. Keeps the door open for
  /// the daemon to register a custom URL handler later — for now the
  /// receiving user pastes it back into "Import from link".
  Future<void> _shareLink(BackgroundSession s) async {
    final payload = _sessionPayloads[s.id];
    final blob = ShareableSession(
      appId: widget.app.appId,
      name: s.name,
      params: s.params,
      routingKeys: s.routingKeys,
      workspace: s.workspace,
      prompt: payload?.prompt ?? '',
      metadata: payload?.metadata ?? const {},
    );
    final link = SessionShareCodec.encode(blob);
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    _toast('Share link copied · ${link.length} chars');
  }

  /// Serialize a session's full configuration (name, params, payload)
  /// into a pretty-printed JSON string and copy it to the clipboard.
  /// Format is symmetrical with the daemon's shape so another user
  /// can paste it back into a new session of the same app.
  Future<void> _exportSession(BackgroundSession s) async {
    final payload = _sessionPayloads[s.id];
    final blob = <String, dynamic>{
      'schema': 'digitorn.session.v1',
      'app_id': widget.app.appId,
      'session': {
        'name': s.name,
        'params': s.params,
        'routing_keys': s.routingKeys,
        if (s.workspace.isNotEmpty) 'workspace': s.workspace,
      },
      if (payload != null && !payload.isEmpty)
        'payload': {
          'prompt': payload.prompt,
          'metadata': payload.metadata,
          'files': payload.files
              .map((f) => {
                    'name': f.name,
                    'mime_type': f.mimeType,
                    'size_bytes': f.sizeBytes,
                  })
              .toList(),
        },
    };
    final json = const JsonEncoder.withIndent('  ').convert(blob);
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    _toast(payload != null && payload.files.isNotEmpty
        ? 'JSON copied — note file contents are NOT included, only metadata'
        : 'JSON copied to clipboard');
  }

  static String _copyName(String name) {
    if (name.isEmpty) return 'Copy';
    final m = RegExp(r'^(.*?)(?: \(copy(?: (\d+))?\))?$').firstMatch(name);
    if (m == null) return '$name (copy)';
    final base = m.group(1) ?? name;
    final n = int.tryParse(m.group(2) ?? '');
    if (n == null && m.group(0) == base) return '$base (copy)';
    if (n == null) return '$base (copy 2)';
    return '$base (copy ${n + 1})';
  }

  void _toast(String msg, {bool err = false}) {
    if (!mounted) return;
    final c = context.colors;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          (err ? c.red : c.green).withValues(alpha: 0.9),
      duration: const Duration(seconds: 3),
    ));
  }

  /// An app supports user-scoped background sessions when at least one
  /// of its triggers is routed non-broadcast (i.e. per-user or
  /// round-robin) — otherwise there's only one logical session and
  /// the "+ New" button would just fail server-side. We also allow
  /// sessions for apps that declared any routing_keys on their
  /// trigger configuration.
  bool get _supportsSessions {
    final triggers = _svc.triggerInfo?.triggers ?? const [];
    if (triggers.isEmpty) return false;
    return triggers.any(
      (t) => (t.routing.isNotEmpty && t.routing != 'broadcast') ||
          (t.routingKey != null && t.routingKey!.isNotEmpty),
    );
  }

  Future<void> _openCreateSessionDialog() async {
    // Gate: creating a session is destructive — block until the app
    // has a complete credentials set.
    if (!await ensureCredentials(
      context,
      appId: widget.app.appId,
      appName: widget.app.name,
    )) {
      return;
    }
    if (!mounted) return;
    final triggers = _svc.triggerInfo?.triggers ?? const [];
    // Collect every distinct routing key referenced by the triggers so
    // we can pre-populate the form with empty inputs — otherwise the
    // user has to remember which keys matter.
    final routingKeys = <String>{
      for (final t in triggers)
        if (t.routingKey != null && t.routingKey!.isNotEmpty) t.routingKey!,
    }.toList();

    final created = await showDialog<BackgroundSession?>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _CreateSessionDialog(
        appId: widget.app.appId,
        routingKeys: routingKeys,
        svc: _svc,
      ),
    );
    if (created != null && mounted) {
      // The service already inserted the new session at the top of
      // the list, but we force a reload of activations / stats so
      // everything stays coherent.
      _svc.loadSessions(widget.app.appId);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('background.session_created'
            .tr(namedArgs: {'name': created.name})),
        backgroundColor: context.colors.green.withValues(alpha: 0.9),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void _openActivation(Activation a) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, _, _) =>
          ActivationDrawer(appId: widget.app.appId, activation: a),
    ));
  }

  void _openCredentials() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CredentialsFormPage(
        appId: widget.app.appId,
        appName: widget.app.name,
      ),
    ));
  }

  Future<void> _openSessionPayload(BackgroundSession session) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SessionPayloadPage(
        appId: widget.app.appId,
        session: session,
        triggers: _svc.triggerInfo?.triggers ?? const [],
        schema: PayloadSchema.parse(widget.app.payloadSchema),
      ),
    ));
    // The payload page may have changed the session's state on the
    // server (e.g. via a manual trigger fire). Force-refresh the
    // dashboard's sessions/activations list when we come back.
    if (mounted) {
      await _svc.loadSessions(widget.app.appId);
      await _loadSessionPayloads();
      await _svc.loadActivations(widget.app.appId, limit: 20);
      _rebuildSessionHealth();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSmall = MediaQuery.of(context).size.width < 600;

    return Container(
      color: c.bg,
      child: Column(
        children: [
          _HeroHeader(
            app: widget.app,
            status: _svc.status,
            onBack: widget.onBack,
            onRefresh: _refresh,
            onOpenCredentials: _openCredentials,
          ),
          Expanded(
            child: _loading
                ? Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: c.textMuted),
                    ),
                  )
                : ListenableBuilder(
                    listenable: _svc,
                    builder: (ctx, _) {
                      return ListView(
                        padding: EdgeInsets.symmetric(
                          horizontal: isSmall ? 16 : 32,
                          vertical: 24,
                        ),
                        children: [
                          if (_svc.status != null)
                            _HeroStatsCard(status: _svc.status!)
                          else if (_svc.stats != null)
                            _HeroStatsCard(
                              status: AppStatus(stats: _svc.stats),
                            ),
                          const SizedBox(height: 28),

                          // ── Triggers ─────────────────────────────
                          if (_svc.triggerInfo != null &&
                              _svc.triggerInfo!.triggers.isNotEmpty) ...[
                            _SectionHeader(
                                label: 'background.triggers'.tr(),
                                count: _svc.triggerInfo!.triggers.length),
                            const SizedBox(height: 10),
                            for (final t in _svc.triggerInfo!.triggers)
                              _TriggerCard(
                                trigger: t,
                                appId: widget.app.appId,
                                appName: widget.app.name,
                                svc: _svc,
                              ),
                            const SizedBox(height: 26),
                          ],

                          // ── Channels ─────────────────────────────
                          if (_svc.channelsHealth.isNotEmpty ||
                              (_svc.triggerInfo?.channels.isNotEmpty ?? false)) ...[
                            _SectionHeader(
                                label: 'background.channels'.tr(),
                                count: _svc.channelsHealth.isNotEmpty
                                    ? _svc.channelsHealth.length
                                    : _svc.triggerInfo!.channels.length),
                            const SizedBox(height: 10),
                            if (_svc.channelsHealth.isNotEmpty)
                              for (final ch in _svc.channelsHealth)
                                _ChannelHealthCard(channel: ch)
                            else
                              for (final ch in _svc.triggerInfo!.channels)
                                _ChannelHealthCard(
                                  channel: ChannelHealth(
                                    name: ch.name,
                                    type: ch.type,
                                    status: ch.status,
                                    sent: ch.eventsReceived,
                                    lastSentAt: ch.lastEventAt,
                                  ),
                                ),
                            const SizedBox(height: 26),
                          ],

                          // ── Sessions ─────────────────────────────
                          _SectionHeader(
                            label: 'background.sessions_label'.tr(),
                            count: _svc.sessions.length,
                            action: _supportsSessions
                                ? _NewSessionBtn(
                                    onTap: _openCreateSessionDialog)
                                : null,
                          ),
                          const SizedBox(height: 10),
                          if (_svc.sessions.length >= 5)
                            _buildSessionFilter(c),
                          if (_svc.sessions.isEmpty)
                            const _EmptyBlock(
                              icon: Icons.person_outline_rounded,
                              text: 'No background sessions yet',
                            )
                          else ...[
                            for (final s in _filteredSessions())
                              _SessionCard(
                                session: s,
                                payload: _sessionPayloads[s.id],
                                health: _sessionHealth[s.id],
                                onTap: () => _openSessionPayload(s),
                                onDuplicate: () => _duplicateSession(s),
                                onExport: () => _exportSession(s),
                                onShareLink: () => _shareLink(s),
                                onViewRuns: () => _openSessionRuns(s),
                              ),
                            if (_filteredSessions().isEmpty)
                              _EmptyBlock(
                                icon: Icons.search_off_rounded,
                                text:
                                    'No session matches "${_sessionFilter.text}"',
                              ),
                          ],
                          const SizedBox(height: 26),

                          // ── Recent activations ───────────────────
                          _SectionHeader(
                              label: 'background.recent_activations'.tr(),
                              count: _svc.activations.length),
                          const SizedBox(height: 10),
                          if (_svc.activations.isEmpty)
                            const _EmptyBlock(
                              icon: Icons.history_rounded,
                              text:
                                  'No activations yet — triggers will show up here',
                            )
                          else
                            Container(
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: c.border),
                              ),
                              child: Column(
                                children: [
                                  for (var i = 0;
                                      i < _svc.activations.length;
                                      i++) ...[
                                    _ActivationRow(
                                      activation: _svc.activations[i],
                                      onTap: () =>
                                          _openActivation(_svc.activations[i]),
                                    ),
                                    if (i < _svc.activations.length - 1)
                                      Divider(
                                          height: 1,
                                          thickness: 1,
                                          color: c.border),
                                  ],
                                ],
                              ),
                            ),
                          const SizedBox(height: 40),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Hero header ──────────────────────────────────────────────────────────

class _HeroHeader extends StatelessWidget {
  final AppSummary app;
  final AppStatus? status;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onOpenCredentials;
  const _HeroHeader({
    required this.app,
    required this.status,
    required this.onBack,
    required this.onRefresh,
    required this.onOpenCredentials,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hash = app.name.hashCode;
    final c1 = HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.6, 0.5).toColor();
    final c2 = HSLColor.fromAHSL(
        1, ((hash ~/ 7) % 360).toDouble(), 0.5, 0.4).toColor();
    final state = status?.state ?? 'idle';
    final (dotColor, label) = switch (state) {
      'running' => (c.green, 'running'),
      'error' => (c.red, 'error'),
      'disabled' => (c.textMuted, 'disabled'),
      _ => (c.textDim, 'idle'),
    };
    final iconData = Icons.bolt_rounded;

    final hasTriggers = app.triggerTypes.isNotEmpty;
    return Container(
      height: hasTriggers ? 104 : 84,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'common.back'.tr(),
            icon: Icon(Icons.arrow_back_rounded, size: 18, color: c.textMuted),
            onPressed: onBack,
          ),
          const SizedBox(width: 6),
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [c1, c2],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: c1.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: app.icon.isNotEmpty
                ? Text(app.icon, style: const TextStyle(fontSize: 22))
                : Icon(iconData, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: c.textBright),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _PulseDot(color: dotColor, active: state == 'running'),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: GoogleFonts.inter(
                          fontSize: 11,
                          color: dotColor,
                          fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _metadataLine(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted),
                ),
                if (hasTriggers) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 18,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: app.triggerTypes.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (_, i) =>
                          _TriggerChip(type: app.triggerTypes[i]),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'chat.credentials'.tr(),
            icon: Icon(Icons.key_outlined, size: 18, color: c.textMuted),
            onPressed: onOpenCredentials,
          ),
          IconButton(
            tooltip: 'common.refresh'.tr(),
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }

  String _metadataLine() {
    final parts = <String>['BACKGROUND'];
    if (app.version.isNotEmpty) parts.add('v${app.version}');
    parts.add('${app.totalTools} tools');
    if (status?.lastRunAt != null) {
      parts.add('last run ${_ago(status!.lastRunAt!)}');
    } else if (status?.nextRun != null) {
      parts.add('next ${status!.nextRun}');
    }
    return parts.join(' · ');
  }

  static String _ago(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 10) return 'just now';
    if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _TriggerChip extends StatelessWidget {
  final String type;
  const _TriggerChip({required this.type});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, label, tint) = _styleFor(type, c);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: tint.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: tint),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: tint,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  static (IconData, String, Color) _styleFor(String type, AppColors c) {
    switch (type.toLowerCase()) {
      case 'cron':
      case 'schedule':
      case 'scheduled':
        return (Icons.schedule_rounded, 'cron', c.blue);
      case 'telegram':
        return (Icons.send_rounded, 'telegram', c.blue);
      case 'slack':
        return (Icons.tag_rounded, 'slack', c.purple);
      case 'webhook':
      case 'http':
        return (Icons.webhook_rounded, 'webhook', c.green);
      case 'email':
      case 'mail':
        return (Icons.mail_outline_rounded, 'email', c.orange);
      case 'manual':
        return (Icons.touch_app_rounded, 'manual', c.textMuted);
      default:
        return (Icons.bolt_rounded, type, c.textMuted);
    }
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  final bool active;
  const _PulseDot({required this.color, required this.active});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, _) {
                final t = _ctrl.value;
                return Container(
                  width: 8 + 12 * t,
                  height: 8 + 12 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: (1 - t) * 0.5),
                  ),
                );
              },
            ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withValues(alpha: 0.5),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Hero stats card ──────────────────────────────────────────────────────

class _HeroStatsCard extends StatelessWidget {
  final AppStatus status;
  const _HeroStatsCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stats = status.stats;
    final runs = stats?.total ?? 0;
    final success = stats != null
        ? '${stats.successRate.toStringAsFixed(1)}%'
        : '—';
    final avg = stats != null
        ? (stats.avgDurationMs < 1000
            ? '${stats.avgDurationMs.round()}ms'
            : '${(stats.avgDurationMs / 1000).toStringAsFixed(1)}s')
        : '—';
    final tokens = stats != null ? _fmt(stats.totalTokens) : '—';
    final successColor = stats == null
        ? c.textMuted
        : stats.successRate > 90
            ? c.green
            : stats.successRate > 70
                ? c.orange
                : c.red;
    final failed = stats?.failed ?? 0;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Row of 4 big metrics
          Row(
            children: [
              Expanded(
                  child: _Metric(
                      label: 'total runs',
                      value: _fmt(runs),
                      color: c.textBright)),
              _vbar(c),
              Expanded(
                  child: _Metric(
                      label: 'success',
                      value: success,
                      color: successColor)),
              _vbar(c),
              Expanded(
                  child: _Metric(
                      label: 'avg duration',
                      value: avg,
                      color: c.textBright)),
              _vbar(c),
              Expanded(
                  child: _Metric(
                      label: 'tokens',
                      value: tokens,
                      color: c.textBright)),
            ],
          ),
          const SizedBox(height: 20),
          Container(height: 1, color: c.border),
          const SizedBox(height: 16),
          // Sparkline
          SizedBox(
            height: 48,
            child: status.runs24h.isEmpty
                ? Center(
                    child: Text('24h sparkline will appear once the app has runs',
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.textDim)),
                  )
                : Sparkline(
                    values: status.runs24h,
                    color: c.blue,
                    trackColor: c.border,
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('last 24h',
                  style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textDim)),
              const Spacer(),
              if (failed > 0) ...[
                Icon(Icons.error_outline_rounded, size: 10, color: c.red),
                const SizedBox(width: 3),
                Text('$failed failed',
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.red)),
                const SizedBox(width: 10),
              ],
              if (status.trendPct != null)
                _TrendBadge(pct: status.trendPct!),
            ],
          ),
        ],
      ),
    );
  }

  Widget _vbar(AppColors c) =>
      Container(width: 1, height: 44, color: c.border);

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            color: c.textDim,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _TrendBadge extends StatelessWidget {
  final double pct;
  const _TrendBadge({required this.pct});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final up = pct >= 0;
    final color = up ? c.green : c.red;
    final icon = up ? Icons.trending_up_rounded : Icons.trending_down_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 3),
        Text(
          '${pct.toStringAsFixed(1)}% vs yesterday',
          style: GoogleFonts.firaCode(fontSize: 10, color: color),
        ),
      ],
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final Widget? action;
  const _SectionHeader({
    required this.label,
    required this.count,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 10,
            color: c.textDim,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text('$count',
              style: GoogleFonts.firaCode(
                  fontSize: 9,
                  color: c.textMuted,
                  fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: c.border)),
        if (action != null) ...[
          const SizedBox(width: 10),
          action!,
        ],
      ],
    );
  }
}

// ─── Trigger card ─────────────────────────────────────────────────────────

class _TriggerCard extends StatefulWidget {
  final Trigger trigger;
  final String appId;
  final String appName;
  final BackgroundAppService svc;
  const _TriggerCard({
    required this.trigger,
    required this.appId,
    required this.appName,
    required this.svc,
  });

  @override
  State<_TriggerCard> createState() => _TriggerCardState();
}

class _TriggerCardState extends State<_TriggerCard> {
  bool _firing = false;
  bool _h = false;

  Future<void> _fire() async {
    // Gate: block firing if credentials are incomplete / expired.
    final ok = await ensureCredentials(
      context,
      appId: widget.appId,
      appName: widget.appName,
    );
    if (!ok || !mounted) return;
    setState(() => _firing = true);
    final fired = await widget.svc.fireTrigger(widget.appId, widget.trigger.id);
    if (!mounted) return;
    setState(() => _firing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(fired
          ? 'Trigger fired: ${widget.trigger.displayType}'
          : 'Failed to fire trigger'),
      backgroundColor: (fired ? context.colors.green : context.colors.red)
          .withValues(alpha: 0.9),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = widget.trigger;
    final (iconData, tint) = switch (t.type) {
      'cron' => (Icons.schedule_rounded, c.blue),
      'http' => (Icons.link_rounded, c.purple),
      'file_watch' => (Icons.folder_open_rounded, c.orange),
      _ => (Icons.flash_on_rounded, c.cyan),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _h ? c.surfaceAlt : c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: tint.withValues(alpha: 0.3)),
                ),
                child: Icon(iconData, size: 18, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(t.displayType,
                            style: GoogleFonts.inter(
                                fontSize: 12.5,
                                color: c.textBright,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        _MiniDot(color: c.green),
                        const SizedBox(width: 4),
                        Text('active',
                            style: GoogleFonts.inter(
                                fontSize: 10, color: c.green)),
                      ],
                    ),
                    if (t.displaySchedule.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(t.displaySchedule,
                          style: GoogleFonts.firaCode(
                              fontSize: 10.5, color: c.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                    if (t.type == 'cron' && t.schedule != null)
                      _NextRuns(schedule: t.schedule!),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _FireBtn(onTap: _firing ? null : _fire, loading: _firing),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders the next 3 cron occurrences as tiny chips. Silent when the
/// expression can't be parsed — keeps the card clean for exotic
/// schedules the client parser doesn't support.
class _NextRuns extends StatelessWidget {
  final String schedule;
  const _NextRuns({required this.schedule});

  @override
  Widget build(BuildContext context) {
    final cron = CronExpression.parse(schedule);
    if (cron == null) return const SizedBox.shrink();
    final runs = cron.nextRuns(DateTime.now(), count: 3);
    if (runs.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          Icon(Icons.history_toggle_off_rounded,
              size: 11, color: c.textMuted),
          for (final r in runs)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.blue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: c.blue.withValues(alpha: 0.2)),
              ),
              child: Text(
                relativeDateTime(r),
                style: GoogleFonts.firaCode(
                  fontSize: 9.5,
                  color: c.blue,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FireBtn extends StatefulWidget {
  final VoidCallback? onTap;
  final bool loading;
  const _FireBtn({required this.onTap, required this.loading});

  @override
  State<_FireBtn> createState() => _FireBtnState();
}

class _FireBtnState extends State<_FireBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.onTap != null && !widget.loading;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: _h && enabled
                ? c.blue.withValues(alpha: 0.18)
                : c.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: c.blue.withValues(alpha: _h ? 0.5 : 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              widget.loading
                  ? SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.2, color: c.blue),
                    )
                  : Icon(Icons.play_arrow_rounded, size: 13, color: c.blue),
              const SizedBox(width: 4),
              Text('background.fire'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: c.blue,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniDot extends StatelessWidget {
  final Color color;
  const _MiniDot({required this.color});
  @override
  Widget build(BuildContext context) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 4),
          ],
        ),
      );
}

// ─── Channel health card ──────────────────────────────────────────────────

class _ChannelHealthCard extends StatelessWidget {
  final ChannelHealth channel;
  const _ChannelHealthCard({required this.channel});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (iconData, tint) = switch (channel.type) {
      'email' => (Icons.mail_outline_rounded, c.cyan),
      'slack' => (Icons.tag_rounded, c.purple),
      'webhook' => (Icons.link_rounded, c.orange),
      'telegram' => (Icons.send_rounded, c.blue),
      'log' => (Icons.receipt_long_outlined, c.textMuted),
      _ => (Icons.outbox_rounded, c.cyan),
    };
    final statusColor = switch (channel.status) {
      'connected' => c.green,
      'degraded' => c.orange,
      'error' => c.red,
      _ => c.textMuted,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: tint.withValues(alpha: 0.3)),
              ),
              child: Icon(iconData, size: 18, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(channel.type,
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: c.textBright,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      _MiniDot(color: statusColor),
                      const SizedBox(width: 4),
                      Text(channel.status,
                          style: GoogleFonts.inter(
                              fontSize: 10, color: statusColor)),
                    ],
                  ),
                  if (channel.target != null && channel.target!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(channel.target!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.firaCode(
                            fontSize: 10.5, color: c.textMuted)),
                  ],
                  if (channel.hasError && channel.lastError != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      channel.lastError!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.red),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${channel.sent}',
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        color: c.textBright,
                        fontWeight: FontWeight.w700)),
                Text('sent',
                    style: GoogleFonts.inter(
                        fontSize: 9, color: c.textDim)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Session card (with avatar) ───────────────────────────────────────────

/// Derived per-session observability — computed client-side from the
/// 20 most recent activations so we can surface failure bursts and
/// last-response previews without a dedicated endpoint.
class _SessionHealth {
  final String lastStatus;
  final int consecutiveFails;
  final String? lastError;
  final String responsePreview;
  const _SessionHealth({
    required this.lastStatus,
    required this.consecutiveFails,
    this.lastError,
    this.responsePreview = '',
  });

  bool get isFailing => consecutiveFails >= 2;
}

class _SessionCard extends StatefulWidget {
  final BackgroundSession session;
  final SessionPayload? payload;
  final _SessionHealth? health;
  final VoidCallback onTap;
  final VoidCallback? onDuplicate;
  final VoidCallback? onExport;
  final VoidCallback? onShareLink;
  final VoidCallback? onViewRuns;
  const _SessionCard({
    required this.session,
    required this.onTap,
    this.payload,
    this.health,
    this.onDuplicate,
    this.onExport,
    this.onShareLink,
    this.onViewRuns,
  });

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = widget.session;
    final name = s.name.isNotEmpty ? s.name : s.id;
    final initials = _initials(name);
    final hash = name.hashCode;
    final c1 = HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.5, 0.45).toColor();
    final c2 = HSLColor.fromAHSL(
        1, ((hash ~/ 11) % 360).toDouble(), 0.5, 0.35).toColor();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _h ? c.surfaceAlt : c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _h ? c.borderHover : c.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [c1, c2],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(initials,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: c.textBright,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        '${s.activationCount} activations · ${s.timeAgo}',
                        style: GoogleFonts.firaCode(
                            fontSize: 10.5, color: c.textMuted),
                      ),
                      _buildPayloadPreview(c),
                      _buildResponsePreview(c),
                    ],
                  ),
                ),
                if (widget.health?.isFailing == true)
                  Tooltip(
                    message: widget.health?.lastError ??
                        '${widget.health!.consecutiveFails} consecutive failures',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: c.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                            color: c.red.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              size: 10, color: c.red),
                          const SizedBox(width: 3),
                          Text(
                              '${widget.health!.consecutiveFails} FAILS',
                              style: GoogleFonts.firaCode(
                                  fontSize: 8,
                                  color: c.red,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5)),
                        ],
                      ),
                    ),
                  ),
                if (widget.payload?.validation.blocksActivation == true)
                  Tooltip(
                    message: widget.payload!.validation.errors.isEmpty
                        ? 'Payload incomplete'
                        : widget.payload!.validation.errors.join('\n'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: c.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                            color: c.red.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error_outline_rounded,
                              size: 10, color: c.red),
                          const SizedBox(width: 3),
                          Text('background.invalid'.tr(),
                              style: GoogleFonts.firaCode(
                                  fontSize: 8,
                                  color: c.red,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5)),
                        ],
                      ),
                    ),
                  ),
                if (s.isPaused)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: c.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                          color: c.orange.withValues(alpha: 0.3)),
                    ),
                    child: Text('background.paused'.tr(),
                        style: GoogleFonts.firaCode(
                            fontSize: 8,
                            color: c.orange,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5)),
                  ),
                const SizedBox(width: 8),
                if (widget.onDuplicate != null ||
                    widget.onExport != null ||
                    widget.onShareLink != null ||
                    widget.onViewRuns != null)
                  PopupMenuButton<String>(
                    tooltip: 'background.more'.tr(),
                    position: PopupMenuPosition.under,
                    icon: Icon(Icons.more_horiz_rounded,
                        size: 16, color: c.textMuted),
                    onSelected: (v) {
                      if (v == 'duplicate') widget.onDuplicate?.call();
                      if (v == 'export') widget.onExport?.call();
                      if (v == 'share') widget.onShareLink?.call();
                      if (v == 'runs') widget.onViewRuns?.call();
                    },
                    itemBuilder: (_) => [
                      if (widget.onViewRuns != null)
                        PopupMenuItem(
                          value: 'runs',
                          height: 32,
                          child: Row(
                            children: [
                              Icon(Icons.history_rounded,
                                  size: 13, color: c.text),
                              const SizedBox(width: 8),
                              Text('background.view_runs'.tr(),
                                  style: GoogleFonts.inter(
                                      fontSize: 12, color: c.text)),
                            ],
                          ),
                        ),
                      if (widget.onDuplicate != null)
                        PopupMenuItem(
                          value: 'duplicate',
                          height: 32,
                          child: Row(
                            children: [
                              Icon(Icons.content_copy_rounded,
                                  size: 13, color: c.text),
                              const SizedBox(width: 8),
                              Text('background.duplicate'.tr(),
                                  style: GoogleFonts.inter(
                                      fontSize: 12, color: c.text)),
                            ],
                          ),
                        ),
                      if (widget.onShareLink != null)
                        PopupMenuItem(
                          value: 'share',
                          height: 32,
                          child: Row(
                            children: [
                              Icon(Icons.share_rounded,
                                  size: 13, color: c.text),
                              const SizedBox(width: 8),
                              Text('background.copy_share_link'.tr(),
                                  style: GoogleFonts.inter(
                                      fontSize: 12, color: c.text)),
                            ],
                          ),
                        ),
                      if (widget.onExport != null)
                        PopupMenuItem(
                          value: 'export',
                          height: 32,
                          child: Row(
                            children: [
                              Icon(Icons.download_rounded,
                                  size: 13, color: c.text),
                              const SizedBox(width: 8),
                              Text('background.copy_as_json'.tr(),
                                  style: GoogleFonts.inter(
                                      fontSize: 12, color: c.text)),
                            ],
                          ),
                        ),
                    ],
                  ),
                Tooltip(
                  message: 'View & edit payload',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _h
                          ? c.surface
                          : c.surfaceAlt.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: _h ? c.borderHover : c.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.tune_rounded,
                            size: 11, color: _h ? c.text : c.textMuted),
                        const SizedBox(width: 4),
                        Text(
                          'Open',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: _h ? c.text : c.textMuted,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResponsePreview(AppColors c) {
    final h = widget.health;
    if (h == null || h.responsePreview.isEmpty) return const SizedBox.shrink();
    final cleaned = h.responsePreview
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return const SizedBox.shrink();
    final short =
        cleaned.length > 88 ? '${cleaned.substring(0, 88)}…' : cleaned;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            h.lastStatus == 'failed'
                ? Icons.error_outline_rounded
                : Icons.auto_awesome_outlined,
            size: 11,
            color: h.lastStatus == 'failed' ? c.red : c.green,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              short,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                color: c.text,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPayloadPreview(AppColors c) {
    final p = widget.payload;
    if (p == null || p.isEmpty) return const SizedBox.shrink();

    final chips = <Widget>[];
    if (p.prompt.trim().isNotEmpty) {
      final snippet = p.prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
      final short =
          snippet.length > 72 ? '${snippet.substring(0, 72)}…' : snippet;
      chips.add(Flexible(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.format_quote_rounded, size: 11, color: c.blue),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                short,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 10.5,
                  fontStyle: FontStyle.italic,
                  color: c.text,
                ),
              ),
            ),
          ],
        ),
      ));
    }
    if (p.files.isNotEmpty) {
      if (chips.isNotEmpty) chips.add(const SizedBox(width: 10));
      chips.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file_rounded, size: 11, color: c.green),
          const SizedBox(width: 3),
          Text(
            '${p.files.length} file${p.files.length == 1 ? '' : 's'}',
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: c.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ));
    }
    if (p.metadata.isNotEmpty) {
      if (chips.isNotEmpty) chips.add(const SizedBox(width: 10));
      chips.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.data_object_rounded, size: 11, color: c.orange),
          const SizedBox(width: 3),
          Text(
            '${p.metadata.length} pref${p.metadata.length == 1 ? '' : 's'}',
            style: GoogleFonts.firaCode(
              fontSize: 10,
              color: c.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: chips,
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'[\s@._-]+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.isEmpty
          ? '?'
          : parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

// ─── Activation row ───────────────────────────────────────────────────────

class _ActivationRow extends StatefulWidget {
  final Activation activation;
  final VoidCallback onTap;
  const _ActivationRow({required this.activation, required this.onTap});

  @override
  State<_ActivationRow> createState() => _ActivationRowState();
}

class _ActivationRowState extends State<_ActivationRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = widget.activation;
    final (iconData, iconColor) = switch (a.status) {
      'failed' => (Icons.close_rounded, c.red),
      'running' => (Icons.hourglass_empty_rounded, c.orange),
      _ => (Icons.check_rounded, c.green),
    };
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _h ? c.surfaceAlt : c.surface,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: iconColor.withValues(alpha: 0.3)),
                ),
                child: Icon(iconData, size: 12, color: iconColor),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 90,
                child: Text(
                  a.triggerType.isNotEmpty ? a.triggerType : 'manual',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                      fontSize: 11,
                      color: c.text,
                      fontWeight: FontWeight.w500),
                ),
              ),
              SizedBox(
                width: 66,
                child: Text(
                  a.durationDisplay,
                  style: GoogleFonts.firaCode(
                      fontSize: 11,
                      color: c.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  '${a.totalTokens} tok',
                  style: GoogleFonts.firaCode(
                      fontSize: 11,
                      color: c.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              Expanded(
                child: Text(
                  a.message.isNotEmpty ? a.message : '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.textMuted),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                a.timeDisplay,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textDim),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded,
                  size: 14,
                  color: _h ? c.text : c.textDim),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty block ──────────────────────────────────────────────────────────

class _EmptyBlock extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyBlock({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.textMuted),
          const SizedBox(width: 10),
          Text(text,
              style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
        ],
      ),
    );
  }
}

// ─── New session button ──────────────────────────────────────────────────

class _NewSessionBtn extends StatefulWidget {
  final VoidCallback onTap;
  const _NewSessionBtn({required this.onTap});

  @override
  State<_NewSessionBtn> createState() => _NewSessionBtnState();
}

class _NewSessionBtnState extends State<_NewSessionBtn> {
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _h
                ? c.blue.withValues(alpha: 0.15)
                : c.surfaceAlt,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _h
                  ? c.blue.withValues(alpha: 0.45)
                  : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded,
                  size: 12, color: _h ? c.blue : c.textMuted),
              const SizedBox(width: 4),
              Text(
                'New session',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  color: _h ? c.blue : c.textMuted,
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

// ─── Create-session dialog ────────────────────────────────────────────────

class _CreateSessionDialog extends StatefulWidget {
  final String appId;
  final List<String> routingKeys;
  final BackgroundAppService svc;
  const _CreateSessionDialog({
    required this.appId,
    required this.routingKeys,
    required this.svc,
  });

  @override
  State<_CreateSessionDialog> createState() => _CreateSessionDialogState();
}

class _CreateSessionDialogState extends State<_CreateSessionDialog> {
  final _nameCtrl = TextEditingController();
  final _workspaceCtrl = TextEditingController();
  late final Map<String, TextEditingController> _routingCtrls = {
    for (final k in widget.routingKeys) k: TextEditingController(),
  };
  bool _creating = false;
  String? _error;

  /// Imported payload that should be applied right after the session
  /// is created (the daemon doesn't accept payload on create — we
  /// PUT it in a follow-up call).
  ShareableSession? _imported;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _workspaceCtrl.dispose();
    for (final c in _routingCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    final routingKeys = <String, dynamic>{};
    _routingCtrls.forEach((k, c) {
      final v = c.text.trim();
      if (v.isNotEmpty) routingKeys[k] = v;
    });
    final session = await widget.svc.createSession(
      widget.appId,
      name: name,
      routingKeys: routingKeys,
      workspace: _workspaceCtrl.text.trim(),
    );
    if (!mounted) return;
    if (session == null) {
      setState(() {
        _creating = false;
        _error = 'Failed to create session — check daemon logs';
      });
      return;
    }
    // If the user imported a link, apply the payload now so the
    // session is fully usable on first open.
    final imp = _imported;
    if (imp != null && (imp.prompt.isNotEmpty || imp.metadata.isNotEmpty)) {
      try {
        await PayloadService().setPromptAndMetadata(
          widget.appId,
          session.id,
          prompt: imp.prompt.isNotEmpty ? imp.prompt : null,
          metadata: imp.metadata.isNotEmpty ? imp.metadata : null,
        );
      } catch (_) {
        // Non-fatal — the session exists, only the payload import
        // failed. The user can re-paste manually.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(session);
  }

  /// Open a paste dialog, decode the link, and pre-fill every
  /// editable field. Bad input shows an inline error and bails out.
  Future<void> _importFromLink() async {
    final c = context.colors;
    final ctrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('background.import_from_link'.tr(),
            style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textBright)),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width < 520
              ? MediaQuery.sizeOf(context).width - 48
              : 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Paste a digitorn://session link. We\'ll fill the form '
                  'with the imported config.',
                  style: GoogleFonts.inter(
                      fontSize: 11.5, color: c.textMuted, height: 1.5)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 5,
                style: GoogleFonts.firaCode(fontSize: 11, color: c.text),
                decoration: InputDecoration(
                  hintText: 'digitorn://session?d=…',
                  hintStyle: GoogleFonts.firaCode(
                      fontSize: 11, color: c.textDim),
                  filled: true,
                  fillColor: c.bg,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('common.cancel'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            style: ElevatedButton.styleFrom(
                backgroundColor: c.blue,
                foregroundColor: Colors.white,
                elevation: 0),
            child: Text('background.import'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (raw == null || raw.isEmpty || !mounted) return;

    final decoded = SessionShareCodec.decode(raw);
    if (decoded == null) {
      setState(() => _error = 'Could not parse the link — wrong format?');
      return;
    }
    if (decoded.appId != widget.appId) {
      setState(() => _error =
          'This link is for a different app (${decoded.appId})');
      return;
    }
    setState(() {
      _imported = decoded;
      _nameCtrl.text =
          decoded.name.isNotEmpty ? '${decoded.name} (imported)' : '';
      _workspaceCtrl.text = decoded.workspace;
      decoded.routingKeys.forEach((k, v) {
        _routingCtrls[k]?.text = v.toString();
      });
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_add_rounded, size: 16, color: c.blue),
          const SizedBox(width: 8),
          Text('background.new_background_session'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.textBright)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A user-scoped session isolates a run of this app for '
              'one recipient — each trigger that matches its routing '
              'keys fires against the session.',
              style: GoogleFonts.inter(
                  fontSize: 11.5, color: c.textMuted, height: 1.5),
            ),
            const SizedBox(height: 12),
            // Import-from-link affordance — same form, prefilled.
            OutlinedButton.icon(
              onPressed: _importFromLink,
              icon: Icon(Icons.link_rounded, size: 13, color: c.blue),
              label: Text(
                _imported != null
                    ? 'Imported · ${_imported!.prompt.isNotEmpty ? "with payload" : "config only"}'
                    : 'background.import_from_link'.tr(),
                style: GoogleFonts.inter(fontSize: 11.5, color: c.blue),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: c.blue.withValues(alpha: 0.4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 30),
              ),
            ),
            const SizedBox(height: 16),
            _fieldLabel(c, 'Name'),
            const SizedBox(height: 4),
            _textField(c, _nameCtrl, hint: 'alice@example.com'),
            if (widget.routingKeys.isNotEmpty) ...[
              const SizedBox(height: 14),
              _fieldLabel(c, 'Routing keys'),
              const SizedBox(height: 4),
              for (final key in widget.routingKeys) ...[
                Text(key,
                    style: GoogleFonts.firaCode(
                        fontSize: 10,
                        color: c.textMuted,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                _textField(c, _routingCtrls[key]!, hint: 'value'),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 8),
            _fieldLabel(c, 'Workspace (optional)'),
            const SizedBox(height: 4),
            _textField(c, _workspaceCtrl, hint: '/path/to/workspace'),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 12, color: c.red),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(_error!,
                        style: GoogleFonts.firaCode(
                            fontSize: 10, color: c.red)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.of(context).pop(),
          child: Text('common.cancel'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12, color: c.textMuted)),
        ),
        ElevatedButton(
          onPressed: _creating ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.blue,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6)),
          ),
          child: _creating
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.4, color: Colors.white),
                )
              : Text('background.create'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _fieldLabel(AppColors c, String text) => Text(
        text,
        style: GoogleFonts.inter(
            fontSize: 11,
            color: c.textBright,
            fontWeight: FontWeight.w600),
      );

  Widget _textField(
    AppColors c,
    TextEditingController ctrl, {
    required String hint,
  }) {
    return TextField(
      controller: ctrl,
      style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: c.bg,
        hintText: hint,
        hintStyle: GoogleFonts.firaCode(fontSize: 12, color: c.textDim),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: c.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: c.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: c.blue)),
      ),
    );
  }
}
