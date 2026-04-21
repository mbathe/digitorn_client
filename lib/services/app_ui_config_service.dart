/// Per-app cache for `GET /api/apps/{id}/ui-config`.
///
/// The config is immutable between redeploys, so we cache it for the
/// whole session and only invalidate when the user hits "Reload app"
/// or we receive a daemon `app_redeployed` event.
///
/// Usage:
///   * `AppUiConfigService().configFor(appId)` — sync read, null if
///     not cached yet (kicks off a background fetch).
///   * `await AppUiConfigService().ensure(appId)` — awaitable fetch.
///   * `AppUiConfigService()` is a [ChangeNotifier] — listen to
///     rebuild UI when the cache fills in.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_ui_config.dart';
import 'api_client.dart';
import 'user_events_service.dart';

class AppUiConfigService extends ChangeNotifier {
  AppUiConfigService._internal() {
    _startRedeployListener();
  }
  static final AppUiConfigService _instance =
      AppUiConfigService._internal();
  factory AppUiConfigService() => _instance;

  final Map<String, AppUiConfig> _cache = {};
  final Map<String, Future<AppUiConfig?>> _inflight = {};
  StreamSubscription<UserEvent>? _redeploySub;

  /// Listen for `app_deployed` / `app_redeployed` / `app_undeployed`
  /// events on the user-scoped bus. When one lands we drop the cached
  /// config for that app_id so the next read re-fetches (a redeploy
  /// can flip `auto_approve`, change `render_mode`, toggle preview).
  /// Non-payload events (no app_id) are ignored.
  void _startRedeployListener() {
    _redeploySub ??= UserEventsService().events.listen((e) {
      const triggers = {
        'app_deployed',
        'app_redeployed',
        'app_undeployed',
        'app_reloaded',
      };
      if (!triggers.contains(e.type)) return;
      final appId = e.appId ?? (e.payload['app_id'] as String?);
      if (appId == null || appId.isEmpty) return;
      debugPrint('AppUiConfigService: invalidating cache for '
          '$appId (event=${e.type})');
      unawaited(invalidate(appId));
    });
  }

  /// Sync read. Returns null when not yet cached; also kicks off a
  /// background fetch so the listener fires once the data lands.
  AppUiConfig? configFor(String appId) {
    final hit = _cache[appId];
    if (hit != null) return hit;
    // Kick off a fetch if we don't already have one in-flight.
    unawaited(ensure(appId));
    return null;
  }

  /// Awaitable fetch. Deduplicates concurrent calls.
  Future<AppUiConfig?> ensure(String appId) async {
    if (_cache.containsKey(appId)) return _cache[appId];
    final existing = _inflight[appId];
    if (existing != null) return existing;
    final future = _fetch(appId);
    _inflight[appId] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(appId);
    }
  }

  Future<AppUiConfig?> _fetch(String appId) async {
    final raw = await DigitornApiClient().fetchAppUiConfig(appId);
    if (raw == null) return null;
    final parsed = AppUiConfig.fromJson(raw);
    _cache[appId] = parsed;
    notifyListeners();
    return parsed;
  }

  /// Force-refetch — called when the user hits "Reload app" or on an
  /// `app_redeployed` SSE event.
  Future<AppUiConfig?> invalidate(String appId) async {
    _cache.remove(appId);
    _inflight.remove(appId);
    return ensure(appId);
  }

  /// Reset the whole cache (logout, daemon switch, tests).
  void clear() {
    if (_cache.isEmpty && _inflight.isEmpty) return;
    _cache.clear();
    _inflight.clear();
    notifyListeners();
  }

  /// Convenience: `true` when the current app is in auto-approve
  /// mode. Returns false when not yet loaded (safest default — shows
  /// approve/reject controls until we know otherwise).
  bool isAutoApprove(String appId) {
    final cfg = _cache[appId];
    return cfg?.workspace.autoApprove ?? false;
  }
}
