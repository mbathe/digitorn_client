/// Regression test for the "compaction always sinks to the bottom"
/// bug.
///
/// Root cause: `_onCompactionCompleted` used `_anchorForNewLocalBubble()`
/// = max daemon seq seen so far. A compaction hook can fire while
/// ~1k higher-seq envelopes (thinking_delta / out_token / tool_call)
/// are still buffered, and the bubble would anchor to that ballooned
/// max — rendering below every one of them regardless of when the
/// compaction actually happened.
///
/// Fix: thread the hook envelope's own `seq` through to the bubble's
/// `anchorSeq`. This test asserts the resulting sort key slots the
/// compaction between the hook's seq and the next higher seq.
library;

import 'package:digitorn_client/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _makeAgentAt(int seq) {
  final m = ChatMessage(
    id: 'msg-$seq',
    role: MessageRole.assistant,
    initialText: 'at $seq',
  );
  m.updateSortKey(seq);
  return m;
}

ChatMessage _makeCompactionAnchoredTo(int envelopeSeq) {
  return ChatMessage(
    id: 'compact-$envelopeSeq',
    role: MessageRole.system,
    initialText: 'Context compacted: 90k → 28k',
    anchorSeq: envelopeSeq,
  );
}

void main() {
  test(
      'compaction anchored at envelope seq sorts BETWEEN '
      'that seq and the next higher one', () {
    final hook = _makeAgentAt(100); // proxy for the hook envelope
    final laterThinking = _makeAgentAt(101);
    final compaction = _makeCompactionAnchoredTo(100);

    final all = [laterThinking, hook, compaction]..sort(
        (a, b) => a.sortKey.compareTo(b.sortKey));

    expect(all.map((m) => m.id).toList(),
        ['msg-100', 'compact-100', 'msg-101'],
        reason: 'Compaction bubble must land just after its own hook '
            'and before the following higher-seq event.');
  });

  test(
      'the bug: anchoring to the CURRENT MAX seq sinks the '
      'compaction below every buffered higher-seq event', () {
    // Simulate the pre-fix behaviour — anchor to max seq instead of
    // the hook's own seq. The test locks the bug in place so the
    // regression is obvious if the fallback ever wins again.
    final hook = _makeAgentAt(100);
    final buffered = [
      for (final s in [101, 102, 150, 200, 201]) _makeAgentAt(s),
    ];
    final currentMax = 201; // what _anchorForNewLocalBubble returned
    final brokenCompaction = _makeCompactionAnchoredTo(currentMax);

    final all = [...buffered, hook, brokenCompaction]..sort(
        (a, b) => a.sortKey.compareTo(b.sortKey));

    // Broken behaviour: compaction is LAST.
    expect(all.last.id, 'compact-201',
        reason: 'Documents the bug — anchoring to max seq puts '
            'the compaction below every buffered event. The fix '
            'passes the hook envelope seq instead.');
  });

  test(
      'multiple compactions in the same turn stack in seq order',
      () {
    final h1 = _makeAgentAt(50);
    final h2 = _makeAgentAt(70);
    final c1 = _makeCompactionAnchoredTo(50);
    final c2 = _makeCompactionAnchoredTo(70);
    final assistant = _makeAgentAt(80);

    final all = [assistant, c2, h1, h2, c1]..sort(
        (a, b) => a.sortKey.compareTo(b.sortKey));

    expect(all.map((m) => m.id).toList(),
        ['msg-50', 'compact-50', 'msg-70', 'compact-70', 'msg-80']);
  });

  test(
      'fallback path: when the envelope seq is null/0 we anchor '
      'to the current max so the bubble still lands at the tail '
      '— matches the pre-fix behaviour as a graceful degradation',
      () {
    // The real fallback in chat_panel.dart passes
    // `_anchorForNewLocalBubble()` which returns the max daemon
    // seq seen so far. Simulate that here by anchoring to the max.
    final buffered = [_makeAgentAt(10), _makeAgentAt(20)];
    final compaction = _makeCompactionAnchoredTo(20); // current max

    final all = [...buffered, compaction]..sort(
        (a, b) => a.sortKey.compareTo(b.sortKey));

    // Compaction anchored at max seq tiebreaks AFTER the msg at
    // that same seq thanks to the provisional tick.
    expect(all.map((m) => m.id).toList(),
        ['msg-10', 'msg-20', 'compact-20']);
  });
}
