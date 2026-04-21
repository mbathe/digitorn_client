import 'package:flutter_test/flutter_test.dart';
import 'package:digitorn_client/models/chat_message.dart';

// sortKey drives the chat transcript order. Bubbles created
// optimistically (before any server event) get a sentinel key; once
// the server's `seq` arrives, updateSortKey() pins them to
// `seq * 10 + roleOffset`. Sorting by sortKey must always reproduce
// user → assistant chronological order.

void main() {
  group('ChatMessage.sortKey', () {
    test('optimistic bubbles get sentinel keys > any realistic seq', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      expect(m.sortKey, greaterThanOrEqualTo(0x40000000));
    });

    test('updateSortKey anchors to seq * 10 + role offset', () {
      final u = ChatMessage(id: 'u', role: MessageRole.user);
      final a = ChatMessage(id: 'a', role: MessageRole.assistant);
      u.updateSortKey(42);
      a.updateSortKey(43);
      // user offset = 0, assistant offset = 5.
      expect(u.sortKey, 42 * 10);
      expect(a.sortKey, 43 * 10 + 5);
    });

    test('user of turn N sorts before assistant of the same turn N', () {
      final u = ChatMessage(id: 'u', role: MessageRole.user)
        ..updateSortKey(42);
      final a = ChatMessage(id: 'a', role: MessageRole.assistant)
        ..updateSortKey(42);
      expect(u.sortKey, lessThan(a.sortKey));
    });

    test(
        'user N+1 sorts after assistant N (seq monotonic, roles interleave)',
        () {
      final u1 = ChatMessage(id: 'u1', role: MessageRole.user)
        ..updateSortKey(10);
      final a1 = ChatMessage(id: 'a1', role: MessageRole.assistant)
        ..updateSortKey(11);
      final u2 = ChatMessage(id: 'u2', role: MessageRole.user)
        ..updateSortKey(20);
      final a2 = ChatMessage(id: 'a2', role: MessageRole.assistant)
        ..updateSortKey(21);

      final list = [a2, u1, a1, u2]..sort(
          (a, b) => a.sortKey.compareTo(b.sortKey));
      expect(list.map((m) => m.id).toList(), ['u1', 'a1', 'u2', 'a2']);
    });

    test('optimistic user sorts after a pinned agent bubble if no seq yet',
        () {
      // When an optimistic bubble has no seq yet, it sits at the tail
      // (sentinel value). Any pinned message has a lower sortKey.
      final pinnedAgent = ChatMessage(id: 'a', role: MessageRole.assistant)
        ..updateSortKey(1000);
      final optimisticUser =
          ChatMessage(id: 'u', role: MessageRole.user);
      expect(pinnedAgent.sortKey, lessThan(optimisticUser.sortKey));
    });

    test('updateSortKey(0) is a no-op (ephemeral events have no seq)', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      final before = m.sortKey;
      m.updateSortKey(0);
      expect(m.sortKey, before);
    });

    test('updateSortKey notifies listeners so UIs re-sort', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      var notified = 0;
      m.addListener(() => notified++);
      m.updateSortKey(17);
      expect(notified, 1);
      // Setting the same sortKey again still notifies — updateSortKey
      // is unconditional. That's fine; UIs coalesce with setState.
    });

    test('clientMessageId + correlationId carried through reconcile', () {
      final m = ChatMessage(
        id: 'm',
        role: MessageRole.user,
        clientMessageId: 'cmid-1',
        correlationId: 'fp-abc',
      );
      expect(m.clientMessageId, 'cmid-1');
      expect(m.correlationId, 'fp-abc');
    });
  });
}
