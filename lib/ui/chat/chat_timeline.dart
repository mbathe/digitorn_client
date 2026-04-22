/// Single source of truth for chat bubble ordering.
///
/// The ONLY way to mutate the visible transcript. Direct mutation of
/// the underlying list is forbidden — the public surface is an
/// `upsert(bubble, at: sortKey)` + `removeById(id)` pair that maintains
/// the sort invariant by construction. Zero call sites can "forget to
/// re-sort" because the class refuses to hand out a mutable list.
///
/// Ordering rule (the only one):
///
///   sortKey = (seq, tick)
///             ^^^^^ from the daemon — strictly monotonic per session
///                   (§0 of the event spec "La règle d'or — l'ordre
///                   vient du daemon, pas du client").
///                   `null` for optimistic bubbles not yet echoed.
///                   `tick` is a tiebreaker assigned at insertion for
///                   bubbles that share the same seq or that share
///                   the same "tail-of-list" sentinel.
///
/// Optimistic bubbles (user just pressed Enter, daemon hasn't echoed
/// yet) take the sentinel `_tailBaseSeq` which is higher than any
/// possible real seq — they always render at the tail. On daemon
/// echo they are re-pinned to the real seq via
/// [rekey], which triggers one final resort.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/chat_message.dart';

/// Compound sort key. Two bubbles never share one thanks to the tick.
@immutable
class TimelineKey implements Comparable<TimelineKey> {
  /// Daemon-assigned monotonic seq. `null` for optimistic-tail bubbles.
  final int? seq;

  /// Insertion-order tiebreaker. Non-null for every bubble. Assigned
  /// by [ChatTimeline] at upsert time, never by callers.
  final int tick;

  const TimelineKey._(this.seq, this.tick);

  /// Greater than any possible real daemon seq — used to pin
  /// optimistic bubbles at the bottom of the list until the daemon
  /// echoes a real seq back. `2^53-1` so JSON round-trips stay exact
  /// across Dart/JS and so even the longest session never wraps.
  static const int tailBaseSeq = 0x1FFFFFFFFFFFFF;

  @override
  int compareTo(TimelineKey other) {
    final a = seq ?? tailBaseSeq;
    final b = other.seq ?? tailBaseSeq;
    if (a != b) return a.compareTo(b);
    return tick.compareTo(other.tick);
  }

  @override
  bool operator ==(Object other) =>
      other is TimelineKey && other.seq == seq && other.tick == tick;

  @override
  int get hashCode => Object.hash(seq, tick);

  @override
  String toString() => 'TimelineKey(seq: $seq, tick: $tick)';
}

/// Immutable list view returned by [ChatTimeline.messages]. Callers
/// get a read-only snapshot, never the internal list.
typedef TimelineView = UnmodifiableListView<ChatMessage>;

/// Ordered bubble transcript with strict invariants.
///
/// Call sites:
///   * [upsert] — insert or reposition a bubble at the given key.
///     Idempotent on [id]: a repeat call replaces the existing entry
///     and re-sorts.
///   * [rekey] — change an existing bubble's sort key (e.g. optimistic
///     bubble's seq is now known). Uses the id lookup.
///   * [removeById] — drop a bubble and its key.
///   * [clear] — blow the whole thing away (session switch).
///
/// Internally, a sorted index (`SplayTreeMap<TimelineKey, String>`)
/// keeps the order cheap; the bubbles live in a plain Map by id for
/// constant-time upsert. The two structures are kept in lockstep.
class ChatTimeline extends ChangeNotifier {
  ChatTimeline();

  // ── Storage ────────────────────────────────────────────────────────────────

  /// Bubbles keyed by their stable id.
  final Map<String, ChatMessage> _byId = {};

  /// Sort key for each bubble id. 1:1 with `_byId`.
  final Map<String, TimelineKey> _keyOf = {};

  /// Sorted (key → id) — the actual order of the view.
  final SplayTreeMap<TimelineKey, String> _order =
      SplayTreeMap<TimelineKey, String>();

  /// Monotonic tick counter. Every upsert (including rekey) burns one
  /// to guarantee uniqueness between calls within the same seq bucket.
  int _nextTick = 1;

  /// Event-id dedup — used by the reducer to ignore events already
  /// applied. Kept here so the timeline owns the only piece of state
  /// required to stay consistent across reconnects + backfills.
  final Set<String> _seenEventIds = <String>{};

  /// Cached materialised view of [_order] in sorted order. Invalidated
  /// by every mutation; rebuilt lazily on first read. Avoids N^2 cost
  /// when a `ListView.builder` calls [messages] once per item and each
  /// call would otherwise rebuild the whole list.
  List<ChatMessage>? _cachedMessages;

  // ── Public getters ─────────────────────────────────────────────────────────

  /// Read-only in-order view. Use in the widget tree.
  TimelineView get messages {
    final cached = _cachedMessages;
    if (cached != null) return UnmodifiableListView(cached);
    final built = _order.values.map((id) => _byId[id]!).toList(growable: false);
    _cachedMessages = built;
    return UnmodifiableListView(built);
  }

  /// Count of bubbles currently in the timeline.
  int get length => _byId.length;

  /// True when empty.
  bool get isEmpty => _byId.isEmpty;

  /// Highest real daemon seq currently rendered. Used as the
  /// `since_seq` watermark for reconnect backfill. `0` when no daemon
  /// bubble is present yet.
  int get lastSeq {
    var max = 0;
    for (final k in _keyOf.values) {
      final s = k.seq;
      if (s != null && s != TimelineKey.tailBaseSeq && s > max) max = s;
    }
    return max;
  }

  /// True if we've seen this event id before. Used by the reducer to
  /// short-circuit duplicate events (ring-buffer replay + Socket.IO
  /// fanout both can deliver the same event twice).
  bool hasSeenEvent(String eventId) => _seenEventIds.contains(eventId);

  /// Mark an event as applied. The reducer calls this after a
  /// successful apply to prevent double-application.
  void markEventSeen(String eventId) {
    if (eventId.isEmpty) return;
    _seenEventIds.add(eventId);
  }

  // ── Mutations ──────────────────────────────────────────────────────────────

  /// Insert or replace a bubble, pinning it at [seq] (or to the tail
  /// if [seq] is null). Returns the key actually assigned so callers
  /// can store it if they need to rekey later.
  ///
  /// If a bubble with the same id already exists, its old key is
  /// evicted from the order map before the new key goes in — zero
  /// duplicate rows, no chance of leaking a stale slot.
  TimelineKey upsert(ChatMessage msg, {required int? seq}) {
    final id = msg.id;
    // Evict old key if this id was already here.
    final oldKey = _keyOf[id];
    if (oldKey != null) _order.remove(oldKey);
    final key = TimelineKey._(seq, _nextTick++);
    _byId[id] = msg;
    _keyOf[id] = key;
    _order[key] = id;
    _cachedMessages = null;
    notifyListeners();
    return key;
  }

  /// Append a bubble at the tail (optimistic — no daemon seq yet).
  /// Sugar for `upsert(msg, seq: null)`.
  TimelineKey appendTail(ChatMessage msg) => upsert(msg, seq: null);

  /// Re-pin an existing bubble to a new daemon seq. Common path: the
  /// optimistic user bubble gets its canonical seq after the daemon
  /// echoes `user_message`. Lookup is by id. No-op if the id isn't
  /// tracked.
  TimelineKey? rekey(String id, {required int seq}) {
    if (!_byId.containsKey(id)) return null;
    final old = _keyOf[id]!;
    _order.remove(old);
    final key = TimelineKey._(seq, _nextTick++);
    _keyOf[id] = key;
    _order[key] = id;
    _cachedMessages = null;
    notifyListeners();
    return key;
  }

  /// Remove a bubble by id. Silent no-op if not present.
  void removeById(String id) {
    final key = _keyOf.remove(id);
    if (key == null) return;
    _byId.remove(id);
    _order.remove(key);
    _cachedMessages = null;
    notifyListeners();
  }

  /// Look up a bubble by id. Null when absent.
  ChatMessage? byId(String id) => _byId[id];

  /// Find the first bubble matching [predicate] in render order.
  /// Useful for "the streaming assistant bubble for this
  /// correlation_id" lookups.
  ChatMessage? firstWhere(bool Function(ChatMessage) predicate) {
    for (final id in _order.values) {
      final m = _byId[id]!;
      if (predicate(m)) return m;
    }
    return null;
  }

  /// Wipe the whole transcript (session switch). Also clears the
  /// event-id dedup set — a fresh session can legitimately see new
  /// events with ids that collided with the old session's.
  void clear() {
    _byId.clear();
    _keyOf.clear();
    _order.clear();
    _seenEventIds.clear();
    _nextTick = 1;
    _cachedMessages = null;
    notifyListeners();
  }

  /// Seed the timeline from a list of pre-ordered bubbles. Used by
  /// the `/history` cold-open path where `messages[]` already arrives
  /// denormalised. Each bubble gets the provided seq (or the index
  /// as a synthetic monotonic fallback if seq is null).
  ///
  /// Callers pass the list in the server's canonical order; this
  /// method preserves that order via the tick counter alone — no
  /// re-sort needed.
  void seed(List<({ChatMessage msg, int? seq})> entries) {
    for (final e in entries) {
      upsert(e.msg, seq: e.seq);
    }
  }

  // ── Debug ──────────────────────────────────────────────────────────────────

  /// Dump the current order for troubleshooting. Keys + ids, no content.
  String debugOrder() {
    final sb = StringBuffer('ChatTimeline(${_byId.length} bubbles):\n');
    _order.forEach((k, id) {
      sb.writeln('  $k → $id');
    });
    return sb.toString();
  }
}
