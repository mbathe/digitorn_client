import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../models/chat_message.dart';
import '../models/app_manifest.dart';
import '../models/app_summary.dart';
import 'auth_service.dart';
import 'workspace_module.dart' show WorkspaceFile;

/// Result of a single-file fetch from `/workspace/files/{path}`.
/// Carries the full [WorkspaceFile] plus — when
/// `include_baseline=true` — the last approved content and the
/// unified diff against it.
class WorkspaceFileContent {
  final String path;
  final WorkspaceFile file;
  /// Content of the last approved version, or empty when the file
  /// has never been approved.
  final String baseline;
  final String unifiedDiffPending;

  const WorkspaceFileContent({
    required this.path,
    required this.file,
    this.baseline = '',
    this.unifiedDiffPending = '',
  });

  factory WorkspaceFileContent.fromJson(Map<String, dynamic> json) {
    final path = (json['path'] as String?) ?? '';
    final payload = (json['payload'] is Map)
        ? (json['payload'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    return WorkspaceFileContent(
      path: path,
      file: WorkspaceFile.fromJson(path, payload),
      baseline: (json['baseline'] as String?) ?? '',
      unifiedDiffPending:
          (json['unified_diff_pending'] as String?) ?? '',
    );
  }
}

/// Result of `POST /workspace/commit`. Carries either the success
/// payload (`commit_sha`, `files_committed`, `pushed`, …) or an
/// error string surfaced from the daemon's 400 response. Transport
/// failures return null from the call — no outcome at all.
class CommitOutcome {
  final bool ok;
  final String? error;
  final Map<String, dynamic> data;

  const CommitOutcome._({
    required this.ok,
    this.error,
    this.data = const {},
  });

  factory CommitOutcome.success(Map<String, dynamic> data) =>
      CommitOutcome._(ok: true, data: data);

  factory CommitOutcome.error(String error) =>
      CommitOutcome._(ok: false, error: error);

  String? get commitSha => data['commit_sha'] as String?;
  String? get branch => data['branch'] as String?;
  List<String> get filesCommitted {
    final raw = data['files_committed'];
    if (raw is! List) return const [];
    return raw.whereType<String>().toList();
  }
  bool get pushed => data['pushed'] == true;
  String? get commitStdout => data['commit_stdout'] as String?;
}

/// Portable envelope persisted by the daemon for every session's
/// workspace. Round-trips through export → save-a-copy → import.
class WorkspaceSnapshotEnvelope {
  /// Always `"digitorn.workspace.snapshot"`.
  final String format;
  final int version;
  final String appId;
  final String sourceSessionId;
  final DateTime? exportedAt;
  final Map<String, dynamic> state;
  /// Nested: channel → id → payload.
  final Map<String, Map<String, dynamic>> resources;
  final int seq;

  const WorkspaceSnapshotEnvelope({
    this.format = 'digitorn.workspace.snapshot',
    this.version = 1,
    required this.appId,
    required this.sourceSessionId,
    this.exportedAt,
    this.state = const {},
    this.resources = const {},
    this.seq = 0,
  });

  factory WorkspaceSnapshotEnvelope.fromJson(Map<String, dynamic> json) {
    final rawResources = json['resources'];
    final resources = <String, Map<String, dynamic>>{};
    if (rawResources is Map) {
      for (final entry in rawResources.entries) {
        final v = entry.value;
        if (v is Map) {
          resources[entry.key.toString()] =
              Map<String, dynamic>.from(v);
        }
      }
    }
    DateTime? ts;
    final rawTs = json['exported_at'];
    if (rawTs is String) ts = DateTime.tryParse(rawTs);
    return WorkspaceSnapshotEnvelope(
      format:
          (json['format'] ?? 'digitorn.workspace.snapshot') as String,
      version: (json['version'] as num?)?.toInt() ?? 1,
      appId: (json['app_id'] ?? '') as String,
      sourceSessionId: (json['source_session_id'] ?? '') as String,
      exportedAt: ts,
      state: (json['state'] as Map?)?.cast<String, dynamic>() ??
          const {},
      resources: resources,
      seq: (json['seq'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'format': format,
        'version': version,
        'app_id': appId,
        'source_session_id': sourceSessionId,
        'exported_at':
            (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
        'state': state,
        'resources': resources,
        'seq': seq,
      };

  /// How many files across every channel — for toasts like "N files
  /// copied".
  int get totalResources =>
      resources.values.fold(0, (n, channel) => n + channel.length);
}

/// Result of a fork call — the daemon answers with the new session
/// id (fresh uuid unless the caller pinned one) and bookkeeping
/// we surface in the toast.
class WorkspaceForkResult {
  final String sessionId;
  final String sourceSessionId;
  final int files;
  final int seq;

  const WorkspaceForkResult({
    required this.sessionId,
    required this.sourceSessionId,
    this.files = 0,
    this.seq = 0,
  });

  factory WorkspaceForkResult.fromJson(Map<String, dynamic> json) =>
      WorkspaceForkResult(
        sessionId: (json['session_id'] ?? '') as String,
        sourceSessionId: (json['source_session_id'] ?? '') as String,
        files: (json['files'] as num?)?.toInt() ?? 0,
        seq: (json['seq'] as num?)?.toInt() ?? 0,
      );
}

/// Result of a server-side transcription.
class TranscriptionResult {
  final String text;
  final String? language;
  final int? durationMs;
  final double? confidence;
  const TranscriptionResult({
    required this.text,
    this.language,
    this.durationMs,
    this.confidence,
  });

  factory TranscriptionResult.fromJson(Map<String, dynamic> json) =>
      TranscriptionResult(
        text: (json['text'] ?? json['transcript'] ?? '') as String,
        language: json['language'] as String?,
        durationMs: (json['duration_ms'] as num?)?.toInt() ??
            ((json['duration'] as num?)?.toDouble() != null
                ? ((json['duration'] as num).toDouble() * 1000).round()
                : null),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );

  bool get isEmpty => text.trim().isEmpty;
}

/// Result envelope for a single LSP RPC call — unified across
/// success, daemon-reported timeout, and transport errors so the
/// caller doesn't juggle try/catch + status codes + error keys.
///
/// The `result` field is the raw LSP payload as-delivered by the
/// language server (no reshape), typed `dynamic` because each method
/// has a different shape per the LSP spec.
class LspRequestResult {
  final bool success;
  final bool cancelled;
  final String? server;
  final String? method;
  final dynamic result;
  final String? error;
  /// Echo of the `request_id` the daemon used. On successful calls
  /// this is what the caller must pass to `/lsp/cancel` to abort it.
  final String? requestId;
  const LspRequestResult._({
    required this.success,
    this.cancelled = false,
    this.server,
    this.method,
    this.result,
    this.error,
    this.requestId,
  });
  factory LspRequestResult.ok({
    String? server,
    String? method,
    dynamic result,
    String? requestId,
  }) =>
      LspRequestResult._(
        success: true,
        server: server,
        method: method,
        result: result,
        requestId: requestId,
      );
  factory LspRequestResult.errored(String message) =>
      LspRequestResult._(success: false, error: message);
  /// Client-side cancellation (Dio CancelToken fired). Treated
  /// separately so callers can distinguish "daemon failed" from
  /// "we walked away" — useful for telemetry and for deciding
  /// whether to log.
  factory LspRequestResult.cancelled() => const LspRequestResult._(
        success: false,
        cancelled: true,
        error: 'cancelled',
      );

  bool get hasResult => success && result != null;
}

class DigitornApiClient {
  static final DigitornApiClient _instance = DigitornApiClient._internal();
  factory DigitornApiClient() => _instance;

  DigitornApiClient._internal();

  late Dio _dio = _buildDio('http://127.0.0.1:8000');

  /// Shared Dio for the whole session-scoped daemon API. Other
  /// services (SessionActionsService, AppLifecycleService, …) reuse
  /// this instance so they always hit the same baseUrl the user
  /// configured, and share the auth-refresh interceptor.
  Dio get dio => _dio;

  String appId = "code-assistant";
  String sessionId = "default-session";

  Dio _buildDio(String baseUrl) => Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(hours: 1),
      ))..interceptors.add(AuthService().authInterceptor);

  // ─── Auth ─────────────────────────────────────────────────────────────────

  void updateBaseUrl(String baseUrl, {String? token}) {
    // `token` is accepted for backwards compatibility but ignored —
    // auth is injected by AuthService's Dio interceptor on every call.
    _dio = _buildDio(baseUrl);
  }

  // ─── Workspace IDE endpoints ──────────────────────────────────────────────
  //
  // Three lightweight endpoints + three action endpoints that together
  // implement the Lovable-style code editor experience:
  //
  //   GET  .../workspace/preview-snapshot  → preview pane payload
  //   GET  .../workspace/code-snapshot     → file tree (NO content)
  //   GET  .../workspace/files/{path}      → single file + baseline
  //   POST .../workspace/files/approve     → baseline = current
  //   POST .../workspace/files/reject      → content ← baseline (or delete)
  //   POST .../workspace/git-status        → refresh git_status on every file
  //
  // All return `null` (or false) on failure so the UI can fall back
  // gracefully without a thrown exception derailing the caller.

  Future<Map<String, dynamic>?> fetchPreviewSnapshot(
    String appId,
    String sessionId,
  ) async {
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/sessions/$sessionId/workspace/preview-snapshot',
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      return (data['data'] ?? data).cast<String, dynamic>();
    } catch (e) {
      debugPrint('fetchPreviewSnapshot error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> fetchCodeSnapshot(
    String appId,
    String sessionId,
  ) async {
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/sessions/$sessionId/workspace/code-snapshot',
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      return (data['data'] ?? data).cast<String, dynamic>();
    } catch (e) {
      debugPrint('fetchCodeSnapshot error: $e');
      return null;
    }
  }

  /// Fetch the session's workspace metadata — the struct that drives
  /// canvas routing (`render_mode`, `entry_file`, `title`, `workspace`
  /// path). Scout-confirmed on `digitorn-builder`:
  ///
  ///   `GET /api/apps/{appId}/sessions/{sid}/workspace`
  ///   → `{ "render_mode": "builder", "entry_file": "app.yaml",
  ///         "title": "Digitorn App Builder",
  ///         "workspace": "C:\\…\\digitorn-bridge" }`
  ///
  /// The daemon does NOT ship this via `preview:state_changed` — the
  /// client has to fetch it explicitly on session load. Returns null
  /// on any failure (the UI falls back to `render_mode=code`).
  Future<Map<String, dynamic>?> fetchWorkspaceMeta(
    String appId,
    String sessionId,
  ) async {
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/sessions/$sessionId/workspace',
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      return (data['data'] ?? data).cast<String, dynamic>();
    } catch (e) {
      debugPrint('fetchWorkspaceMeta error: $e');
      return null;
    }
  }

  /// Load a single file's content, optionally with its last-approved
  /// baseline + the pending unified diff. Called lazily when the
  /// user clicks a file in the explorer.
  Future<WorkspaceFileContent?> fetchFileContent(
    String appId,
    String sessionId,
    String path, {
    bool includeBaseline = false,
  }) async {
    try {
      final uri = '/api/apps/$appId/sessions/$sessionId/workspace/files/'
          '${Uri.encodeComponent(path)}'
          '${includeBaseline ? '?include_baseline=true' : ''}';
      final resp = await _dio.get(
        uri,
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode == 404) return null;
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      final root = (data['data'] ?? data) as Map;
      return WorkspaceFileContent.fromJson(root.cast<String, dynamic>());
    } catch (e) {
      debugPrint('fetchFileContent error: $e');
      return null;
    }
  }

  Future<bool> approveFile(
    String appId,
    String sessionId,
    String path,
  ) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/files/approve',
        data: {'path': path},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      return resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['success'] == true;
    } catch (e) {
      debugPrint('approveFile error: $e');
      return false;
    }
  }

  Future<bool> rejectFile(
    String appId,
    String sessionId,
    String path,
  ) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/files/reject',
        data: {'path': path},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      return resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['success'] == true;
    } catch (e) {
      debugPrint('rejectFile error: $e');
      return false;
    }
  }

  /// POST /workspace/files/approve-hunks — stage only the hunks named
  /// by hash (12-char sha256) or index (int). Returns the daemon's
  /// response on success, null on failure. Scout-verified contract:
  /// ```
  /// {
  ///   "path": "...",
  ///   "approved_hunks": [{"index": 0, "hash": "2ec6cce5cc4e"}, …],
  ///   "remaining_hunks": [],
  ///   "validation": "approved" | "pending"
  /// }
  /// ```
  Future<Map<String, dynamic>?> approveFileHunks(
    String appId,
    String sessionId,
    String path,
    List<Object> hunks, // mix of String hash or int index
  ) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/files/approve-hunks',
        data: {'path': path, 'hunks': hunks},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      if (data['success'] != true) return null;
      return (data['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('approveFileHunks error: $e');
      return null;
    }
  }

  /// POST /workspace/files/reject-hunks — revert only the hunks named
  /// by hash or index. Returns `{path, reverted_hunks:[{index,hash}]}`
  /// on success, null on failure. Daemon also emits a
  /// `resource_patched` event with the new content — **do not**
  /// update UI optimistically; let the event land.
  Future<Map<String, dynamic>?> rejectFileHunks(
    String appId,
    String sessionId,
    String path,
    List<Object> hunks,
  ) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/files/reject-hunks',
        data: {'path': path, 'hunks': hunks},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      if (data['success'] != true) return null;
      return (data['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('rejectFileHunks error: $e');
      return null;
    }
  }

  /// PUT /workspace/files/{path} — writeback path for user edits
  /// (Monaco onBlur, drag-drop, conflict resolution, external seed).
  /// `source: 'user'` flows back through the resource_set event so
  /// the UI can tag "edited by you". `autoApprove: true` bypasses
  /// the approve step — used only for conflict-resolution flows.
  Future<bool> writebackFile(
    String appId,
    String sessionId,
    String path,
    String content, {
    bool autoApprove = false,
    String source = 'user',
  }) async {
    try {
      final uri = '/api/apps/$appId/sessions/$sessionId/workspace/files/'
          '${Uri.encodeComponent(path)}';
      final resp = await _dio.put(
        uri,
        data: {
          'content': content,
          'auto_approve': autoApprove,
          'source': source,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      return resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['success'] == true;
    } catch (e) {
      debugPrint('writebackFile error: $e');
      return false;
    }
  }

  /// POST /workspace/commit — ship approved changes to the underlying
  /// git repo. Returns the full commit record on success:
  /// `{commit_sha, branch, files_committed, pushed, commit_stdout}`.
  /// Returns an error record `{error: String, data?: Map}` on 400
  /// responses (e.g. "workspace is not a git repo", "no files to
  /// commit") so the UI can surface a meaningful toast. Returns null
  /// on transport failure.
  Future<CommitOutcome?> commitSession(
    String appId,
    String sessionId, {
    required String message,
    List<String>? files,
    bool push = false,
  }) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/commit',
        data: {
          'message': message,
          'files': files,
          'push': push,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.data is! Map) return null;
      final body = resp.data as Map;
      if (resp.statusCode == 200 && body['success'] == true) {
        return CommitOutcome.success(
          (body['data'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
      }
      final detail = body['detail'];
      if (detail is Map) {
        return CommitOutcome.error(
          detail['error']?.toString() ?? 'commit failed',
        );
      }
      return CommitOutcome.error('commit failed');
    } catch (e) {
      debugPrint('commitSession error: $e');
      return null;
    }
  }

  /// GET /workspace/files/{path}/history — approval timeline for a
  /// single file. Returns the raw `{revisions: [...]}` list; callers
  /// cache with a short TTL (≥ 30s) per the daemon contract to avoid
  /// over-polling.
  Future<List<Map<String, dynamic>>?> fetchFileHistory(
    String appId,
    String sessionId,
    String path,
  ) async {
    try {
      final uri = '/api/apps/$appId/sessions/$sessionId/workspace/files/'
          '${Uri.encodeComponent(path)}/history';
      final resp = await _dio.get(
        uri,
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = (resp.data['data'] ?? resp.data) as Map;
      final revs = data['revisions'];
      if (revs is! List) return null;
      return revs
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('fetchFileHistory error: $e');
      return null;
    }
  }

  /// GET /api/apps/{app_id}/ui-config — UI-safe config (allow-list).
  /// Scout-verified shape:
  /// ```
  /// { "app_id": "...",
  ///   "workspace_config": { "render_mode"?, "entry_file"?,
  ///                         "title"?, "sync_to_disk"?, "lint"?,
  ///                         "auto_approve"? },
  ///   "preview_config":   { "enabled"?, "port"? } }
  /// ```
  /// No prompts / api_keys / secrets leak — the daemon strips them
  /// via the `_WS_ALLOW` / `_PREVIEW_ALLOW` whitelists.
  Future<Map<String, dynamic>?> fetchAppUiConfig(String appId) async {
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/ui-config',
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final root = (resp.data['data'] ?? resp.data) as Map;
      return root.cast<String, dynamic>();
    } catch (e) {
      debugPrint('fetchAppUiConfig error: $e');
      return null;
    }
  }

  /// POST /workspace/git-status — asks the daemon to run
  /// `git status --porcelain` on the workspace dir and push a
  /// `resource_patched` per file with the updated `git_status`.
  Future<bool> refreshWorkspaceGitStatus(
    String appId,
    String sessionId,
  ) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/git-status',
        data: const {},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      return resp.statusCode == 200 &&
          resp.data is Map &&
          resp.data['success'] == true;
    } catch (e) {
      debugPrint('refreshWorkspaceGitStatus error: $e');
      return false;
    }
  }

  // ─── LSP RPC (Phase 2) ────────────────────────────────────────────────────
  //
  // POST /api/apps/{app_id}/sessions/{sid}/lsp/request is the single
  // entrypoint for every LSP method (hover, definition, references,
  // completion, rename, etc). The daemon routes the request to the
  // appropriate language server based on the file extension. The
  // payload is raw LSP — the client does NOT reshape anything. The
  // daemon auto-fills `textDocument.uri` from [path] if omitted and
  // runs `didOpen` before the call.
  //
  // Response shape:
  //   200  {success: true,  data: {server, method, result}}      — happy path
  //   200  {success: true,  data: {timeout: true}, error: "..."} — server returned None / unsupported
  //   400  {success: false, error: "No LSP server registered..."} — unknown extension
  //   404  {success: false, error: "App has no LSP module"}       — module missing
  //
  // All errors bubble up as [LspRequestResult.errored] so the caller
  // can decide whether to show a UI toast or silently fall back.
  Future<LspRequestResult> lspRequest(
    String appId,
    String sessionId, {
    required String path,
    required String method,
    required Map<String, dynamic> params,
    int? timeoutSeconds,
    /// Opaque id echoed by the daemon so the client can `/lsp/cancel`
    /// this specific request later. When omitted the daemon picks one
    /// and returns it in the response envelope, but we won't know it
    /// on the send side so explicit is better for cancellation.
    String? requestId,
    /// Ask the daemon to cancel any in-flight request for the same
    /// `(session, path, method)` triple. Default true matches daemon
    /// default. Set to false for user-initiated calls where stale
    /// results still matter (references / rename).
    bool supersedePrevious = true,
    /// Tie the HTTP call to a Dio [CancelToken] — when
    /// [CancelToken.cancel] fires the socket drops, the daemon notices
    /// the disconnect (≤100 ms) and cancels the underlying LSP task.
    CancelToken? cancelToken,
  }) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/lsp/request',
        data: {
          'path': path,
          'method': method,
          'params': params,
          'timeout_seconds': ?timeoutSeconds,
          'request_id': ?requestId,
          // Only send when diverging from the daemon default — keeps
          // payloads quiet on the happy path.
          if (!supersedePrevious) 'supersede_previous': false,
        },
        cancelToken: cancelToken,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      final data = resp.data;
      if (data is! Map) {
        return LspRequestResult.errored(
            'Unexpected response shape (HTTP ${resp.statusCode})');
      }
      if (data['success'] != true) {
        return LspRequestResult.errored(
            (data['error'] as String?) ?? 'LSP request failed');
      }
      final inner = data['data'];
      if (inner is! Map) {
        return LspRequestResult.errored('Missing data envelope');
      }
      if (inner['timeout'] == true) {
        return LspRequestResult.errored(
            (data['error'] as String?) ?? 'LSP server timed out');
      }
      return LspRequestResult.ok(
        server: inner['server'] as String?,
        method: (inner['method'] as String?) ?? method,
        result: inner['result'],
        requestId: (inner['request_id'] as String?) ?? requestId,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // Local cancellation — caller (usually Monaco) already moved
        // on. Don't log: this is the happy path for supersession.
        return LspRequestResult.cancelled();
      }
      debugPrint('lspRequest (${e.type}) error: ${e.message}');
      return LspRequestResult.errored(e.message ?? 'network error');
    } catch (e) {
      debugPrint('lspRequest error: $e');
      return LspRequestResult.errored('$e');
    }
  }

  /// POST /api/apps/{app_id}/sessions/{sid}/lsp/cancel — best-effort
  /// abort for a specific in-flight [requestId]. The daemon returns
  /// 2xx with `{success: false, error: "request not found"}` when the
  /// id is unknown (already completed / never existed), so we treat
  /// that as a no-op and still return true to the caller. Exposes
  /// false only on transport / auth failures.
  Future<bool> lspCancel(
    String appId,
    String sessionId,
    String requestId,
  ) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/lsp/cancel',
        data: {'request_id': requestId},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      // Any 2xx is success from the client's perspective — a "not
      // found" just means the task already settled.
      return resp.statusCode != null &&
          resp.statusCode! >= 200 &&
          resp.statusCode! < 300;
    } on DioException catch (e) {
      debugPrint('lspCancel error: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('lspCancel error: $e');
      return false;
    }
  }

  // ─── Workspace snapshots ──────────────────────────────────────────────────
  //
  // The daemon persists the full workspace state (state + resources)
  // of every session and exposes three endpoints:
  //
  //   GET  .../workspace/export → `WorkspaceSnapshotEnvelope`
  //   POST .../workspace/import → replace or merge a foreign snapshot
  //   POST .../workspace/fork   → copy this session's workspace into
  //                                a new session
  //
  // The client wraps them as typed methods so the UI doesn't have to
  // deal with JSON shapes.

  /// GET /api/apps/{app_id}/sessions/{sid}/workspace/export —
  /// returns the portable envelope (format, version, state,
  /// resources, seq). Returns null on any failure so the UI can
  /// toast gracefully.
  Future<WorkspaceSnapshotEnvelope?> exportWorkspaceSnapshot(
    String appId,
    String sessionId,
  ) async {
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/sessions/$sessionId/workspace/export',
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      final data = resp.data as Map;
      final payload = (data['data'] ?? data) as Map;
      return WorkspaceSnapshotEnvelope.fromJson(
          payload.cast<String, dynamic>());
    } on DioException catch (e) {
      debugPrint('exportWorkspaceSnapshot error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('exportWorkspaceSnapshot error: $e');
      return null;
    }
  }

  /// POST /api/apps/{app_id}/sessions/{sid}/workspace/import —
  /// pushes an envelope into the session. When [replace] is true the
  /// existing state is wiped first. Returns true on success.
  Future<bool> importWorkspaceSnapshot(
    String appId,
    String sessionId, {
    required WorkspaceSnapshotEnvelope envelope,
    bool replace = true,
  }) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/import',
        data: {'snapshot': envelope.toJson(), 'replace': replace},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200) return false;
      return resp.data is Map && resp.data['success'] == true;
    } catch (e) {
      debugPrint('importWorkspaceSnapshot error: $e');
      return false;
    }
  }

  /// POST /api/apps/{app_id}/sessions/{sid}/workspace/fork —
  /// creates a new session whose workspace mirrors this one. The
  /// daemon picks a fresh `session_id` unless [targetSessionId] is
  /// provided. Returns the new session id + file count.
  Future<WorkspaceForkResult?> forkWorkspace(
    String appId,
    String sessionId, {
    String? targetSessionId,
    String? title,
  }) async {
    try {
      final resp = await _dio.post(
        '/api/apps/$appId/sessions/$sessionId/workspace/fork',
        data: {
          'target_session_id': ?targetSessionId,
          if (title != null && title.isNotEmpty) 'title': title,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode != 200 || resp.data is! Map) return null;
      if (resp.data['success'] != true) return null;
      final data = (resp.data['data'] ?? resp.data) as Map;
      return WorkspaceForkResult.fromJson(data.cast<String, dynamic>());
    } catch (e) {
      debugPrint('forkWorkspace error: $e');
      return null;
    }
  }

  // ─── App manifest (YAML) ──────────────────────────────────────────────────
  //
  // The full app spec — `app.yaml` compiled server-side. Drives every
  // adaptive piece of the chat UI. Client prefers the JSON endpoint
  // if the daemon exposes one (cheaper to parse) but also accepts
  // raw YAML, so a minimal daemon can just expose the file as-is.

  Future<AppManifest?> fetchAppManifest(String appId) async {
    // Try JSON first — if the daemon pre-flattens the YAML to JSON
    // we save a YAML parse on the client.
    try {
      final resp = await _dio.get(
        '/api/apps/$appId/manifest',
        options: Options(
          headers: {'Accept': 'application/json, application/yaml'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.statusCode == 404) return null;
      final data = resp.data;
      if (data is Map) {
        final payload = (data['data'] ?? data) as Map;
        return AppManifest.fromJson(payload.cast<String, dynamic>());
      }
      if (data is String && data.trim().isNotEmpty) {
        return AppManifest.fromYaml(data, fallbackAppId: appId);
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      debugPrint('fetchAppManifest dio error: ${e.message}');
    } catch (e) {
      debugPrint('fetchAppManifest error: $e');
    }
    return null;
  }

  // ─── Voice transcription ──────────────────────────────────────────────────
  //
  // Client-side STT (speech_to_text) covers Android/iOS/Web/Windows
  // natively. Linux — and any time the user prefers higher-quality,
  // unified transcription — relies on this endpoint: the daemon
  // transcribes the uploaded audio (typically via Whisper) and
  // returns the text. The endpoint is optional from the client's
  // point of view: a 404 (or any non-2xx) is handled gracefully
  // upstream, and the audio is attached to the next message as a
  // fallback.

  /// Upload an audio file and get back the transcription. Returns
  /// null if the endpoint is unreachable / not implemented — caller
  /// falls back to attaching the raw audio.
  Future<TranscriptionResult?> transcribeAudio(
    String audioPath, {
    String? language,
    String? appId,
  }) async {
    try {
      final file = File(audioPath);
      if (!await file.exists()) {
        debugPrint('transcribeAudio: file missing $audioPath');
        return null;
      }
      final form = FormData.fromMap({
        'audio': await MultipartFile.fromFile(audioPath),
        'language': ?language,
        'app_id': ?appId,
      });
      final response = await _dio.post(
        '/api/transcribe',
        data: form,
        options: Options(
          // Transcription can take a while on CPU-only daemons; give
          // Whisper room to breathe before we give up.
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(minutes: 2),
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (response.statusCode == 200 && response.data is Map) {
        final data = response.data as Map;
        final payload = (data['data'] ?? data) as Map<String, dynamic>;
        final result = TranscriptionResult.fromJson(payload);
        if (result.isEmpty) return null;
        return result;
      }
      debugPrint('transcribeAudio ← ${response.statusCode} ${response.data}');
      return null;
    } on DioException catch (e) {
      // 404 / 501 → endpoint not implemented yet → fall back silently.
      final code = e.response?.statusCode;
      if (code == 404 || code == 501) return null;
      debugPrint('transcribeAudio error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('transcribeAudio error: $e');
      return null;
    }
  }

  // ─── Apps ─────────────────────────────────────────────────────────────────

  Future<List<AppSummary>> fetchApps() async {
    try {
      debugPrint('fetchApps → GET ${_dio.options.baseUrl}/api/apps');
      final response = await _dio.get('/api/apps', options: Options(
        headers: {'Accept': 'application/json'},
        validateStatus: (s) => s != null && s < 500 && s != 401,
      ));
      debugPrint('fetchApps ← ${response.statusCode} data=${response.data}');
      if (response.data != null && response.data['success'] == true) {
        final List list = response.data['data'] ?? [];
        debugPrint('fetchApps: ${list.length} apps found');
        return list.map((json) => AppSummary.fromJson(json)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('fetchApps error: $e');
      return [];
    }
  }

  // ─── Event handler — invoked by ChatPanel on every Socket.IO event ────────
  //
  // Kept as a free-standing dispatcher so ChatPanel can reuse it for
  // both its own inline processing and the SessionService stream.

  /// Dispatches a single live stream event (token, thinking, tool_*,
  /// result, …) onto [msg]. Pass [envelopeTs] with the envelope's
  /// `ts` string (ISO-8601 UTC, Z-suffixed) so tool calls can
  /// record their daemon-observed start / end moments and expose
  /// `observedDuration` without needing any per-tool duration field
  /// in the result payload.
  void handleStreamEvent(
    String event,
    Map<String, dynamic> data,
    ChatMessage msg, {
    String? envelopeTs,
  }) {
    final envelopeTsParsed = envelopeTs != null && envelopeTs.isNotEmpty
        ? DateTime.tryParse(envelopeTs)
        : null;
    switch (event) {
      // ── Text tokens ──────────────────────────────────────────────────────
      case 'token':
      case 'out_token' when data.containsKey('delta'):
        final delta = data['delta'] as String? ?? '';
        if (delta.isNotEmpty) msg.appendText(delta);
        break;

      // ── Thinking ─────────────────────────────────────────────────────────
      case 'thinking_started':
        msg.setThinkingState(true);
        break;
      case 'thinking_delta':
        final delta = data['delta'] as String? ?? '';
        if (delta.isNotEmpty) msg.appendThinking(delta);
        break;
      case 'thinking':
        // batch — full thinking text at once
        final text = data['text'] as String? ?? '';
        if (text.isNotEmpty) msg.setThinkingText(text);
        break;
      case 'stream_done':
        msg.setThinkingState(false);
        break;

      // ── Tool calls ────────────────────────────────────────────────────────
      case 'tool_start':
        final id = data['id'] as String? ?? data['name'] as String? ?? 'tool';
        debugPrint('tool_start id=$id name=${data['name']}');
        final display = data['display'] as Map<String, dynamic>?;
        final visibleParamsRaw = display?['visible_params'];
        msg.addOrUpdateToolCall(ToolCall(
          id: id,
          name: data['name'] as String? ?? 'tool',
          label: display?['verb'] as String? ?? data['label'] as String? ?? '',
          detail: display?['detail'] as String? ?? data['detail'] as String? ?? '',
          detailParam: display?['detail_param'] as String? ??
              data['detail_param'] as String? ??
              '',
          icon: display?['icon'] as String? ?? 'tool',
          channel: display?['channel'] as String? ?? 'chat',
          category: display?['category'] as String? ?? 'action',
          group: display?['group'] as String? ?? '',
          hidden: display?['hidden'] as bool? ??
              data['silent'] as bool? ??
              false,
          visibleParams: visibleParamsRaw is List
              ? visibleParamsRaw.whereType<String>().toList()
              : null,
          params: Map<String, dynamic>.from(data['params'] ?? {}),
          status: 'started',
          startedAt: envelopeTsParsed,
        ));
        break;
      case 'tool_call':
        final id = data['id'] as String? ?? data['name'] as String? ?? 'tool';
        debugPrint('tool_call id=$id name=${data['name']}');
        final name = data['name'] as String? ?? 'tool';
        final success = data['success'];
        final errorStr = data['error'] as String? ?? '';
        final isFailed = success == false;
        final display = data['display'] as Map<String, dynamic>?;
        final result = data['result'];
        final md = data['metadata'];
        final metadata = md is Map
            ? Map<String, dynamic>.from(md)
            : (result is Map && result['metadata'] is Map
                ? Map<String, dynamic>.from(result['metadata'] as Map)
                : null);
        final unified = data['unified_diff'] as String?
            ?? (result is Map ? result['unified_diff'] as String? : null);
        final diffText = data['diff'] as String?
            ?? (result is Map ? result['diff'] as String? : null);
        final imgData = data['image_data'] as String?
            ?? (result is Map ? result['image_data'] as String? : null)
            ?? (metadata?['image_data'] as String?);
        final imgMime = data['image_mime'] as String?
            ?? (result is Map ? result['image_mime'] as String? : null)
            ?? (metadata?['image_mime'] as String?);
        final visibleParamsRaw = display?['visible_params'];
        msg.addOrUpdateToolCall(ToolCall(
          id: id,
          name: name,
          label: display?['verb'] as String? ?? data['label'] as String? ?? '',
          detail: display?['detail'] as String? ?? data['detail'] as String? ?? '',
          detailParam: display?['detail_param'] as String? ??
              data['detail_param'] as String? ??
              '',
          icon: display?['icon'] as String? ?? 'tool',
          channel: display?['channel'] as String? ?? 'chat',
          category: display?['category'] as String? ?? 'action',
          group: display?['group'] as String? ?? '',
          hidden: display?['hidden'] as bool? ??
              data['silent'] as bool? ??
              false,
          visibleParams: visibleParamsRaw is List
              ? visibleParamsRaw.whereType<String>().toList()
              : null,
          params: Map<String, dynamic>.from(data['params'] ?? {}),
          status: isFailed ? 'failed' : 'completed',
          result: result,
          error: errorStr.isNotEmpty ? errorStr : null,
          previousContent: data['previous_content'] as String?,
          newContent: data['new_content'] as String?,
          output: data['output'] as String?,
          metadata: metadata,
          diff: diffText,
          unifiedDiff: unified,
          imageData: imgData,
          imageMime: imgMime,
          completedAt: envelopeTsParsed,
        ));
        break;

      // ── Turn result ───────────────────────────────────────────────────────
      case 'result':
        msg.setStreamingState(false);
        msg.setThinkingState(false);
        // Persist token usage from result payload
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          msg.addTokens(
            out: usage['output_tokens'] as int? ?? 0,
            inT: usage['input_tokens'] as int? ?? 0,
          );
        }
        break;

      // ── Token counts ─────────────────────────────────────────────────────
      case 'out_token':
        final count = data['count'] as int? ?? 0;
        if (count > 0) msg.addTokens(out: count);
        break;
      case 'in_token':
        final count = data['count'] as int? ?? 0;
        if (count > 0) msg.addTokens(inT: count);
        break;

      // ── Status phase ───────────────────────────────────────────────────
      case 'status':
        // Handled by ChatPanel via onStatusPhase callback
        break;

      // ── Agent events ──────────────────────────────────────────────────────
      case 'agent_event':
        final agentId = data['agent_id'] as String? ?? '';
        if (agentId.isNotEmpty) {
          msg.addAgentEvent(AgentEventData(
            agentId: agentId,
            status: data['status'] as String? ?? 'unknown',
            specialist: data['specialist'] as String? ?? '',
            task: data['task'] as String? ?? '',
            duration: (data['duration_seconds'] as num?)?.toDouble() ?? 0,
            preview: data['preview'] as String? ?? '',
          ));
        }
        break;

      // ── Hook events ───────────────────────────────────────────────────────
      case 'hook':
        msg.addHookEvent(HookEventData(
          hookId: data['hook_id'] as String? ?? '',
          actionType: data['action_type'] as String? ?? '',
          phase: data['phase'] as String? ?? '',
          details: Map<String, dynamic>.from(data['details'] ?? {}),
        ));
        break;

      // ── Memory update — show as system info in tool pills ─────────────────
      case 'memory_update':
        final action = data['action'] as String? ?? 'memory';
        msg.addOrUpdateToolCall(ToolCall(
          id: 'memory_$action',
          name: 'memory.$action',
          params: {},
          status: 'completed',
          result: data['result'],
        ));
        break;

      // ── Approval request — handled by ChatPanel directly ──────────────────
      case 'approval_request':
        // Delegated to ChatPanel._handleSessionEvent
        break;

      case 'error':
        msg.appendText('\n\n**Error:** ${data['error'] ?? 'Unknown error'}');
        msg.setStreamingState(false);
        break;
    }
  }
}
