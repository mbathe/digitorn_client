/// Authoritative session state envelope — mirror of the daemon's
/// `build_state_envelope` payload.
///
/// The daemon emits this:
///   - As the `state:snapshot` SSE event on Socket.IO join_session
///   - As the `state` field on POST /messages responses
///   - From `GET /api/apps/{app}/sessions/{sid}/state`
///
/// The client treats this as the single source of truth for UI. Local
/// state (animated send button, queue chip, progress bar) is always
/// derived from the last envelope received. Incoming SSE events update
/// the envelope's fields as deltas.
///
/// Strict invariants (enforced by the server):
///   - `seq` is monotonically increasing per session
///   - `turn` is null when no turn is running
///   - `queue.is_active == true`  iff one entry has status='running'
///   - `server_time` is ISO-8601 UTC — useful for skew detection
library;

import 'package:flutter/foundation.dart';

@immutable
class TurnEnvelope {
  final bool active;
  final String correlationId;
  final double startedAt; // unix seconds
  final double lastActivityAt;
  final String phase; // requesting|generating|thinking|tool_use|waiting
  final int toolCallsCount;
  final int tokensOut;
  final int tokensIn;
  final bool interrupted;
  final int durationMs;
  final int idleMs;

  const TurnEnvelope({
    required this.active,
    required this.correlationId,
    required this.startedAt,
    required this.lastActivityAt,
    required this.phase,
    required this.toolCallsCount,
    required this.tokensOut,
    required this.tokensIn,
    required this.interrupted,
    required this.durationMs,
    required this.idleMs,
  });

  factory TurnEnvelope.fromJson(Map<String, dynamic> json) {
    return TurnEnvelope(
      active: json['active'] == true,
      correlationId: (json['correlation_id'] ?? '').toString(),
      startedAt: (json['started_at'] as num?)?.toDouble() ?? 0.0,
      lastActivityAt:
          (json['last_activity_at'] as num?)?.toDouble() ?? 0.0,
      phase: (json['phase'] ?? 'generating').toString(),
      toolCallsCount: (json['tool_calls_count'] as num?)?.toInt() ?? 0,
      tokensOut: (json['tokens_out'] as num?)?.toInt() ?? 0,
      tokensIn: (json['tokens_in'] as num?)?.toInt() ?? 0,
      interrupted: json['interrupted'] == true,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      idleMs: (json['idle_ms'] as num?)?.toInt() ?? 0,
    );
  }

  TurnEnvelope copyWith({
    bool? active,
    String? phase,
    int? toolCallsCount,
    int? tokensOut,
    int? tokensIn,
    int? idleMs,
  }) {
    return TurnEnvelope(
      active: active ?? this.active,
      correlationId: correlationId,
      startedAt: startedAt,
      lastActivityAt: lastActivityAt,
      phase: phase ?? this.phase,
      toolCallsCount: toolCallsCount ?? this.toolCallsCount,
      tokensOut: tokensOut ?? this.tokensOut,
      tokensIn: tokensIn ?? this.tokensIn,
      interrupted: interrupted,
      durationMs: durationMs,
      idleMs: idleMs ?? this.idleMs,
    );
  }
}

@immutable
class QueueEnvelope {
  final List<Map<String, dynamic>> entries;
  final int depth;
  final bool isActive;
  final String? runningCorrelationId;

  const QueueEnvelope({
    required this.entries,
    required this.depth,
    required this.isActive,
    required this.runningCorrelationId,
  });

  factory QueueEnvelope.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    final entries = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) entries.add(Map<String, dynamic>.from(e));
      }
    }
    return QueueEnvelope(
      entries: entries,
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      isActive: json['is_active'] == true,
      runningCorrelationId: json['running_correlation_id']?.toString(),
    );
  }

  static const empty = QueueEnvelope(
    entries: <Map<String, dynamic>>[],
    depth: 0,
    isActive: false,
    runningCorrelationId: null,
  );
}

@immutable
class CompactionEnvelope {
  final bool hadCompaction;
  final int? lastAtSeq;
  final int? keptFromSeq;

  const CompactionEnvelope({
    required this.hadCompaction,
    this.lastAtSeq,
    this.keptFromSeq,
  });

  factory CompactionEnvelope.fromJson(Map<String, dynamic> json) {
    return CompactionEnvelope(
      hadCompaction: json['had_compaction'] == true,
      lastAtSeq: (json['last_at_seq'] as num?)?.toInt(),
      keptFromSeq: (json['kept_from_seq'] as num?)?.toInt(),
    );
  }

  static const empty = CompactionEnvelope(hadCompaction: false);
}

@immutable
class StateEnvelope {
  final int schemaVersion;
  final String appId;
  final String sessionId;
  final String userId;
  final int seq;
  final TurnEnvelope? turn;
  final QueueEnvelope queue;
  final CompactionEnvelope compaction;
  final DateTime? serverTime;
  final DateTime receivedAt;

  const StateEnvelope({
    required this.schemaVersion,
    required this.appId,
    required this.sessionId,
    required this.userId,
    required this.seq,
    required this.turn,
    required this.queue,
    required this.compaction,
    required this.serverTime,
    required this.receivedAt,
  });

  factory StateEnvelope.fromJson(Map<String, dynamic> json) {
    final turnJson = json['turn'];
    final queueJson = json['queue'];
    final compJson = json['compaction'];
    DateTime? serverTime;
    final stRaw = json['server_time'];
    if (stRaw is String && stRaw.isNotEmpty) {
      serverTime = DateTime.tryParse(stRaw);
    }
    return StateEnvelope(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
      appId: (json['app_id'] ?? '').toString(),
      sessionId: (json['session_id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      turn: (turnJson is Map<String, dynamic>)
          ? TurnEnvelope.fromJson(turnJson)
          : null,
      queue: (queueJson is Map<String, dynamic>)
          ? QueueEnvelope.fromJson(queueJson)
          : QueueEnvelope.empty,
      compaction: (compJson is Map<String, dynamic>)
          ? CompactionEnvelope.fromJson(compJson)
          : CompactionEnvelope.empty,
      serverTime: serverTime,
      receivedAt: DateTime.now(),
    );
  }

  /// Convenience getter — true when the server says a turn is running.
  /// The UI should drive the animated send button exclusively from this.
  bool get isTurnActive => turn != null && turn!.active && !turn!.interrupted;

  /// How long since the server last observed activity on the current
  /// turn. Returns null when no turn is active. Used by the client
  /// watchdog to detect "stuck turns" and trigger a resync.
  Duration? get turnIdle =>
      turn == null ? null : Duration(milliseconds: turn!.idleMs);

  StateEnvelope copyWith({
    int? seq,
    TurnEnvelope? turn,
    bool clearTurn = false,
    QueueEnvelope? queue,
    CompactionEnvelope? compaction,
  }) {
    return StateEnvelope(
      schemaVersion: schemaVersion,
      appId: appId,
      sessionId: sessionId,
      userId: userId,
      seq: seq ?? this.seq,
      turn: clearTurn ? null : (turn ?? this.turn),
      queue: queue ?? this.queue,
      compaction: compaction ?? this.compaction,
      serverTime: serverTime,
      receivedAt: DateTime.now(),
    );
  }

  @override
  String toString() =>
      'StateEnvelope(sid=$sessionId seq=$seq turn.active=$isTurnActive '
      'queue.depth=${queue.depth})';
}
