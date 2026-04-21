/// Digitorn Widgets v1 — HTTP service.
///
/// Thin wrapper around the daemon's `/api/apps/{id}/widgets*`
/// routes. SSE `widget:*` events are decoded by the existing
/// session SSE pipeline in `session_service.dart` and forwarded
/// to [WidgetEventBus] so hosts can subscribe by widget_id.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import 'models.dart';

class WidgetsService extends ChangeNotifier {
  static final WidgetsService _i = WidgetsService._();
  factory WidgetsService() => _i;
  WidgetsService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 12),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String get _base => AuthService().baseUrl;

  /// Per-app spec cache. Cleared on app switch.
  final Map<String, WidgetsAppSpec> _cache = {};

  Future<WidgetsAppSpec> fetchSpec(String appId, {bool force = false}) async {
    if (!force && _cache.containsKey(appId)) return _cache[appId]!;
    try {
      final r = await _dio.get('$_base/api/apps/$appId/widgets');
      if (r.statusCode == 404 || r.statusCode == 501) {
        _cache[appId] = WidgetsAppSpec.empty;
        return WidgetsAppSpec.empty;
      }
      final data = _unwrap(r.data);
      if (data == null) {
        _cache[appId] = WidgetsAppSpec.empty;
        return WidgetsAppSpec.empty;
      }
      final spec = WidgetsAppSpec.fromJson(data);
      _cache[appId] = spec;
      notifyListeners();
      return spec;
    } catch (e) {
      debugPrint('WidgetsService.fetchSpec($appId) failed: $e');
      _cache[appId] = WidgetsAppSpec.empty;
      return WidgetsAppSpec.empty;
    }
  }

  void clearCache() {
    _cache.clear();
    notifyListeners();
  }

  /// `POST /api/apps/{id}/widgets/action` — sends a widget action
  /// payload to the daemon. Returns the daemon's response envelope
  /// (`effect:` may contain a follow-up action to execute locally).
  Future<Map<String, dynamic>?> postAction(
    String appId, {
    required Map<String, dynamic> payload,
  }) async {
    try {
      final r = await _dio.post(
        '$_base/api/apps/$appId/widgets/action',
        data: payload,
      );
      return _unwrap(r.data);
    } catch (e) {
      debugPrint('WidgetsService.postAction failed: $e');
      return null;
    }
  }

  /// `POST` / `GET` a data binding on demand. Used by `refresh`
  /// actions and initial fetches.
  Future<dynamic> fetchBinding(
    String appId, {
    required String method,
    required String url,
    Map<String, dynamic>? query,
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final fullUrl = _resolveUrl(appId, url);
    try {
      final r = await _dio.request(
        fullUrl,
        data: body,
        queryParameters: query,
        options: Options(
          method: method.toUpperCase(),
          headers: {'Accept': 'application/json', ...?headers},
        ),
      );
      // Tolerant unwrap — accept envelope {success,data:{...}} OR
      // raw body (daemon may send either depending on endpoint).
      final raw = r.data;
      if (raw is Map && raw['success'] is bool) {
        return raw['data'];
      }
      return raw;
    } catch (e) {
      debugPrint('fetchBinding failed ($url): $e');
      rethrow;
    }
  }

  /// Resolve a widget URL relative to the app's daemon base. Apps
  /// use `/some/path` → becomes `{baseUrl}/api/apps/{id}/some/path`.
  /// Absolute URLs are returned as-is (with a warning — widgets
  /// aren't supposed to reach outside the app scope).
  String _resolveUrl(String appId, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    final clean = url.startsWith('/') ? url : '/$url';
    return '$_base/api/apps/$appId$clean';
  }

  Map<String, dynamic>? _unwrap(dynamic body) {
    if (body is! Map) return null;
    if (body['success'] == false) return null;
    final data = body['data'];
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    // Some daemon responses return the widgets object at the root.
    if (body.containsKey('version') ||
        body.containsKey('chat_side') ||
        body.containsKey('workspace_tabs')) {
      return body.cast<String, dynamic>();
    }
    return null;
  }
}

/// Global bus for inbound `widget:*` Socket.IO events. A [WidgetHost]
/// subscribes at mount with its widget_id and receives only events
/// targeted at it.
///
/// The chat panel's event handler is responsible for calling [publish]
/// when it sees a `widget:*` event in the Socket.IO stream.
class WidgetEventBus {
  static final WidgetEventBus _i = WidgetEventBus._();
  factory WidgetEventBus() => _i;
  WidgetEventBus._();

  final StreamController<WidgetEvent> _ctrl =
      StreamController<WidgetEvent>.broadcast();

  Stream<WidgetEvent> get stream => _ctrl.stream;

  void publish(WidgetEvent event) {
    _ctrl.add(event);
  }

  void publishRaw(String eventName, Map<String, dynamic> data) {
    publish(WidgetEvent.fromJson(eventName, data));
  }

  /// Convenience: subscribe to events for a specific widget_id.
  /// The callback only fires for matching events; un-targeted
  /// events (e.g. inline renders with a fresh id) are ignored.
  StreamSubscription<WidgetEvent> listenFor(
    String widgetId,
    void Function(WidgetEvent) onEvent,
  ) {
    return stream.where((e) => e.widgetId == widgetId).listen(onEvent);
  }
}
