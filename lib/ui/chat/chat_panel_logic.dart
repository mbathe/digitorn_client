// Pure, side-effect-free predicates used by chat_panel. Factored out
// so tests exercise the exact same functions production calls — no
// mirrors, no duplication.

import '../../models/chat_message.dart';
import '../../services/queue_service.dart';

/// True while the daemon is visibly doing something for the current
/// turn. Used by the response-timeout to avoid a false "no response"
/// banner during long tool calls.
bool hasLiveAgentActivity({required bool hadTokens, required String phase}) {
  if (hadTokens) return true;
  if (phase.isEmpty || phase == 'requesting') return false;
  const livePrefixes = [
    'thinking',
    'tool_use',
    'responding',
    'generating',
    'planning',
    'executing',
    'compacting',
    'waiting',
  ];
  for (final prefix in livePrefixes) {
    if (phase.startsWith(prefix)) return true;
  }
  return false;
}

/// Decides whether the next send must be routed through the queue
/// (busy=true) or can hit the daemon directly (busy=false).
bool computeBusy({
  required bool isSending,
  required String sessionId,
  QueueService? queue,
}) {
  final q = queue ?? QueueService();
  return isSending ||
      q.runningFor(sessionId) != null ||
      q.pendingCountFor(sessionId) > 0;
}

/// Walks the dedupe cascade over [messages] to find the optimistic
/// user bubble that an incoming `user_message` event should reconcile
/// with. Returns null when no optimistic candidate exists (cross-tab
/// send, history replay, or fresh queued send never locally echoed).
///
/// Cascade, matching the daemon's own priority:
///   1. clientMessageId — happy path, daemon echoes our uuid.
///   2. correlationId   — daemon minted its own id, we reconciled it
///                        onto the optimistic bubble earlier.
///   3. content + sentinel sortKey — fallback when the daemon drops
///                        client_message_id (history replay, older
///                        bridge versions). Only bubbles still at a
///                        sentinel sortKey are eligible — pinned
///                        bubbles were already reconciled.
ChatMessage? findUserBubbleToReconcile(
  List<ChatMessage> messages, {
  String? clientMessageId,
  String? correlationId,
  required String content,
}) {
  if (clientMessageId != null && clientMessageId.isNotEmpty) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].clientMessageId == clientMessageId) return messages[i];
    }
  }
  if (correlationId != null && correlationId.isNotEmpty) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == MessageRole.user && m.correlationId == correlationId) {
        return m;
      }
    }
  }
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m.role == MessageRole.user &&
        m.text == content &&
        m.daemonSeq == null) {
      return m;
    }
  }
  return null;
}
