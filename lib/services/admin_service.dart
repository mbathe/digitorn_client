/// Admin-only routes for the daemon. Wraps everything that lives
/// under `/api/admin/*` and isn't already owned by a more specific
/// service (quotas → [QuotasService], system credentials →
/// [CredentialsV2Service.listSystem], MCP pool → [McpService]).
///
/// Currently surfaces:
///   * `GET /api/admin/users`              — list every user on the daemon
///   * `GET /api/admin/users/{id}`         — single user detail
///   * `PUT /api/admin/users/{id}`         — update roles / display name
///   * `GET /api/admin/users/{id}/sessions`— per-user sessions for revoke
///   * `DELETE /api/admin/sessions/{sid}`  — revoke a session
///   * `GET /api/admin/audit-log`          — recent admin actions log
///   * `GET /api/admin/stats`              — workspace overview tile counts
///
/// All routes degrade gracefully — when the daemon hasn't shipped a
/// given endpoint, the wrapper returns an empty result with [error]
/// populated so the UI can render an "Admin endpoint not deployed"
/// state instead of crashing.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// Raised when an `/api/admin/users*` call surfaces an actionable
/// error (403 admin required, 400 self-refused, 404 not found, 5xx
/// daemon broke). UI catches it, reads [message], and renders the
/// right snackbar / dialog.
class AdminUserException implements Exception {
  final String message;
  final int? statusCode;
  const AdminUserException(this.message, {this.statusCode});
  @override
  String toString() => 'AdminUserException($statusCode): $message';
}

/// Return value of PATCH `/users/{id}`. [changes] is the daemon's
/// list of field tags it applied (e.g. `["display_name",
/// "roles@digitorn-chat"]`) — handy for telemetry / toasts.
class UserPatchResult {
  final AdminUser user;
  final List<String> changes;
  const UserPatchResult({required this.user, required this.changes});
}

/// Scoped role grant on an [AdminUser]. `appId == null` = global
/// role (applies daemon-wide). `appId != null` = role limited to
/// that specific app — used by the Hub's per-app admin features.
class RoleAssignment {
  final String name;
  final List<String> permissions;
  final String? appId;
  final DateTime? grantedAt;

  const RoleAssignment({
    required this.name,
    this.permissions = const [],
    this.appId,
    this.grantedAt,
  });

  factory RoleAssignment.fromJson(Map<String, dynamic> j) => RoleAssignment(
        name: (j['name'] ?? '') as String,
        permissions: (j['permissions'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        appId: j['app_id'] as String?,
        grantedAt: _parseDate(j['granted_at']),
      );

  bool get isGlobal => appId == null;
}

/// One entry from `GET /api/admin/roles` — the catalogue of roles
/// the daemon knows about, used to drive the role picker.
class RoleCatalog {
  final String id;
  final String name;
  final String description;
  final bool isBuiltin;
  final List<String> permissions;

  const RoleCatalog({
    required this.id,
    required this.name,
    this.description = '',
    this.isBuiltin = false,
    this.permissions = const [],
  });

  factory RoleCatalog.fromJson(Map<String, dynamic> j) => RoleCatalog(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        description: (j['description'] ?? '') as String,
        isBuiltin: j['is_builtin'] == true,
        permissions: (j['permissions'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

class AdminUser {
  final String userId;
  final String? externalId;
  final String? provider;
  final String? appId;
  final String? email;
  final String? displayName;
  final String? phone;
  final String? avatarUrl;

  /// All scoped grants (global + per-app). The legacy
  /// [roles] getter flattens this to a List&lt;String&gt; of names
  /// for older UI paths.
  final List<RoleAssignment> roleAssignments;
  final List<String> permissions;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastSeenAt;
  final Map<String, dynamic> attributes;
  final bool active;

  /// Daemon-provided convenience flag when the response surfaces
  /// `is_admin` explicitly. Null otherwise — [isAdmin] falls back
  /// to scanning [roleAssignments].
  final bool? serverIsAdmin;

  const AdminUser({
    required this.userId,
    this.externalId,
    this.provider,
    this.appId,
    this.email,
    this.displayName,
    this.phone,
    this.avatarUrl,
    this.roleAssignments = const [],
    this.permissions = const [],
    this.serverIsAdmin,
    this.createdAt,
    this.updatedAt,
    this.lastSeenAt,
    this.attributes = const {},
    this.active = true,
  });

  factory AdminUser.fromJson(Map<String, dynamic> j) {
    final rolesRaw = j['roles'];
    final roleAssignments = <RoleAssignment>[];
    final flatRoleNames = <String>[];
    if (rolesRaw is List) {
      for (final item in rolesRaw) {
        if (item is Map) {
          roleAssignments
              .add(RoleAssignment.fromJson(item.cast<String, dynamic>()));
        } else if (item is String) {
          // Legacy shape — list of role names only. Reconstruct a
          // synthetic assignment so the new UI can still render.
          roleAssignments.add(RoleAssignment(name: item));
          flatRoleNames.add(item);
        }
      }
    }
    final attrRaw = j['attributes'];
    return AdminUser(
      userId: (j['id'] ?? j['user_id'] ?? '') as String,
      externalId: j['external_id'] as String?,
      provider: j['provider'] as String?,
      appId: j['app_id'] as String?,
      email: j['email'] as String?,
      displayName: j['display_name'] as String?,
      phone: j['phone'] as String?,
      avatarUrl: j['avatar_url'] as String?,
      roleAssignments: roleAssignments,
      permissions: (j['permissions'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
      serverIsAdmin: j['is_admin'] is bool ? j['is_admin'] as bool : null,
      createdAt: _parseDate(j['created_at']),
      updatedAt: _parseDate(j['updated_at']),
      lastSeenAt: _parseDate(j['last_seen_at']),
      attributes: attrRaw is Map
          ? attrRaw.cast<String, dynamic>()
          : const <String, dynamic>{},
      // Daemon uses `is_active` (unified model); old routes used
      // `active`. Accept both; default to `true` when neither is
      // present so idle rows don't look disabled.
      active: j['is_active'] is bool
          ? j['is_active'] as bool
          : (j['active'] != false),
    );
  }

  /// Flat list of role names (legacy shape consumed by the older
  /// UI). Built from [roleAssignments] lazily.
  List<String> get roles =>
      roleAssignments.map((r) => r.name).toSet().toList();

  /// Role assignments grouped by scope: global (`null`) vs per-app.
  List<RoleAssignment> get globalRoles =>
      roleAssignments.where((r) => r.isGlobal).toList();
  List<RoleAssignment> get appScopedRoles =>
      roleAssignments.where((r) => !r.isGlobal).toList();

  /// Unique set of app ids where the user has at least one scoped
  /// role. Used by the detail drawer to render one section per app.
  Set<String> get appScopesWithRoles =>
      appScopedRoles
          .map((r) => r.appId!)
          .where((id) => id.isNotEmpty)
          .toSet();

  bool get isAdmin {
    if (serverIsAdmin != null) return serverIsAdmin!;
    return roleAssignments.any(
            (r) => r.name == 'admin' && r.permissions.contains('*')) ||
        roleAssignments.any((r) => r.name == '*') ||
        permissions.contains('*') ||
        permissions.contains('admin');
  }

  /// True when the user has any role scoped to [targetAppId].
  bool hasOverrideOnApp(String targetAppId) =>
      roleAssignments.any((r) => r.appId == targetAppId);

  String get label => displayName?.trim().isNotEmpty == true
      ? displayName!
      : (email ?? userId);
}

/// Paginated response of `GET /api/admin/users`.
class AdminUserListResponse {
  final List<AdminUser> users;
  final int total;
  final int limit;
  final int offset;
  final bool hasMore;

  const AdminUserListResponse({
    required this.users,
    required this.total,
    required this.limit,
    required this.offset,
    required this.hasMore,
  });

  factory AdminUserListResponse.fromJson(Map<String, dynamic> j) {
    final raw = j['users'];
    final list = raw is List
        ? raw
            .whereType<Map>()
            .map((m) => AdminUser.fromJson(m.cast<String, dynamic>()))
            .toList()
        : const <AdminUser>[];
    return AdminUserListResponse(
      users: list,
      total: (j['total'] as num?)?.toInt() ?? list.length,
      limit: (j['limit'] as num?)?.toInt() ?? list.length,
      offset: (j['offset'] as num?)?.toInt() ?? 0,
      hasMore: j['has_more'] == true,
    );
  }
}

/// Simple value object the admin UI passes into
/// [AdminService.listUsersFiltered]. Keeping it a plain object
/// avoids naked-string-param soup at call sites.
class UserFilters {
  final String q;
  final String? appId;
  final String? role;
  final bool? isActive;
  final String? provider;
  final int limit;
  final int offset;

  const UserFilters({
    this.q = '',
    this.appId,
    this.role,
    this.isActive,
    this.provider,
    this.limit = 50,
    this.offset = 0,
  });

  UserFilters copyWith({
    String? q,
    String? appId,
    String? role,
    bool? isActive,
    String? provider,
    int? limit,
    int? offset,
    bool clearAppId = false,
    bool clearRole = false,
    bool clearIsActive = false,
    bool clearProvider = false,
  }) =>
      UserFilters(
        q: q ?? this.q,
        appId: clearAppId ? null : (appId ?? this.appId),
        role: clearRole ? null : (role ?? this.role),
        isActive: clearIsActive ? null : (isActive ?? this.isActive),
        provider: clearProvider ? null : (provider ?? this.provider),
        limit: limit ?? this.limit,
        offset: offset ?? this.offset,
      );
}

class AdminAuditEntry {
  final String id;
  final String actorId;
  final String? actorLabel;
  final String action;
  final String? targetType;
  final String? targetId;
  final Map<String, dynamic> details;
  final DateTime when;

  const AdminAuditEntry({
    required this.id,
    required this.actorId,
    required this.action,
    required this.when,
    this.actorLabel,
    this.targetType,
    this.targetId,
    this.details = const {},
  });

  factory AdminAuditEntry.fromJson(Map<String, dynamic> j) {
    // Daemon ships unified-ledger shape (history_log): `actor_user_id`,
    // `event_type`, `target_user_id`+`target_app_id`, `before`/`after`.
    // Older / generic shapes (`actor_id`, `action`, `target_id`,
    // `details`) stay supported as fallbacks.
    final targetApp = j['target_app_id'] as String?;
    final targetUser = j['target_user_id'] as String?;
    final detailsMap = j['details'] is Map
        ? (j['details'] as Map).cast<String, dynamic>()
        : (j['after'] is Map
            ? (j['after'] as Map).cast<String, dynamic>()
            : <String, dynamic>{});
    return AdminAuditEntry(
      id: (j['id']?.toString() ?? ''),
      actorId: (j['actor_user_id'] ?? j['actor_id'] ?? j['user_id'] ?? '')
          as String,
      actorLabel: j['actor_label'] as String? ?? j['actor_email'] as String?,
      action: (j['event_type'] ?? j['action'] ?? j['type'] ?? 'unknown')
          as String,
      targetType: j['target_type'] as String? ??
          (targetApp != null && targetApp.isNotEmpty
              ? 'app'
              : (targetUser != null && targetUser.isNotEmpty ? 'user' : null)),
      targetId: (j['target_id'] ?? targetApp ?? targetUser) as String?,
      details: detailsMap,
      when: _parseDate(j['ts'] ?? j['created_at']) ?? DateTime.now(),
    );
  }
}

class AdminStats {
  final int users;
  final int apps;
  final int packages;
  final int systemPackages;
  final int credentials;
  final int systemCredentials;
  final int mcpServers;
  final int activeSessions;
  final double monthlyCostUsd;

  const AdminStats({
    this.users = 0,
    this.apps = 0,
    this.packages = 0,
    this.systemPackages = 0,
    this.credentials = 0,
    this.systemCredentials = 0,
    this.mcpServers = 0,
    this.activeSessions = 0,
    this.monthlyCostUsd = 0,
  });

  factory AdminStats.fromJson(Map<String, dynamic> j) {
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    double asDbl(dynamic v) => v is num ? v.toDouble() : 0;
    return AdminStats(
      users: asInt(j['users']),
      apps: asInt(j['apps']),
      packages: asInt(j['packages']),
      systemPackages: asInt(j['system_packages']),
      credentials: asInt(j['credentials']),
      systemCredentials: asInt(j['system_credentials']),
      mcpServers: asInt(j['mcp_servers']),
      activeSessions: asInt(j['active_sessions']),
      monthlyCostUsd: asDbl(j['monthly_cost_usd']),
    );
  }
}

class AdminService extends ChangeNotifier {
  static final AdminService _i = AdminService._();
  factory AdminService() => _i;
  AdminService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // ── Cache state ─────────────────────────────────────────────────

  List<AdminUser> _users = const [];
  List<AdminUser> get users => _users;

  List<AdminAuditEntry> _audit = const [];
  List<AdminAuditEntry> get audit => _audit;

  AdminStats? _stats;
  AdminStats? get stats => _stats;

  bool _loadingUsers = false;
  bool get loadingUsers => _loadingUsers;
  String? _usersError;
  String? get usersError => _usersError;

  // ── Users ───────────────────────────────────────────────────────

  Future<void> listUsers() async {
    _loadingUsers = true;
    _usersError = null;
    notifyListeners();
    const candidates = [
      '/api/admin/users',
      '/api/users',
      '/auth/admin/users',
      '/auth/users',
    ];
    int? lastStatus;
    String? lastMessage;
    for (final path in candidates) {
      try {
        debugPrint('[admin] GET $_base$path');
        final r = await _dio.get('$_base$path');
        lastStatus = r.statusCode;
        debugPrint('[admin] ← $_base$path HTTP ${r.statusCode}');
        if (r.statusCode == 403) {
          _usersError = 'Admin permission required';
          _users = const [];
          _loadingUsers = false;
          notifyListeners();
          return;
        }
        if (r.statusCode == 404 || r.statusCode == 405) {
          lastMessage = 'Route not found: $path';
          continue;
        }
        if (r.statusCode != 200) {
          lastMessage = _bodyMessage(r.data) ?? 'HTTP ${r.statusCode}';
          continue;
        }
        final raw = _extractList(r.data, 'users');
        _users = raw
            .whereType<Map>()
            .map((m) => AdminUser.fromJson(m.cast<String, dynamic>()))
            .toList()
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
        _loadingUsers = false;
        notifyListeners();
        return;
      } on DioException catch (e) {
        lastStatus = e.response?.statusCode;
        lastMessage = _bodyMessage(e.response?.data) ?? e.message ?? e.toString();
        debugPrint('[admin] DioException on $path: $lastMessage');
        if (lastStatus != 404 && lastStatus != 405) {
          break;
        }
      }
    }
    _usersError = lastMessage ??
        (lastStatus != null
            ? 'HTTP $lastStatus'
            : 'No admin users route available');
    _users = const [];
    _loadingUsers = false;
    notifyListeners();
  }

  String? _bodyMessage(dynamic body) {
    if (body is Map) {
      final err = body['error'] ?? body['detail'] ?? body['message'];
      if (err is String && err.isNotEmpty) return err;
    }
    if (body is String && body.isNotEmpty) return body;
    return null;
  }

  Future<AdminUser?> getUser(String userId) async {
    try {
      final r = await _dio.get('$_base/api/admin/users/$userId');
      if (r.statusCode != 200 || r.data is! Map) return null;
      final body = (r.data as Map).cast<String, dynamic>();
      final data = body['user'] is Map
          ? (body['user'] as Map).cast<String, dynamic>()
          : body;
      return AdminUser.fromJson(data);
    } on DioException {
      return null;
    }
  }

  /// Legacy PUT-style updater kept so older call sites compile.
  /// Internally delegates to [patchUser] which hits the canonical
  /// PATCH route the daemon accepts. Returns bool for backward
  /// compat; new code should call [patchUser] and keep the
  /// [UserPatchResult] for the changes log.
  Future<bool> updateUser(
    String userId, {
    String? displayName,
    List<String>? roles,
    bool? active,
  }) async {
    try {
      await patchUser(
        userId,
        displayName: displayName,
        roles: roles,
        isActive: active,
      );
      return true;
    } on AdminUserException {
      return false;
    }
  }

  // ── New admin-user API (matches live daemon 2026-04) ─────────────

  /// GET `/api/admin/users` with filters + pagination. Live-validated
  /// shape (see conv.md §user-admin tests). Parses the envelope
  /// strictly so a `success: false` response doesn't silently look
  /// like an empty list.
  Future<AdminUserListResponse> listUsersFiltered(UserFilters f) async {
    final qp = <String, dynamic>{
      if (f.q.isNotEmpty) 'q': f.q,
      if (f.appId != null && f.appId!.isNotEmpty) 'app_id': f.appId,
      if (f.role != null && f.role!.isNotEmpty) 'role': f.role,
      if (f.isActive != null) 'is_active': f.isActive!.toString(),
      if (f.provider != null && f.provider!.isNotEmpty)
        'provider': f.provider,
      'limit': f.limit,
      'offset': f.offset,
    };
    debugPrint('[admin] GET $_base/api/admin/users qp=$qp');
    final Response r;
    try {
      r = await _dio.get(
        '$_base/api/admin/users',
        queryParameters: qp,
      );
    } on DioException catch (e) {
      debugPrint('[admin] DioException: ${e.type} '
          'status=${e.response?.statusCode} '
          'body=${e.response?.data} msg=${e.message}');
      throw AdminUserException(
        e.response?.data is Map
            ? (_bodyMessage(e.response!.data) ?? e.message ?? 'Network error')
            : (e.message ?? 'Network error'),
        statusCode: e.response?.statusCode,
      );
    }
    debugPrint('[admin] ← HTTP ${r.statusCode} '
        'contentType=${r.headers.value('content-type')} '
        'dataType=${r.data?.runtimeType}');
    if ((r.statusCode ?? 0) == 403) {
      throw const AdminUserException(
        'Admin permission required',
        statusCode: 403,
      );
    }
    if (r.data is! Map || r.data['success'] != true) {
      debugPrint('[admin] unexpected envelope: ${r.data}');
      throw AdminUserException(
        _bodyMessage(r.data) ?? 'HTTP ${r.statusCode}',
        statusCode: r.statusCode,
      );
    }
    final data = (r.data['data'] as Map).cast<String, dynamic>();
    final parsed = AdminUserListResponse.fromJson(data);
    debugPrint('[admin] parsed ${parsed.users.length} users '
        '(total=${parsed.total})');
    return parsed;
  }

  /// GET `/api/admin/roles` — catalogue used by the role picker.
  Future<List<RoleCatalog>> listRoles() async {
    final r = await _dio.get('$_base/api/admin/roles');
    if (r.data is! Map || r.data['success'] != true) {
      return const [];
    }
    final data = (r.data['data'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final raw = data['roles'] as List? ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => RoleCatalog.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// PATCH `/api/admin/users/{id}`. Every field is optional; pass
  /// only what changed. `roles` REPLACES the set for the given
  /// [appId] scope (null = global). See the server guards in
  /// the admin-users spec for the 400 variants (self-disable,
  /// self-delete-last-admin, unknown role).
  Future<UserPatchResult> patchUser(
    String userId, {
    String? displayName,
    String? email,
    String? phone,
    bool? isActive,
    List<String>? roles,
    String? appId,
  }) async {
    final body = <String, dynamic>{
      'display_name': ?displayName,
      'email': ?email,
      'phone': ?phone,
      'is_active': ?isActive,
      'roles': ?roles,
      'app_id': ?appId,
    };
    final r = await _dio.patch(
      '$_base/api/admin/users/$userId',
      data: body,
    );
    final status = r.statusCode ?? 0;
    if (status == 400 && r.data is Map) {
      final msg = _bodyMessage(r.data) ?? 'Bad request';
      throw AdminUserException(msg, statusCode: 400);
    }
    if (status == 403) {
      throw const AdminUserException(
        'Admin permission required',
        statusCode: 403,
      );
    }
    if (status == 404) {
      throw const AdminUserException('User not found', statusCode: 404);
    }
    if (r.data is! Map || r.data['success'] != true) {
      throw AdminUserException(
        _bodyMessage(r.data) ?? 'HTTP $status',
        statusCode: status,
      );
    }
    final data = (r.data['data'] as Map).cast<String, dynamic>();
    final userJson =
        (data['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    final changes = (data['changes'] as List? ?? const [])
        .map((e) => e.toString())
        .toList();
    final user = AdminUser.fromJson(userJson);
    // Mirror the update into the cached list so listeners re-render
    // without waiting for the next listUsersFiltered() call.
    _users = _users
        .map((u) => u.userId == userId ? user : u)
        .toList(growable: false);
    notifyListeners();
    return UserPatchResult(user: user, changes: changes);
  }

  /// DELETE `/api/admin/users/{id}?hard={bool}`. Soft delete
  /// (default) disables + logs out, preserves history; hard delete
  /// wipes everything. Server rejects self-delete with 400.
  Future<void> deleteUser(String userId, {bool hard = false}) async {
    final r = await _dio.delete(
      '$_base/api/admin/users/$userId',
      queryParameters: {'hard': hard.toString()},
    );
    final status = r.statusCode ?? 0;
    if (status == 400) {
      throw AdminUserException(
        _bodyMessage(r.data) ?? 'Refused',
        statusCode: 400,
      );
    }
    if (status == 403) {
      throw const AdminUserException(
        'Admin permission required',
        statusCode: 403,
      );
    }
    if (status == 404) {
      throw const AdminUserException('User not found', statusCode: 404);
    }
    if (r.data is! Map || r.data['success'] != true) {
      throw AdminUserException(
        _bodyMessage(r.data) ?? 'HTTP $status',
        statusCode: status,
      );
    }
    // Drop from the cached list.
    _users = _users.where((u) => u.userId != userId).toList();
    notifyListeners();
  }

  // ── Sessions (per-user, for revocation) ─────────────────────────

  Future<List<Map<String, dynamic>>> listUserSessions(String userId) async {
    try {
      final r = await _dio
          .get('$_base/api/admin/users/$userId/sessions');
      if (r.statusCode != 200) return const [];
      return _extractList(r.data, 'sessions')
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } on DioException {
      return const [];
    }
  }

  Future<bool> revokeSession(String sessionId) async {
    try {
      final r =
          await _dio.delete('$_base/api/admin/sessions/$sessionId');
      return (r.statusCode ?? 0) < 300;
    } on DioException {
      return false;
    }
  }

  // ── Audit log ───────────────────────────────────────────────────

  Future<List<AdminAuditEntry>> loadAudit({int limit = 100}) async {
    try {
      final r = await _dio.get(
        '$_base/api/admin/audit-log',
        queryParameters: {'limit': limit},
      );
      if (r.statusCode != 200) return const [];
      final raw = _extractList(r.data, 'entries').isNotEmpty
          ? _extractList(r.data, 'entries')
          : _extractList(r.data, 'audit');
      _audit = raw
          .whereType<Map>()
          .map((m) =>
              AdminAuditEntry.fromJson(m.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => b.when.compareTo(a.when));
      notifyListeners();
      return _audit;
    } on DioException {
      return const [];
    }
  }

  // ── Workspace stats overview ───────────────────────────────────

  Future<AdminStats?> loadStats() async {
    try {
      final r = await _dio.get('$_base/api/admin/stats');
      if (r.statusCode != 200 || r.data is! Map) return null;
      final body = (r.data as Map).cast<String, dynamic>();
      final data = body['stats'] is Map
          ? (body['stats'] as Map).cast<String, dynamic>()
          : body;
      _stats = AdminStats.fromJson(data);
      notifyListeners();
      return _stats;
    } on DioException {
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────

  /// Tolerant list extractor — accepts both `{key: [...]}` and
  /// `{data: {key: [...]}}` envelopes, plus the legacy bare list.
  List _extractList(dynamic body, String key) {
    if (body is List) return body;
    if (body is! Map) return const [];
    if (body[key] is List) return body[key] as List;
    if (body['data'] is Map) {
      final inner = (body['data'] as Map);
      if (inner[key] is List) return inner[key] as List;
    }
    return const [];
  }
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v);
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
  }
  return null;
}
