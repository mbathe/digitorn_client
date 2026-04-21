import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/app_summary.dart';
import 'auth_service.dart';

/// Structured result of a destructive or reversible lifecycle call.
/// Every field is optional so partial daemon responses still parse.
class AppLifecycleResult {
  /// `delete` | `disable` | `enable`.
  final String operation;
  final String appId;
  final bool deleted;
  final bool disabled;
  final bool enabled;
  final bool wasDeployed;
  final bool wasDisabled;
  final bool redeployed;
  final bool historyPreserved;
  final int bundlesDeleted;
  final int secretsDeleted;
  final bool diskRemoved;
  final bool dbRemoved;
  final String message;

  const AppLifecycleResult({
    required this.operation,
    required this.appId,
    this.deleted = false,
    this.disabled = false,
    this.enabled = false,
    this.wasDeployed = false,
    this.wasDisabled = false,
    this.redeployed = false,
    this.historyPreserved = false,
    this.bundlesDeleted = 0,
    this.secretsDeleted = 0,
    this.diskRemoved = false,
    this.dbRemoved = false,
    this.message = '',
  });

  factory AppLifecycleResult.fromJson(
    Map<String, dynamic> json, {
    required String operation,
  }) =>
      AppLifecycleResult(
        operation: operation,
        appId: json['app_id'] as String? ?? '',
        deleted: json['deleted'] == true,
        disabled: json['disabled'] == true,
        enabled: json['enabled'] == true,
        wasDeployed: json['was_deployed'] == true ||
            json['deployed'] == true,
        wasDisabled: json['was_disabled'] == true,
        redeployed: json['redeployed'] == true,
        historyPreserved: json['history_preserved'] == true,
        bundlesDeleted: (json['bundles_deleted'] as num?)?.toInt() ?? 0,
        secretsDeleted: (json['secrets_deleted'] as num?)?.toInt() ?? 0,
        diskRemoved: json['disk_removed'] == true,
        dbRemoved: json['db_removed'] == true,
        message: json['message'] as String? ?? '',
      );
}

/// Admin-only view: one disabled app returned by
/// `GET /api/apps?include_disabled=true`.
class DisabledApp {
  final String appId;
  final String name;
  final String version;
  final DateTime? disabledAt;
  final String? disabledReason;
  /// Whether the preserved bundle still exists on disk. When false,
  /// the app cannot be re-enabled — only purged with a final DELETE.
  final bool hasBundle;
  /// `"system"` or `"user"` — drives the admin action (re-enable
  /// system-wide vs re-enable for a specific user).
  final String scope;
  /// Owner when [scope] == `"user"`, empty otherwise.
  final String ownerUserId;

  const DisabledApp({
    required this.appId,
    required this.name,
    this.version = '',
    this.disabledAt,
    this.disabledReason,
    this.hasBundle = true,
    this.scope = 'system',
    this.ownerUserId = '',
  });

  bool get isUserScope => scope == 'user';
  bool get isSystemScope => scope == 'system';

  factory DisabledApp.fromJson(Map<String, dynamic> json) {
    DateTime? ts;
    final raw = json['disabled_at'];
    if (raw is String) {
      ts = DateTime.tryParse(raw);
    } else if (raw is num) {
      ts = DateTime.fromMillisecondsSinceEpoch(
          (raw * 1000).toInt(),
          isUtc: true);
    }
    return DisabledApp(
      appId: (json['app_id'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      version: (json['version'] ?? '') as String,
      disabledAt: ts,
      disabledReason: json['disabled_reason'] as String?,
      hasBundle: json['has_bundle'] != false,
      scope: (json['scope'] as String?)?.toLowerCase() == 'user'
          ? 'user'
          : 'system',
      ownerUserId: (json['owner_user_id'] as String?) ?? '',
    );
  }
}

/// Thrown by [AppsService.deploy] / [AppsService.deleteApp] / [AppsService.stop]
/// on any failure. When the daemon reports missing `{{env.X}}` variables,
/// [missingSecrets] will contain their names so the UI can prompt the
/// user for values and retry the deploy.
class DeployException implements Exception {
  final String message;
  final List<String> missingSecrets;

  const DeployException(this.message, {this.missingSecrets = const []});

  bool get needsSecrets => missingSecrets.isNotEmpty;

  @override
  String toString() => 'DeployException: $message';
}

/// Singleton service in charge of the new daemon deploy/delete routes
/// (`/api/apps/deploy/upload`, `DELETE /api/apps/{id}`). The service
/// keeps a cached list of deployed apps that any Provider consumer can
/// watch; call [refresh] after important mutations.
///
/// Note: the chat / popover UIs still fetch apps via the older
/// [DigitornApiClient.fetchApps] path and pass them around explicitly,
/// so this service is used mainly as the **write** surface (deploy,
/// delete, stop) + a secondary cache for management screens.
class AppsService extends ChangeNotifier {
  static final AppsService _instance = AppsService._();
  factory AppsService() => _instance;
  AppsService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    // Longer receive timeout because upload can take a moment for
    // bundles that reference large skill assets.
    receiveTimeout: const Duration(minutes: 2),
  ))..interceptors.add(AuthService().authInterceptor);

  List<AppSummary> _apps = [];
  List<AppSummary> get apps => List.unmodifiable(_apps);
  bool isLoading = false;
  String? lastError;

  // ── Read ────────────────────────────────────────────────────────────

  /// GET /api/apps — refresh the cached list.
  Future<void> refresh() async {
    final base = AuthService().baseUrl;
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final resp = await _dio.get(
        '$base/api/apps',
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.data is Map && resp.data['success'] == true) {
        final list = resp.data['data'] as List? ?? const [];
        _apps = list
            .whereType<Map<String, dynamic>>()
            .map(AppSummary.fromJson)
            .toList();
      }
    } catch (e) {
      lastError = e.toString();
      debugPrint('AppsService.refresh error: $e');
    }
    isLoading = false;
    notifyListeners();
  }

  // ── Deploy ──────────────────────────────────────────────────────────

  /// POST /api/apps/deploy/upload — upload a YAML file's bytes plus
  /// any referenced assets (skill files, agent prompts…) that the
  /// YAML points at via relative paths, then wait for the app to
  /// finish deploying via GET /api/apps/{id} polling.
  ///
  /// The daemon requires every `./skills/xxx.md` / `./prompts/yyy.md`
  /// path in the YAML to be supplied through the [assets] map, keyed
  /// by its forward-slash path relative to the YAML's directory.
  /// See [AppBundle] / `loadAppBundle()` for the loader that builds
  /// this map from a ZIP or a bare YAML.
  ///
  /// Throws [DeployException] on any failure. When the YAML references
  /// `{{env.FOO}}` variables that aren't set daemon-side, the
  /// exception's [DeployException.missingSecrets] lists their names —
  /// catch it and re-call [deploy] with a filled-in [secrets] map.
  Future<AppSummary> deploy({
    required Uint8List yamlBytes,
    required String filename,
    Map<String, String>? secrets,
    Map<String, String>? assets,
    bool force = true,
    /// `"system"` (default — requires admin) or `"user"` (private
    /// install scoped to the caller). Non-admins get a 403 when
    /// trying to install system-wide.
    String scope = 'system',
  }) async {
    final base = AuthService().baseUrl;

    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(yamlBytes, filename: filename),
      'force': force.toString(),
      'scope': scope,
      if (secrets != null && secrets.isNotEmpty)
        'secrets': jsonEncode(secrets),
      if (assets != null && assets.isNotEmpty)
        'assets': jsonEncode(assets),
    });

    Response resp;
    try {
      resp = await _dio.post(
        '$base/api/apps/deploy/upload',
        data: formData,
        options: Options(
          contentType: 'multipart/form-data',
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
    } on DioException catch (e) {
      throw DeployException('Network error: ${e.message ?? e.type.name}');
    }

    if (resp.data is! Map || resp.data['success'] != true) {
      final errorMsg =
          (resp.data is Map ? resp.data['error'] as String? : null) ??
              'Unknown deploy error (HTTP ${resp.statusCode})';
      throw DeployException(
        errorMsg,
        missingSecrets: _parseMissingSecrets(errorMsg),
      );
    }

    final appId = resp.data['data']?['app_id'] as String? ?? '';
    if (appId.isEmpty) {
      throw const DeployException('Deploy succeeded but no app_id returned');
    }

    // The deploy is asynchronous: poll GET /api/apps/{id} until it's
    // reachable or we hit the 30s deadline.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        final check = await _dio.get(
          '$base/api/apps/$appId',
          options: Options(
            validateStatus: (s) => s != null && s < 500 && s != 401,
          ),
        );
        if (check.statusCode == 200 &&
            check.data is Map &&
            check.data['success'] == true &&
            check.data['data'] is Map) {
          final app = AppSummary.fromJson(
              (check.data['data'] as Map).cast<String, dynamic>());
          await refresh();
          return app;
        }
      } catch (_) {
        // 404 = still deploying or failed silently — keep polling.
      }
    }
    throw const DeployException(
      'Deployment is taking longer than expected — check daemon logs',
    );
  }

  // ── Delete / Disable / Enable ───────────────────────────────────────

  /// DELETE /api/apps/{id} — permanent wipe (code + DB rows + sessions
  /// + secrets). Irreversible. Builtin apps are rejected by the daemon.
  /// Kept for backwards-compat — new code should use [deleteApp]
  /// which exposes the `deleteHistory` / `undeployOnly` flags.
  Future<void> delete(String appId) => deleteApp(appId);

  /// Rich delete — exposes the two flags the daemon accepts. On
  /// success the local cache is invalidated; the daemon also emits
  /// an `app_deleted` event the Socket.IO layer can react to.
  ///
  /// * [deleteHistory] — when false, keeps sessions / messages /
  ///   activations in the DB but wipes the code bundle. The app row
  ///   is marked disabled. Still irreversible for the bundle itself.
  /// * [undeployOnly] — stop in memory only, leave everything on
  ///   disk + in the DB (redeployed at the next daemon restart).
  /// * [scope] — `"system"` (admin only) forces deletion of the
  ///   shared install. Without it, the daemon targets the caller's
  ///   user-scoped install first, falling back to system only if
  ///   the caller is admin.
  Future<AppLifecycleResult> deleteApp(
    String appId, {
    bool deleteHistory = true,
    bool undeployOnly = false,
    String? scope,
  }) async {
    final base = AuthService().baseUrl;
    Response resp;
    try {
      resp = await _dio.delete(
        '$base/api/apps/$appId',
        queryParameters: {
          if (!deleteHistory) 'delete_history': 'false',
          if (undeployOnly) 'undeploy_only': 'true',
          if (scope != null && scope.isNotEmpty) 'scope': scope,
        },
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
    } on DioException catch (e) {
      throw DeployException('Network error: ${e.message ?? e.type.name}');
    }
    if (resp.statusCode == 403) {
      throw const DeployException(
        'Only administrators can target the system scope explicitly.',
        missingSecrets: ['__admin__'],
      );
    }
    if (resp.data is! Map || resp.data['success'] != true) {
      final err = (resp.data is Map ? resp.data['error'] as String? : null) ??
          'Delete failed (HTTP ${resp.statusCode})';
      throw DeployException(err);
    }
    // Only remove local entry when it matches the scope we targeted.
    _apps.removeWhere((a) => a.appId == appId &&
        (scope == null || a.scope == scope));
    notifyListeners();
    final data =
        (resp.data['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AppLifecycleResult.fromJson(data, operation: 'delete');
  }

  /// POST /api/apps/{id}/disable — hides the app from listings and
  /// refuses interactions, but preserves everything on disk and in
  /// the DB. Reversible only by an admin via [enableApp].
  ///
  /// `scope=system` is admin-only — non-admins hitting the system
  /// install get a 403 translated to a DeployException with
  /// `missingSecrets: ['__admin__']` so the UI can render the
  /// "admin only" toast.
  Future<AppLifecycleResult> disableApp(
    String appId, {
    String? reason,
    String? scope,
  }) async {
    final base = AuthService().baseUrl;
    Response resp;
    try {
      resp = await _dio.post(
        '$base/api/apps/$appId/disable',
        queryParameters: {
          if (scope != null && scope.isNotEmpty) 'scope': scope,
        },
        data: {if (reason != null && reason.isNotEmpty) 'reason': reason},
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
    } on DioException catch (e) {
      throw DeployException('Network error: ${e.message ?? e.type.name}');
    }
    if (resp.statusCode == 403) {
      throw const DeployException(
        'Only administrators can target the system scope explicitly.',
        missingSecrets: ['__admin__'],
      );
    }
    if (resp.data is! Map || resp.data['success'] != true) {
      final err = (resp.data is Map ? resp.data['error'] as String? : null) ??
          'Disable failed (HTTP ${resp.statusCode})';
      throw DeployException(err);
    }
    _apps.removeWhere((a) => a.appId == appId &&
        (scope == null || a.scope == scope));
    notifyListeners();
    final data =
        (resp.data['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AppLifecycleResult.fromJson(data, operation: 'disable');
  }

  /// POST /api/apps/{id}/enable — admin-only. Redeploys the app from
  /// its preserved bundle. Throws a [DeployException] with
  /// `missingSecrets = ['__admin__']` as a sentinel when the daemon
  /// returns 403, so the UI can show the "admin only" toast.
  ///
  /// * Default call (no params) → reactivates the **system** install.
  /// * `scope: 'user', userId: 'alice'` → reactivates Alice's private
  ///   install. The caller must still be admin; the daemon enforces.
  Future<AppLifecycleResult> enableApp(
    String appId, {
    String? scope,
    String? userId,
  }) async {
    final base = AuthService().baseUrl;
    Response resp;
    try {
      resp = await _dio.post(
        '$base/api/apps/$appId/enable',
        queryParameters: {
          if (scope != null && scope.isNotEmpty) 'scope': scope,
          if (userId != null && userId.isNotEmpty) 'user_id': userId,
        },
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
    } on DioException catch (e) {
      throw DeployException('Network error: ${e.message ?? e.type.name}');
    }
    if (resp.statusCode == 403) {
      throw const DeployException(
        'Only administrators can re-enable a disabled app.',
        missingSecrets: ['__admin__'],
      );
    }
    if (resp.data is! Map || resp.data['success'] != true) {
      final err = (resp.data is Map ? resp.data['error'] as String? : null) ??
          'Enable failed (HTTP ${resp.statusCode})';
      throw DeployException(err);
    }
    await refresh();
    final data =
        (resp.data['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return AppLifecycleResult.fromJson(data, operation: 'enable');
  }

  /// Admin-only — GET /api/apps?include_disabled=true returns the
  /// active apps **and** the disabled ones. Non-admins get the same
  /// payload as the plain `/api/apps`; the daemon silently ignores
  /// the flag.
  Future<List<DisabledApp>> fetchDisabledApps() async {
    final base = AuthService().baseUrl;
    try {
      final resp = await _dio.get(
        '$base/api/apps',
        queryParameters: const {'include_disabled': 'true'},
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (resp.data is! Map || resp.data['success'] != true) return const [];
      final list = (resp.data['data'] as List?) ?? const [];
      return list
          .whereType<Map>()
          .where((m) => m['disabled'] == true)
          .map((m) => DisabledApp.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      debugPrint('fetchDisabledApps error: $e');
      return const [];
    }
  }

  /// DELETE /api/apps/{id}?undeploy_only=true — stop an app in memory
  /// without removing its persisted data. The daemon will reload it at
  /// the next restart. 404 is treated as already-stopped and silently
  /// ignored.
  Future<void> stop(String appId) async {
    final base = AuthService().baseUrl;
    Response resp;
    try {
      resp = await _dio.delete(
        '$base/api/apps/$appId',
        queryParameters: const {'undeploy_only': 'true'},
        options: Options(
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
    } on DioException catch (e) {
      throw DeployException('Network error: ${e.message ?? e.type.name}');
    }
    if (resp.statusCode == 404) return; // already stopped — not an error
    if (resp.data is! Map || resp.data['success'] != true) {
      final err = (resp.data is Map ? resp.data['error'] as String? : null) ??
          'Stop failed (HTTP ${resp.statusCode})';
      throw DeployException(err);
    }
    await refresh();
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  /// Extract the names of missing environment variables from a daemon
  /// compilation error message. Returns an empty list on no match.
  static List<String> _parseMissingSecrets(String errorMessage) {
    final re = RegExp(r"Environment variable '([A-Z_][A-Z0-9_]*)' not found");
    return re
        .allMatches(errorMessage)
        .map((m) => m.group(1)!)
        .toSet()
        .toList(growable: false);
  }
}
