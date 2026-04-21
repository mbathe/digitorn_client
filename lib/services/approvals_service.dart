/// Cross-app approvals queue. One unified list of every pending
/// approval the daemon is waiting on, regardless of app/session.
/// Backed by `GET /api/users/me/approvals`; responses use the
/// per-app approve endpoint already owned by [SessionService].
///
/// Subscribes to [UserEventsService] so new `approval_request` and
/// `session.awaiting_approval` events refresh the list in real time.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'session_service.dart';
import 'user_events_service.dart';

class PendingApproval {
  final String id;
  final String appId;
  final String sessionId;
  final String toolName;
  final String riskLevel;
  final String? summary;
  final Map<String, dynamic> params;
  final DateTime createdAt;

  /// Optional daemon-enriched context so the list can show the right
  /// icon / colour without a second lookup.
  final String? appName;
  final String? appIcon;
  final String? appColor;

  const PendingApproval({
    required this.id,
    required this.appId,
    required this.sessionId,
    required this.toolName,
    required this.riskLevel,
    required this.params,
    required this.createdAt,
    this.summary,
    this.appName,
    this.appIcon,
    this.appColor,
  });

  factory PendingApproval.fromJson(Map<String, dynamic> j) {
    return PendingApproval(
      id: (j['id'] ?? j['request_id'] ?? '') as String,
      appId: (j['app_id'] ?? '') as String,
      sessionId: (j['session_id'] ?? '') as String,
      toolName: (j['tool_name'] ?? j['action'] ?? 'tool') as String,
      riskLevel: (j['risk_level'] ?? 'unknown') as String,
      summary: j['summary'] as String?,
      params: j['params'] is Map
          ? (j['params'] as Map).cast<String, dynamic>()
          : <String, dynamic>{},
      createdAt: _parseDate(j['created_at']) ?? DateTime.now(),
      appName: j['app_name'] as String?,
      appIcon: j['app_icon'] as String?,
      appColor: j['app_color'] as String?,
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is String) return DateTime.tryParse(v);
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).toInt());
    }
    return null;
  }
}

class ApprovalsService extends ChangeNotifier {
  static final ApprovalsService _i = ApprovalsService._();
  factory ApprovalsService() => _i;
  ApprovalsService._() {
    _bindEvents();
  }

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  StreamSubscription<UserEvent>? _eventsSub;

  List<PendingApproval> _pending = const [];
  List<PendingApproval> get pending => _pending;
  int get count => _pending.length;

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  void _bindEvents() {
    _eventsSub?.cancel();
    _eventsSub = UserEventsService().events.listen((e) {
      if (e.type == 'approval_request' ||
          e.type == 'session.awaiting_approval') {
        // New approval landed — cheapest way to stay consistent is
        // to refetch the list. The endpoint returns deduped data
        // so concurrent pushes don't multi-add.
        unawaited(refresh());
      }
      if (e.type == 'approval_resolved' ||
          e.type == 'approval.resolved') {
        final id = e.payload['request_id'] as String? ??
            e.payload['id'] as String?;
        if (id != null) {
          _pending = _pending.where((p) => p.id != id).toList();
          notifyListeners();
        }
      }
    });
  }

  Future<void> refresh() async {
    final token = AuthService().accessToken;
    if (token == null) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/users/me/approvals',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (r.statusCode != 200) {
        _error = 'HTTP ${r.statusCode}';
        _loading = false;
        notifyListeners();
        return;
      }
      // Tolerate every reasonable envelope: bare list,
      // {approvals: [...]}, {pending: [...]}, or
      // {data: {approvals: [...]}}.
      List raw = const [];
      final body = r.data;
      if (body is List) {
        raw = body;
      } else if (body is Map) {
        raw = (body['approvals'] as List?) ??
            (body['pending'] as List?) ??
            (body['items'] as List?) ??
            const [];
        if (raw.isEmpty && body['data'] is Map) {
          final inner = (body['data'] as Map);
          raw = (inner['approvals'] as List?) ??
              (inner['pending'] as List?) ??
              (inner['items'] as List?) ??
              const [];
        }
      }
      _pending = raw
          .whereType<Map>()
          .map((m) => PendingApproval.fromJson(m.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _loading = false;
      notifyListeners();
    } on DioException catch (e) {
      _error = e.message ?? e.toString();
      _loading = false;
      notifyListeners();
    }
  }

  /// Approve or deny an approval request, then optimistically remove
  /// it from the list. The daemon will emit `approval_resolved`
  /// shortly after which is a no-op because we already dropped it.
  Future<bool> respond(
    PendingApproval req, {
    required bool approved,
    String message = '',
  }) async {
    final ok = await SessionService().approveRequest(
      appId: req.appId,
      requestId: req.id,
      approved: approved,
      message: message,
    );
    if (ok) {
      _pending = _pending.where((p) => p.id != req.id).toList();
      notifyListeners();
    }
    return ok;
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }
}
