/// Wire-level client for the widgets runtime + preview server
/// endpoints.
///
/// **Widgets**: the daemon serves dynamic widget data, streams
/// updates, stores uploaded files, and accepts action / interact
/// callbacks from Flutter widgets built at runtime.
///
/// **Preview server**: for apps that host a long-running preview
/// (React / Vite / SPA), the daemon manages the subprocess. The
/// client can query status, stream logs, and restart the server.
///
/// Scout audit 2026-04-20 covered:
///
///   * GET    /apps/{id}/widgets/data/{binding}
///   * GET    /apps/{id}/widgets/data/{binding}/stream  (SSE)
///   * POST   /apps/{id}/widgets/upload
///   * GET    /apps/{id}/widgets/upload/{user_id}/{sid}/{file_id}/{filename}
///   * GET    /apps/{id}/widgets/validate
///   * POST   /apps/{id}/widgets/action
///   * POST   /apps/{id}/interact
///   * GET    /apps/{id}/preview/{buffer_key}
///   * GET    /apps/{id}/preview-server/status
///   * GET    /apps/{id}/preview-server/logs
///   * POST   /apps/{id}/preview-server/restart
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'auth_service.dart';

class WidgetsRuntimeService {
  WidgetsRuntimeService._();
  static final WidgetsRuntimeService _instance = WidgetsRuntimeService._();
  factory WidgetsRuntimeService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  Options _opts() => Options(
        validateStatus: (s) => s != null && s < 500 && s != 401,
        headers: const {'Content-Type': 'application/json'},
      );

  Map<String, dynamic>? _data(Response r) {
    if (r.statusCode != 200 || r.data is! Map) return null;
    if ((r.data as Map)['success'] != true) return null;
    return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
  }

  // ── Widget data ──────────────────────────────────────────────

  /// GET /apps/{id}/widgets/data/{binding} — one-shot read of a
  /// widget's data-binding output. Used by widgets rendered from a
  /// static layout that don't need live updates.
  Future<Map<String, dynamic>?> fetchWidgetData(
    String appId,
    String binding, {
    Map<String, dynamic>? params,
  }) async {
    try {
      final r = await _dio.get(
        '/api/apps/$appId/widgets/data/'
        '${Uri.encodeComponent(binding)}',
        queryParameters: params,
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('WidgetsRuntime.fetchWidgetData: $e');
      return null;
    }
  }

  /// GET /apps/{id}/widgets/data/{binding}/stream — Server-Sent
  /// Events stream for live widget data. Each incoming event is a
  /// JSON object; caller typically pipes it into the widget's
  /// state. Cancel by disposing the returned [StreamSubscription]
  /// (the underlying HTTP connection closes automatically).
  Stream<Map<String, dynamic>> streamWidgetData(
    String appId,
    String binding, {
    Map<String, dynamic>? params,
  }) async* {
    final base = _dio.options.baseUrl;
    final uri = Uri.parse(
      '$base/api/apps/$appId/widgets/data/'
      '${Uri.encodeComponent(binding)}/stream',
    ).replace(queryParameters: {
      ...?params?.map((k, v) => MapEntry(k, v.toString())),
    });
    final token = AuthService().accessToken;
    final headers = {
      'Accept': 'text/event-stream',
      if (token != null) 'Authorization': 'Bearer $token',
    };

    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      req.headers.addAll(headers);
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        debugPrint('WidgetsRuntime.streamWidgetData HTTP ${resp.statusCode}');
        return;
      }
      String buffer = '';
      await for (final chunk
          in resp.stream.transform(utf8.decoder)) {
        buffer += chunk;
        while (buffer.contains('\n\n')) {
          final idx = buffer.indexOf('\n\n');
          final frame = buffer.substring(0, idx);
          buffer = buffer.substring(idx + 2);
          for (final line in frame.split('\n')) {
            if (!line.startsWith('data: ')) continue;
            final payload = line.substring(6).trim();
            if (payload.isEmpty || payload == '[DONE]') continue;
            try {
              final decoded = jsonDecode(payload);
              if (decoded is Map) {
                yield decoded.cast<String, dynamic>();
              }
            } catch (_) {}
          }
        }
      }
    } finally {
      client.close();
    }
  }

  /// POST /apps/{id}/widgets/upload — multipart file upload from a
  /// widget (e.g. `<FileDropZone/>`). Returns the daemon's file_id
  /// + the download URL the widget should render the link for.
  Future<Map<String, dynamic>?> uploadWidgetFile(
    String appId, {
    required String sessionId,
    required List<int> bytes,
    required String filename,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final form = FormData.fromMap({
        'session_id': sessionId,
        'file': MultipartFile.fromBytes(bytes, filename: filename),
        if (metadata != null) 'metadata': jsonEncode(metadata),
      });
      final r = await _dio.post(
        '/api/apps/$appId/widgets/upload',
        data: form,
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('WidgetsRuntime.uploadWidgetFile: $e');
      return null;
    }
  }

  /// Build the authenticated URL for a previously uploaded widget
  /// file. The caller passes it to `Image.network` / `<video>` /
  /// etc.; the auth header is appended by the AuthService Dio
  /// interceptor on any Dio call, or the caller sets Authorization
  /// themselves for raw Flutter widgets.
  String buildWidgetFileUrl(
      String appId, String userId, String sessionId,
      String fileId, String filename) {
    return '${_dio.options.baseUrl}/api/apps/$appId/widgets/upload/'
        '${Uri.encodeComponent(userId)}/'
        '${Uri.encodeComponent(sessionId)}/'
        '${Uri.encodeComponent(fileId)}/'
        '${Uri.encodeComponent(filename)}';
  }

  /// GET /apps/{id}/widgets/validate — ask the daemon to re-validate
  /// the app's widget spec; returns errors / warnings. Builder UI
  /// uses this before allowing a deploy.
  Future<Map<String, dynamic>?> validateWidgets(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/widgets/validate',
          options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('WidgetsRuntime.validateWidgets: $e');
      return null;
    }
  }

  /// POST /apps/{id}/widgets/action — the canonical entry point for
  /// a widget firing an action (button click, form submit). The
  /// daemon routes to the bound tool / pipeline.
  Future<Map<String, dynamic>?> widgetAction(
    String appId, {
    required String actionId,
    String? sessionId,
    Map<String, dynamic>? payload,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/widgets/action',
        data: {
          'action_id': actionId,
          'session_id': ?sessionId,
          'payload': ?payload,
        },
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('WidgetsRuntime.widgetAction: $e');
      return null;
    }
  }

  /// POST /apps/{id}/interact — legacy interact endpoint that
  /// preceded [widgetAction]. Kept wired because some apps still
  /// use it.
  Future<Map<String, dynamic>?> interact(
    String appId,
    Map<String, dynamic> body,
  ) async {
    try {
      final r = await _dio.post('/api/apps/$appId/interact',
          data: body, options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('WidgetsRuntime.interact: $e');
      return null;
    }
  }

  // ── Preview buffer ──────────────────────────────────────────

  /// GET /apps/{id}/preview/{buffer_key} — read a rendered preview
  /// buffer (e.g. a markdown page, a PNG image, a JSON asset). The
  /// daemon returns the raw content + a `Content-Type` header;
  /// callers typically use this URL directly in Image.network or
  /// similar, but this method also lets Dart fetch the body as
  /// bytes for programmatic access.
  Future<(List<int>, String?)?> fetchPreviewBuffer(
      String appId, String bufferKey) async {
    try {
      final r = await _dio.get(
        '/api/apps/$appId/preview/${Uri.encodeComponent(bufferKey)}',
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && s < 500 && s != 401,
        ),
      );
      if (r.statusCode != 200) return null;
      final ct = r.headers.map['content-type']?.first;
      return (r.data as List<int>, ct);
    } catch (e) {
      debugPrint('WidgetsRuntime.fetchPreviewBuffer: $e');
      return null;
    }
  }

  /// Build the authenticated URL for a preview buffer (useful for
  /// Image.network / iframe src).
  String buildPreviewBufferUrl(String appId, String bufferKey) {
    return '${_dio.options.baseUrl}/api/apps/$appId/preview/'
        '${Uri.encodeComponent(bufferKey)}';
  }

  // ── Preview server ──────────────────────────────────────────

  /// GET /apps/{id}/preview-server/status — "is the preview subprocess
  /// up?" + port + last-alive timestamp. Null when the app has no
  /// preview server module.
  Future<Map<String, dynamic>?> previewServerStatus(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/preview-server/status',
          options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('WidgetsRuntime.previewServerStatus: $e');
      return null;
    }
  }

  /// GET /apps/{id}/preview-server/logs — recent stdout / stderr of
  /// the preview server. Returns up to [limit] lines.
  Future<List<Map<String, dynamic>>?> previewServerLogs(String appId,
      {int limit = 200}) async {
    try {
      final r = await _dio.get(
        '/api/apps/$appId/preview-server/logs',
        queryParameters: {'limit': limit},
        options: _opts(),
      );
      final data = _data(r);
      if (data == null) return null;
      final raw = data['logs'] ?? data['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('WidgetsRuntime.previewServerLogs: $e');
      return null;
    }
  }

  /// POST /apps/{id}/preview-server/restart — bounce the preview
  /// subprocess. Useful when env vars change or a native dep was
  /// installed.
  Future<bool> previewServerRestart(String appId) async {
    try {
      final r = await _dio.post('/api/apps/$appId/preview-server/restart',
          data: const {}, options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('WidgetsRuntime.previewServerRestart: $e');
      return false;
    }
  }
}
