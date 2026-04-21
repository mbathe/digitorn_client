/// Regression tests for the reconnect-reconciliation helpers on
/// [ChatMessage].
///
/// Scout-verified scenario: daemon replays every persisted event
/// on `join_session`, then ships `queue:snapshot { is_active:
/// false }` when no turn is in flight. The chat panel uses the
/// helpers under test to finalize any orphaned tool spinner or
/// streaming bubble before the user sees a stale UI.
library;

import 'package:digitorn_client/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _agentMsg() => ChatMessage(
      id: 'msg-1',
      role: MessageRole.assistant,
      initialText: '',
    );

ToolCall _tool({required String status, String? error}) => ToolCall(
      id: 'call-${status}-${DateTime.now().microsecondsSinceEpoch}',
      name: 'workspace.write',
      params: const {'path': 'foo.txt'},
      status: status,
      error: error,
    );

void main() {
  test('hasOpenToolStart true when any tool is still started', () {
    final m = _agentMsg();
    m.addOrUpdateToolCall(_tool(status: 'started'));
    expect(m.hasOpenToolStart, isTrue);

    // Finish the call — no longer open.
    for (final t in m.toolCalls) {
      t.status = 'completed';
    }
    expect(m.hasOpenToolStart, isFalse);
  });

  test(
      'hasOpenToolStart false when all tools are in terminal states',
      () {
    final m = _agentMsg();
    m.addOrUpdateToolCall(_tool(status: 'completed'));
    m.addOrUpdateToolCall(_tool(status: 'failed'));
    expect(m.hasOpenToolStart, isFalse);
  });

  test(
      'markToolStartsInterrupted flips started → failed with a '
      'reconnect reason', () {
    final m = _agentMsg();
    m.addOrUpdateToolCall(_tool(status: 'started'));
    m.addOrUpdateToolCall(_tool(status: 'completed')); // already done

    m.markToolStartsInterrupted();

    final byStatus = {for (final t in m.toolCalls) t.status: t};
    expect(byStatus.containsKey('failed'), isTrue,
        reason: 'started call flipped to failed');
    expect(byStatus.containsKey('completed'), isTrue,
        reason: 'already-completed call left alone');
    expect(byStatus['failed']!.error,
        contains('Interrupted'),
        reason: 'error message must surface the reconnect cause.');
    expect(byStatus['failed']!.completedAt, isNotNull,
        reason: 'completedAt stamped on interruption for the '
            'timer display.');
  });

  test('markToolStartsInterrupted is idempotent (no re-interruption)',
      () {
    final m = _agentMsg();
    m.addOrUpdateToolCall(_tool(
        status: 'failed',
        error: 'Original error — do not clobber'));

    m.markToolStartsInterrupted();

    final t = m.toolCalls.single;
    expect(t.error, 'Original error — do not clobber',
        reason: 'an already-failed call must keep its original '
            'error message; the reconciler only fixes dangling '
            '`started` spinners.');
  });

  test('markToolStartsInterrupted is safe on a message with no '
      'tool calls at all', () {
    final m = _agentMsg();
    // Should not throw or mutate anything.
    m.markToolStartsInterrupted();
    expect(m.toolCalls, isEmpty);
  });
}
