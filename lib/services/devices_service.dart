/// Device registry. On startup we register this client with the
/// daemon via `POST /api/users/me/devices` so the user can audit / revoke it
/// from any session. The device id is a UUID persisted locally so
/// the same row gets updated across restarts.
///
/// On mobile builds the `push_token` field is populated with the FCM
/// token; on desktop/web it's omitted (no push channel available)
/// but the device row still appears in the user's device list so
/// session attribution works consistently.
library;

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

class Device {
  final String id;
  final String platform;
  final String name;
  final DateTime? registeredAt;
  final DateTime? lastSeenAt;
  final bool isCurrent;
  const Device({
    required this.id,
    required this.platform,
    required this.name,
    this.registeredAt,
    this.lastSeenAt,
    this.isCurrent = false,
  });

  factory Device.fromJson(Map<String, dynamic> j, {String? currentId}) {
    final id = j['id'] as String? ?? j['device_id'] as String? ?? '';
    return Device(
      id: id,
      platform: j['platform'] as String? ?? 'unknown',
      name: j['name'] as String? ?? id,
      registeredAt: _parseDate(j['registered_at'] ?? j['created_at']),
      lastSeenAt: _parseDate(j['last_seen_at'] ?? j['updated_at']),
      isCurrent: currentId != null && currentId == id,
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

class DevicesService extends ChangeNotifier {
  static final DevicesService _i = DevicesService._();
  factory DevicesService() => _i;
  DevicesService._();

  static const _kDeviceId = 'device.id';

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);

  String? _deviceId;
  String? get deviceId => _deviceId;

  List<Device> _devices = const [];
  List<Device> get devices => _devices;

  bool _registered = false;
  bool get registered => _registered;

  /// Ensure we have a stable device id. First call hits
  /// SharedPreferences — if we've never registered before we mint a
  /// new UUID-ish string and persist it.
  Future<String> _ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = _mintUuid();
      await p.setString(_kDeviceId, id);
    }
    _deviceId = id;
    return id;
  }

  /// Register this client with the daemon. Called from `main()` after
  /// auth loads and again on login. Idempotent — the daemon does an
  /// upsert keyed on `device_id`.
  Future<void> registerCurrentDevice({
    String? pushToken,
    String? appVersion,
  }) async {
    final token = AuthService().accessToken;
    if (token == null) return;
    final id = await _ensureDeviceId();
    final platform = _platformName();
    final name = _friendlyName(platform);
    try {
      final r = await _dio.post(
        '${AuthService().baseUrl}/api/users/me/devices',
        data: {
          'device_id': id,
          'platform': platform,
          'device_name': name,
          'fcm_token': ?pushToken,
          'app_version': ?appVersion,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if ((r.statusCode ?? 0) < 300 && r.statusCode != 0) {
        _registered = true;
        notifyListeners();
      }
    } on DioException catch (e) {
      debugPrint('devices register failed: ${e.message}');
    }
  }

  Future<void> refreshList() async {
    final token = AuthService().accessToken;
    if (token == null) return;
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/users/me/devices',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (r.statusCode != 200) return;
      final raw = r.data is Map && r.data['devices'] is List
          ? r.data['devices'] as List
          : (r.data is List ? r.data as List : const []);
      final current = await _ensureDeviceId();
      _devices = raw
          .whereType<Map>()
          .map((m) =>
              Device.fromJson(m.cast<String, dynamic>(), currentId: current))
          .toList();
      notifyListeners();
    } on DioException catch (e) {
      debugPrint('devices list failed: ${e.message}');
    }
  }

  Future<bool> revoke(String id) async {
    final token = AuthService().accessToken;
    if (token == null) return false;
    try {
      final r = await _dio.delete(
        '${AuthService().baseUrl}/api/users/me/devices/$id',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (r.statusCode == 200 || r.statusCode == 204) {
        _devices = _devices.where((d) => d.id != id).toList();
        notifyListeners();
        return true;
      }
      return false;
    } on DioException {
      return false;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────

  String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  String _friendlyName(String platform) {
    switch (platform) {
      case 'windows':
        return 'Windows desktop';
      case 'macos':
        return 'macOS desktop';
      case 'linux':
        return 'Linux desktop';
      case 'web':
        return 'Browser';
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      default:
        return 'Digitorn client';
    }
  }

  String _mintUuid() {
    // Lightweight v4-like UUID without a native dep. Good enough as
    // a device fingerprint — collisions at user scope are effectively
    // impossible. The server validates format and owns the real id.
    final rng = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => rng.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + rng.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}
