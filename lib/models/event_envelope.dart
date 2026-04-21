/// Universal event contract (session_event_contract_v2).
///
/// Every Socket.IO envelope emitted by the daemon on the `/events`
/// namespace is structured as:
///
/// ```
/// top-level (transport):
///   type, kind, seq, ts, session_id
/// payload (contract + type-specific data):
///   event_id, op_id, op_type, op_state, op_parent_id?,
///   correlation_id?, session_id, ... type-specific ...
/// ```
///
/// Scout-verified against a live daemon on 2026-04-20
/// (`scout/explore_events.py`, 4 scenarios, 0 contract violations
/// after 7 durable events checked). The payload-first layout is the
/// daemon's canonical shape; [EventEnvelope.fromJson] reads payload
/// first, falls back to top-level — keeping the client robust if
/// the daemon ever migrates fields upward.
///
/// Rules enforced here (no silent fallbacks allowed by contract):
///   * `event_id`, `op_id`, `op_type`, `op_state` MUST be present.
///     A missing field throws [ContractError] rather than producing
///     a half-baked envelope.
///   * `op_type` / `op_state` MUST decode to a known enum value;
///     unknown strings throw (a new op_type is a daemon change and
///     should fail the client explicitly, not silently collapse).
///   * Ephemeral types (see [ephemeralEventTypes]) never carry the
///     full contract — [EventEnvelope.isEphemeral] returns true for
///     them, and [EventEnvelope.tryFromJson] returns null so the
///     caller routes them to the volatile stream buffer instead of
///     the durable [OpRegistry].
library;

import 'package:flutter/foundation.dart';

/// High-level classification of an operation. Mirrors the daemon's
/// `OpType` enum 1:1 — any new value requires a coordinated daemon
/// + client release.
enum OpType {
  turn,
  tool,
  agent,
  approval,
  compact,
  system;

  static OpType fromString(String raw) {
    switch (raw) {
      case 'turn':
        return OpType.turn;
      case 'tool':
        return OpType.tool;
      case 'agent':
        return OpType.agent;
      case 'approval':
        return OpType.approval;
      case 'compact':
        return OpType.compact;
      case 'system':
        return OpType.system;
    }
    throw ContractError('Unknown op_type: $raw');
  }

  String get wire => switch (this) {
        OpType.turn => 'turn',
        OpType.tool => 'tool',
        OpType.agent => 'agent',
        OpType.approval => 'approval',
        OpType.compact => 'compact',
        OpType.system => 'system',
      };
}

/// Lifecycle state of a single operation. Terminal states
/// ([completed], [failed], [cancelled], [timeout]) mean no further
/// event for this `op_id` will ever arrive.
enum OpState {
  pending,
  running,
  waitingApproval,
  completed,
  failed,
  cancelled,
  timeout;

  static OpState fromString(String raw) {
    switch (raw) {
      case 'pending':
        return OpState.pending;
      case 'running':
        return OpState.running;
      case 'waiting_approval':
        return OpState.waitingApproval;
      case 'completed':
        return OpState.completed;
      case 'failed':
        return OpState.failed;
      case 'cancelled':
        return OpState.cancelled;
      case 'timeout':
        return OpState.timeout;
    }
    throw ContractError('Unknown op_state: $raw');
  }

  bool get isTerminal =>
      this == OpState.completed ||
      this == OpState.failed ||
      this == OpState.cancelled ||
      this == OpState.timeout;

  String get wire => switch (this) {
        OpState.pending => 'pending',
        OpState.running => 'running',
        OpState.waitingApproval => 'waiting_approval',
        OpState.completed => 'completed',
        OpState.failed => 'failed',
        OpState.cancelled => 'cancelled',
        OpState.timeout => 'timeout',
      };
}

/// Thrown when the daemon emits an envelope missing a contractual
/// field, or carrying an enum value the client doesn't know. Never
/// caught silently by production code — it should surface as a
/// debug log + a test failure, not a degraded UI.
class ContractError extends Error {
  final String message;
  ContractError(this.message);
  @override
  String toString() => 'ContractError: $message';
}

/// Event types the daemon declares ephemeral. They never hit the
/// durable log (`session_events` table) and the client must not
/// feed them into [OpRegistry]. They still drive live UI (token
/// animation, thinking ticker, agent progress bar) via a volatile
/// side-channel.
const Set<String> ephemeralEventTypes = {
  'token',
  'thinking',
  'thinking_delta',
  'thinking_started',
  'in_token',
  'out_token',
  'assistant_stream_snapshot',
  'streaming_frame',
  'preview:delta',
  'agent_progress',
};

/// Types emitted only as hydration snapshots on `join_session` —
/// they carry a payload but don't belong to any op's lifecycle.
/// Routed to dedicated controllers, never stored in [OpRegistry].
const Set<String> snapshotEventTypes = {
  'connected',
  'preview:snapshot',
  'queue:snapshot',
  'active_ops:snapshot',
  'session:snapshot',
  'memory:snapshot',
  'approvals:snapshot',
  'workspace:snapshot',
};

/// Immutable universal event envelope. Build via [EventEnvelope.fromJson]
/// for durable events or [EventEnvelope.tryFromJson] if the caller
/// is willing to accept null for ephemeral / snapshot shapes.
@immutable
class EventEnvelope {
  /// Globally unique event id. Stable across room fanout — the
  /// canonical dedup key.
  final String eventId;

  /// Fine-grained event type (`tool_start`, `message_done`,
  /// `agent_event`, …).
  final String type;

  /// Coarse classification (`session` | `approval` | `error` |
  /// `system`). Matches the daemon's `EventKind`.
  final String kind;

  /// Monotone **per user** — two concurrent sessions of the same
  /// user share the seq space. Filter by [sessionId] before
  /// ordering within a chat.
  final int seq;

  /// Publish timestamp (daemon-local UTC, microsecond precision).
  final DateTime ts;

  /// App id. May be empty when the daemon omits it (observed on
  /// some legacy events); never null.
  final String appId;

  /// Session id — present at top-level AND in payload; we prefer
  /// top-level because the transport layer fills it in even when
  /// the originating op omitted it.
  final String sessionId;

  /// User id that owns the event. Empty when the daemon omits it
  /// (legacy events); never null.
  final String userId;

  /// Fast-path `fp-*` id OR queue row id identifying the turn this
  /// event belongs to. Null for system events that don't tie to a
  /// turn (e.g. background compaction triggered by a watcher).
  final String? correlationId;

  /// The operation this event belongs to. Every event of the same
  /// cycle shares this id:
  ///
  ///   * turn       → `op_id == correlation_id` (scout-confirmed)
  ///   * tool       → `op-tool-<hex>`
  ///   * agent      → agent id
  ///   * approval   → approval id
  ///   * compact    → `op-compact-<hex>`
  ///   * system     → `_system` (always running, session heartbeat)
  final String opId;

  final OpType opType;
  final OpState opState;

  /// Parent op for nested operations (a tool running inside a
  /// sub-agent has `op_parent_id = agent.op_id`). Null for
  /// top-level ops.
  final String? opParentId;

  /// Type-specific data. Callers must NOT read contract fields
  /// (`event_id`, `op_id`, …) from here — use the typed getters
  /// above. Payload is for domain data only (`content`, `result`,
  /// `tool_name`, …).
  final Map<String, dynamic> payload;

  const EventEnvelope({
    required this.eventId,
    required this.type,
    required this.kind,
    required this.seq,
    required this.ts,
    required this.appId,
    required this.sessionId,
    required this.userId,
    required this.correlationId,
    required this.opId,
    required this.opType,
    required this.opState,
    required this.opParentId,
    required this.payload,
  });

  /// True for ephemeral types — callers MUST route these to the
  /// volatile buffer, not the durable [OpRegistry].
  bool get isEphemeral => ephemeralEventTypes.contains(type);

  /// True for hydration snapshots — routed to their controllers.
  bool get isSnapshot => snapshotEventTypes.contains(type);

  bool get isTerminal => opState.isTerminal;

  /// Strict parse: throws [ContractError] on any missing
  /// contractual field. Use for durable events only. Snapshots /
  /// ephemerals have looser shapes — call [tryFromJson] instead.
  factory EventEnvelope.fromJson(Map<String, dynamic> raw) {
    final payload = (raw['payload'] is Map)
        ? (raw['payload'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};

    String? pick(String key) {
      // Payload wins — it's the canonical carrier per the daemon's
      // contract. Top-level is kept as a fallback for older events
      // and for the transport-only fields.
      final p = payload[key];
      if (p is String && p.isNotEmpty) return p;
      final t = raw[key];
      if (t is String && t.isNotEmpty) return t;
      return null;
    }

    int? pickInt(String key) {
      final v = raw[key] ?? payload[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    }

    final type = raw['type'] as String?;
    if (type == null || type.isEmpty) {
      throw ContractError('envelope missing top-level type');
    }
    final kind = (raw['kind'] as String?) ?? 'session';
    final seq = pickInt('seq');
    if (seq == null) {
      throw ContractError('envelope $type missing seq');
    }
    final rawTs = raw['ts'] as String? ?? payload['ts'] as String?;
    final ts = rawTs == null
        ? throw ContractError('envelope $type missing ts')
        : DateTime.tryParse(rawTs)?.toUtc()
            ?? (throw ContractError('envelope $type has unparseable ts=$rawTs'));

    final eventId = pick('event_id');
    if (eventId == null) {
      throw ContractError('envelope $type seq=$seq missing event_id');
    }
    final opId = pick('op_id');
    if (opId == null) {
      throw ContractError('envelope $type seq=$seq missing op_id');
    }
    final opTypeStr = pick('op_type');
    if (opTypeStr == null) {
      throw ContractError('envelope $type seq=$seq missing op_type');
    }
    final opStateStr = pick('op_state');
    if (opStateStr == null) {
      throw ContractError('envelope $type seq=$seq missing op_state');
    }

    return EventEnvelope(
      eventId: eventId,
      type: type,
      kind: kind,
      seq: seq,
      ts: ts,
      appId: pick('app_id') ?? '',
      sessionId: pick('session_id') ?? '',
      userId: pick('user_id') ?? '',
      correlationId: pick('correlation_id'),
      opId: opId,
      opType: OpType.fromString(opTypeStr),
      opState: OpState.fromString(opStateStr),
      opParentId: pick('op_parent_id'),
      payload: payload,
    );
  }

  /// Non-throwing variant — returns null when the envelope is
  /// ephemeral (by type), a snapshot, or malformed. Use at the
  /// socket boundary where you want to route before parsing.
  static EventEnvelope? tryFromJson(Map<String, dynamic> raw) {
    final type = raw['type'];
    if (type is! String) return null;
    if (ephemeralEventTypes.contains(type)) return null;
    if (snapshotEventTypes.contains(type)) return null;
    try {
      return EventEnvelope.fromJson(raw);
    } on ContractError catch (e, st) {
      debugPrint('EventEnvelope.tryFromJson rejected $type: $e\n$st');
      return null;
    }
  }

  @override
  String toString() =>
      'EventEnvelope(seq=$seq type=$type op=$opId/${opType.wire}/${opState.wire})';
}
