/// TTL-cached access to `GET /workspace/files/{path}/history`.
///
/// The brief explicitly calls out: "le client ne poll pas /history
/// agressivement (cache avec TTL 30s)". We honour that: a cold read
/// hits the daemon, subsequent reads within 30s return the cached
/// list. The "Approve" / "Reject" / "Writeback" UI flows explicitly
/// invalidate the cache for the target path so the user sees the
/// new revision immediately.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/file_revision.dart';
import 'api_client.dart';

class _CachedHistory {
  final List<FileRevision> revisions;
  final DateTime fetchedAt;
  const _CachedHistory(this.revisions, this.fetchedAt);
}

class FileHistoryService extends ChangeNotifier {
  FileHistoryService._internal();
  static final FileHistoryService _instance =
      FileHistoryService._internal();
  factory FileHistoryService() => _instance;

  static const Duration _ttl = Duration(seconds: 30);

  final Map<String, _CachedHistory> _cache = {};
  final Map<String, Future<List<FileRevision>?>> _inflight = {};

  String _key(String appId, String sessionId, String path) =>
      '$appId|$sessionId|$path';

  /// Sync cache read — returns null when empty or stale. The UI
  /// usually wants [ensure] which also kicks off a fetch.
  List<FileRevision>? cached(String appId, String sessionId, String path) {
    final hit = _cache[_key(appId, sessionId, path)];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.fetchedAt) > _ttl) return null;
    return hit.revisions;
  }

  /// Returns the cached list if fresh, otherwise fetches. Dedupes
  /// concurrent calls on the same key.
  Future<List<FileRevision>?> ensure(
    String appId,
    String sessionId,
    String path,
  ) async {
    final key = _key(appId, sessionId, path);
    final hit = _cache[key];
    if (hit != null &&
        DateTime.now().difference(hit.fetchedAt) <= _ttl) {
      return hit.revisions;
    }
    final existing = _inflight[key];
    if (existing != null) return existing;
    final future = _fetch(appId, sessionId, path, key);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<List<FileRevision>?> _fetch(
    String appId,
    String sessionId,
    String path,
    String key,
  ) async {
    final raw = await DigitornApiClient()
        .fetchFileHistory(appId, sessionId, path);
    if (raw == null) return null;
    final parsed = raw.map(FileRevision.fromJson).toList()
      ..sort((a, b) => b.revision.compareTo(a.revision));
    _cache[key] = _CachedHistory(parsed, DateTime.now());
    notifyListeners();
    return parsed;
  }

  /// Drop the cache entry for [path] — call this right after an
  /// approve / reject / writeback for that path so the next
  /// [ensure] re-hits the daemon and picks up the new revision.
  void invalidate(String appId, String sessionId, String path) {
    _cache.remove(_key(appId, sessionId, path));
  }

  void clearAll() {
    if (_cache.isEmpty) return;
    _cache.clear();
    notifyListeners();
  }
}
