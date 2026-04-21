/// Lazy, auto-refreshing loader for a **single** workspace file.
///
/// The `code-snapshot` endpoint returns file metadata without
/// content. The editor loads the content on demand through
/// [load(path)]; subsequent writes by the agent bump
/// `WorkspaceFile.updated_at` and we silently re-fetch so the
/// editor stays in sync without a user refresh.
///
/// Cached per (sessionId, path, updatedAt). When the user switches
/// session the cache is wiped.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'session_service.dart';
import 'workspace_module.dart';

class FileContentService extends ChangeNotifier {
  static final FileContentService _i = FileContentService._();
  factory FileContentService() => _i;
  FileContentService._() {
    WorkspaceModule().addListener(_onModuleChanged);
  }

  /// Cache key = (sessionId, path, updatedAt stamp).
  final Map<String, WorkspaceFileContent> _cache = {};
  /// Inflight requests — prevents two editor opens racing to the
  /// same file.
  final Map<String, Future<WorkspaceFileContent?>> _inflight = {};
  /// Last observed `updatedAt` per path. When it grows we drop the
  /// cache entry and re-fetch transparently.
  final Map<String, double> _lastUpdatedAt = {};
  /// Last observed session id so we can wipe the cache on switch.
  String? _sessionId;

  String _key(String sessionId, String path) => '$sessionId::$path';

  /// Load [path] for the current active session. Returns the cached
  /// copy when available AND the file's `updatedAt` hasn't changed,
  /// else fetches from the daemon. Always includes baseline + pending
  /// unified diff so the editor can switch to diff mode cheaply.
  Future<WorkspaceFileContent?> load(String path) async {
    final session = SessionService().activeSession;
    if (session == null) return null;
    final sid = session.sessionId;
    if (_sessionId != sid) {
      _sessionId = sid;
      _cache.clear();
      _inflight.clear();
      _lastUpdatedAt.clear();
    }
    final key = _key(sid, path);
    final cached = _cache[key];
    final moduleFile = WorkspaceModule().files[path];
    final moduleUpdatedAt = moduleFile?.updatedAt ?? 0;
    final cachedUpdatedAt = cached?.file.updatedAt ?? 0;
    if (cached != null && cachedUpdatedAt >= moduleUpdatedAt) {
      return cached;
    }
    final existing = _inflight[key];
    if (existing != null) return existing;

    debugPrint('FileContentService.load — GET $path (app=${session.appId}, '
        'sid=$sid)');
    final future = DigitornApiClient()
        .fetchFileContent(session.appId, sid, path, includeBaseline: true)
        .then((res) {
      _inflight.remove(key);
      if (res != null) {
        debugPrint('FileContentService.load — HTTP OK $path, '
            'content=${res.file.content.length}B');
        _cache[key] = res;
        _lastUpdatedAt[path] = res.file.updatedAt ?? 0;
        notifyListeners();
        return res;
      }
      debugPrint('FileContentService.load — HTTP returned null for $path, '
          'trying WorkspaceModule fallback');
      // Fallback — apps that only carry the `filesystem` module
      // (fs-tester, prod-coding-assistant, sec-*, …) reject this
      // route with a **400**:
      //   {"success":false,"error":"App has no preview module",
      //    "status_code":400}
      // (scout-confirmed: the `/workspace/files/{path}` endpoint is
      // served by the daemon's preview module, not the filesystem
      // one). Those apps still land files on disk AND our
      // `PreviewStore.ingestToolCall` bridges the tool_call result
      // into `WorkspaceModule`, so we can serve the content from
      // there when the HTTP round-trip fails. Without this fallback
      // the editor shows "Could not load file content" on every
      // click, which is exactly the bug the user reported.
      final local = WorkspaceModule().files[path];
      if (local != null) {
        debugPrint('FileContentService.load — fallback for $path, '
            'local content=${local.content.length}B');
        final wrapped = WorkspaceFileContent(
          path: path,
          file: local,
          baseline: '',
          unifiedDiffPending: '',
        );
        _cache[key] = wrapped;
        _lastUpdatedAt[path] = local.updatedAt ?? 0;
        notifyListeners();
        return wrapped;
      }
      debugPrint('FileContentService.load — NO SOURCE for $path '
          '(HTTP null + WorkspaceModule miss)');
      return null;
    });
    _inflight[key] = future;
    return future;
  }

  /// Purge the cached copy for [path] — used after approve/reject
  /// so the next open goes to the daemon for the fresh baseline.
  void invalidate(String path) {
    final sid = _sessionId;
    if (sid == null) return;
    _cache.remove(_key(sid, path));
    _lastUpdatedAt.remove(path);
    notifyListeners();
  }

  /// Wipe everything — session switch, logout.
  void reset() {
    _cache.clear();
    _inflight.clear();
    _lastUpdatedAt.clear();
    _sessionId = null;
    notifyListeners();
  }

  void _onModuleChanged() {
    // For every cached file whose module counterpart has a newer
    // updatedAt than what we stored, drop the cache entry so the
    // next `load()` re-fetches. We don't auto-fetch — only the
    // editor currently showing the file needs a refresh, and it
    // will call `load()` itself when the panel listens to us.
    final module = WorkspaceModule();
    final sid = _sessionId;
    if (sid == null) return;
    var changed = false;
    for (final entry in _lastUpdatedAt.entries.toList()) {
      final path = entry.key;
      final ours = entry.value;
      final theirs = module.files[path]?.updatedAt ?? 0;
      if (theirs > ours) {
        _cache.remove(_key(sid, path));
        _lastUpdatedAt.remove(path);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    WorkspaceModule().removeListener(_onModuleChanged);
    super.dispose();
  }
}
