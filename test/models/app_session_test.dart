import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/services/session_service.dart';

void main() {
  group('AppSession', () {
    test('fromJson parses all fields', () {
      final s = AppSession.fromJson({
        'session_id': 'sess-123',
        'app_id': 'my-app',
        'is_active': true,
        'message_count': 5,
        'title': 'My chat',
        'created_at': 1700000000.0,
        'last_active': 1700003600.0,
      });
      expect(s.sessionId, 'sess-123');
      expect(s.appId, 'my-app');
      expect(s.isActive, true);
      expect(s.messageCount, 5);
      expect(s.title, 'My chat');
      expect(s.createdAt, isNotNull);
      expect(s.lastActive, isNotNull);
    });

    test('displayTitle uses title if available', () {
      final s = AppSession(sessionId: 'abcdef12345', appId: 'app', title: 'My conversation');
      expect(s.displayTitle, 'My conversation');
    });

    test('displayTitle falls back to shortId', () {
      final s = AppSession(sessionId: 'abcdef12345', appId: 'app');
      expect(s.displayTitle, 'abcdef12');
    });

    test('shortId truncates to 8 chars', () {
      final s = AppSession(sessionId: 'abcdef12345678', appId: 'app');
      expect(s.shortId, 'abcdef12');
    });

    test('shortId keeps short ids as is', () {
      final s = AppSession(sessionId: 'abc', appId: 'app');
      expect(s.shortId, 'abc');
    });

    test('timeAgo shows relative time', () {
      final now = DateTime.now();
      final s = AppSession(
        sessionId: 'id', appId: 'app',
        lastActive: now.subtract(const Duration(minutes: 5)),
      );
      expect(s.timeAgo, '5m ago');
    });

    test('timeAgo shows now for recent', () {
      final s = AppSession(
        sessionId: 'id', appId: 'app',
        lastActive: DateTime.now(),
      );
      expect(s.timeAgo, 'now');
    });

    test('parseDate handles unix timestamp', () {
      final dt = AppSession.parseDate(1700000000.0);
      expect(dt, isNotNull);
    });

    test('parseDate handles ISO string', () {
      final dt = AppSession.parseDate('2024-01-01T00:00:00Z');
      expect(dt, isNotNull);
    });

    test('parseDate returns null for null', () {
      expect(AppSession.parseDate(null), isNull);
    });
  });
}
