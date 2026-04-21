import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../services/auth_service.dart';
import '../services/socket_service.dart';
import '../services/queue_service.dart';
import '../services/preview_store.dart';
import '../services/workspace_module.dart';
import '../services/workspace_service.dart';
import '../models/queue_entry.dart';
import '../models/session_metrics.dart';

/// Flatten a daemon `content` field into plain text. The daemon may
/// send either a raw String (simple messages) or a `List<Map>` of
/// typed blocks when a turn carries images or tool uses alongside
/// prose. We only keep `type == 'text'` blocks — images / tool-use
/// blocks are rendered separately by the chat panel from their own
/// fields, so dropping them here prevents JSON noise from leaking
/// into the message bubble.
String extractText(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => (b['text'] ?? '').toString())
        .join(' ');
  }
  return '';
}

/// Thrown by session list/history calls when the daemon says the app
/// isn't deployed anymore (404). UI should pop back to the app picker
/// rather than retrying — the app is gone until someone redeploys it.
class AppNotDeployedException implements Exception {
  final String appId;
  const AppNotDeployedException(this.appId);
  @override
  String toString() => 'AppNotDeployedException($appId)';
}

/// Snapshot of the last message the user submitted on a session.
/// Stashed by [SessionService.sendMessage] and read back by the
/// credential picker flow so we can resend the exact same payload
/// (text + attachments + workspace) after a grant succeeds, even
/// if the user switched sessions mid-picker.
class PendingMessage {
  final String appId;
  final String sessionId;
  final String message;
  final String? workspace;
  final List<String> images;
  final List<String> files;
  final DateTime stashedAt;

  PendingMessage({
    required this.appId,
    required this.sessionId,
    required this.message,
    this.workspace,
    this.images = const [],
    this.files = const [],
    DateTime? stashedAt,
  }) : stashedAt = stashedAt ?? DateTime.now();
}

class AppSession {
  final String sessionId;
  final String appId;
  /// `is_active` from the daemon — true iff a turn is currently
  /// executing for this session. Distinct from the "currently
  /// selected" session in the UI; the drawer uses both.
  final bool isActive;
  /// True if the session's last turn was interrupted (daemon crash,
  /// disconnect, abort). Replayable with the next user message.
  final bool interrupted;
  final int messageCount;
  final int turnCount;
  final String title;
  final DateTime? createdAt;
  final DateTime? lastActive;

  /// Daemon-enriched fields (added 2026-04 — see
  /// FLUTTER_OMNIBUS_INTEGRATION.md §2). They make the cards
  /// renderable without a second `/api/apps` lookup.
  final String? lastMessagePreview;
  final String? lastMessageRole;
  final String? appName;
  final String? appIcon;
  final String? appColor;

  /// Absolute workspace path the daemon bound this session to.
  /// Non-null when the session was created with a `workspace_path`
  /// (apps whose manifest declares `workspace_mode: required` or
  /// the user picked one for an optional app). The session drawer
  /// groups sessions sharing the same path under a project header.
  final String? workspacePath;

  /// Token / cost / error slots — daemon promises to fill them in
  /// a future iteration (per-session join with UsageStore). For
  /// now they default to 0 / null.
  final int tokens;
  final double costUsd;
  final String? lastError;

  /// Client-local only. True while the session exists optimistically
  /// (POST /sessions returned a sid, but the first turn hasn't
  /// succeeded yet). Commit-on-first-success means the server won't
  /// list this session until `message_done` has fired — so the UI
  /// renders a draft indicator and the chat panel skips the resume
  /// round-trip. Cleared on the first post-`message_done` refetch.
  final bool isDraft;

  AppSession({
    required this.sessionId,
    required this.appId,
    this.isActive = false,
    this.interrupted = false,
    this.messageCount = 0,
    this.turnCount = 0,
    this.title = '',
    this.createdAt,
    this.lastActive,
    this.lastMessagePreview,
    this.lastMessageRole,
    this.appName,
    this.appIcon,
    this.appColor,
    this.workspacePath,
    this.tokens = 0,
    this.costUsd = 0,
    this.lastError,
    this.isDraft = false,
  });

  /// True iff the daemon reports the session as running a turn right
  /// now and it hasn't been flagged as interrupted. The session drawer
  /// uses this to render the live-running dot next to the title.
  bool get isRunning => isActive && !interrupted;

  factory AppSession.fromJson(Map<String, dynamic> json) {
    return AppSession(
      sessionId: json['session_id'] ?? '',
      appId: json['app_id'] ?? '',
      isActive: json['is_active'] ?? false,
      interrupted: json['interrupted'] ?? false,
      messageCount: json['message_count'] ?? 0,
      turnCount: json['turn_count'] ?? 0,
      title: json['title'] ?? '',
      createdAt: parseDate(json['created_at']),
      lastActive: parseDate(json['last_active'] ?? json['last_active_at']),
      lastMessagePreview: json['last_message_preview'] as String?,
      lastMessageRole: json['last_message_role'] as String?,
      appName: json['app_name'] as String?,
      appIcon: json['app_icon'] as String?,
      appColor: json['app_color'] as String?,
      workspacePath: (json['workspace_path'] ?? json['workspace']) as String?,
      tokens: (json['tokens'] as num?)?.toInt() ?? 0,
      costUsd: (json['cost_usd'] as num?)?.toDouble() ?? 0,
      lastError: json['last_error'] as String?,
    );
  }

  /// Last path segment of [workspacePath], used as the project
  /// group label. Handles both POSIX (`/`) and Windows (`\`)
  /// separators and trailing slashes. Returns empty when the
  /// session has no workspace binding.
  String get workspaceName {
    final p = workspacePath;
    if (p == null || p.isEmpty) return '';
    var normalised = p.replaceAll('\\', '/');
    while (normalised.endsWith('/') && normalised.length > 1) {
      normalised = normalised.substring(0, normalised.length - 1);
    }
    final i = normalised.lastIndexOf('/');
    if (i < 0) return normalised;
    final seg = normalised.substring(i + 1);
    return seg.isEmpty ? normalised : seg;
  }

  /// Parent directory of [workspacePath] — shown as a subtle
  /// subtitle under the project label in the tree header so users
  /// can tell two same-named projects apart.
  String get workspaceParent {
    final p = workspacePath;
    if (p == null || p.isEmpty) return '';
    final normalised = p.replaceAll('\\', '/');
    final i = normalised.lastIndexOf('/');
    if (i <= 0) return '';
    return normalised.substring(0, i);
  }

  AppSession copyWith({
    String? title,
    String? lastMessagePreview,
    String? lastMessageRole,
    String? workspacePath,
    int? messageCount,
    int? turnCount,
    int? tokens,
    double? costUsd,
    DateTime? lastActive,
    bool? isActive,
    bool? interrupted,
    bool? isDraft,
  }) =>
      AppSession(
        sessionId: sessionId,
        appId: appId,
        isActive: isActive ?? this.isActive,
        interrupted: interrupted ?? this.interrupted,
        messageCount: messageCount ?? this.messageCount,
        turnCount: turnCount ?? this.turnCount,
        title: title ?? this.title,
        createdAt: createdAt,
        lastActive: lastActive ?? this.lastActive,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        lastMessageRole: lastMessageRole ?? this.lastMessageRole,
        appName: appName,
        appIcon: appIcon,
        appColor: appColor,
        workspacePath: workspacePath ?? this.workspacePath,
        tokens: tokens ?? this.tokens,
        costUsd: costUsd ?? this.costUsd,
        lastError: lastError,
        isDraft: isDraft ?? this.isDraft,
      );

  String get shortId {
    // For IDs like "session-1775430395385", show last 6 digits
    if (sessionId.startsWith('session-') && sessionId.length > 14) {
      return '#${sessionId.substring(sessionId.length - 6)}';
    }
    return sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
  }

  /// Display title with a 3-tier fallback:
  ///   1. `title` — the daemon's canonical title (semantic 3-7 word
  ///      version once the LLM generator has run, OR the raw
  ///      first-message truncation the daemon uses as a placeholder)
  ///   2. `last_message_preview` — truncated to 60 chars. Every
  ///      session on the daemon carries this field and it's a much
  ///      better identifier for the user than a random short-id.
  ///      Used when the daemon hasn't generated a title yet (common
  ///      on pre-migration sessions where `title == ""`).
  ///   3. `shortId` — last resort. Only hits for brand-new draft
  ///      sessions that have neither a title nor a first message.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final preview = lastMessagePreview?.replaceAll('\n', ' ').trim();
    if (preview != null && preview.isNotEmpty) {
      return preview.length > 60
          ? '${preview.substring(0, 60)}…'
          : preview;
    }
    return shortId;
  }

  /// Relative time label (e.g. "2m ago", "3h ago", "Yesterday")
  String get timeAgo {
    final dt = lastActive ?? createdAt;
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}';
  }

  static DateTime? parseDate(dynamic v) {
    if (v == null) return null;
    if (v is num) return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    if (v is String) return DateTime.tryParse(v);
    return null;
  }
}

class SessionService extends ChangeNotifier {
  static final SessionService _instance = SessionService._internal();
  factory SessionService() => _instance;
  SessionService._internal();

  List<AppSession> sessions = [];
  AppSession? activeSession;
  bool isLoading = false;

  /// Session ids we inserted optimistically via POST /sessions but
  /// that the server has not yet persisted (commit-on-first-success).
  /// Used to (a) keep the entry in the sidebar across a refetch
  /// before the first turn commits, (b) fire a post-`message_done`
  /// refetch so the daemon's LLM-generated title replaces our raw
  /// preview, (c) drop the entry on failure/close with no trace.
  final Set<String> _draftSessionIds = {};

  /// Whether [sessionId] is a client-local draft (not yet persisted
  /// on the server). Sidebar widgets read this to render the draft
  /// indicator.
  bool isDraft(String sessionId) => _draftSessionIds.contains(sessionId);

  /// Drafts whose first `message_done` has arrived and whose
  /// post-commit refetch is already scheduled. Used to distinguish
  /// "first turn failed" (drop the draft) from "first turn ran fine,
  /// later turn errored" (keep the session — the server has it now).
  final Set<String> _draftCommitPending = {};

  /// Trigger a `loadSessions(appId)` ~3 s after a draft's first
  /// `message_done`. The delay gives the daemon's fire-and-forget
  /// title-generation LLM call a chance to land (typical latency
  /// 2–5 s). Once the refetch returns the session, [loadSessions]
  /// will clear the draft flag and sidebar will display the
  /// semantic title in place of our optimistic preview.
  void _onDraftFirstMessageDone(String sessionId) {
    if (_draftCommitPending.contains(sessionId)) return;
    _draftCommitPending.add(sessionId);
    final appId = sessions
        .firstWhere(
          (s) => s.sessionId == sessionId,
          orElse: () => AppSession(sessionId: '', appId: ''),
        )
        .appId;
    if (appId.isEmpty) {
      debugPrint(
          'SessionService: draft $sessionId committed but appId unknown, skipping refetch');
      return;
    }
    Future.delayed(const Duration(seconds: 3), () async {
      // Bail if the draft was removed (user closed / second abort)
      // between scheduling and firing.
      if (!_draftSessionIds.contains(sessionId)) {
        _draftCommitPending.remove(sessionId);
        return;
      }
      try {
        await loadSessions(appId);
      } catch (_) {
        // AppNotDeployedException, network drop — leave the draft
        // alone, the next manual refetch will settle it.
      } finally {
        _draftCommitPending.remove(sessionId);
      }
    });
  }

  /// True while loading history for the active session
  bool isLoadingHistory = false;

  /// Cached history messages per session (sessionId → turns)
  final Map<String, List<Map<String, dynamic>>> _historyCache = {};

  final StreamController<Map<String, dynamic>> _eventCtrl =
      StreamController.broadcast();

  /// Fires when the active session changes (old sessionId, new sessionId)
  final StreamController<String?> _sessionChangeCtrl =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get events => _eventCtrl.stream;
  Stream<String?> get onSessionChange => _sessionChangeCtrl.stream;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(hours: 4),
    // Accept 2xx-4xx except 401 (let interceptor handle auth refresh)
    validateStatus: (status) => status != null && status < 500 && status != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  Options get _opts => Options(headers: {
    'Content-Type': 'application/json',
  });

  String get _base => AuthService().baseUrl;

  // ─── List Sessions ───────────────────────────────────────────────────────

  /// Fetch `GET /api/apps/{appId}/sessions`.
  ///
  /// Commit-on-first-success semantics: sessions we created
  /// optimistically via [createAndSetSession] are NOT in the server's
  /// list until their first `message_done`. The refetch therefore
  /// re-merges any still-draft entries on top of the server list so
  /// the sidebar doesn't flash them away the instant a refetch
  /// completes. Once a draft's first turn commits, the server will
  /// return it with its LLM-generated title — at which point we drop
  /// the draft flag and let the server row be the source of truth.
  ///
  /// 503 → respects `Retry-After` once (warm-up window, typically
  /// 1–5 s after daemon start). 404 → throws
  /// [AppNotDeployedException] so the caller can pop back to the app
  /// picker instead of retrying forever.
  Future<void> loadSessions(String appId) async {
    isLoading = true;
    notifyListeners();
    try {
      Response resp = await _dio.get(
        '$_base/api/apps/$appId/sessions',
        options: _opts,
      );
      if (resp.statusCode == 503) {
        final retryAfter = int.tryParse(
              resp.headers.value('retry-after') ?? '',
            ) ??
            2;
        debugPrint(
            'loadSessions: daemon warming up, retrying in ${retryAfter}s');
        await Future.delayed(Duration(seconds: retryAfter.clamp(1, 10)));
        resp = await _dio.get(
          '$_base/api/apps/$appId/sessions',
          options: _opts,
        );
      }
      if (resp.statusCode == 404) {
        throw AppNotDeployedException(appId);
      }
      if (resp.data != null && resp.data['success'] == true) {
        final rawData = resp.data['data'];
        // Daemon envelope can be either `{ sessions: [...] }` or a
        // bare list in `data`. Accept both so we survive minor shape
        // tweaks without a breaking change.
        final List list = rawData is Map
            ? (rawData['sessions'] as List? ?? const [])
            : (rawData as List? ?? const []);
        final fromServer =
            list.map((j) => AppSession.fromJson(j)).toList();
        final serverIds = fromServer.map((s) => s.sessionId).toSet();
        // Any draft that the server now knows about → drop the draft
        // flag (server title/preview wins from here).
        _draftSessionIds.removeWhere((d) => serverIds.contains(d));
        // Drafts the server does NOT yet know about → keep the local
        // entry prepended so the sidebar is stable across refetches.
        final stillDraft = sessions
            .where((s) =>
                _draftSessionIds.contains(s.sessionId) &&
                !serverIds.contains(s.sessionId))
            .toList();
        sessions = [...stillDraft, ...fromServer];

        // Keep `activeSession` pointing at the canonical server row
        // after a refetch. Without this step the sidebar (which reads
        // `sessions`) picks up the LLM-generated semantic title that
        // lands ~3 s after the first `message_done`, but the chat
        // header / title bar / anyone reading `activeSession.title`
        // stays stuck on the raw first-message preview. Match by
        // sessionId and swap to the fresh AppSession; only useful
        // fields (title, preview, counts, last_active) change.
        final activeId = activeSession?.sessionId;
        if (activeId != null) {
          final refreshed = fromServer.firstWhere(
            (s) => s.sessionId == activeId,
            orElse: () => AppSession(sessionId: '', appId: ''),
          );
          if (refreshed.sessionId.isNotEmpty) {
            activeSession = refreshed;
          }
        }
      }
    } on AppNotDeployedException {
      rethrow;
    } catch (e) {
      debugPrint('SessionService.loadSessions error: $e');
    }
    isLoading = false;
    notifyListeners();
  }

  /// Drop a still-draft session locally. Call when the user closes
  /// the app before sending the first message, or when the first
  /// turn fails — the server has no record of it either way, so
  /// we must clean up our optimistic entry ourselves.
  void removeDraftSession(String sessionId) {
    if (!_draftSessionIds.contains(sessionId)) return;
    _draftSessionIds.remove(sessionId);
    sessions.removeWhere((s) => s.sessionId == sessionId);
    if (activeSession?.sessionId == sessionId) {
      activeSession = null;
    }
    _historyCache.remove(sessionId);
    notifyListeners();
  }

  /// Cross-app — `GET /api/users/me/sessions?limit=&offset=`.
  /// Returns the user's sessions across **every** app, sorted by
  /// `last_active desc`. Each entry already carries `app_name`,
  /// `app_icon`, `app_color`, and `last_message_preview` so the
  /// "Recent conversations" home view can render without a second
  /// lookup. Errors → empty list (logged).
  Future<List<AppSession>> loadCrossAppSessions({
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final r = await _dio.get(
        '$_base/api/users/me/sessions',
        queryParameters: {'limit': limit, 'offset': offset},
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! Map) return const [];
      final list = (r.data['sessions'] as List? ??
          r.data['data']?['sessions'] as List? ??
          const []);
      return list
          .whereType<Map>()
          .map((j) => AppSession.fromJson(j.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      debugPrint('loadCrossAppSessions error: $e');
      return const [];
    }
  }

  // ─── New Session ─────────────────────────────────────────────────────────

  String newSessionId() =>
      'session-${DateTime.now().millisecondsSinceEpoch}';

  /// Wipe every store whose content is scoped to a single session.
  /// MUST be called SYNCHRONOUSLY the instant a switch starts — if
  /// deferred behind an `await`, the workspace panel renders the
  /// previous session's files during the HTTP round-trip, which was
  /// the exact bug the user reported ("I see the old workspace when
  /// creating a new session"). The chat panel's own session-change
  /// listener runs a second, redundant reset once setActiveSession
  /// fires — harmless, idempotent.
  void _resetSessionScopedStores() {
    PreviewStore().reset();
    WorkspaceModule().reset();
    WorkspaceService().clearAll();
  }

  void setActiveSession(AppSession session) {
    // Leave previous session room before joining the new one.
    final prev = activeSession;
    final isSwitch = prev != null && prev.sessionId != session.sessionId;
    if (isSwitch) {
      DigitornSocketService().leaveSession(prev.sessionId);
      // Synchronous store wipe — avoids the render frame where the
      // new session is "active" but stores still carry the prior
      // session's files / terminal / diagnostics.
      _resetSessionScopedStores();
    }
    activeSession = session;
    notifyListeners();
    // On a real switch, force the daemon to replay every event for
    // the incoming session (`since: 0`). Without this, stores that
    // just got reset by the session-change handler would stay empty
    // because the daemon only replays deltas since our last visit —
    // and the pre-visit snapshot is gone from PreviewStore.
    if (isSwitch) {
      resetSeqFor(session.sessionId);
    }
    _joinSocketRoom(session.appId, session.sessionId);
    _sessionChangeCtrl.add(session.sessionId);
    // Hydrate the daemon-side message queue so the panel above the
    // composer reflects any messages pending from a previous run —
    // refresh, daemon restart, or another tab that enqueued while we
    // were elsewhere.
    // ignore: discarded_futures
    QueueService().hydrate(session.appId, session.sessionId);
    // History is fetched by the chat panel via [loadFullHistory] — a
    // previous `_preloadHistory` call here was duplicated work (same
    // HTTP endpoint, lost data) and has been removed. The chat panel
    // is responsible for toggling [isLoadingHistory] via
    // [markLoadingHistory].
  }

  /// Externally-set loading flag used by the chat panel to drive the
  /// message skeleton while the full history is being fetched +
  /// replayed. Safe to call from any widget state.
  void markLoadingHistory(bool value) {
    if (isLoadingHistory == value) return;
    isLoadingHistory = value;
    notifyListeners();
  }

  /// Create a new session on the daemon and set it as active.
  /// Returns true if successful, false if daemon rejected.
  /// Create a new session on the daemon. The daemon generates the session ID.
  /// Create a new session on the daemon.
  ///
  /// When [workspacePath] is non-null, the daemon binds the session
  /// to that on-disk directory — every workspace mutation mirrors to
  /// the folder and the persistence backend is filesystem-based
  /// (no DB bloat). When null, the daemon picks an isolated
  /// ephemeral workspace under `~/.digitorn/workspaces/…`.
  Future<bool> createAndSetSession(
    String appId, {
    String? workspacePath,
  }) async {
    // Wipe session-scoped stores synchronously BEFORE the HTTP call —
    // creating a new session must not leave the prior session's files
    // visible during the round-trip. setActiveSession (called at the
    // end) runs the same reset again as a belt-and-braces check.
    _resetSessionScopedStores();
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/sessions',
        data: {
          if (workspacePath != null && workspacePath.isNotEmpty)
            'workspace_path': workspacePath,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      debugPrint('createSession ← ${resp.statusCode} ${resp.data}');

      if (resp.statusCode == 200 || resp.statusCode == 201 || resp.statusCode == 202) {
        if (resp.data is! Map) return false;
        final body = resp.data as Map;
        final data = body['data'] as Map<String, dynamic>? ?? body.cast<String, dynamic>();
        final sid = data['session_id'] as String? ?? data['id'] as String? ?? '';
        if (sid.isEmpty) {
          debugPrint('createSession: daemon returned no session_id');
          return false;
        }
        final s = AppSession(
          sessionId: sid,
          appId: appId,
          title: data['title'] as String? ?? '',
          workspacePath: (data['workspace_path'] ?? data['workspace']) as String?
              ?? (workspacePath?.isNotEmpty == true ? workspacePath : null),
          createdAt: DateTime.now(),
          lastActive: DateTime.now(),
          // Commit-on-first-success: the server does NOT persist this
          // session until the first turn ends with `message_done`. Flag
          // it as a draft so the sidebar shows a spinner / "draft"
          // badge, and so a `loadSessions()` refetch before that first
          // success doesn't wipe the entry (it simply won't be there).
          isDraft: true,
        );
        sessions.insert(0, s);
        _draftSessionIds.add(sid);
        _historyCache.remove(sid);
        setActiveSession(s);
        debugPrint('createSession: OK, sid=$sid (draft)');

        // Parse initial context from creation response
        // Try data.context first, then body.context (in case data wrapper is missing)
        final ctx = data['context'] as Map<String, dynamic>?
            ?? body['context'] as Map<String, dynamic>?;
        debugPrint('createSession: data keys=${data.keys.toList()}, ctx=$ctx');
        if (ctx != null) {
          debugPrint('createSession: context received, pressure=${ctx['pressure']}, tokens=${ctx['total_estimated_tokens']}');
          // Session-creation context is the canonical baseline — trust
          // it unconditionally to seed the ring on session switch.
          ContextState().updateFromJson(ctx, authoritative: true);
          SessionMetrics().updateContext(ctx);
        } else {
          debugPrint('createSession: NO context in response');
        }

        return true;
      }
      debugPrint('createSession: status ${resp.statusCode}');
    } catch (e) {
      debugPrint('createSession error: $e');
    }
    return false;
  }

  /// Update the display title of a session locally. Mirrors the
  /// change to [activeSession] when it targets the current session,
  /// so the chat header flips in the same frame the sidebar does —
  /// otherwise readers of `activeSession.title` stay stuck on the
  /// previous (raw / placeholder) title until the next session
  /// switch.
  void updateSessionTitle(String sessionId, String title) {
    final i = sessions.indexWhere((s) => s.sessionId == sessionId);
    bool changed = false;
    if (i != -1) {
      sessions[i] = sessions[i].copyWith(title: title);
      changed = true;
    }
    if (activeSession?.sessionId == sessionId) {
      activeSession = activeSession!.copyWith(title: title);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Get cached history for a session, or empty list
  List<Map<String, dynamic>> getCachedHistory(String sessionId) {
    return _historyCache[sessionId] ?? [];
  }

  /// Invalidate history cache for a session (e.g. after new message)
  void invalidateHistory(String sessionId) {
    _historyCache.remove(sessionId);
  }

  // ─── Event delivery (Socket.IO only) ──────────────────────────────────

  int _lastEventSeq = 0;
  int get lastEventSeq => _lastEventSeq;

  /// Per-session highest seq we have seen. Used to pass `since` on
  /// `join_session` so the daemon only replays what we missed.
  final Map<String, int> _seqBySession = {};

  int seqFor(String sessionId) => _seqBySession[sessionId] ?? 0;

  /// Explicit setter — used by the history loader once replay of the
  /// stored events is complete, so the next `join_session` asks only
  /// for what's newer than the last replayed event.
  void setSeqFor(String sessionId, int seq) {
    if (seq <= 0) return;
    final prev = _seqBySession[sessionId] ?? 0;
    if (seq > prev) _seqBySession[sessionId] = seq;
    if (seq > _lastEventSeq) _lastEventSeq = seq;
  }

  /// Wipe every per-session seq — called when the daemon signals it
  /// has restarted (via a `connected` event with a seq lower than
  /// ours). A restart means the old seqs no longer point at real
  /// events on the server, so the next `join_session` must ask for
  /// everything (`since: 0`).
  void resetAllSeqs() {
    _seqBySession.clear();
    _lastEventSeq = 0;
    _historyCache.clear();
  }

  /// Forget our cached seq for [sessionId] so the next `join_session`
  /// asks the daemon for a full replay (`since: 0`). Used on session
  /// switch so that in-memory stores (PreviewStore, WorkspaceModule)
  /// that just got reset can rebuild from the canonical event stream
  /// instead of showing an empty workspace because the daemon only
  /// replayed "events you haven't seen since last visit".
  void resetSeqFor(String sessionId) {
    _seqBySession.remove(sessionId);
  }

  /// Session ids whose turn is currently running (live). Derived
  /// from `status` events — filled when an agent phase starts, drained
  /// on `turn_complete`/`result`/`error`/`abort`. The session drawer
  /// watches this set to render the "turn in progress" dot without
  /// having to re-fetch the sessions list.
  final Set<String> _runningSessions = {};
  Set<String> get runningSessions => Set.unmodifiable(_runningSessions);

  /// Drop a session from the running-set — called by
  /// [DigitornSocketService.leaveSession] so the drawer stops showing
  /// the live dot for a session the user has closed or switched away
  /// from. Safe to call even if the session isn't in the set.
  void clearRunning(String sessionId) {
    if (_runningSessions.remove(sessionId)) notifyListeners();
  }

  // Phases the daemon emits while a turn is actively progressing.
  static const _runningPhases = {
    'turn_start', 'requesting', 'responding', 'generating',
    'thinking', 'tool_use', 'waiting', 'executing',
    'compacting', 'planning',
  };

  /// Inject an event delivered by [DigitornSocketService].
  ///
  /// Events for sessions other than the currently active one update
  /// the running-set (so the drawer's dots stay accurate) but are
  /// **not** forwarded to `_eventCtrl`. The chat panel's listener
  /// should never see events from a session the user isn't viewing —
  /// a previous isolation filter lived in `_onEvent` but dropped
  /// events silently; filtering at the source is both cheaper and
  /// easier to reason about.
  void injectSocketEvent(Map<String, dynamic> event) {
    final seq = (event['seq'] as num?)?.toInt();
    final sid = event['session_id'] as String?;
    if (seq != null) {
      if (seq > _lastEventSeq) _lastEventSeq = seq;
      if (sid != null && sid.isNotEmpty) {
        final prev = _seqBySession[sid] ?? 0;
        if (seq > prev) _seqBySession[sid] = seq;
      }
    }

    // Maintain the running-sessions set for any session, active or
    // not — the drawer uses it to render the live dot even for
    // background sessions.
    final type = event['type'] as String? ?? '';
    if (sid != null && sid.isNotEmpty) {
      final data = event['data'] as Map<String, dynamic>? ?? const {};
      bool changed = false;
      if (type == 'status') {
        final phase = data['phase'] as String? ?? '';
        if (_runningPhases.contains(phase)) {
          changed = _runningSessions.add(sid);
        }
      } else if (type == 'result' ||
          type == 'turn_complete' ||
          type == 'turn_end' ||
          type == 'error' ||
          type == 'abort') {
        changed = _runningSessions.remove(sid);
      }
      if (changed) notifyListeners();

      // Commit-on-first-success bookkeeping for draft sessions.
      if (_draftSessionIds.contains(sid)) {
        if (type == 'message_done') {
          _onDraftFirstMessageDone(sid);
        } else if ((type == 'error' || type == 'abort') &&
            !_draftCommitPending.contains(sid)) {
          // First turn failed before any `message_done` — the server
          // will never persist this session, so drop our optimistic
          // entry with no trace.
          debugPrint(
              'SessionService: draft $sid failed first turn ($type), removing');
          removeDraftSession(sid);
        }
      }

      // Semantic title push. The daemon MAY emit
      // `session_title_updated` (or legacy `session.title`) after its
      // fire-and-forget LLM call finishes — landing 2–5 s after the
      // first `message_done`. When it does, apply it directly so the
      // sidebar/header flip to the 3-7 word title without waiting for
      // the scheduled refetch in `_onDraftFirstMessageDone`. The
      // refetch is still the fallback when the daemon doesn't emit
      // this event.
      if (type == 'session_title_updated' || type == 'session.title') {
        final data = event['data'] as Map<String, dynamic>? ?? const {};
        final newTitle = (data['title'] as String?)?.trim() ?? '';
        if (newTitle.isNotEmpty) {
          updateSessionTitle(sid, newTitle);
        }
      }
    }

    // Filter at the source: only events for the active session reach
    // the chat panel. Events without a session_id (heartbeat,
    // connected, _connection_*, _session_meta) pass through.
    final active = activeSession?.sessionId;
    if (sid != null && sid.isNotEmpty && active != null && sid != active) {
      return;
    }
    _eventCtrl.add(event);
  }

  /// Ensure the session room is joined on the Socket.IO connection.
  /// Called by [setActiveSession] and after session state checks.
  void _joinSocketRoom(String appId, String sessionId) {
    DigitornSocketService().joinSession(appId, sessionId);
  }

  /// Re-join the session room on the Socket.IO connection.
  void rejoinSessionRoom() {
    final session = activeSession;
    if (session != null) _joinSocketRoom(session.appId, session.sessionId);
  }

  // ─── Session state check + restore + resume ─────────────────────────

  /// Full session reconnection: fetch state, restore workspace, resume if needed
  /// Returns the session metadata from the daemon
  Future<Map<String, dynamic>?> checkAndResume(String appId, String sessionId) async {
    try {
      // Step 1: GET /sessions/{sid} — full session state
      final resp = await _dio.get(
        '$_base/api/apps/$appId/sessions/$sessionId',
        options: _opts,
      );
      if (resp.statusCode != 200 || resp.data == null) return null;

      final data = (resp.data['data'] ?? resp.data) as Map<String, dynamic>;
      final isActive = data['is_active'] as bool? ?? false;
      final interrupted = data['interrupted'] as bool? ?? false;
      final workspace = data['workspace'] as String? ?? '';

      debugPrint('Session state: active=$isActive interrupted=$interrupted workspace=$workspace');

      // Step 2: Notify caller of session metadata (workspace, model, etc.)
      _eventCtrl.add({
        'type': '_session_meta',
        'data': data,
      });

      // Step 3: Re-join session room if active. We used to inject a
      // synthetic `status: responding` event here, but that forced
      // the chat panel's spinner on even when no events followed —
      // leaving a stale spinner forever. The real status events
      // coming from the daemon (after the rejoin) are authoritative.
      if (isActive) {
        debugPrint('Session active, joining session room');
        rejoinSessionRoom();
      } else if (interrupted) {
        debugPrint('Session interrupted — will resume when user sends next message');
        rejoinSessionRoom();
      }

      return data;
    } catch (e) {
      debugPrint('checkAndResume error: $e');
      return null;
    }
  }

  // ─── Send Message ─────────────────────────────────────────────────────────

  /// Last outbound message per session, keyed by session id. Used
  /// as the single source of truth when the credential picker needs
  /// to resend the original message after a grant succeeds — works
  /// even if the user switched sessions mid-picker, unlike the
  /// chat panel's `_lastUserText` which is per-ChatPanel instance.
  final Map<String, PendingMessage> _pendingBySession = {};

  PendingMessage? pendingFor(String sessionId) =>
      _pendingBySession[sessionId];

  void clearPending(String sessionId) {
    _pendingBySession.remove(sessionId);
  }

  /// Send a message, asking the daemon to enqueue it if a turn is
  /// already running. Returns the full [EnqueueResult] envelope so
  /// the caller can distinguish "accepted-and-running" from "parked
  /// in the queue" (which arrives with a [correlationId] + position).
  ///
  /// The daemon supports two modes:
  ///   * `async` (default) — returns immediately with the queued /
  ///     accepted status. Progress arrives via SSE.
  ///   * `wait` — blocks until the turn ends. Legacy mode kept for
  ///     callers that still expect the old synchronous contract.
  Future<EnqueueResult> enqueueMessage(
    String appId,
    String sessionId,
    String message, {
    String? workspace,
    List<String>? images,
    List<String>? files,
    String queueMode = 'async',
    String? correlationId,
    /// Client-generated idempotency key — echoed by the daemon on the
    /// `user_message` event so the optimistic bubble reconciles with
    /// the server's canonical row via exact id match (no content
    /// guessing, robust to duplicate text).
    String? clientMessageId,
  }) async {
    _pendingBySession[sessionId] = PendingMessage(
      appId: appId,
      sessionId: sessionId,
      message: message,
      workspace: workspace,
      images: images == null ? const [] : List.unmodifiable(images),
      files: files == null ? const [] : List.unmodifiable(files),
    );
    try {
      final url = '$_base/api/apps/$appId/sessions/$sessionId/messages';
      final resp = await _dio.post(
        url,
        data: {
          'message': message,
          if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
          if (images != null && images.isNotEmpty) 'images': images,
          if (files != null && files.isNotEmpty) 'files': files,
          'queue_mode': queueMode,
          'correlation_id': ?correlationId,
          'client_message_id': ?clientMessageId,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 600 && s != 401,
        ),
      );
      final status = resp.statusCode ?? 0;
      final body = resp.data;
      if (status == 429) {
        return EnqueueResult.queueFull(
          depth: body is Map ? (body['depth'] as num?)?.toInt() : null,
          max: body is Map ? (body['max'] as num?)?.toInt() : null,
        );
      }
      if (status == 200 || status == 202) {
        final data = (body is Map ? body['data'] : null) as Map?;
        final outerStatus = data?['status'] as String? ?? 'accepted';
        if (outerStatus == 'queued') {
          return EnqueueResult.queued(
            correlationId:
                (data?['correlation_id'] as String?) ?? correlationId ?? '',
            position: (data?['position'] as num?)?.toInt() ?? 0,
            queueDepth: (data?['queue_depth'] as num?)?.toInt() ?? 0,
          );
        }
        return EnqueueResult.accepted(
          correlationId:
              (data?['correlation_id'] as String?) ?? correlationId,
        );
      }
      final err = _extractError(body, status);
      return EnqueueResult.errored(err);
    } catch (e) {
      return EnqueueResult.errored(_humanDioError(e));
    }
  }

  /// GET /api/apps/{app_id}/sessions/{sid}/queue — full list of
  /// pending + running entries, authoritative daemon view.
  Future<List<QueueEntry>> fetchQueue(String appId, String sessionId) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/sessions/$sessionId/queue',
        options: Options(validateStatus: (s) => s != null && s != 401),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return const [];
      final data = (resp.data['data'] ?? resp.data) as Map;
      final entries = (data['entries'] as List?) ?? const [];
      return entries
          .whereType<Map>()
          .map((e) => QueueEntry.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      debugPrint('fetchQueue error: $e');
      return const [];
    }
  }

  /// DELETE /api/apps/{app_id}/sessions/{sid}/queue/{entry_id} —
  /// cancels a queued (not running) entry. Silent success semantics:
  /// returns true when the daemon accepts or the entry has already
  /// been settled.
  Future<bool> cancelQueued(
      String appId, String sessionId, String entryId) async {
    try {
      final resp = await _dio.delete(
        '$_base/api/apps/$appId/sessions/$sessionId/queue/$entryId',
        options: Options(validateStatus: (s) => s != null && s != 401),
      );
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } catch (e) {
      debugPrint('cancelQueued error: $e');
      return false;
    }
  }

  /// POST /api/apps/{app_id}/sessions/{sid}/queue/clear — drops every
  /// queued entry without touching the currently running turn.
  Future<bool> clearQueue(String appId, String sessionId) async {
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/sessions/$sessionId/queue/clear',
        options: Options(
          validateStatus: (s) => s != null && s != 401,
          headers: {'Content-Type': 'application/json'},
        ),
      );
      return resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['success'] == true;
    } catch (e) {
      debugPrint('clearQueue error: $e');
      return false;
    }
  }

  String _humanDioError(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return 'Connection timeout. Check if the daemon is running.';
      }
      if (e.type == DioExceptionType.connectionError) {
        return 'Cannot connect to daemon. Check your network.';
      }
      final body = e.response?.data;
      if (body is Map) {
        return body['error'] as String? ??
            body['detail'] as String? ??
            'Request failed (${e.response?.statusCode})';
      }
      return 'Request failed: ${e.message}';
    }
    return 'Unexpected error: $e';
  }

  String _extractError(dynamic body, int status) {
    String errMsg = 'HTTP $status';
    if (body is Map) {
      errMsg = body['error'] as String? ??
          body['detail'] as String? ??
          body['message'] as String? ??
          errMsg;
    } else if (body is String && body.isNotEmpty) {
      errMsg = body;
    }
    return switch (status) {
      402 => 'Insufficient balance: $errMsg',
      403 => 'Access denied: $errMsg',
      404 => 'Session not found. Try creating a new session.',
      409 => 'Session is busy: $errMsg',
      429 => 'Rate limited. Please wait and try again.',
      500 => 'Server error: $errMsg',
      502 || 503 => 'Daemon is unavailable. Check if it is running.',
      _ => errMsg,
    };
  }

  /// Legacy wrapper — returns null on success, error message string
  /// otherwise. Kept for callers that haven't migrated to
  /// [enqueueMessage]. New code should use [enqueueMessage] so it can
  /// react to the "queued" branch with UI placement.
  Future<String?> sendMessage(
      String appId, String sessionId, String message,
      {String? workspace, List<String>? images, List<String>? files}) async {
    final res = await enqueueMessage(
      appId,
      sessionId,
      message,
      workspace: workspace,
      images: images,
      files: files,
    );
    if (res.isOk) return null;
    return res.error ?? 'send failed';
  }

  // ─── History ─────────────────────────────────────────────────────────────

  /// Load full session history including messages, events, memory,
  /// workbench. Message `content` is normalised in place via
  /// [extractText] so callers can read plain strings regardless of
  /// whether the daemon sent a raw String or a `List<Map>` of typed
  /// blocks (text + images + tool uses).
  ///
  /// 503 → respects `Retry-After` once (warm-up). 404 → throws
  /// [AppNotDeployedException]; the caller should return to the
  /// app picker because the app is no longer deployed.
  Future<Map<String, dynamic>?> loadFullHistory(
      String appId, String sessionId) async {
    try {
      Response resp = await _dio.get(
        '$_base/api/apps/$appId/sessions/$sessionId/history',
        options: _opts,
      );
      if (resp.statusCode == 503) {
        final retryAfter = int.tryParse(
              resp.headers.value('retry-after') ?? '',
            ) ??
            2;
        await Future.delayed(Duration(seconds: retryAfter.clamp(1, 10)));
        resp = await _dio.get(
          '$_base/api/apps/$appId/sessions/$sessionId/history',
          options: _opts,
        );
      }
      if (resp.statusCode == 404) {
        throw AppNotDeployedException(appId);
      }
      if (resp.data != null && resp.data['success'] == true) {
        final data = resp.data['data'] as Map<String, dynamic>? ?? {};
        final rawMessages = (data['messages'] ?? data['turns']) as List?;
        if (rawMessages != null) {
          // Normalise block content → plain string so the chat panel
          // can keep its simple String-based rendering path. Images /
          // tool uses arrive via other events (or via dedicated
          // fields on the assistant turn) so dropping non-text blocks
          // here is safe.
          for (final m in rawMessages) {
            if (m is Map<String, dynamic> && m['content'] is! String) {
              m['content'] = extractText(m['content']);
            }
          }
        }
        return data;
      }
    } on AppNotDeployedException {
      rethrow;
    } catch (e) {
      debugPrint('loadFullHistory error: $e');
    }
    return null;
  }

  /// Backward compat — returns just message turns.
  Future<List<Map<String, dynamic>>> loadHistory(
      String appId, String sessionId) async {
    final full = await loadFullHistory(appId, sessionId);
    if (full == null) return [];
    final list = full['messages'] ?? full['turns'] ?? [];
    return List<Map<String, dynamic>>.from(list);
  }

  // ─── Approve / Deny ────────────────────────────────────────────────────────

  Future<bool> approveRequest({
    required String appId,
    required String requestId,
    required bool approved,
    String message = '',
  }) async {
    try {
      final url = '$_base/api/apps/$appId/approve';
      debugPrint('approveRequest → POST $url (requestId=$requestId approved=$approved message=${message.length > 80 ? "${message.substring(0, 80)}…" : message})');
      final resp = await _dio.post(
        url,
        data: {
          'request_id': requestId,
          'approved': approved,
          if (message.isNotEmpty) ...{
            'message': message,
            'response': message,
            'answer': message,
            'value': message,
            'reply': message,
            'user_response': message,
          },
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      debugPrint('approveRequest ← ${resp.statusCode} ${resp.data}');
      if (resp.statusCode == 200 || resp.statusCode == 202) return true;
      debugPrint('approveRequest: unexpected status ${resp.statusCode}');
      return false;
    } catch (e) {
      debugPrint('approveRequest error: $e');
      return false;
    }
  }

  // ─── Load Pending Approvals ─────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> loadPendingApprovals(String appId) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/approvals',
        options: _opts,
      );
      if (resp.data?['success'] == true) {
        final pending = resp.data['data']['pending'] as List? ?? [];
        return List<Map<String, dynamic>>.from(pending);
      }
    } catch (e) {
      debugPrint('loadPendingApprovals error: $e');
    }
    return [];
  }

  // ─── Abort Session ────────────────────────────────────────────────────────

  /// Cancel the currently running turn. By default the queue is
  /// preserved — the daemon auto-dispatches the next queued message
  /// within ~200 ms (emits `message_started` for it). Pass
  /// [purgeQueue] = true to also drop every queued entry, matching
  /// the old hard-stop behaviour.
  Future<void> abortSession(
    String appId,
    String sessionId, {
    bool purgeQueue = false,
  }) async {
    try {
      final qs = purgeQueue ? '?purge_queue=true' : '';
      await _dio.post(
        '$_base/api/apps/$appId/sessions/$sessionId/abort$qs',
        options: _opts,
      );
    } catch (e) {
      debugPrint('abortSession error: $e');
    }
  }

  // ─── Delete Session ───────────────────────────────────────────────────────

  Future<void> deleteSession(String appId, String sessionId) async {
    try {
      await _dio.delete(
        '$_base/api/apps/$appId/sessions/$sessionId',
        options: _opts,
      );
      sessions.removeWhere((s) => s.sessionId == sessionId);
      if (activeSession?.sessionId == sessionId) {
        activeSession = null;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('deleteSession error: $e');
    }
  }

  // ─── Search Sessions ─────────────────────────────────────────────────────

  List<SessionSearchResult> searchResults = [];
  bool isSearching = false;

  void clearSearch() {
    searchResults = [];
    isSearching = false;
    notifyListeners();
  }

  Future<void> searchSessions(String appId, String query, {int limit = 20, int offset = 0}) async {
    if (query.trim().isEmpty) {
      searchResults = [];
      isSearching = false;
      notifyListeners();
      return;
    }
    isSearching = true;
    notifyListeners();
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/sessions/search',
        queryParameters: {'q': query, 'limit': limit, 'offset': offset},
        options: _opts,
      );
      if (resp.data != null && resp.data['success'] == true) {
        final List list = resp.data['data']['sessions'] ?? [];
        searchResults = list.map((j) => SessionSearchResult.fromJson(j)).toList();
      } else {
        searchResults = [];
      }
    } catch (e) {
      debugPrint('searchSessions error: $e');
      searchResults = [];
    }
    isSearching = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _eventCtrl.close();
    _sessionChangeCtrl.close();
    super.dispose();
  }
}

/// Search result from GET /api/apps/{appId}/sessions/search
class SessionSearchResult {
  final String sessionId;
  final String title;
  final int relevance;
  final List<String> snippets;
  final int messageCount;
  final DateTime? createdAt;
  final DateTime? lastActive;

  const SessionSearchResult({
    required this.sessionId,
    required this.title,
    this.relevance = 0,
    this.snippets = const [],
    this.messageCount = 0,
    this.createdAt,
    this.lastActive,
  });

  factory SessionSearchResult.fromJson(Map<String, dynamic> j) {
    return SessionSearchResult(
      sessionId: j['session_id'] ?? '',
      title: j['title'] ?? '',
      relevance: j['relevance'] ?? 0,
      snippets: (j['snippets'] as List?)?.map((s) => s.toString()).toList() ?? [],
      messageCount: j['message_count'] ?? 0,
      createdAt: _parseTs(j['created_at']),
      lastActive: _parseTs(j['last_active']),
    );
  }

  String get shortId => sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;

  /// Same 3-tier fallback as [AppSession.displayTitle] — prefer the
  /// daemon's title, fall back to the highest-ranked snippet, then
  /// the short id. Search results always carry at least one snippet
  /// (that's why they matched the query), so the middle tier almost
  /// always has something useful to show.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    if (snippets.isNotEmpty) {
      final s = snippets.first.replaceAll('\n', ' ').trim();
      if (s.isNotEmpty) {
        return s.length > 60 ? '${s.substring(0, 60)}…' : s;
      }
    }
    return shortId;
  }

  static DateTime? _parseTs(dynamic v) {
    if (v == null) return null;
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }
}
