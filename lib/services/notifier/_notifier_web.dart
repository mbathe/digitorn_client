/// Browser notifications backend — uses the HTML5 Notification API
/// via dart:js_interop / package:web. Pulled in via conditional
/// import from [notifier.dart] so the desktop binary never sees
/// dart:html / web-only APIs.
library;

import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

bool _granted = false;

Future<void> initNotifier() async {
  // Permission isn't requested at init — only on first show — so the
  // browser doesn't show a permission popup before the user does
  // anything. We just check the cached state.
  try {
    _granted = web.Notification.permission == 'granted';
  } catch (_) {
    _granted = false;
  }
}

Future<bool> requestNotificationPermission() async {
  try {
    if (web.Notification.permission == 'granted') {
      _granted = true;
      return true;
    }
    if (web.Notification.permission == 'denied') return false;
    final result = await web.Notification.requestPermission().toDart;
    _granted = result.toDart == 'granted';
    return _granted;
  } catch (e) {
    debugPrint('Notifier (web) permission error: $e');
    return false;
  }
}

Future<void> showNotification({
  required String title,
  String body = '',
}) async {
  if (!_granted) {
    final ok = await requestNotificationPermission();
    if (!ok) return;
  }
  try {
    web.Notification(
      title,
      web.NotificationOptions(
        body: body,
        // Re-use the favicon as the toast icon — works on every
        // browser that supports notifications.
        icon: '/favicon.png',
      ),
    );
  } catch (e) {
    debugPrint('Notifier (web) show error: $e');
  }
}
