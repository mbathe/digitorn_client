import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import '../services/auth_service.dart';

class AppSession {
  final String sessionId;
  final String appId;
  final bool isActive;
  final int messageCount;
  final String title;
  final DateTime? createdAt;
  final DateTime? lastActive;

  AppSession({
    required this.sessionId,
    required this.appId,
    this.isActive = false,
    this.messageCount = 0,
    this.title = '',
    this.createdAt,
    this.lastActive,
  });

  factory AppSession.fromJson(Map<String, dynamic> json) {
    return AppSession(
      sessionId: json['session_id'] ?? '',
      appId: json['app_id'] ?? '',
      isActive: json['is_active'] ?? false,
      messageCount: json['message_count'] ?? 0,
      title: json['title'] ?? '',
      createdAt: parseDate(json['created_at']),
      lastActive: parseDate(json['last_active'] ?? json['last_active_at']),
    );
  }

  String get shortId {
    // For IDs like "session-1775430395385", show last 6 digits
    if (sessionId.startsWith('session-') && sessionId.length > 14) {
      return '#${sessionId.substring(sessionId.length - 6)}';
    }
    return sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
  }

  /// Display title: session title, or fallback to short ID
  String get displayTitle => title.isNotEmpty ? title : shortId;

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

  /// True while loading history for the active session
  bool isLoadingHistory = false;

  /// Cached history messages per session (sessionId → turns)
  final Map<String, List<Map<String, dynamic>>> _historyCache = {};

  StreamSubscription? _sseSubscription;
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
    validateStatus: (status) => status != null && status < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  Options get _opts => Options(headers: {
    'Content-Type': 'application/json',
  });

  String get _base => AuthService().baseUrl;

  // ─── List Sessions ───────────────────────────────────────────────────────

  Future<void> loadSessions(String appId) async {
    isLoading = true;
    notifyListeners();
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/sessions',
        options: _opts,
      );
      if (resp.data != null && resp.data['success'] == true) {
        final List list = resp.data['data']['sessions'] ?? [];
        sessions = list.map((j) => AppSession.fromJson(j)).toList();
      }
    } catch (e) {
      debugPrint('SessionService.loadSessions error: $e');
    }
    isLoading = false;
    notifyListeners();
  }

  // ─── New Session ─────────────────────────────────────────────────────────

  String newSessionId() =>
      'session-${DateTime.now().millisecondsSinceEpoch}';

  void setActiveSession(AppSession session) {
    activeSession = session;
    notifyListeners();
    _connectSSE(session.appId, session.sessionId);
    _sessionChangeCtrl.add(session.sessionId);

    // Pre-load history for existing sessions (messageCount > 0)
    if (session.messageCount > 0) {
      _preloadHistory(session.appId, session.sessionId);
    }
  }

  void createAndSetSession(String appId) {
    final sid = newSessionId();
    final s = AppSession(sessionId: sid, appId: appId);
    sessions.insert(0, s);
    _historyCache.remove(sid);
    setActiveSession(s);
  }

  /// Update the display title of a session locally
  void updateSessionTitle(String sessionId, String title) {
    final i = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (i != -1) {
      sessions[i] = AppSession(
        sessionId: sessions[i].sessionId,
        appId: sessions[i].appId,
        isActive: sessions[i].isActive,
        messageCount: sessions[i].messageCount,
        title: title,
        createdAt: sessions[i].createdAt,
        lastActive: sessions[i].lastActive,
      );
      notifyListeners();
    }
  }

  /// Load + cache history for a session
  Future<void> _preloadHistory(String appId, String sessionId) async {
    if (_historyCache.containsKey(sessionId)) return;
    isLoadingHistory = true;
    notifyListeners();
    final turns = await loadHistory(appId, sessionId);
    _historyCache[sessionId] = turns;
    isLoadingHistory = false;
    notifyListeners();
  }

  /// Get cached history for a session, or empty list
  List<Map<String, dynamic>> getCachedHistory(String sessionId) {
    return _historyCache[sessionId] ?? [];
  }

  /// Invalidate history cache for a session (e.g. after new message)
  void invalidateHistory(String sessionId) {
    _historyCache.remove(sessionId);
  }

  // ─── SSE per-session with auto-reconnect + resume ─────────────────────

  bool _sseConnected = false;
  int _lastEventSeq = 0;
  http.Client? _httpClient; // Reusable HTTP client for web SSE // Track last received event sequence for replay
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const _maxReconnectDelay = 30; // seconds

  void _connectSSE(String appId, String sessionId, {int? since}) {
    _sseSubscription?.cancel();
    _reconnectTimer?.cancel();
    _sseConnected = false;

    var url = '$_base/api/apps/$appId/sessions/$sessionId/events';
    if (since != null && since > 0) url += '?since=$since';
    debugPrint('SSE connecting → $url');

    if (kIsWeb) {
      _connectSSEWeb(url, appId, sessionId);
    } else {
      _connectSSENative(url, appId, sessionId);
    }
  }

  /// Web SSE using package:http (supports streaming via fetch API)
  void _connectSSEWeb(String url, String appId, String sessionId) {
    final token = AuthService().accessToken;
    final request = http.Request('GET', Uri.parse(url));
    request.headers['Accept'] = 'text/event-stream';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';

    // Close previous client to prevent connection leaks
    _httpClient?.close();
    _httpClient = http.Client();
    _httpClient!.send(request).then((response) {
      if (response.statusCode != 200) {
        debugPrint('SSE non-200: ${response.statusCode}');
        _scheduleReconnect(appId, sessionId);
        return;
      }
      _sseConnected = true;
      _reconnectAttempts = 0;
      debugPrint('SSE connected ✓ (web)');

      String ct = '';
      String db = '';

      _sseSubscription = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.startsWith('event: ')) {
            ct = line.substring(7).trim();
          } else if (line.startsWith('data: ')) {
            db = line.substring(6).trim();
          } else if (line.isEmpty && ct.isNotEmpty) {
            if (db.isNotEmpty && db != '[DONE]') {
              try {
                final data = jsonDecode(db) as Map<String, dynamic>;
                final seq = data['seq'] as int?;
                if (seq != null) _lastEventSeq = seq;
                _eventCtrl.add({'type': ct, 'data': data});
              } catch (_) {}
            }
            ct = '';
            db = '';
          }
        },
        onError: (e) {
          debugPrint('SSE error: $e');
          _sseConnected = false;
          _scheduleReconnect(appId, sessionId);
        },
        onDone: () {
          debugPrint('SSE stream closed');
          _sseConnected = false;
          _scheduleReconnect(appId, sessionId);
        },
      );
    }).catchError((e) {
      debugPrint('SSE connect error: $e');
      _sseConnected = false;
      _scheduleReconnect(appId, sessionId);
    });
  }

  /// Native SSE using Dio (desktop/mobile)
  void _connectSSENative(String url, String appId, String sessionId) {
    _dio
        .get<ResponseBody>(url, options: Options(
          responseType: ResponseType.stream,
          headers: {'Accept': 'text/event-stream'},
          validateStatus: (status) => status != null && status < 500,
        ))
        .then((response) {
      if (response.statusCode != 200) {
        debugPrint('SSE non-200: ${response.statusCode}');
        _scheduleReconnect(appId, sessionId);
        return;
      }
      _sseConnected = true;
      _reconnectAttempts = 0;
      debugPrint('SSE connected ✓');

      String ct = '';
      String db = '';

      _sseSubscription = response.data?.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.startsWith('event: ')) {
            ct = line.substring(7).trim();
          } else if (line.startsWith('data: ')) {
            db = line.substring(6).trim();
          } else if (line.isEmpty && ct.isNotEmpty) {
            if (db.isNotEmpty && db != '[DONE]') {
              try {
                final data = jsonDecode(db) as Map<String, dynamic>;
                final seq = data['seq'] as int?;
                if (seq != null) _lastEventSeq = seq;
                _eventCtrl.add({'type': ct, 'data': data});
              } catch (_) {}
            }
            ct = '';
            db = '';
          }
        },
        onError: (e) {
          debugPrint('SSE error: $e');
          _sseConnected = false;
          _scheduleReconnect(appId, sessionId);
        },
        onDone: () {
          debugPrint('SSE stream closed');
          _sseConnected = false;
          _scheduleReconnect(appId, sessionId);
        },
      );
    }).catchError((e) {
      debugPrint('SSE connect error: $e');
      _sseConnected = false;
      _scheduleReconnect(appId, sessionId);
    });
  }


  /// Auto-reconnect with exponential backoff
  void _scheduleReconnect(String appId, String sessionId) {
    _reconnectTimer?.cancel();
    // Don't reconnect if session changed
    if (activeSession?.sessionId != sessionId) return;

    final delay = (_reconnectAttempts < 6)
        ? (1 << _reconnectAttempts).clamp(1, _maxReconnectDelay)
        : _maxReconnectDelay;
    _reconnectAttempts++;

    debugPrint('SSE reconnect in ${delay}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (activeSession?.sessionId == sessionId) {
        _connectSSE(appId, sessionId, since: _lastEventSeq);
      }
    });
  }

  /// Reconnect SSE if not connected
  void reconnectSSE() {
    if (_sseConnected) return;
    final session = activeSession;
    if (session != null) {
      _reconnectAttempts = 0;
      _connectSSE(session.appId, session.sessionId, since: _lastEventSeq);
    }
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

      // Step 3: Reconnect SSE if active (but do NOT auto-resume interrupted)
      if (isActive) {
        debugPrint('Session active, reconnecting SSE');
        _eventCtrl.add({'type': 'status', 'data': {'phase': 'responding'}});
        reconnectSSE();
      } else if (interrupted) {
        debugPrint('Session interrupted — will resume when user sends next message');
        reconnectSSE();
        // Do NOT call _resumeSession here — wait for user's next message
      }

      return data;
    } catch (e) {
      debugPrint('checkAndResume error: $e');
      return null;
    }
  }

  /// Resume an interrupted session
  Future<void> _resumeSession(String appId, String sessionId) async {
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/sessions/$sessionId/resume',
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      debugPrint('Resume ← ${resp.statusCode} ${resp.data}');
    } catch (e) {
      debugPrint('Resume error: $e');
    }
  }

  // ─── Send Message ─────────────────────────────────────────────────────────

  Future<String?> sendMessage(
      String appId, String sessionId, String message,
      {String? workspace}) async {
    try {
      final url = '$_base/api/apps/$appId/sessions/$sessionId/messages';
      debugPrint('sendMessage → POST $url (workspace: $workspace)');
      final resp = await _dio.post(
        url,
        data: {
          'message': message,
          if (workspace != null && workspace.isNotEmpty) 'workspace': workspace,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
        ),
      );
      debugPrint('sendMessage ← ${resp.statusCode} ${resp.data}');
      if (resp.statusCode == 200 || resp.statusCode == 202) return null;
      return 'HTTP ${resp.statusCode}: ${resp.data}';
    } catch (e) {
      debugPrint('sendMessage error: $e');
      if (e is DioException) {
         return 'DioError: ${e.response?.statusCode} ${e.message} ${e.response?.data}';
      }
      return e.toString();
    }
  }

  // ─── History ─────────────────────────────────────────────────────────────

  /// Load full session history including messages, events, memory, workbench
  Future<Map<String, dynamic>?> loadFullHistory(
      String appId, String sessionId) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/sessions/$sessionId/history',
        options: _opts,
      );
      if (resp.data != null && resp.data['success'] == true) {
        return resp.data['data'] as Map<String, dynamic>? ?? {};
      }
    } catch (e) {
      debugPrint('loadFullHistory error: $e');
    }
    return null;
  }

  /// Backward compat — returns just message turns
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
      final resp = await _dio.post(
        '$_base/api/apps/$appId/approve',
        data: {
          'request_id': requestId,
          'approved': approved,
          'message': message,
        },
        options: _opts,
      );
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('approveRequest error: $e');
      return false;
    }
  }

  // ─── Abort Session ────────────────────────────────────────────────────────

  Future<void> abortSession(String appId, String sessionId) async {
    try {
      await _dio.post(
        '$_base/api/apps/$appId/sessions/$sessionId/abort',
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
        _sseSubscription?.cancel();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('deleteSession error: $e');
    }
  }

  // ─── Search Sessions ─────────────────────────────────────────────────────

  List<SessionSearchResult> searchResults = [];
  bool isSearching = false;

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
    _sseSubscription?.cancel();
    _reconnectTimer?.cancel();
    _httpClient?.close();
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

  static DateTime? _parseTs(dynamic v) {
    if (v == null) return null;
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }
}
