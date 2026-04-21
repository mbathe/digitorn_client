/// Thin wrapper around the daemon's bundle asset routes. Each app
/// and each package is stored as a directory bundle on disk
/// (prompts/, skills/, assets/, fragments/, …) and the daemon
/// exposes a handful of routes to stream / list / resize their
/// contents:
///
/// **Apps (deployed, visible to the caller):**
///   * `GET /api/apps/{id}/icon` — shortcut for the icon asset
///   * `GET /api/apps/{id}/assets/{path}` — stream any bundle file
///   * `GET /api/apps/{id}/assets/{path}?size=128` — Pillow resize
///   * `GET /api/apps/{id}/files?subdir=prompts` — list files in
///     a sub-folder (returns names + sizes)
///
/// **Packages (installed bundles — same shape as apps but before
/// deployment, used by the future editor):**
///   * `GET /api/packages/{id}/icon`
///   * `GET /api/packages/{id}/assets/{path}`
///
/// **Discovery (no install required — for live prompt preview):**
///   * `POST /api/discovery/prompt-preview` — compile a prompt
///     against variables without deploying
///
/// The UI doesn't call these directly yet (the main consumer is
/// `RemoteIcon` via the icon route) but having the service shape in
/// place means any future editor / asset browser can land without
/// rewriting network plumbing.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

class BundleFile {
  final String name;
  final String path;
  final int size;
  final String? contentType;
  const BundleFile({
    required this.name,
    required this.path,
    required this.size,
    this.contentType,
  });

  factory BundleFile.fromJson(Map<String, dynamic> j) => BundleFile(
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? j['name'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        contentType: j['content_type'] as String?,
      );
}

class PromptPreviewResult {
  final String compiledText;
  final int tokenEstimate;
  final List<String> referencedAssets;
  final Map<String, dynamic> frontmatter;
  const PromptPreviewResult({
    required this.compiledText,
    required this.tokenEstimate,
    this.referencedAssets = const [],
    this.frontmatter = const {},
  });

  factory PromptPreviewResult.fromJson(Map<String, dynamic> j) =>
      PromptPreviewResult(
        compiledText: j['compiled_text'] as String? ?? '',
        tokenEstimate: (j['token_estimate'] as num?)?.toInt() ?? 0,
        referencedAssets: (j['referenced_assets'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        frontmatter: (j['frontmatter'] is Map)
            ? (j['frontmatter'] as Map).cast<String, dynamic>()
            : const {},
      );
}

class AssetsService extends ChangeNotifier {
  static final AssetsService _i = AssetsService._();
  factory AssetsService() => _i;
  AssetsService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // ── Apps ─────────────────────────────────────────────────────────

  /// Build the URL the UI should feed to `Image.network` (or
  /// `Image.memory` after a manual fetch) for an app's icon. The
  /// caller still needs to pass [authImageHeaders] when rendering.
  String appIconUrl(String appId) => '$_base/api/apps/$appId/icon';

  /// Any file inside a deployed app's bundle. Pass [size] to get a
  /// Pillow-resized version (images only — the daemon falls back to
  /// the original on non-image paths).
  String appAssetUrl(String appId, String path, {int? size}) {
    final q = size != null ? '?size=$size' : '';
    return '$_base/api/apps/$appId/assets/$path$q';
  }

  /// Fetch the raw bytes of an app asset. Returns null on 404 so
  /// callers can fall back to emoji / initials.
  Future<Uint8List?> fetchAppAsset(
    String appId,
    String path, {
    int? size,
  }) async {
    try {
      final r = await _dio.get<List<int>>(
        appAssetUrl(appId, path, size: size),
        options: Options(responseType: ResponseType.bytes),
      );
      if (r.statusCode != 200 || r.data == null) return null;
      return Uint8List.fromList(r.data!);
    } on DioException {
      return null;
    }
  }

  /// List files inside a sub-folder of an app bundle. Used by
  /// future editors that want to browse prompts / skills / fragments.
  Future<List<BundleFile>> listAppFiles(
    String appId, {
    required String subdir,
  }) async {
    try {
      final r = await _dio.get(
        '$_base/api/apps/$appId/files',
        queryParameters: {'subdir': subdir},
      );
      if (r.statusCode != 200 || r.data is! Map) return const [];
      final list = (r.data as Map)['files'] as List? ?? const [];
      return list
          .whereType<Map>()
          .map((m) => BundleFile.fromJson(m.cast<String, dynamic>()))
          .toList();
    } on DioException {
      return const [];
    }
  }

  // ── Packages ────────────────────────────────────────────────────

  String packageIconUrl(String packageId) =>
      '$_base/api/packages/$packageId/icon';

  String packageAssetUrl(String packageId, String path, {int? size}) {
    final q = size != null ? '?size=$size' : '';
    return '$_base/api/packages/$packageId/assets/$path$q';
  }

  Future<Uint8List?> fetchPackageAsset(
    String packageId,
    String path, {
    int? size,
  }) async {
    try {
      final r = await _dio.get<List<int>>(
        packageAssetUrl(packageId, path, size: size),
        options: Options(responseType: ResponseType.bytes),
      );
      if (r.statusCode != 200 || r.data == null) return null;
      return Uint8List.fromList(r.data!);
    } on DioException {
      return null;
    }
  }

  // ── Discovery / editor helpers ──────────────────────────────────

  /// Compile a prompt from a raw bundle dir against variables,
  /// without deploying the app. Used by a live-preview editor.
  Future<PromptPreviewResult?> promptPreview({
    required String bundleDir,
    required String promptName,
    Map<String, dynamic> variables = const {},
    String locale = 'en',
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/discovery/prompt-preview',
        data: {
          'bundle_dir': bundleDir,
          'prompt_name': promptName,
          'variables': variables,
          'locale': locale,
        },
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      final data = (r.data as Map).cast<String, dynamic>();
      return PromptPreviewResult.fromJson(data);
    } on DioException {
      return null;
    }
  }
}
