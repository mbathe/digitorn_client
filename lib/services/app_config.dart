import 'package:flutter/foundation.dart';

/// Centralized runtime configuration for the Digitorn client.
///
/// The daemon URL resolves in this order:
///   1. User-saved URL (SharedPreferences, via AuthService.baseUrl)
///   2. --dart-define=DIGITORN_DAEMON_URL=... at build time
///   3. defaultDaemonUrl fallback (localhost for local-dev only)
class AppConfig {
  static const String defaultDaemonUrl = String.fromEnvironment(
    'DIGITORN_DAEMON_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  /// HTTP timeouts — single source of truth across all services.
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// SSE streams are long-lived: we only want a ceiling, not a real timeout.
  /// Auto-reconnect logic in SessionService handles drops.
  static const Duration sseReceiveTimeout = Duration(minutes: 5);

  /// Auth flows (login / refresh / me).
  static const Duration authConnectTimeout = Duration(seconds: 15);
  static const Duration authReceiveTimeout = Duration(seconds: 25);

  static bool get isDebug => kDebugMode;
}
