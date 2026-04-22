/// One controller per session that ties together:
///
///   * [HistoryService] — HTTP fetcher for `/history` + backfill
///   * [ChatTimeline] — ordered bubble store (invariant-enforced)
///   * [EventReducer] — the single path that turns daemon events into
///     bubble mutations
///
/// Lifecycle:
///
///   ```
///   final ctrl = HistoryController(dio, onSideEffects: …);
///   await ctrl.loadSession(appId, sid);
///   // attach the widget tree to `ctrl.timeline` / `ctrl.state`
///   // for each live socket event:
///   ctrl.applyLiveEvent(rawEventMap);
///   // when the session closes:
///   ctrl.dispose();
///   ```
///
/// [loadSession] is idempotent — calling it twice with the same
/// sessionId is a no-op. Calling it with a different sessionId wipes
/// the timeline and starts fresh.
///
/// On reconnect the controller bumps a `since_seq` watermark so the
/// daemon only sends events we don't already have.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/chat_message.dart';
import '../../services/history_service.dart';
import 'chat_timeline.dart';
import 'event_reducer.dart';

/// Observable wrapper — widgets listen via `AnimatedBuilder` /
/// `ListenableBuilder` to rebuild when the timeline changes OR when
/// ambient reducer state (spinner, queued, error) changes.
class HistoryController extends ChangeNotifier {
  final HistoryService _svc;

  /// Injected side-effect hooks. Called when the reducer sees an
  /// event that needs the outer widget world (modal open, toast).
  final void Function(EventEnvelope event)? onApproval;
  final void Function(EventEnvelope event)? onCredentialRequired;
  final void Function(EventEnvelope event)? onError;
  final void Function(EventEnvelope event)? onPreviewEvent;
  final void Function(EventEnvelope event)? onWidgetEvent;
  final void Function(EventEnvelope event)? onMemoryEvent;
  final void Function(EventEnvelope event)? onAgentEvent;

  HistoryController({
    required Dio dio,
    this.onApproval,
    this.onCredentialRequired,
    this.onError,
    this.onPreviewEvent,
    this.onWidgetEvent,
    this.onMemoryEvent,
    this.onAgentEvent,
  }) : _svc = HistoryService(dio) {
    timeline.addListener(_bump);
  }

  final ChatTimeline timeline = ChatTimeline();
  final ReducerState state = ReducerState();
  late final EventReducer _reducer = EventReducer(
    timeline: timeline,
    state: state,
    onApproval: onApproval,
    onCredentialRequired: onCredentialRequired,
    onError: onError,
    onPreviewEvent: onPreviewEvent,
    onWidgetEvent: onWidgetEvent,
    onMemoryEvent: onMemoryEvent,
    onAgentEvent: onAgentEvent,
  );

  String? _appId;
  String? _sessionId;
  HistoryMeta? _meta;
  HistoryMeta? get meta => _meta;

  bool _loading = false;
  bool get loading => _loading;

  String? _loadError;
  String? get loadError => _loadError;

  /// Highest event seq ever applied — watermark for reconnect.
  int get lastSeq => timeline.lastSeq;

  String? get currentAppId => _appId;
  String? get currentSessionId => _sessionId;

  void _bump() => notifyListeners();

  /// Cold-open a session: fetch full history, replay events, optionally
  /// fall back to the denormalised ``messages[]`` for legacy sessions
  /// whose event log is incomplete. Safe to call more than once —
  /// the second call with the same (appId, sessionId) pair is a no-op.
  ///
  /// Ordering contract: events are the SOURCE OF TRUTH. They carry
  /// ``seq`` + ``correlation_id`` + ``event_id`` and rebuild every
  /// bubble (user_message, tokens, stream_snapshot, tool_call, etc.).
  /// The denormalised ``messages[]`` from the server has neither
  /// ``correlation_id`` nor ``seq``, so seeding from it BEFORE replay
  /// used to create duplicate bubbles (one from seed without corr, one
  /// from the user_message event with corr). Now we replay events
  /// first; only if that produces zero bubbles (legacy session with a
  /// purged event log) do we fall back to seeding from messages[].
  Future<void> loadSession(String appId, String sessionId) async {
    if (appId == _appId && sessionId == _sessionId && _meta != null) return;
    _appId = appId;
    _sessionId = sessionId;
    _loading = true;
    _loadError = null;
    timeline.clear();
    state.reset();
    notifyListeners();
    try {
      final page = await _svc.fetchAllPages(appId, sessionId);
      // Events FIRST — they own ordering + correlation + full content.
      for (final ev in page.events) {
        _reducer.apply(ev);
      }
      // Fallback for legacy sessions where the event log doesn't
      // contain user_message / assistant streaming events (e.g.
      // sessions recorded before the unified history_log rollout).
      // If events built a usable timeline we skip this entirely.
      if (timeline.isEmpty && page.messages.isNotEmpty) {
        _seedMessages(page.messages);
      }
      _meta = page.meta;
      // A mid-turn reopen leaves the spinner on — live events will
      // finish it. Otherwise make sure we don't have a stale spinner.
      if (!page.meta.turnActive && state.spinnerVisible) {
        state.spinnerVisible = false;
      }
      _loading = false;
      notifyListeners();
    } on HistoryException catch (e) {
      _loading = false;
      _loadError = e.message;
      notifyListeners();
    } catch (e) {
      _loading = false;
      _loadError = e.toString();
      notifyListeners();
    }
  }

  /// Backfill any events the daemon emitted while we were offline.
  /// Called after a Socket.IO reconnect. Safe to call concurrently
  /// with live events — the reducer's dedup on event_id absorbs any
  /// overlap.
  Future<void> backfillSince(int sinceSeq) async {
    final appId = _appId;
    final sessionId = _sessionId;
    if (appId == null || sessionId == null) return;
    try {
      final page = await _svc.fetchPage(
        appId,
        sessionId,
        sinceSeq: sinceSeq,
      );
      for (final ev in page.events) {
        _reducer.apply(ev);
      }
      _meta = page.meta;
      notifyListeners();
    } catch (e) {
      debugPrint('HistoryController: backfill failed: $e');
    }
  }

  /// Feed a raw event envelope (from Socket.IO or a test) through
  /// the reducer. Returns true if the event actually applied, false
  /// when deduped by event_id.
  bool applyLiveEvent(Map<String, dynamic> raw) {
    final ev = EventEnvelope.fromJson(raw);
    final applied = _reducer.apply(ev);
    if (applied) notifyListeners();
    return applied;
  }

  /// Append an optimistic user bubble (before the daemon echoes
  /// `user_message`). The bubble is pinned to the tail via
  /// [ChatTimeline.appendTail]; it will be rekeyed to the real seq
  /// once the reducer sees the echo (matched by `clientMessageId`).
  ChatMessage appendOptimisticUserBubble({
    required String clientMessageId,
    required String text,
    String? correlationId,
  }) {
    final msg = ChatMessage(
      id: 'u_opt_$clientMessageId',
      role: MessageRole.user,
      initialText: text,
      clientMessageId: clientMessageId,
      correlationId: correlationId,
    );
    msg.pending = true;
    timeline.appendTail(msg);
    return msg;
  }

  /// Remove the optimistic bubble for the given [clientMessageId] —
  /// used when the POST failed and we don't want the phantom bubble
  /// to linger. If the daemon already echoed a real one, this removes
  /// the real one too; callers should gate on their own "POST
  /// failed" signal.
  void removeOptimisticBubble(String clientMessageId) {
    final b = timeline.firstWhere(
      (m) => m.clientMessageId == clientMessageId,
    );
    if (b != null) timeline.removeById(b.id);
  }

  /// Internal — seed the timeline from `messages[]` denormalised
  /// rows. Each row becomes one bubble. Tool calls merged in by the
  /// daemon are replayed onto the assistant bubble.
  void _seedMessages(List<HistoryMessage> messages) {
    for (final m in messages) {
      final rawSeq = (m.raw['seq'] as num?)?.toInt();
      final corr = (m.raw['correlation_id'] as String?) ??
          (m.raw['payload'] is Map
              ? (m.raw['payload'] as Map)['correlation_id'] as String?
              : null);
      if (m.isUser) {
        final content = m.content;
        final text = content is String
            ? content
            : (content is List ? _extractUserText(content) : '');
        final bubble = ChatMessage(
          id: 'u_hist_${rawSeq ?? _nextSynthetic()}',
          role: MessageRole.user,
          initialText: text,
          correlationId: corr,
          daemonSeq: rawSeq,
        );
        timeline.upsert(bubble, seq: rawSeq);
      } else if (m.isAssistant) {
        final bubble = ChatMessage(
          id: 'a_hist_${rawSeq ?? _nextSynthetic()}',
          role: MessageRole.assistant,
          correlationId: corr,
          daemonSeq: rawSeq,
        );
        if (m.thinking != null && m.thinking!.isNotEmpty) {
          bubble.setThinkingText(m.thinking!);
        }
        for (final tc in m.toolCalls) {
          bubble.addOrUpdateToolCall(_toolCallFromJson(tc));
        }
        final content = m.content;
        if (content is String && content.isNotEmpty) {
          bubble.appendText(content);
        }
        timeline.upsert(bubble, seq: rawSeq);
      }
      // System messages stay out unless include_system was true.
    }
  }

  int _syntheticCounter = 0;
  int _nextSynthetic() => ++_syntheticCounter;

  /// Best-effort text extraction from a multimodal `content` array.
  /// Returns the concatenation of every `text` part; images / files
  /// are rendered elsewhere.
  String _extractUserText(List content) {
    final sb = StringBuffer();
    for (final p in content) {
      if (p is Map && p['type'] == 'text') {
        final t = p['text'] as String? ?? '';
        if (sb.isNotEmpty) sb.write('\n');
        sb.write(t);
      }
    }
    return sb.toString();
  }

  ToolCall _toolCallFromJson(Map<String, dynamic> j) {
    return ToolCall(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      label: (j['label'] as String?) ?? '',
      detail: (j['detail'] as String?) ?? '',
      detailParam: (j['detail_param'] as String?) ?? '',
      icon: (j['icon'] as String?) ?? 'tool',
      channel: (j['channel'] as String?) ?? 'chat',
      category: (j['category'] as String?) ?? 'action',
      group: (j['group'] as String?) ?? '',
      params: (j['params'] is Map)
          ? Map<String, dynamic>.from(j['params'] as Map)
          : const {},
      status: (j['status'] as String?) ?? 'completed',
      result: j['result'],
      error: j['error'] as String?,
    );
  }

  @override
  void dispose() {
    timeline.removeListener(_bump);
    timeline.dispose();
    super.dispose();
  }
}
