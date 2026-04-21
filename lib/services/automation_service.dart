/// Automation primitives wired against the daemon:
///
///   * **Triggers** — declared in app.yaml, can be fired manually
///     or tested from the dashboard.
///   * **Background tasks** — long-lived async work (e.g. batch
///     embeddings) the agent launches via the `tasks` tool.
///   * **Watchers** — filesystem / cron / event watchers that re-
///     run the agent when something changes.
///   * **Background sessions** — headless sessions driven by a
///     payload rather than interactive chat (webhooks, scheduled
///     jobs).
///
/// Scout audit 2026-04-20 covered:
///
///   * POST   /apps/{id}/triggers/{trigger_id}/fire
///   * POST   /apps/{id}/triggers/{trigger_id}/test
///   * POST   /apps/{id}/background-tasks
///   * GET    /apps/{id}/background-tasks
///   * GET    /apps/{id}/background-tasks/{task_id}
///   * DELETE /apps/{id}/background-tasks/{task_id}
///   * POST   /apps/{id}/background-tasks/{task_id}/wait
///   * POST   /apps/{id}/watchers
///   * GET    /apps/{id}/watchers
///   * GET    /apps/{id}/watchers/{watcher_id}
///   * DELETE /apps/{id}/watchers/{watcher_id}
///   * POST   /apps/{id}/watchers/{watcher_id}/pause
///   * POST   /apps/{id}/watchers/{watcher_id}/resume
///   * POST   /apps/{id}/background-sessions
///   * GET    /apps/{id}/background-sessions
///   * GET    /apps/{id}/background-sessions/{id}
///   * DELETE /apps/{id}/background-sessions/{id}
///   * POST   /apps/{id}/background-sessions/{id}/pause
///   * POST   /apps/{id}/background-sessions/{id}/resume
///   * GET    /apps/{id}/background-sessions/{id}/payload
///   * PUT    /apps/{id}/background-sessions/{id}/payload
///   * DELETE /apps/{id}/background-sessions/{id}/payload
///   * POST   /apps/{id}/background-sessions/{id}/payload/files
///   * DELETE /apps/{id}/background-sessions/{id}/payload/files/{fn}
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

class AutomationService {
  AutomationService._();
  static final AutomationService _instance = AutomationService._();
  factory AutomationService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  Options _opts() => Options(
        validateStatus: (s) => s != null && s < 500 && s != 401,
        headers: const {'Content-Type': 'application/json'},
      );

  Map<String, dynamic>? _asMap(Response r) {
    if (r.statusCode != 200 || r.data is! Map) return null;
    if ((r.data as Map)['success'] != true) return null;
    return ((r.data as Map)['data'] as Map?)?.cast<String, dynamic>();
  }

  List<Map<String, dynamic>>? _asList(Response r, List<String> keys) {
    final data = _asMap(r);
    if (data == null) return null;
    for (final k in keys) {
      final v = data[k];
      if (v is List) {
        return v
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList();
      }
    }
    return const [];
  }

  // ── Triggers ─────────────────────────────────────────────────

  /// POST /apps/{id}/triggers/{trigger}/fire — fire a trigger with
  /// optional payload. Returns the daemon's result envelope.
  Future<Map<String, dynamic>?> fireTrigger(
    String appId,
    String triggerId, {
    Map<String, dynamic>? payload,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/triggers/$triggerId/fire',
        data: {'payload': ?payload},
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.fireTrigger: $e');
      return null;
    }
  }

  /// POST /apps/{id}/triggers/{trigger}/test — dry-run the trigger
  /// against the payload without side effects. Useful from the
  /// builder dashboard.
  Future<Map<String, dynamic>?> testTrigger(
    String appId,
    String triggerId, {
    Map<String, dynamic>? payload,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/triggers/$triggerId/test',
        data: {'payload': ?payload},
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.testTrigger: $e');
      return null;
    }
  }

  // ── Background tasks ─────────────────────────────────────────

  Future<Map<String, dynamic>?> launchBackgroundTask(
    String appId, {
    required String tool,
    required Map<String, dynamic> args,
    String? label,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/background-tasks',
        data: {
          'tool': tool,
          'args': args,
          'label': ?label,
        },
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.launchBackgroundTask: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> listBackgroundTasks(
      String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/background-tasks',
          options: _opts());
      return _asList(r, const ['tasks', 'items']);
    } catch (e) {
      debugPrint('Automation.listBackgroundTasks: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getBackgroundTask(
      String appId, String taskId) async {
    try {
      final r = await _dio.get(
          '/api/apps/$appId/background-tasks/$taskId',
          options: _opts());
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.getBackgroundTask: $e');
      return null;
    }
  }

  Future<bool> cancelBackgroundTask(String appId, String taskId) async {
    try {
      final r = await _dio.delete(
          '/api/apps/$appId/background-tasks/$taskId',
          options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.cancelBackgroundTask: $e');
      return false;
    }
  }

  /// Blocks until the task reaches a terminal state or the daemon
  /// times out. Use sparingly — prefer polling [getBackgroundTask].
  Future<Map<String, dynamic>?> waitBackgroundTask(
    String appId,
    String taskId, {
    Duration? timeout,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/background-tasks/$taskId/wait',
        data: {
          'timeout': ?timeout?.inSeconds,
        },
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.waitBackgroundTask: $e');
      return null;
    }
  }

  // ── Watchers ─────────────────────────────────────────────────

  Future<Map<String, dynamic>?> createWatcher(
    String appId, {
    required String kind,
    required Map<String, dynamic> config,
    String? label,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/watchers',
        data: {'kind': kind, 'config': config, 'label': ?label},
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.createWatcher: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> listWatchers(String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/watchers',
          options: _opts());
      return _asList(r, const ['watchers', 'items']);
    } catch (e) {
      debugPrint('Automation.listWatchers: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getWatcher(
      String appId, String watcherId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/watchers/$watcherId',
          options: _opts());
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.getWatcher: $e');
      return null;
    }
  }

  Future<bool> stopWatcher(String appId, String watcherId) async {
    try {
      final r = await _dio.delete('/api/apps/$appId/watchers/$watcherId',
          options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.stopWatcher: $e');
      return false;
    }
  }

  Future<bool> pauseWatcher(String appId, String watcherId) async {
    try {
      final r = await _dio.post(
          '/api/apps/$appId/watchers/$watcherId/pause',
          data: const {}, options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.pauseWatcher: $e');
      return false;
    }
  }

  Future<bool> resumeWatcher(String appId, String watcherId) async {
    try {
      final r = await _dio.post(
          '/api/apps/$appId/watchers/$watcherId/resume',
          data: const {}, options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.resumeWatcher: $e');
      return false;
    }
  }

  // ── Background sessions (payload-driven, non-interactive) ───

  Future<Map<String, dynamic>?> createBackgroundSession(
    String appId, {
    Map<String, dynamic>? payload,
    String? label,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/background-sessions',
        data: {
          'payload': ?payload,
          'label': ?label,
        },
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.createBackgroundSession: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> listBackgroundSessions(
      String appId) async {
    try {
      final r = await _dio.get('/api/apps/$appId/background-sessions',
          options: _opts());
      return _asList(r, const ['sessions', 'items']);
    } catch (e) {
      debugPrint('Automation.listBackgroundSessions: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getBackgroundSession(
      String appId, String bgSessionId) async {
    try {
      final r = await _dio.get(
          '/api/apps/$appId/background-sessions/$bgSessionId',
          options: _opts());
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.getBackgroundSession: $e');
      return null;
    }
  }

  Future<bool> deleteBackgroundSession(
      String appId, String bgSessionId) async {
    try {
      final r = await _dio.delete(
          '/api/apps/$appId/background-sessions/$bgSessionId',
          options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.deleteBackgroundSession: $e');
      return false;
    }
  }

  Future<bool> pauseBackgroundSession(
      String appId, String bgSessionId) async {
    try {
      final r = await _dio.post(
          '/api/apps/$appId/background-sessions/$bgSessionId/pause',
          data: const {}, options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.pauseBackgroundSession: $e');
      return false;
    }
  }

  Future<bool> resumeBackgroundSession(
      String appId, String bgSessionId) async {
    try {
      final r = await _dio.post(
          '/api/apps/$appId/background-sessions/$bgSessionId/resume',
          data: const {}, options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.resumeBackgroundSession: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getBackgroundSessionPayload(
      String appId, String bgSessionId) async {
    try {
      final r = await _dio.get(
          '/api/apps/$appId/background-sessions/$bgSessionId/payload',
          options: _opts());
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.getBackgroundSessionPayload: $e');
      return null;
    }
  }

  Future<bool> setBackgroundSessionPayload(
      String appId, String bgSessionId, Map<String, dynamic> payload) async {
    try {
      final r = await _dio.put(
        '/api/apps/$appId/background-sessions/$bgSessionId/payload',
        data: payload,
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.setBackgroundSessionPayload: $e');
      return false;
    }
  }

  Future<bool> clearBackgroundSessionPayload(
      String appId, String bgSessionId) async {
    try {
      final r = await _dio.delete(
          '/api/apps/$appId/background-sessions/$bgSessionId/payload',
          options: _opts());
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.clearBackgroundSessionPayload: $e');
      return false;
    }
  }

  /// Multipart upload to the payload's attachments folder.
  Future<Map<String, dynamic>?> uploadBackgroundSessionFile(
    String appId,
    String bgSessionId, {
    required List<int> bytes,
    required String filename,
  }) async {
    try {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final r = await _dio.post(
        '/api/apps/$appId/background-sessions/$bgSessionId/payload/files',
        data: form,
        options: _opts(),
      );
      return _asMap(r);
    } catch (e) {
      debugPrint('Automation.uploadBackgroundSessionFile: $e');
      return null;
    }
  }

  Future<bool> deleteBackgroundSessionFile(
    String appId,
    String bgSessionId,
    String filename,
  ) async {
    try {
      final r = await _dio.delete(
        '/api/apps/$appId/background-sessions/$bgSessionId/'
        'payload/files/${Uri.encodeComponent(filename)}',
        options: _opts(),
      );
      return r.statusCode == 200 &&
          r.data is Map &&
          (r.data as Map)['success'] == true;
    } catch (e) {
      debugPrint('Automation.deleteBackgroundSessionFile: $e');
      return false;
    }
  }
}
