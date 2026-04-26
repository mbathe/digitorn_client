/// Unified `/api/apps/*` client. Replaces the old split between
/// `PackageService` (`/api/packages/*`) and the lifecycle endpoints
/// in `AppLifecycleService` — the daemon now surfaces install,
/// deploy, upgrade, check-update and runtime state under one
/// namespace. See the April 2026 Hub contract for full details.
///
/// Error shapes:
///   * 2xx + `success: true`        — payload in `data`
///   * 2xx + `success: false`       — idempotent no-op (e.g. disable
///     on an already-disabled app). Callers should treat as info.
///   * 4xx/5xx + `success: false`   — real error. 409 with
///     `detail.error == "permissions_required"` is surfaced as
///     [PermissionsRequiredException] so the consent dialog can run.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/app_package.dart' show PermissionsRequired;
import '../models/app_summary.dart';
import 'auth_service.dart';
import 'cache/swr_cache.dart';

/// Raised by anything that hits the unified app API and fails in a
/// way the UI needs to react to beyond "show a toast". Carries the
/// HTTP status so callers can branch on 403/404/501/etc.
class AppCatalogException implements Exception {
  final String message;
  final int? statusCode;
  final String? errorCode;
  const AppCatalogException(
    this.message, {
    this.statusCode,
    this.errorCode,
  });
  @override
  String toString() =>
      'AppCatalogException($statusCode${errorCode != null ? "/$errorCode" : ""}): $message';
}

/// 409 with `detail.error == "permissions_required"` — the app asks
/// for sensitive permissions that must be consented to. Caller
/// re-issues the same call with `acceptPermissions: true` after the
/// user clicks Accept in the consent dialog.
class PermissionsRequiredException extends AppCatalogException {
  final PermissionsRequired details;
  const PermissionsRequiredException(this.details)
      : super('permissions_required',
            statusCode: 409, errorCode: 'permissions_required');
}

/// 409 with `detail.error == "app_already_installed"` — the target
/// app id already exists on the daemon. Caller shows a toast and
/// flips to the Installed tab.
class AppAlreadyInstalledException extends AppCatalogException {
  final Map<String, dynamic>? existing;
  const AppAlreadyInstalledException({this.existing})
      : super('app_already_installed',
            statusCode: 409, errorCode: 'app_already_installed');
}

/// 501 Not Implemented — Hub / Git sources not yet wired in v1.
class UnsupportedSourceException extends AppCatalogException {
  final String sourceType;
  const UnsupportedSourceException(this.sourceType)
      : super('source_not_supported',
            statusCode: 501, errorCode: 'source_not_supported');
}

/// Result of an install / upgrade call. `deployed` distinguishes a
/// successful install-and-deploy from an install that landed on disk
/// but whose deploy failed (the daemon keeps the files but the app
/// is `runtime_status: "broken"`).
class InstallResult {
  final AppSummary app;
  final bool deployed;
  final String? deployError;
  const InstallResult({
    required this.app,
    required this.deployed,
    this.deployError,
  });
}

/// Result of the check-update probe.
class UpdateCheck {
  final String appId;
  final String currentVersion;
  final String? latestVersion;
  final bool updateAvailable;
  final String? reason;
  const UpdateCheck({
    required this.appId,
    required this.currentVersion,
    required this.latestVersion,
    required this.updateAvailable,
    this.reason,
  });

  factory UpdateCheck.fromJson(Map<String, dynamic> j) => UpdateCheck(
        appId: (j['app_id'] as String?) ?? '',
        currentVersion: (j['current_version'] as String?) ?? '',
        latestVersion: j['latest_version'] as String?,
        updateAvailable: j['update_available'] == true,
        reason: j['reason'] as String?,
      );
}

class AppCatalogService extends ChangeNotifier {
  static final AppCatalogService _i = AppCatalogService._();
  factory AppCatalogService() => _i;
  AppCatalogService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    // Install / upgrade can take 5-30 s (fetch + compile + deploy).
    receiveTimeout: const Duration(minutes: 2),
    sendTimeout: const Duration(seconds: 20),
    // Let our own code branch on 4xx; the interceptor still
    // transparently refreshes on 401.
    validateStatus: (s) => s != null && s < 600 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // ─── In-memory cache shared by Hub + App Panel ───────────────────────
  List<AppSummary> _apps = const [];

  /// Stale-while-revalidate cache for the ``/api/apps`` endpoint.
  /// Tab switches used to hit the daemon every time; now the cached
  /// list is served immediately and revalidated in background only
  /// when it's older than [_listCacheTtl]. Invalidated by
  /// [invalidateListCache] on explicit lifecycle changes (install,
  /// uninstall, enable, disable, redeploy).
  static const Duration _listCacheTtl = Duration(minutes: 5);
  final SwrCache<String, List<AppSummary>> _listCache = SwrCache(
    ttl: _listCacheTtl,
    name: 'apps_list',
  );
  List<AppSummary> get apps => List.unmodifiable(_apps);

  /// `runtime_status == "running"` subset — the only view surfaced to
  /// the home App Panel. Built-in sort: built-ins first, then by name.
  List<AppSummary> get runnableApps {
    final running = _apps.where((a) => a.isRunning).toList();
    running.sort((a, b) {
      if (a.builtin != b.builtin) return a.builtin ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return running;
  }

  bool isLoading = false;
  String? lastError;

  // ─── GET /api/apps — unified list ────────────────────────────────────

  /// Fetch the canonical apps list. Pass [includeInstalled] to also
  /// surface installed-but-not-deployed rows (`runtime_status ==
  /// "not_deployed"`) and installs with `install_status == "broken"`
  /// (manifest corrupt on disk, hash mismatch, …). [includeDisabled]
  /// is admin-only server-side; non-admins get a 200 with `data`
  /// silently filtered.
  Future<List<AppSummary>> refresh({
    bool includeInstalled = true,
    bool includeDisabled = false,
    /// Force a network round-trip, skipping the SWR cache. Used by
    /// the pull-to-refresh gesture and right after explicit lifecycle
    /// mutations (install, uninstall, enable, disable).
    bool force = false,
  }) async {
    final cacheKey = 'apps:installed=$includeInstalled:disabled=$includeDisabled';
    // When the cache is fresh we return instantly and skip all the
    // loading-flag / notify churn — the UI already has the right
    // data. This is what makes tab-switching feel instant.
    if (!force && _listCache.isFresh(cacheKey)) {
      final cached = _listCache.peek(cacheKey);
      if (cached != null) {
        _apps = cached;
        return _apps;
      }
    }

    lastError = null;

    Future<List<AppSummary>> fetch() async {
      final resp = await _dio.get(
        '$_base/api/apps',
        queryParameters: {
          if (includeInstalled) 'include_installed': 'true',
          if (includeDisabled) 'include_disabled': 'true',
        },
      );
      final envelope = _envelope(resp);
      final rawList = envelope['data'];
      final list = rawList is List ? rawList : const [];
      return list
          .whereType<Map>()
          .map((m) => AppSummary.fromJson(m.cast<String, dynamic>()))
          .toList();
    }

    // Serve stale-if-present immediately, revalidate in background.
    // On cold miss we await the fetch and show the spinner.
    final hadCache = _listCache.peek(cacheKey) != null;
    if (!hadCache) {
      isLoading = true;
      notifyListeners();
    }
    try {
      final result = await _listCache.getOrFetch(
        key: cacheKey,
        fetcher: fetch,
        force: force,
        onRevalidated: (fresh) {
          _apps = fresh;
          notifyListeners();
        },
      );
      _apps = result;
      return _apps;
    } on AppCatalogException catch (e) {
      lastError = e.message;
      return _apps;
    } catch (e) {
      lastError = e.toString();
      debugPrint('AppCatalogService.refresh error: $e');
      return _apps;
    } finally {
      if (isLoading) {
        isLoading = false;
      }
      notifyListeners();
    }
  }

  /// Drop the SWR cache — the next ``refresh()`` call will hit the
  /// daemon. Call after any mutation that changes the apps list:
  /// install, uninstall, enable, disable, redeploy.
  void invalidateListCache() {
    _listCache.clear();
  }

  // ─── GET /api/apps/{id} — canonical detail with drift + metadata ────

  Future<AppSummary?> getApp(String appId) async {
    try {
      final resp = await _dio.get('$_base/api/apps/$appId');
      final envelope = _envelope(resp);
      final data = envelope['data'];
      if (data is! Map) return null;
      return AppSummary.fromJson(data.cast<String, dynamic>());
    } catch (e) {
      debugPrint('AppCatalogService.getApp($appId) error: $e');
      return null;
    }
  }

  // ─── GET /api/apps/{id}/status — lightweight probe ──────────────────

  Future<Map<String, dynamic>?> appStatus(String appId) async {
    try {
      final resp = await _dio.get('$_base/api/apps/$appId/status');
      final envelope = _envelope(resp);
      final data = envelope['data'];
      return data is Map ? data.cast<String, dynamic>() : null;
    } catch (e) {
      debugPrint('AppCatalogService.appStatus($appId) error: $e');
      return null;
    }
  }

  // ─── POST /api/apps/install — consent dance ─────────────────────────

  /// Install an app. Accepts all three shapes the daemon supports:
  ///   * explicit: pass [sourceType] + [sourceUri]
  ///   * shortcut: pass [source] ("hub://owner/name@v", "git+...", an
  ///     absolute path, or a bare id for built-ins)
  ///   * legacy: the shortcut form with [force] == true (maps to
  ///     `accept_permissions: true`, kept for BUG-100 compat)
  ///
  /// Throws [PermissionsRequiredException] on the first 409 probe —
  /// catch it, show the consent dialog, and call again with
  /// [acceptPermissions] set to `true`.
  Future<InstallResult> installApp({
    String? source,
    String? sourceType,
    String? sourceUri,
    bool acceptPermissions = false,
    bool force = false,
    String scope = 'user',
  }) async {
    assert(source != null || (sourceType != null && sourceUri != null),
        'installApp needs `source` OR (`sourceType` + `sourceUri`)');
    final body = <String, dynamic>{
      'source': ?source,
      'source_type': ?sourceType,
      'source_uri': ?sourceUri,
      'accept_permissions': acceptPermissions,
      if (force) 'force': true,
      'scope': scope,
    };
    final resp = await _dio.post('$_base/api/apps/install', data: body);
    _handlePermissionOrConflict(resp);
    final envelope = _envelope(resp);
    final data =
        (envelope['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final appJson = (data['app'] as Map?)?.cast<String, dynamic>() ?? data;
    final deployed = data['deployed'] == true;
    final deployError = data['deploy_error'] as String?;
    final app = AppSummary.fromJson(appJson);
    // Refresh the cache so the Hub sees the new row without a second
    // round-trip. Cheap because the list is typically small (<50).
    // The server just mutated the apps list — drop the SWR cache so
    // the refresh actually goes to the network instead of serving the
    // stale copy from before the enable/disable.
    invalidateListCache();
    // ignore: discarded_futures
    refresh(force: true);
    return InstallResult(
      app: app,
      deployed: deployed,
      deployError: deployError,
    );
  }

  // ─── POST /api/apps/{id}/upgrade — consent dance, rollback-aware ────

  Future<InstallResult> upgradeApp({
    required String appId,
    String sourceType = 'local',
    String? sourceUri,
    bool acceptPermissions = false,
  }) async {
    final body = <String, dynamic>{
      'source_type': sourceType,
      'source_uri': ?sourceUri,
      'accept_permissions': acceptPermissions,
    };
    final resp = await _dio.post(
      '$_base/api/apps/$appId/upgrade',
      data: body,
    );
    _handlePermissionOrConflict(resp);
    final envelope = _envelope(resp);
    final data =
        (envelope['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final appJson = (data['app'] as Map?)?.cast<String, dynamic>() ?? data;
    final deployed = data['deployed'] == true;
    final deployError = data['deploy_error'] as String?;
    final app = AppSummary.fromJson(appJson);
    // The server just mutated the apps list — drop the SWR cache so
    // the refresh actually goes to the network instead of serving the
    // stale copy from before the enable/disable.
    invalidateListCache();
    // ignore: discarded_futures
    refresh(force: true);
    return InstallResult(
      app: app,
      deployed: deployed,
      deployError: deployError,
    );
  }

  // ─── GET /api/apps/{id}/check-update ────────────────────────────────

  Future<UpdateCheck?> checkUpdate(String appId) async {
    try {
      final resp = await _dio.get('$_base/api/apps/$appId/check-update');
      final envelope = _envelope(resp);
      final data = envelope['data'];
      if (data is! Map) return null;
      return UpdateCheck.fromJson(data.cast<String, dynamic>());
    } catch (e) {
      debugPrint('AppCatalogService.checkUpdate($appId) error: $e');
      return null;
    }
  }

  /// Batch helper: run `checkUpdate` on every installed app with a
  /// concurrency cap so we don't hammer the daemon on the Updates
  /// tab refresh. Entries whose check failed are skipped silently.
  Future<List<UpdateCheck>> checkUpdatesBatch(List<String> appIds,
      {int concurrency = 6}) async {
    final results = <UpdateCheck>[];
    for (var i = 0; i < appIds.length; i += concurrency) {
      final batch = appIds.skip(i).take(concurrency);
      final probes = await Future.wait(batch.map(checkUpdate));
      for (final p in probes) {
        if (p != null) results.add(p);
      }
    }
    return results;
  }

  // ─── Lifecycle — reload / disable / enable / uninstall / delete ─────
  //
  // All endpoints that touch the install DB (disable / enable /
  // uninstall) MUST accept a [scope] because the daemon's default
  // scope for the caller's JWT is `"user"`. For apps deployed via
  // the legacy route (which is most installs in practice), the
  // write lands in `scope=system` — a no-scope call returns
  // `success:false, error:"...not found in DB"`. Pass the pkg's
  // known scope from [AppSummary.scope] (defaults to `"system"`
  // when the daemon omits the field for legacy rows).

  Future<bool> reloadApp(String appId) async {
    final resp = await _dio.post('$_base/api/apps/$appId/reload');
    return _envelope(resp)['success'] == true;
  }

  /// POST /api/apps/{id}/disable[?scope=...]. Returns `success:true`
  /// for a fresh disable, `success:true` with `was_disabled:true`
  /// for an idempotent no-op, and throws [AppCatalogException] on
  /// a real error (wrong scope, unknown app, 403 for system apps
  /// when the caller isn't admin).
  Future<bool> disableApp(String appId, {String? scope}) async {
    final resp = await _dio.post(
      '$_base/api/apps/$appId/disable',
      queryParameters: {
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      },
    );
    // The server just mutated the apps list — drop the SWR cache so
    // the refresh actually goes to the network instead of serving the
    // stale copy from before the enable/disable.
    invalidateListCache();
    // ignore: discarded_futures
    refresh(force: true);
    return _envelope(resp)['success'] == true;
  }

  Future<bool> enableApp(String appId, {String? scope}) async {
    final resp = await _dio.post(
      '$_base/api/apps/$appId/enable',
      queryParameters: {
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      },
    );
    // The server just mutated the apps list — drop the SWR cache so
    // the refresh actually goes to the network instead of serving the
    // stale copy from before the enable/disable.
    invalidateListCache();
    // ignore: discarded_futures
    refresh(force: true);
    return _envelope(resp)['success'] == true;
  }

  /// Uninstall an app. Uses `DELETE /api/apps/{id}?scope={scope}` —
  /// validated live as the only endpoint that works for both the
  /// unified install registry AND legacy deploys (39/46 installs on
  /// a typical daemon). `POST /api/apps/{id}/uninstall` returns 404
  /// for legacy rows and 403 for builtins, so it's not safe here.
  ///
  /// [scope] must match the pkg's known scope (`AppSummary.scope`).
  /// Without it the daemon defaults to `scope=user` and returns
  /// `{success:false, error:"nothing_to_delete"}` for everything
  /// the caller didn't install personally.
  ///
  /// [force] is kept in the query string for the daemon builds that
  /// still gate built-in uninstalls behind it.
  Future<bool> uninstallApp(String appId,
      {bool force = false, String? scope}) async {
    final resp = await _dio.delete(
      '$_base/api/apps/$appId',
      queryParameters: {
        if (scope != null && scope.isNotEmpty) 'scope': scope,
        if (force) 'force': 'true',
      },
    );
    final env = _envelope(resp);
    // 2xx + success:false is an idempotent no-op (wrong scope,
    // already removed, unknown app). Reject strictly so the UI
    // surfaces the daemon's message instead of silently pretending
    // the uninstall worked while the app stayed in the list.
    if (env['success'] == false) {
      final body = env['data'] is Map
          ? env['data'] as Map
          : env;
      throw AppCatalogException(
        (body['message'] as String?) ??
            (env['error'] as String?) ??
            'Daemon refused the uninstall',
        statusCode: resp.statusCode,
        errorCode: env['error'] as String?,
      );
    }
    // The server just mutated the apps list — drop the SWR cache so
    // the refresh actually goes to the network instead of serving the
    // stale copy from before the enable/disable.
    invalidateListCache();
    // ignore: discarded_futures
    refresh(force: true);
    return true;
  }

  /// DELETE /api/apps/{id}?delete_history=true&scope=... — hard
  /// delete variant that also wipes session history + workspace
  /// files. The "soft" path is [uninstallApp].
  Future<bool> deleteApp(String appId,
      {bool deleteHistory = false, String? scope}) async {
    final resp = await _dio.delete(
      '$_base/api/apps/$appId',
      queryParameters: {
        if (deleteHistory) 'delete_history': 'true',
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      },
    );
    final env = _envelope(resp);
    if (env['success'] == false) {
      final body = env['data'] is Map ? env['data'] as Map : env;
      throw AppCatalogException(
        (body['message'] as String?) ??
            (env['error'] as String?) ??
            'Daemon refused the delete',
        statusCode: resp.statusCode,
        errorCode: env['error'] as String?,
      );
    }
    // The server just mutated the apps list — drop the SWR cache so
    // the refresh actually goes to the network instead of serving the
    // stale copy from before the enable/disable.
    invalidateListCache();
    // ignore: discarded_futures
    refresh(force: true);
    return true;
  }

  // ─── Sessions — used by App Panel tap ───────────────────────────────

  /// POST /api/apps/{id}/sessions — create a new session for this
  /// app. Returns the sessionId on success, null on failure (which
  /// typically means the app is broken / not deployed anymore).
  Future<String?> createSession(String appId) async {
    try {
      final resp = await _dio.post('$_base/api/apps/$appId/sessions');
      final envelope = _envelope(resp);
      final data =
          (envelope['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      return (data['session_id'] as String?)?.isNotEmpty == true
          ? data['session_id'] as String
          : null;
    } catch (e) {
      debugPrint('AppCatalogService.createSession($appId) error: $e');
      return null;
    }
  }

  // ─── Assets — icon URL + README / CHANGELOG fetch ───────────────────

  /// Absolute URL for the app icon. Use `AuthService().authImageHeaders`
  /// when passing it to `Image.network` so the bearer token reaches
  /// the daemon.
  String iconUrl(String appId) => '$_base/api/apps/$appId/icon';

  /// Raw text asset (README.md / CHANGELOG.md / LICENSE). Returns
  /// null on 404 so the caller can hide the pane gracefully.
  Future<String?> fetchTextAsset(String appId, String path) async {
    try {
      final resp = await _dio.get(
        '$_base/api/apps/$appId/assets/$path',
        options: Options(responseType: ResponseType.plain),
      );
      if (resp.statusCode == 200 && resp.data is String) {
        return resp.data as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ─── Envelope + 409 parser ──────────────────────────────────────────

  /// Normalise the response into the canonical `{success, data, error,
  /// detail}` map. Rejects anything that isn't a JSON object, and
  /// raises [AppCatalogException] for real errors while letting
  /// `success: false` on a 2xx (idempotent no-op) through unchanged.
  Map<String, dynamic> _envelope(Response resp) {
    final body = resp.data;
    final status = resp.statusCode ?? 0;
    if (body is! Map) {
      throw AppCatalogException(
        'malformed response (${body.runtimeType})',
        statusCode: status,
      );
    }
    final env = body.cast<String, dynamic>();
    // 2xx success or 2xx idempotent no-op — both surface the same map
    // shape; caller can read `success` to branch.
    if (status >= 200 && status < 300) return env;
    // 4xx / 5xx — unwrap error/detail if present. FastAPI's
    // HTTPException(detail="...") sends a String, while structured
    // errors (HTTPException(detail={...})) send a Map. Handle both
    // shapes so checkUpdate doesn't blow up on plain-string details.
    final rawDetail = env['detail'];
    final Map<String, dynamic> detail = rawDetail is Map
        ? rawDetail.cast<String, dynamic>()
        : const {};
    final detailMsg = rawDetail is String ? rawDetail : null;
    final err = (detail['error'] as String?) ??
        (env['error'] as String?) ??
        'http_$status';
    final msg = (detail['message'] as String?) ??
        detailMsg ??
        (env['message'] as String?) ??
        err;
    if (status == 501) {
      throw UnsupportedSourceException(
          (detail['source_type'] as String?) ?? '');
    }
    throw AppCatalogException(msg,
        statusCode: status, errorCode: err);
  }

  /// Inspect a 409 response and promote it to the typed exception so
  /// callers don't have to parse the shape themselves. No-op for any
  /// other status.
  void _handlePermissionOrConflict(Response resp) {
    if (resp.statusCode != 409) return;
    final body = resp.data;
    if (body is! Map) return;
    // detail may be a Map (structured) or a String (plain message) —
    // only Maps carry an `error` field, so a String detail just falls
    // through to the body-level fallback.
    final rawDetail = body['detail'];
    final detail = rawDetail is Map
        ? rawDetail.cast<String, dynamic>()
        : null;
    final error = detail?['error'] ?? body['error'];
    if (error == 'permissions_required') {
      final payload = detail ?? body.cast<String, dynamic>();
      throw PermissionsRequiredException(
        PermissionsRequired.fromJson(payload),
      );
    }
    if (error == 'app_already_installed') {
      final existing =
          (detail?['existing'] as Map?)?.cast<String, dynamic>() ??
              (body['existing'] as Map?)?.cast<String, dynamic>();
      throw AppAlreadyInstalledException(existing: existing);
    }
  }
}
