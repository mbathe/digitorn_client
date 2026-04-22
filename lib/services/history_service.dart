/// Cold-open + reconnect backfill against the daemon's unified
/// `/api/apps/{app_id}/sessions/{session_id}/history` endpoint.
///
/// The daemon persists one event per row in the `history_log` ledger;
/// the response denormalises that ledger into two lists:
///   * `messages[]` — chat bubbles (user + assistant + tool-only),
///     already ordered and with tool_calls merged into their parent
///     assistant turn.
///   * `events[]` — the raw ledger as-is, for reconstructing
///     streaming / thinking / approvals / errors / preview / widgets /
///     agents etc.
///
/// Plus session metadata (title, turn_active, interrupted,
/// pending_queue) and optional restoration snapshots
/// (memory_snapshot, preview_snapshot).
///
/// This file ONLY does the HTTP work + shape normalisation. The
/// downstream reducer (see [EventReducer]) is what turns the lists
/// into bubble/timeline mutations.
library;

import 'package:dio/dio.dart';

import '../ui/chat/event_reducer.dart' show EventEnvelope;

/// Typed snapshot of one `/history` response page.
class HistoryPage {
  /// Denormalised chat bubbles, already ordered.
  final List<HistoryMessage> messages;

  /// Raw event ledger entries — feed to [EventReducer].
  final List<EventEnvelope> events;

  /// Session metadata.
  final HistoryMeta meta;

  /// Pagination cursor — pass to [HistoryService.fetchPage] for the
  /// next chunk. Null when the response reports `events_has_more=false`.
  final int? nextSinceSeq;

  /// True when the daemon has more events beyond this page.
  final bool hasMore;

  /// Total event count in the session (informational, for pagination
  /// UI).
  final int eventsTotal;

  const HistoryPage({
    required this.messages,
    required this.events,
    required this.meta,
    required this.nextSinceSeq,
    required this.hasMore,
    required this.eventsTotal,
  });
}

class HistoryMeta {
  final String sessionId;
  final String appId;
  final String userId;
  final String title;
  final double createdAt;
  final double lastActive;
  final int messageCount;
  final int turnCount;

  /// True when the daemon crashed mid-turn. The UI should mark the
  /// last assistant bubble with a "conversation interrupted" flag.
  final bool interrupted;

  /// True when an LLM call is in flight right now. Don't clear the
  /// spinner after replay if this is true — live events will finish it.
  final bool turnActive;

  /// Messages queued behind the currently-running turn.
  final List<Map<String, dynamic>> pendingQueue;

  /// Optional memory snapshot (goal / todos / facts) — only for apps
  /// that use the memory module.
  final Map<String, dynamic>? memorySnapshot;

  /// Optional preview/workspace snapshot — only for apps with a
  /// preview layer.
  final Map<String, dynamic>? previewSnapshot;

  const HistoryMeta({
    required this.sessionId,
    required this.appId,
    required this.userId,
    required this.title,
    required this.createdAt,
    required this.lastActive,
    required this.messageCount,
    required this.turnCount,
    required this.interrupted,
    required this.turnActive,
    required this.pendingQueue,
    required this.memorySnapshot,
    required this.previewSnapshot,
  });

  factory HistoryMeta.fromJson(Map<String, dynamic> j) => HistoryMeta(
        sessionId: (j['session_id'] as String?) ?? '',
        appId: (j['app_id'] as String?) ?? '',
        userId: (j['user_id'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        createdAt: (j['created_at'] as num?)?.toDouble() ?? 0,
        lastActive: (j['last_active'] as num?)?.toDouble() ?? 0,
        messageCount: (j['message_count'] as num?)?.toInt() ?? 0,
        turnCount: (j['turn_count'] as num?)?.toInt() ?? 0,
        interrupted: j['interrupted'] == true,
        turnActive: j['turn_active'] == true,
        pendingQueue: (j['pending_queue'] is List)
            ? List<Map<String, dynamic>>.from(
                (j['pending_queue'] as List).whereType<Map>().map(
                      (m) => Map<String, dynamic>.from(m),
                    ),
              )
            : const [],
        memorySnapshot: (j['memory_snapshot'] is Map)
            ? Map<String, dynamic>.from(j['memory_snapshot'] as Map)
            : null,
        previewSnapshot: (j['preview_snapshot'] is Map)
            ? Map<String, dynamic>.from(j['preview_snapshot'] as Map)
            : null,
      );
}

/// Denormalised chat bubble from `messages[]`. The daemon has already
/// merged tool_calls into the right assistant message. Multimodal
/// content is passed through verbatim (may be string or list of parts).
class HistoryMessage {
  /// `"user"` | `"assistant"` | `"system"`
  final String role;

  /// String for simple text, list of ContentPart maps for multimodal.
  final dynamic content;

  /// Optional chain-of-thought exposed by the provider.
  final String? thinking;

  /// Tool calls merged into this assistant message. snake_case is
  /// canonical; the daemon also emits camelCase `toolCalls` for
  /// legacy clients — we read both and the downstream renderer sees
  /// the first non-null.
  final List<Map<String, dynamic>> toolCalls;

  /// Raw row — used for any field the typed surface doesn't expose
  /// (timestamp, seq, correlation_id).
  final Map<String, dynamic> raw;

  const HistoryMessage({
    required this.role,
    required this.content,
    required this.thinking,
    required this.toolCalls,
    required this.raw,
  });

  factory HistoryMessage.fromJson(Map<String, dynamic> j) {
    final tc = (j['tool_calls'] ?? j['toolCalls']);
    return HistoryMessage(
      role: (j['role'] as String?) ?? '',
      content: j['content'],
      thinking: j['thinking'] as String?,
      toolCalls: tc is List
          ? List<Map<String, dynamic>>.from(
              tc.whereType<Map>().map((m) => Map<String, dynamic>.from(m)),
            )
          : const [],
      raw: j,
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
}

/// Error surfaced when `/history` returns a non-success envelope.
class HistoryException implements Exception {
  final String message;
  final int? statusCode;
  const HistoryException(this.message, {this.statusCode});
  @override
  String toString() => 'HistoryException($statusCode): $message';
}

/// HTTP client for `/history`. Reusable across sessions — pass a
/// configured Dio in (the one with the daemon base URL + auth
/// interceptor).
class HistoryService {
  final Dio _dio;
  HistoryService(this._dio);

  /// Fetch a single page. For whole-session loads, iterate with
  /// [fetchAllPages] below instead of rolling the loop manually.
  ///
  /// [sinceSeq] — exclusive watermark. `0` on cold open; last
  /// applied seq on reconnect.
  /// [eventsLimit] — cap per page. The daemon's default is 50k which
  /// is plenty for a normal session, but chop it lower during
  /// reconnects to get the spinner off screen faster.
  /// [includeSystem] — usually false; set true to include system
  /// messages in `messages[]` (debug / audit views).
  Future<HistoryPage> fetchPage(
    String appId,
    String sessionId, {
    int sinceSeq = 0,
    int eventsLimit = 50000,
    bool includeSystem = false,
  }) async {
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/sessions/$sessionId/history',
        queryParameters: {
          'since_seq': sinceSeq,
          'events_limit': eventsLimit,
          if (includeSystem) 'include_system': true,
        },
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode == 404) {
        throw HistoryException('Session not found', statusCode: 404);
      }
      if (resp.data is! Map || resp.data['success'] != true) {
        throw HistoryException(
          resp.data is Map
              ? ((resp.data as Map)['error']?.toString() ??
                  'HTTP ${resp.statusCode}')
              : 'HTTP ${resp.statusCode}',
          statusCode: resp.statusCode,
        );
      }
      final data = Map<String, dynamic>.from(resp.data['data'] as Map);
      final rawMessages = data['messages'];
      final rawEvents = data['events'];
      final messages = (rawMessages is List)
          ? rawMessages
              .whereType<Map>()
              .map((m) =>
                  HistoryMessage.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <HistoryMessage>[];
      final events = (rawEvents is List)
          ? rawEvents
              .whereType<Map>()
              .map((m) =>
                  EventEnvelope.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : <EventEnvelope>[];
      return HistoryPage(
        messages: messages,
        events: events,
        meta: HistoryMeta.fromJson(data),
        nextSinceSeq: (data['events_next_seq'] as num?)?.toInt(),
        hasMore: data['events_has_more'] == true,
        eventsTotal: (data['events_total'] as num?)?.toInt() ?? events.length,
      );
    } on DioException catch (e) {
      throw HistoryException(
        e.message ?? 'Network error',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// Fetch every page starting at [sinceSeq] until the daemon reports
  /// `has_more=false`. Use for whole-session cold-open when sessions
  /// are big enough to exceed the per-page cap.
  ///
  /// Returns a single fused page whose `messages` come from the FIRST
  /// page (the daemon returns the full denormalised list on page 0)
  /// and whose `events` are the concatenation of every page's events
  /// in order. Later pages carry no new messages — only more events —
  /// so the bubble list is correct after page 0 alone.
  ///
  /// Invariants:
  ///   * events are globally sorted by `seq` across pages (the daemon
  ///     returns pages in strict seq order; we just concatenate).
  ///   * dedup is a reducer concern — this method may emit duplicate
  ///     event_ids if the daemon replays a tail on reconnect.
  Future<HistoryPage> fetchAllPages(
    String appId,
    String sessionId, {
    int sinceSeq = 0,
    int eventsPerPage = 2000,
    bool includeSystem = false,
  }) async {
    // Fetch page 0 first so head is non-null for the whole method.
    final head = await fetchPage(
      appId,
      sessionId,
      sinceSeq: sinceSeq,
      eventsLimit: eventsPerPage,
      includeSystem: includeSystem,
    );
    final allEvents = <EventEnvelope>[...head.events];
    var since = head.nextSinceSeq ?? sinceSeq;
    var hasMore = head.hasMore;
    while (hasMore) {
      final page = await fetchPage(
        appId,
        sessionId,
        sinceSeq: since,
        eventsLimit: eventsPerPage,
        includeSystem: includeSystem,
      );
      allEvents.addAll(page.events);
      if (!page.hasMore || page.nextSinceSeq == null) break;
      if (page.nextSinceSeq == since) break; // defensive: no progress
      since = page.nextSinceSeq!;
      hasMore = page.hasMore;
    }
    return HistoryPage(
      messages: head.messages,
      events: allEvents,
      meta: head.meta,
      nextSinceSeq: null,
      hasMore: false,
      eventsTotal: allEvents.length,
    );
  }
}
