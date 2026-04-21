/// Shim around the April-2026 unified `/api/apps/*` backend, kept so
/// the existing Hub UI (package cards, install flow, updates list)
/// keeps compiling while the UI layer is migrated to [AppSummary].
///
/// Reads delegate to [AppCatalogService]: `list()` calls
/// `AppCatalogService.refresh()` and adapts each `AppSummary` into
/// the [AppPackage] shape the UI expects. Writes (install / upgrade
/// / uninstall) also go through [AppCatalogService] so there's a
/// single source of truth — but we still surface them as
/// `AppPackage` + the existing [PermissionsRequiredException] /
/// [PackageConflictException] so call sites don't need to change.
///
/// When the UI is fully on `AppSummary` this file can be deleted.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/app_package.dart';
import '../models/app_summary.dart';
import 'app_catalog_service.dart' as cat;
import 'auth_service.dart';

class PackageException implements Exception {
  final String message;
  final int? statusCode;
  const PackageException(this.message, {this.statusCode});
  @override
  String toString() => 'PackageException($statusCode): $message';
}

/// Raised when the install/upgrade endpoint returns 409 with the
/// permissions probe payload. The caller catches this, shows the
/// consent dialog, and re-issues the same call with
/// `acceptPermissions: true`.
class PermissionsRequiredException extends PackageException {
  final PermissionsRequired details;
  const PermissionsRequiredException(this.details, {super.statusCode = 409})
      : super('permissions_required');
}

/// Raised on duplicate package_id (D12).
class PackageConflictException extends PackageException {
  final String existingSourceType;
  final String existingVersion;
  const PackageConflictException(
    super.message, {
    required this.existingSourceType,
    required this.existingVersion,
    super.statusCode = 409,
  });
}

class PackageService extends ChangeNotifier {
  static final PackageService _i = PackageService._();
  factory PackageService() => _i;
  PackageService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(minutes: 2), // installs can be slow
    sendTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // Local cache so multiple consumers share state.
  List<AppPackage> _packages = const [];
  List<AppPackage> get packages => List.unmodifiable(_packages);
  bool isLoading = false;

  // ── List / get ────────────────────────────────────────────────────

  /// Installed apps, adapted from the unified `/api/apps` response.
  /// Includes everything the daemon tracks on disk — running,
  /// not-deployed, broken — so the Hub Installed tab can group by
  /// runtime state. Disabled rows are only included for admins
  /// (the daemon filters them out for regular users anyway).
  Future<List<AppPackage>> list() async {
    isLoading = true;
    notifyListeners();
    try {
      final summaries = await cat.AppCatalogService().refresh(
        includeInstalled: true,
      );
      final list = summaries.map(_summaryToPackage).toList();
      _packages = list;
      debugPrint('PackageService.list → ${list.length} app(s)');
      return list;
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to list apps');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Convert an [AppSummary] (unified shape) into the legacy
  /// [AppPackage] shape the Hub cards expect. Lossy by design — the
  /// card only renders a subset — but preserves every field the
  /// install / upgrade / uninstall flows read back (source_type,
  /// hash, install_dir, scope, update availability).
  AppPackage _summaryToPackage(AppSummary s) {
    final installedAt =
        s.installedAt.isNotEmpty ? DateTime.tryParse(s.installedAt) : null;
    return AppPackage(
      packageId: s.appId,
      name: s.name,
      version: s.version,
      description: s.description,
      author: s.author,
      icon: s.icon.isNotEmpty ? s.icon : null,
      category: s.category.isNotEmpty ? s.category : null,
      sourceType: s.sourceType.isNotEmpty ? s.sourceType : 'local',
      sourceUri: s.sourceUri.isNotEmpty ? s.sourceUri : null,
      status: s.installStatus.isNotEmpty ? s.installStatus : 'installed',
      hash: s.hash.isNotEmpty ? s.hash : null,
      installDir: s.installDir.isNotEmpty ? s.installDir : null,
      installedAt: installedAt,
      updatedAt: installedAt,
      // `update_available` is a separate `/check-update` probe on
      // the unified API — the list endpoint doesn't pre-compute it.
      // Set null here so the Hub Updates tab asks per-app.
      updateAvailable: null,
      // When the runtime is live, deployedAppId == appId by
      // construction; when it isn't, keep null so the card knows
      // the app isn't launchable.
      deployedAppId: s.isRunning ? s.appId : null,
      runtimeStatus: s.runtimeStatus,
      deployError: s.deployError,
      scope: s.scope,
      ownerUserId: s.ownerUserId.isEmpty ? null : s.ownerUserId,
    );
  }

  Future<AppPackage?> get(String packageId) async {
    try {
      final r = await _dio.get('$_base/api/packages/$packageId');
      final data = _unwrap(r);
      if (data == null) return null;
      return AppPackage.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to load package');
    }
  }

  // ── Install ───────────────────────────────────────────────────────

  /// First call without [acceptPermissions] returns 409 with the
  /// permissions probe — the client shows a dialog. After consent,
  /// call again with `acceptPermissions: true`.
  ///
  /// [scope] controls who will see the install:
  ///   * `user` (default) — personal install, only the caller sees it
  ///   * `system` — admin only, visible to every user (403 otherwise)
  Future<AppPackage> install({
    required String sourceType, // local | hub | git | builtin
    required String sourceUri,
    String? version,
    bool acceptPermissions = false,
    String scope = 'user',
  }) async {
    try {
      final res = await cat.AppCatalogService().installApp(
        sourceType: sourceType,
        sourceUri: sourceUri,
        acceptPermissions: acceptPermissions,
        scope: scope,
      );
      final pkg = _summaryToPackage(res.app);
      _packages = [
        ..._packages.where((p) => p.packageId != pkg.packageId),
        pkg,
      ];
      notifyListeners();
      return pkg;
    } on cat.PermissionsRequiredException catch (e) {
      throw PermissionsRequiredException(e.details);
    } on cat.AppAlreadyInstalledException catch (e) {
      final existing = e.existing ?? const {};
      throw PackageConflictException(
        'Already installed',
        existingSourceType:
            existing['source_type'] as String? ?? 'unknown',
        existingVersion: existing['version'] as String? ?? '?',
      );
    } on cat.UnsupportedSourceException {
      throw const PackageException(
        "This app source isn't available in your daemon yet.",
        statusCode: 501,
      );
    } on cat.AppCatalogException catch (e) {
      throw PackageException(
        e.message,
        statusCode: e.statusCode,
      );
    } on DioException catch (e) {
      throw _wrap(e, 'Install failed');
    }
  }

  // ── Uninstall ─────────────────────────────────────────────────────

  /// [scope] is forwarded to the daemon. Callers should pass the
  /// pkg's known scope (`AppSummary.scope` / `AppPackage.scope`) —
  /// without it the daemon's default `scope=user` misses anything
  /// not installed by the caller personally and returns
  /// "nothing_to_delete" with `success:false`.
  Future<void> uninstall(String packageId,
      {bool force = false, String? scope}) async {
    try {
      await cat.AppCatalogService()
          .uninstallApp(packageId, force: force, scope: scope);
      _packages =
          _packages.where((p) => p.packageId != packageId).toList();
      notifyListeners();
    } on cat.AppCatalogException catch (e) {
      throw PackageException(e.message, statusCode: e.statusCode);
    } on DioException catch (e) {
      throw _wrap(e, 'Uninstall failed');
    }
  }

  // ── Upgrade ───────────────────────────────────────────────────────

  Future<AppPackage> upgrade(
    String packageId, {
    String? version,
    bool acceptPermissions = false,
  }) async {
    try {
      final res = await cat.AppCatalogService().upgradeApp(
        appId: packageId,
        acceptPermissions: acceptPermissions,
      );
      final pkg = _summaryToPackage(res.app);
      _packages = [
        for (final p in _packages) p.packageId == packageId ? pkg : p
      ];
      notifyListeners();
      return pkg;
    } on cat.PermissionsRequiredException catch (e) {
      throw PermissionsRequiredException(e.details);
    } on cat.AppCatalogException catch (e) {
      throw PackageException(e.message, statusCode: e.statusCode);
    } on DioException catch (e) {
      throw _wrap(e, 'Upgrade failed');
    }
  }

  // ── Check updates ─────────────────────────────────────────────────

  /// The unified API dropped the bulk `/check-updates` endpoint — the
  /// Hub Updates tab now probes one app at a time via
  /// `AppCatalogService.checkUpdate`. We keep this shape so the
  /// existing UI compiles; it fans out to the new per-app probe.
  Future<List<({String packageId, String current, String latest})>>
      checkUpdates() async {
    final ids = _packages.map((p) => p.packageId).toList();
    final probes = await cat.AppCatalogService().checkUpdatesBatch(ids);
    return [
      for (final u in probes)
        if (u.updateAvailable && u.latestVersion != null)
          (
            packageId: u.appId,
            current: u.currentVersion,
            latest: u.latestVersion!,
          )
    ];
  }

  // ── Hub: discover available packages ──────────────────────────────

  /// `GET /api/packages/available?source=hub&q=…` — list featured
  /// + searchable packages from the daemon's hub source. The hub is
  /// a stub in v1 (returns 501); the store UI catches that and
  /// falls back to its hardcoded featured catalogue so the demo
  /// experience stays alive.
  Future<List<AppPackage>> listAvailable({
    String source = 'hub',
    String? query,
    String? category,
  }) async {
    try {
      final r = await _dio.get(
        '$_base/api/packages/available',
        queryParameters: {
          'source': source,
          'q': ?query,
          'category': ?category,
        },
      );
      if (r.statusCode == 501) {
        throw const PackageException(
          'Hub source isn\'t available in your daemon yet.',
          statusCode: 501,
        );
      }
      final data = _unwrap(r);
      final list = (data?['results'] as List? ??
              data?['packages'] as List? ??
              const [])
          .whereType<Map>()
          .map((m) => AppPackage.fromJson(m.cast<String, dynamic>()))
          .toList();
      return list;
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to fetch hub catalogue');
    }
  }

  // ── Generate manifest from a yaml ─────────────────────────────────

  Future<String?> generateManifest(String yaml) async {
    try {
      final r = await _dio.post(
        '$_base/api/discovery/generate-package-manifest',
        data: {'yaml': yaml},
      );
      final data = _unwrap(r);
      return data?['toml'] as String?;
    } on DioException catch (e) {
      throw _wrap(e, 'Manifest generation failed');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Map<String, dynamic>? _unwrap(Response r) {
    final body = r.data;
    if (body is! Map) return null;
    if (body['success'] == false) {
      final err = body['error']?.toString() ?? 'Unknown error';
      throw PackageException(err, statusCode: r.statusCode);
    }
    final data = body['data'] ?? body;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return null;
  }

  PackageException _wrap(DioException e, String fallback) {
    String? detail;
    final body = e.response?.data;
    if (body is Map) {
      detail = body['error']?.toString() ?? body['detail']?.toString();
    }
    return PackageException(
      detail ?? '$fallback: ${e.message ?? e.type.name}',
      statusCode: e.response?.statusCode,
    );
  }
}
