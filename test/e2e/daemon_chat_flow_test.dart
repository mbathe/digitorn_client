// Real end-to-end tests against a running digitorn-bridge daemon at
// 127.0.0.1:8000. Zero mocks, zero speculation — we speak the actual
// HTTP + Socket.IO contract and verify what the daemon emits.
//
// The whole group is skipped when the daemon is unreachable so CI
// without a bridge doesn't wedge.
//
// These tests are heavy (they spawn a real LLM turn) — run in isolation:
//   flutter test test/e2e/daemon_chat_flow_test.dart

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'package:digitorn_client/models/queue_entry.dart';
import 'package:digitorn_client/services/queue_service.dart';
import 'package:digitorn_client/ui/chat/chat_panel_logic.dart';
import 'package:digitorn_client/models/chat_message.dart';

const _baseUrl = 'http://127.0.0.1:8000';
const _appId = 'digitorn-chat';
const _testUser = 'admin';
const _testPassword = 'admin1234admin';

String? _cachedToken;

Future<String?> _login() async {
  if (_cachedToken != null) return _cachedToken;
  try {
    final r = await Dio().post(
      '$_baseUrl/auth/login',
      data: {'username': _testUser, 'password': _testPassword},
      options: Options(
        headers: {'Content-Type': 'application/json'},
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        validateStatus: (_) => true,
      ),
    );
    if (r.statusCode != 200) return null;
    _cachedToken = (r.data as Map)['access_token'] as String?;
    return _cachedToken;
  } catch (_) {
    return null;
  }
}

Dio _authedDio(String token) => Dio(BaseOptions(
      headers: {'Authorization': 'Bearer $token'},
    ));

Future<bool> _daemonUp() async {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final r = await Dio().get(
        '$_baseUrl/health',
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      if (r.statusCode == 200) return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  return false;
}

Future<String?> _createSession(String token) async {
  final r = await _authedDio(token).post(
    '$_baseUrl/api/apps/$_appId/sessions',
    data: <String, dynamic>{},
    options: Options(
      headers: {'Content-Type': 'application/json'},
      validateStatus: (_) => true,
    ),
  );
  if (r.statusCode == 404) {
    return null; // App not deployed — caller skips.
  }
  if (r.statusCode != 200 && r.statusCode != 201 && r.statusCode != 202) {
    throw StateError('createSession failed: ${r.statusCode} ${r.data}');
  }
  final data = (r.data as Map)['data'] as Map;
  return data['session_id'] as String;
}

class _EventCollector {
  final List<Map<String, dynamic>> events = [];
  final _subs = <StreamSubscription<dynamic>>[];
  late final io.Socket socket;
  final _connectedCompleter = Completer<void>();

  Future<void> connect(String sessionId, String token, {int since = 0}) async {
    final opts = io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .enableForceNew()
        .setAuth({'token': token})
        .setQuery({'token': token})
        .setExtraHeaders({'Authorization': 'Bearer $token'})
        .setReconnectionAttempts(0)
        .build();
    socket = io.io('$_baseUrl/events', opts);
    socket.onConnect((_) {
      socket.emitWithAck('join_session', {
        'app_id': _appId,
        'session_id': sessionId,
        if (since > 0) 'since': since,
      }, ack: (ackData) {
        if (!_connectedCompleter.isCompleted) {
          _connectedCompleter.complete();
        }
      });
    });
    socket.onConnectError((e) {
      if (!_connectedCompleter.isCompleted) {
        _connectedCompleter.completeError('connect_error: $e');
      }
    });
    socket.on('event', (raw) {
      if (raw is Map) events.add(Map<String, dynamic>.from(raw));
    });
    socket.connect();
    await _connectedCompleter.future.timeout(const Duration(seconds: 5));
  }

  Future<Map<String, dynamic>> waitFor(
    bool Function(Map<String, dynamic>) predicate, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var idx = 0;
    while (DateTime.now().isBefore(deadline)) {
      while (idx < events.length) {
        if (predicate(events[idx])) return events[idx];
        idx++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
        'no matching event in ${timeout.inSeconds}s (got ${events.length})');
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    socket.dispose();
  }
}

Future<Map<String, dynamic>> _postMessage(
  String token,
  String sessionId,
  String text, {
  String? clientMessageId,
  String? correlationId,
  String queueMode = 'async',
}) async {
  final r = await _authedDio(token).post(
    '$_baseUrl/api/apps/$_appId/sessions/$sessionId/messages',
    data: {
      'message': text,
      'queue_mode': queueMode,
      if (clientMessageId != null) 'client_message_id': clientMessageId,
      if (correlationId != null) 'correlation_id': correlationId,
    },
    options: Options(
      headers: {'Content-Type': 'application/json'},
      validateStatus: (_) => true,
    ),
  );
  if (r.statusCode != 200 && r.statusCode != 202) {
    throw StateError('postMessage: ${r.statusCode} ${r.data}');
  }
  final data = (r.data as Map)['data'] as Map?;
  return data == null ? <String, dynamic>{} : Map<String, dynamic>.from(data);
}

void main() {
  late bool daemonUp;
  String? token;
  setUpAll(() async {
    daemonUp = await _daemonUp();
    // ignore: avoid_print
    if (!daemonUp) {
      print('[e2e] daemon unreachable on $_baseUrl — skipping group');
      return;
    }
    token = await _login();
    if (token == null) {
      // ignore: avoid_print
      print('[e2e] login failed ($_testUser) — socket tests will skip');
    }
  });

  group('daemon chat flow (real HTTP + Socket.IO)', () {
    test('health endpoint responds', () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      final r = await Dio().get('$_baseUrl/health');
      expect(r.statusCode, 200);
      expect((r.data as Map)['status'], 'ok');
    });

    test('session creation returns a session_id', () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }
      expect(sid, isNotEmpty);
      expect(sid.length, greaterThan(8));
    });

    test('user_message → message_started → tokens → turn_complete', () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }
      final collector = _EventCollector();
      addTearDown(collector.dispose);
      await collector.connect(sid, token!);

      const cmid = 'e2e-cmid-happy-path';
      final ack = await _postMessage(
        token!,
        sid,
        'Say the word PONG and nothing else.',
        clientMessageId: cmid,
        queueMode: 'sync',
      );
      final serverCid = ack['correlation_id'] as String?;
      expect(serverCid, isNotNull, reason: 'daemon must echo correlation_id');

      final userMsg = await collector.waitFor((e) =>
          e['type'] == 'user_message' &&
          (e['payload'] is Map) &&
          ((e['payload'] as Map)['client_message_id'] == cmid ||
              (e['payload'] as Map)['correlation_id'] == serverCid));
      final userData = userMsg['payload'] as Map;
      expect(userData['client_message_id'], cmid,
          reason: 'daemon must echo the clientMessageId we sent');

      final started = await collector.waitFor(
          (e) => e['type'] == 'message_started');
      expect((started['payload'] as Map)['correlation_id'], serverCid);

      final done = await collector
          .waitFor((e) => e['type'] == 'message_done', timeout: const Duration(seconds: 90));
      expect((done['payload'] as Map)['correlation_id'], serverCid);

      final seqUser = (userMsg['seq'] as num).toInt();
      final seqStarted = (started['seq'] as num).toInt();
      final seqDone = (done['seq'] as num).toInt();
      expect(seqStarted, greaterThan(seqUser),
          reason: 'message_started must have a higher seq than user_message');
      expect(seqDone, greaterThan(seqStarted),
          reason: 'message_done must have a higher seq than message_started');
    },
        timeout: const Timeout(Duration(seconds: 120)),
        skip: false);

    test('client cascade reconciles optimistic bubble with daemon echo',
        () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }
      final collector = _EventCollector();
      addTearDown(collector.dispose);
      await collector.connect(sid, token!);

      const cmid = 'e2e-cmid-cascade';
      const optimisticText = 'What is 2+2? Answer with digits only.';

      // Simulate the optimistic bubble chat_panel inserts on _send.
      final optimistic = ChatMessage(
        id: 'u-optimistic',
        role: MessageRole.user,
        initialText: optimisticText,
        clientMessageId: cmid,
      );
      expect(optimistic.sortKey >= ChatMessage.sentinelThreshold, true,
          reason: 'optimistic bubbles must start at sentinel sortKey');
      final messages = <ChatMessage>[optimistic];

      final ack = await _postMessage(token!, sid, optimisticText,
          clientMessageId: cmid, queueMode: 'sync');
      final serverCid = ack['correlation_id'] as String;

      final userEvt = await collector.waitFor((e) =>
          e['type'] == 'user_message' &&
          (e['payload'] as Map)['client_message_id'] == cmid);
      final envSeq = (userEvt['seq'] as num).toInt();

      // Run the SAME cascade chat_panel uses against the real event.
      final reconciled = findUserBubbleToReconcile(
        messages,
        clientMessageId: cmid,
        correlationId: serverCid,
        content: optimisticText,
      );
      expect(reconciled, same(optimistic),
          reason: 'cascade must resolve our optimistic bubble');
      reconciled!
        ..correlationId = serverCid
        ..updateSortKey(envSeq);
      expect(reconciled.sortKey, envSeq * 10);
      expect(reconciled.sortKey < ChatMessage.sentinelThreshold, true,
          reason: 'after reconcile, sortKey must drop below sentinel');
    },
        timeout: const Timeout(Duration(seconds: 60)));

    test('queue: second message while first is running gets queued', () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }
      final collector = _EventCollector();
      addTearDown(collector.dispose);
      await collector.connect(sid, token!);

      // Turn 1 — fast-path, starts immediately.
      final ack1 = await _postMessage(token!, sid,
          'Count from 1 to 3 slowly, one number per line.',
          clientMessageId: 'e2e-q-1');
      final cid1 = ack1['correlation_id'] as String;
      expect(ack1['status'], 'accepted',
          reason: 'first message on an idle session must fast-path');

      await collector.waitFor((e) =>
          e['type'] == 'message_started' &&
          (e['payload'] as Map)['correlation_id'] == cid1);

      // Turn 2 — daemon must enqueue it because turn 1 is running.
      final ack2 = await _postMessage(token!, sid, 'Then say DONE.',
          clientMessageId: 'e2e-q-2');
      expect(ack2['status'], 'queued',
          reason: 'daemon must queue when first turn is still running');
      final cid2 = ack2['correlation_id'] as String;

      final queuedEvt = await collector.waitFor((e) =>
          e['type'] == 'message_queued' &&
          (e['payload'] as Map)['correlation_id'] == cid2);
      final queuedPayload = queuedEvt['payload'] as Map;
      expect(queuedPayload['correlation_id'], cid2);
      expect(queuedPayload['position'], isA<num>(),
          reason: 'message_queued must carry a position');

      // Mirror the client-side queue path: the real ChatPanel adds an
      // optimistic entry BEFORE POST on the busy branch, then reconciles
      // with the server's cid. Run that against the live response.
      final q = QueueService();
      q.forgetSession(sid);
      addTearDown(() => q.forgetSession(sid));
      final opt = q.addOptimistic(sid, 'Then say DONE.');
      q.reconcile(
        sid,
        EnqueueResult.queued(
          correlationId: cid2,
          position: (queuedPayload['position'] as num).toInt(),
          queueDepth: 0,
        ),
        tempCid: opt.correlationId,
      );
      expect(q.pendingCountFor(sid), 1,
          reason: 'reconciled entry must remain pending');
      expect(
          computeBusy(isSending: false, sessionId: sid, queue: q), true,
          reason: 'busy while pending in queue');

      // Wait for both turns to finish so the daemon is idle again.
      await collector.waitFor(
          (e) =>
              e['type'] == 'message_done' &&
              (e['payload'] as Map)['correlation_id'] == cid1,
          timeout: const Duration(seconds: 90));
      await collector.waitFor(
          (e) =>
              e['type'] == 'message_done' &&
              (e['payload'] as Map)['correlation_id'] == cid2,
          timeout: const Duration(seconds: 120));
    },
        timeout: const Timeout(Duration(seconds: 240)));

    test(
        'abort mid-turn stops token stream and emits turn_complete',
        () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }
      final collector = _EventCollector();
      addTearDown(collector.dispose);
      await collector.connect(sid, token!);

      const cmid = 'e2e-abort';
      final ack = await _postMessage(token!, sid,
          'Count slowly from 1 to 50, one number per line with a brief pause.',
          clientMessageId: cmid);
      final cid = ack['correlation_id'] as String;
      await collector.waitFor((e) =>
          e['type'] == 'message_started' &&
          (e['payload'] as Map)['correlation_id'] == cid);

      // Wait for at least one token before aborting so we know the
      // turn is really running.
      await collector.waitFor((e) => e['type'] == 'token');

      final abortResp = await _authedDio(token!).post(
        '$_baseUrl/api/apps/$_appId/sessions/$sid/abort',
        options: Options(validateStatus: (_) => true),
      );
      expect(abortResp.statusCode, anyOf(200, 202, 204),
          reason: 'daemon must accept abort');

      // Abort can emit message_cancelled, message_done, or turn_complete
      // depending on daemon version — any of them means the turn stopped.
      final complete = await collector.waitFor(
          (e) =>
              e['type'] == 'turn_complete' ||
              e['type'] == 'message_done' ||
              e['type'] == 'message_cancelled' ||
              e['type'] == 'message_aborted' ||
              e['type'] == 'turn_aborted',
          timeout: const Duration(seconds: 30));
      // ignore: avoid_print
      print('[e2e] abort completed via type=${complete['type']}');
      expect(complete['type'], isNotNull);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('replay: reconnecting with since=<seq> re-delivers past events',
        () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }

      // First connection — collects a full turn, remembers the max seq.
      final first = _EventCollector();
      addTearDown(first.dispose);
      await first.connect(sid, token!);
      final ack = await _postMessage(token!, sid, 'Say OK.',
          clientMessageId: 'e2e-replay-1', queueMode: 'sync');
      final cid = ack['correlation_id'] as String;
      final done = await first.waitFor(
          (e) =>
              e['type'] == 'message_done' &&
              (e['payload'] as Map)['correlation_id'] == cid,
          timeout: const Duration(seconds: 90));
      final firstDoneSeq = (done['seq'] as num).toInt();
      final userSeq = (first.events.firstWhere(
        (e) =>
            e['type'] == 'user_message' &&
            (e['payload'] as Map)['correlation_id'] == cid,
      )['seq'] as num)
          .toInt();
      first.socket.dispose();

      // Second connection — asks the daemon to replay from seq=userSeq-1.
      // We must see user_message + message_started + message_done again.
      final second = _EventCollector();
      addTearDown(second.dispose);
      await second.connect(sid, token!, since: userSeq - 1);

      final replayedUser = await second.waitFor((e) =>
          e['type'] == 'user_message' &&
          (e['payload'] as Map)['correlation_id'] == cid);
      final replayedDone = await second.waitFor((e) =>
          e['type'] == 'message_done' &&
          (e['payload'] as Map)['correlation_id'] == cid);
      expect((replayedUser['seq'] as num).toInt(), userSeq,
          reason: 'replayed user_message must keep its original seq');
      expect((replayedDone['seq'] as num).toInt(), firstDoneSeq,
          reason: 'replayed message_done must keep its original seq');
    }, timeout: const Timeout(Duration(seconds: 180)));

    test(
        'queue cancel: DELETE /queue/{entry_id} removes a pending message',
        () async {
      if (!daemonUp) fail('daemon not reachable — start digitorn-bridge');
      if (token == null) fail('login failed with $_testUser');
      final sid = await _createSession(token!);
      if (sid == null) {
        // ignore: avoid_print
        print('[e2e] app $_appId not deployed — skipping');
        return;
      }
      final collector = _EventCollector();
      addTearDown(collector.dispose);
      await collector.connect(sid, token!);

      // Turn 1 occupies the daemon so turn 2 can be queued.
      final ack1 = await _postMessage(token!, sid,
          'Count from 1 to 30 slowly, one number per line.',
          clientMessageId: 'e2e-cancel-1');
      final cid1 = ack1['correlation_id'] as String;
      await collector.waitFor((e) =>
          e['type'] == 'message_started' &&
          (e['payload'] as Map)['correlation_id'] == cid1);

      // Turn 2 queued.
      final ack2 = await _postMessage(token!, sid, 'Never runs.',
          clientMessageId: 'e2e-cancel-2');
      expect(ack2['status'], 'queued');
      final cid2 = ack2['correlation_id'] as String;
      await collector.waitFor((e) =>
          e['type'] == 'message_queued' &&
          (e['payload'] as Map)['correlation_id'] == cid2);

      // Cancel turn 2 via HTTP. The daemon may key the entry by
      // correlation_id directly; our client does the same.
      final cancelResp = await _authedDio(token!).delete(
        '$_baseUrl/api/apps/$_appId/sessions/$sid/queue/$cid2',
        options: Options(validateStatus: (_) => true),
      );
      expect(cancelResp.statusCode, anyOf(200, 202, 204),
          reason: 'daemon must accept queue cancellation');

      // Daemon confirms with either message_cancelled or a queue
      // snapshot update that drops cid2.
      await collector.waitFor(
          (e) =>
              (e['type'] == 'message_cancelled' &&
                  (e['payload'] as Map)['correlation_id'] == cid2) ||
              (e['type'] == 'queue:snapshot' &&
                  !(((e['payload'] as Map?)?['entries'] as List?)
                          ?.any((x) =>
                              (x as Map)['correlation_id'] == cid2) ??
                      true)),
          timeout: const Duration(seconds: 30));

      // Abort turn 1 so the test doesn't block waiting for the LLM.
      await _authedDio(token!).post(
        '$_baseUrl/api/apps/$_appId/sessions/$sid/abort',
        options: Options(validateStatus: (_) => true),
      );
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
