/// Per-app admin actions: quota management, secrets CRUD, OAuth
/// flows, MCP OAuth tokens, approvals management, required-secrets.
///
/// These routes exist in two near-identical namespaces: the
/// **owner-scope** (`/api/apps/{id}/…`) reachable by any app
/// owner, and the **admin-scope** (`/api/admin/{id}/…`) reserved
/// for global admin users. Both are covered here — the UI decides
/// which to call based on the current user's role.
///
/// Scout audit 2026-04-20 coverage:
///   * GET/PUT/DELETE /apps/{id}/quota
///   * GET/PUT/DELETE /apps/{id}/quota/user/{uid}
///   * GET/PUT/DELETE /apps/{id}/secrets, /secrets/{key}, bulk PUT
///   * GET            /apps/{id}/required-secrets
///   * GET            /apps/{id}/oauth/authorize
///   * GET            /apps/{id}/oauth/callback  (browser-side)
///   * GET            /apps/{id}/mcp/pending-oauth
///   * POST/DELETE    /apps/{id}/mcp/{server}/oauth-token
///   * GET            /apps/{id}/approvals         (list pending)
///   * POST           /apps/{id}/approve           (resolve one)
///   * Same under /api/admin/{id}/...              (admin scope)
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/quota.dart';
import 'api_client.dart';

enum AdminScope {
  /// `/api/apps/{id}/...` — any owner of the app can call these.
  owner,

  /// `/api/admin/{id}/...` — require global admin privileges.
  admin,
}

class AppAdminService {
  AppAdminService._();
  static final AppAdminService _instance = AppAdminService._();
  factory AppAdminService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  String _scope(AdminScope s) => s == AdminScope.admin ? 'admin' : 'apps';

  Options _opts() => Options(
        validateStatus: (s) => s != null && s < 500 && s != 401,
        headers: const {'Content-Type': 'application/json'},
      );

  Map<String, dynamic>? _data(Response r) {
    if (r.statusCode != 200 || r.data is! Map) return null;
    if ((r.data as Map)['success'] != true) return null;
    return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
  }

  // ── Quota ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> getQuota(String appId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
          '/api/${_scope(scope)}/$appId/quota', options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Admin.getQuota: $e');
      return null;
    }
  }

  Future<bool> setQuota(
    String appId,
    Map<String, dynamic> quota, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.put(
        '/api/${_scope(scope)}/$appId/quota',
        data: quota,
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.setQuota: $e');
      return false;
    }
  }

  Future<bool> clearQuota(String appId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.delete(
          '/api/${_scope(scope)}/$appId/quota', options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.clearQuota: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getUserQuota(String appId, String userId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
          '/api/${_scope(scope)}/$appId/quota/user/'
          '${Uri.encodeComponent(userId)}',
          options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Admin.getUserQuota: $e');
      return null;
    }
  }

  Future<bool> setUserQuota(
    String appId,
    String userId,
    Map<String, dynamic> quota, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.put(
        '/api/${_scope(scope)}/$appId/quota/user/'
        '${Uri.encodeComponent(userId)}',
        data: quota,
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.setUserQuota: $e');
      return false;
    }
  }

  Future<bool> clearUserQuota(String appId, String userId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.delete(
          '/api/${_scope(scope)}/$appId/quota/user/'
          '${Uri.encodeComponent(userId)}',
          options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.clearUserQuota: $e');
      return false;
    }
  }

  // ── Typed quota API (2026-04 spec, live-validated) ──────────────
  //
  // These complement the legacy Map-based methods above. The daemon
  // accepts BOTH shapes on PUT (wrapped `{"quota": {...}}` and the
  // bare map), but the wrapped form is what the 2026-04 spec
  // documents, and responses always come wrapped. Use the typed
  // methods for new code — the old Map-based ones stay for back-
  // compat with [AdminQuotaDialog].

  /// Self-service — ANY authenticated user can read their own
  /// quota + current usage on an app. Used by the Settings → Quota
  /// view.
  Future<QuotaResponse?> getMyQuota(String appId) async {
    try {
      final r = await _dio.get(
        '/api/apps/$appId/quota/me',
        options: _opts(),
      );
      final data = _data(r);
      return data == null ? null : QuotaResponse.fromJson(data);
    } catch (e) {
      debugPrint('Admin.getMyQuota: $e');
      return null;
    }
  }

  Future<QuotaResponse?> getAppQuotaTyped(
    String appId, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.get(
        '/api/${_scope(scope)}/$appId/quota',
        options: _opts(),
      );
      final data = _data(r);
      return data == null ? null : QuotaResponse.fromJson(data);
    } catch (e) {
      debugPrint('Admin.getAppQuotaTyped: $e');
      return null;
    }
  }

  Future<QuotaResponse?> setAppQuotaTyped(
    String appId,
    QuotaDefinition definition, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.put(
        '/api/${_scope(scope)}/$appId/quota',
        data: {'quota': definition.toJson()},
        options: _opts(),
      );
      final data = _data(r);
      if (data == null) return null;
      return QuotaResponse.fromJson(data);
    } catch (e) {
      debugPrint('Admin.setAppQuotaTyped: $e');
      return null;
    }
  }

  Future<QuotaResponse?> getUserQuotaTyped(
    String appId,
    String userId, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.get(
        '/api/${_scope(scope)}/$appId/quota/user/'
        '${Uri.encodeComponent(userId)}',
        options: _opts(),
      );
      final data = _data(r);
      return data == null ? null : QuotaResponse.fromJson(data);
    } catch (e) {
      debugPrint('Admin.getUserQuotaTyped: $e');
      return null;
    }
  }

  Future<QuotaResponse?> setUserQuotaTyped(
    String appId,
    String userId,
    QuotaDefinition definition, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.put(
        '/api/${_scope(scope)}/$appId/quota/user/'
        '${Uri.encodeComponent(userId)}',
        data: {'quota': definition.toJson()},
        options: _opts(),
      );
      final data = _data(r);
      if (data == null) return null;
      return QuotaResponse.fromJson(data);
    } catch (e) {
      debugPrint('Admin.setUserQuotaTyped: $e');
      return null;
    }
  }

  // ── Secrets ───────────────────────────────────────────────────

  /// GET /apps/{id}/secrets — list secret KEYS (never values) with
  /// metadata (last-set-at, source, required flag).
  Future<List<Map<String, dynamic>>?> listSecrets(String appId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
          '/api/${_scope(scope)}/$appId/secrets', options: _opts());
      final d = _data(r);
      final raw = d?['secrets'] ?? d?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('Admin.listSecrets: $e');
      return null;
    }
  }

  /// PUT /apps/{id}/secrets/{key} — upsert a single secret value.
  Future<bool> setSecret(String appId, String key, String value,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.put(
        '/api/${_scope(scope)}/$appId/secrets/'
        '${Uri.encodeComponent(key)}',
        data: {'value': value},
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.setSecret: $e');
      return false;
    }
  }

  /// PUT /apps/{id}/secrets — bulk upsert `{key: value, …}`.
  Future<bool> setSecretsBulk(String appId, Map<String, String> secrets,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.put(
        '/api/${_scope(scope)}/$appId/secrets',
        data: {'secrets': secrets},
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.setSecretsBulk: $e');
      return false;
    }
  }

  /// DELETE /apps/{id}/secrets/{key}.
  Future<bool> deleteSecret(String appId, String key,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.delete(
        '/api/${_scope(scope)}/$appId/secrets/'
        '${Uri.encodeComponent(key)}',
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.deleteSecret: $e');
      return false;
    }
  }

  /// GET /apps/{id}/required-secrets — secrets the daemon needs
  /// before the app can serve traffic. UI uses this to drive the
  /// pre-session credentials picker.
  Future<Map<String, dynamic>?> requiredSecrets(String appId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
          '/api/${_scope(scope)}/$appId/required-secrets',
          options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Admin.requiredSecrets: $e');
      return null;
    }
  }

  // ── OAuth flow ────────────────────────────────────────────────

  /// GET /apps/{id}/oauth/authorize — returns the authorize URL the
  /// client opens in an external browser. The callback lands on the
  /// daemon and closes the loop.
  Future<Map<String, dynamic>?> oauthAuthorize(String appId,
      {String? provider, AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
        '/api/${_scope(scope)}/$appId/oauth/authorize',
        queryParameters: {'provider': ?provider},
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Admin.oauthAuthorize: $e');
      return null;
    }
  }

  // ── MCP OAuth (admin override — NOT the normal path) ────────
  //
  // The canonical MCP OAuth flow is user-scoped and lives in
  // [CredentialsV2Service.startMcp / stopMcp / statusMcp]. Those
  // hit `/api/credentials/users/me/credentials/{app_id}/{provider}
  // /mcp/...` so the OAuth token is stored inside the user's own
  // credential vault, which matters for multi-user deployments.
  //
  // The three methods below exist for the rare case where an admin
  // has to inject a machine-scope token manually (e.g. when a
  // user's account is locked and their MCP server needs to keep
  // running). Don't surface them in the normal settings UI.
  Future<Map<String, dynamic>?> mcpPendingOauth(String appId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
          '/api/${_scope(scope)}/$appId/mcp/pending-oauth',
          options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Admin.mcpPendingOauth: $e');
      return null;
    }
  }

  Future<bool> mcpSetOauthToken(
    String appId,
    String serverId,
    String token, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.post(
        '/api/${_scope(scope)}/$appId/mcp/'
        '${Uri.encodeComponent(serverId)}/oauth-token',
        data: {'token': token},
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.mcpSetOauthToken: $e');
      return false;
    }
  }

  Future<bool> mcpDeleteOauthToken(
    String appId,
    String serverId, {
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.delete(
        '/api/${_scope(scope)}/$appId/mcp/'
        '${Uri.encodeComponent(serverId)}/oauth-token',
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.mcpDeleteOauthToken: $e');
      return false;
    }
  }

  // ── Approvals (admin-scope sees global pending) ───────────────

  Future<List<Map<String, dynamic>>?> listApprovals(String appId,
      {AdminScope scope = AdminScope.owner}) async {
    try {
      final r = await _dio.get(
          '/api/${_scope(scope)}/$appId/approvals',
          options: _opts());
      final d = _data(r);
      final raw = d?['approvals'] ?? d?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('Admin.listApprovals: $e');
      return null;
    }
  }

  Future<bool> resolveApproval(
    String appId, {
    required String requestId,
    required bool approved,
    String? reason,
    AdminScope scope = AdminScope.owner,
  }) async {
    try {
      final r = await _dio.post(
        '/api/${_scope(scope)}/$appId/approve',
        data: {
          'request_id': requestId,
          'approved': approved,
          'reason': ?reason,
        },
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.resolveApproval: $e');
      return false;
    }
  }

  // ── Admin-only: delete / enable / disable / reload ──────────

  /// DELETE /api/admin/{id} — global admin wipe.
  Future<bool> adminDeleteApp(String appId) async {
    try {
      final r = await _dio.delete('/api/admin/$appId', options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Admin.adminDeleteApp: $e');
      return false;
    }
  }
}
