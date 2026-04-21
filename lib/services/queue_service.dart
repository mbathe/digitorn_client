/// Persistent message queue — client-side mirror of the daemon's
/// authoritative queue at
/// `GET /api/apps/{app_id}/sessions/{sid}/queue`.
///
/// Source of truth is the daemon. This service:
///   1. Hydrates on session join and socket reconnect.
///   2. Reconciles in real time via SSE events
///      (`message_queued`, `message_started`, `message_done`,
///       `message_cancelled`, `queue_cleared`, `queue_full`, `abort`).
///   3. Supports optimistic UI — the user sees their message as
///      "queued" the instant Send is pressed; the POST response and
///      subsequent `message_queued` event replace the placeholder
///      with the server's canonical row (by correlation id).
///
/// Consumers (ChatPanel, queue panel widget) watch this ChangeNotifier
/// and read [entriesFor] / [pendingFor] / [runningFor].
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/queue_entry.dart';
import 'session_service.dart';

class QueueService extends ChangeNotifier {
  static final QueueService _i = QueueService._();
  factory QueueService() => _i;
  QueueService._();

  /// One queue per session. Order matches daemon FIFO via
  /// [QueueEntry.position].
  final Map<String, List<QueueEntry>> _entriesBySession = {};

  /// Per-session flag toggled the first time we hydrate after a join.
  /// Prevents duplicate hydrations when several call sites (session
  /// join, socket reconnect, route change) race to seed the queue.
  final Set<String> _hydrated = {};

  /// Most recent queue-full event payload — surfaced once via UI as
  /// a toast then cleared.
  QueueFullEvent? _lastQueueFull;
  QueueFullEvent? get lastQueueFull => _lastQueueFull;

  /// Correlation ids that the daemon accepted for immediate dispatch
  /// (the HTTP response said "status: accepted"). The daemon may
  /// still emit a `message_queued` event for these because internally
  /// every message transits through the queue — but the UI should
  /// not flash a "queued" row for a turn that's already running.
  ///
  /// Entries are aged out after [_acceptedTtl]. Long enough to cover
  /// socket reordering, short enough that an honest re-enqueue of
  /// the same id (rare) still lands in the panel.
  final Map<String, int> _acceptedCorrelationIds = {};
  static const int _acceptedTtl = 5; // seconds

  void _markAccepted(String correlationId) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _acceptedCorrelationIds[correlationId] = now + _acceptedTtl;
    _pruneAccepted();
  }

  bool _wasRecentlyAccepted(String correlationId) {
    _pruneAccepted();
    return _acceptedCorrelationIds.containsKey(correlationId);
  }

  void _pruneAccepted() {
    if (_acceptedCorrelationIds.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _acceptedCorrelationIds.removeWhere((_, exp) => exp < now);
  }

  // ── Read-side API ───────────────────────────────────────────────

  List<QueueEntry> entriesFor(String sessionId) =>
      List.unmodifiable(_entriesBySession[sessionId] ?? const []);

  /// All pending entries (status == queued) for a session, in
  /// position order. The running entry, if any, is excluded.
  List<QueueEntry> pendingFor(String sessionId) => entriesFor(sessionId)
      .where((e) => e.status.isPending)
      .toList(growable: false);

  /// Every non-terminal entry — queued + running — in position order
  /// (running first, then queued). Used by the queue panel so the
  /// user keeps seeing their message from "queued" through "running"
  /// until it's truly done, instead of the chip disappearing the
  /// instant the daemon picks it.
  List<QueueEntry> activeFor(String sessionId) {
    final list = entriesFor(sessionId)
        .where((e) => e.status.isPending || e.status.isRunning)
        .toList(growable: false);
    // Stable sort: running entries first (position=0), then queued
    // by ascending position. Matches the FIFO contract.
    final sorted = [...list];
    sorted.sort((a, b) {
      final rankA = a.status.isRunning ? 0 : 1;
      final rankB = b.status.isRunning ? 0 : 1;
      if (rankA != rankB) return rankA.compareTo(rankB);
      return a.position.compareTo(b.position);
    });
    return sorted;
  }

  QueueEntry? runningFor(String sessionId) {
    final list = _entriesBySession[sessionId];
    if (list == null) return null;
    for (final e in list) {
      if (e.status.isRunning) return e;
    }
    return null;
  }

  int pendingCountFor(String sessionId) => pendingFor(sessionId).length;

  int totalCountFor(String sessionId) =>
      _entriesBySession[sessionId]?.length ?? 0;

  bool hasPending(String sessionId) => pendingCountFor(sessionId) > 0;

  // ── Hydration ──────────────────────────────────────────────────

  /// Force re-fetch of the daemon queue and replace the local view.
  /// Call from:
  ///   * [SessionService] when the active session changes.
  ///   * Socket reconnect — the daemon may have progressed the queue
  ///     while we were offline.
  Future<void> hydrate(String appId, String sessionId) async {
    final rows = await SessionService().fetchQueue(appId, sessionId);
    rows.sort((a, b) => a.position.compareTo(b.position));
    _entriesBySession[sessionId] = rows;
    _hydrated.add(sessionId);
    notifyListeners();
  }

  /// Clear a session's cached entries — used when the user fully
  /// leaves the app or deletes the session.
  void forgetSession(String sessionId) {
    if (_entriesBySession.remove(sessionId) != null) {
      _hydrated.remove(sessionId);
      notifyListeners();
    }
  }

  // ── Optimistic add / reconcile ─────────────────────────────────

  /// Returns a fresh UUID-ish correlation id suitable for the client
  /// to pass to POST /messages. Same format the LSP service uses —
  /// opaque string, sub-ms entropy, collision-safe.
  static String newCorrelationId() {
    final ms = DateTime.now().microsecondsSinceEpoch;
    final r = _rng.nextInt(1 << 32).toRadixString(36);
    return 'msg-$ms-$r';
  }

  static final math.Random _rng = math.Random();

  /// Add an optimistic placeholder to the end of the queue — call
  /// BEFORE the HTTP send. The returned correlation id must be
  /// passed to [SessionService.enqueueMessage] so the server assigns
  /// the same id to its canonical row.
  ///
  /// If the daemon reports the message was accepted immediately
  /// (no queue), the placeholder will be replaced by a "running"
  /// entry on the next [onMessageStarted] event.
  QueueEntry addOptimistic(String sessionId, String message) {
    final list = _entriesBySession.putIfAbsent(sessionId, () => []);
    final id = newCorrelationId();
    // Optimistic position is last-in-queue + 1; the server will fix
    // it on reconcile if there's a race with another client.
    final lastPos = list.isEmpty
        ? 0
        : list.map((e) => e.position).reduce(math.max);
    final entry = QueueEntry.optimistic(
      correlationId: id,
      message: message,
      position: lastPos + 1,
    );
    list.add(entry);
    notifyListeners();
    return entry;
  }

  /// Replace an optimistic entry with the server's canonical row.
  ///
  /// The daemon mints its own `correlation_id` for every message
  /// (queue row id or `fp-<hex>` for fast-path), which does not
  /// necessarily equal the id we passed. [tempCid] is what we used
  /// when adding the optimistic entry locally — we look the entry
  /// up by that, then rewrite its id/correlationId to the server's
  /// canonical value so subsequent events (`message_started`,
  /// `message_done`) find the same row.
  void reconcile(String sessionId, EnqueueResult result, {String? tempCid}) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final serverCid = result.correlationId;
    if (serverCid == null) return;

    // Prefer lookup by the client-generated cid we used in
    // addOptimistic; fall back to server cid (in case the daemon
    // kept ours) or the optimistic flag (last-optimistic wins).
    int idx = -1;
    if (tempCid != null && tempCid.isNotEmpty) {
      idx = list.indexWhere((e) => e.correlationId == tempCid);
    }
    if (idx < 0) {
      idx = list.indexWhere((e) => e.correlationId == serverCid);
    }
    if (idx < 0) {
      idx = list.lastIndexWhere(
          (e) => e.optimistic && e.status.isPending);
    }
    if (idx < 0) return;

    if (result.wasQueued) {
      // Do not clobber a row that's already running — a racing
      // `message_started` may have beaten the HTTP response back to
      // us and we shouldn't demote it.
      if (!list[idx].status.isRunning) {
        list[idx] = list[idx].copyWith(
          id: serverCid,
          correlationId: serverCid,
          position: result.position ?? list[idx].position,
          status: QueueEntryStatus.queued,
          optimistic: false,
        );
      }
    } else if (result.wasAccepted) {
      // Dispatched straight to the agent. Drop the optimistic entry
      // and remember the id so any late `message_queued` event (the
      // daemon routes every message through its queue internally)
      // doesn't re-add it to the visible panel.
      list.removeAt(idx);
      _markAccepted(serverCid);
      if (tempCid != null && tempCid != serverCid) _markAccepted(tempCid);
      _reindexPending(list);
      notifyListeners();
      return;
    } else {
      // Errored — drop the optimistic entry so the UI doesn't show a
      // ghost row. The caller decides how to surface the error.
      list.removeAt(idx);
    }
    notifyListeners();
  }

  /// Drop an optimistic entry that never reached the server (network
  /// error, etc.).
  void removeOptimistic(String sessionId, String correlationId) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final before = list.length;
    list.removeWhere(
        (e) => e.optimistic && e.correlationId == correlationId);
    if (list.length != before) notifyListeners();
  }

  // ── Socket event handlers ───────────────────────────────────────
  //
  // Each handler takes the raw event payload (just the `data` map,
  // same shape as the daemon docs). Call sites live in SessionService
  // / ChatPanel where they already route session events.

  /// `message_queued` — daemon accepted the message and assigned a
  /// real position. Promotes an optimistic placeholder to canonical.
  /// Falls back to an insert when the event arrives before the POST
  /// response (rare but possible on fast Socket.IO).
  ///
  /// Socket.IO may deliver `message_queued` and `message_started`
  /// in either order for an accepted-and-immediately-dispatched
  /// message. We must not downgrade a row that's already running or
  /// terminal — otherwise the entry flickers back into the pending
  /// panel while the agent is actively processing it.
  void onMessageQueued(String sessionId, Map<String, dynamic> data) {
    final list = _entriesBySession.putIfAbsent(sessionId, () => []);
    final cid = data['correlation_id'] as String? ?? '';
    if (cid.isEmpty) return;

    // If the HTTP response already marked this id as accepted, the
    // turn is either running right now or done. Ignore the late
    // `message_queued` to keep the panel quiet.
    if (_wasRecentlyAccepted(cid)) return;

    final position = (data['position'] as num?)?.toInt() ?? 0;
    final preview = data['message_preview'] as String? ??
        data['message'] as String? ??
        '';

    // Locate the matching entry:
    //   1. Exact correlation id — happy path, reconcile already ran.
    //   2. Optimistic entry with matching content — the HTTP response
    //      hasn't landed yet, our temp cid is still in place. Adopt
    //      the server's cid now so later events find it.
    //   3. Any optimistic entry at this position — fallback when the
    //      daemon mutated the content (shouldn't happen on plain
    //      enqueue but keeps us safe).
    int idx = list.indexWhere((e) => e.correlationId == cid);
    if (idx < 0 && preview.isNotEmpty) {
      idx = list.indexWhere(
          (e) => e.optimistic && e.message == preview);
    }
    if (idx < 0) {
      idx = list.lastIndexWhere(
          (e) => e.optimistic && e.status.isPending);
    }

    if (idx >= 0) {
      final existing = list[idx];
      // Don't downgrade — the dispatcher already picked up this row
      // and we'll let its canonical status stand.
      if (existing.status.isRunning || existing.status.isTerminal) return;
      list[idx] = existing.copyWith(
        id: cid,
        correlationId: cid,
        position: position,
        status: QueueEntryStatus.queued,
        message: existing.message.isEmpty ? preview : existing.message,
        optimistic: false,
      );
    } else {
      // No optimistic placeholder — create from scratch.
      list.add(QueueEntry(
        id: cid,
        position: position,
        message: preview,
        status: QueueEntryStatus.queued,
        correlationId: cid,
        enqueuedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
      ));
    }
    _resort(list);
    notifyListeners();
  }

  /// `message_merged` — the daemon's auto-merge folded the new text
  /// into an existing tail-queued row. Same `correlation_id` as the
  /// pre-existing row, but the preview now carries the concatenated
  /// message (separated by `\n\n---\n\n` per daemon contract).
  ///
  /// The UX intent is that the tail entry *reads differently* now —
  /// rapid successive sends collapse into one turn rather than
  /// queueing 5 separate LLM calls.
  void onMessageMerged(String sessionId, Map<String, dynamic> data) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final cid = data['correlation_id'] as String? ?? '';
    if (cid.isEmpty) return;
    final preview = data['message_preview'] as String? ?? '';
    final idx = list.indexWhere((e) => e.correlationId == cid);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(
        message: preview.isNotEmpty ? preview : list[idx].message,
        enqueuedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
        optimistic: false,
      );
      notifyListeners();
    } else if (preview.isNotEmpty) {
      // We don't have a pre-existing row for the id — could happen if
      // the client joined after the original enqueue. Fall back to
      // plain add so the user still sees the merged row.
      list.add(QueueEntry(
        id: cid,
        position: (data['position'] as num?)?.toInt() ?? list.length + 1,
        message: preview,
        status: QueueEntryStatus.queued,
        correlationId: cid,
        enqueuedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
      ));
      _resort(list);
      notifyListeners();
    }
  }

  /// `message_replaced` — user re-submitted with `queue_mode=replace_last`.
  /// The daemon rotates the correlation id and resets the timestamp
  /// on the tail queued row. We look up the previous row by position
  /// (or by prior correlation id when we cached it) and swap both.
  void onMessageReplaced(String sessionId, Map<String, dynamic> data) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final newCid = data['correlation_id'] as String? ?? '';
    if (newCid.isEmpty) return;
    final position = (data['position'] as num?)?.toInt() ?? 0;
    final preview = data['message_preview'] as String? ?? '';

    // Find the row — prefer position match (daemon guarantees same
    // position on replace), then fall back to tail queued.
    int idx = list.indexWhere(
        (e) => e.status.isPending && e.position == position);
    if (idx < 0) {
      // Last-queued fallback.
      for (var i = list.length - 1; i >= 0; i--) {
        if (list[i].status.isPending) {
          idx = i;
          break;
        }
      }
    }
    if (idx < 0) return;

    list[idx] = list[idx].copyWith(
      id: newCid,
      correlationId: newCid,
      message: preview.isNotEmpty ? preview : list[idx].message,
      enqueuedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
      optimistic: false,
    );
    notifyListeners();
  }

  /// `message_started` — daemon picked the head of the queue and is
  /// now running the agent loop against it.
  ///
  /// Lookup strategy: match by correlation id first (the happy path),
  /// then fall back to "the first pending entry in position order"
  /// ONLY when the event comes from the queue drain path. Fast-path
  /// messages bypass the queue entirely, so the fallback must not
  /// kick in for them — otherwise a fast-path `message_started`
  /// would wrongly promote an unrelated queued message from another
  /// user action and hide it from the panel.
  void onMessageStarted(String sessionId, Map<String, dynamic> data) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final cid = data['correlation_id'] as String? ?? '';
    final fastPath = data['fast_path'] == true;

    int idx = -1;
    if (cid.isNotEmpty) {
      idx = list.indexWhere((e) => e.correlationId == cid);
    }
    if (idx < 0 && !fastPath) {
      // Fallback — head pending entry (lowest position).
      var bestPos = 1 << 30;
      for (var i = 0; i < list.length; i++) {
        final e = list[i];
        if (e.status.isPending && e.position < bestPos) {
          bestPos = e.position;
          idx = i;
        }
      }
    }
    if (idx < 0) return;
    list[idx] = list[idx].copyWith(
      position: 0,
      status: QueueEntryStatus.running,
      correlationId: cid.isNotEmpty ? cid : list[idx].correlationId,
      startedAt: DateTime.now().microsecondsSinceEpoch / 1e6,
      optimistic: false,
    );
    _reindexPending(list);
    notifyListeners();
  }

  /// `message_done` — turn ended normally. We keep the row around
  /// with status=completed for one notify tick so UIs can animate,
  /// then prune.
  void onMessageDone(String sessionId, Map<String, dynamic> data) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final cid = data['correlation_id'] as String? ?? '';
    if (cid.isEmpty) return;
    list.removeWhere((e) => e.correlationId == cid);
    _reindexPending(list);
    notifyListeners();
  }

  /// `message_cancelled` — the daemon confirms a DELETE /queue/{id}
  /// or equivalent teardown (e.g. cleared via POST /queue/clear).
  void onMessageCancelled(String sessionId, Map<String, dynamic> data) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final entryId = data['entry_id'] as String? ??
        data['correlation_id'] as String? ?? '';
    if (entryId.isEmpty) return;
    list.removeWhere((e) => e.id == entryId || e.correlationId == entryId);
    _reindexPending(list);
    notifyListeners();
  }

  /// `queue_cleared` — purge every queued (but not running) row.
  void onQueueCleared(String sessionId) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    list.removeWhere((e) => e.status.isPending);
    notifyListeners();
  }

  /// `abort` — the running turn was killed. By default the queue is
  /// **preserved**; the daemon auto-dispatches the next queued message
  /// and will emit `message_started` shortly. Only a hard abort (with
  /// `purge_queue=true`) clears pending rows too — that's signalled
  /// by a non-zero `queue_purged` count in the event payload.
  ///
  /// The cancelled running entry is flipped to [QueueEntryStatus.cancelled]
  /// first so its row visibly terminates before the next one starts.
  void onAbort(String sessionId, [Map<String, dynamic>? data]) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final purgedCount = (data?['queue_purged'] as num?)?.toInt() ?? 0;
    final preserved = data?['queue_preserved'] == true;

    // Soft abort → mark the running entry as cancelled, leave the
    // queued ones alone. The next `message_started` promotes the
    // head of the queue within ~200 ms.
    if (preserved || purgedCount == 0) {
      markRunningAsCancelled(sessionId);
      return;
    }

    // Hard abort → daemon has already purged the queue; mirror it.
    list.clear();
    notifyListeners();
  }

  /// Transition the running entry of [sessionId] to cancelled. Used
  /// by the soft-abort path and by callers that want to reflect an
  /// imperative cancel before the daemon's event echoes back.
  void markRunningAsCancelled(String sessionId) {
    final list = _entriesBySession[sessionId];
    if (list == null) return;
    final idx = list.indexWhere((e) => e.status.isRunning);
    if (idx < 0) return;
    // Drop the entry outright — keeping a terminal "cancelled" row
    // above the queue makes the list look stale. The user sees the
    // chat bubble instead (marked as cancelled by the assistant
    // stream handler on `abort`).
    list.removeAt(idx);
    _reindexPending(list);
    notifyListeners();
  }

  /// `queue_full` — the last enqueue attempt hit the per-session cap.
  /// UIs read [lastQueueFull] to show a transient toast and call
  /// [consumeQueueFull] once acknowledged.
  void onQueueFull(String sessionId, Map<String, dynamic> data) {
    _lastQueueFull = QueueFullEvent(
      sessionId: sessionId,
      depth: (data['depth'] as num?)?.toInt() ?? 0,
      max: (data['max'] as num?)?.toInt() ?? 0,
    );
    notifyListeners();
  }

  void consumeQueueFull() {
    if (_lastQueueFull == null) return;
    _lastQueueFull = null;
    // No notify — purely consumer-driven clear.
  }

  // ── Mutation helpers (wrapped daemon calls) ─────────────────────

  /// Cancel a queued entry. Optimistically removes it from the local
  /// view; the `message_cancelled` event will confirm.
  Future<bool> cancel(
      String appId, String sessionId, String entryId) async {
    // Optimistic remove so the UI reacts immediately.
    final list = _entriesBySession[sessionId];
    QueueEntry? removed;
    if (list != null) {
      final idx = list.indexWhere((e) => e.id == entryId);
      if (idx >= 0 && list[idx].status.isPending) {
        removed = list.removeAt(idx);
        _reindexPending(list);
        notifyListeners();
      }
    }
    final ok = await SessionService().cancelQueued(appId, sessionId, entryId);
    // Server may return false if the id already settled — we already
    // removed it locally, so just no-op. If the call errors hard and
    // we want the row back, re-insert.
    if (!ok && removed != null && list != null) {
      list.insert(removed.position.clamp(0, list.length), removed);
      notifyListeners();
    }
    return ok;
  }

  /// Clear every queued (not running) entry — both local and daemon.
  Future<bool> clear(String appId, String sessionId) async {
    final list = _entriesBySession[sessionId];
    List<QueueEntry>? snapshot;
    if (list != null && list.any((e) => e.status.isPending)) {
      snapshot = list.where((e) => e.status.isPending).toList();
      list.removeWhere((e) => e.status.isPending);
      notifyListeners();
    }
    final ok = await SessionService().clearQueue(appId, sessionId);
    if (!ok && snapshot != null && list != null) {
      list.addAll(snapshot);
      _resort(list);
      notifyListeners();
    }
    return ok;
  }

  // ── Internals ───────────────────────────────────────────────────

  void _resort(List<QueueEntry> list) {
    list.sort((a, b) {
      // Running entries first (position 0), then queued by position,
      // then terminal (shouldn't remain but defensive).
      final rankA = a.status.isRunning
          ? 0
          : a.status.isPending
              ? 1
              : 2;
      final rankB = b.status.isRunning
          ? 0
          : b.status.isPending
              ? 1
              : 2;
      if (rankA != rankB) return rankA.compareTo(rankB);
      return a.position.compareTo(b.position);
    });
  }

  /// Re-number queued rows so their `position` reflects the current
  /// FIFO order. Runs after any mutation that may have left gaps.
  void _reindexPending(List<QueueEntry> list) {
    var pos = 1;
    for (var i = 0; i < list.length; i++) {
      if (list[i].status.isPending) {
        if (list[i].position != pos) {
          list[i] = list[i].copyWith(position: pos);
        }
        pos++;
      }
    }
  }
}

/// Transient event surfaced by the UI as a toast when the user tries
/// to enqueue more messages than the daemon's configured cap.
@immutable
class QueueFullEvent {
  final String sessionId;
  final int depth;
  final int max;
  const QueueFullEvent({
    required this.sessionId,
    required this.depth,
    required this.max,
  });
}
