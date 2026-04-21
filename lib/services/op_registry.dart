/// OpRegistry — the single source of truth for chat ordering.
///
/// ## Why it exists
///
/// The legacy chat flow trusted wire arrival order to position
/// bubbles. This is fragile under three failure modes the daemon
/// exposes:
///
///   1. **Reconnect + replay** — events >N replayed after join
///      interleave with events >N+k that arrive live. Naive
///      append-on-arrival buries older-seq events at the bottom
///      (the "tool_call under its message_done" bug).
///
///   2. **Room fanout** — an `approval_request` emitted to both
///      the user-room AND the session-room lands twice, same
///      `event_id`, same `seq`. Without dedup the UI doubles.
///
///   3. **ASGI pipeline asymmetry** — persistence + Socket.IO
///      broadcast travel different paths with different latencies,
///      so a quick `tool_start` / `tool_call` pair can arrive with
///      the `tool_call` ahead of `tool_start`.
///
/// Fix: every durable event is inserted into a [SplayTreeMap] keyed
/// by `seq`. The chat iterates the tree (sorted) — insertion
/// position is mathematically correct even when a lower-seq event
/// lands last. Dedup uses `event_id` so room-fanout copies collapse
/// to one entry.
///
/// ## Ingest contract
///
/// Callers MUST:
///   * filter by `session_id` BEFORE ingesting — the daemon's seq
///     is per-USER, so two concurrent sessions of the same user
///     share the seq space and gaps are normal.
///   * route ephemeral types (`token`, `thinking_delta`, …) to a
///     volatile buffer, NOT here. The registry throws on ephemeral
///     ingest to catch the misrouting in development.
///   * route snapshot types (`session:snapshot`, `queue:snapshot`,
///     …) to their dedicated controllers.
///
/// ## Reading
///
/// - [inOrder]     → seq-sorted iterable, the canonical chat feed.
/// - [latestFor]   → last event seen for an `op_id` (current state).
/// - [activeOps]   → non-terminal ops (used by the reconciler on
///                    reconnect).
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/event_envelope.dart';

class EphemeralInRegistryError extends Error {
  final String type;
  EphemeralInRegistryError(this.type);
  @override
  String toString() =>
      'EphemeralInRegistryError: `$type` is ephemeral — route it '
      'to the volatile stream buffer, not the durable registry.';
}

class OpRegistry extends ChangeNotifier {
  /// The session this registry is scoped to. Events for other
  /// sessions are filtered at [ingest] since the daemon's `seq` is
  /// monotone per-user, not per-session.
  final String sessionId;

  OpRegistry({required this.sessionId});

  // ── Primary indices ───────────────────────────────────────────

  /// Canonical seq-sorted store. SplayTreeMap keeps insertion
  /// cheap (O(log n)) while ordered iteration is free — the exact
  /// shape the chat widget needs.
  final SplayTreeMap<int, EventEnvelope> _bySeq = SplayTreeMap();

  /// Dedup by stable `event_id`. Same event fanned out on two
  /// rooms collapses to a single entry; re-playing the same seq
  /// (daemon restart seq reset) is also rejected here.
  final Set<String> _seenEventIds = {};

  /// "Current state" of each op = the envelope with the largest
  /// seq seen for that `op_id`. Tool chips / agent pills /
  /// approval modals listen to this map — a late higher-seq event
  /// with `op_state: completed` will flip them in-place without
  /// creating a duplicate UI.
  final Map<String, EventEnvelope> _latestByOpId = {};

  // ── Ingest ────────────────────────────────────────────────────

  /// Ingest an event. Returns true when the event was stored
  /// (false when it was a duplicate or out-of-session no-op).
  /// Throws [EphemeralInRegistryError] if a caller tries to feed
  /// an ephemeral type — this catches the misrouting in dev /
  /// tests rather than silently piling volatile data in the chat
  /// history.
  bool ingest(EventEnvelope e) {
    if (e.isEphemeral) {
      throw EphemeralInRegistryError(e.type);
    }
    if (e.sessionId.isNotEmpty && e.sessionId != sessionId) {
      // Same user, different session — seq is shared, skip.
      return false;
    }
    if (_seenEventIds.contains(e.eventId)) {
      return false; // room fanout / replay overlap
    }
    _seenEventIds.add(e.eventId);

    // Seq should be globally unique per user, but we also guard
    // against a reset after daemon restart.
    if (_bySeq.containsKey(e.seq)) {
      // Different event_id but same seq — race during daemon
      // restart. Keep the earlier insert (it matched our event_id
      // set first) and log.
      debugPrint(
          'OpRegistry: seq collision keeping existing — '
          'seq=${e.seq} new=${e.eventId} '
          'existing=${_bySeq[e.seq]!.eventId}');
      return false;
    }
    _bySeq[e.seq] = e;

    final prev = _latestByOpId[e.opId];
    if (prev == null || e.seq > prev.seq) {
      _latestByOpId[e.opId] = e;
    }
    notifyListeners();
    return true;
  }

  /// Inject the `active_ops:snapshot` reconciliation. For every
  /// reported op whose `last_seq` is ahead of what we've seen
  /// locally, synthesise a tombstone envelope that pins the op's
  /// state. This surfaces ops the client missed while disconnected
  /// (e.g. a mid-turn `tool_start` whose session we rejoined late).
  ///
  /// Caller passes the `active_ops` list from the snapshot payload
  /// — typically:
  /// ```
  /// [{op_id, op_type, op_state, last_seq, last_ts, correlation_id,
  ///   op_parent_id?, last_type, first_seq, started_at}, …]
  /// ```
  /// We require the fields `op_id`, `op_type`, `op_state`, `last_seq`
  /// strictly; anything else is best-effort.
  void reconcileActiveOps(List<Map<String, dynamic>> activeOps) {
    var changed = false;
    for (final op in activeOps) {
      final opId = op['op_id'] as String?;
      if (opId == null) continue;
      final lastSeq = (op['last_seq'] as num?)?.toInt() ?? 0;
      final existing = _latestByOpId[opId];
      if (existing != null && existing.seq >= lastSeq) {
        continue; // registry already ahead of or level with the snapshot
      }

      // Build a synthetic envelope that matches the snapshot's
      // view of the op's current state. It uses a dedicated
      // `synthetic-recon-<opId>` event_id so the real event
      // (when / if it arrives) can still register — we'll just
      // overwrite the synthetic tombstone.
      //
      // `seq` is set to `last_seq` so `inOrder()` positions the
      // reconciled state exactly where the daemon says it was.
      OpType? opType;
      OpState? opState;
      try {
        opType = op['op_type'] is String
            ? OpType.fromString(op['op_type'] as String)
            : null;
        opState = op['op_state'] is String
            ? OpState.fromString(op['op_state'] as String)
            : null;
      } on ContractError catch (err) {
        debugPrint('OpRegistry.reconcileActiveOps: unknown enum in '
            'snapshot for op=$opId — $err');
        continue;
      }
      if (opType == null || opState == null) continue;

      final tsRaw = op['last_ts'] as String? ?? op['started_at'] as String?;
      final ts = tsRaw == null
          ? DateTime.now().toUtc()
          : (DateTime.tryParse(tsRaw)?.toUtc() ?? DateTime.now().toUtc());

      final synthId = 'ev-recon-$opId-$lastSeq';
      if (_seenEventIds.contains(synthId)) continue;

      final synth = EventEnvelope(
        eventId: synthId,
        type: op['last_type'] as String? ?? 'active_op:reconciled',
        kind: 'session',
        seq: lastSeq,
        ts: ts,
        appId: '',
        sessionId: sessionId,
        userId: '',
        correlationId: op['correlation_id'] as String?,
        opId: opId,
        opType: opType,
        opState: opState,
        opParentId: op['op_parent_id'] as String?,
        payload: {
          '_reconciled': true,
          'source': 'active_ops:snapshot',
          ...op,
        },
      );
      _seenEventIds.add(synthId);
      // Replace any stale entry at that seq so the reconciler wins.
      _bySeq[lastSeq] = synth;
      final prev = _latestByOpId[opId];
      if (prev == null || synth.seq > prev.seq) {
        _latestByOpId[opId] = synth;
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // ── Reads ─────────────────────────────────────────────────────

  /// seq-sorted iterable. The chat widget MUST iterate this (not a
  /// List of arrival-order events) or ordering drifts on reconnect.
  Iterable<EventEnvelope> inOrder() => _bySeq.values;

  /// Latest known state of an op, or null when the registry never
  /// saw it. Used by tool chips / agent pills / approval modals to
  /// bind to "the single source of truth" without caring about
  /// intermediate events.
  EventEnvelope? latestFor(String opId) => _latestByOpId[opId];

  /// Non-terminal ops — "what's still running". Excludes the
  /// daemon's ever-running `_system` op by default since it's a
  /// session heartbeat, not a user-visible activity.
  Iterable<EventEnvelope> activeOps({bool includeSystem = false}) {
    return _latestByOpId.values.where((e) {
      if (e.opState.isTerminal) return false;
      if (!includeSystem &&
          (e.opId == '_system' || e.opType == OpType.system)) {
        return false;
      }
      return true;
    });
  }

  /// Highest seq stored, or 0 when empty. Clients pass this as
  /// `since` on their next `join_session` to resume incrementally.
  int get maxSeq => _bySeq.isEmpty ? 0 : _bySeq.lastKey()!;

  /// Number of unique events stored. Useful for dashboards / debug.
  int get length => _bySeq.length;

  bool get isEmpty => _bySeq.isEmpty;

  // ── Lifecycle ────────────────────────────────────────────────

  /// Drop everything. Called on session switch / logout.
  void reset() {
    if (_bySeq.isEmpty && _seenEventIds.isEmpty) return;
    _bySeq.clear();
    _seenEventIds.clear();
    _latestByOpId.clear();
    notifyListeners();
  }
}
