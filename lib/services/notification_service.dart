import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

/// Desktop notification service — shows OS-level notifications
class NotificationService {
  static final NotificationService _i = NotificationService._();
  factory NotificationService() => _i;
  NotificationService._();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    try {
      await localNotifier.setup(appName: 'Digitorn');
      _initialized = true;
    } catch (e) {
      debugPrint('NotificationService init error: $e');
    }
  }

  /// Show a desktop notification
  Future<void> show({
    required String title,
    String body = '',
  }) async {
    if (!_initialized) await init();
    try {
      final notification = LocalNotification(
        title: title,
        body: body,
      );
      await notification.show();
    } catch (e) {
      debugPrint('Notification error: $e');
    }
  }

  /// Notify when agent turn completes
  void onTurnComplete({String? content, String? error}) {
    if (error != null && error.isNotEmpty) {
      show(title: 'Agent Error', body: error.length > 100 ? '${error.substring(0, 100)}...' : error);
    } else {
      final preview = content != null && content.isNotEmpty
          ? (content.length > 80 ? '${content.substring(0, 80)}...' : content)
          : 'Turn completed';
      show(title: 'Agent Response', body: preview);
    }
  }
}
