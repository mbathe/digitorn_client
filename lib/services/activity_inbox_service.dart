/// Cross-app event aggregator. Primary source is the daemon's
/// persistent inbox at `GET /api/users/me/inbox` — we hydrate on
/// open + let `UserEventsService` (via Socket.IO) push new items
/// in real time. On top of that the service still derives a few
/// client-only items from local state (missing/expired credentials)
/// because the daemon doesn't model those as inbox events.
///
/// Read / archive actions are round-tripped to the daemon so they
/// persist across devices:
///   * `markRead(id)`    → POST /api/users/me/inbox/{id}/read
///   * `markAllRead()`   → POST /api/users/me/inbox/read_all
///   * `archive(id)`     → DELETE /api/users/me/inbox/{id}
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'apps_service.dart';
import 'auth_service.dart';
import 'background_app_service.dart';
import 'credential_service.dart';
import 'user_events_service.dart';

enum InboxItemKind {
  failure,
  credentialExpired,
  credentialMissing,
  info,
  sessionRunning,
  sessionCompleted,
  sessionFailed,
  awaitingApproval,
  bgActivationFinished,
}

class InboxItem {
  final String id;
  final InboxItemKind kind;
  final String title;
  final String subtitle;
  final DateTime when;

  /// Optional callback target — the inbox dropdown reads this to
  /// resolve a tap into a navigation action.
  final String? appId;
  final String? sessionId;
  final String? credentialProvider;

  const InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.when,
    this.appId,
    this.sessionId,
    this.credentialProvider,
  });
}

class ActivityInboxService extends ChangeNotifier {
  static final ActivityInboxService _i = ActivityInboxService._();
  factory ActivityInboxService() => _i;
  ActivityInboxService._() {
    _bindWatcher();
  }

  final _appsSvc = AppsService();
  final _bgSvc = BackgroundAppService();
  final _credSvc = CredentialService();
  final _events = UserEventsService();

  /// Monotonic counter appended to every synthetic inbox id so that
  /// two items created in the same millisecond don't collide on the
  /// Map key and clobber each other in [_push].
  int _idSeq = 0;
  String _mkId(String prefix) =>
      '$prefix-${DateTime.now().millisecondsSinceEpoch}-${_idSeq++}';
  StreamSubscription<UserEvent>? _watcherSub;

  late final Dio _dio = Dio(BaseOptions(
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 15),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  List<InboxItem> _items = [];
  List<InboxItem> get items => List.unmodifiable(_items);

  /// Items filtered to hide noise from the app/session the user is
  /// currently looking at. Passing nulls disables the filter.
  List<InboxItem> itemsFiltered({String? excludeAppId, String? excludeSessionId}) {
    if (excludeAppId == null && excludeSessionId == null) {
      return List.unmodifiable(_items);
    }
    return List.unmodifiable(
      _items.where((i) {
        if (excludeAppId != null &&
            excludeSessionId != null &&
            i.appId == excludeAppId &&
            i.sessionId == excludeSessionId) {
          return false;
        }
        if (excludeAppId != null &&
            excludeSessionId == null &&
            i.appId == excludeAppId) {
          return false;
        }
        return true;
      }),
    );
  }

  /// Unread count that honours the same exclusion as [itemsFiltered].
  /// Falls back to the raw server count when both exclusions are null
  /// (zero filtering) since that's the cheapest path.
  int unreadCountFiltered({String? excludeAppId, String? excludeSessionId}) {
    if (excludeAppId == null && excludeSessionId == null) return unreadCount;
    final filtered = itemsFiltered(
      excludeAppId: excludeAppId,
      excludeSessionId: excludeSessionId,
    );
    return filtered.where((i) => !_read.contains(i.id)).length;
  }

  /// Live-updated map of session-id → running InboxItem (one entry
  /// per session currently turning). When a turn ends we promote the
  /// item to a `completed`/`failed` entry. Allows the bell to show
  /// "X sessions running" at a glance.
  final Map<String, InboxItem> _running = {};

  /// IDs the user has acknowledged. Persistent only for the session
  /// lifetime — don't bother saving to disk, the daemon is the source
  /// of truth on next refresh.
  final Set<String> _read = {};

  /// Subscribers that get every newly-added item so other layers
  /// (notifications, OS toasts) can react in real time.
  final _newItemCtrl = StreamController<InboxItem>.broadcast();
  Stream<InboxItem> get onNewItem => _newItemCtrl.stream;

  /// Cheap local count derived from whatever's in memory. Used as
  /// an instant fallback before [fetchUnreadCountFromServer] replies.
  int get unreadCount => _serverUnreadCount ??
      _items.where((i) => !_read.contains(i.id)).length;

  /// Authoritative count from the daemon. Null until the first call
  /// to [fetchUnreadCountFromServer] lands — the getter above hides
  /// that transition by falling back to the local derivation.
  int? _serverUnreadCount;

  /// Fetch the authoritative unread count from
  /// `GET /api/users/me/inbox/unread_count`. Cheaper than a full
  /// `refresh()` — the bell calls this on startup and on every
  /// `inbox.created` event so the badge stays in sync without
  /// re-hydrating the whole list.
  Future<int?> fetchUnreadCountFromServer() async {
    try {
      final r = await _dio.get('$_base/api/users/me/inbox/unread_count');
      if (r.statusCode != 200) return null;
      // The daemon may return any of these shapes:
      //   * a bare number  →  5
      //   * {"unread_count": 5}
      //   * {"unread": 5}
      //   * {"count": 5}
      //   * {"data": {"unread_count": 5}}
      // Accept all of them so we don't break on minor schema drift.
      final body = r.data;
      num? n;
      if (body is num) {
        n = body;
      } else if (body is Map) {
        n = body['unread_count'] as num? ??
            body['unread'] as num? ??
            body['count'] as num?;
        if (n == null && body['data'] is Map) {
          final inner = (body['data'] as Map);
          n = inner['unread_count'] as num? ??
              inner['unread'] as num? ??
              inner['count'] as num?;
        }
      }
      if (n != null) {
        _serverUnreadCount = n.toInt();
        notifyListeners();
        return _serverUnreadCount;
      }
    } catch (_) {}
    return null;
  }

  /// Number of sessions currently turning — the bell uses this to
  /// show a live pulse instead of just the unread count.
  int get runningCount => _running.length;

  bool _refreshing = false;
  DateTime? lastRefresh;

  /// Pull from every source in parallel. Primary is the daemon's
  /// persistent inbox; the local derivations (credentials, bg
  /// activations) get appended for state the daemon doesn't model.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final out = <InboxItem>[];

      // 0. Daemon-persisted inbox items — source of truth for
      //    anything event-driven (completions, failures, approvals,
      //    background activations). We hydrate first so a fresh
      //    cold-start can show history; Socket.IO keeps it live after.
      try {
        final r = await _dio.get(
          '$_base/api/users/me/inbox',
          queryParameters: {'limit': 100, 'include_archived': false},
        );
        debugPrint('[inbox] GET /api/users/me/inbox ← HTTP ${r.statusCode}');
        if (r.statusCode == 200) {
          final raw = _extractItems(r.data);
          debugPrint('[inbox] parsed ${raw.length} items from response');
          for (final entry in raw) {
            if (entry is! Map) continue;
            final item = _itemFromServer(entry.cast<String, dynamic>());
            if (item != null) {
              out.add(item);
              if (entry['read'] == true) _read.add(item.id);
            } else {
              debugPrint('[inbox] skipped malformed entry: $entry');
            }
          }
        }
      } catch (e) {
        debugPrint('[inbox] refresh error: $e');
      }

      // 1. Failed activations from each background app's loaded
      //    activations list (capped at the 10 most recent failures
      //    cross-app to keep the inbox glanceable).
      //    Sequential because BackgroundAppService.activations is
      //    shared state — parallel calls would overwrite each other.
      if (_appsSvc.apps.isEmpty) {
        try {
          await _appsSvc.refresh();
        } catch (_) {}
      }

      for (final app in _appsSvc.apps) {
        if (app.mode != 'background') continue;
        try {
          await _bgSvc.loadActivations(app.appId, limit: 5);
          for (final a in _bgSvc.activations.where((x) => x.status == 'failed')) {
            out.add(InboxItem(
              id: 'fail-${app.appId}-${a.id}',
              kind: InboxItemKind.failure,
              title: '${app.name} — activation failed',
              subtitle: a.error?.split('\n').first ?? 'Run errored out',
              when: a.completedAt ?? a.startedAt ?? DateTime.now(),
              appId: app.appId,
              sessionId: a.sessionId,
            ));
          }
        } catch (_) {}
      }

      // 2. Expired / invalid credentials across every app schema —
      //    fetched in parallel since each getSchema call is independent.
      final credResults = await Future.wait(
        _appsSvc.apps.map((app) async {
          final items = <InboxItem>[];
          try {
            final schema = await _credSvc.getSchema(app.appId);
            for (final p in schema.providers) {
              if (!p.isEditableByEndUser) continue;
              if (p.required && !p.filled) {
                items.add(InboxItem(
                  id: 'missing-${app.appId}-${p.name}',
                  kind: InboxItemKind.credentialMissing,
                  title: '${p.label} required by ${app.name}',
                  subtitle: 'Configure to enable this app',
                  when: DateTime.now(),
                  appId: app.appId,
                  credentialProvider: p.name,
                ));
              } else if (p.status == 'expired') {
                items.add(InboxItem(
                  id: 'expired-${app.appId}-${p.name}',
                  kind: InboxItemKind.credentialExpired,
                  title: '${p.label} expired',
                  subtitle: '${app.name} will fail until you refresh it',
                  when: DateTime.now(),
                  appId: app.appId,
                  credentialProvider: p.name,
                ));
              }
            }
          } catch (_) {}
          return items;
        }),
        eagerError: false,
      );
      for (final appItems in credResults) {
        out.addAll(appItems);
      }

      // Newest first.
      out.sort((a, b) => b.when.compareTo(a.when));
      _items = out;
      lastRefresh = DateTime.now();
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  void markAllRead() {
    _read.addAll(_items.map((i) => i.id));
    _serverUnreadCount = 0;
    notifyListeners();
    // Fire-and-forget — daemon is the source of truth across
    // devices. Failure is silent; the next refresh() will reconcile.
    unawaited(_dio
        .post('$_base/api/users/me/inbox/read_all')
        .catchError((_) => Response(
              requestOptions: RequestOptions(path: ''),
              statusCode: 0,
            )));
  }

  void markRead(String id) {
    final wasUnread = !_read.contains(id);
    _read.add(id);
    if (wasUnread && _serverUnreadCount != null && _serverUnreadCount! > 0) {
      _serverUnreadCount = _serverUnreadCount! - 1;
    }
    notifyListeners();
    unawaited(_dio
        .post('$_base/api/users/me/inbox/$id/read')
        .catchError((_) => Response(
              requestOptions: RequestOptions(path: ''),
              statusCode: 0,
            )));
  }

  bool isRead(String id) => _read.contains(id);

  /// Permanently remove an item from the user's inbox. Optimistic —
  /// we drop it locally first and roll back if the server rejects.
  Future<void> archive(String id) async {
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx == -1) return;
    final removed = _items.removeAt(idx);
    notifyListeners();
    try {
      final r = await _dio.delete('$_base/api/users/me/inbox/$id');
      if (r.statusCode != null && r.statusCode! >= 400) {
        _items.insert(idx, removed);
        notifyListeners();
      }
    } catch (_) {
      _items.insert(idx, removed);
      notifyListeners();
    }
  }

  /// Parse the daemon's inbox envelope into an [InboxItem]. Returns
  /// null if the row is malformed — we skip bad rows rather than
  /// crashing the whole hydrate.
  /// Extract the list of inbox entries from whatever shape the daemon
  /// returned. Supports:
  ///   * `[...]` — bare list at the root
  ///   * `{items: [...]}`
  ///   * `{data: {items: [...]}}` — standard Digitorn envelope
  ///   * `{data: [...]}` — envelope with bare list inside
  ///   * `{inbox: [...]}` — legacy shape
  List _extractItems(dynamic body) {
    if (body is List) return body;
    if (body is! Map) return const [];
    if (body['items'] is List) return body['items'] as List;
    if (body['inbox'] is List) return body['inbox'] as List;
    final data = body['data'];
    if (data is List) return data;
    if (data is Map) {
      if (data['items'] is List) return data['items'] as List;
      if (data['inbox'] is List) return data['inbox'] as List;
    }
    return const [];
  }

  InboxItem? _itemFromServer(Map<String, dynamic> j) {
    var id = j['id'] as String? ?? j['item_id'] as String?;
    if (id == null || id.isEmpty) {
      final kind = j['kind'] ?? j['type'] ?? 'item';
      final appId = j['app_id'] ?? '';
      final sid = j['session_id'] ?? '';
      final ts = j['created_at'] ?? j['ts'] ?? DateTime.now().toIso8601String();
      id = '$kind-$appId-$sid-$ts';
    }
    final kindStr = (j['kind'] as String? ?? j['type'] as String? ?? '')
        .toLowerCase();
    final kind = switch (kindStr) {
      'session.completed' ||
      'session_completed' ||
      'completed' =>
        InboxItemKind.sessionCompleted,
      'session.failed' ||
      'session_failed' ||
      'failed' ||
      'failure' =>
        InboxItemKind.sessionFailed,
      'session.running' ||
      'running' =>
        InboxItemKind.sessionRunning,
      'approval_request' ||
      'awaiting_approval' ||
      'session.awaiting_approval' =>
        InboxItemKind.awaitingApproval,
      'credential_expired' => InboxItemKind.credentialExpired,
      'credential_missing' => InboxItemKind.credentialMissing,
      'bg_activation_finished' ||
      'background_activation' =>
        InboxItemKind.bgActivationFinished,
      _ => InboxItemKind.info,
    };
    DateTime when = DateTime.now();
    final ts = j['created_at'] ?? j['ts'] ?? j['when'];
    if (ts is String) {
      when = DateTime.tryParse(ts) ?? when;
    } else if (ts is num) {
      when = DateTime.fromMillisecondsSinceEpoch((ts * 1000).toInt());
    }
    return InboxItem(
      id: id,
      kind: kind,
      title: (j['title'] as String?) ?? 'Activity',
      subtitle: (j['subtitle'] as String?) ??
          (j['message'] as String?) ??
          (j['preview'] as String?) ??
          '',
      when: when,
      appId: j['app_id'] as String?,
      sessionId: j['session_id'] as String?,
      credentialProvider: j['credential_provider'] as String?,
    );
  }

  // ── Live event ingestion from UserEventsService ────────────────────
  //
  // Live event ingestion from UserEventsService (Socket.IO).
  // We listen to every user-scoped event and translate the ones
  // that should surface in the bell into InboxItems. Everything
  // else (tokens, tool_start, etc.) is ignored here.

  void _bindWatcher() {
    _watcherSub?.cancel();
    _watcherSub = _events.events.listen(_onEvent);
  }

  void _onEvent(UserEvent e) {
    final type = e.type;
    final appId = e.appId ?? '';
    final sid = e.sessionId ?? '';
    final data = e.payload;

    // ── Turn lifecycle ──────────────────────────────────────────────
    if (sid.isNotEmpty &&
        (type == 'session.started' ||
            type == 'session.turn_started' ||
            type == 'turn_started')) {
      _markRunning(appId, sid);
      return;
    }

    if (type == 'session.completed' ||
        type == 'turn_complete' ||
        type == 'agent_done') {
      if (sid.isNotEmpty) _markCompleted(appId, sid, data);
      return;
    }

    if (type == 'session.failed' || type == 'turn_failed') {
      final msg = data['error'] as String? ??
          data['message'] as String? ??
          'Run errored out';
      if (sid.isNotEmpty) _markFailed(appId, sid, msg);
      return;
    }

    if (type == 'approval_request' ||
        type == 'session.awaiting_approval') {
      final tool = data['tool_name'] as String? ?? 'a tool';
      final risk = data['risk_level'] as String? ?? 'unknown';
      _push(InboxItem(
        id: _mkId('approval-$sid'),
        kind: InboxItemKind.awaitingApproval,
        title: 'Approval needed · $tool',
        subtitle: 'Risk: $risk · session ${_short(sid)}',
        when: DateTime.now(),
        appId: appId,
        sessionId: sid,
      ));
      return;
    }

    // ── Background app activation finished ──────────────────────────
    // The daemon emits `bg.activation_completed` when a background
    // trigger (cron, webhook, schedule, …) successfully runs the app
    // once. Surface it as an info row so the user sees recent cron
    // hits without having to open the background dashboard.
    if (type == 'bg.activation_completed') {
      final appLabel = data['app_name'] as String? ?? appId;
      final summary = data['summary'] as String? ??
          data['trigger_type'] as String? ??
          'ran successfully';
      _push(InboxItem(
        id: _mkId('bg-$appId'),
        kind: InboxItemKind.bgActivationFinished,
        title: '$appLabel finished a run',
        subtitle: summary,
        when: DateTime.now(),
        appId: appId,
      ));
      return;
    }

    // ── Credential missing (from the daemon's auth middleware) ─────
    // Surfaced as a soft reminder — the ChatPanel still handles
    // live `credential_auth_required` pickers during a turn.
    if (type == 'credential.missing' ||
        type == 'credential_missing') {
      final provider = data['provider'] as String? ??
          data['provider_name'] as String? ??
          'a provider';
      _push(InboxItem(
        id: 'credmiss-$appId-$provider',
        kind: InboxItemKind.credentialMissing,
        title: 'Missing ${provider.toUpperCase()} credential',
        subtitle: appId.isNotEmpty
            ? '$appId requires a credential to run'
            : 'Connect the credential to enable this app',
        when: DateTime.now(),
        appId: appId.isEmpty ? null : appId,
        credentialProvider: provider,
      ));
      return;
    }

    // ── Credential expired (reserved — not emitted yet by daemon) ──
    if (type == 'credential.expired' ||
        type == 'credential_expired') {
      final provider = data['provider'] as String? ??
          data['provider_name'] as String? ??
          'a provider';
      _push(InboxItem(
        id: 'credexp-$appId-$provider',
        kind: InboxItemKind.credentialExpired,
        title: '${provider.toUpperCase()} credential expired',
        subtitle: appId.isNotEmpty
            ? '$appId will fail until you refresh it'
            : 'Refresh the credential to continue',
        when: DateTime.now(),
        appId: appId.isEmpty ? null : appId,
        credentialProvider: provider,
      ));
      return;
    }

    // ── Quota warning (reserved — not emitted yet by daemon) ───────
    if (type == 'quota.warning' || type == 'quota_warning') {
      _push(InboxItem(
        id: _mkId('quota'),
        kind: InboxItemKind.info,
        title: 'Quota warning',
        subtitle: data['message'] as String? ??
            'You are approaching your monthly quota limit.',
        when: DateTime.now(),
      ));
      return;
    }

    // ── Inbox events pushed directly by the daemon ─────────────────
    // When the daemon writes to its own inbox table it emits
    // `inbox.created`; the payload carries a fully-formed item so
    // we surface it verbatim without guessing.
    if (type == 'inbox.created') {
      final id = data['id'] as String? ?? _mkId('inbox');
      final title = data['title'] as String? ?? 'Activity';
      final subtitle =
          data['subtitle'] as String? ?? data['message'] as String? ?? '';
      _push(InboxItem(
        id: id,
        kind: InboxItemKind.info,
        title: title,
        subtitle: subtitle,
        when: DateTime.now(),
        appId: appId,
        sessionId: sid.isEmpty ? null : sid,
      ));
      // Keep the bell badge in sync with the daemon rather than
      // trusting our local derivation — the server has the real
      // count including items we don't have in memory.
      unawaited(fetchUnreadCountFromServer());
      return;
    }
  }

  void _markRunning(String appId, String sid) {
    if (_running.containsKey(sid)) return;
    final item = InboxItem(
      id: 'running-$sid',
      kind: InboxItemKind.sessionRunning,
      title: 'Agent is working',
      subtitle: 'session ${_short(sid)}',
      when: DateTime.now(),
      appId: appId,
      sessionId: sid,
    );
    _running[sid] = item;
    _push(item);
  }

  void _markCompleted(String appId, String sid, Map<String, dynamic> data) {
    _running.remove(sid);
    final preview = (data['response'] as String?) ??
        (data['summary'] as String?) ??
        'Turn finished';
    _push(InboxItem(
      id: _mkId('done-$sid'),
      kind: InboxItemKind.sessionCompleted,
      title: 'Agent finished a turn',
      subtitle: preview.length > 80 ? '${preview.substring(0, 80)}…' : preview,
      when: DateTime.now(),
      appId: appId,
      sessionId: sid,
    ));
    // Also drop the matching `running-` entry from the visible list.
    _items.removeWhere((it) => it.id == 'running-$sid');
    notifyListeners();
  }

  void _markFailed(String appId, String sid, String message) {
    _running.remove(sid);
    _push(InboxItem(
      id: _mkId('fail-$sid'),
      kind: InboxItemKind.sessionFailed,
      title: 'Agent failed',
      subtitle: message.split('\n').first,
      when: DateTime.now(),
      appId: appId,
      sessionId: sid,
    ));
    _items.removeWhere((it) => it.id == 'running-$sid');
    notifyListeners();
  }

  /// Add a fresh item to the top of the feed and broadcast it on
  /// [onNewItem] so layers like NotificationService can react.
  void _push(InboxItem item) {
    // Replace any existing entry with the same id (keeps the feed
    // idempotent when the daemon emits duplicate events).
    _items.removeWhere((i) => i.id == item.id);
    _items.insert(0, item);
    if (_items.length > 200) {
      _items.removeRange(200, _items.length);
    }
    notifyListeners();
    _newItemCtrl.add(item);
  }

  static String _short(String id) =>
      id.length > 8 ? id.substring(0, 8) : id;

  @override
  void dispose() {
    _watcherSub?.cancel();
    _newItemCtrl.close();
    super.dispose();
  }
}
