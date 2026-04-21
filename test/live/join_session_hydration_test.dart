/// Live integration test — connects to a real Digitorn daemon,
/// exercises the full `join_session` hydration sequence, and
/// verifies that our [SessionEventRouter] + [OpRegistry] +
/// [SessionSnapshotSinks] stack reproduces the same state the
/// backend expects (same scenarios as the Python reference test
/// `tests/live/prod_bugs/verify_join_session_full_hydration.py`).
///
/// Run:
/// ```
/// flutter test integration_test/join_session_hydration_test.dart \
///   --dart-define=DIGITORN_BASE=http://127.0.0.1:8000
/// ```
///
/// The test:
///   1. Registers a temporary user.
///   2. POSTs a short message and waits for `message_done`.
///   3. Opens a Socket.IO connection, emits `join_session`,
///      collects every envelope for 3s.
///   4. Replays each envelope through [SessionEventRouter].
///   5. Asserts:
///      * the 5 expected snapshots land in their sinks
///        (connected / queue / active_ops / session / memory)
///      * the durable events hit the registry in seq-sorted order
///      * no ephemeral (`token`, `thinking_delta`, …) leaked into
///        the registry
///      * `latestFor(op_id)` of the turn reflects
///        `OpState.completed` after `message_done`
///
/// If DIGITORN_BASE points at an unreachable host the whole group
/// is skipped — we don't want CI red lights just because a
/// developer ran `flutter test` without a daemon.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:digitorn_client/models/event_envelope.dart';
import 'package:digitorn_client/services/op_registry.dart';
import 'package:digitorn_client/services/session_event_router.dart';
import 'package:digitorn_client/services/session_snapshot_sinks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as sio;

const String _baseUrl = String.fromEnvironment(
  'DIGITORN_BASE',
  defaultValue: 'http://127.0.0.1:8000',
);

Future<bool> _daemonReachable() async {
  try {
    final r = await http.get(Uri.parse('$_baseUrl/health'))
        .timeout(const Duration(seconds: 3));
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<(String, String)> _register() async {
  final uname = 'fhyd${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  final email = '$uname@test.local';
  const pwd = 'FlutterHyd1234!xyz';
  final res = await http.post(
    Uri.parse('$_baseUrl/auth/register'),
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode({'username': uname, 'email': email, 'password': pwd}),
  );
  if (res.statusCode != 200) {
    final login = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': pwd}),
    );
    expect(login.statusCode, 200,
        reason: 'either register or login must succeed');
    final j = jsonDecode(login.body) as Map<String, dynamic>;
    return (uname, j['access_token'] as String);
  }
  final j = jsonDecode(res.body) as Map<String, dynamic>;
  return (uname, j['access_token'] as String);
}

Future<String> _postMessage(
    String token, String appId, String sid, String msg) async {
  final res = await http.post(
    Uri.parse('$_baseUrl/api/apps/$appId/sessions/$sid/messages'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    },
    body: jsonEncode({'message': msg}),
  );
  expect(res.statusCode, 200,
      reason: 'POST /messages should accept');
  final body = jsonDecode(res.body);
  final cid = ((body['data'] as Map?)?['correlation_id']) as String?;
  expect(cid, isNotNull, reason: 'daemon must echo a correlation_id');
  return cid!;
}

Future<bool> _waitMessageDone(
    String token, String appId, String sid, String cid,
    {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  int seen = 0;
  while (DateTime.now().isBefore(deadline)) {
    final res = await http.get(
      Uri.parse(
          '$_baseUrl/api/apps/$appId/sessions/$sid/events?since_seq=$seen&limit=200'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body);
      final events = (body['data'] as Map?)?['events'] as List? ?? [];
      for (final ev in events) {
        final s = (ev['seq'] as num?)?.toInt() ?? 0;
        if (s > seen) seen = s;
        final t = ev['type'] as String?;
        final p = (ev['payload'] as Map?) ?? const {};
        if ((t == 'message_done' || t == 'message_cancelled') &&
            (p['correlation_id'] == cid || ev['correlation_id'] == cid)) {
          return true;
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
  return false;
}

/// Opens a Socket.IO connection, joins the session, collects every
/// envelope for [hold] seconds, then disconnects.
Future<List<Map<String, dynamic>>> _joinAndCollect(
  String token,
  String appId,
  String sid, {
  int since = 0,
  Duration hold = const Duration(seconds: 3),
}) async {
  final collected = <Map<String, dynamic>>[];
  final done = Completer<void>();
  final socket = sio.io(
    '$_baseUrl/events',
    sio.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .setAuth({'token': token})
        .build(),
  );

  socket.onConnect((_) async {
    socket.emitWithAck(
      'join_session',
      {'app_id': appId, 'session_id': sid, 'since': since},
      ack: (data) {},
    );
  });

  socket.on('event', (raw) {
    if (raw is Map) {
      collected.add(raw.cast<String, dynamic>());
    }
  });

  socket.onConnectError((err) {
    if (!done.isCompleted) done.completeError(StateError('connect: $err'));
  });
  socket.onError((err) {
    stderr.writeln('socket error: $err');
  });

  socket.connect();
  await Future<void>.delayed(hold);
  socket.disconnect();
  socket.dispose();
  return collected;
}

void main() {
  setUpAll(() async {
    if (!await _daemonReachable()) {
      // ignore: avoid_print
      print('Daemon at $_baseUrl unreachable — skipping live tests');
    }
  });

  group('live join_session hydration',
      skip: null, // resolved at runtime below
      () {
    late bool alive;
    setUpAll(() async {
      alive = await _daemonReachable();
    });

    test('A · fresh chat → join → all snapshots + seq-ordered replay',
        () async {
      if (!alive) {
        markTestSkipped('daemon unreachable at $_baseUrl');
        return;
      }
      final (_, token) = await _register();
      const appId = 'digitorn-chat';
      final sid = 'fhyd-A-${DateTime.now().microsecondsSinceEpoch}';

      final cid = await _postMessage(
          token, appId, sid, "Reply 'hi' in one word.");
      expect(await _waitMessageDone(token, appId, sid, cid),
          isTrue, reason: 'turn must complete under 90s');

      final envs = await _joinAndCollect(token, appId, sid);

      // Route through the production router.
      final reg = OpRegistry(sessionId: sid);
      final sinks = SessionSnapshotSinks();
      final router = SessionEventRouter(registry: reg, sinks: sinks);
      try {
        for (final raw in envs) {
          router.dispatch(raw);
        }

        // Every snapshot the daemon promises must have landed.
        expect(sinks.onConnected.value, isNotNull);
        expect(sinks.queueSnapshot.value, isNotNull);
        expect(sinks.activeOpsSnapshot.value, isNotNull);
        expect(sinks.sessionSnapshot.value, isNotNull);
        expect(sinks.memorySnapshot.value, isNotNull);

        // Durable replay landed in the registry, seq-sorted.
        final seqs = reg.inOrder().map((e) => e.seq).toList();
        expect(seqs, isNotEmpty, reason: 'at least one durable event');
        for (var i = 1; i < seqs.length; i++) {
          expect(seqs[i] > seqs[i - 1], isTrue,
              reason:
                  'registry must expose events in strictly ascending '
                  'seq order (indices ${i - 1}/$i = '
                  '${seqs[i - 1]} / ${seqs[i]})');
        }

        // No ephemerals slipped into the durable store.
        for (final e in reg.inOrder()) {
          expect(ephemeralEventTypes.contains(e.type), isFalse,
              reason:
                  'ephemeral type ${e.type} must never enter the '
                  'registry');
        }

        // The turn op is terminal (message_done flipped it).
        final turnOp = reg.latestFor(cid);
        if (turnOp != null) {
          expect(turnOp.opState.isTerminal, isTrue,
              reason: 'turn op must be terminal after message_done');
        }

        // session:snapshot matches reality.
        final ss = sinks.sessionSnapshot.value!;
        expect(ss['turn_running'], isFalse,
            reason: 'turn is done — snapshot must reflect that');
      } finally {
        router.dispose();
        sinks.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('B · mid-turn join → active_ops surfaces the running turn',
        () async {
      if (!alive) {
        markTestSkipped('daemon unreachable at $_baseUrl');
        return;
      }
      final (_, token) = await _register();
      const appId = 'digitorn-chat';
      final sid = 'fhyd-B-${DateTime.now().microsecondsSinceEpoch}';

      final cid = await _postMessage(
        token, appId, sid,
        'Write a 10-line poem about reconnection, one line at a time.',
      );

      // Join IMMEDIATELY — do not wait for message_done.
      final envs = await _joinAndCollect(
        token, appId, sid,
        hold: const Duration(seconds: 3),
      );

      final reg = OpRegistry(sessionId: sid);
      final sinks = SessionSnapshotSinks();
      final router = SessionEventRouter(registry: reg, sinks: sinks);
      try {
        for (final raw in envs) {
          router.dispatch(raw);
        }

        // active_ops:snapshot should carry the turn as running
        // (unless the LLM was fast enough to complete — tolerated).
        final ao = sinks.activeOpsSnapshot.value;
        expect(ao, isNotNull);
        final active = (ao!['active_ops'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final turnOps = active.where(
            (o) => (o['op_type'] as String?) == 'turn').toList();
        if (turnOps.isNotEmpty) {
          expect(turnOps.first['op_state'], 'running',
              reason:
                  'mid-turn join must see the turn as running');
          // And the reconciliation should have surfaced it in the
          // registry.
          final opId = turnOps.first['op_id'] as String;
          final latest = reg.latestFor(opId);
          expect(latest, isNotNull,
              reason: 'reconciliation must ingest the running op');
        }
        // Clean up — wait for completion so no turn leaks between
        // tests.
        await _waitMessageDone(token, appId, sid, cid);
      } finally {
        router.dispose();
        sinks.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        'C · incremental join (since=N) → only newer events '
        'pass through',
        () async {
      if (!alive) {
        markTestSkipped('daemon unreachable at $_baseUrl');
        return;
      }
      final (_, token) = await _register();
      const appId = 'digitorn-chat';
      final sid = 'fhyd-C-${DateTime.now().microsecondsSinceEpoch}';

      final cid1 = await _postMessage(token, appId, sid, 'Hello.');
      await _waitMessageDone(token, appId, sid, cid1);

      // Record the current max seq via HTTP.
      final r = await http.get(
        Uri.parse(
            '$_baseUrl/api/apps/$appId/sessions/$sid/events?since_seq=0&limit=500'),
        headers: {'Authorization': 'Bearer $token'},
      );
      final events = ((jsonDecode(r.body) as Map)['data'] as Map?)
              ?['events'] as List? ??
          [];
      final baselineSeq = events
          .map((e) => ((e as Map)['seq'] as num?)?.toInt() ?? 0)
          .fold<int>(0, (a, b) => a > b ? a : b);

      // Send a second turn so there are new events above baselineSeq.
      final cid2 = await _postMessage(token, appId, sid, 'Again please.');
      await _waitMessageDone(token, appId, sid, cid2);

      final envs = await _joinAndCollect(
        token, appId, sid, since: baselineSeq,
      );

      final reg = OpRegistry(sessionId: sid);
      final sinks = SessionSnapshotSinks();
      final router = SessionEventRouter(registry: reg, sinks: sinks);
      try {
        for (final raw in envs) {
          router.dispatch(raw);
        }
        for (final e in reg.inOrder()) {
          expect(e.seq > baselineSeq, isTrue,
              reason:
                  'since=$baselineSeq replay should never surface '
                  'events at or below the cursor (got seq=${e.seq})');
        }
      } finally {
        router.dispose();
        sinks.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
