/// Platform-aware OS notification facade. Re-exports the right
/// backend at compile time so neither dart:html nor local_notifier
/// is reachable on the wrong platform.
///
/// Public API:
///   * initNotifier()                 — call once at app start
///   * requestNotificationPermission()— web only; no-op on desktop
///   * showNotification(title, body)  — fire and forget
library;

export '_notifier_io.dart' if (dart.library.js_interop) '_notifier_web.dart';
