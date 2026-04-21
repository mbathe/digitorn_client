/// Pure event bus for user-scoped events delivered over Socket.IO.
///
/// Historically this service owned an SSE connection to
/// `GET /api/users/me/events?since=<seq>`. That transport is gone —
/// the daemon now delivers every event through the single Socket.IO
/// connection owned by [DigitornSocketService], which calls
/// [injectFromSocket] for each incoming envelope.
///
/// The service still exposes:
///   * a broadcast `Stream<UserEvent>` for downstream consumers
///     (`ActivityInboxService`, `ApprovalsService`, `BackgroundService`, …)
///   * persistent `latestSeq` tracking — written to SharedPreferences
///     so a cold start can ask the daemon to replay missed events via
///     `join_app { since }` / `join_session { since }`
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserEvent {
  /// Raw event type from the daemon — `session.completed`,
  /// `session.failed`, `approval_request`, `inbox.created`, etc.
  final String type;

  /// Monotonic per-user sequence number. Persist this to resume
  /// after a restart.
  final int seq;
  final String? appId;
  final String? sessionId;

  /// `session` | `background_activation` | `credential` | `channel`
  /// | `watcher` | `inbox` | `system`
  final String kind;
  final DateTime timestamp;
  final Map<String, dynamic> payload;

  UserEvent({
    required this.type,
    required this.seq,
    required this.kind,
    required this.payload,
    this.appId,
    this.sessionId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory UserEvent.fromEnvelope(String type, Map<String, dynamic> j) {
    return UserEvent(
      type: type,
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      kind: j['kind'] as String? ?? 'system',
      appId: j['app_id'] as String?,
      sessionId: j['session_id'] as String?,
      payload: j['payload'] is Map
          ? (j['payload'] as Map).cast<String, dynamic>()
          : <String, dynamic>{},
      timestamp: _parseTs(j['ts']),
    );
  }

  static DateTime? _parseTs(dynamic v) {
    if (v == null) return null;
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }
}

class UserEventsService extends ChangeNotifier {
  static final UserEventsService _i = UserEventsService._();
  factory UserEventsService() => _i;
  UserEventsService._() {
    _hydrateSeq();
  }

  static const _prefsKey = 'user_events.latest_seq';

  bool _disposed = false;

  int _latestSeq = 0;
  int get latestSeq => _latestSeq;

  final _eventCtrl = StreamController<UserEvent>.broadcast();
  Stream<UserEvent> get events => _eventCtrl.stream;

  /// Always true — the underlying Socket.IO connection tracks its own
  /// state via [DigitornSocketService.isConnected]. Kept for API
  /// compatibility with UI code that used to subscribe here.
  bool get isConnected => true;

  Future<void> _hydrateSeq() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _latestSeq = prefs.getInt(_prefsKey) ?? 0;
      debugPrint('UserEventsService: hydrated seq=$_latestSeq');
    } catch (_) {}
  }

  /// Called by [DigitornSocketService] when a user-scoped event
  /// lands on the socket. Decodes the envelope, bumps the seq
  /// counter, and broadcasts on [events].
  void injectFromSocket(Map<String, dynamic> raw) {
    if (_disposed) return;
    final type = raw['type'] as String? ?? '';
    if (type.isEmpty) return;
    try {
      final event = UserEvent.fromEnvelope(type, raw);
      if (event.seq > _latestSeq) {
        _latestSeq = event.seq;
        _persistSeq();
      }
      _eventCtrl.add(event);
    } catch (e) {
      debugPrint('UserEventsService.injectFromSocket error: $e');
    }
  }

  /// Sync the latest seq from the Socket.IO handshake or app-level join.
  void updateSeq(int seq) {
    if (seq > _latestSeq) {
      _latestSeq = seq;
      _persistSeq();
    }
  }

  /// Clear the persisted seq — call on logout so a different user
  /// on the same device doesn't replay events that aren't theirs.
  Future<void> reset() async {
    _latestSeq = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }

  Future<void> _persistSeq() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, _latestSeq);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _eventCtrl.close();
    super.dispose();
  }
}
