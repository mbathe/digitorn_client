import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/models/queue_entry.dart';
import 'package:digitorn_client/services/queue_service.dart';

// These tests exercise QueueService in isolation — no HTTP, no socket.
// They verify the state transitions that the live UI relies on:
//   addOptimistic → reconcile → message_queued → message_started → message_done
// plus edge cases: cid drift, fast_path bypass, replace_last, cancel.

const sid = 'sid-test';

void main() {
  late QueueService q;

  setUp(() {
    q = QueueService();
    q.forgetSession(sid);
  });

  tearDown(() {
    q.forgetSession(sid);
  });

  group('addOptimistic', () {
    test('adds a queued entry visible in pendingFor', () {
      final e = q.addOptimistic(sid, 'hello');
      expect(q.pendingFor(sid).length, 1);
      expect(q.pendingFor(sid).first.message, 'hello');
      expect(q.pendingFor(sid).first.status, QueueEntryStatus.queued);
      expect(q.pendingFor(sid).first.optimistic, true);
      expect(e.correlationId, isNotEmpty);
    });

    test('assigns incrementing positions', () {
      q.addOptimistic(sid, 'one');
      q.addOptimistic(sid, 'two');
      q.addOptimistic(sid, 'three');
      final entries = q.pendingFor(sid);
      expect(entries.map((e) => e.message).toList(),
          ['one', 'two', 'three']);
      expect(entries.map((e) => e.position).toList(), [1, 2, 3]);
    });
  });

  group('reconcile', () {
    test('wasAccepted drops the optimistic entry', () {
      final e = q.addOptimistic(sid, 'hello');
      q.reconcile(
        sid,
        EnqueueResult.accepted(correlationId: 'fp-xxx'),
        tempCid: e.correlationId,
      );
      expect(q.pendingFor(sid), isEmpty);
    });

    test('wasQueued updates entry with server cid', () {
      final e = q.addOptimistic(sid, 'hello');
      q.reconcile(
        sid,
        EnqueueResult.queued(
            correlationId: 'queue-row-1', position: 3, queueDepth: 3),
        tempCid: e.correlationId,
      );
      final entries = q.pendingFor(sid);
      expect(entries.length, 1);
      expect(entries.first.correlationId, 'queue-row-1');
      expect(entries.first.position, 3);
      expect(entries.first.optimistic, false);
    });

    test('wasAccepted then late message_queued is ignored', () {
      // Simulates daemon race: fast-path accept returns first, then
      // an internal `message_queued` echoes for the same id. The
      // panel should stay empty.
      final e = q.addOptimistic(sid, 'hello');
      q.reconcile(
        sid,
        EnqueueResult.accepted(correlationId: 'fp-xxx'),
        tempCid: e.correlationId,
      );
      q.onMessageQueued(sid, {
        'correlation_id': 'fp-xxx',
        'position': 1,
        'message_preview': 'hello',
      });
      expect(q.pendingFor(sid), isEmpty);
    });
  });

  group('message_queued', () {
    test('updates optimistic entry when server cid matches temp', () {
      q.addOptimistic(sid, 'hello');
      // Say the daemon happened to echo our cid back.
      final myCid = q.pendingFor(sid).first.correlationId;
      q.onMessageQueued(sid, {
        'correlation_id': myCid,
        'position': 2,
        'message_preview': 'hello',
      });
      final entries = q.pendingFor(sid);
      expect(entries.length, 1);
      expect(entries.first.position, 2);
      expect(entries.first.optimistic, false);
    });

    test('upgrades by content when server mints a different cid', () {
      // The optimistic has client-cid "msg-abc"; the server's event
      // carries "queue-row-xyz". Without content fallback we end up
      // with TWO entries.
      q.addOptimistic(sid, 'hello');
      q.onMessageQueued(sid, {
        'correlation_id': 'queue-row-xyz',
        'position': 1,
        'message_preview': 'hello',
      });
      final entries = q.pendingFor(sid);
      expect(entries.length, 1, reason: 'duplicate entries after cid drift');
      expect(entries.first.correlationId, 'queue-row-xyz');
      expect(entries.first.optimistic, false);
    });

    test('creates entry when nothing optimistic exists (cross-tab)', () {
      q.onMessageQueued(sid, {
        'correlation_id': 'queue-row-xyz',
        'position': 1,
        'message_preview': 'from other tab',
      });
      final entries = q.pendingFor(sid);
      expect(entries.length, 1);
      expect(entries.first.message, 'from other tab');
    });
  });

  group('message_started', () {
    test('promotes queued entry to running by cid', () {
      q.addOptimistic(sid, 'one');
      final cid = q.pendingFor(sid).first.correlationId;
      q.onMessageStarted(sid, {'correlation_id': cid});
      expect(q.pendingFor(sid), isEmpty);
      final running = q.runningFor(sid);
      expect(running, isNotNull);
      expect(running!.status, QueueEntryStatus.running);
    });

    test('fallback to head when cid does not match (queue-drain)', () {
      q.addOptimistic(sid, 'one');
      q.addOptimistic(sid, 'two');
      q.onMessageStarted(sid, {'correlation_id': 'mystery-cid'});
      // First queued entry should be running now.
      expect(q.runningFor(sid), isNotNull);
      expect(q.runningFor(sid)!.message, 'one');
      // Only "two" remains pending.
      expect(q.pendingFor(sid).length, 1);
      expect(q.pendingFor(sid).first.message, 'two');
    });

    test('fast_path event does NOT touch the queue', () {
      // Regression: a fast-path message_started arrives for a message
      // that never was in the queue; the panel has an unrelated
      // queued message from a concurrent send. Without the fast_path
      // guard we'd promote the wrong one.
      q.addOptimistic(sid, 'queued message');
      q.onMessageStarted(sid, {
        'correlation_id': 'fp-other',
        'fast_path': true,
      });
      expect(q.runningFor(sid), isNull);
      expect(q.pendingFor(sid).length, 1);
      expect(q.pendingFor(sid).first.message, 'queued message');
    });
  });

  group('message_done', () {
    test('removes running entry by cid', () {
      q.addOptimistic(sid, 'one');
      final cid = q.pendingFor(sid).first.correlationId;
      q.onMessageStarted(sid, {'correlation_id': cid});
      q.onMessageDone(sid, {'correlation_id': cid});
      expect(q.runningFor(sid), isNull);
      expect(q.pendingFor(sid), isEmpty);
    });
  });

  group('abort', () {
    test('soft abort (queue_preserved) drops only the running entry', () {
      q.addOptimistic(sid, 'one');
      q.addOptimistic(sid, 'two');
      final cid = q.pendingFor(sid).first.correlationId;
      q.onMessageStarted(sid, {'correlation_id': cid});
      q.onAbort(sid, {'queue_preserved': true, 'queue_purged': 0});
      expect(q.runningFor(sid), isNull);
      // 'two' still pending.
      expect(q.pendingFor(sid).length, 1);
      expect(q.pendingFor(sid).first.message, 'two');
    });

    test('hard abort (queue_purged) clears everything', () {
      q.addOptimistic(sid, 'one');
      q.addOptimistic(sid, 'two');
      q.onAbort(sid, {'queue_purged': 2});
      expect(q.pendingFor(sid), isEmpty);
      expect(q.runningFor(sid), isNull);
    });
  });

  group('message_replaced', () {
    test('rotates correlation id and updates preview', () {
      q.addOptimistic(sid, 'original');
      final oldCid = q.pendingFor(sid).first.correlationId;
      q.onMessageReplaced(sid, {
        'correlation_id': 'rotated-cid',
        'position': 1,
        'message_preview': 'corrected',
      });
      final entries = q.pendingFor(sid);
      expect(entries.length, 1);
      expect(entries.first.correlationId, 'rotated-cid');
      expect(entries.first.correlationId, isNot(oldCid));
      expect(entries.first.message, 'corrected');
    });
  });

  group('message_merged', () {
    test('updates content in place without adding a row', () {
      q.addOptimistic(sid, 'first');
      q.onMessageQueued(sid, {
        'correlation_id': q.pendingFor(sid).first.correlationId,
        'position': 1,
        'message_preview': 'first',
      });
      final cid = q.pendingFor(sid).first.correlationId;
      q.onMessageMerged(sid, {
        'correlation_id': cid,
        'message_preview': 'first\n\n---\n\nsecond',
      });
      final entries = q.pendingFor(sid);
      expect(entries.length, 1);
      expect(entries.first.message, 'first\n\n---\n\nsecond');
    });
  });

  group('activeFor', () {
    test('returns running first then queued by position', () {
      q.addOptimistic(sid, 'a');
      q.addOptimistic(sid, 'b');
      q.addOptimistic(sid, 'c');
      // Promote 'a' to running.
      final aCid = q.pendingFor(sid).first.correlationId;
      q.onMessageStarted(sid, {'correlation_id': aCid});
      final list = q.activeFor(sid);
      expect(list.length, 3);
      expect(list[0].message, 'a');
      expect(list[0].status, QueueEntryStatus.running);
      expect(list[1].message, 'b');
      expect(list[2].message, 'c');
    });
  });

  group('queue_cleared', () {
    test('drops queued rows but keeps running', () {
      q.addOptimistic(sid, 'a');
      q.addOptimistic(sid, 'b');
      final aCid = q.pendingFor(sid).first.correlationId;
      q.onMessageStarted(sid, {'correlation_id': aCid});
      q.onQueueCleared(sid);
      expect(q.pendingFor(sid), isEmpty);
      expect(q.runningFor(sid), isNotNull);
    });
  });
}
