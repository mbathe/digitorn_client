/// Wrapper around every `/api/credentials*` route on the unified
/// credential model. Distinct from the older [CredentialService]
/// which still serves the legacy per-app form and the OAuth flow
/// endpoints (we keep that one alive for OAuth start/poll only).
///
/// All errors surface as [CredV2Exception] with the HTTP status
/// code and the daemon's `error.detail` string when present.
library;

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';

import '../models/credential_v2.dart';
import 'auth_service.dart';

class CredV2Exception implements Exception {
  final String message;
  final int? statusCode;
  const CredV2Exception(this.message, {this.statusCode});
  @override
  String toString() => 'CredV2Exception($statusCode): $message';
}

class CredentialsV2Service extends ChangeNotifier {
  static final CredentialsV2Service _i = CredentialsV2Service._();
  factory CredentialsV2Service() => _i;
  CredentialsV2Service._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    sendTimeout: const Duration(seconds: 12),
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // Local cache so multiple consumers don't refetch on every
  // build. Refreshed by [list()] and any mutation.
  List<CredentialV2> _cache = const [];
  List<CredentialV2> get cache => List.unmodifiable(_cache);

  // ── Required secrets (pre-session gate) ───────────────────────────

  /// `GET /api/apps/{app_id}/required-secrets` — returns every secret
  /// the app declares (via `{{secret.FOO}}` references in its YAML),
  /// whether each is already set for the current user, and which
  /// credential provider maps to it.
  ///
  /// The response is the source of truth for the pre-session gate:
  /// `missing_count > 0` means the app cannot start until the user
  /// fills / grants those secrets.
  ///
  /// Falls back gracefully when the route isn't deployed (404 / 501)
  /// — we return an empty info so older daemons still work, the user
  /// just won't get the pre-session dialog.
  Future<RequiredSecretsInfo> fetchRequiredSecrets(String appId) async {
    try {
      final r = await _dio.get(
        '$_base/api/apps/$appId/required-secrets',
      );
      if (r.statusCode == 404 || r.statusCode == 501) {
        return const RequiredSecretsInfo(missingCount: 0, secrets: []);
      }
      final body = r.data;
      if (body is Map && body['success'] == false) {
        final err = body['error']?.toString() ??
            'credentials.svc_required_secrets_failed'.tr();
        // 404 for non-deployed app bubbles up as success:false
        if (r.statusCode == 404) {
          throw CredV2Exception(err, statusCode: 404);
        }
        return const RequiredSecretsInfo(missingCount: 0, secrets: []);
      }
      final data = _unwrap(r) ?? const <String, dynamic>{};
      return RequiredSecretsInfo.fromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 || e.response?.statusCode == 501) {
        return const RequiredSecretsInfo(missingCount: 0, secrets: []);
      }
      throw _wrap(e, 'credentials.svc_fetch_required_secrets_failed'.tr());
    }
  }

  // ── Credentials CRUD ──────────────────────────────────────────────

  /// `GET /api/credentials` — list every credential the caller owns
  /// + every system credential they're allowed to see.
  Future<List<CredentialV2>> list({String? provider}) async {
    try {
      final r = await _dio.get(
        '$_base/api/credentials',
        queryParameters: {'provider': ?provider},
      );
      final data = _unwrap(r);
      final list = (data?['credentials'] as List? ??
              data?['entries'] as List? ??
              const [])
          .whereType<Map>()
          .map((e) => CredentialV2.fromJson(e.cast<String, dynamic>()))
          .toList();
      _cache = list;
      notifyListeners();
      return list;
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_load_failed'.tr());
    }
  }

  /// `GET /api/credentials/{id}` — single credential, no plaintext.
  Future<CredentialV2?> get(String id) async {
    try {
      final r = await _dio.get('$_base/api/credentials/$id');
      final data = _unwrap(r);
      if (data == null) return null;
      return CredentialV2.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_load_single_failed'.tr());
    }
  }

  /// `POST /api/credentials` — create a new one. [fields] holds the
  /// secret values the user just typed; the daemon returns the
  /// stored credential with masked previews only.
  Future<CredentialV2> create({
    required String providerName,
    required String providerType,
    String label = '',
    Map<String, dynamic> fields = const {},
  }) async {
    debugPrint('[credsv2] POST /api/credentials '
        'provider=$providerName type=$providerType '
        'field_keys=${fields.keys.toList()} label=$label');
    try {
      final r = await _dio.post(
        '$_base/api/credentials',
        data: {
          'provider_name': providerName,
          'provider_type': providerType,
          'label': label,
          'fields': fields,
        },
      );
      debugPrint('[credsv2] ← create HTTP ${r.statusCode} body=${r.data}');
      final data = _unwrap(r);
      if (data == null) {
        throw CredV2Exception('credentials.svc_empty_create_response'.tr());
      }
      final cred = CredentialV2.fromJson(data);
      _cache = [..._cache, cred];
      notifyListeners();
      return cred;
    } on DioException catch (e) {
      debugPrint('[credsv2] DioException create: ${e.message} '
          'status=${e.response?.statusCode} body=${e.response?.data}');
      throw _wrap(e, 'credentials.svc_create_failed'.tr());
    }
  }

  /// Test a credential without persisting it. The daemon runs the
  /// provider-specific probe recipe (e.g. `GET /v1/models` for
  /// OpenAI) and returns `{ok, detail, latency_ms}`. Used by the
  /// "Test connection" button in the create form so the user
  /// validates the key before saving.
  Future<Map<String, dynamic>> testFields({
    required String providerName,
    required String providerType,
    required Map<String, dynamic> fields,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/credentials/test',
        data: {
          'provider_name': providerName,
          'provider_type': providerType,
          'fields': fields,
        },
      );
      final data = _unwrap(r) ?? <String, dynamic>{};
      return {
        'ok': data['ok'] ?? (r.statusCode == 200),
        'detail': data['detail'] ?? data['error'] ?? '',
        'latency_ms': data['latency_ms'],
      };
    } on DioException catch (e) {
      final err = _wrap(e, 'credentials.svc_test_failed'.tr());
      return {'ok': false, 'detail': err.message};
    }
  }

  /// Re-test an existing credential by id. Daemon uses its stored
  /// plaintext to run the probe recipe.
  Future<Map<String, dynamic>> testExisting(String id) async {
    try {
      final r = await _dio.post('$_base/api/credentials/$id/test');
      final data = _unwrap(r) ?? <String, dynamic>{};
      return {
        'ok': data['ok'] ?? (r.statusCode == 200),
        'detail': data['detail'] ?? data['error'] ?? '',
        'latency_ms': data['latency_ms'],
      };
    } on DioException catch (e) {
      return {
        'ok': false,
        'detail': _wrap(e, 'credentials.svc_test_failed'.tr()).message
      };
    }
  }

  /// Kick off a user-scoped OAuth flow for the new unified credential
  /// model. Returns `{auth_url, state}` — the client opens the URL
  /// and the daemon handles the provider callback, dropping the
  /// resulting credential into the vault.
  ///
  /// Tries two route shapes in order (compat across daemon
  /// generations):
  ///   1. `POST /api/credentials/oauth/start` with
  ///      `{provider_name, label}` in the body
  ///   2. `GET /api/credentials/oauth/{providerName}/start`
  Future<Map<String, dynamic>?> startUserOauth({
    required String providerName,
    String label = 'default',
  }) async {
    // Route 1 — POST body (new v2).
    try {
      final r = await _dio.post(
        '$_base/api/credentials/oauth/start',
        data: {
          'provider_name': providerName,
          'label': label,
        },
      );
      final code = r.statusCode ?? 0;
      if (code != 404 && code != 405 && code != 501) {
        return _unwrap(r);
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (code != 404 && code != 405 && code != 501) {
        throw _wrap(e, 'credentials.svc_oauth_start_failed'.tr());
      }
    }
    // Route 2 — GET with path param (spec variant).
    try {
      final r = await _dio.get(
        '$_base/api/credentials/oauth/$providerName/start',
      );
      return _unwrap(r);
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_oauth_start_failed'.tr());
    }
  }

  /// Poll the OAuth flow status. Tries both route shapes and
  /// returns a `{status, error?}` map. `status` is one of
  /// `pending`, `connected`, `failed`.
  Future<Map<String, dynamic>> pollOauthStatus({
    required String providerName,
    required String state,
  }) async {
    // Route 1 — POST body.
    try {
      final r = await _dio.get(
        '$_base/api/credentials/oauth/status',
        queryParameters: {'state': state, 'provider_name': providerName},
      );
      final code = r.statusCode ?? 0;
      if (code != 404 && code != 405 && code != 501) {
        return _unwrap(r) ?? {'status': 'pending'};
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (code != 404 && code != 405 && code != 501) {
        throw _wrap(e, 'credentials.svc_oauth_status_failed'.tr());
      }
    }
    // Route 2 — path param.
    try {
      final r = await _dio.get(
        '$_base/api/credentials/oauth/$providerName/status',
        queryParameters: {'state': state},
      );
      return _unwrap(r) ?? {'status': 'pending'};
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_oauth_status_failed'.tr());
    }
  }

  // ── MCP lifecycle tied to a user credential ──────────────────
  //
  // MCP servers whose auth is an OAuth flow or a per-user token are
  // bound to the user's credential, not to the app. The three
  // methods below start / stop / inspect the live MCP subprocess
  // from that credential row — so the resulting OAuth token lives
  // in the user's credential vault, never as a machine-scope admin
  // override.
  //
  // Routes (scout-verified):
  //   POST /api/users/me/credentials/{app_id}/{provider}/mcp/start
  //   POST /api/users/me/credentials/{app_id}/{provider}/mcp/stop
  //   GET  /api/users/me/credentials/{app_id}/{provider}/mcp/status

  String _mcpBase(String appId, String providerName) =>
      '$_base/api/users/me/credentials/$appId/'
      '${Uri.encodeComponent(providerName)}/mcp';

  /// Start (or restart) the MCP server backed by the user's
  /// credential for [providerName] inside [appId]. Returns
  /// `{started, provider}` on success, null on failure.
  Future<Map<String, dynamic>?> startMcp(
      String appId, String providerName) async {
    try {
      final r = await _dio.post('${_mcpBase(appId, providerName)}/start',
          data: const {});
      return _unwrap(r);
    } on DioException catch (e) {
      debugPrint('CredentialsV2.startMcp: $e');
      return null;
    }
  }

  /// Stop the MCP server but keep the credential intact.
  Future<bool> stopMcp(String appId, String providerName) async {
    try {
      final r = await _dio.post('${_mcpBase(appId, providerName)}/stop',
          data: const {});
      return (r.statusCode ?? 0) == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } on DioException catch (e) {
      debugPrint('CredentialsV2.stopMcp: $e');
      return false;
    }
  }

  /// Snapshot `{provider, running, status, tools_count, last_error}`
  /// for a user's MCP server. Null when the route is missing (old
  /// daemons) or the credential doesn't exist.
  Future<Map<String, dynamic>?> statusMcp(
      String appId, String providerName) async {
    try {
      final r = await _dio.get('${_mcpBase(appId, providerName)}/status');
      return _unwrap(r);
    } on DioException catch (e) {
      debugPrint('CredentialsV2.statusMcp: $e');
      return null;
    }
  }

  /// `PUT /api/credentials/{id}` — update label and/or fields.
  Future<CredentialV2> update(
    String id, {
    String? label,
    Map<String, dynamic>? fields,
  }) async {
    try {
      final r = await _dio.put(
        '$_base/api/credentials/$id',
        data: {
          'label': ?label,
          'fields': ?fields,
        },
      );
      final data = _unwrap(r);
      if (data == null) {
        throw CredV2Exception('credentials.svc_empty_update_response'.tr());
      }
      final cred = CredentialV2.fromJson(data);
      _cache = [
        for (final c in _cache) c.id == id ? cred : c,
      ];
      notifyListeners();
      return cred;
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_update_failed'.tr());
    }
  }

  /// `DELETE /api/credentials/{id}` — hard delete, cascades grants.
  Future<void> delete(String id) async {
    try {
      final r = await _dio.delete('$_base/api/credentials/$id');
      _checkSuccess(r);
      _cache = _cache.where((c) => c.id != id).toList();
      notifyListeners();
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_delete_failed'.tr());
    }
  }

  // ── Grants ────────────────────────────────────────────────────────

  /// `GET /api/credentials/{id}/grants` — apps using this credential.
  Future<List<CredentialGrant>> listGrants(String credentialId) async {
    try {
      final r = await _dio
          .get('$_base/api/credentials/$credentialId/grants');
      final data = _unwrap(r);
      final list = (data?['grants'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => CredentialGrant.fromJson(m.cast<String, dynamic>()))
          .toList();
      return list;
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_list_grants_failed'.tr());
    }
  }

  /// `POST /api/credentials/{id}/grant` — authorize an app.
  ///
  /// The daemon accepts both `/grant` (current) and `/grants`
  /// (legacy) — we try the current one first and fall back on
  /// 404/405/501 so the client remains compatible with both
  /// daemon generations.
  Future<void> grant({
    required String credentialId,
    required String appId,
    List<String> scopesGranted = const [],
  }) async {
    final body = {
      'app_id': appId,
      if (scopesGranted.isNotEmpty) 'scopes_granted': scopesGranted,
    };
    debugPrint('[credsv2] POST /api/credentials/$credentialId/grant '
        'app=$appId');
    // Try the singular route first (new daemon).
    try {
      final r = await _dio.post(
        '$_base/api/credentials/$credentialId/grant',
        data: body,
      );
      final code = r.statusCode ?? 0;
      debugPrint('[credsv2] ← grant(singular) HTTP $code body=${r.data}');
      if (code >= 400 && (code == 404 || code == 405 || code == 501)) {
        // Fallthrough to legacy route.
        debugPrint('[credsv2] → falling back to /grants (plural)');
      } else {
        _checkSuccess(r);
        return;
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      debugPrint('[credsv2] DioException grant(singular): ${e.message} '
          'status=$code body=${e.response?.data}');
      if (code != 404 && code != 405 && code != 501) {
        throw _wrap(e, 'credentials.svc_grant_failed'.tr());
      }
    }
    // Legacy plural fallback.
    try {
      final r = await _dio.post(
        '$_base/api/credentials/$credentialId/grants',
        data: body,
      );
      debugPrint('[credsv2] ← grant(plural) HTTP ${r.statusCode} body=${r.data}');
      _checkSuccess(r);
    } on DioException catch (e) {
      debugPrint('[credsv2] DioException grant(plural): ${e.message} '
          'status=${e.response?.statusCode} body=${e.response?.data}');
      throw _wrap(e, 'credentials.svc_grant_failed'.tr());
    }
  }

  /// `DELETE /api/credentials/{id}/grant/{app_id}` — revoke (soft).
  /// Same dual-route story as [grant].
  Future<void> revoke({
    required String credentialId,
    required String appId,
    bool hard = false,
  }) async {
    final qp = {'hard': ?(hard ? 'true' : null)};
    try {
      final r = await _dio.delete(
        '$_base/api/credentials/$credentialId/grant/$appId',
        queryParameters: qp,
      );
      final code = r.statusCode ?? 0;
      if (code == 404 || code == 405 || code == 501) {
        // Fallthrough.
      } else {
        _checkSuccess(r);
        return;
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (code != 404 && code != 405 && code != 501) {
        throw _wrap(e, 'credentials.svc_revoke_internal_failed'.tr());
      }
    }
    try {
      final r = await _dio.delete(
        '$_base/api/credentials/$credentialId/grants/$appId',
        queryParameters: qp,
      );
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_revoke_internal_failed'.tr());
    }
  }

  /// `GET /api/credentials-grants` — every grant the user has
  /// across all credentials. Used by the App permissions view.
  Future<List<CredentialGrant>> listAllGrants() async {
    try {
      final r = await _dio.get('$_base/api/credentials-grants');
      final data = _unwrap(r);
      final list = (data?['grants'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => CredentialGrant.fromJson(m.cast<String, dynamic>()))
          .toList();
      return list;
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_list_grants_failed'.tr());
    }
  }

  // ── Admin (system credentials) ────────────────────────────────────
  //
  // These three endpoints are gated by `credentials.admin` or `*`
  // permissions on the daemon. Calls from a non-admin user return
  // 403 — the UI hides the surface in that case.

  /// `GET /api/admin/credentials` — list every system credential the
  /// caller can see. System creds are visible to every app the
  /// daemon serves, so they only show up in the admin view.
  Future<List<CredentialV2>> listSystem() async {
    try {
      final r = await _dio.get('$_base/api/admin/credentials');
      final data = _unwrap(r);
      final list = (data?['credentials'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => CredentialV2.fromJson(e.cast<String, dynamic>()))
          .toList();
      return list;
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_list_system_failed'.tr());
    }
  }

  /// `POST /api/admin/credentials` — create a system credential.
  /// When [appId] is null the credential is implicitly visible to
  /// every app; when set, it's restricted to that one app.
  Future<CredentialV2> createSystem({
    required String providerName,
    required String providerType,
    String label = '',
    String? appId,
    Map<String, dynamic> fields = const {},
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/admin/credentials',
        data: {
          'provider_name': providerName,
          'provider_type': providerType,
          'label': label,
          'app_id': ?appId,
          'fields': fields,
        },
      );
      final data = _unwrap(r);
      if (data == null) {
        throw CredV2Exception(
            'credentials.svc_empty_admin_create_response'.tr());
      }
      return CredentialV2.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_create_system_failed'.tr());
    }
  }

  /// `DELETE /api/admin/credentials/{id}` — delete a system cred.
  Future<void> deleteSystem(String id) async {
    try {
      final r = await _dio.delete('$_base/api/admin/credentials/$id');
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'credentials.svc_delete_system_failed'.tr());
    }
  }

  // ── Provider catalogue ────────────────────────────────────────────

  /// Cached provider catalogue from `/api/credentials/providers`.
  /// Static (no expiry) — the daemon serves a fixed list of 25
  /// well-known providers, refreshing it on every settings open is
  /// pointless.
  List<ProviderCatalogueEntry> _providerCache = const [];
  bool _providerLoaded = false;

  /// Synchronous accessor — returns the cache, falls back to the
  /// hardcoded list if the daemon hasn't been hit yet.
  List<ProviderCatalogueEntry> get cachedProviders =>
      _providerLoaded ? _providerCache : catalogue;

  /// Hits `GET /api/credentials/providers` and caches the result for
  /// the rest of the app session. Safe to call multiple times.
  Future<List<ProviderCatalogueEntry>> loadProviders({
    bool force = false,
  }) async {
    if (_providerLoaded && !force) return _providerCache;
    try {
      final r = await _dio.get('$_base/api/credentials/providers');
      // 404 / 501 / "success: false" all mean "route not deployed" —
      // fall back to the hardcoded catalogue so the picker keeps
      // working regardless of daemon generation.
      if (r.statusCode == 404 || r.statusCode == 501) {
        _providerLoaded = true;
        _providerCache = catalogue;
        notifyListeners();
        return catalogue;
      }
      final body = r.data;
      if (body is Map && body['success'] == false) {
        _providerLoaded = true;
        _providerCache = catalogue;
        notifyListeners();
        return catalogue;
      }
      final data = _unwrap(r);
      final raw = data?['providers'] as List? ?? const [];
      if (raw.isEmpty) {
        _providerLoaded = true;
        _providerCache = catalogue;
        notifyListeners();
        return catalogue;
      }
      final parsed = raw
          .whereType<Map>()
          .map((m) =>
              _providerEntryFromDaemon(m.cast<String, dynamic>()))
          .toList();
      _providerCache = parsed;
      _providerLoaded = true;
      notifyListeners();
      return parsed;
    } catch (e) {
      // Catch everything — DioException, CredV2Exception, whatever.
      // A broken provider route must never break the picker.
      debugPrint('loadProviders fallback: $e');
      _providerLoaded = true;
      _providerCache = catalogue;
      notifyListeners();
      return catalogue;
    }
  }

  /// Converts the daemon's `/credentials/providers` payload into the
  /// existing [ProviderCatalogueEntry] shape. The daemon doesn't
  /// expose `fields` per-provider — only their names — so we reuse
  /// the local field-spec table for known providers and synthesise
  /// a single `secret` field for the unknown ones.
  ProviderCatalogueEntry _providerEntryFromDaemon(Map<String, dynamic> j) {
    final name = j['id'] as String? ?? j['name'] as String? ?? '';
    final type = j['type'] as String? ?? 'api_key';
    final label = j['display_name'] as String? ??
        j['label'] as String? ??
        name;
    // Try to find a richer spec in the local catalogue (gives us
    // labels + placeholders for the well-known fields).
    ProviderCatalogueEntry? known;
    for (final c in catalogue) {
      if (c.name == name) {
        known = c;
        break;
      }
    }
    final fieldNames = (j['fields'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final fields = <ProviderFieldSpec>[];
    if (known != null && known.fields.isNotEmpty) {
      // Filter the local catalogue's fields to whichever ones the
      // daemon declared (in case the daemon dropped one).
      for (final f in known.fields) {
        if (fieldNames.isEmpty || fieldNames.any(
            (n) => n.toLowerCase() == f.name.toLowerCase() ||
                f.name.toLowerCase().contains(n.toLowerCase()))) {
          fields.add(f);
        }
      }
      if (fields.isEmpty) fields.addAll(known.fields);
    } else {
      // Synthesise one secret per declared field name.
      for (final fname in fieldNames) {
        fields.add(ProviderFieldSpec(
          name: fname,
          type: 'secret',
          label: _humaniseFieldName(fname),
          required: true,
        ));
      }
      if (fields.isEmpty && type == 'api_key') {
        fields.add(const ProviderFieldSpec(
          name: 'api_key',
          type: 'secret',
          label: 'API key',
          required: true,
        ));
      }
    }
    return ProviderCatalogueEntry(
      name: name,
      label: label,
      type: type,
      fields: fields,
      docsUrl: j['docs_url'] as String?,
    );
  }

  static String _humaniseFieldName(String n) {
    if (n.isEmpty) return n;
    return n
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .split(' ')
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  /// Static fallback catalogue of providers we know how to render
  /// forms for. Used when the daemon hasn't been called yet, or as
  /// the source of field metadata when [loadProviders] returns a
  /// thinner shape.
  static const List<ProviderCatalogueEntry> catalogue = [
    ProviderCatalogueEntry(
      name: 'openai',
      label: 'OpenAI',
      type: 'api_key',
      fields: [
        ProviderFieldSpec(
          name: 'OPENAI_API_KEY',
          type: 'secret',
          label: 'API key',
          required: true,
          placeholder: 'sk-...',
          docsUrl: 'https://platform.openai.com/api-keys',
        ),
        ProviderFieldSpec(
          name: 'OPENAI_ORG_ID',
          type: 'string',
          label: 'Organization (optional)',
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'anthropic',
      label: 'Anthropic',
      type: 'api_key',
      fields: [
        ProviderFieldSpec(
          name: 'ANTHROPIC_API_KEY',
          type: 'secret',
          label: 'API key',
          required: true,
          placeholder: 'sk-ant-...',
          docsUrl: 'https://console.anthropic.com/account/keys',
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'deepseek',
      label: 'DeepSeek',
      type: 'api_key',
      fields: [
        ProviderFieldSpec(
          name: 'DEEPSEEK_API_KEY',
          type: 'secret',
          label: 'API key',
          required: true,
          placeholder: 'sk-...',
          docsUrl: 'https://platform.deepseek.com/api_keys',
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'serpapi',
      label: 'SerpAPI',
      type: 'api_key',
      fields: [
        ProviderFieldSpec(
          name: 'SERPAPI_KEY',
          type: 'secret',
          label: 'API key',
          required: true,
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'github',
      label: 'GitHub',
      type: 'api_key',
      fields: [
        ProviderFieldSpec(
          name: 'GITHUB_TOKEN',
          type: 'secret',
          label: 'Personal access token',
          required: true,
          docsUrl: 'https://github.com/settings/tokens',
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'telegram',
      label: 'Telegram bot',
      type: 'api_key',
      fields: [
        ProviderFieldSpec(
          name: 'TELEGRAM_BOT_TOKEN',
          type: 'secret',
          label: 'Bot token',
          required: true,
          description: 'From @BotFather',
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'slack',
      label: 'Slack',
      type: 'multi_field',
      fields: [
        ProviderFieldSpec(
          name: 'SLACK_BOT_TOKEN',
          type: 'secret',
          label: 'Bot token',
          required: true,
        ),
        ProviderFieldSpec(
          name: 'SLACK_SIGNING_SECRET',
          type: 'secret',
          label: 'Signing secret',
        ),
      ],
    ),
    ProviderCatalogueEntry(
      name: 'notion',
      label: 'Notion',
      type: 'oauth2',
    ),
    ProviderCatalogueEntry(
      name: 'gmail',
      label: 'Gmail',
      type: 'oauth2',
    ),
  ];

  // ── Helpers ───────────────────────────────────────────────────────

  Map<String, dynamic>? _unwrap(Response r) {
    // Reject HTTP error codes loud — otherwise a 400/403/404 with a
    // non-envelope body silently looks like success and the caller
    // thinks the credential was saved when it wasn't.
    final code = r.statusCode ?? 0;
    final body = r.data;
    if (code >= 400) {
      String message = 'HTTP $code';
      if (body is Map) {
        message = body['error']?.toString() ??
            body['detail']?.toString() ??
            body['message']?.toString() ??
            message;
      } else if (body is String && body.isNotEmpty) {
        message = body;
      }
      throw CredV2Exception(message, statusCode: code);
    }
    if (body is! Map) return null;
    if (body['success'] == false) {
      final err =
          body['error']?.toString() ?? 'credentials.svc_unknown_error'.tr();
      throw CredV2Exception(err, statusCode: r.statusCode);
    }
    final data = body['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is List) return {'credentials': data};
    return null;
  }

  void _checkSuccess(Response r) {
    final code = r.statusCode ?? 0;
    final body = r.data;
    if (code >= 400) {
      String message = 'HTTP $code';
      if (body is Map) {
        message = body['error']?.toString() ??
            body['detail']?.toString() ??
            body['message']?.toString() ??
            message;
      } else if (body is String && body.isNotEmpty) {
        message = body;
      }
      throw CredV2Exception(message, statusCode: code);
    }
    if (body is Map && body['success'] == false) {
      final err =
          body['error']?.toString() ?? 'credentials.svc_unknown_error'.tr();
      throw CredV2Exception(err, statusCode: r.statusCode);
    }
  }

  CredV2Exception _wrap(DioException e, String fallback) {
    String? detail;
    final body = e.response?.data;
    if (body is Map) {
      detail = body['error']?.toString() ?? body['detail']?.toString();
    }
    return CredV2Exception(
      detail ?? '$fallback: ${e.message ?? e.type.name}',
      statusCode: e.response?.statusCode,
    );
  }
}
