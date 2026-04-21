// Real tests against the production chat_panel logic. These import
// chat_panel_logic.dart directly — the same module chat_panel.dart
// calls at runtime. No mirrors, no duplicated predicates.

import 'package:flutter_test/flutter_test.dart';

import 'package:digitorn_client/models/chat_message.dart';
import 'package:digitorn_client/models/queue_entry.dart';
import 'package:digitorn_client/services/queue_service.dart';
import 'package:digitorn_client/ui/chat/chat_panel_logic.dart';

void main() {
  group('hasLiveAgentActivity', () {
    test('tokens already streamed → live', () {
      expect(hasLiveAgentActivity(hadTokens: true, phase: ''), true);
    });

    test('empty phase, no tokens → NOT live (daemon silent)', () {
      expect(hasLiveAgentActivity(hadTokens: false, phase: ''), false);
    });

    test('phase=requesting, no tokens → NOT live', () {
      expect(
          hasLiveAgentActivity(hadTokens: false, phase: 'requesting'), false);
    });

    test('thinking/responding/compacting → live', () {
      for (final p in ['thinking', 'responding', 'compacting', 'generating']) {
        expect(hasLiveAgentActivity(hadTokens: false, phase: p), true,
            reason: 'phase "$p" must count as live');
      }
    });

    test('tool_use with tool name → live', () {
      expect(
          hasLiveAgentActivity(hadTokens: false, phase: 'tool_use:Parallel'),
          true);
      expect(hasLiveAgentActivity(hadTokens: false, phase: 'tool_use'), true);
    });

    test('rate_limited is NOT live', () {
      expect(hasLiveAgentActivity(hadTokens: false, phase: 'rate_limited'),
          false);
    });

    test('unknown phase → NOT live (fail safe)', () {
      expect(hasLiveAgentActivity(hadTokens: false, phase: 'whatever'), false);
    });
  });

  group('computeBusy', () {
    const sid = 'sid-busy';
    late QueueService q;

    setUp(() {
      q = QueueService();
      q.forgetSession(sid);
    });
    tearDown(() => q.forgetSession(sid));

    test('idle queue + !isSending → NOT busy', () {
      expect(computeBusy(isSending: false, sessionId: sid, queue: q), false);
    });

    test('isSending=true alone forces busy', () {
      expect(computeBusy(isSending: true, sessionId: sid, queue: q), true);
    });

    test('running entry in queue → busy even if !isSending', () {
      final e = q.addOptimistic(sid, 'running');
      q.onMessageStarted(sid, {'correlation_id': e.correlationId});
      expect(q.runningFor(sid), isNotNull);
      expect(computeBusy(isSending: false, sessionId: sid, queue: q), true);
    });

    test('pending entry in queue → busy', () {
      q.addOptimistic(sid, 'pending');
      expect(computeBusy(isSending: false, sessionId: sid, queue: q), true);
    });

    test('everything settled → NOT busy', () {
      final e = q.addOptimistic(sid, 'x');
      q.onMessageStarted(sid, {'correlation_id': e.correlationId});
      q.onMessageDone(sid, {'correlation_id': e.correlationId});
      expect(computeBusy(isSending: false, sessionId: sid, queue: q), false);
    });

    test('turn_complete gap — pending still queued → busy', () {
      final t1 = q.addOptimistic(sid, 't1');
      q.onMessageStarted(sid, {'correlation_id': t1.correlationId});
      q.addOptimistic(sid, 't2');
      q.onMessageDone(sid, {'correlation_id': t1.correlationId});
      expect(q.pendingCountFor(sid), 1);
      expect(computeBusy(isSending: false, sessionId: sid, queue: q), true);
    });

    test('accepted fast-path drop → NOT busy (caller may still set isSending)',
        () {
      final e = q.addOptimistic(sid, 'fp');
      q.reconcile(sid, EnqueueResult.accepted(correlationId: 'fp-1'),
          tempCid: e.correlationId);
      expect(q.pendingFor(sid), isEmpty);
      expect(computeBusy(isSending: false, sessionId: sid, queue: q), false);
      expect(computeBusy(isSending: true, sessionId: sid, queue: q), true);
    });
  });

  group('findUserBubbleToReconcile', () {
    test('match by clientMessageId (happy path)', () {
      final optimistic = ChatMessage(
        id: 'u-1',
        role: MessageRole.user,
        initialText: 'hello',
        clientMessageId: 'cmid-abc',
      );
      final hit = findUserBubbleToReconcile(
        [optimistic],
        clientMessageId: 'cmid-abc',
        content: 'hello',
      );
      expect(hit, same(optimistic));
    });

    test('clientMessageId miss falls through to correlationId', () {
      final optimistic = ChatMessage(
        id: 'u-1',
        role: MessageRole.user,
        initialText: 'hello',
        correlationId: 'queue-row-42',
      );
      final hit = findUserBubbleToReconcile(
        [optimistic],
        clientMessageId: 'not-there',
        correlationId: 'queue-row-42',
        content: 'hello',
      );
      expect(hit, same(optimistic));
    });

    test('both ids miss — content+sentinel fallback picks optimistic', () {
      final optimistic = ChatMessage(
        id: 'u-1',
        role: MessageRole.user,
        initialText: 'fallback',
      );
      expect(optimistic.sortKey >= ChatMessage.sentinelThreshold, true);
      final hit = findUserBubbleToReconcile(
        [optimistic],
        content: 'fallback',
      );
      expect(hit, same(optimistic));
    });

    test('content fallback rejects already-reconciled bubble', () {
      final pinned = ChatMessage(
        id: 'u-1',
        role: MessageRole.user,
        initialText: 'pinned',
        daemonSeq: 42,
      );
      final hit = findUserBubbleToReconcile([pinned], content: 'pinned');
      expect(hit, isNull, reason: 'pinned bubble must not be rematched');
    });

    test('content fallback rejects agent bubbles with same text', () {
      final agent = ChatMessage(
        id: 'a-1',
        role: MessageRole.assistant,
        initialText: 'echo me',
      );
      final hit = findUserBubbleToReconcile([agent], content: 'echo me');
      expect(hit, isNull);
    });

    test('duplicate sends — most recent wins in content fallback', () {
      final first = ChatMessage(
        id: 'u-1',
        role: MessageRole.user,
        initialText: 'same',
      );
      final second = ChatMessage(
        id: 'u-2',
        role: MessageRole.user,
        initialText: 'same',
      );
      final hit =
          findUserBubbleToReconcile([first, second], content: 'same');
      expect(hit, same(second));
    });

    test('cross-tab send — no optimistic candidate → null', () {
      final hit = findUserBubbleToReconcile(
        [
          ChatMessage(
              id: 'a-1',
              role: MessageRole.assistant,
              initialText: 'prev reply'),
        ],
        clientMessageId: 'fresh-cmid',
        correlationId: 'fresh-corr',
        content: 'new user text',
      );
      expect(hit, isNull);
    });

    test('empty messages → null', () {
      expect(findUserBubbleToReconcile([], content: 'x'), isNull);
    });
  });
}
