/// Routing invariants: snapshots → sinks, ephemerals → volatile
/// stream, durables → strict parse into the registry.
library;

import 'package:digitorn_client/models/event_envelope.dart';
import 'package:digitorn_client/services/op_registry.dart';
import 'package:digitorn_client/services/session_event_router.dart';
import 'package:digitorn_client/services/session_snapshot_sinks.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _durableEnvelope({
  required String type,
  required int seq,
  required String opId,
  String opState = 'running',
  String opType = 'turn',
  String sessionId = 'S',
}) {
  return {
    'type': type,
    'kind': 'session',
    'seq': seq,
    'ts': '2026-04-20T12:00:${seq.toString().padLeft(2, "0")}Z',
    'session_id': sessionId,
    'payload': {
      'event_id': 'ev-$opId-$seq',
      'op_id': opId,
      'op_type': opType,
      'op_state': opState,
      'correlation_id': 'cid-$opId',
      'session_id': sessionId,
    },
  };
}

void main() {
  late OpRegistry reg;
  late SessionSnapshotSinks sinks;
  late SessionEventRouter router;

  setUp(() {
    reg = OpRegistry(sessionId: 'S');
    sinks = SessionSnapshotSinks();
    router = SessionEventRouter(registry: reg, sinks: sinks);
  });

  tearDown(() {
    router.dispose();
    sinks.dispose();
  });

  test('durable envelope → OpRegistry (parsed strictly)', () {
    router.dispatch(_durableEnvelope(
      type: 'user_message', seq: 1, opId: 'fp-abc',
    ));
    expect(reg.length, 1);
    expect(reg.latestFor('fp-abc')!.opState, OpState.running);
  });

  test('ephemeral envelope → volatile stream, registry untouched',
      () async {
    final received = <Map<String, dynamic>>[];
    final sub = router.ephemeralEvents.listen(received.add);
    router.dispatch({
      'type': 'token',
      'payload': {'delta': 'he'},
    });
    router.dispatch({
      'type': 'thinking_delta',
      'payload': {'text': 'let me think'},
    });
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(received, hasLength(2));
    expect(reg.length, 0,
        reason: 'ephemerals must never enter the registry.');
  });

  test('snapshot envelope → sink, registry untouched', () {
    router.dispatch({
      'type': 'session:snapshot',
      'seq': 7,
      'ts': '2026-04-20T12:00:00Z',
      'payload': {
        'app_id': 'A', 'session_id': 'S',
        'turn_running': true, 'message_count': 4,
      },
    });
    expect(sinks.sessionSnapshot.value, isNotNull);
    expect(sinks.sessionSnapshot.value!['turn_running'], isTrue);
    expect(reg.length, 0);
  });

  test(
      'active_ops:snapshot → sink AND triggers registry reconciliation',
      () {
    router.dispatch({
      'type': 'active_ops:snapshot',
      'seq': 12,
      'ts': '2026-04-20T12:00:00Z',
      'payload': {
        'app_id': 'A', 'session_id': 'S', 'count': 1,
        'active_ops': [
          {
            'op_id': 'op-ghost',
            'op_type': 'tool',
            'op_state': 'running',
            'last_seq': 99,
            'last_type': 'tool_start',
          },
        ],
      },
    });
    expect(sinks.activeOpsSnapshot.value, isNotNull);
    expect(reg.latestFor('op-ghost')!.opState, OpState.running,
        reason:
            'the registry must adopt the snapshot op as synthetic.');
  });

  test('malformed durable envelope → logged and dropped, no crash',
      () {
    // payload missing op_id — strict parse must reject cleanly.
    final bad = _durableEnvelope(
      type: 'tool_start', seq: 3, opId: 'op-x',
    );
    (bad['payload'] as Map).remove('op_id');
    // Should not throw out of dispatch.
    router.dispatch(bad);
    expect(reg.length, 0);
  });

  test('envelope without type is dropped', () {
    router.dispatch({'payload': {'foo': 'bar'}});
    expect(reg.length, 0);
  });

  test(
      'full join_session sequence (replay + snapshots in order) '
      'lands everything where it belongs', () {
    // Mirrors scout output on Scenario A:
    //   connected, replay durable events, then the 4 snapshots.
    router.dispatch({
      'type': 'connected', 'seq': 0, 'ts': '2026-04-20T12:00:00Z',
      'payload': {'latest_seq': 100},
    });
    router.dispatch(_durableEnvelope(
        type: 'user_message', seq: 1, opId: 'fp-1',
        opState: 'pending'));
    router.dispatch(_durableEnvelope(
        type: 'message_started', seq: 2, opId: 'fp-1',
        opState: 'running'));
    router.dispatch(_durableEnvelope(
        type: 'message_done', seq: 3, opId: 'fp-1',
        opState: 'completed'));
    router.dispatch({
      'type': 'queue:snapshot', 'seq': 4,
      'ts': '2026-04-20T12:00:00Z',
      'payload': {'is_active': false, 'depth': 0},
    });
    router.dispatch({
      'type': 'active_ops:snapshot', 'seq': 5,
      'ts': '2026-04-20T12:00:00Z',
      'payload': {'count': 0, 'active_ops': []},
    });
    router.dispatch({
      'type': 'session:snapshot', 'seq': 6,
      'ts': '2026-04-20T12:00:00Z',
      'payload': {'message_count': 2, 'turn_running': false},
    });
    router.dispatch({
      'type': 'memory:snapshot', 'seq': 7,
      'ts': '2026-04-20T12:00:00Z',
      'payload': {'goal': null, 'todos': [], 'facts': []},
    });

    expect(reg.length, 3,
        reason: '3 durable replay events hit the registry.');
    expect(sinks.onConnected.value, isNotNull);
    expect(sinks.queueSnapshot.value!['depth'], 0);
    expect(sinks.activeOpsSnapshot.value!['count'], 0);
    expect(sinks.sessionSnapshot.value!['turn_running'], isFalse);
    expect(sinks.memorySnapshot.value!['todos'], isEmpty);
    expect(reg.latestFor('fp-1')!.opState, OpState.completed);
  });
}
