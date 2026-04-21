/// Native notifications backend for every non-web platform.
///
/// Two implementations under one façade:
///   * Desktop (Windows / macOS / Linux) → [local_notifier] — the
///     same path we've been shipping for months, works out of the
///     box with native OS toast centers.
///   * Mobile (Android / iOS) → [flutter_local_notifications],
///     which owns the correct Android channel + iOS permission
///     dance that `local_notifier` doesn't support.
///
/// Web has its own file selected at compile time via conditional
/// import in [notifier.dart].
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart' as ln;

final FlutterLocalNotificationsPlugin _mobilePlugin =
    FlutterLocalNotificationsPlugin();

bool _initialized = false;

bool get _isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
bool get _isMobile => Platform.isAndroid || Platform.isIOS;

Future<void> initNotifier() async {
  if (_initialized) return;
  try {
    if (_isDesktop) {
      await ln.localNotifier.setup(appName: 'Digitorn');
    } else if (_isMobile) {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const settings = InitializationSettings(android: android, iOS: ios);
      await _mobilePlugin.initialize(settings);
    }
    _initialized = true;
  } catch (e) {
    debugPrint('Notifier (io) init error: $e');
  }
}

Future<bool> requestNotificationPermission() async {
  if (_isDesktop) return true;
  try {
    if (Platform.isAndroid) {
      final android = _mobilePlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final ok = await android?.requestNotificationsPermission();
      return ok ?? false;
    }
    if (Platform.isIOS) {
      final ios = _mobilePlugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final ok = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return ok ?? false;
    }
    return true;
  } catch (e) {
    debugPrint('Notifier (io) permission error: $e');
    return false;
  }
}

Future<void> showNotification({
  required String title,
  String body = '',
}) async {
  if (!_initialized) await initNotifier();
  try {
    if (_isDesktop) {
      final n = ln.LocalNotification(title: title, body: body);
      await n.show();
      return;
    }
    if (_isMobile) {
      const android = AndroidNotificationDetails(
        'digitorn_default',
        'Digitorn',
        channelDescription: 'Activity and error notifications',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
      );
      const ios = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      const details = NotificationDetails(android: android, iOS: ios);
      await _mobilePlugin.show(
        DateTime.now().millisecondsSinceEpoch.remainder(1 << 30),
        title,
        body,
        details,
      );
    }
  } catch (e) {
    debugPrint('Notifier (io) show error: $e');
  }
}
