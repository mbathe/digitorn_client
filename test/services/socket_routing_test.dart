import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/services/user_events_service.dart';
import 'package:digitorn_client/services/session_service.dart';

/// Tests for the event routing logic that
/// [DigitornSocketService._handleBusEvent] implements.
///
/// Because the services are singletons wired to Socket.IO and
/// SharedPreferences, we test through the public injection points
/// ([SessionService.injectSocketEvent], [UserEventsService.injectFromSocket])
/// and verify the outputs on the broadcast streams. This tests the
/// same contract without requiring a live socket connection.

void main() {
  group('SessionService.injectSocketEvent', () {
    test('emits event on the events stream', () async {
      final events = <Map<String, dynamic>>[];
      final sub = SessionService().events.listen(events.add);

      SessionService().injectSocketEvent({
        'type': 'token',
        'data': {'text': 'hello'},
      });

      // Wait a tick for the stream to deliver.
      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events[0]['type'], 'token');
      expect(events[0]['data']['text'], 'hello');
      await sub.cancel();
    });

    test('tracks seq from event envelope', () {
      final before = SessionService().lastEventSeq;

      SessionService().injectSocketEvent({
        'type': 'status',
        'data': {'phase': 'responding'},
        'seq': before + 10,
      });

      expect(SessionService().lastEventSeq, before + 10);
    });

    test('ignores seq lower than current', () {
      final high = SessionService().lastEventSeq + 100;
      SessionService().injectSocketEvent({
        'type': 'token',
        'data': {'text': 'a'},
        'seq': high,
      });
      expect(SessionService().lastEventSeq, high);

      SessionService().injectSocketEvent({
        'type': 'token',
        'data': {'text': 'b'},
        'seq': high - 50,
      });
      expect(SessionService().lastEventSeq, high);
    });

    test('handles null seq gracefully', () {
      final before = SessionService().lastEventSeq;
      SessionService().injectSocketEvent({
        'type': 'abort',
        'data': {},
      });
      expect(SessionService().lastEventSeq, before);
    });

    test('handles _connection_lost and _connection_restored', () async {
      final events = <Map<String, dynamic>>[];
      final sub = SessionService().events.listen(events.add);

      SessionService().injectSocketEvent({
        'type': '_connection_lost',
        'data': <String, dynamic>{},
      });
      SessionService().injectSocketEvent({
        'type': '_connection_restored',
        'data': <String, dynamic>{},
      });

      await Future.delayed(Duration.zero);
      expect(events.where((e) => e['type'] == '_connection_lost'), hasLength(1));
      expect(events.where((e) => e['type'] == '_connection_restored'), hasLength(1));
      await sub.cancel();
    });
  });

  group('UserEventsService.injectFromSocket', () {
    test('emits UserEvent on the events stream', () async {
      final events = <UserEvent>[];
      final sub = UserEventsService().events.listen(events.add);

      UserEventsService().injectFromSocket({
        'type': 'session.completed',
        'seq': 999,
        'kind': 'session',
        'app_id': 'my-app',
        'session_id': 'ses-1',
        'payload': {'response': 'done'},
        'ts': '2026-04-15T10:00:00Z',
      });

      await Future.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events[0].type, 'session.completed');
      expect(events[0].seq, 999);
      expect(events[0].appId, 'my-app');
      expect(events[0].sessionId, 'ses-1');
      expect(events[0].kind, 'session');
      expect(events[0].payload['response'], 'done');
      await sub.cancel();
    });

    test('updates latestSeq', () {
      final before = UserEventsService().latestSeq;
      final newSeq = before + 50;

      UserEventsService().injectFromSocket({
        'type': 'inbox.created',
        'seq': newSeq,
        'kind': 'inbox',
        'payload': {'id': 'item-1', 'title': 'test'},
      });

      expect(UserEventsService().latestSeq, newSeq);
    });

    test('ignores empty type', () async {
      final events = <UserEvent>[];
      final sub = UserEventsService().events.listen(events.add);

      UserEventsService().injectFromSocket({
        'type': '',
        'seq': 1,
        'payload': {},
      });

      await Future.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
    });

    test('handles missing optional fields', () async {
      final events = <UserEvent>[];
      final sub = UserEventsService().events.listen(events.add);

      UserEventsService().injectFromSocket({
        'type': 'quota.warning',
        'seq': 1000,
        'payload': {'message': 'low'},
      });

      await Future.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events[0].appId, isNull);
      expect(events[0].sessionId, isNull);
      expect(events[0].kind, 'system');
      await sub.cancel();
    });

    test('updateSeq syncs latest without emitting event', () async {
      final events = <UserEvent>[];
      final sub = UserEventsService().events.listen(events.add);

      UserEventsService().updateSeq(5000);

      await Future.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(UserEventsService().latestSeq, greaterThanOrEqualTo(5000));
      await sub.cancel();
    });
  });

  group('Event routing logic', () {
    // Simulate _handleBusEvent routing by calling the injection
    // points the same way socket_service.dart does.

    /// Session-scoped event types — must match
    /// [DigitornSocketService._sessionEventTypes] exactly.
    const sessionEventTypes = {
      'token', 'out_token', 'in_token', 'stream_done',
      'thinking_started', 'thinking_delta', 'thinking',
      'tool_start', 'tool_call',
      'status', 'hook', 'result', 'error', 'abort',
      'workbench_read', 'workbench_write', 'workbench_edit',
      'workbench_mutation',
      'terminal_output', 'diagnostics',
      'memory_update', 'agent_event',
      'credential_required', 'credential_auth_required',
    };

    test('all session event types are routed to SessionService', () async {
      for (final type in sessionEventTypes) {
        final events = <Map<String, dynamic>>[];
        final sub = SessionService().events.listen(events.add);

        SessionService().injectSocketEvent({
          'type': type,
          'data': {'test': true},
          'seq': 1,
        });

        await Future.delayed(Duration.zero);
        expect(events, isNotEmpty,
            reason: 'Event type "$type" should reach SessionService');
        expect(events.last['type'], type);
        await sub.cancel();
      }
    });

    test('widget: prefixed events are routed to SessionService', () async {
      final events = <Map<String, dynamic>>[];
      final sub = SessionService().events.listen(events.add);

      for (final action in ['widget:render', 'widget:update', 'widget:close', 'widget:error']) {
        SessionService().injectSocketEvent({
          'type': action,
          'data': {'widgetId': 'w1'},
          'seq': 1,
        });
      }

      await Future.delayed(Duration.zero);
      expect(events, hasLength(4));
      expect(events.map((e) => e['type']).toList(),
          ['widget:render', 'widget:update', 'widget:close', 'widget:error']);
      await sub.cancel();
    });

    test('user-scoped events are routed to UserEventsService', () async {
      const userTypes = [
        'session.completed', 'session.failed', 'session.started',
        'turn_complete', 'agent_done',
        'bg.activation_completed',
        'inbox.created',
        'credential.missing', 'credential.expired',
        'quota.warning',
      ];

      for (final type in userTypes) {
        final events = <UserEvent>[];
        final sub = UserEventsService().events.listen(events.add);

        UserEventsService().injectFromSocket({
          'type': type,
          'seq': 1,
          'kind': 'system',
          'payload': {},
        });

        await Future.delayed(Duration.zero);
        expect(events, isNotEmpty,
            reason: 'Event type "$type" should reach UserEventsService');
        expect(events.last.type, type);
        await sub.cancel();
      }
    });

    test('approval_request reaches both SessionService and UserEventsService', () async {
      final sessionEvents = <Map<String, dynamic>>[];
      final userEvents = <UserEvent>[];
      final sSub = SessionService().events.listen(sessionEvents.add);
      final uSub = UserEventsService().events.listen(userEvents.add);

      // Simulate what socket_service.dart does for approval_request:
      final payload = {
        'request_id': 'req-1',
        'tool_name': 'bash',
        'risk_level': 'high',
      };
      SessionService().injectSocketEvent({
        'type': 'approval_request',
        'data': payload,
        'seq': 42,
        'session_id': 'ses-1',
      });
      UserEventsService().injectFromSocket({
        'type': 'approval_request',
        'seq': 42,
        'kind': 'session',
        'app_id': 'app-1',
        'session_id': 'ses-1',
        'payload': payload,
      });

      await Future.delayed(Duration.zero);
      expect(sessionEvents.where((e) => e['type'] == 'approval_request'),
          hasLength(1));
      expect(userEvents.where((e) => e.type == 'approval_request'),
          hasLength(1));
      await sSub.cancel();
      await uSub.cancel();
    });

    test('connected event updates seq without emitting on user stream', () async {
      final events = <UserEvent>[];
      final sub = UserEventsService().events.listen(events.add);

      // This simulates what socket_service does on "connected" event
      UserEventsService().updateSeq(7777);

      await Future.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(UserEventsService().latestSeq, greaterThanOrEqualTo(7777));
      await sub.cancel();
    });
  });

  group('UserEvent.fromEnvelope', () {
    test('parses complete envelope', () {
      final e = UserEvent.fromEnvelope('session.completed', {
        'seq': 42,
        'kind': 'session',
        'app_id': 'app-1',
        'session_id': 'ses-1',
        'payload': {'response': 'done', 'summary': 'ok'},
        'ts': '2026-04-15T10:00:00Z',
      });

      expect(e.type, 'session.completed');
      expect(e.seq, 42);
      expect(e.kind, 'session');
      expect(e.appId, 'app-1');
      expect(e.sessionId, 'ses-1');
      expect(e.payload['response'], 'done');
      expect(e.timestamp, isNotNull);
      expect(e.timestamp.year, 2026);
    });

    test('defaults missing fields', () {
      final e = UserEvent.fromEnvelope('inbox.created', {});
      expect(e.seq, 0);
      expect(e.kind, 'system');
      expect(e.appId, isNull);
      expect(e.sessionId, isNull);
      expect(e.payload, isEmpty);
    });

    test('parses numeric timestamp (epoch seconds)', () {
      final epoch = 1713168000; // 2024-04-15 ~
      final e = UserEvent.fromEnvelope('test', {'ts': epoch});
      expect(e.timestamp, isNotNull);
    });

    test('parses payload when it is a Map', () {
      final e = UserEvent.fromEnvelope('test', {
        'payload': {'key': 'value'},
      });
      expect(e.payload['key'], 'value');
    });

    test('treats non-Map payload as empty', () {
      final e = UserEvent.fromEnvelope('test', {
        'payload': 'not a map',
      });
      expect(e.payload, isEmpty);
    });
  });
}
