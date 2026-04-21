/// Quota management. User-facing surface (the current user's own
/// quota) is already exposed as part of the `/api/users/me/usage`
/// payload via [UsageService]; this service covers the admin CRUD
/// surface on top of `/api/admin/quotas`.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// One quota row as modelled by the daemon's admin API. A quota
/// ties a `tokens_limit` to a given `(scope_type, scope_id)` pair,
/// optionally restricted to a specific `app_id`, and scoped to a
/// reset period (`day` / `week` / `month`).
class UserQuota {
  /// Daemon-assigned id — opaque uuid.
  final String id;

  /// `user` | `user_app` | `app`.
  final String scopeType;

  /// The subject — a user id for `user` / `user_app` scopes, an
  /// app id for `app` scopes.
  final String scopeId;

  /// Only set when `scope_type == user_app` — the app the quota
  /// applies to for that specific user.
  final String? appId;

  /// `day` | `week` | `month`.
  final String period;

  /// Maximum tokens the subject can burn in [period].
  final int tokensLimit;

  /// Tokens already used in the current period (daemon computes
  /// this on the fly). Null when the daemon hasn't measured yet.
  final int? tokensUsed;

  /// Wall-clock when the daemon will reset the usage counter.
  final DateTime? resetsAt;

  /// Optional enrichment for admin UIs — the daemon may resolve
  /// the scope subject into a human-readable label so the admin
  /// doesn't have to look up uuids.
  final String? displayName;
  final String? email;

  const UserQuota({
    required this.id,
    required this.scopeType,
    required this.scopeId,
    required this.period,
    required this.tokensLimit,
    this.appId,
    this.tokensUsed,
    this.resetsAt,
    this.displayName,
    this.email,
  });

  factory UserQuota.fromJson(Map<String, dynamic> j) {
    int? asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    return UserQuota(
      id: j['id'] as String? ?? '',
      scopeType: j['scope_type'] as String? ?? 'user',
      scopeId: j['scope_id'] as String? ??
          (j['user_id'] as String? ?? ''),
      appId: j['app_id'] as String?,
      period: j['period'] as String? ?? 'month',
      tokensLimit: asInt(j['tokens_limit']) ??
          asInt(j['token_limit']) ??
          0,
      tokensUsed: asInt(j['tokens_used']) ?? asInt(j['token_used']),
      resetsAt: _parseDate(j['resets_at'] ?? j['period_end']),
      displayName: j['display_name'] as String?,
      email: j['email'] as String?,
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }

  /// Fraction 0..1 of the limit consumed in the current period.
  double get fraction {
    if (tokensLimit <= 0) return 0;
    final used = tokensUsed ?? 0;
    return (used / tokensLimit).clamp(0, 1);
  }

  /// Human-friendly label for the subject, with fallback to the id.
  String get subjectLabel =>
      displayName ?? email ?? scopeId;
}

class QuotasService extends ChangeNotifier {
  static final QuotasService _i = QuotasService._();
  factory QuotasService() => _i;
  QuotasService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 15),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  /// Admin-side: every quota row across the workspace.
  List<UserQuota> _all = const [];
  List<UserQuota> get all => _all;

  /// User-side: the quotas that apply to the *caller* (cross-app
  /// and per-app). Populated by [loadMyQuotas] — admin never uses it.
  List<UserQuota> _mine = const [];
  List<UserQuota> get mine => _mine;

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  String get _base => AuthService().baseUrl;

  // ── User-facing: /api/users/me/quotas ───────────────────────────

  /// Fetch the quotas that apply to the current caller. Includes
  /// cross-app (`user`), per-app (`user_app`) and any team
  /// (`app`) quota the user inherits from. The daemon returns an
  /// empty list when nothing constrains them.
  Future<List<UserQuota>> loadMyQuotas() async {
    try {
      final r = await _dio.get('$_base/api/users/me/quotas');
      if (r.statusCode != 200) return const [];
      final raw = _extractQuotas(r.data);
      _mine = raw
          .whereType<Map>()
          .map((m) => UserQuota.fromJson(m.cast<String, dynamic>()))
          .toList();
      notifyListeners();
      return _mine;
    } on DioException {
      return const [];
    }
  }

  /// Tolerant list extractor — accepts the daemon's various
  /// envelope shapes:
  ///   * `[ ... ]`                       — bare list
  ///   * `{ "quotas": [...] }`           — typed envelope
  ///   * `{ "data": { "quotas": [...] }}` — versioned envelope
  ///   * `{ "items": [...] }`            — generic envelope
  List _extractQuotas(dynamic body) {
    if (body is List) return body;
    if (body is! Map) return const [];
    if (body['quotas'] is List) return body['quotas'] as List;
    if (body['items'] is List) return body['items'] as List;
    if (body['data'] is Map) {
      final inner = body['data'] as Map;
      if (inner['quotas'] is List) return inner['quotas'] as List;
      if (inner['items'] is List) return inner['items'] as List;
    }
    if (body['data'] is List) return body['data'] as List;
    return const [];
  }

  // ── Admin CRUD: /api/admin/quotas ──────────────────────────────

  /// List every quota row. Admin only — non-admin gets 403 and we
  /// surface it via [error] without crashing the UI.
  ///
  /// Optional [scopeId] filters to one subject (user or app).
  Future<void> listAll({String? scopeId}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await _dio.get(
        '$_base/api/admin/quotas',
        queryParameters: {'scope_id': ?scopeId},
      );
      if (r.statusCode == 403) {
        _error = 'Admin permission required';
        _all = const [];
        _loading = false;
        notifyListeners();
        return;
      }
      if (r.statusCode != 200) {
        _error = 'HTTP ${r.statusCode}';
        _all = const [];
        _loading = false;
        notifyListeners();
        return;
      }
      final raw = _extractQuotas(r.data);
      _all = raw
          .whereType<Map>()
          .map((m) => UserQuota.fromJson(m.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => a.scopeId.compareTo(b.scopeId));
      _loading = false;
      notifyListeners();
    } on DioException catch (e) {
      _error = e.message ?? e.toString();
      _loading = false;
      notifyListeners();
    }
  }

  /// Create a new quota row. Matches the daemon shape:
  /// `{scope_type, scope_id, app_id?, period, tokens_limit}`.
  ///
  /// [scopeType] is one of `user` / `user_app` / `app`; when it's
  /// `user_app`, [appId] must be set.
  Future<UserQuota?> create({
    required String scopeType,
    required String scopeId,
    required String period,
    required int tokensLimit,
    String? appId,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/admin/quotas',
        data: {
          'scope_type': scopeType,
          'scope_id': scopeId,
          'period': period,
          'tokens_limit': tokensLimit,
          'app_id': ?appId,
        },
      );
      if ((r.statusCode ?? 0) >= 300) return null;
      final data = r.data is Map ? r.data as Map : null;
      if (data == null) return null;
      // Accept `{quota: {...}}`, `{data: {quota: {...}}}`,
      // `{data: {...}}` and the bare row.
      Map<String, dynamic> body;
      if (data['quota'] is Map) {
        body = (data['quota'] as Map).cast<String, dynamic>();
      } else if (data['data'] is Map) {
        final inner = (data['data'] as Map).cast<String, dynamic>();
        body = inner['quota'] is Map
            ? (inner['quota'] as Map).cast<String, dynamic>()
            : inner;
      } else {
        body = data.cast<String, dynamic>();
      }
      final quota = UserQuota.fromJson(body);
      _all = [..._all, quota]
        ..sort((a, b) => a.scopeId.compareTo(b.scopeId));
      notifyListeners();
      return quota;
    } on DioException {
      return null;
    }
  }

  /// Delete a quota row by its daemon-assigned id.
  Future<bool> delete(String id) async {
    try {
      final r = await _dio.delete('$_base/api/admin/quotas/$id');
      if ((r.statusCode ?? 0) >= 300) return false;
      _all = _all.where((q) => q.id != id).toList();
      notifyListeners();
      return true;
    } on DioException {
      return false;
    }
  }
}
