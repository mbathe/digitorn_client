/// User-facing preferences persisted across sessions via
/// SharedPreferences. Distinct from [AuthService] (credentials) and
/// [ThemeService] (single boolean dark/light) because it groups the
/// long tail of "settings page" choices: language, accent colour,
/// notification toggles, UI density, default model.
///
/// Layout decisions kept here are the ones we can persist locally
/// without daemon support. Anything that needs server enforcement
/// (quotas, billing) lives in dedicated services.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

class PreferencesService extends ChangeNotifier {
  static final PreferencesService _i = PreferencesService._();
  factory PreferencesService() => _i;
  PreferencesService._();

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 8),
    validateStatus: (s) => s != null && s < 500,
  ))..interceptors.add(AuthService().authInterceptor);
  Timer? _pushDebounce;

  // ── Keys ─────────────────────────────────────────────────────────
  static const _kLanguage = 'pref.language';
  static const _kAccent = 'pref.accent';
  static const _kDensity = 'pref.density';
  static const _kNotifyDesktop = 'pref.notify.desktop';
  static const _kNotifyPush = 'pref.notify.push';
  static const _kNotifySound = 'pref.notify.sound';
  static const _kNotifyOnCompletion = 'pref.notify.on_completion';
  static const _kNotifyOnError = 'pref.notify.on_error';
  static const _kNotifyOnMention = 'pref.notify.on_mention';
  static const _kQuietHoursStart = 'pref.notify.quiet_start';
  static const _kQuietHoursEnd = 'pref.notify.quiet_end';
  static const _kQuietHoursTz = 'pref.notify.quiet_tz';
  static const _kChannelEmail = 'pref.notify.channel_email';

  // ── State ────────────────────────────────────────────────────────
  String language = 'en'; // en | fr | es | de
  String accent = 'blue'; // blue | purple | green | orange | red | pink
  String density = 'comfortable'; // compact | comfortable | spacious

  bool notifyDesktop = true;
  bool notifyPush = true;
  bool notifySound = true;
  bool notifyOnCompletion = true;
  bool notifyOnError = true;
  bool notifyOnMention = true;
  int? quietHoursStart; // 0..23, null if unset
  int? quietHoursEnd;
  String quietHoursTz = 'Europe/Paris';
  String? channelEmail;

  /// True once notification prefs have been pulled from the daemon
  /// at least once this process. The first local write blocks the
  /// push if this is false, to avoid overwriting untouched server
  /// state with stale local defaults.
  bool _serverLoaded = false;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    language = p.getString(_kLanguage) ?? 'en';
    accent = p.getString(_kAccent) ?? 'blue';
    density = p.getString(_kDensity) ?? 'comfortable';
    notifyDesktop = p.getBool(_kNotifyDesktop) ?? true;
    notifyPush = p.getBool(_kNotifyPush) ?? true;
    notifySound = p.getBool(_kNotifySound) ?? true;
    notifyOnCompletion = p.getBool(_kNotifyOnCompletion) ?? true;
    notifyOnError = p.getBool(_kNotifyOnError) ?? true;
    notifyOnMention = p.getBool(_kNotifyOnMention) ?? true;
    quietHoursStart = p.getInt(_kQuietHoursStart);
    quietHoursEnd = p.getInt(_kQuietHoursEnd);
    quietHoursTz = p.getString(_kQuietHoursTz) ?? 'Europe/Paris';
    channelEmail = p.getString(_kChannelEmail);
    _loaded = true;
    notifyListeners();
    // Best-effort overlay with the server copy. If the daemon is
    // offline or the route isn't deployed, local values remain the
    // source of truth.
    unawaited(syncFromServer());
  }

  /// Pull the user's notification prefs from the daemon and overlay
  /// them on top of the local state. Any field the server omits is
  /// left untouched so a v1 daemon returning a subset still works.
  Future<void> syncFromServer() async {
    final token = AuthService().accessToken;
    if (token == null) return;
    try {
      final r = await _dio.get(
        '${AuthService().baseUrl}/api/users/me/notification-prefs',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (r.statusCode != 200 || r.data is! Map) return;
      final j = (r.data['prefs'] is Map)
          ? (r.data['prefs'] as Map).cast<String, dynamic>()
          : (r.data as Map).cast<String, dynamic>();
      final evs = j['events'];
      final whitelist = (evs is List)
          ? evs.map((e) => e.toString()).toSet()
          : null;
      if (j['desktop'] is bool) notifyDesktop = j['desktop'] as bool;
      if (j['push'] is bool) notifyPush = j['push'] as bool;
      if (j['sound'] is bool) notifySound = j['sound'] as bool;
      // Events whitelist is the source of truth — derive the three
      // local toggles from whichever set the daemon sent.
      if (whitelist != null) {
        notifyOnCompletion = whitelist.contains('session.completed');
        notifyOnError = whitelist.contains('session.failed');
        notifyOnMention = whitelist.contains('mention') ||
            whitelist.contains('session.awaiting_approval');
      }
      if (j['quiet_hours'] is Map) {
        final q = (j['quiet_hours'] as Map).cast<String, dynamic>();
        if (q['start_hour'] is num) {
          quietHoursStart = (q['start_hour'] as num).toInt();
        } else if (q['start'] is num) {
          quietHoursStart = (q['start'] as num).toInt();
        }
        if (q['end_hour'] is num) {
          quietHoursEnd = (q['end_hour'] as num).toInt();
        } else if (q['end'] is num) {
          quietHoursEnd = (q['end'] as num).toInt();
        }
        if (q['tz'] is String) quietHoursTz = q['tz'] as String;
      }
      if (j['channels'] is Map) {
        final ch = (j['channels'] as Map).cast<String, dynamic>();
        channelEmail = ch['email'] as String?;
      }
      _serverLoaded = true;
      notifyListeners();
    } on DioException {
      // Silent — daemon offline or route not deployed.
    }
  }

  /// Push the current notification/quiet-hours state to the daemon.
  /// Debounced so a flurry of toggle flips only results in a single
  /// request. Fire-and-forget: failures are logged, not surfaced.
  void _schedulePush() {
    if (!_serverLoaded) {
      // Never pushed before → do a best-effort immediate push so
      // the server has our baseline.
      unawaited(_pushNow());
      return;
    }
    _pushDebounce?.cancel();
    _pushDebounce =
        Timer(const Duration(milliseconds: 400), () => unawaited(_pushNow()));
  }

  Future<void> _pushNow() async {
    final token = AuthService().accessToken;
    if (token == null) return;
    try {
      final events = <String>[
        if (notifyOnCompletion) 'session.completed',
        if (notifyOnError) 'session.failed',
        if (notifyOnMention) 'session.awaiting_approval',
      ];
      await _dio.put(
        '${AuthService().baseUrl}/api/users/me/notification-prefs',
        data: {
          'desktop': notifyDesktop,
          'push': notifyPush,
          'sound': notifySound,
          'events': events,
          'quiet_hours': {
            'start_hour': ?quietHoursStart,
            'end_hour': ?quietHoursEnd,
            'tz': quietHoursTz,
          },
          'channels': {
            'email': ?channelEmail,
          },
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      _serverLoaded = true;
    } on DioException catch (e) {
      debugPrint('notification-prefs push failed: ${e.message}');
    }
  }

  Future<void> setLanguage(String v) async {
    if (language == v) return;
    language = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLanguage, v);
    notifyListeners();
  }

  Future<void> setAccent(String v) async {
    if (accent == v) return;
    accent = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAccent, v);
    notifyListeners();
  }

  Future<void> setDensity(String v) async {
    if (density == v) return;
    density = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDensity, v);
    notifyListeners();
  }

  Future<void> setNotify({
    bool? desktop,
    bool? push,
    bool? sound,
    bool? onCompletion,
    bool? onError,
    bool? onMention,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (desktop != null) {
      notifyDesktop = desktop;
      await p.setBool(_kNotifyDesktop, desktop);
    }
    if (push != null) {
      notifyPush = push;
      await p.setBool(_kNotifyPush, push);
    }
    if (sound != null) {
      notifySound = sound;
      await p.setBool(_kNotifySound, sound);
    }
    if (onCompletion != null) {
      notifyOnCompletion = onCompletion;
      await p.setBool(_kNotifyOnCompletion, onCompletion);
    }
    if (onError != null) {
      notifyOnError = onError;
      await p.setBool(_kNotifyOnError, onError);
    }
    if (onMention != null) {
      notifyOnMention = onMention;
      await p.setBool(_kNotifyOnMention, onMention);
    }
    notifyListeners();
    _schedulePush();
  }

  Future<void> setQuietHours({int? start, int? end, String? tz}) async {
    quietHoursStart = start;
    quietHoursEnd = end;
    if (tz != null) quietHoursTz = tz;
    final p = await SharedPreferences.getInstance();
    if (start == null) {
      await p.remove(_kQuietHoursStart);
    } else {
      await p.setInt(_kQuietHoursStart, start);
    }
    if (end == null) {
      await p.remove(_kQuietHoursEnd);
    } else {
      await p.setInt(_kQuietHoursEnd, end);
    }
    if (tz != null) await p.setString(_kQuietHoursTz, tz);
    notifyListeners();
    _schedulePush();
  }

  /// Set (or clear) the email channel used for non-desktop
  /// notifications. Daemon uses this for `channels.email` dispatch.
  Future<void> setChannelEmail(String? email) async {
    channelEmail = email?.trim().isEmpty == true ? null : email;
    final p = await SharedPreferences.getInstance();
    if (channelEmail == null) {
      await p.remove(_kChannelEmail);
    } else {
      await p.setString(_kChannelEmail, channelEmail!);
    }
    notifyListeners();
    _schedulePush();
  }

  /// Available languages — display label + ISO code. Add more here
  /// as the i18n bundles land.
  static const languages = <(String code, String label, String flag)>[
    ('en', 'English', '🇬🇧'),
    ('fr', 'Français', '🇫🇷'),
    ('es', 'Español', '🇪🇸'),
    ('de', 'Deutsch', '🇩🇪'),
    ('pt', 'Português', '🇵🇹'),
    ('it', 'Italiano', '🇮🇹'),
  ];

  /// Available accent palettes.
  static const accents = <(String code, String label, int rgb)>[
    ('blue', 'Blue', 0xFF4F8CFF),
    ('purple', 'Purple', 0xFF8B5CF6),
    ('green', 'Green', 0xFF10B981),
    ('orange', 'Orange', 0xFFF59E0B),
    ('red', 'Red', 0xFFEF4444),
    ('pink', 'Pink', 0xFFEC4899),
  ];

  static const densities = <(String code, String label)>[
    ('compact', 'Compact'),
    ('comfortable', 'Comfortable'),
    ('spacious', 'Spacious'),
  ];

  @override
  void dispose() {
    _pushDebounce?.cancel();
    super.dispose();
  }
}
