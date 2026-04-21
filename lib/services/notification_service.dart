/// High-level notification orchestrator. Subscribes to the
/// [ActivityInboxService.onNewItem] live stream and decides which
/// items deserve an OS toast based on the user's
/// [PreferencesService] toggles + quiet-hours window.
///
/// Cross-platform: delegates the actual surface (local_notifier on
/// desktop, HTML5 Notification on web) to `notifier/notifier.dart`,
/// which is selected by conditional import. Either way, the rest of
/// the app talks to a single [NotificationService] singleton.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'activity_inbox_service.dart';
import 'notifier/notifier.dart' as notifier;
import 'preferences_service.dart';

class NotificationService {
  static final NotificationService _i = NotificationService._();
  factory NotificationService() => _i;
  NotificationService._();

  StreamSubscription<InboxItem>? _inboxSub;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await notifier.initNotifier();
    } catch (e) {
      debugPrint('NotificationService init error: $e');
    }
    _inboxSub?.cancel();
    _inboxSub = ActivityInboxService().onNewItem.listen(_onInboxItem);
  }

  /// Publicly available so the rest of the app can fire one-off
  /// notifications (e.g. "Session created"), bypassing the inbox
  /// policy. Use sparingly.
  Future<void> show({
    required String title,
    String body = '',
  }) async {
    try {
      await notifier.showNotification(title: title, body: body);
    } catch (e) {
      debugPrint('Notification show error: $e');
    }
  }

  /// Asks the OS / browser for permission. No-op on desktop.
  Future<bool> requestPermission() => notifier.requestNotificationPermission();

  // ── Policy ─────────────────────────────────────────────────────────

  void _onInboxItem(InboxItem item) {
    final prefs = PreferencesService();
    if (!prefs.notifyDesktop) return;
    if (_isQuietHour(prefs)) {
      // During quiet hours we still let through the most urgent
      // categories — failures and approval requests — because they
      // need the user's eye even at 03:00.
      const allowedDuringQuiet = {
        InboxItemKind.sessionFailed,
        InboxItemKind.failure,
        InboxItemKind.awaitingApproval,
      };
      if (!allowedDuringQuiet.contains(item.kind)) return;
    }
    if (!_matchesPrefs(prefs, item.kind)) return;

    final (title, body) = _format(item);
    show(title: title, body: body);
  }

  bool _isQuietHour(PreferencesService p) {
    final start = p.quietHoursStart;
    final end = p.quietHoursEnd;
    if (start == null || end == null) return false;
    final now = DateTime.now().hour;
    if (start == end) return false;
    if (start < end) {
      return now >= start && now < end;
    }
    // Wraps around midnight.
    return now >= start || now < end;
  }

  bool _matchesPrefs(PreferencesService p, InboxItemKind kind) {
    switch (kind) {
      case InboxItemKind.sessionCompleted:
      case InboxItemKind.bgActivationFinished:
        return p.notifyOnCompletion;
      case InboxItemKind.sessionFailed:
      case InboxItemKind.failure:
        return p.notifyOnError;
      case InboxItemKind.awaitingApproval:
        // Approvals are always allowed when any notification is on —
        // missing one means the agent stalls indefinitely.
        return true;
      case InboxItemKind.credentialExpired:
      case InboxItemKind.credentialMissing:
        return p.notifyOnError;
      case InboxItemKind.sessionRunning:
        // Don't toast for "still running" — too noisy. The bell pulse
        // is enough.
        return false;
      case InboxItemKind.info:
        return false;
    }
  }

  (String, String) _format(InboxItem item) {
    return (item.title, item.subtitle);
  }

  /// Legacy entry point still used by chat_panel for end-of-turn
  /// pings. Kept for backward compatibility — new code should prefer
  /// pushing into the inbox so the policy + quiet hours apply.
  void onTurnComplete({String? content, String? error}) {
    final prefs = PreferencesService();
    if (!prefs.notifyDesktop) return;
    if (error != null && error.isNotEmpty) {
      if (!prefs.notifyOnError) return;
      show(
        title: 'Agent error',
        body: error.length > 100 ? '${error.substring(0, 100)}…' : error,
      );
    } else {
      if (!prefs.notifyOnCompletion) return;
      final preview = content != null && content.isNotEmpty
          ? (content.length > 80 ? '${content.substring(0, 80)}…' : content)
          : 'Turn completed';
      show(title: 'Agent finished', body: preview);
    }
  }

  void disposeSub() {
    _inboxSub?.cancel();
    _inboxSub = null;
  }
}
