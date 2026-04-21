/// Session-level actions exposed by the daemon — the ones that
/// modify or introspect a specific chat session. Grouped here (not
/// in [DigitornApiClient]) so the API surface stays discoverable
/// and the chat panel can compose them without sifting through
/// 1200+ lines of api_client.
///
/// Every method is a thin HTTP wrapper. Failures never throw —
/// they return null / false / an empty record so the UI can toast
/// gracefully. The authoritative error is logged via [debugPrint].
///
/// Coverage (scout audit 2026-04-20, "unwired" → now wired):
///   * POST   /sessions/{sid}/compact              → [compact]
///   * POST   /sessions/{sid}/undo                 → [undo]
///   * POST   /sessions/{sid}/fork                 → [fork]
///   * POST   /sessions/{sid}/resume               → [resume]
///   * POST   /sessions/{sid}/abort                → [abortTurn]
///   * GET    /sessions/{sid}/export               → [exportSession]
///   * GET    /sessions/{sid}/memory               → [fetchMemory]
///   * GET    /sessions/{sid}/preview              → [fetchPreview]
///   * GET    /sessions/{sid}/tasks                → [fetchTasks]
///   * GET    /sessions/{sid}/images/{image_id}    → [fetchImageUrl]
///   * GET    /apps/{id}/sessions/search           → [searchSessions]
///
/// The existing [DigitornApiClient] already owns workspace + file
/// endpoints + core chat send — we keep those there and call here
/// only for session meta-actions.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

class SessionActionsService {
  SessionActionsService._();
  static final SessionActionsService _instance = SessionActionsService._();
  factory SessionActionsService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  Options _opts() => Options(
        validateStatus: (s) => s != null && s < 500 && s != 401,
        headers: const {'Content-Type': 'application/json'},
      );

  // ── Destructive / mutating actions ────────────────────────────

  /// POST /sessions/{sid}/compact — force a compaction cycle.
  /// Returns the daemon's `{before, after, reduced, strategy, …}`
  /// summary on success. Fire-and-forget style; the UI learns the
  /// result via the live `hook/compact_context:end` event too.
  Future<Map<String, dynamic>?> compact(String appId, String sid) async {
    try {
      final r = await _dio.post('/api/apps/$appId/sessions/$sid/compact',
          data: const {}, options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      if ((r.data as Map)['success'] != true) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('SessionActions.compact: $e');
      return null;
    }
  }

  /// POST /sessions/{sid}/undo — revert the last user-assistant pair
  /// (scout-verified: daemon removes two messages + re-anchors the
  /// context). Returns the new message_count on success.
  Future<int?> undo(String appId, String sid) async {
    try {
      final r = await _dio.post('/api/apps/$appId/sessions/$sid/undo',
          data: const {}, options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = ((r.data as Map)['data'] as Map?)
          ?.cast<String, dynamic>();
      return (data?['message_count'] as num?)?.toInt();
    } catch (e) {
      debugPrint('SessionActions.undo: $e');
      return null;
    }
  }

  /// POST /sessions/{sid}/fork — duplicate this session into a new
  /// one (same history, new session_id). Daemon picks the id unless
  /// [targetSessionId] is given. Returns `{session_id, message_count}`.
  Future<Map<String, dynamic>?> fork(
    String appId,
    String sid, {
    String? targetSessionId,
    String? title,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/sessions/$sid/fork',
        data: {
          'target_session_id': ?targetSessionId,
          'title': ?title,
        },
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('SessionActions.fork: $e');
      return null;
    }
  }

  /// POST /sessions/{sid}/resume — ask the daemon to reissue the
  /// last turn after an `interrupted` state (server restart, user
  /// abort, etc.). Returns true on acceptance.
  Future<bool> resume(String appId, String sid) async {
    try {
      final r = await _dio.post('/api/apps/$appId/sessions/$sid/resume',
          data: const {}, options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('SessionActions.resume: $e');
      return false;
    }
  }

  /// POST /sessions/{sid}/abort — cancel the in-flight turn. The
  /// daemon responds with HTTP 200 even when nothing was running;
  /// that's not an error, just a no-op.
  Future<bool> abortTurn(String appId, String sid, {String? reason}) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/sessions/$sid/abort',
        data: {'reason': ?reason},
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('SessionActions.abortTurn: $e');
      return false;
    }
  }

  // ── Read-only introspection ───────────────────────────────────

  /// GET /sessions/{sid}/export — portable session envelope (chat
  /// history + workspace snapshot + metadata). Returns the raw
  /// map so the UI can save it as JSON verbatim.
  Future<Map<String, dynamic>?> exportSession(String appId, String sid) async {
    try {
      final r = await _dio.get('/api/apps/$appId/sessions/$sid/export',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('SessionActions.exportSession: $e');
      return null;
    }
  }

  /// GET /sessions/{sid}/memory — the session's memory module state
  /// (goal, todos, facts). Null if the app has no memory module.
  Future<Map<String, dynamic>?> fetchMemory(String appId, String sid) async {
    try {
      final r = await _dio.get('/api/apps/$appId/sessions/$sid/memory',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('SessionActions.fetchMemory: $e');
      return null;
    }
  }

  /// GET /sessions/{sid}/preview — the preview module's authoritative
  /// snapshot (same shape as the `preview:snapshot` Socket.IO event).
  /// Used on cold-load when the socket hasn't delivered its snapshot yet.
  Future<Map<String, dynamic>?> fetchPreview(String appId, String sid) async {
    try {
      final r = await _dio.get('/api/apps/$appId/sessions/$sid/preview',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('SessionActions.fetchPreview: $e');
      return null;
    }
  }

  /// GET /sessions/{sid}/tasks — background tasks spawned from this
  /// session (agent sub-task launches). Already partially wired by
  /// `BackgroundService` at the app level; this endpoint scopes to
  /// the specific session for the "what did this turn produce"
  /// query.
  Future<List<Map<String, dynamic>>?> fetchTasks(
      String appId, String sid) async {
    try {
      final r = await _dio.get('/api/apps/$appId/sessions/$sid/tasks',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
      final raw = data?['tasks'] ?? data?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('SessionActions.fetchTasks: $e');
      return null;
    }
  }

  /// GET /sessions/{sid}/images/{image_id} — authenticated URL for a
  /// session-scoped image. Since the endpoint streams binary with
  /// auth headers, we expose the URL (callers build it with the
  /// current bearer token) rather than download here — the chat
  /// widget renders through Image.network with auth interceptor.
  String buildImageUrl(String appId, String sid, String imageId) {
    return '${_dio.options.baseUrl}/api/apps/$appId/sessions/$sid'
        '/images/${Uri.encodeComponent(imageId)}';
  }

  /// GET /apps/{id}/sessions/search — server-side search across the
  /// user's session list for [query]. Returns matches with enough
  /// metadata to render a session-picker row.
  Future<List<Map<String, dynamic>>?> searchSessions(
    String appId,
    String query, {
    int limit = 20,
  }) async {
    try {
      final r = await _dio.get(
        '/api/apps/$appId/sessions/search',
        queryParameters: {'q': query, 'limit': limit},
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
      final raw = data?['sessions'] ?? data?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('SessionActions.searchSessions: $e');
      return null;
    }
  }
}
