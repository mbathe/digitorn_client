import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:flutter/foundation.dart';
import 'auth_service.dart';
import 'session_service.dart';
import 'user_events_service.dart';

/// Single Socket.IO connection to the daemon's `/events` namespace.
///
/// This is the ONE transport for every server → client event in the
/// app. There is no SSE fallback any more: ChatPanel streaming,
/// inbox updates, approvals, background activations, workbench events
/// — all of them arrive here and get routed to the right consumer
/// stream ([SessionService.events] or [UserEventsService.events]).
///
/// ## Room model
///
/// - **user room**: auto-joined on connect (keyed on the JWT subject).
///   Delivers every user-scoped event (inbox, approvals, credentials,
///   bg activations, quota).
/// - **app room**: joined via [joinApp]. Delivers app-wide events
///   (session lifecycle, deploy notifications).
/// - **session room**: joined via [joinSession]. Delivers per-turn
///   streaming (tokens, tools, status, workbench mutations…).
///
/// Join calls carry `since: <lastSeq>` so the daemon can replay
/// events the client missed while disconnected.
///
/// ## Token lifecycle
///
/// - [AuthService.ensureValidToken] is called every 60 s by an
///   internal timer. If the token expires in < 2 min it is refreshed
///   transparently; the auth listener then reconnects the socket
///   with the new JWT.
/// - Concurrent [connect] calls are coalesced — the daemon's
///   5-connections-per-10s rate limiter is never hit.
///
/// ## Capabilities handshake
///
/// On connect the daemon emits:
///
///     { "type": "connected", "latest_seq": <int>, "payload": { ... } }
///
/// The client uses `latest_seq` to sync [UserEventsService] so the
/// next `join_app` / `join_session` call includes an accurate
/// `since` parameter.
class DigitornSocketService extends ChangeNotifier {
  static final DigitornSocketService _instance =
      DigitornSocketService._internal();
  factory DigitornSocketService() => _instance;
  DigitornSocketService._internal() {
    AuthService().addListener(_onAuthChanged);
    _startTokenRefreshTimer();
  }

  io.Socket? _socket;
  bool isConnected = false;
  String? currentAppId;
  String? _currentBaseUrl;
  String? _lastTokenUsed;
  String? lastError;

  // Coalesce concurrent connect() calls.
  Future<void>? _connectFuture;

  // Proactive JWT refresh — keeps the socket alive across token expiry.
  Timer? _tokenRefreshTimer;

  // Track current session so we can re-join after reconnect.
  String? _currentSessionId;
  String? _currentSessionAppId;

  // Preview events stream — consumed by PreviewWorkspaceProvider.
  final _previewEventsCtrl =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get previewEvents =>
      _previewEventsCtrl.stream;

  // ── Connect ────────────────────────────────────────────────────────────────

  Future<void> connect(String baseUrl) {
    final inflight = _connectFuture;
    if (inflight != null) return inflight;
    final fut = _connect(baseUrl);
    _connectFuture = fut;
    return fut.whenComplete(() => _connectFuture = null);
  }

  Future<void> _connect(String baseUrl) async {
    _currentBaseUrl = baseUrl;

    await AuthService().ensureValidToken();
    final token = AuthService().accessToken;
    if (token == null || token.isEmpty) {
      debugPrint('Socket: no auth token available, skipping connect');
      return;
    }

    if (_socket != null && _socket!.connected && _lastTokenUsed == token) {
      return;
    }

    _disposeSocket();
    _lastTokenUsed = token;

    final options = io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .setAuth({'token': token})
        .setQuery({'token': token})
        .setExtraHeaders({'Authorization': 'Bearer $token'})
        .enableReconnection()
        // Unlimited reconnection attempts. The previous cap of 5
        // meant the client could reach a permanent disconnected
        // state after ~38 seconds of network trouble (the
        // cumulative backoff), leaving the UI apparently functional
        // but silently isolated from the daemon — messages sent
        // after that point never received responses because the
        // socket never re-joined the session room. socket.io_client's
        // contract: a negative value keeps retrying forever with the
        // configured exponential backoff.
        .setReconnectionAttempts(1 << 31)
        .setReconnectionDelay(2000)
        .setReconnectionDelayMax(30000)
        .build();

    final socket = io.io('$baseUrl/events', options);
    _socket = socket;

    socket.onConnect((_) {
      debugPrint('Socket connected → /events');
      final wasConnected = isConnected;
      isConnected = true;
      lastError = null;
      notifyListeners();
      _rejoinRooms();
      // Notify session consumers that the pipe is back up so the
      // ChatPanel can clear its "disconnected" banner. Emit only on
      // transition to avoid spamming subscribers.
      if (!wasConnected) {
        SessionService().injectSocketEvent({
          'type': '_connection_restored',
          'data': <String, dynamic>{},
        });
      }
    });

    socket.onConnectError((err) {
      debugPrint('Socket connect error: $err');
      lastError = err.toString();
      notifyListeners();
    });

    socket.onError((err) {
      debugPrint('Socket error: $err');
      lastError = err.toString();
      notifyListeners();
    });

    socket.onDisconnect((_) {
      debugPrint('Socket disconnected');
      final wasConnected = isConnected;
      isConnected = false;
      notifyListeners();
      if (wasConnected) {
        SessionService().injectSocketEvent({
          'type': '_connection_lost',
          'data': <String, dynamic>{},
        });
      }
    });

    socket.on('event', _handleBusEvent);

    socket.connect();
  }

  // ── Room management ────────────────────────────────────────────────────────

  void joinApp(String appId) {
    currentAppId = appId;
    if (!isConnected) return;
    final since = UserEventsService().latestSeq;
    _socket?.emitWithAck('join_app', {
      'app_id': appId,
      if (since > 0) 'since': since,
    }, ack: (data) {
      if (data is Map && data['ok'] != true) {
        debugPrint('join_app failed: ${data['error']}');
      }
    });
  }

  void joinSession(String appId, String sessionId) {
    _currentSessionAppId = appId;
    _currentSessionId = sessionId;
    if (!isConnected) return;
    // Ask only for what's newer than the highest seq we've seen for
    // this specific session — a fresh session or a full replay both
    // resolve to 0, which asks the daemon for everything.
    final since = SessionService().seqFor(sessionId);
    _socket?.emitWithAck('join_session', {
      'app_id': appId,
      'session_id': sessionId,
      if (since > 0) 'since': since,
    }, ack: (data) {
      if (data is Map && data['ok'] != true) {
        debugPrint('join_session failed: ${data['error']}');
      }
    });
  }

  void leaveSession(String sessionId) {
    _socket?.emitWithAck('leave_session', {
      'session_id': sessionId,
    }, ack: (_) {});
    if (_currentSessionId == sessionId) {
      _currentSessionId = null;
      _currentSessionAppId = null;
    }
    // Drop any cached "running" flag for this session so the drawer
    // and any other observer don't keep thinking a turn is live.
    SessionService().clearRunning(sessionId);
  }

  void leaveApp(String appId) {
    _socket?.emitWithAck('leave_app', {
      'app_id': appId,
    }, ack: (_) {});
    if (currentAppId == appId) currentAppId = null;
  }

  /// Send a message to a session via Socket.IO. The ack from the
  /// daemon signals acceptance — the actual response arrives as
  /// streaming events on the session room.
  void sendMessage({
    required String appId,
    required String sessionId,
    required String message,
    String? workspace,
    List<Map<String, String>>? images,
  }) {
    if (!isConnected || _socket == null) {
      debugPrint('sendMessage: not connected');
      return;
    }
    _socket!.emitWithAck('send_message', {
      'app_id': appId,
      'session_id': sessionId,
      'message': message,
      if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
      if (images != null && images.isNotEmpty) 'images': images,
    }, ack: (data) {
      if (data is Map && data['ok'] != true) {
        debugPrint('send_message rejected: ${data['error']}');
      }
    });
  }

  void _rejoinRooms() {
    final app = currentAppId;
    if (app != null) joinApp(app);
    final sid = _currentSessionId;
    final sAppId = _currentSessionAppId;
    if (sid != null && sAppId != null) joinSession(sAppId, sid);
  }

  // ── Event routing ──────────────────────────────────────────────────────────

  // Events that belong to the per-session stream (ChatPanel, workspace,
  // preview, widgets). Everything else is user-scoped.
  static const _sessionEventTypes = {
    // Agent (17 types)
    'token', 'out_token', 'in_token', 'stream_done', 'token_usage',
    'thinking_started', 'thinking_delta', 'thinking',
    'tool_start', 'tool_call',
    'status', 'hook', 'hook_notification',
    'result', 'turn_complete', 'error', 'abort',
    'memory_update', 'agent_event', 'terminal_output', 'diagnostics',
    // Queue (9 types — daemon-persisted message queue)
    'message_queued', 'message_merged', 'message_replaced',
    'message_started', 'message_done', 'message_cancelled',
    'queue_cleared', 'queue_full',
    // Durable user-message event — fires for every user turn
    // (fast-path + queue-drain), persisted so late joiners see it.
    'user_message',
    // Background tasks
    'bg_task_update',
    // Credentials (2 types)
    'credential_required', 'credential_auth_required',
  };

  /// Returns true for event types prefixed with a session-scoped
  /// namespace. The daemon ships these on `join_session` as the
  /// post-reconnect state snapshot — tested live against
  /// `digitorn-builder/resume-a22188e8`, the daemon emits
  /// `preview:snapshot`, `queue:snapshot`, `active_ops:snapshot`,
  /// `session:snapshot`, `memory:snapshot` immediately after
  /// replaying the event log. Without routing them through to the
  /// chat panel the client can't reconcile its UI with the
  /// authoritative server state after a mid-turn disconnect.
  static bool _isSessionPrefixed(String type) =>
      type.startsWith('widget:') ||
      type.startsWith('preview:') ||
      type.startsWith('queue:') ||
      type.startsWith('memory:') ||
      type.startsWith('session:') ||
      type.startsWith('active_ops:');

  /// Visible for testing — routes a raw Socket.IO envelope to the
  /// appropriate consumer stream.
  @visibleForTesting
  void handleBusEvent(dynamic data) => _handleBusEvent(data);

  void _handleBusEvent(dynamic data) {
    if (data is! Map) return;
    final raw = Map<String, dynamic>.from(data);

    final type = raw['type'] as String? ?? '';
    if (type.isEmpty) return;
    if (type != 'token') debugPrint('Socket event: $type (session=${raw['session_id']}, app=${raw['app_id']})');

    // Handshake — sync the user-scope seq. If the daemon seq is LOWER
    // than ours, the daemon restarted and its seq counter reset — we
    // must reset ours too so we don't ask for a `since` that doesn't
    // exist on the new daemon instance. The per-session seq map is
    // also wiped so subsequent `join_session` calls ask for full
    // replay rather than pointing at seqs that vanished with the
    // daemon's crash.
    if (type == 'connected') {
      final serverSeq = _extractSeq(raw);
      final clientSeq = UserEventsService().latestSeq;
      if (serverSeq > 0 && serverSeq < clientSeq) {
        debugPrint('Socket: daemon restarted (server=$serverSeq < client=$clientSeq) — resetting seq');
        UserEventsService().updateSeq(0);
        SessionService().resetAllSeqs();
      } else if (serverSeq > 0) {
        UserEventsService().updateSeq(serverSeq);
      }
      return;
    }

    final payload = raw['payload'] is Map
        ? Map<String, dynamic>.from(raw['payload'] as Map)
        : <String, dynamic>{};
    final appId = raw['app_id'] as String?;
    final sessionId = raw['session_id'] as String?;
    final seq = (raw['seq'] as num?)?.toInt();
    final kind = raw['kind'] as String?;
    // `ts` is ISO-8601 UTC stamped at publish-time on the daemon
    // (EventBuffer.append). It's the server clock — propagate it
    // verbatim so downstream services can use it for display
    // timestamps and observed-duration calculations. Never used for
    // sort: §0 mandates seq-only ordering.
    final ts = raw['ts'] as String?;

    // Fan out preview events to the dedicated stream.
    if (type.startsWith('preview:')) {
      debugPrint('Socket: preview event → $type (payload keys: ${payload.keys})');
      _previewEventsCtrl.add({'type': type, 'payload': payload, 'seq': seq});
    }

    if (_sessionEventTypes.contains(type) || _isSessionPrefixed(type)) {
      SessionService().injectSocketEvent({
        'type': type,
        'data': payload,
        'seq': ?seq,
        'kind': ?kind,
        'ts': ?ts,
        'app_id': appId,
        'session_id': sessionId,
      });
      return;
    }

    // User-scoped → UserEventsService stream (inbox, approvals, bg…)
    UserEventsService().injectFromSocket(raw);

    // approval_request also needs to reach ChatPanel (session consumer).
    if ((type == 'approval_request' || type == 'session.awaiting_approval')
        && sessionId != null) {
      SessionService().injectSocketEvent({
        'type': type,
        'data': payload,
        'seq': ?seq,
        'kind': ?kind,
        'ts': ?ts,
        'app_id': appId,
        'session_id': sessionId,
      });
    }
  }

  static int _extractSeq(Map<String, dynamic> raw) {
    final direct = raw['latest_seq'] ?? raw['seq'];
    if (direct is num) return direct.toInt();
    final payload = raw['payload'];
    if (payload is Map) {
      final p = payload['latest_seq'] ?? payload['seq'];
      if (p is num) return p.toInt();
    }
    return 0;
  }

  // ── Proactive token refresh ────────────────────────────────────────────────

  void _startTokenRefreshTimer() {
    _tokenRefreshTimer?.cancel();
    _tokenRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      final token = AuthService().accessToken;
      if (token == null || token.isEmpty) return;
      // Refresh if < 120 s left. AuthService fires listeners on some
      // paths but not all, so we compare the token ourselves and
      // reconnect defensively if it rotated — a belt-and-braces
      // guarantee the socket never lingers on an expired JWT.
      await AuthService().ensureValidToken();
      final fresh = AuthService().accessToken;
      if (fresh != null && fresh != _lastTokenUsed && _currentBaseUrl != null) {
        debugPrint('Socket: token rotated silently — reconnecting');
        unawaited(connect(_currentBaseUrl!));
      }
    });
  }

  // ── Auth change ────────────────────────────────────────────────────────────

  void _onAuthChanged() {
    final base = _currentBaseUrl;
    if (base == null) return;
    final token = AuthService().accessToken;
    if (token == null) {
      _disposeSocket();
      _lastTokenUsed = null;
      isConnected = false;
      notifyListeners();
      return;
    }
    if (token != _lastTokenUsed) {
      unawaited(connect(base));
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void _disposeSocket() {
    final s = _socket;
    if (s == null) return;
    try { s.clearListeners(); } catch (_) {}
    try { s.disconnect(); } catch (_) {}
    try { s.dispose(); } catch (_) {}
    _socket = null;
  }

  void disconnect() {
    _disposeSocket();
    isConnected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    AuthService().removeListener(_onAuthChanged);
    _tokenRefreshTimer?.cancel();
    _disposeSocket();
    _previewEventsCtrl.close();
    super.dispose();
  }
}
