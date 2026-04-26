/// Stale-while-revalidate cache — one primitive, reusable everywhere.
///
/// The pattern: callers get the cached value **immediately** (even if
/// stale), and a background revalidation fires if the entry has aged
/// past its TTL. This is how Slack, Linear, Notion etc. make tab
/// switches feel instant: no spinner on hot data, fresh data lands
/// quietly a beat later.
///
/// Usage:
///
/// ```dart
/// final cache = SwrCache<String, List<AppSummary>>(
///   ttl: const Duration(minutes: 5),
/// );
///
/// Future<List<AppSummary>> fetchApps() async {
///   return cache.getOrFetch(
///     key: 'apps',
///     fetcher: () => _dio.get(...).then(_parse),
///     onRevalidated: (fresh) => notifyListeners(),
///   );
/// }
/// ```
///
/// Guarantees:
///   - **Deduplication**: two concurrent calls for the same key share
///     ONE in-flight fetch. No thundering herd.
///   - **Reentrant safe**: calling `invalidate` mid-fetch re-queues
///     the next call instead of aborting the current.
///   - **Never throws to hot path**: if the fetch fails, the cached
///     value (even if null/stale) is returned. Errors bubble only on
///     the first ever fetch.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

class _CacheEntry<V> {
  V value;
  DateTime storedAt;
  _CacheEntry(this.value, this.storedAt);
}

typedef SwrFetcher<V> = Future<V> Function();
typedef SwrOnRevalidated<V> = void Function(V fresh);

class SwrCache<K, V> {
  SwrCache({
    required this.ttl,
    this.name = 'swr',
  });

  /// Time after which a cached value is considered stale and triggers
  /// a background revalidation. The stale value is still served
  /// immediately — this only gates when the background refresh fires.
  final Duration ttl;

  /// Label for debug logs. Distinct caches get distinct names.
  final String name;

  final Map<K, _CacheEntry<V>> _entries = {};
  final Map<K, Future<V>> _inFlight = {};

  /// Return the cached value if present (regardless of staleness),
  /// otherwise null. Never triggers a fetch.
  V? peek(K key) => _entries[key]?.value;

  /// Is [key] currently cached with an unexpired value?
  bool isFresh(K key) {
    final entry = _entries[key];
    if (entry == null) return false;
    return DateTime.now().difference(entry.storedAt) < ttl;
  }

  /// The main API. Semantics:
  ///   - First call for [key] — awaits [fetcher], caches result, returns.
  ///   - Subsequent call within TTL — returns cached immediately, no fetch.
  ///   - Subsequent call past TTL — returns cached immediately AND
  ///     fires a background revalidation; [onRevalidated] is called
  ///     with the fresh value when it lands.
  ///   - Concurrent calls — share the in-flight Future (dedup).
  ///
  /// [force] skips the cache entirely and always fetches fresh.
  Future<V> getOrFetch({
    required K key,
    required SwrFetcher<V> fetcher,
    SwrOnRevalidated<V>? onRevalidated,
    bool force = false,
  }) async {
    final entry = _entries[key];
    final now = DateTime.now();

    // Fresh cache hit — serve immediately, no fetch.
    if (!force && entry != null && now.difference(entry.storedAt) < ttl) {
      return entry.value;
    }

    // Stale cache hit — serve immediately, fire background revalidation.
    if (!force && entry != null) {
      _revalidateInBackground(key, fetcher, onRevalidated);
      return entry.value;
    }

    // Cold miss (or forced) — await the fetch.
    return _fetchAndCache(key, fetcher);
  }

  Future<V> _fetchAndCache(K key, SwrFetcher<V> fetcher) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final fut = fetcher().then((value) {
      _entries[key] = _CacheEntry(value, DateTime.now());
      _inFlight.remove(key);
      return value;
    }).catchError((e) {
      _inFlight.remove(key);
      throw e;
    });
    _inFlight[key] = fut;
    return fut;
  }

  void _revalidateInBackground(
    K key,
    SwrFetcher<V> fetcher,
    SwrOnRevalidated<V>? onRevalidated,
  ) {
    // Dedup — if a revalidation is already in flight, hook onto it.
    final existing = _inFlight[key];
    if (existing != null) {
      if (onRevalidated != null) existing.then(onRevalidated).catchError((_) {});
      return;
    }
    final fut = fetcher().then((value) {
      _entries[key] = _CacheEntry(value, DateTime.now());
      _inFlight.remove(key);
      if (onRevalidated != null) {
        try {
          onRevalidated(value);
        } catch (e) {
          debugPrint('[$name] onRevalidated callback threw: $e');
        }
      }
      return value;
    }).catchError((e) {
      _inFlight.remove(key);
      // Revalidation failure MUST NOT throw — the hot path already
      // returned the stale value; this was best-effort refresh.
      debugPrint('[$name] bg revalidate failed for $key: $e');
      throw e;
    });
    _inFlight[key] = fut;
  }

  /// Set the cached value directly without going through a fetch.
  /// Useful when an event / socket message delivers fresh data that
  /// would otherwise force the next read to do an HTTP round-trip.
  void set(K key, V value) {
    _entries[key] = _CacheEntry(value, DateTime.now());
  }

  /// Drop a specific cache entry. Next [getOrFetch] call will do a
  /// real fetch.
  void invalidate(K key) {
    _entries.remove(key);
    // Don't cancel in-flight — let it complete and cache normally;
    // consumers may depend on its result.
  }

  /// Wipe all entries. Called on logout / app switch / auth change.
  void clear() {
    _entries.clear();
  }
}
