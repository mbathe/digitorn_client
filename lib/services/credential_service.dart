/// HTTP wrapper for the Digitorn daemon's universal credentials API.
///
/// Every route in §3 of the credentials spec is represented here as a
/// single async method. All errors are surfaced as
/// [CredentialException] with the HTTP status so the UI can branch
/// on 401/403/404/503 etc.
///
/// Polling helpers for OAuth and MCP flows live at the bottom — they
/// take a callback and a timeout instead of returning a Stream, which
/// keeps the call sites simple.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/credential_schema.dart';
import 'auth_service.dart';

class CredentialException implements Exception {
  final String message;
  final int? statusCode;
  const CredentialException(this.message, {this.statusCode});
  @override
  String toString() => 'CredentialException($statusCode): $message';
}

class CredentialService extends ChangeNotifier {
  static final CredentialService _i = CredentialService._();
  factory CredentialService() => _i;
  CredentialService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 15),
    // We want the 4xx bodies to come back so we can read `error.detail`.
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // ── 3.1 Schema + fill state for one app ───────────────────────────────

  Future<CredentialSchema> getSchema(String appId) async {
    try {
      final r = await _dio.get('$_base/api/apps/$appId/credentials/schema');
      final data = _unwrap(r);
      if (data == null) return CredentialSchema.empty;
      return CredentialSchema.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to load credentials schema');
    }
  }

  // ── 3.2 All credentials of the current user ───────────────────────────

  Future<List<UserCredentialEntry>> listMine() async {
    try {
      final r = await _dio.get('$_base/api/users/me/credentials');
      final data = _unwrap(r);
      if (data == null) return const [];
      final list = data['credentials'] as List? ?? data['entries'] as List? ?? [];
      return list
          .whereType<Map>()
          .map((e) => UserCredentialEntry.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to list credentials');
    }
  }

  // ── 3.3 Upsert one credential ─────────────────────────────────────────

  /// [appId] may be `"_global"` to store a cross-app per-user credential.
  Future<void> upsert({
    required String appId,
    required String providerName,
    required Map<String, dynamic> fields,
  }) async {
    try {
      final r = await _dio.put(
        '$_base/api/users/me/credentials/$appId/$providerName',
        data: {'fields': fields},
      );
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to save $providerName');
    }
  }

  // ── 3.4 Delete one credential ─────────────────────────────────────────

  Future<void> delete({
    required String appId,
    required String providerName,
  }) async {
    try {
      final r = await _dio.delete(
        '$_base/api/users/me/credentials/$appId/$providerName',
      );
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to delete $providerName');
    }
  }

  // ── 3.5 OAuth flow ────────────────────────────────────────────────────

  /// Returns `{auth_url, state, provider, scopes}` from the daemon. The
  /// caller is responsible for opening [authUrl] in an external
  /// browser, then calling [pollOauthStatus] with the returned state.
  Future<OAuthStartResponse> startOauth({
    required String appId,
    required String providerName,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/users/me/credentials/$appId/$providerName/oauth/start',
      );
      final data = _unwrap(r);
      if (data == null) {
        throw const CredentialException('OAuth start returned empty data');
      }
      return OAuthStartResponse.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to start OAuth');
    }
  }

  Future<OAuthStatus> getOauthStatus({
    required String appId,
    required String providerName,
    required String state,
  }) async {
    try {
      final r = await _dio.get(
        '$_base/api/users/me/credentials/$appId/$providerName/oauth/status',
        queryParameters: {'state': state},
      );
      final data = _unwrap(r);
      return OAuthStatus.fromJson(data ?? const {});
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to poll OAuth status');
    }
  }

  Future<void> refreshOauth({
    required String appId,
    required String providerName,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/users/me/credentials/$appId/$providerName/oauth/refresh',
      );
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to refresh OAuth');
    }
  }

  // ── 3.6 MCP lifecycle ─────────────────────────────────────────────────

  Future<void> startMcp({
    required String appId,
    required String providerName,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/users/me/credentials/$appId/$providerName/mcp/start',
      );
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to start MCP server');
    }
  }

  Future<void> stopMcp({
    required String appId,
    required String providerName,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/users/me/credentials/$appId/$providerName/mcp/stop',
      );
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to stop MCP server');
    }
  }

  Future<McpStatus> getMcpStatus({
    required String appId,
    required String providerName,
  }) async {
    try {
      final r = await _dio.get(
        '$_base/api/users/me/credentials/$appId/$providerName/mcp/status',
      );
      final data = _unwrap(r);
      return McpStatus.fromJson(data ?? const {});
    } on DioException catch (e) {
      throw _wrap(e, 'Failed to get MCP status');
    }
  }

  // ── Helpers: polling ──────────────────────────────────────────────────

  /// Polls `oauth/status` every [interval] until it returns `connected`,
  /// an error, or [timeout] elapses. The UI shows a spinner during this.
  Future<OAuthStatus> pollOauthUntilDone({
    required String appId,
    required String providerName,
    required String state,
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(interval);
      final s = await getOauthStatus(
        appId: appId,
        providerName: providerName,
        state: state,
      );
      if (s.status == 'connected' ||
          s.status == 'error' ||
          s.status == 'expired') {
        return s;
      }
    }
    return const OAuthStatus(status: 'timeout', error: 'Timed out');
  }

  // ── Helpers: response unwrapping ──────────────────────────────────────

  Map<String, dynamic>? _unwrap(Response r) {
    final body = r.data;
    if (body is! Map) return null;
    if (body['success'] == false) {
      final err = body['error']?.toString() ?? 'Unknown error';
      throw CredentialException(err, statusCode: r.statusCode);
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return null;
  }

  void _checkSuccess(Response r) {
    final body = r.data;
    if (body is Map && body['success'] == false) {
      final err = body['error']?.toString() ?? 'Unknown error';
      throw CredentialException(err, statusCode: r.statusCode);
    }
  }

  CredentialException _wrap(DioException e, String fallback) {
    final code = e.response?.statusCode;
    // Prefer a server-provided detail when it exists.
    String? detail;
    final body = e.response?.data;
    if (body is Map) {
      detail = body['error']?.toString() ?? body['detail']?.toString();
    }
    return CredentialException(
      detail ?? '$fallback: ${e.message ?? e.type.name}',
      statusCode: code,
    );
  }
}

class OAuthStartResponse {
  final String authUrl;
  final String state;
  final String provider;
  final List<String> scopes;

  const OAuthStartResponse({
    required this.authUrl,
    required this.state,
    required this.provider,
    this.scopes = const [],
  });

  factory OAuthStartResponse.fromJson(Map<String, dynamic> j) =>
      OAuthStartResponse(
        authUrl: j['auth_url'] as String? ?? '',
        state: j['state'] as String? ?? '',
        provider: j['provider'] as String? ?? '',
        scopes: (j['scopes'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

class OAuthStatus {
  /// pending | connected | error | expired | timeout
  final String status;
  final String? credentialId;
  final String? error;

  const OAuthStatus({required this.status, this.credentialId, this.error});

  factory OAuthStatus.fromJson(Map<String, dynamic> j) => OAuthStatus(
        status: j['status'] as String? ?? 'pending',
        credentialId: j['credential_id'] as String?,
        error: j['error'] as String?,
      );
}

class McpStatus {
  final String provider;
  final bool running;
  final String status;
  final int toolsCount;
  final String? lastError;
  final String transportType;

  const McpStatus({
    required this.provider,
    required this.running,
    required this.status,
    this.toolsCount = 0,
    this.lastError,
    this.transportType = 'stdio',
  });

  static const stopped = McpStatus(
    provider: '',
    running: false,
    status: 'stopped',
  );

  factory McpStatus.fromJson(Map<String, dynamic> j) => McpStatus(
        provider: j['provider'] as String? ?? '',
        running: j['running'] == true,
        status: j['status'] as String? ?? 'stopped',
        toolsCount: (j['tools_count'] as num?)?.toInt() ?? 0,
        lastError: j['last_error'] as String?,
        transportType: j['transport_type'] as String? ?? 'stdio',
      );
}
