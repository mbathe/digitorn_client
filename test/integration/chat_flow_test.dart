// End-to-end-ish tests of the chat/queue/workspace pipeline.
//
// We drive the pipeline by calling `SessionService().injectSocketEvent(...)`
// directly — this is the exact entry point the real Socket.IO layer
// uses. Everything downstream (QueueService, WorkspaceModule,
// PreviewStore, ChatPanel events) reacts as it would in production.
//
// These tests do NOT mount the UI widget — they verify the state
// pipeline. Any UI bug that depends on a wrong state transition is
// reproduced here first, and fixing it here is a real fix.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:digitorn_client/models/queue_entry.dart';
import 'package:digitorn_client/services/preview_store.dart';
import 'package:digitorn_client/services/queue_service.dart';
import 'package:digitorn_client/services/session_service.dart';
import 'package:digitorn_client/services/workspace_module.dart';

const sid = 'sid-int-test';
const appId = 'app-int-test';

/// Test-side event router — mirrors what the real app does:
///   • `preview:*`       → PreviewStore.applyHistoryEvent
///   • queue lifecycle   → QueueService handlers
///   • everything else   → SessionService.injectSocketEvent (no-op
///     from the service's POV without a UI consumer, but sets seq).
///
/// In production, chat_panel._onEvent is the glue: it listens on
/// SessionService.events and forwards to QueueService. Tests skip
/// chat_panel and invoke the handlers directly, just like
/// chat_panel does.
void _inject(String type, Map<String, dynamic> data,
    {int? seq, String? sessionId}) {
  final ssid = sessionId ?? sid;
  if (type.startsWith('preview:')) {
    PreviewStore().applyHistoryEvent(type, data);
    return;
  }
  final qsvc = QueueService();
  switch (type) {
    case 'message_queued':
      qsvc.onMessageQueued(ssid, data);
      return;
    case 'message_merged':
      qsvc.onMessageMerged(ssid, data);
      return;
    case 'message_replaced':
      qsvc.onMessageReplaced(ssid, data);
      return;
    case 'message_started':
      qsvc.onMessageStarted(ssid, data);
      return;
    case 'message_done':
      qsvc.onMessageDone(ssid, data);
      return;
    case 'message_cancelled':
      qsvc.onMessageCancelled(ssid, data);
      return;
    case 'queue_cleared':
      qsvc.onQueueCleared(ssid);
      return;
    case 'queue_full':
      qsvc.onQueueFull(ssid, data);
      return;
    case 'abort':
      qsvc.onAbort(ssid, data);
      return;
  }
  SessionService().injectSocketEvent({
    'type': type,
    'data': data,
    'seq': ?seq,
    'app_id': appId,
    'session_id': ssid,
  });
}

Future<void> _settle() async {
  // Let WorkspaceModule's microtask-scheduled rebuild run.
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late QueueService qsvc;
  late WorkspaceModule wm;

  setUp(() {
    qsvc = QueueService();
    qsvc.forgetSession(sid);
    wm = WorkspaceModule();
    wm.reset();
    PreviewStore().reset();
  });

  tearDown(() {
    qsvc.forgetSession(sid);
    wm.reset();
    PreviewStore().reset();
  });

  group('Queue lifecycle — fast-path (idle session)', () {
    test('user sends while idle → no chip, bubble-owning events flow',
        () async {
      // 1. User sends. POST returns accepted (fast-path). No
      //    optimistic entry should be stuck in the queue.
      //    (In real code _send drops the entry; here we emulate
      //    that by NOT calling addOptimistic — idle path doesn't.)
      _inject('user_message', {
        'content': 'hello',
        'correlation_id': 'fp-abc',
        'client_message_id': 'cmid-1',
        'pending': false,
      }, seq: 1);
      expect(qsvc.pendingFor(sid), isEmpty);

      // 2. message_started with fast_path=true → must NOT promote
      //    any unrelated queued entry.
      _inject('message_started', {
        'correlation_id': 'fp-abc',
        'fast_path': true,
      }, seq: 2);
      expect(qsvc.runningFor(sid), isNull);
      expect(qsvc.pendingFor(sid), isEmpty);

      // 3. message_done → still nothing in the queue.
      _inject('message_done', {
        'correlation_id': 'fp-abc',
        'fast_path': true,
      }, seq: 3);
      expect(qsvc.pendingFor(sid), isEmpty);
      expect(qsvc.runningFor(sid), isNull);
    });
  });

  group('Queue lifecycle — busy path (turn in progress)', () {
    test('message queued while turn running → chip visible, then promoted',
        () async {
      // 1. First message accepted fast-path (idle before user's
      //    second send). This mimics the state right before the
      //    second message lands: turn1 is running.
      _inject('user_message', {
        'content': 'turn 1',
        'correlation_id': 'fp-1',
        'client_message_id': 'cmid-1',
        'pending': false,
      }, seq: 1);
      _inject('message_started', {
        'correlation_id': 'fp-1',
        'fast_path': true,
      }, seq: 2);

      // 2. User sends second message. Busy path calls addOptimistic.
      final opt = qsvc.addOptimistic(sid, 'turn 2');
      expect(qsvc.pendingFor(sid).length, 1, reason: 'chip visible');

      // 3. POST returns queued.
      qsvc.reconcile(
          sid,
          EnqueueResult.queued(
              correlationId: 'queue-row-2',
              position: 1,
              queueDepth: 1),
          tempCid: opt.correlationId);
      final chip = qsvc.pendingFor(sid).first;
      expect(chip.correlationId, 'queue-row-2');
      expect(chip.optimistic, false);

      // 4. Daemon emits user_message {pending:true} — bubble appears
      //    dimmed in chat. QueueService stays unchanged.
      _inject('user_message', {
        'content': 'turn 2',
        'correlation_id': 'queue-row-2',
        'client_message_id': 'cmid-2',
        'pending': true,
      }, seq: 3);
      expect(qsvc.pendingFor(sid).length, 1,
          reason: 'chip stays during pending');

      // 5. Turn 1 done. (Doesn't affect queue entry for turn 2.)
      _inject('message_done', {
        'correlation_id': 'fp-1',
        'fast_path': true,
      }, seq: 4);
      expect(qsvc.pendingFor(sid).length, 1);

      // 6. Daemon picks turn 2 → message_started promotes.
      _inject('message_started', {
        'correlation_id': 'queue-row-2',
        'fast_path': false,
      }, seq: 5);
      expect(qsvc.pendingFor(sid), isEmpty,
          reason: 'chip disappears on started');
      expect(qsvc.runningFor(sid), isNotNull);
      expect(qsvc.runningFor(sid)!.message, 'turn 2');

      // 7. Turn 2 done → queue empty.
      _inject('message_done', {'correlation_id': 'queue-row-2'}, seq: 6);
      expect(qsvc.pendingFor(sid), isEmpty);
      expect(qsvc.runningFor(sid), isNull);
    });

    test('3 fast sends during a long turn → 3 chips, drained FIFO',
        () async {
      // Turn 0 running.
      _inject('user_message', {
        'content': 'root',
        'correlation_id': 'fp-0',
        'pending': false,
      }, seq: 10);
      _inject('message_started', {
        'correlation_id': 'fp-0',
        'fast_path': true,
      }, seq: 11);

      // User sends 3 quick messages.
      final a = qsvc.addOptimistic(sid, 'a');
      final b = qsvc.addOptimistic(sid, 'b');
      final c = qsvc.addOptimistic(sid, 'c');
      expect(qsvc.pendingFor(sid).length, 3);

      // Server confirms all 3 in order.
      qsvc.reconcile(
          sid,
          EnqueueResult.queued(
              correlationId: 'q-a', position: 1, queueDepth: 3),
          tempCid: a.correlationId);
      qsvc.reconcile(
          sid,
          EnqueueResult.queued(
              correlationId: 'q-b', position: 2, queueDepth: 3),
          tempCid: b.correlationId);
      qsvc.reconcile(
          sid,
          EnqueueResult.queued(
              correlationId: 'q-c', position: 3, queueDepth: 3),
          tempCid: c.correlationId);

      expect(qsvc.pendingFor(sid).map((e) => e.message).toList(),
          ['a', 'b', 'c']);

      // Turn 0 done, daemon drains in FIFO order.
      _inject('message_done', {
        'correlation_id': 'fp-0',
        'fast_path': true,
      }, seq: 20);
      _inject('message_started', {'correlation_id': 'q-a'}, seq: 21);
      expect(qsvc.runningFor(sid)!.message, 'a');
      expect(qsvc.pendingFor(sid).map((e) => e.message).toList(), ['b', 'c']);

      _inject('message_done', {'correlation_id': 'q-a'}, seq: 30);
      _inject('message_started', {'correlation_id': 'q-b'}, seq: 31);
      expect(qsvc.runningFor(sid)!.message, 'b');
      expect(qsvc.pendingFor(sid).map((e) => e.message).toList(), ['c']);

      _inject('message_done', {'correlation_id': 'q-b'}, seq: 40);
      _inject('message_started', {'correlation_id': 'q-c'}, seq: 41);
      expect(qsvc.runningFor(sid)!.message, 'c');
      expect(qsvc.pendingFor(sid), isEmpty);

      _inject('message_done', {'correlation_id': 'q-c'}, seq: 50);
      expect(qsvc.runningFor(sid), isNull);
    });
  });

  group('Soft abort preserves queue', () {
    test('abort with queue_preserved → running dropped, pending kept',
        () async {
      final a = qsvc.addOptimistic(sid, 'a');
      final b = qsvc.addOptimistic(sid, 'b');
      qsvc.reconcile(
          sid,
          EnqueueResult.queued(
              correlationId: 'q-a', position: 1, queueDepth: 2),
          tempCid: a.correlationId);
      qsvc.reconcile(
          sid,
          EnqueueResult.queued(
              correlationId: 'q-b', position: 2, queueDepth: 2),
          tempCid: b.correlationId);
      _inject('message_started', {'correlation_id': 'q-a'}, seq: 1);
      expect(qsvc.runningFor(sid)!.message, 'a');

      _inject('abort', {
        'queue_preserved': true,
        'queue_purged': 0,
      }, seq: 2);

      expect(qsvc.runningFor(sid), isNull);
      expect(qsvc.pendingFor(sid).length, 1);
      expect(qsvc.pendingFor(sid).first.message, 'b');
    });

    test('abort with queue_purged > 0 → clears everything', () async {
      qsvc.addOptimistic(sid, 'a');
      qsvc.addOptimistic(sid, 'b');
      _inject('abort', {'queue_purged': 2}, seq: 1);
      expect(qsvc.pendingFor(sid), isEmpty);
      expect(qsvc.runningFor(sid), isNull);
    });
  });

  group('Workspace — files appear via preview events', () {
    test('resource_set on files channel populates WorkspaceModule',
        () async {
      _inject('preview:resource_set', {
        'channel': 'files',
        'id': 'src/main.py',
        'payload': {'content': 'print("ok")'},
      });
      await _settle();
      expect(wm.hasFiles, true);
      expect(wm.files.length, 1);
      expect(wm.files['src/main.py']!.content, 'print("ok")');
    });

    test('multiple agent writes land in the module', () async {
      for (var i = 0; i < 5; i++) {
        _inject('preview:resource_set', {
          'channel': 'files',
          'id': 'file$i.py',
          'payload': {'content': 'content $i'},
        });
      }
      await _settle();
      expect(wm.files.length, 5);
    });
  });

  group('Seq ordering via user_message events', () {
    test('event envelope carries seq at the root', () {
      var seenSeq = -1;
      final sub = SessionService().events.listen((e) {
        if (e['type'] == 'user_message') seenSeq = e['seq'] as int? ?? -1;
      });
      _inject('user_message', {
        'content': 'seq-test',
        'correlation_id': 'x',
      }, seq: 42);
      // Microtask drain.
      Future<void>.microtask(() {
        expect(seenSeq, 42);
        sub.cancel();
      });
    });
  });
}
