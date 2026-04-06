import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthUser {
  final String userId;
  final String? email;
  final String? displayName;
  final List<String> roles;

  AuthUser({
    required this.userId,
    this.email,
    this.displayName,
    this.roles = const [],
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        userId: json['user_id'] ?? '',
        email: json['email'],
        displayName: json['display_name'],
        roles: List<String>.from(json['roles'] ?? []),
      );
}

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyBaseUrl = 'base_url';

  String baseUrl = 'http://127.0.0.1:8000';
  String? _accessToken;
  String? _refreshToken;
  AuthUser? currentUser;
  bool isLoading = false;
  String? lastError;

  String? get accessToken => _accessToken;
  bool get isAuthenticated => _accessToken != null;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  ));

  /// Create a Dio interceptor that auto-refreshes on 401.
  /// Add this to any Dio instance that calls the daemon API.
  Interceptor get authInterceptor => InterceptorsWrapper(
    onRequest: (options, handler) async {
      // Ensure token is fresh before each request
      await ensureValidToken();
      final token = _accessToken;
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    },
    onError: (error, handler) async {
      if (error.response?.statusCode == 401) {
        // Try refresh once
        final ok = await refreshToken();
        if (ok) {
          // Retry with new token
          error.requestOptions.headers['Authorization'] = 'Bearer $_accessToken';
          try {
            final resp = await _dio.fetch(error.requestOptions);
            return handler.resolve(resp);
          } catch (_) {}
        }
        // Refresh failed — force logout to redirect to login
        await logout();
      }
      handler.next(error);
    },
  );

  // ─── Persistence ─────────────────────────────────────────────────────────

  Future<void> loadFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString(_keyAccessToken);
    _refreshToken = prefs.getString(_keyRefreshToken);
    baseUrl = prefs.getString(_keyBaseUrl) ?? 'http://127.0.0.1:8000';
    if (_accessToken != null) {
      await _fetchMe();
    }
    notifyListeners();
  }

  Future<void> _saveTokens(String access, String? refresh) async {
    _accessToken = access;
    _refreshToken = refresh;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAccessToken, access);
    if (refresh != null) await prefs.setString(_keyRefreshToken, refresh);
    await prefs.setString(_keyBaseUrl, baseUrl);
  }

  Future<void> _clearTokens() async {
    _accessToken = null;
    _refreshToken = null;
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyRefreshToken);
  }

  // ─── Auth Header ─────────────────────────────────────────────────────────

  Options get _authOptions => Options(headers: {
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      });

  // ─── Login ───────────────────────────────────────────────────────────────

  Future<bool> login({
    String? username,
    String? email,
    required String password,
  }) async {
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final response = await _dio.post(
        '$baseUrl/auth/login',
        data: {
          if (username != null) 'username': username,
          if (email != null) 'email': email,
          'password': password,
        },
      );
      if (response.statusCode == 200) {
        final data = response.data;
        await _saveTokens(data['access_token'], data['refresh_token']);
        currentUser = AuthUser(
          userId: data['user_id'] ?? '',
          email: data['email'],
          displayName: data['display_name'],
          roles: List<String>.from(data['roles'] ?? []),
        );
        isLoading = false;
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      lastError = _extractError(e);
    } catch (e) {
      lastError = e.toString();
    }
    isLoading = false;
    notifyListeners();
    return false;
  }

  // ─── Register ────────────────────────────────────────────────────────────

  Future<bool> register({
    required String username,
    required String password,
    String? email,
    String? displayName,
  }) async {
    isLoading = true;
    lastError = null;
    notifyListeners();
    try {
      final response = await _dio.post(
        '$baseUrl/auth/register',
        data: {
          'username': username,
          'password': password,
          if (email != null) 'email': email,
          if (displayName != null) 'display_name': displayName,
        },
      );
      if (response.statusCode == 200) {
        final data = response.data;
        await _saveTokens(data['access_token'], data['refresh_token']);
        currentUser = AuthUser(
          userId: data['user_id'] ?? '',
          email: data['email'],
          displayName: data['display_name'],
          roles: List<String>.from(data['roles'] ?? []),
        );
        isLoading = false;
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      lastError = _extractError(e);
    } catch (e) {
      lastError = e.toString();
    }
    isLoading = false;
    notifyListeners();
    return false;
  }

  // ─── Ensure token is valid (refresh if expired) ──────────────────────────

  Future<void> ensureValidToken() async {
    if (_accessToken == null) return;
    // JWT tokens have 3 parts; decode payload to check exp
    try {
      final parts = _accessToken!.split('.');
      if (parts.length == 3) {
        // Pad base64 if needed
        var payload = parts[1];
        while (payload.length % 4 != 0) payload += '=';
        final decoded = utf8.decode(base64Url.decode(payload));
        final Map<String, dynamic> claims = jsonDecode(decoded);
        final exp = claims['exp'] as int? ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        // Refresh if less than 60s left
        if (exp - now < 60) {
          await refreshToken();
        }
      }
    } catch (_) {
      // If decode fails, try refresh anyway
      await refreshToken();
    }
  }

  // ─── Refresh ─────────────────────────────────────────────────────────────

  Future<bool> refreshToken() async {
    if (_refreshToken == null) {
      debugPrint('refreshToken: no refresh token');
      return false;
    }
    try {
      final response = await _dio.post(
        '$baseUrl/auth/refresh',
        data: {'refresh_token': _refreshToken},
        options: Options(
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      debugPrint('refreshToken ← ${response.statusCode}');
      if (response.statusCode == 200 && response.data['access_token'] != null) {
        await _saveTokens(response.data['access_token'], _refreshToken);
        return true;
      }
    } catch (e) {
      debugPrint('refreshToken error: $e');
    }
    return false;
  }

  // ─── Me ──────────────────────────────────────────────────────────────────

  Future<void> _fetchMe() async {
    try {
      final response = await _dio.get(
        '$baseUrl/auth/me',
        options: _authOptions,
      );
      if (response.statusCode == 200) {
        currentUser = AuthUser.fromJson(response.data);
      }
    } catch (_) {
      // Token likely invalid — clear
      await _clearTokens();
    }
  }

  // ─── Logout ──────────────────────────────────────────────────────────────

  Future<void> logout() async {
    if (_refreshToken != null) {
      try {
        await _dio.post(
          '$baseUrl/auth/logout',
          data: {'refresh_token': _refreshToken},
          options: _authOptions,
        );
      } catch (_) {}
    }
    await _clearTokens();
    notifyListeners();
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  String _extractError(DioException e) {
    try {
      final body = e.response?.data;
      if (body is Map) return body['error'] ?? body['detail'] ?? 'Unknown error';
      if (body is String) return body;
    } catch (_) {}
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return 'Connection timeout — is the daemon running?';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'Cannot connect to daemon at $baseUrl';
    }
    return e.message ?? 'Network error';
  }
}
