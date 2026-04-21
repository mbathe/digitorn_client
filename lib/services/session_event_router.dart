/// Routes raw Socket.IO envelopes to the right consumer per the
/// universal event contract.
///
/// ```
///                     +-----------------------+
///   envelope ──────► | SessionEventRouter   |
///                     +-----------------------+
///                        │        │       │
///              snapshot   │ephemeral │durable
///                ▼        ▼       ▼
///      SnapshotSinks  ephemeralStream  OpRegistry
/// ```
///
/// ## Policy
///
///   * **Snapshot types** (`connected`, `preview:snapshot`,
///     `queue:snapshot`, `active_ops:snapshot`,
///     `session:snapshot`, `memory:snapshot`,
///     `approvals:snapshot`, `workspace:snapshot`)
///     → route to their dedicated sink in [SessionSnapshotSinks].
///     Never hit the registry.
///
///   * **Ephemeral types** (token, thinking_delta, in/out_token,
///     assistant_stream_snapshot, streaming_frame, preview:delta,
///     agent_progress, thinking_started) → stream on
///     [ephemeralEvents]. Volatile by nature, never durable.
///
///   * **Durable types** (`user_message`, `message_started`,
///     `message_done`, `tool_start`, `tool_call`, `result`,
///     `hook`, `agent_event`, …) → parse into [EventEnvelope]
///     (strict, payload-first), ingest into [OpRegistry]. The
///     ordering invariant (seq-sorted) is enforced THERE.
///
/// Malformed envelopes are logged and dropped — no silent
/// degradation. If a new event type lands, it arrives here first;
/// add it to [snapshotEventTypes] / [ephemeralEventTypes] in
/// `event_envelope.dart` so the router knows how to route it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/event_envelope.dart';
import 'op_registry.dart';
import 'session_snapshot_sinks.dart';

class SessionEventRouter {
  final OpRegistry registry;
  final SessionSnapshotSinks sinks;

  final StreamController<Map<String, dynamic>> _ephemeralCtrl =
      StreamController.broadcast();

  /// Live stream of raw ephemeral envelopes. ChatPanel subscribes
  /// for thinking / token animation; nothing here is kept past the
  /// widget that consumes it.
  Stream<Map<String, dynamic>> get ephemeralEvents => _ephemeralCtrl.stream;

  SessionEventRouter({required this.registry, required this.sinks});

  /// Dispatch a raw envelope. Every path writes observability
  /// telemetry on malformed data but never crashes the stream.
  void dispatch(Map<String, dynamic> raw) {
    final type = raw['type'];
    if (type is! String || type.isEmpty) {
      debugPrint('SessionEventRouter: skip envelope without type');
      return;
    }

    // ── Snapshots (including the `connected` handshake) ─────
    if (snapshotEventTypes.contains(type)) {
      final payload = (raw['payload'] is Map)
          ? (raw['payload'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      sinks.handleSnapshot(type, payload, envelope: raw);
      // active_ops:snapshot also triggers reconciliation into the
      // registry so orphaned ops resurface after a disconnect.
      if (type == 'active_ops:snapshot') {
        final list = payload['active_ops'];
        if (list is List) {
          registry.reconcileActiveOps(
              list.whereType<Map>()
                  .map((m) => m.cast<String, dynamic>())
                  .toList());
        }
      }
      return;
    }

    // ── Ephemerals (volatile stream) ──────────────────────────
    if (ephemeralEventTypes.contains(type)) {
      _ephemeralCtrl.add(raw);
      return;
    }

    // ── Durable (strict parse → registry) ─────────────────────
    try {
      final env = EventEnvelope.fromJson(raw);
      registry.ingest(env);
    } on ContractError catch (err) {
      debugPrint('SessionEventRouter: dropping malformed $type '
          '(${raw['seq']}): $err');
    } on EphemeralInRegistryError catch (err) {
      // Shouldn't happen (ephemeral check above is exhaustive) but
      // if it does, the registry itself guards against it — we
      // just log so dev sees it.
      debugPrint('SessionEventRouter: registry rejected $type: $err');
    }
  }

  void dispose() {
    _ephemeralCtrl.close();
  }
}
