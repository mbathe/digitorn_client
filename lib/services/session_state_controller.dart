/// SessionStateController — per-session authoritative state holder.
///
/// One instance manages one session's state envelope and exposes it as
/// a ChangeNotifier for the UI. The controller:
///
/// 1. Applies state snapshots wholesale (overwrites the envelope)
/// 2. Applies SSE events as deltas on top of the latest snapshot
/// 3. Detects seq gaps and triggers an HTTP resync
/// 4. Runs a watchdog that force-refreshes state after 10s of silence
///    while a turn is reported active
///
/// The UI (animated send button, queue chip, progress bar) reads from
/// `envelope.isTurnActive` / `envelope.queue.depth` / etc. — it never
/// derives these from events directly, which makes the UI immune to
/// dropped events, reordering, and reconnect races.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/state_envelope.dart';
import 'auth_service.dart';

/// Reasons a resync was triggered — logged for debug, also surfaces to
/// the UI if we ever want to show "Reconnecting…" text based on cause.
enum ResyncReason {
  seqGap,
  watchdogTimeout,
  manual,
  reconnect,
  mount,
}

class SessionStateController extends ChangeNotifier {
  SessionStateController._internal();
  static final SessionStateController _instance =
      SessionStateController._internal();
  factory SessionStateController() => _instance;

  // One envelope per session the client has subscribed to. Keeping old
  // sessions around (instead of clearing on switch) lets "go back to
  // previous session" be instant — the existing envelope is still
  // valid until the next event invalidates it, and on join_session the
  // server re-sends a fresh state:snapshot anyway.
  final Map<String, StateEnvelope> _envelopes = {};

  // Per-session watchdog timers. Cancelled when the controller sees
  // fresh activity for that session.
  final Map<String, Timer> _watchdogs = {};

  // Per-session re-entrant resync guard — avoids firing 3 concurrent
  // /state fetches when a burst of events lands before the first
  // returns.
  final Set<String> _inFlightResyncs = {};

  // ── Public getters ─────────────────────────────────────────────────

  StateEnvelope? envelopeFor(String sessionId) => _envelopes[sessionId];

  bool isTurnActive(String sessionId) {
    final env = _envelopes[sessionId];
    return env != null && env.isTurnActive;
  }

  /// Live TurnState as JSON-ish map — convenient for widgets that
  /// display "generating… / thinking… / tool: Bash" badges.
  TurnEnvelope? turnFor(String sessionId) => _envelopes[sessionId]?.turn;

  QueueEnvelope queueFor(String sessionId) =>
      _envelopes[sessionId]?.queue ?? QueueEnvelope.empty;

  // ── Snapshot application (authoritative overwrite) ──────────────────

  /// Apply a full envelope — OVERWRITES any prior state for that session.
  /// Called from:
  ///   - `state:snapshot` SSE event
  ///   - POST /messages response `state` field
  ///   - GET /state HTTP resync
  void applySnapshot(StateEnvelope envelope) {
    if (envelope.sessionId.isEmpty) return;
    _envelopes[envelope.sessionId] = envelope;
    _armWatchdog(envelope.sessionId);
    notifyListeners();
  }

  /// Parse + apply a raw JSON envelope (from event payload or HTTP body).
  /// Silently ignores malformed input — better to keep the previous
  /// envelope than to blow up the UI.
  void applySnapshotJson(Map<String, dynamic> json) {
    try {
      final env = StateEnvelope.fromJson(json);
      applySnapshot(env);
    } catch (e) {
      debugPrint('SessionStateController: snapshot parse failed: $e');
    }
  }

  // ── Delta application — seq-ordered event ingestion ────────────────

  /// Feed an incoming SSE event. Returns true if the delta was applied,
  /// false if the event was stale (seq <= current) or triggered a gap
  /// resync (seq > current+1, with some tolerance).
  bool applyEvent({
    required String sessionId,
    required int seq,
    required String type,
    Map<String, dynamic>? payload,
  }) {
    final env = _envelopes[sessionId];
    if (env == null) return false; // no snapshot yet — will catch up on join

    // Strictly stale — ignore.
    if (seq > 0 && seq <= env.seq) return false;

    // Tolerate small gaps (events arriving slightly out of order due
    // to batching) but force a resync on large gaps — these usually
    // mean we dropped events during a reconnection race.
    final gap = seq - env.seq;
    if (seq > 0 && gap > 5) {
      resync(sessionId, reason: ResyncReason.seqGap);
      return false;
    }

    // Apply the delta. Most events only bump seq + refresh the
    // idle timer via watchdog rearm; a few carry structural info
    // (turn:heartbeat, queue:snapshot, message_done, …) that updates
    // specific fields.
    StateEnvelope next = env.copyWith(seq: seq > 0 ? seq : env.seq);

    switch (type) {
      case 'turn:heartbeat':
        final turnJson = (payload ?? const {})['turn'];
        if (turnJson is Map<String, dynamic>) {
          next = next.copyWith(turn: TurnEnvelope.fromJson(turnJson));
        }
        break;

      case 'message_started':
      case 'user_message':
        // A new turn began. Mark as active and reset the watchdog —
        // tokens/tool_calls will flow next and update deltas.
        // We don't know the full TurnEnvelope shape yet; let the next
        // heartbeat / state:snapshot fill it in. What matters here is
        // the UI knows "turn is running NOW".
        if (next.turn == null) {
          next = next.copyWith(
            turn: TurnEnvelope(
              active: true,
              correlationId: (payload ?? const {})['correlation_id']?.toString() ?? '',
              startedAt:
                  DateTime.now().millisecondsSinceEpoch / 1000.0,
              lastActivityAt:
                  DateTime.now().millisecondsSinceEpoch / 1000.0,
              phase: 'requesting',
              toolCallsCount: 0,
              tokensOut: 0,
              tokensIn: 0,
              interrupted: false,
              durationMs: 0,
              idleMs: 0,
            ),
          );
        }
        break;

      case 'message_done':
      case 'message_cancelled':
      case 'message_failed':
      case 'result':
      case 'turn_complete':
        // Unambiguously terminal — clear the turn envelope. The daemon's
        // `turn_complete` payload does NOT carry `correlation_id`, so
        // keying the clear on a correlation match leaves `isTurnActive`
        // stuck true, which makes `computeBusy` route the next user send
        // to the queue instead of straight to the daemon. Seq ordering
        // in `applyEvent` already filters stale/out-of-order deliveries.
        if (next.turn != null) {
          next = next.copyWith(clearTurn: true);
        }
        break;
      case 'error':
      case 'abort':
        // Guarded: these can fire out-of-band for already-completed
        // turns (legacy retries). Only clear when the correlation_id
        // matches the currently-running turn.
        if (next.turn != null &&
            payload?['correlation_id']?.toString() ==
                next.turn!.correlationId) {
          next = next.copyWith(clearTurn: true);
        }
        break;

      case 'tool_start':
        if (next.turn != null) {
          next = next.copyWith(
            turn: next.turn!.copyWith(
              phase: 'tool_use',
              toolCallsCount: next.turn!.toolCallsCount + 1,
            ),
          );
        }
        break;

      case 'token':
      case 'out_token':
      case 'stream_done':
        if (next.turn != null) {
          next = next.copyWith(turn: next.turn!.copyWith(phase: 'generating'));
        }
        break;

      case 'thinking_started':
      case 'thinking_delta':
        if (next.turn != null) {
          next = next.copyWith(turn: next.turn!.copyWith(phase: 'thinking'));
        }
        break;

      case 'queue:snapshot':
        if (payload != null) {
          next = next.copyWith(queue: QueueEnvelope.fromJson(payload));
        }
        break;

      case 'state:snapshot':
        if (payload != null) {
          applySnapshotJson(payload);
          return true; // handled — don't fall through to the update below
        }
        break;
    }

    _envelopes[sessionId] = next;
    _armWatchdog(sessionId);
    notifyListeners();
    return true;
  }

  // ── Watchdog — detect silence + force resync ───────────────────────

  /// Rearms the per-session silence timer. The timer fires after
  /// [_watchdogTimeout] of NO event activity while a turn is reported
  /// active, forcing an HTTP resync.
  static const Duration _watchdogTimeout = Duration(seconds: 10);

  void _armWatchdog(String sessionId) {
    _watchdogs.remove(sessionId)?.cancel();
    _watchdogs[sessionId] = Timer(_watchdogTimeout, () {
      final env = _envelopes[sessionId];
      if (env != null && env.isTurnActive) {
        resync(sessionId, reason: ResyncReason.watchdogTimeout);
      }
    });
  }

  // ── Resync — HTTP /state with gap-fill ──────────────────────────────

  /// Fetch the authoritative envelope from the server. Replays any
  /// events we've missed since [sinceSeq] ?? lastKnownSeq, then applies
  /// the final snapshot.
  ///
  /// Re-entrant: multiple concurrent callers for the same session
  /// collapse into the first in-flight request.
  Future<void> resync(
    String sessionId, {
    String? appId,
    ResyncReason reason = ResyncReason.manual,
    int? sinceSeq,
  }) async {
    if (_inFlightResyncs.contains(sessionId)) return;
    _inFlightResyncs.add(sessionId);
    try {
      final env = _envelopes[sessionId];
      final effectiveAppId = appId ?? env?.appId;
      if (effectiveAppId == null || effectiveAppId.isEmpty) {
        debugPrint('resync: no appId for $sessionId — skipping');
        return;
      }
      final since = sinceSeq ?? env?.seq ?? 0;
      final token = AuthService().accessToken;
      if (token == null || token.isEmpty) return;

      final base = AuthService().baseUrl;
      final uri = Uri.parse(
        '$base/api/apps/$effectiveAppId/sessions/$sessionId/state'
        '?since_seq=$since',
      );
      final resp = await http
          .get(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        debugPrint(
          'resync: ${resp.statusCode} for $sessionId (reason=$reason)',
        );
        return;
      }

      final body = json.decode(resp.body) as Map<String, dynamic>;
      final data = body['data'];
      if (data is! Map<String, dynamic>) return;

      // Replay gap events FIRST so UIs that listen to the event stream
      // see them in order, then apply the snapshot to overwrite any
      // local drift.
      final gapEvents = data['gap_events'];
      if (gapEvents is List) {
        for (final ev in gapEvents) {
          if (ev is Map<String, dynamic>) {
            applyEvent(
              sessionId: sessionId,
              seq: (ev['seq'] as num?)?.toInt() ?? 0,
              type: (ev['type'] ?? '').toString(),
              payload: ev['payload'] is Map<String, dynamic>
                  ? ev['payload'] as Map<String, dynamic>
                  : null,
            );
          }
        }
      }

      applySnapshotJson(data);
      debugPrint(
        'resync OK sid=$sessionId since=$since new_seq=${envelopeFor(sessionId)?.seq} reason=$reason',
      );
    } catch (e) {
      debugPrint('resync failed sid=$sessionId: $e');
    } finally {
      _inFlightResyncs.remove(sessionId);
    }
  }

  /// Called by the socket layer after a reconnect. Triggers a resync
  /// for the currently active session.
  void onReconnect({String? appId, String? sessionId}) {
    if (sessionId == null || sessionId.isEmpty) return;
    resync(sessionId, appId: appId, reason: ResyncReason.reconnect);
  }

  /// Called when the chat panel mounts or the user switches back to a
  /// session. Fetches a fresh snapshot to ensure the UI is accurate.
  void onSessionEntered({String? appId, String? sessionId}) {
    if (sessionId == null || sessionId.isEmpty) return;
    resync(sessionId, appId: appId, reason: ResyncReason.mount, sinceSeq: 0);
  }

  /// Drop a session's envelope + timers. Called on logout or when a
  /// session is permanently deleted.
  void dispose_(String sessionId) {
    _envelopes.remove(sessionId);
    _watchdogs.remove(sessionId)?.cancel();
    _inFlightResyncs.remove(sessionId);
  }

  void clearAll() {
    _envelopes.clear();
    for (final t in _watchdogs.values) {
      t.cancel();
    }
    _watchdogs.clear();
    _inFlightResyncs.clear();
    notifyListeners();
  }
}
