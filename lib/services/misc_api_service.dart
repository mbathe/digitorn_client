/// Grab-bag of daemon endpoints that didn't fit into a dedicated
/// service — config browse, discovery templates / triggers /
/// compile, modules execute, package update checks, builder
/// drafts deploy, MCP pool health, transcribe health.
///
/// Scout audit 2026-04-20 coverage:
///   * GET    /api/config/browse             → [browseConfig]
///   * POST   /api/discovery/compile         → [discoveryCompile]
///   * GET    /api/discovery/templates       → [discoveryTemplates]
///   * GET    /api/discovery/triggers        → [discoveryTriggers]
///   * GET    /api/discovery/triggers/configured
///                                           → [discoveryConfiguredTriggers]
///   * POST   /api/modules/{id}/execute      → [executeModuleAction]
///   * GET    /api/packages/{id}/check-update → [checkPackageUpdate]
///   * POST   /api/builder/drafts/{id}/deploy → [deployDraft]
///   * GET    /api/mcp/pool/health           → [mcpPoolHealth]
///   * GET    /api/transcribe/health         → [transcribeHealth]
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

class MiscApiService {
  MiscApiService._();
  static final MiscApiService _instance = MiscApiService._();
  factory MiscApiService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  Options _opts() => Options(
        validateStatus: (s) => s != null && s < 500 && s != 401,
        headers: const {'Content-Type': 'application/json'},
      );

  Map<String, dynamic>? _data(Response r) {
    if (r.statusCode != 200 || r.data is! Map) return null;
    final body = r.data as Map;
    if (body.containsKey('success') && body['success'] != true) return null;
    final data = (body['data'] as Map?)?.cast<String, dynamic>();
    return data ?? body.cast<String, dynamic>();
  }

  // The `/auth/sessions*` family was removed in the 2026-04 per-app
  // sessions migration — those routes now return 404. Chat sessions
  // are per-app (see SessionService) and there is no replacement API
  // for "list my logged-in devices" today.

  // ── Config browser ──────────────────────────────────────────

  /// GET /api/config/browse — walk a filesystem path the daemon
  /// knows about (used by the builder's "pick YAML" UI).
  Future<Map<String, dynamic>?> browseConfig({String? path}) async {
    try {
      final r = await _dio.get(
        '/api/config/browse',
        queryParameters: {'path': ?path},
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Misc.browseConfig: $e');
      return null;
    }
  }

  // ── Discovery (builder primitives) ──────────────────────────

  /// POST /api/discovery/compile — compile a user's YAML draft into
  /// the internal app-bundle representation. Used by the
  /// Builder's live preview.
  Future<Map<String, dynamic>?> discoveryCompile(
    Map<String, dynamic> yamlOrDraft,
  ) async {
    try {
      final r = await _dio.post(
        '/api/discovery/compile',
        data: yamlOrDraft,
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Misc.discoveryCompile: $e');
      return null;
    }
  }

  /// GET /api/discovery/templates — list starter templates available
  /// in the Builder's "New app" dialog.
  Future<List<Map<String, dynamic>>?> discoveryTemplates() async {
    try {
      final r = await _dio.get('/api/discovery/templates', options: _opts());
      final d = _data(r);
      final raw = d?['templates'] ?? d?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('Misc.discoveryTemplates: $e');
      return null;
    }
  }

  /// GET /api/discovery/triggers — catalogue of trigger kinds (cron,
  /// webhook, fs-watch, etc.) with their config schemas. Drives
  /// the trigger-builder form.
  Future<List<Map<String, dynamic>>?> discoveryTriggers() async {
    try {
      final r = await _dio.get('/api/discovery/triggers', options: _opts());
      final d = _data(r);
      final raw = d?['triggers'] ?? d?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('Misc.discoveryTriggers: $e');
      return null;
    }
  }

  /// GET /api/discovery/triggers/configured — triggers already
  /// configured across all the user's apps (dashboard view).
  Future<List<Map<String, dynamic>>?> discoveryConfiguredTriggers() async {
    try {
      final r = await _dio.get(
          '/api/discovery/triggers/configured', options: _opts());
      final d = _data(r);
      final raw = d?['triggers'] ?? d?['items'] ?? const [];
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      debugPrint('Misc.discoveryConfiguredTriggers: $e');
      return null;
    }
  }

  // ── Modules (cross-app) ────────────────────────────────────

  /// POST /api/modules/{id}/execute — run a module-level action
  /// without a specific app context. Used by ops / debug UIs.
  Future<Map<String, dynamic>?> executeModuleAction(
    String moduleId, {
    required String action,
    Map<String, dynamic>? args,
  }) async {
    try {
      final r = await _dio.post(
        '/api/modules/${Uri.encodeComponent(moduleId)}/execute',
        data: {
          'action': action,
          'args': ?args,
        },
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Misc.executeModuleAction: $e');
      return null;
    }
  }

  // ── Packages ───────────────────────────────────────────────

  /// GET /api/packages/{id}/check-update — check if a newer version
  /// of a package is available. Powers the "update available" chip
  /// in the Packages panel.
  Future<Map<String, dynamic>?> checkPackageUpdate(String packageId) async {
    try {
      final r = await _dio.get(
        '/api/packages/${Uri.encodeComponent(packageId)}/check-update',
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Misc.checkPackageUpdate: $e');
      return null;
    }
  }

  // ── Builder drafts ─────────────────────────────────────────

  /// POST /api/builder/drafts/{draft_id}/deploy — promote a saved
  /// Builder draft straight to a deployed app (without going
  /// through the upload form).
  Future<Map<String, dynamic>?> deployDraft(String draftId) async {
    try {
      final r = await _dio.post(
        '/api/builder/drafts/${Uri.encodeComponent(draftId)}/deploy',
        data: const {},
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Misc.deployDraft: $e');
      return null;
    }
  }

  // ── Health probes (ops) ────────────────────────────────────

  /// GET /api/mcp/pool/health — health of the MCP client-pool
  /// (useful for MCP settings / debug panels).
  Future<Map<String, dynamic>?> mcpPoolHealth() async {
    try {
      final r = await _dio.get('/api/mcp/pool/health', options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Misc.mcpPoolHealth: $e');
      return null;
    }
  }

  /// GET /api/transcribe/health — transcribe subsystem status
  /// (voice input settings page reads this before offering the
  /// record button).
  Future<Map<String, dynamic>?> transcribeHealth() async {
    try {
      final r = await _dio.get('/api/transcribe/health', options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Misc.transcribeHealth: $e');
      return null;
    }
  }

  /// GET /api/apps/{id}/notifications/active — has the app any
  /// active background notifications? Drives the red-dot on the
  /// app icon.
  Future<Map<String, dynamic>?> hasActiveNotifications(String appId) async {
    try {
      final r = await _dio.get(
          '/api/apps/$appId/notifications/active',
          options: _opts());
      return _data(r);
    } catch (e) {
      debugPrint('Misc.hasActiveNotifications: $e');
      return null;
    }
  }

  /// POST /api/apps/{id}/notifications — trigger the notification
  /// check cycle manually (debug / settings "force refresh").
  Future<Map<String, dynamic>?> checkNotifications(
    String appId, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final r = await _dio.post(
        '/api/apps/$appId/notifications',
        data: body ?? const {},
        options: _opts(),
      );
      return _data(r);
    } catch (e) {
      debugPrint('Misc.checkNotifications: $e');
      return null;
    }
  }
}
