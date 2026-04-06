import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'auth_service.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class BackgroundTask {
  final String id;
  final String appId;
  final String description;
  final String status; // running | completed | failed | cancelled
  final DateTime createdAt;
  final double? progress;

  const BackgroundTask({
    required this.id,
    required this.appId,
    required this.description,
    required this.status,
    required this.createdAt,
    this.progress,
  });

  factory BackgroundTask.fromJson(Map<String, dynamic> j) => BackgroundTask(
        id: j['task_id'] as String? ?? j['id'] as String? ?? '',
        appId: j['app_id'] as String? ?? '',
        description: j['description'] as String? ?? j['name'] as String? ?? '',
        status: j['status'] as String? ?? 'running',
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now()
            : DateTime.now(),
        progress: (j['progress'] as num?)?.toDouble(),
      );

  bool get isRunning => status == 'running';
  bool get isDone => status == 'completed' || status == 'failed' || status == 'cancelled';
}

// ─── BackgroundService ───────────────────────────────────────────────────────

class BackgroundService extends ChangeNotifier {
  static final BackgroundService _i = BackgroundService._();
  factory BackgroundService() => _i;
  BackgroundService._();

  List<BackgroundTask> tasks = [];
  bool hasActiveTasks = false;
  int unreadNotifications = 0;

  Timer? _pollTimer;
  String? _currentAppId;
  String? _currentSessionId;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (status) => status != null && status < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  Options get _opts {
    final t = AuthService().accessToken;
    return Options(headers: {if (t != null) 'Authorization': 'Bearer $t'});
  }

  String get _base => AuthService().baseUrl;

  // ── Start polling for an app/session ──────────────────────────────────────

  void startPolling(String appId, String sessionId) {
    if (_currentAppId == appId && _currentSessionId == sessionId) return;
    stopPolling();
    _currentAppId = appId;
    _currentSessionId = sessionId;
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _currentAppId = null;
    _currentSessionId = null;
  }

  Future<void> _poll() async {
    final appId = _currentAppId;
    final sessionId = _currentSessionId;
    if (appId == null || sessionId == null) return;

    try {
      // Quick check: are there active bg tasks?
      final resp = await _dio.get(
        '$_base/api/apps/$appId/notifications/active',
        options: _opts,
      );
      final active = resp.data?['data']?['active'] as bool? ?? false;
      if (active != hasActiveTasks) {
        hasActiveTasks = active;
        if (active) unreadNotifications++;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('BackgroundService._poll: $e');
    }

    try {
      // Load task list
      final resp = await _dio.get(
        '$_base/api/apps/$appId/background-tasks',
        options: _opts,
      );
      if (resp.data?['success'] == true) {
        final list = resp.data['data']['tasks'] as List? ?? [];
        tasks = list.map((j) => BackgroundTask.fromJson(j as Map<String, dynamic>)).toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint('BackgroundService.loadTasks: $e');
    }
  }

  Future<void> cancelTask(String appId, String taskId) async {
    try {
      await _dio.delete(
        '$_base/api/apps/$appId/background-tasks/$taskId',
        options: _opts,
      );
      tasks.removeWhere((t) => t.id == taskId);
      notifyListeners();
    } catch (e) {
      debugPrint('BackgroundService.cancelTask: $e');
    }
  }

  void clearUnread() {
    unreadNotifications = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
