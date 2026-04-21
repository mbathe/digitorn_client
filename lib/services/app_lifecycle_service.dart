/// App-level lifecycle actions — deploy, validate, run, reload,
/// enable / disable, pipeline, deploy-status, errors, diagnostics.
/// These are the routes the Builder UI (and the app-settings drawer)
/// needs to drive a full create → validate → deploy → monitor
/// workflow without leaving the client.
///
/// Scout audit 2026-04-20: the following were unwired and are now
/// exposed through this service.
///
///   * POST   /api/apps/validate                  → [validateYaml]
///   * POST   /api/apps/deploy                    → [deployFromYamlPath]
///   * POST   /api/apps/deploy/upload             → [deployFromUpload]
///   * GET    /api/apps/{id}/deploy-status        → [deployStatus]
///   * POST   /api/apps/{id}/pipeline             → [runPipeline]
///   * POST   /api/apps/{id}/run                  → [runApp]
///   * POST   /api/apps/{id}/reload               → [reload]
///   * POST   /api/apps/{id}/disable              → [disable]
///   * POST   /api/apps/{id}/enable               → [enable]
///   * DELETE /api/apps/{id}                      → [deleteApp]
///   * GET    /api/apps/{id}/payload-schema       → [fetchPayloadSchema]
///   * GET    /api/apps/{id}/index                → [fetchAppIndex]
///   * GET    /api/apps/{id}/errors               → [fetchErrors]
///   * GET    /api/apps/{id}/diagnostics          → [fetchDiagnostics]
///   * GET    /api/apps/{id}/files                → [listAppFiles]
///   * GET    /api/apps/{id}/activations/stats    → [activationStats]
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'app_catalog_service.dart' as cat;

class AppLifecycleService {
  AppLifecycleService._();
  static final AppLifecycleService _instance = AppLifecycleService._();
  factory AppLifecycleService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  Options _opts() => Options(
        validateStatus: (s) => s != null && s < 500 && s != 401,
        headers: const {'Content-Type': 'application/json'},
      );

  // ── Validate / deploy ────────────────────────────────────────

  /// POST /api/apps/validate — check an app.yaml without deploying.
  /// Pass either [yamlPath] (local filesystem path the daemon can
  /// read) or [yamlContent] (inline text). Returns
  /// `{valid: bool, errors?: [...], warnings?: [...]}`.
  Future<Map<String, dynamic>?> validateYaml({
    String? yamlPath,
    String? yamlContent,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/validate',
        data: {
          'yaml_path': ?yamlPath,
          'yaml_content': ?yamlContent,
        },
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.validateYaml: $e');
      return null;
    }
  }

  /// POST /api/apps/deploy — deploy from a filesystem path that the
  /// daemon reads (path must be on a volume the daemon process can
  /// access). For inline content from a Flutter client use
  /// [deployFromUpload] instead.
  Future<Map<String, dynamic>?> deployFromYamlPath(
    String yamlPath, {
    bool force = false,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/deploy',
        data: {'yaml_path': yamlPath, 'force': force},
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.deployFromYamlPath: $e');
      return null;
    }
  }

  /// POST /api/apps/deploy/upload — multipart upload for deploying
  /// from the client. [bundle] is the raw bytes of a .yaml or
  /// .zip bundle; [filename] informs the daemon which shape to
  /// expect.
  Future<Map<String, dynamic>?> deployFromUpload({
    required List<int> bundle,
    required String filename,
    bool force = false,
  }) async {
    try {
      final form = FormData.fromMap({
        'force': force.toString(),
        'file': MultipartFile.fromBytes(bundle, filename: filename),
      });
      final r = await _dio.post(
        '/api/apps/deploy/upload',
        data: form,
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.deployFromUpload: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/deploy-status — poll this after a deploy to
  /// see if the daemon finished compiling + starting the app. The
  /// UI uses this to show a spinner that resolves when
  /// `status == 'ready'`.
  Future<Map<String, dynamic>?> deployStatus(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/deploy-status',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.deployStatus: $e');
      return null;
    }
  }

  /// POST /api/apps/{id}/pipeline — run the app's declared pipeline
  /// (a multi-step compound operation different from a regular chat
  /// turn). Payload shape is app-specific; pass [inputs] as the raw
  /// map.
  Future<Map<String, dynamic>?> runPipeline(
    String appId, {
    required Map<String, dynamic> inputs,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/pipeline',
        data: {'inputs': inputs},
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.runPipeline: $e');
      return null;
    }
  }

  /// POST /api/apps/{id}/run — trigger a headless run (no chat
  /// session), useful for cron / trigger-style executions.
  Future<Map<String, dynamic>?> runApp(
    String appId, {
    Map<String, dynamic>? inputs,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/run',
        data: {'inputs': ?inputs},
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.runApp: $e');
      return null;
    }
  }

  // ── Enable / disable / reload / delete ───────────────────────
  //
  // These four delegate to [cat.AppCatalogService] so the lifecycle
  // contract is unified with the Hub's install / upgrade /
  // check-update calls. Exceptions propagate so the UI can surface a
  // real error message instead of a generic "Delete failed" toast —
  // `_AdminMenuButton` catches [AppCatalogException] and renders its
  // `.message` on the snackbar.

  /// POST /api/apps/{id}/reload — re-read the deployed app.yaml +
  /// restart modules. Use after an in-place edit. Scope-agnostic on
  /// the daemon side.
  Future<bool> reload(String appId) =>
      cat.AppCatalogService().reloadApp(appId);

  /// POST /api/apps/{id}/disable?scope=... — pause the app without
  /// undeploying. Triggers won't fire; existing sessions keep their
  /// state but can't send new messages until re-enabled. Admin
  /// required for system-scoped apps (403 otherwise). Scope is
  /// MANDATORY: without it, a legacy `system`-installed app returns
  /// `{success:false, error:"...not found in DB"}` because the
  /// daemon walks `scope=user` by default.
  Future<bool> disable(String appId, {String? scope}) =>
      cat.AppCatalogService().disableApp(appId, scope: scope);

  /// POST /api/apps/{id}/enable?scope=... — reverse of [disable].
  /// Admin-only for system scope.
  Future<bool> enable(String appId, {String? scope}) =>
      cat.AppCatalogService().enableApp(appId, scope: scope);

  /// `DELETE /api/apps/{id}?scope={scope}` — tested-live uninstall.
  ///
  /// Why DELETE and not POST `/uninstall`: the daemon has a split
  /// install registry. Apps deployed via the unified install flow
  /// carry the full metadata shape (`source_type`, `install_dir`,
  /// `scope`, `hash`…) and are addressable by either endpoint. Apps
  /// deployed via the legacy `POST /api/apps/deploy` path (which is
  /// the majority in real daemons — 39/46 on the test env) are NOT
  /// in the install registry and `POST /uninstall` responds with
  /// `404 "App not visible"`. Only `DELETE /api/apps/{id}` targets
  /// both registries and is safe for every app.
  ///
  /// [scope] is MANDATORY for correctness: when missing the daemon
  /// defaults to `"user"` and walks only the caller's private
  /// store. For any app the user didn't install themselves (every
  /// built-in, every `system`-scoped install) the call returns
  /// `{success: false, error: "nothing_to_delete"}` — the exact
  /// symptom the user reported. Always pass the pkg's known scope.
  Future<bool> deleteApp(String appId,
      {bool force = false, String? scope}) async {
    debugPrint(
        'AppLifecycle.deleteApp → DELETE /api/apps/$appId scope=$scope force=$force');
    try {
      final r = await _dio.delete(
        '/api/apps/$appId',
        queryParameters: {
          if (scope != null && scope.isNotEmpty) 'scope': scope,
          if (force) 'force': 'true',
        },
        options: _opts(),
      );
      debugPrint(
          'AppLifecycle.deleteApp ← status=${r.statusCode} body=${r.data}');
      final body = r.data;
      final status = r.statusCode ?? 0;
      if (status < 200 || status >= 300 || body is! Map) {
        throw cat.AppCatalogException(
          _extractError(body) ?? 'HTTP $status',
          statusCode: status,
        );
      }
      // Reject `success: false` strictly. The daemon returns 200 +
      // success:false for idempotent no-ops (wrong scope, already
      // removed, unknown app) — classifying those as success was
      // the "no error but app still there" bug. We surface them as
      // an error so the UI shows the dialog with the real reason.
      if (body['success'] == false) {
        throw cat.AppCatalogException(
          _extractError(body) ?? 'Daemon refused the uninstall',
          statusCode: status,
          errorCode: body['error'] as String?,
        );
      }
      // Refresh the shared catalog so the Hub's list re-renders
      // without the deleted row in the same frame as the toast.
      // ignore: discarded_futures
      cat.AppCatalogService().refresh();
      return true;
    } on DioException catch (e) {
      debugPrint('AppLifecycle.deleteApp DioException: ${e.message}');
      throw cat.AppCatalogException(
        _extractError(e.response?.data) ??
            e.message ??
            'network error',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// DELETE /api/apps/{id}?delete_history=true — the spec's "Supprimer
  /// dur" variant that also wipes session history. Used by the
  /// `_BrokenCard` Delete affordance (via the Library flow), not the
  /// admin menu's Delete which is always the soft "keep sessions"
  /// path above.
  Future<bool> hardDeleteApp(String appId) async {
    debugPrint(
        'AppLifecycle.hardDeleteApp → DELETE /api/apps/$appId?delete_history=true');
    final r = await _dio.delete(
      '/api/apps/$appId',
      queryParameters: {'delete_history': 'true'},
      options: _opts(),
    );
    debugPrint(
        'AppLifecycle.hardDeleteApp ← status=${r.statusCode} body=${r.data}');
    final body = r.data;
    final status = r.statusCode ?? 0;
    if (status < 200 || status >= 300 || body is! Map) {
      throw cat.AppCatalogException(
        _extractError(body) ?? 'HTTP $status',
        statusCode: status,
      );
    }
    if (body['success'] == false) {
      throw cat.AppCatalogException(
        _extractError(body) ?? 'Daemon refused the delete',
        statusCode: status,
      );
    }
    // ignore: discarded_futures
    cat.AppCatalogService().refresh();
    return true;
  }

  String? _extractError(dynamic body) {
    if (body is! Map) return null;
    final detail = body['detail'];
    if (detail is String) return detail;
    if (detail is Map) {
      final msg = detail['error'] ?? detail['message'];
      if (msg != null) return msg.toString();
    }
    final e = body['error'] ?? body['message'];
    return e?.toString();
  }

  /// Legacy raw-endpoint path kept for the error / diagnostics / file
  /// routes below. Removed from the lifecycle block above.
  // ignore: unused_element
  Future<bool> _legacyRaw(String appId) async {
    try {
      final r = await _dio.delete('/api/apps/$appId', options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('AppLifecycle.deleteApp: $e');
      return false;
    }
  }

  // ── Introspection ────────────────────────────────────────────

  /// GET /api/apps/{id}/payload-schema — JSON schema the daemon
  /// would validate a `runApp(inputs: …)` call against. Drives
  /// auto-generated forms in the dashboard.
  Future<Map<String, dynamic>?> fetchPayloadSchema(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/payload-schema',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.fetchPayloadSchema: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/index — capability index (agents, tools,
  /// modules, triggers, assets) for app inspection.
  Future<Map<String, dynamic>?> fetchAppIndex(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/index', options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.fetchAppIndex: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/errors — recent deploy / runtime errors.
  Future<List<Map<String, dynamic>>?> fetchErrors(
      String appId, {int limit = 10}) async {
    try {
      final r = await _dio.get(
        '/api/apps/$appId/errors',
        queryParameters: {'limit': limit},
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
      final raw = data?['errors'] ?? data?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('AppLifecycle.fetchErrors: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/diagnostics — self-diagnostic snapshot
  /// (compile state, required-secrets pending, module health).
  Future<Map<String, dynamic>?> fetchDiagnostics(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/diagnostics',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.fetchDiagnostics: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/files — raw source files of the deployed
  /// app (read-only browse; use workspace endpoints for session-
  /// scoped edits).
  Future<List<Map<String, dynamic>>?> listAppFiles(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/files', options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
      final raw = data?['files'] ?? data?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('AppLifecycle.listAppFiles: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/activations/stats — aggregate activation
  /// counters (total, by status, by day). Feeds the app dashboard
  /// chart.
  Future<Map<String, dynamic>?> activationStats(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/activations/stats',
          options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.activationStats: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/status — high-level deploy + runtime status.
  Future<Map<String, dynamic>?> status(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/status', options: _opts());
      if (r.statusCode != 200 || r.data is! Map) return null;
      return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('AppLifecycle.status: $e');
      return null;
    }
  }
}
