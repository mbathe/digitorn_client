import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'background_app_service.dart';

/// Friendly wrapper for the `/payload` routes on a background session.
///
/// Use [BackgroundAppService] to create the session itself, then this
/// service to manage what the session sends to its agent on every
/// tick: a prompt, a structured metadata bag, and a list of file
/// attachments.
///
/// Errors are surfaced as [PayloadException] with a human-readable
/// message and the matching HTTP status code so the UI can branch
/// (e.g. show a clear message on a 413).
class PayloadException implements Exception {
  final String message;
  final int? statusCode;
  const PayloadException(this.message, {this.statusCode});
  @override
  String toString() => 'PayloadException($statusCode): $message';
}

class PayloadService extends ChangeNotifier {
  static final PayloadService _i = PayloadService._();
  factory PayloadService() => _i;
  PayloadService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    // Multipart uploads can be slow for 25 MB files on web.
    receiveTimeout: const Duration(minutes: 2),
    sendTimeout: const Duration(minutes: 2),
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  String _path(String appId, String sessionId) =>
      '$_base/api/apps/$appId/background-sessions/$sessionId/payload';

  // ── GET ──────────────────────────────────────────────────────────────

  /// Fetch the current payload. Returns [SessionPayload.empty] when the
  /// daemon reports `{prompt: "", metadata: {}, files: []}` — i.e. the
  /// session has never been configured.
  Future<SessionPayload> get(String appId, String sessionId) async {
    try {
      final r = await _dio.get(_path(appId, sessionId));
      return _parsePayload(r);
    } on DioException catch (e) {
      throw PayloadException(
        'Failed to load payload: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
      );
    }
  }

  // ── PUT prompt + metadata ────────────────────────────────────────────

  /// Upserts `prompt` and / or `metadata`. The daemon shallow-merges:
  /// keys you don't send stay intact. Pass at least one of them.
  Future<SessionPayload> setPromptAndMetadata(
    String appId,
    String sessionId, {
    String? prompt,
    Map<String, dynamic>? metadata,
  }) async {
    if (prompt == null && metadata == null) {
      throw const PayloadException(
          'setPromptAndMetadata requires at least one of prompt / metadata');
    }
    try {
      final r = await _dio.put(
        _path(appId, sessionId),
        data: {
          'prompt': ?prompt,
          'metadata': ?metadata,
        },
      );
      return _parsePayload(r);
    } on DioException catch (e) {
      throw PayloadException(
        'Failed to save payload: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
      );
    }
  }

  // ── Upload file (multipart) ──────────────────────────────────────────

  static const int _maxFileBytes = 25 * 1024 * 1024;

  /// Uploads a file from raw bytes — the only path that works on
  /// Flutter Web, where there's no filesystem path. Pass [filename]
  /// (the daemon sanitizes it server-side) and an optional
  /// [contentType] (defaults to `application/octet-stream`).
  ///
  /// Throws [PayloadException] with `statusCode == 413` when the file
  /// exceeds the 25 MiB cap. The check is performed client-side first
  /// to fail fast without uploading 50 MB to the network.
  Future<SessionPayload> uploadFileBytes({
    required String appId,
    required String sessionId,
    required Uint8List bytes,
    required String filename,
    String? contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (bytes.length > _maxFileBytes) {
      throw PayloadException(
        'File "$filename" is ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB '
        '(max 25 MB). Pick a smaller file.',
        statusCode: 413,
      );
    }
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: contentType != null
            ? DioMediaType.parse(contentType)
            : null,
      ),
    });
    try {
      final r = await _dio.post(
        '${_path(appId, sessionId)}/files',
        data: form,
        onSendProgress: onProgress,
        options: Options(contentType: 'multipart/form-data'),
      );
      // The daemon may return either the new payload directly or
      // wrap it inside `data:` — _parsePayload handles both.
      if (r.statusCode == 413) {
        throw const PayloadException(
          'File too large (max 25 MB)',
          statusCode: 413,
        );
      }
      return _parsePayload(r);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 413) {
        throw const PayloadException(
            'File too large (max 25 MB)',
            statusCode: 413);
      }
      throw PayloadException(
        'Upload failed: ${e.message ?? e.type.name}',
        statusCode: code,
      );
    }
  }

  // ── Delete file ──────────────────────────────────────────────────────

  Future<SessionPayload> deleteFile({
    required String appId,
    required String sessionId,
    required String filename,
  }) async {
    try {
      final r = await _dio.delete(
        '${_path(appId, sessionId)}/files/$filename',
      );
      return _parsePayload(r);
    } on DioException catch (e) {
      throw PayloadException(
        'Failed to delete $filename: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
      );
    }
  }

  // ── Wipe ─────────────────────────────────────────────────────────────

  Future<void> clear({
    required String appId,
    required String sessionId,
  }) async {
    try {
      await _dio.delete(_path(appId, sessionId));
    } on DioException catch (e) {
      throw PayloadException(
        'Failed to clear payload: ${e.message ?? e.type.name}',
        statusCode: e.response?.statusCode,
      );
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  SessionPayload _parsePayload(Response r) {
    final body = r.data;
    if (body is! Map) {
      return SessionPayload.empty;
    }
    if (body['success'] != true) {
      final err = body['error'] as String? ?? 'Unknown error';
      throw PayloadException(err, statusCode: r.statusCode);
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) {
      return SessionPayload.fromJson(data);
    }
    if (data is Map) {
      return SessionPayload.fromJson(data.cast<String, dynamic>());
    }
    return SessionPayload.empty;
  }
}
