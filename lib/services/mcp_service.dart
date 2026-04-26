/// Wrapper around the daemon's MCP server registry. Talks to the
/// real routes exposed by the Digitorn daemon:
///
///   GET    /api/mcp/catalog              — discoverable servers
///   GET    /api/mcp/catalog/{id}         — full detail w/ README
///   GET    /api/mcp/servers              — installed servers
///   GET    /api/mcp/servers/{id}
///   POST   /api/mcp/servers              { name, command, args, env }
///   DELETE /api/mcp/servers/{id}
///   POST   /api/mcp/servers/{id}/start
///   POST   /api/mcp/servers/{id}/stop
///   POST   /api/mcp/servers/{id}/test    — probe tool listing
///   GET    /api/mcp/servers/{id}/status
///   GET    /api/mcp/servers/{id}/tools
///   POST   /api/mcp/oauth/start          { provider, entry_id }
///   POST   /api/mcp/oauth/callback       { state, code }
///
/// `/catalogue` (plural, old) is accepted as a fallback for v1
/// daemons that haven't migrated yet — if both return 404 we flip
/// [stubbed] and the UI falls back to the bundled catalogue.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/mcp_server.dart';
import 'auth_service.dart';
import 'cache/swr_cache.dart';

class McpException implements Exception {
  final String message;
  final int? statusCode;
  const McpException(this.message, {this.statusCode});
  @override
  String toString() => 'McpException($statusCode): $message';
}

class McpService extends ChangeNotifier {
  static final McpService _i = McpService._();
  factory McpService() => _i;
  McpService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    sendTimeout: const Duration(seconds: 12),
    validateStatus: (s) => s != null && s < 500 && s != 401,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // Local cache so repeated tab opens don't trigger a refetch.
  List<McpServer> _servers = const [];
  List<McpServer> get servers => List.unmodifiable(_servers);

  /// True when the daemon doesn't expose MCP routes yet — the
  /// store falls back to the hardcoded catalogue and disables
  /// install actions in that case.
  bool stubbed = false;

  // ── Catalog ───────────────────────────────────────────────────────
  //
  // The daemon's discoverable catalog lives at `/api/mcp/catalog`
  // (singular). Older daemons used the plural `/catalogue` path —
  // we try the new one first and fall back once so a client can
  // transparently work against both generations.

  /// The MCP catalog is static for the lifetime of the daemon build
  /// (new MCP servers only appear on daemon upgrade). 10-minute SWR
  /// is comfortable — any freshness issues resolve on the next tick.
  final SwrCache<String, List<McpCatalogueEntry>> _catalogCache = SwrCache(
    ttl: const Duration(minutes: 10),
    name: 'mcp_catalog',
  );

  Future<List<McpCatalogueEntry>> listCatalog() async {
    return _catalogCache.getOrFetch(
      key: 'catalog',
      fetcher: _fetchCatalogOnce,
      onRevalidated: (fresh) => notifyListeners(),
    );
  }

  Future<List<McpCatalogueEntry>> _fetchCatalogOnce() async {
    for (final path in ['/api/mcp/catalog', '/api/mcp/catalogue']) {
      try {
        final r = await _dio.get('$_base$path');
        if (r.statusCode == 404 || r.statusCode == 501) continue;
        stubbed = false;
        final body = r.data;
        if (body is! Map) return const [];
        final list = body['data']?['catalog'] as List? ??
            body['data']?['catalogue'] as List? ??
            body['catalog'] as List? ??
            body['catalogue'] as List? ??
            const [];
        return list
            .whereType<Map>()
            .map((m) => _entryFromJson(m.cast<String, dynamic>()))
            .toList();
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 404 || code == 501) continue;
        // Real error — give up and report stubbed so UI falls back.
        stubbed = true;
        notifyListeners();
        return const [];
      }
    }
    stubbed = true;
    notifyListeners();
    return const [];
  }

  /// Fetch the full detail for a single catalog entry. This is the
  /// "detail-before-install" pattern: clicking an entry hits this
  /// route to pull README, OAuth provider, env mapping, and key
  /// descriptions, which then populate the install form.
  Future<McpCatalogueEntry?> getCatalogEntry(String id) async {
    for (final path in [
      '/api/mcp/catalog/$id',
      '/api/mcp/catalogue/$id',
    ]) {
      try {
        final r = await _dio.get('$_base$path');
        if (r.statusCode == 404 || r.statusCode == 501) continue;
        final data = _data(r);
        if (data == null) return null;
        return _entryFromJson(data);
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 404 || code == 501) continue;
        throw _wrap(e, 'Catalog detail fetch failed');
      }
    }
    return null;
  }

  /// Back-compat alias — older callers still reference the plural.
  Future<List<McpCatalogueEntry>> listCatalogue() => listCatalog();

  // ── OAuth — for catalog entries that use a hosted identity
  //    provider (Google, GitHub, Slack, Notion, etc.). Two-leg flow:
  //
  //    1. `startOAuth(entryId)` → returns `{auth_url, state}`. The
  //       client opens `auth_url` in the browser.
  //    2. Daemon handles the provider callback, exchanges the code
  //       for a token, stores it in the credential vault, and emits
  //       an `oauth.completed` user event that the UI listens for.
  //
  //    Clients that want to drive the exchange themselves can call
  //    `completeOAuth(state, code)` with the values they captured —
  //    useful for desktop deep-link handlers.

  /// Step 1 / 8 — kick off an OAuth session. Returns
  /// `{auth_url, state, session_id}`. The caller opens `auth_url`
  /// in a browser then polls [pollOAuthStatus] with `state` until
  /// it flips to `completed` or `failed`.
  Future<Map<String, dynamic>?> startOAuth(String entryId) async {
    try {
      final r = await _dio.post(
        '$_base/api/mcp/oauth/start',
        data: {'entry_id': entryId},
      );
      return _data(r);
    } on DioException catch (e) {
      throw _wrap(e, 'OAuth start failed');
    }
  }

  /// Step 5 / 8 — poll the status of an OAuth session.
  ///
  /// Returns `{status, credential_id?, server_id?, error?}` where
  /// `status` is one of `pending`, `completed`, `failed`, `timeout`.
  /// The client calls this every 2s with the `state` returned by
  /// [startOAuth] until `status != 'pending'`, then either finishes
  /// the install or surfaces the error.
  Future<Map<String, dynamic>?> pollOAuthStatus(String state) async {
    try {
      final r = await _dio.get(
        '$_base/api/mcp/oauth/status',
        queryParameters: {'state': state},
      );
      return _data(r);
    } on DioException catch (e) {
      // Don't throw on transient polling errors — return a dummy
      // pending so the caller keeps retrying.
      debugPrint('mcp oauth poll: ${e.message}');
      return {'status': 'pending'};
    }
  }

  /// Step 7 / 8 — desktop clients that captured the callback via a
  /// deep link can finish the exchange themselves. Most flows don't
  /// need this — the daemon handles the callback server-side and
  /// the client just polls [pollOAuthStatus].
  Future<bool> completeOAuth({
    required String state,
    required String code,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/mcp/oauth/callback',
        data: {'state': state, 'code': code},
      );
      _checkSuccess(r);
      return true;
    } on DioException catch (e) {
      throw _wrap(e, 'OAuth callback failed');
    }
  }

  /// Probe an installed server to verify it starts and lists tools.
  /// Returns the tool list on success; the daemon also updates the
  /// server's status in the background.
  Future<List<Map<String, dynamic>>> testServer(String id) async {
    try {
      final r = await _dio.post('$_base/api/mcp/servers/$id/test');
      final data = _data(r);
      final list = data?['tools'] as List? ?? const [];
      return list
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } on DioException catch (e) {
      throw _wrap(e, 'Test failed');
    }
  }

  /// Fuzzy search the catalog — delegates to the daemon which can
  /// match on name, description, tags, category, and author.
  Future<List<McpCatalogueEntry>> searchCatalog(String query) async {
    try {
      final r = await _dio.get(
        '$_base/api/mcp/catalog/search',
        queryParameters: {'q': query},
      );
      final body = r.data;
      if (body is! Map) return const [];
      final list = body['data']?['results'] as List? ??
          body['results'] as List? ??
          const [];
      return list
          .whereType<Map>()
          .map((m) => _entryFromJson(m.cast<String, dynamic>()))
          .toList();
    } on DioException {
      // Silent fallback — callers can do a local filter.
      return const [];
    }
  }

  // ── Installed servers ─────────────────────────────────────────────

  Future<List<McpServer>> listServers() async {
    try {
      final r = await _dio.get('$_base/api/mcp/servers');
      if (r.statusCode == 501 || r.statusCode == 404) {
        stubbed = true;
        _servers = const [];
        notifyListeners();
        return const [];
      }
      stubbed = false;
      final body = r.data;
      if (body is! Map) return const [];
      final list = body['data']?['servers'] as List? ??
          body['servers'] as List? ??
          body['data'] as List? ??
          const [];
      _servers = list
          .whereType<Map>()
          .map((m) => McpServer.fromJson(m.cast<String, dynamic>()))
          .toList();
      notifyListeners();
      return _servers;
    } on DioException catch (e) {
      stubbed = e.response?.statusCode == 501 ||
          e.response?.statusCode == 404;
      notifyListeners();
      return const [];
    }
  }

  Future<McpServer> install({
    required String name,
    required String transport,
    String? command,
    List<String> args = const [],
    Map<String, String> env = const {},
    String? source,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/mcp/servers',
        data: {
          'name': name,
          'transport': transport,
          'command': ?command,
          'args': args,
          'env': env,
          'source': ?source,
        },
      );
      _checkSuccess(r);
      final data = _data(r);
      if (data == null) {
        throw const McpException('Empty install response');
      }
      final server = McpServer.fromJson(data);
      _servers = [..._servers, server];
      notifyListeners();
      return server;
    } on DioException catch (e) {
      throw _wrap(e, 'Install failed');
    }
  }

  Future<void> uninstall(String id) async {
    try {
      final r = await _dio.delete('$_base/api/mcp/servers/$id');
      _checkSuccess(r);
      _servers = _servers.where((s) => s.id != id).toList();
      notifyListeners();
    } on DioException catch (e) {
      throw _wrap(e, 'Uninstall failed');
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────

  Future<void> start(String id) async {
    try {
      final r = await _dio.post('$_base/api/mcp/servers/$id/start');
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Start failed');
    }
  }

  Future<void> stop(String id) async {
    try {
      final r = await _dio.post('$_base/api/mcp/servers/$id/stop');
      _checkSuccess(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Stop failed');
    }
  }

  Future<McpServer?> status(String id) async {
    try {
      final r = await _dio.get('$_base/api/mcp/servers/$id/status');
      final data = _data(r);
      if (data == null) return null;
      return McpServer.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'Status fetch failed');
    }
  }

  /// Tools exposed by a running MCP server. Each entry is `{name,
  /// description, schema}`. Used by the detail page.
  Future<List<Map<String, dynamic>>> listTools(String id) async {
    try {
      final r = await _dio.get('$_base/api/mcp/servers/$id/tools');
      final data = _data(r);
      final list = data?['tools'] as List? ?? const [];
      return list
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } on DioException catch (e) {
      throw _wrap(e, 'Tools fetch failed');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────

  Map<String, dynamic>? _data(Response r) {
    final body = r.data;
    if (body is! Map) return null;
    if (body['success'] == false) {
      throw McpException(
        body['error']?.toString() ?? 'Unknown error',
        statusCode: r.statusCode,
      );
    }
    final data = body['data'] ?? body;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return null;
  }

  void _checkSuccess(Response r) {
    final body = r.data;
    if (body is Map && body['success'] == false) {
      throw McpException(
        body['error']?.toString() ?? 'Unknown error',
        statusCode: r.statusCode,
      );
    }
    if (r.statusCode == 501) {
      throw const McpException(
        'MCP routes are not implemented in this daemon yet.',
        statusCode: 501,
      );
    }
  }

  McpException _wrap(DioException e, String fallback) {
    String? detail;
    final body = e.response?.data;
    if (body is Map) {
      detail = body['error']?.toString() ?? body['detail']?.toString();
    }
    return McpException(
      detail ?? '$fallback: ${e.message ?? e.type.name}',
      statusCode: e.response?.statusCode,
    );
  }

  /// Parse the rich envelope the `/catalog` route returns. The
  /// daemon provides long descriptions, OAuth provider slugs,
  /// env-name→credential mapping and per-key descriptions so the
  /// install form can render proper labels without guessing.
  McpCatalogueEntry _entryFromJson(Map<String, dynamic> j) {
    // Env vars: accept both the legacy flat list and the new shape
    // where the daemon also emits a `key_descriptions` dict (so old
    // entries without per-field docs still parse).
    final keyDescs = (j['key_descriptions'] is Map)
        ? (j['key_descriptions'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    List<McpEnvVar> parseEnv(List? raw) {
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((e) => McpEnvVar(
                name: e['name'] as String? ?? '',
                label: e['label'] as String?,
                isSecret: e['secret'] == true || e['is_secret'] == true,
                description: (e['description'] as String?) ??
                    (keyDescs[e['name']] as String?) ??
                    '',
                placeholder: e['placeholder'] as String?,
              ))
          .toList();
    }

    final envMapping = (j['env_mapping'] is Map)
        ? (j['env_mapping'] as Map)
            .map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''))
        : const <String, String>{};

    // OAuth provider detection — accept every reasonable spelling.
    // The daemon may name the field `oauth_provider`, `oauth`,
    // `auth_provider`, or `auth_type` depending on the catalog
    // generation that produced the row. We also fall back to a
    // top-level `auth.type == "oauth2"` block.
    String? oauthProvider;
    final authType = j['auth_type'] as String?;
    final authBlock = j['auth'] is Map
        ? (j['auth'] as Map).cast<String, dynamic>()
        : null;
    oauthProvider = j['oauth_provider'] as String? ??
        j['oauth'] as String? ??
        j['auth_provider'] as String? ??
        (authType == 'oauth2' || authType == 'oauth' ? authType : null) ??
        (authBlock?['provider'] as String?);
    // Some catalogs only mark a boolean; in that case use the
    // entry name as the provider key (the daemon will resolve it
    // through its own provider table).
    if (oauthProvider == null && j['uses_oauth'] == true) {
      oauthProvider = j['name'] as String? ?? 'oauth';
    }

    return McpCatalogueEntry(
      name: j['name'] as String? ?? j['id'] as String? ?? '',
      label: j['label'] as String? ??
          j['display_name'] as String? ??
          j['name'] as String? ??
          '',
      description: j['description'] as String? ?? '',
      author: j['author'] as String? ?? 'community',
      transport: j['transport'] as String? ?? 'stdio',
      defaultCommand: j['command'] as String? ?? 'npx',
      defaultArgs: (j['args'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      requiredEnv: parseEnv(j['required_env'] as List? ?? j['env'] as List?),
      optionalEnv: parseEnv(j['optional_env'] as List?),
      repoUrl: j['repo_url'] as String? ?? j['repository'] as String?,
      tags: (j['tags'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      icon: j['icon'] as String? ?? '🔌',
      category: j['category'] as String? ?? 'developer-tools',
      featured: j['featured'] == true,
      popularity: (j['popularity'] as num?)?.toInt() ?? 0,
      oauthProvider: oauthProvider,
      envMapping: envMapping,
      verified: j['verified'] == true,
      installCount: (j['install_count'] as num?)?.toInt() ?? 0,
      longDescription: (j['long_description'] as String?) ??
          (j['readme'] as String?),
    );
  }

  // ── Pool / config routes (task #191) ──────────────────────────────
  //
  // The daemon exposes a read/write config surface for each server
  // plus a pool endpoint listing shared instances available for
  // reuse. The install flow uses `getConfig()` to pre-fill the form
  // when the user re-opens an entry they already configured.

  Future<Map<String, dynamic>?> getConfig(String id) async {
    try {
      final r = await _dio.get('$_base/api/mcp/servers/$id/config');
      return _data(r);
    } on DioException catch (e) {
      throw _wrap(e, 'Config fetch failed');
    }
  }

  Future<bool> setConfig(String id, Map<String, dynamic> config) async {
    try {
      final r = await _dio.put(
        '$_base/api/mcp/servers/$id/config',
        data: config,
      );
      _checkSuccess(r);
      return true;
    } on DioException catch (e) {
      throw _wrap(e, 'Config save failed');
    }
  }

  /// Pool of shared MCP instances the daemon keeps warm across
  /// users. Admins manage the pool; regular users just see which
  /// entries they can reuse to skip the install form entirely.
  Future<List<Map<String, dynamic>>> listPool() async {
    try {
      final r = await _dio.get('$_base/api/mcp/pool');
      final body = r.data;
      if (body is! Map) return const [];
      final list = body['data']?['pool'] as List? ??
          body['pool'] as List? ??
          const [];
      return list
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } on DioException {
      return const [];
    }
  }

  /// Admin-only — connect a pooled MCP instance to the daemon's
  /// active set. Used by the Pool tab in the MCP admin view.
  Future<bool> connectPool(String id) async {
    try {
      final r = await _dio.post('$_base/api/mcp/pool/$id/connect');
      _checkSuccess(r);
      return true;
    } on DioException catch (e) {
      throw _wrap(e, 'Pool connect failed');
    }
  }

  /// Admin-only — disconnect a pooled MCP instance without
  /// uninstalling it. The pool row stays, the server just stops.
  Future<bool> disconnectPool(String id) async {
    try {
      final r = await _dio.post('$_base/api/mcp/pool/$id/disconnect');
      _checkSuccess(r);
      return true;
    } on DioException catch (e) {
      throw _wrap(e, 'Pool disconnect failed');
    }
  }
}
