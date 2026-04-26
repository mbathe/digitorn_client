/// Hub HTTP client — thin wrappers over the daemon's `/api/hub/*` proxy.
///
/// The client never talks to https://hub.digitorn.ai directly. Every call
/// goes to the local daemon, which carries the user's daemon JWT and
/// forwards to the hub with the cached hub session token.
///
/// Mirror of the web `hub-api.ts` (`digitorn_web/src/lib/hub-api.ts`).
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/hub/hub_models.dart';
import 'api_client.dart';

class HubService {
  HubService._();
  static final HubService _instance = HubService._();
  factory HubService() => _instance;

  Dio get _dio => DigitornApiClient().dio;

  Options _opts() => Options(
        // Keep 4xx out of throws so callers can branch on `statusCode`
        // (the 409 install path is critical here — we MUST inspect the
        // body, not bubble it as an exception).
        validateStatus: (s) => s != null && s < 500,
        headers: const {'Content-Type': 'application/json'},
      );

  // ── Session ─────────────────────────────────────────────────────────────

  Future<HubSession> me() async {
    try {
      final r = await _dio.get('/api/hub/me', options: _opts());
      if (r.statusCode != 200 || r.data is! Map) {
        return const HubSession(loggedIn: false, hubUrl: '');
      }
      return HubSession.fromJson((r.data as Map).cast<String, dynamic>());
    } catch (e) {
      debugPrint('HubService.me: $e');
      return const HubSession(loggedIn: false, hubUrl: '');
    }
  }

  /// Returns null when credentials are rejected (401) so the UI can
  /// show "invalid email or password" without try/catch.
  Future<HubSession?> login({
    required String email,
    required String password,
  }) async {
    try {
      final r = await _dio.post(
        '/api/hub/login',
        data: {'email': email, 'password': password},
        options: _opts(),
      );
      if (r.statusCode == 200 && r.data is Map) {
        return HubSession.fromJson((r.data as Map).cast<String, dynamic>());
      }
      return null;
    } catch (e) {
      debugPrint('HubService.login: $e');
      return null;
    }
  }

  Future<bool> logout() async {
    try {
      final r = await _dio.post('/api/hub/logout', options: _opts());
      return r.statusCode == 200 || r.statusCode == 204;
    } catch (e) {
      debugPrint('HubService.logout: $e');
      return false;
    }
  }

  // ── Search ─────────────────────────────────────────────────────────────

  Future<HubSearchResponse?> search({
    String? q,
    String? category,
    String? tag,
    HubRiskLevel? riskLevel,
    String? publisher,
    bool? includeUnverified,
    int page = 1,
    int pageSize = 20,
  }) async {
    final qp = <String, dynamic>{
      if (q != null && q.isNotEmpty) 'q': q,
      if (category != null) 'category': category,
      if (tag != null) 'tag': tag,
      if (riskLevel != null) 'risk_level': hubRiskToString(riskLevel),
      if (publisher != null) 'publisher': publisher,
      if (includeUnverified != null) 'include_unverified': includeUnverified,
      'page': page,
      'page_size': pageSize,
    };
    try {
      final r = await _dio.get(
        '/api/hub/search',
        queryParameters: qp,
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return HubSearchResponse.fromJson(
        (r.data as Map).cast<String, dynamic>(),
      );
    } catch (e) {
      debugPrint('HubService.search: $e');
      return null;
    }
  }

  // ── Package detail ─────────────────────────────────────────────────────

  Future<HubPackageDetail?> packageDetail(
    String publisher,
    String packageId,
  ) async {
    try {
      final r = await _dio.get(
        '/api/hub/packages/${Uri.encodeComponent(publisher)}'
        '/${Uri.encodeComponent(packageId)}',
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return HubPackageDetail.fromJson(
        (r.data as Map).cast<String, dynamic>(),
      );
    } catch (e) {
      debugPrint('HubService.packageDetail: $e');
      return null;
    }
  }

  // ── Reviews ────────────────────────────────────────────────────────────

  Future<HubReviewListResponse?> reviews(
    String publisher,
    String packageId, {
    HubReviewSort sort = HubReviewSort.recent,
    int page = 1,
    int pageSize = 20,
  }) async {
    try {
      final r = await _dio.get(
        '/api/hub/packages/${Uri.encodeComponent(publisher)}'
        '/${Uri.encodeComponent(packageId)}/reviews',
        queryParameters: {
          'sort': hubReviewSortToQuery(sort),
          'page': page,
          'page_size': pageSize,
        },
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return HubReviewListResponse.fromJson(
        (r.data as Map).cast<String, dynamic>(),
      );
    } catch (e) {
      debugPrint('HubService.reviews: $e');
      return null;
    }
  }

  /// Submit a review. Returns:
  ///   * the [HubReviewItem] on 201
  ///   * `null` on transport / 5xx
  ///   * a [HubServiceError] thrown for 401 / 403 / 429 so the UI can
  ///     show the right message.
  Future<HubReviewItem?> submitReview(
    String publisher,
    String packageId, {
    required int rating,
    String? body,
  }) async {
    try {
      final r = await _dio.post(
        '/api/hub/packages/${Uri.encodeComponent(publisher)}'
        '/${Uri.encodeComponent(packageId)}/reviews',
        data: {
          'rating': rating,
          if (body != null) 'body': body,
        },
        options: _opts(),
      );
      if (r.statusCode == 200 || r.statusCode == 201) {
        if (r.data is Map) {
          return HubReviewItem.fromJson(
            (r.data as Map).cast<String, dynamic>(),
          );
        }
        return null;
      }
      throw HubServiceError(
        status: r.statusCode ?? 0,
        message: _extractDetail(r.data) ?? 'Review submission failed',
      );
    } on HubServiceError {
      rethrow;
    } catch (e) {
      debugPrint('HubService.submitReview: $e');
      return null;
    }
  }

  // ── Reports ────────────────────────────────────────────────────────────

  Future<HubReportOut?> submitReport(
    String publisher,
    String packageId, {
    required HubReportReason reason,
    String? details,
  }) async {
    try {
      final r = await _dio.post(
        '/api/hub/packages/${Uri.encodeComponent(publisher)}'
        '/${Uri.encodeComponent(packageId)}/reports',
        data: {
          'reason': hubReportReasonToString(reason),
          if (details != null) 'details': details,
        },
        options: _opts(),
      );
      if (r.statusCode == 200 || r.statusCode == 201) {
        if (r.data is Map) {
          return HubReportOut.fromJson(
            (r.data as Map).cast<String, dynamic>(),
          );
        }
        return null;
      }
      throw HubServiceError(
        status: r.statusCode ?? 0,
        message: _extractDetail(r.data) ?? 'Report submission failed',
      );
    } on HubServiceError {
      rethrow;
    } catch (e) {
      debugPrint('HubService.submitReport: $e');
      return null;
    }
  }

  // ── Stats ──────────────────────────────────────────────────────────────

  Future<HubPackageStats?> stats(
    String publisher,
    String packageId, {
    int rangeDays = 30,
  }) async {
    try {
      final r = await _dio.get(
        '/api/hub/packages/${Uri.encodeComponent(publisher)}'
        '/${Uri.encodeComponent(packageId)}/stats',
        queryParameters: {'range': rangeDays},
        options: _opts(),
      );
      if (r.statusCode != 200 || r.data is! Map) return null;
      return HubPackageStats.fromJson(
        (r.data as Map).cast<String, dynamic>(),
      );
    } catch (e) {
      debugPrint('HubService.stats: $e');
      return null;
    }
  }

  // ── Install (with consent flow) ────────────────────────────────────────

  Future<HubInstallResult?> install({
    required String publisher,
    required String packageId,
    String? version,
    HubInstallScope scope = HubInstallScope.user,
    bool acceptPermissions = false,
  }) async {
    try {
      final r = await _dio.post(
        '/api/hub/install',
        data: {
          'publisher': publisher,
          'package_id': packageId,
          if (version != null) 'version': version,
          'scope': hubInstallScopeToString(scope),
          'accept_permissions': acceptPermissions,
        },
        options: _opts(),
      );
      if (r.statusCode == 200 && r.data is Map) {
        return HubInstallOk(
          HubInstallSuccess.fromJson((r.data as Map).cast<String, dynamic>()),
        );
      }
      if (r.statusCode == 409 && r.data is Map) {
        // Daemon wraps as `{ detail: { error, package_id, permissions } }`.
        final raw = (r.data as Map).cast<String, dynamic>();
        final detail = raw['detail'] is Map
            ? (raw['detail'] as Map).cast<String, dynamic>()
            : raw;
        if (detail['error'] == 'permissions_required' &&
            detail['permissions'] is Map) {
          return HubInstallNeedsConsent(
            HubPermissionsBreakdown.fromJson(
              (detail['permissions'] as Map).cast<String, dynamic>(),
            ),
          );
        }
      }
      throw HubServiceError(
        status: r.statusCode ?? 0,
        message: _extractDetail(r.data) ?? 'Install failed',
      );
    } on HubServiceError {
      rethrow;
    } catch (e) {
      debugPrint('HubService.install: $e');
      return null;
    }
  }
}

class HubServiceError implements Exception {
  final int status;
  final String message;
  HubServiceError({required this.status, required this.message});

  @override
  String toString() => 'HubServiceError($status): $message';
}

String? _extractDetail(dynamic body) {
  if (body is Map) {
    final raw = body.cast<String, dynamic>();
    final detail = raw['detail'];
    if (detail is String) return detail;
    if (detail is Map) {
      final m = detail.cast<String, dynamic>();
      return (m['message'] as String?) ?? (m['error'] as String?);
    }
    final err = raw['error'];
    if (err is String) return err;
    final msg = raw['message'];
    if (msg is String) return msg;
  }
  return null;
}
