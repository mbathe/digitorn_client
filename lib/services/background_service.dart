import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'auth_service.dart';
import 'session_service.dart';

// ─── Models ───────────────────────────────────────────────────────────────────

class BackgroundTask {
  final String id;
  final String appId;
  final String command;
  final String status; // running | progress | completed | failed | cancelled
  final DateTime createdAt;
  final int? pid;
  final double? elapsed;
  final String? preview;
  final String? error;
  final int? exitCode;

  const BackgroundTask({
    required this.id,
    required this.appId,
    this.command = '',
    required this.status,
    required this.createdAt,
    this.pid,
    this.elapsed,
    this.preview,
    this.error,
    this.exitCode,
  });

  factory BackgroundTask.fromJson(Map<String, dynamic> j) => BackgroundTask(
        id: j['task_id'] as String? ?? j['id'] as String? ?? '',
        appId: j['app_id'] as String? ?? '',
        command: j['command'] as String? ?? j['description'] as String? ?? j['name'] as String? ?? '',
        status: j['status'] as String? ?? 'running',
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now()
            : DateTime.now(),
        pid: (j['pid'] as num?)?.toInt(),
        elapsed: (j['elapsed'] as num?)?.toDouble(),
        preview: j['preview'] as String?,
        error: j['error'] as String?,
        exitCode: (j['exit_code'] as num?)?.toInt(),
      );

  BackgroundTask copyWith({
    String? status,
    double? elapsed,
    String? preview,
    String? error,
    int? exitCode,
  }) => BackgroundTask(
    id: id,
    appId: appId,
    command: command,
    status: status ?? this.status,
    createdAt: createdAt,
    pid: pid,
    elapsed: elapsed ?? this.elapsed,
    preview: preview ?? this.preview,
    error: error ?? this.error,
    exitCode: exitCode ?? this.exitCode,
  );

  bool get isRunning => status == 'running' || status == 'progress';
  bool get isDone => status == 'completed' || status == 'failed' || status == 'cancelled';

  String get elapsedLabel {
    final s = elapsed ?? 0;
    if (s < 60) return '${s.round()}s';
    if (s < 3600) return '${(s / 60).floor()}m ${(s % 60).round()}s';
    return '${(s / 3600).floor()}h ${((s % 3600) / 60).floor()}m';
  }
}

// ─── BackgroundService ───────────────────────────────────────────────────────

class BackgroundService extends ChangeNotifier {
  static final BackgroundService _i = BackgroundService._();
  factory BackgroundService() => _i;
  BackgroundService._();

  final Map<String, BackgroundTask> _tasks = {};
  List<BackgroundTask> get tasks => _tasks.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  bool get hasActiveTasks => _tasks.values.any((t) => t.isRunning);
  int get activeCount => _tasks.values.where((t) => t.isRunning).length;
  int unreadNotifications = 0;

  StreamSubscription? _eventSub;
  String? _currentAppId;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (status) => status != null && status < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  // ── Start watching via Socket.IO events ─────────────────────────────────

  void startPolling(String appId, String sessionId) {
    if (_currentAppId == appId) return;
    stopPolling();
    _currentAppId = appId;
    _eventSub = SessionService().events.listen(_onSessionEvent);
  }

  void stopPolling() {
    _eventSub?.cancel();
    _eventSub = null;
    _currentAppId = null;
  }

  void _onSessionEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    final data = event['data'] as Map<String, dynamic>? ?? {};

    // tool_call with task_id → new background task
    if (type == 'tool_call') {
      final taskId = data['task_id'] as String?;
      if (taskId != null && taskId.isNotEmpty) {
        _tasks[taskId] = BackgroundTask(
          id: taskId,
          appId: _currentAppId ?? '',
          command: data['command'] as String? ??
              (data['params'] is Map ? (data['params'] as Map)['command'] as String? ?? '' : ''),
          status: 'running',
          createdAt: DateTime.now(),
          pid: (data['pid'] as num?)?.toInt(),
        );
        unreadNotifications++;
        notifyListeners();
      }
      return;
    }

    // bg_task_update → update existing task
    if (type == 'bg_task_update') {
      final taskId = data['task_id'] as String? ?? '';
      final status = data['status'] as String? ?? '';
      if (taskId.isEmpty || status.isEmpty) return;

      final existing = _tasks[taskId];
      if (existing != null) {
        _tasks[taskId] = existing.copyWith(
          status: status,
          elapsed: (data['elapsed'] as num?)?.toDouble(),
          preview: data['preview'] as String?,
          error: data['error'] as String?,
          exitCode: (data['exit_code'] as num?)?.toInt(),
        );
      } else {
        _tasks[taskId] = BackgroundTask(
          id: taskId,
          appId: _currentAppId ?? '',
          command: data['command'] as String? ?? '',
          status: status,
          createdAt: DateTime.now(),
          elapsed: (data['elapsed'] as num?)?.toDouble(),
          preview: data['preview'] as String?,
          error: data['error'] as String?,
          exitCode: (data['exit_code'] as num?)?.toInt(),
        );
      }
      if (status == 'completed' || status == 'failed') {
        unreadNotifications++;
      }
      notifyListeners();
      return;
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  Future<bool> cancelTask(String appId, String sessionId, String taskId) async {
    try {
      final resp = await _dio.post(
        '$_base/api/apps/$appId/sessions/$sessionId/tasks/$taskId/cancel',
      );
      if (resp.statusCode == 200) {
        final existing = _tasks[taskId];
        if (existing != null) {
          _tasks[taskId] = existing.copyWith(status: 'cancelled');
          notifyListeners();
        }
        return true;
      }
    } catch (e) {
      debugPrint('BackgroundService.cancelTask: $e');
    }
    return false;
  }

  void clearUnread() {
    unreadNotifications = 0;
    notifyListeners();
  }

  void clearCompleted() {
    _tasks.removeWhere((_, t) => t.isDone);
    notifyListeners();
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
