/// Probes `GET /api/apps/{appId}/preview/` once per app and caches the
/// result.  Apps that don't ship a static preview answer 404:
///
/// ```json
/// {"success":false,"error":"No static preview available for this app",
///  "detail":"No static preview available for this app","status_code":404}
/// ```
///
/// The IDE layout and preview router watch this service so the whole
/// preview column / tab / segment is hidden when unavailable, instead
/// of rendering the raw JSON error in an iframe.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_service.dart';

class PreviewAvailabilityService extends ChangeNotifier {
  static final PreviewAvailabilityService _i =
      PreviewAvailabilityService._();
  factory PreviewAvailabilityService() => _i;
  PreviewAvailabilityService._();

  // null = not probed yet, true = 200, false = 404/other
  final Map<String, bool> _known = {};
  final Set<String> _inFlight = {};

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 4),
    receiveTimeout: const Duration(seconds: 4),
    validateStatus: (s) => s != null,
  ))..interceptors.add(AuthService().authInterceptor);

  /// Returns:
  ///   * `true`  — endpoint responded 200 (preview can be rendered)
  ///   * `false` — endpoint responded 404 / non-200 (hide the pane)
  ///   * `null`  — not probed yet; callers should render a neutral
  ///               placeholder rather than choose a layout blindly.
  bool? isAvailable(String appId) => _known[appId];

  /// Fire-and-forget probe. Safe to call repeatedly — only sends one
  /// request per app per session, even if the UI flips through a
  /// dozen sessions rapidly.
  Future<void> probe(String appId) async {
    if (appId.isEmpty) return;
    if (_known.containsKey(appId)) return;
    if (_inFlight.contains(appId)) return;
    _inFlight.add(appId);
    try {
      final url = '${AuthService().baseUrl}/api/apps/$appId/preview/';
      final resp = await _dio.get(url);
      final ok = resp.statusCode == 200;
      _known[appId] = ok;
    } catch (e) {
      // Network error ≠ "not available" — but the user still sees a
      // broken iframe, so we treat it as unavailable until the next
      // full reset. Less noisy than a spinner that never resolves.
      _known[appId] = false;
      debugPrint('PreviewAvailabilityService.probe($appId): $e');
    } finally {
      _inFlight.remove(appId);
      notifyListeners();
    }
  }

  /// Drop the cached answer — call on app reinstall / hot-reload when
  /// the daemon may have acquired a preview it didn't have before.
  void invalidate(String appId) {
    if (_known.remove(appId) != null) notifyListeners();
  }

  /// Wipe everything — called on logout.
  void reset() {
    if (_known.isEmpty && _inFlight.isEmpty) return;
    _known.clear();
    _inFlight.clear();
    notifyListeners();
  }
}
