import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_config.dart';

/// Singleton marker value used by [AuthService.updateProfile] to
/// signal "delete this attribute key server-side". The daemon's
/// deep-merge treats literal `null` as a delete, so we substitute
/// the sentinel for `null` at send time — Dart maps drop genuine
/// `null` values, which would silently no-op the delete otherwise.
class _AttributeDeleteSentinel {
  const _AttributeDeleteSentinel();
}

class AuthUser {
  final String userId;
  final String? email;
  final String? displayName;
  final List<String> roles;
  final List<String> permissions;

  /// Server-provided convenience flag — true when the user has an
  /// admin role OR the wildcard `*` permission. Set on every login
  /// / register / refresh / `/auth/me` response. When the daemon
  /// hasn't sent the field yet (legacy build) this stays null and
  /// [isAdmin] falls back to the local roles/permissions check.
  final bool? serverIsAdmin;

  /// Relative URL on the daemon (e.g. `/api/users/me/avatar/alice.png`).
  /// The client prefixes it with [AuthService.baseUrl] when rendering.
  final String? avatarUrl;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final DateTime? updatedAt;
  final String? phone;

  /// Free-form user-owned preferences bag. The daemon's 2026-04
  /// profile schema moved `locale` / `timezone` under `attributes`
  /// and added `theme`, `notification_prefs`, etc. Deep-merge
  /// semantics on PUT (null value deletes a key).
  // Backed by a nullable field + getter so the class stays robust
  // against hot-reload: when a field is added, existing in-memory
  // instances read it as null, which would blow up non-null access.
  final Map<String, dynamic>? _attributes;
  Map<String, dynamic> get attributes =>
      _attributes ?? const <String, dynamic>{};

  AuthUser({
    required this.userId,
    this.email,
    this.displayName,
    this.roles = const [],
    this.permissions = const [],
    this.serverIsAdmin,
    this.avatarUrl,
    this.createdAt,
    this.lastSeenAt,
    this.updatedAt,
    this.phone,
    Map<String, dynamic>? attributes,
  }) : _attributes = attributes;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    // The daemon may return `attributes` as a nested map (new shape)
    // or emit `locale` / `timezone` at the top level (legacy `/auth/me`
    // shape). Merge both so downstream getters work either way.
    final attrs = <String, dynamic>{};
    final rawAttrs = json['attributes'];
    if (rawAttrs is Map) {
      attrs.addAll(rawAttrs.cast<String, dynamic>());
    }
    for (final legacyKey in const ['locale', 'timezone']) {
      if (!attrs.containsKey(legacyKey) && json[legacyKey] != null) {
        attrs[legacyKey] = json[legacyKey];
      }
    }
    return AuthUser(
      userId: (json['user_id'] ?? json['id'] ?? '') as String,
      email: json['email'] as String?,
      displayName: json['display_name'] as String?,
      roles: List<String>.from(json['roles'] ?? const []),
      permissions: List<String>.from(json['permissions'] ?? const []),
      serverIsAdmin:
          json['is_admin'] is bool ? json['is_admin'] as bool : null,
      avatarUrl: json['avatar_url'] as String?,
      createdAt: _parseDate(json['created_at']),
      lastSeenAt: _parseDate(json['last_seen_at']),
      updatedAt: _parseDate(json['updated_at']),
      phone: json['phone'] as String?,
      attributes: attrs,
    );
  }

  /// Shortcut getters for the most-read attributes. Readers written
  /// against the pre-migration schema keep working — new code can
  /// either read them here or pull the full [attributes] bag.
  String? get locale => attributes['locale'] as String?;
  String? get timezone => attributes['timezone'] as String?;
  String? get theme => attributes['theme'] as String?;
  Map<String, dynamic> get notificationPrefs =>
      (attributes['notification_prefs'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }

  /// True when the current user is a workspace admin. Prefers the
  /// daemon-provided `is_admin` boolean when available; falls back
  /// to local computation against `roles` / `permissions` for
  /// older daemon builds that don't emit the field yet.
  bool get isAdmin {
    if (serverIsAdmin != null) return serverIsAdmin!;
    return roles.contains('admin') ||
        roles.contains('*') ||
        permissions.contains('*') ||
        permissions.contains('admin');
  }

  /// True when the user has a specific permission. Admins (`*`)
  /// always pass. Used by fine-grained UI gating.
  bool can(String permission) {
    if (isAdmin) return true;
    return permissions.contains(permission);
  }
}

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyBaseUrl = 'base_url';

  String baseUrl = AppConfig.defaultDaemonUrl;
  String? _accessToken;
  String? _refreshToken;
  AuthUser? currentUser;
  bool isLoading = false;
  String? lastError;

  String? get accessToken => _accessToken;
  bool get isAuthenticated => _accessToken != null;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: AppConfig.authConnectTimeout,
    receiveTimeout: AppConfig.authReceiveTimeout,
  ));

  // Prevent concurrent refresh attempts
  Future<bool>? _refreshFuture;

  Future<bool> _safeRefresh() {
    _refreshFuture ??= refreshToken().whenComplete(() => _refreshFuture = null);
    return _refreshFuture!;
  }

  /// Create a Dio interceptor that auto-refreshes on 401.
  /// Add this to any Dio instance that calls the daemon API.
  Interceptor get authInterceptor => InterceptorsWrapper(
    onRequest: (options, handler) async {
      // Ensure token is fresh before each request
      await ensureValidToken();
      final token = _accessToken;
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    },
    onError: (error, handler) async {
      if (error.response?.statusCode == 401 && !_isRefreshing) {
        // Try refresh (deduplicated across concurrent requests)
        final ok = await _safeRefresh();
        if (ok && _accessToken != null) {
          // Retry with new token
          error.requestOptions.headers['Authorization'] = 'Bearer $_accessToken';
          try {
            final resp = await Dio().fetch(error.requestOptions);
            return handler.resolve(resp);
          } catch (e) {
            debugPrint('authInterceptor retry after refresh failed: $e');
          }
        }
        // Refresh failed — refreshToken() already called logout() if needed
      }
      handler.next(error);
    },
  );

  // ─── Persistence ─────────────────────────────────────────────────────────

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_keyAccessToken);
    _refreshToken = prefs.getString(_keyRefreshToken);
    baseUrl = prefs.getString(_keyBaseUrl) ?? AppConfig.defaultDaemonUrl;
    if (_accessToken != null) {
      await _fetchMe();
    }
    notifyListeners();
  }

  Future<void> _saveTokens(String access, String? refresh) async {
    _accessToken = access;
    _refreshToken = refresh;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAccessToken, access);
    if (refresh != null) {
      await prefs.setString(_keyRefreshToken, refresh);
    } else {
      await prefs.remove(_keyRefreshToken);
    }
    await prefs.setString(_keyBaseUrl, baseUrl);
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
  }

  // ─── Auth Header ─────────────────────────────────────────────────────────

  Options get _authOptions => Options(headers: {
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      });

  // ─── Login ───────────────────────────────────────────────────────────────

  Future<bool> login({
    String? username,
    String? email,
    required String password,
  }) async {
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final response = await _dio.post(
        '$baseUrl/auth/login',
        data: {
          'username': ?username,
          'email': ?email,
          'password': password,
        },
      );
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final access = data['access_token'] as String?;
        if (access == null) {
          isLoading = false;
          notifyListeners();
          return false;
        }
        await _saveTokens(
            access, data['refresh_token'] as String?);
        // The login response now carries roles + permissions +
        // is_admin alongside the tokens — parse it directly so we
        // don't need a second `/auth/me` round-trip just to know
        // whether the user is admin.
        currentUser = AuthUser.fromJson(data);
        isLoading = false;
        notifyListeners();
        // Background enrich: /auth/me has more fields than the
        // login response (avatar_url, phone, created_at, …). We
        // fire-and-forget it so the UI can render immediately
        // with what we already have.
        unawaited(_fetchMe());
        return true;
      }
    } on DioException catch (e) {
      lastError = _extractError(e);
    } catch (e) {
      lastError = e.toString();
    }
    isLoading = false;
    notifyListeners();
    return false;
  }

  // ─── Register ────────────────────────────────────────────────────────────

  Future<bool> register({
    required String username,
    required String password,
    String? email,
    String? displayName,
  }) async {
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final response = await _dio.post(
        '$baseUrl/auth/register',
        data: {
          'username': username,
          'password': password,
          'email': ?email,
          'display_name': ?displayName,
        },
      );
      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final access = data['access_token'] as String?;
        if (access == null) {
          isLoading = false;
          notifyListeners();
          return false;
        }
        await _saveTokens(
            access, data['refresh_token'] as String?);
        // Same shape as login — roles, permissions, is_admin are
        // embedded in the response. No second round-trip needed.
        currentUser = AuthUser.fromJson(data);
        isLoading = false;
        notifyListeners();
        unawaited(_fetchMe());
        return true;
      }
    } on DioException catch (e) {
      lastError = _extractError(e);
    } catch (e) {
      lastError = e.toString();
    }
    isLoading = false;
    notifyListeners();
    return false;
  }

  // ─── Ensure token is valid (refresh if expired) ──────────────────────────

  Future<void> ensureValidToken() async {
    if (_accessToken == null) return;
    try {
      final parts = _accessToken!.split('.');
      if (parts.length == 3) {
        var payload = parts[1];
        while (payload.length % 4 != 0) {
          payload += '=';
        }
        final decoded = utf8.decode(base64Url.decode(payload));
        final Map<String, dynamic> claims = jsonDecode(decoded);
        // No `exp` claim → daemon issued a never-expiring token (dev
        // mode `access_token_ttl: 0`). Don't refresh — the prior
        // logic computed `0 - now = -1.7e9 < 120 → true` and spammed
        // /auth/refresh on every check, which raced with itself,
        // 401'd the second call, and bounced the user back to login.
        final expRaw = claims['exp'];
        if (expRaw is! int) return;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        // Refresh if less than 120s left (increased margin)
        if (expRaw - now < 120) {
          await _safeRefresh();
        }
      }
    } catch (_) {
      await _safeRefresh();
    }
  }

  // ─── Refresh ─────────────────────────────────────────────────────────────

  bool _isRefreshing = false;

  Future<bool> refreshToken() async {
    if (_refreshToken == null) {
      debugPrint('refreshToken: no refresh token');
      return false;
    }
    // Prevent infinite loop: if already refreshing, don't retry
    if (_isRefreshing) {
      debugPrint('refreshToken: already refreshing, skip');
      return false;
    }
    _isRefreshing = true;
    try {
      // Use a PLAIN Dio without auth interceptor to avoid infinite loop
      final plainDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));
      final response = await plainDio.post(
        '$baseUrl/auth/refresh',
        data: {'refresh_token': _refreshToken},
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      debugPrint('refreshToken ← ${response.statusCode}');
      if (response.statusCode == 200 && response.data['access_token'] != null) {
        final data = response.data as Map<String, dynamic>;
        await _saveTokens(
            data['access_token'] as String, _refreshToken);
        // The refresh response now carries roles / permissions /
        // is_admin too — keep the local `currentUser` in sync so a
        // role change pushed by the daemon (admin → user, etc.)
        // takes effect on the next refresh without requiring a
        // full app restart.
        if (data['user_id'] is String) {
          currentUser = AuthUser.fromJson(data);
          notifyListeners();
        }
        _isRefreshing = false;
        return true;
      }
      // Refresh token expired — clear it to prevent further attempts
      if (response.statusCode == 401) {
        debugPrint('refreshToken: refresh token expired, logging out');
        _isRefreshing = false;
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('refreshToken error: $e');
    }
    _isRefreshing = false;
    return false;
  }

  // ─── Me ──────────────────────────────────────────────────────────────────

  Future<void> _fetchMe() async {
    try {
      final response = await _dio.get(
        '$baseUrl/auth/me',
        options: _authOptions,
      );
      debugPrint('/auth/me ← ${response.statusCode} ${response.data}');
      if (response.statusCode == 200 && response.data is Map) {
        currentUser = AuthUser.fromJson(
            (response.data as Map).cast<String, dynamic>());
        debugPrint(
            '/auth/me parsed → user=${currentUser?.userId}, '
            'roles=${currentUser?.roles}, '
            'permissions=${currentUser?.permissions}, '
            'serverIsAdmin=${currentUser?.serverIsAdmin}, '
            'effectiveIsAdmin=${currentUser?.isAdmin}');
        notifyListeners();
      }
    } catch (e) {
      debugPrint('/auth/me error: $e');
      // Token likely invalid — clear
      await _clearTokens();
    }
  }

  /// GET the full profile row from ``/api/users/me/profile`` — the
  /// richer endpoint that carries the ``attributes`` bag the client
  /// uses to hydrate theme / language / density / onboarding choices
  /// across devices. Returns the raw ``attributes`` map (already
  /// stripped of daemon-reserved keys by the server) or ``null`` on
  /// any failure. The caller is responsible for applying values to
  /// the local stores — keeping that logic out of AuthService
  /// avoids a circular import with ThemeService / PreferencesService
  /// / OnboardingService (which all pull ``baseUrl`` from here).
  Future<Map<String, dynamic>?> fetchProfileAttributes() async {
    try {
      final r = await _dio.get(
        '$baseUrl/api/users/me/profile',
        options: _authOptions,
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      final body = Map<String, dynamic>.from(r.data as Map);
      final data = (body['data'] ?? body) as Map? ?? const {};
      final attrs = (data['attributes'] as Map?)?.cast<String, dynamic>();
      return attrs;
    } catch (e) {
      debugPrint('fetchProfileAttributes failed: $e');
      return null;
    }
  }

  // The old `/auth/sessions` family was a per-app *chat* session
  // registry in disguise — the daemon removed it in the 2026-04
  // per-app sessions migration. Chat sessions now live exclusively
  // under `/api/apps/{app_id}/sessions[/…]` and are managed by
  // SessionService. There is no replacement for "list my logged-in
  // devices" today; see the migration note in CLAUDE.md.

  /// Absolute URL for the current user's avatar — null when the
  /// daemon hasn't given us one. The daemon returns a relative path
  /// like `/api/users/me/avatar/alice.png`.
  String? get avatarAbsoluteUrl {
    final rel = currentUser?.avatarUrl;
    if (rel == null || rel.isEmpty) return null;
    if (rel.startsWith('http://') || rel.startsWith('https://')) return rel;
    return '$baseUrl$rel';
  }

  /// Headers the UI can pass to `Image.network` so the Authorization
  /// bearer token reaches the daemon (otherwise the avatar / icon
  /// endpoints return 401).
  Map<String, String> get authImageHeaders => {
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  // ─── Profile management ─────────────────────────────────────────────────
  //
  // Backed by three daemon routes:
  //   * PUT    /api/users/me/profile      — display name / phone / locale
  //   * POST   /api/users/me/password     — old + new password
  //   * POST   /api/users/me/avatar       — multipart file upload
  //   * DELETE /api/users/me/avatar       — clear current avatar
  //
  // Every success path refreshes `currentUser` in place so every
  // listener (sidebar, settings header, inbox) picks up the new
  // value on the next rebuild.

  /// Sentinel used to signal "delete this attribute on the server".
  /// The daemon's deep-merge interprets a JSON `null` as a delete,
  /// but Dart drops `null` values from Maps, so callers pass this
  /// sentinel and [updateProfile] swaps it for a literal `null` in
  /// the outgoing body.
  static const Object attributeDelete = _AttributeDeleteSentinel();

  /// Update editable profile fields. Pass `null` to leave a field
  /// untouched. Returns true on success; on failure [lastError] is
  /// populated and listeners are notified so the form can render
  /// the server message inline.
  ///
  /// [attributes] deep-merges into the user's attribute bag — pass
  /// [attributeDelete] as a value to ask the daemon to drop the
  /// key. The daemon guards the privileged bag (`password_hash`,
  /// `mfa_secret`, etc.) and rejects any write atomically with 400;
  /// we never send those from the client but surface the refusal
  /// message verbatim when it happens.
  Future<bool> updateProfile({
    String? displayName,
    String? email,
    String? phone,
    String? locale,
    String? timezone,
    String? theme,
    Map<String, dynamic>? notificationPrefs,
    Map<String, dynamic>? attributes,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (email != null) body['email'] = email;
    if (phone != null) body['phone'] = phone;
    // Build attributes map from explicit top-level locale/timezone/
    // theme helpers + the caller's extra bag. The daemon's 2026-04
    // schema moved locale + timezone under `attributes`, so we must
    // nest them here rather than sending them at the top level.
    final mergedAttrs = <String, dynamic>{};
    if (locale != null) mergedAttrs['locale'] = locale;
    if (timezone != null) mergedAttrs['timezone'] = timezone;
    if (theme != null) mergedAttrs['theme'] = theme;
    if (notificationPrefs != null) {
      mergedAttrs['notification_prefs'] = notificationPrefs;
    }
    if (attributes != null) {
      attributes.forEach((k, v) {
        mergedAttrs[k] = identical(v, attributeDelete) ? null : v;
      });
    }
    if (mergedAttrs.isNotEmpty) body['attributes'] = mergedAttrs;
    if (body.isEmpty) return true;
    try {
      final r = await _dio.put(
        '$baseUrl/api/users/me/profile',
        data: body,
        options: _authOptions,
      );
      debugPrint('updateProfile ← ${r.statusCode} ${r.data}');
      final code = r.statusCode ?? 0;
      if ((code == 200 || code == 204) && r.data is Map) {
        final parsed = _unwrapUser(r.data as Map);
        if (parsed != null) {
          currentUser = parsed;
        } else {
          await _fetchMe();
        }
        lastError = null;
        notifyListeners();
        return true;
      }
      // 400 — likely a forbidden-field guard (`password_hash`,
      // `mfa_secret`) or validation error. The daemon returns the
      // full refusal reason in `detail` / `error`; we surface it so
      // the form renders it inline.
      lastError = _bodyError(r.data) ?? 'HTTP $code';
      notifyListeners();
      return false;
    } on DioException catch (e) {
      lastError = _extractError(e);
      notifyListeners();
      return false;
    }
  }

  /// Change the user's password. The daemon verifies [oldPassword]
  /// and rejects with 400 when it doesn't match — we surface the
  /// server message verbatim so the form can show it inline.
  Future<bool> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      final r = await _dio.post(
        '$baseUrl/api/users/me/password',
        data: {
          'old_password': oldPassword,
          'new_password': newPassword,
        },
        options: _authOptions,
      );
      debugPrint('changePassword ← ${r.statusCode} ${r.data}');
      final code = r.statusCode ?? 0;
      if (code >= 400) {
        lastError = _bodyError(r.data) ?? 'HTTP $code';
        notifyListeners();
        return false;
      }
      if (r.data is Map && (r.data as Map)['success'] == false) {
        lastError = _bodyError(r.data) ?? 'Password change rejected';
        notifyListeners();
        return false;
      }
      lastError = null;
      notifyListeners();
      return true;
    } on DioException catch (e) {
      lastError = _extractError(e);
      notifyListeners();
      return false;
    }
  }

  /// Upload a new avatar. [bytes] is the raw file contents (read
  /// via `image_picker` or `file_picker`), [filename] drives the
  /// content-disposition the daemon stores and [contentType]
  /// should be the MIME type sniffed at pick time.
  Future<bool> uploadAvatar({
    required List<int> bytes,
    required String filename,
    String contentType = 'image/png',
  }) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(contentType),
        ),
      });
      final r = await _dio.post(
        '$baseUrl/api/users/me/avatar',
        data: form,
        options: _authOptions,
      );
      debugPrint('uploadAvatar ← ${r.statusCode} ${r.data}');
      if ((r.statusCode == 200 || r.statusCode == 204) && r.data is Map) {
        final parsed = _unwrapUser(r.data as Map);
        if (parsed != null) {
          currentUser = parsed;
        } else {
          await _fetchMe();
        }
        lastError = null;
        notifyListeners();
        return true;
      }
      lastError = _bodyError(r.data) ?? 'HTTP ${r.statusCode}';
      notifyListeners();
      return false;
    } on DioException catch (e) {
      lastError = _extractError(e);
      notifyListeners();
      return false;
    }
  }

  /// Clear the current avatar — returns the user to the
  /// initials-on-gradient fallback rendered by `RemoteAvatar`.
  Future<bool> deleteAvatar() async {
    try {
      final r = await _dio.delete(
        '$baseUrl/api/users/me/avatar',
        options: _authOptions,
      );
      if (r.statusCode == 200 || r.statusCode == 204) {
        if (currentUser != null) {
          final u = currentUser!;
          currentUser = AuthUser(
            userId: u.userId,
            email: u.email,
            displayName: u.displayName,
            roles: u.roles,
            permissions: u.permissions,
            serverIsAdmin: u.serverIsAdmin,
            avatarUrl: null,
            createdAt: u.createdAt,
            lastSeenAt: u.lastSeenAt,
            updatedAt: u.updatedAt,
            phone: u.phone,
            attributes: u.attributes,
          );
          notifyListeners();
        }
        return true;
      }
      return false;
    } on DioException catch (e) {
      lastError = _extractError(e);
      notifyListeners();
      return false;
    }
  }

  // ─── Logout ──────────────────────────────────────────────────────────────

  Future<void> logout() async {
    if (_refreshToken != null) {
      try {
        await _dio.post(
          '$baseUrl/auth/logout',
          data: {'refresh_token': _refreshToken},
          options: _authOptions,
        );
      } catch (e) {
        debugPrint('logout: remote revocation failed ($e) — clearing locally');
      }
    }
    await _clearTokens();
    notifyListeners();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  String _extractError(DioException e) {
    try {
      final body = e.response?.data;
      if (body is Map) return body['error'] ?? body['detail'] ?? 'Unknown error';
      if (body is String) return body;
    } catch (err) {
      debugPrint('_extractError: body parse failed ($err)');
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return 'Connection timeout — is the daemon running?';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'Cannot connect to daemon at $baseUrl';
    }
    return e.message ?? 'Network error';
  }

  AuthUser? _unwrapUser(Map raw) {
    final candidates = <Map>[];
    if (raw['user'] is Map) candidates.add(raw['user'] as Map);
    if (raw['data'] is Map) {
      final d = raw['data'] as Map;
      if (d['user'] is Map) candidates.add(d['user'] as Map);
      candidates.add(d);
    }
    candidates.add(raw);
    for (final c in candidates) {
      if (c['user_id'] != null || c['id'] != null) {
        final map = Map<String, dynamic>.from(c);
        if (map['user_id'] == null && map['id'] != null) {
          map['user_id'] = map['id'];
        }
        return AuthUser.fromJson(map);
      }
    }
    return null;
  }

  String? _bodyError(dynamic body) {
    if (body is Map) {
      final err = body['error'] ?? body['detail'] ?? body['message'];
      if (err is String && err.isNotEmpty) return err;
      if (body['data'] is Map) {
        return _bodyError(body['data']);
      }
    }
    if (body is String && body.isNotEmpty) return body;
    return null;
  }
}
