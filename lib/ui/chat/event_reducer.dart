/// Single reducer that turns a daemon event into deterministic
/// mutations on a [ChatTimeline]. No side-effect is allowed to go
/// AROUND this function — every bubble mutation during live streaming
/// or history replay must funnel through [apply].
///
/// Contract:
///
///   1. Dedup by `payload.event_id`. Ring-buffer replay + Socket.IO
///      fanout can deliver the same event twice; `ChatTimeline`
///      tracks a seen set we check first.
///   2. Sort by envelope-level `seq`. Timestamps are NEVER used as an
///      ordering key — they only tie-break for the rare pre-seq
///      legacy event, which is already stripped at replay time.
///   3. Every bubble inserted or updated carries the envelope's
///      `seq` — there is no client-fabricated anchor. Optimistic
///      bubbles (e.g. the local echo of a user Send) live at the tail
///      via [ChatTimeline.appendTail] until [apply] sees the daemon's
///      echo and calls [ChatTimeline.rekey] to pin them.
///
/// This file is intentionally domain-focused: it knows about bubbles
/// and correlations, not about fonts, colors, or the widget tree.
library;

import 'package:flutter/foundation.dart';

import '../../models/chat_message.dart';
import 'chat_timeline.dart';

/// Ambient per-session UI state maintained alongside the timeline.
/// The reducer mutates this together with the bubble list so consumers
/// get atomic visible + invisible state transitions.
class ReducerState {
  /// The correlation_id of the currently-running turn, or null when
  /// the session is idle.
  String? currentTurn;

  /// True while the daemon is actively processing (message_started
  /// received, message_done / message_cancelled / error not yet).
  /// The composer's spinner + the live tool-chip strip consume this.
  bool spinnerVisible = false;

  /// True when a turn is currently queued behind another running one
  /// (message_queued received with a pending position). Cleared on
  /// message_started or message_cancelled.
  bool turnQueued = false;

  /// Queue depth reported by `message_queued`. Rendered next to the
  /// composer as "queued, position N".
  int queuedPosition = 0;

  /// Live thinking buffer for the current turn. Accumulates deltas;
  /// flushed into the associated assistant bubble's metadata on
  /// `thinking` (final) or `message_done`.
  final StringBuffer thinkingBuffer = StringBuffer();

  /// Last classified error payload, or null. Consumers render the
  /// matching banner/modal/toast based on `category` and clear this
  /// themselves after dismissal.
  Map<String, dynamic>? lastError;

  /// Pending approvals keyed by approval_id. Drives the approval
  /// modal(s).
  final Map<String, Map<String, dynamic>> pendingApprovals = {};

  void reset() {
    currentTurn = null;
    spinnerVisible = false;
    turnQueued = false;
    queuedPosition = 0;
    thinkingBuffer.clear();
    lastError = null;
    pendingApprovals.clear();
  }
}

/// Shape-normalised view over the daemon's event envelope. The
/// daemon persists both "message rows" and "event rows" in the same
/// table, so the wire format carries top-level columns that aren't
/// in the payload; the reducer only needs a small subset.
@immutable
class EventEnvelope {
  final int seq;
  final String ts;
  final String type;

  /// `payload.correlation_id` or top-level `correlation_id` — the
  /// daemon promotes it both ways depending on the event class, so
  /// we accept whichever. Empty string when the event is not
  /// turn-scoped (e.g. `preview:*`, `memory_update`).
  final String correlationId;

  /// `payload.event_id` — the dedup key. Unique per event across all
  /// rooms and all replays.
  final String eventId;

  final Map<String, dynamic> payload;

  const EventEnvelope({
    required this.seq,
    required this.ts,
    required this.type,
    required this.correlationId,
    required this.eventId,
    required this.payload,
  });

  factory EventEnvelope.fromJson(Map<String, dynamic> j) {
    final payload = (j['payload'] is Map)
        ? Map<String, dynamic>.from(j['payload'] as Map)
        : <String, dynamic>{};
    // correlation_id may live at top level or inside payload — prefer
    // whichever is non-empty. Same for event_id.
    String corr = (j['correlation_id'] as String?) ?? '';
    if (corr.isEmpty) corr = (payload['correlation_id'] as String?) ?? '';
    String evId = (payload['event_id'] as String?) ?? '';
    if (evId.isEmpty) evId = (j['event_id'] as String?) ?? '';
    return EventEnvelope(
      seq: (j['seq'] as num?)?.toInt() ?? 0,
      ts: (j['ts'] as String?) ?? '',
      type: (j['type'] as String?) ?? '',
      correlationId: corr,
      eventId: evId,
      payload: payload,
    );
  }

  /// Non-null [seq] in a non-zero form. Events with seq == 0 are
  /// ephemeral (pre-persist) and should NEVER be used as an ordering
  /// key — the reducer surfaces them into ambient state only.
  int? get authoritativeSeq => seq > 0 ? seq : null;

  @override
  String toString() =>
      'Event(seq: $seq, type: $type, corr: $correlationId, id: $eventId)';
}

/// The reducer. Owns no state of its own; all state lives on the
/// passed-in [ChatTimeline] + [ReducerState]. That separation lets a
/// single session have an arbitrary number of observers (main panel
/// + minimap + test harness) all sharing the same source of truth.
class EventReducer {
  final ChatTimeline timeline;
  final ReducerState state;

  /// Called for events that need UI-level side-effects outside the
  /// bubble timeline — opening modals, routing to credential picker,
  /// firing a toast. The reducer keeps [apply] pure on the timeline +
  /// state; these hooks are how the widget layer gets notified.
  final void Function(EventEnvelope event)? onApproval;
  final void Function(EventEnvelope event)? onCredentialRequired;
  final void Function(EventEnvelope event)? onError;

  /// Optional bridge into `SessionService` / `PreviewStore` etc. The
  /// reducer calls these for events that belong to auxiliary state
  /// (memory snapshot, preview files, widgets) without knowing their
  /// implementations. Pass null to ignore that event family.
  final void Function(EventEnvelope event)? onPreviewEvent;
  final void Function(EventEnvelope event)? onWidgetEvent;
  final void Function(EventEnvelope event)? onMemoryEvent;
  final void Function(EventEnvelope event)? onAgentEvent;

  /// Diagnostic hook fired on every event the reducer can't classify.
  /// Default logs once to the debug console.
  final void Function(EventEnvelope event)? onUnknown;

  EventReducer({
    required this.timeline,
    required this.state,
    this.onApproval,
    this.onCredentialRequired,
    this.onError,
    this.onPreviewEvent,
    this.onWidgetEvent,
    this.onMemoryEvent,
    this.onAgentEvent,
    this.onUnknown,
  });

  /// Route an event envelope through the reducer. Idempotent on
  /// `event_id` — a duplicate call is a silent no-op. Returns true
  /// when the event actually applied, false when deduped.
  bool apply(EventEnvelope ev) {
    if (ev.eventId.isNotEmpty && timeline.hasSeenEvent(ev.eventId)) {
      return false;
    }
    if (ev.eventId.isNotEmpty) timeline.markEventSeen(ev.eventId);

    switch (ev.type) {
      // ── Message lifecycle ──────────────────────────────────────────────
      case 'user_message':
        _applyUserMessage(ev);
        break;
      case 'message_queued':
        _applyMessageQueued(ev);
        break;
      case 'message_started':
        _applyMessageStarted(ev);
        break;
      case 'message_merged':
        _applyMessageMerged(ev);
        break;
      case 'message_replaced':
        _applyMessageReplaced(ev);
        break;
      case 'message_done':
      case 'turn_complete':
      case 'turn_end':
        _applyMessageDone(ev);
        break;
      case 'message_cancelled':
      case 'abort':
        _applyMessageCancelled(ev);
        break;
      case 'result':
        _applyResult(ev);
        break;

      // ── Streaming deltas ──────────────────────────────────────────────
      case 'token':
        _applyToken(ev);
        break;
      case 'assistant_stream_snapshot':
        _applyStreamSnapshot(ev);
        break;
      case 'thinking_started':
        state.thinkingBuffer.clear();
        // Ensure the bubble exists AND open a fresh thinking block.
        // Without this, the first thinking_delta lands before any
        // bubble exists (token events would create one, but they
        // arrive AFTER the thinking burst), and the per-block counter
        // for the very first thought never renders. `beginThinkingBlock`
        // also gives multi-block turns (think → tool → think → ...) a
        // distinct, independently-counted thinking section each time.
        _ensureAssistant(ev).beginThinkingBlock();
        break;
      case 'thinking_delta':
        final d = ev.payload['delta'] as String? ?? '';
        if (d.isNotEmpty) state.thinkingBuffer.write(d);
        // Per-block live token count (litellm-tokenized server-side,
        // scoped to THIS thinking block — does not include the text
        // response that follows). Use _ensureAssistant so the count
        // lands even when no `thinking_started` event preceded us
        // (some providers stream thinking_delta directly).
        final c = ev.payload['count'];
        if (c is int && c > 0) {
          _ensureAssistant(ev).setActiveThinkingTokens(c);
        }
        break;
      case 'thinking':
        _applyThinkingFinal(ev);
        break;
      case 'stream_done':
        // Server side-effect only; the spinner stays until message_done.
        break;

      // ── Tool lifecycle ────────────────────────────────────────────────
      case 'tool_start':
        _applyToolStart(ev);
        break;
      case 'tool_call':
        _applyToolCall(ev);
        break;

      // ── Approvals + credentials (hook out to UI) ─────────────────────
      case 'approval_request':
        final id = (ev.payload['approval_id'] as String?) ?? ev.eventId;
        state.pendingApprovals[id] = ev.payload;
        onApproval?.call(ev);
        break;
      case 'credential_required':
      case 'credential_auth_required':
        onCredentialRequired?.call(ev);
        break;

      // ── Errors (classified) ──────────────────────────────────────────
      case 'error':
        state.lastError = ev.payload;
        onError?.call(ev);
        break;

      // ── Memory / preview / widgets / agents — delegated ──────────────
      case 'memory_update':
        onMemoryEvent?.call(ev);
        break;
      case 'preview:state_changed':
      case 'preview:state_patched':
      case 'preview:resource_set':
      case 'preview:resource_patched':
      case 'preview:resource_deleted':
      case 'preview:resource_bulk_set':
      case 'preview:channel_cleared':
      case 'preview:snapshot':
      case 'preview:cleared':
        onPreviewEvent?.call(ev);
        break;
      case 'widget:render':
      case 'widget:update':
      case 'widget:close':
      case 'widget:error':
      case 'widget:state':
      case 'widget:cleared':
      case 'widget:snapshot':
        onWidgetEvent?.call(ev);
        break;
      case 'agent_event':
      case 'spawn_agent':
      case 'agent_progress':
      case 'agent_result':
      case 'agent_cancel':
        onAgentEvent?.call(ev);
        break;

      // ── Silent telemetry ─────────────────────────────────────────────
      case 'hook':
      case 'hook_notification':
      case 'out_token':
      case 'in_token':
      case 'token_usage':
      case 'status':
      case 'notification':
      case 'notification_result':
      case 'bg_task_update':
      case 'terminal_output':
        break;

      default:
        onUnknown?.call(ev);
        debugPrint('EventReducer: unknown event type ${ev.type}');
    }
    return true;
  }

  // ── Private handlers ────────────────────────────────────────────────────

  void _applyUserMessage(EventEnvelope ev) {
    final corr = ev.correlationId;
    final clientMessageId = ev.payload['client_message_id'] as String? ?? '';
    final content = ev.payload['content'] as String? ?? '';
    final pending = ev.payload['pending'] == true;
    final seq = ev.authoritativeSeq;

    // Reconcile with an optimistic bubble inserted at Send time. Match
    // by clientMessageId first (authoritative), fall back to
    // correlation id for legacy senders.
    ChatMessage? existing;
    if (clientMessageId.isNotEmpty) {
      existing = timeline.firstWhere(
          (m) => m.role == MessageRole.user && m.clientMessageId == clientMessageId);
    }
    existing ??= corr.isEmpty
        ? null
        : timeline.firstWhere(
            (m) => m.role == MessageRole.user && m.correlationId == corr);

    if (existing != null) {
      if (seq != null) {
        existing.updateSortKey(seq);
        timeline.rekey(existing.id, seq: seq);
      }
      existing.correlationId = corr.isEmpty ? existing.correlationId : corr;
      existing.pending = pending;
      return;
    }
    // No optimistic bubble — we arrived late or this is a replay. Mint
    // a fresh bubble pinned to the event's seq.
    final msg = ChatMessage(
      id: 'u_${ev.eventId}',
      role: MessageRole.user,
      initialText: content,
      correlationId: corr.isEmpty ? null : corr,
      clientMessageId: clientMessageId.isEmpty ? null : clientMessageId,
      daemonSeq: seq,
    );
    msg.pending = pending;
    timeline.upsert(msg, seq: seq);
  }

  void _applyMessageQueued(EventEnvelope ev) {
    state.turnQueued = true;
    state.queuedPosition = (ev.payload['position'] as num?)?.toInt() ?? 0;
    // The queued message itself is already rendered (optimistic user
    // bubble) — we just flag the ambient state so the composer can
    // surface "queued, position N".
  }

  void _applyMessageStarted(EventEnvelope ev) {
    state.currentTurn = ev.correlationId;
    state.spinnerVisible = true;
    state.turnQueued = false;
    state.queuedPosition = 0;
  }

  void _applyMessageMerged(EventEnvelope ev) {
    // A pending bubble got folded into a running turn. Rebind the
    // optimistic bubble's correlation_id so subsequent events find it.
    final oldCorr = ev.payload['old_correlation_id'] as String? ?? '';
    final newCorr = ev.payload['into_correlation_id'] as String? ??
        ev.correlationId;
    if (oldCorr.isEmpty) return;
    final b = timeline.firstWhere((m) => m.correlationId == oldCorr);
    if (b != null) b.correlationId = newCorr;
  }

  void _applyMessageReplaced(EventEnvelope ev) {
    // User re-sent a message — replace the content of the optimistic
    // bubble so the user sees their edit land.
    final corr =
        ev.payload['new_correlation_id'] as String? ?? ev.correlationId;
    final content = ev.payload['content'] as String? ?? '';
    final b = timeline.firstWhere(
        (m) => m.role == MessageRole.user && m.correlationId == corr);
    if (b == null) return;
    b.replaceText(content);
  }

  void _applyMessageDone(EventEnvelope ev) {
    final corr = ev.correlationId;
    final seq = ev.authoritativeSeq;
    final bubble = _assistantFor(corr);
    if (bubble != null) {
      bubble.setStreamingState(false);
      bubble.setThinkingState(false);
      if (seq != null) {
        bubble.updateSortKey(seq);
        timeline.rekey(bubble.id, seq: seq);
      }
      // Flush any residual thinking buffer onto the bubble.
      if (state.thinkingBuffer.isNotEmpty) {
        bubble.setThinkingText(state.thinkingBuffer.toString());
        state.thinkingBuffer.clear();
      }
    }
    if (state.currentTurn == corr) {
      state.currentTurn = null;
      state.spinnerVisible = false;
    }
  }

  void _applyMessageCancelled(EventEnvelope ev) {
    final corr = ev.correlationId;
    final bubble = _assistantFor(corr);
    if (bubble != null) {
      bubble.setStreamingState(false);
      bubble.setThinkingState(false);
      // Flip any dangling `started` tool chip to failed so the UI
      // stops spinning forever.
      bubble.markToolStartsInterrupted();
    }
    if (state.currentTurn == corr) {
      state.currentTurn = null;
      state.spinnerVisible = false;
    }
  }

  void _applyResult(EventEnvelope ev) {
    // Legacy fallback — some daemons emit `result` instead of a
    // stream of tokens. Treat it as "assign full text + finalise".
    final text = ev.payload['content'] as String? ?? '';
    if (text.isEmpty) return;
    final bubble = _ensureAssistant(ev);
    bubble.replaceText(text);
  }

  void _applyToken(EventEnvelope ev) {
    // Daemon payload: { delta: "chunk", count?: 142 }
    // Compat fallback for older daemons that sent `content`.
    final chunk =
        (ev.payload['delta'] as String?) ??
        (ev.payload['content'] as String?) ??
        '';
    final count = ev.payload['count'];
    if (chunk.isEmpty && count == null) return;
    final bubble = _ensureAssistant(ev);
    if (chunk.isNotEmpty) bubble.appendText(chunk);
    if (count is int && count > 0) {
      bubble.setOutTokensCumulative(count);
    }
  }

  void _applyStreamSnapshot(EventEnvelope ev) {
    final content = ev.payload['content'] as String? ?? '';
    final bubble = _ensureAssistant(ev);
    bubble.replaceText(content);
  }

  void _applyThinkingFinal(EventEnvelope ev) {
    // Daemon now sends `text`; older builds used `content`. Final
    // per-block token count lands here too if available.
    final content = (ev.payload['text'] as String?) ??
        (ev.payload['content'] as String?) ??
        '';
    // _ensureAssistant (not _assistantFor): a turn that thinks then
    // tool-calls — with no visible text — would otherwise drop the
    // thinking snapshot because no token event ever ran to create
    // the bubble.
    final bubble = _ensureAssistant(ev);
    if (content.isNotEmpty) bubble.setThinkingText(content);
    final c = ev.payload['count'];
    if (c is int && c > 0) {
      bubble.setActiveThinkingTokens(c);
    }
    bubble.setThinkingState(false);
    state.thinkingBuffer.clear();
  }

  void _applyToolStart(EventEnvelope ev) {
    final bubble = _ensureAssistant(ev);
    final call = ToolCall(
      id: (ev.payload['call_id'] as String?) ??
          (ev.payload['op_id'] as String?) ??
          ev.eventId,
      name: (ev.payload['tool'] as String?) ??
          (ev.payload['tool_name'] as String?) ??
          '',
      params: (ev.payload['params'] is Map)
          ? Map<String, dynamic>.from(ev.payload['params'] as Map)
          : const {},
      status: 'started',
      label: (ev.payload['label'] as String?) ?? '',
      detail: (ev.payload['detail'] as String?) ?? '',
      detailParam: (ev.payload['detail_param'] as String?) ?? '',
      icon: (ev.payload['icon'] as String?) ?? 'tool',
      channel: (ev.payload['channel'] as String?) ?? 'chat',
      category: (ev.payload['category'] as String?) ?? 'action',
      group: (ev.payload['group'] as String?) ?? '',
    );
    bubble.addOrUpdateToolCall(call);
  }

  void _applyToolCall(EventEnvelope ev) {
    final callId = (ev.payload['call_id'] as String?) ??
        (ev.payload['op_id'] as String?);
    if (callId == null) return;
    final bubble = _assistantFor(ev.correlationId) ?? _ensureAssistant(ev);
    final success = ev.payload['success'] == true;
    // Pass a fresh ToolCall with the finalised fields — `addOrUpdateToolCall`
    // already merges non-empty incoming over existing and won't regress
    // status, so we get the "update" for free without a copyWith.
    bubble.addOrUpdateToolCall(ToolCall(
      id: callId,
      name: (ev.payload['tool'] as String?) ??
          (ev.payload['tool_name'] as String?) ??
          '',
      status: success ? 'completed' : 'failed',
      result: ev.payload['result'],
      error: ev.payload['error'] as String?,
      label: (ev.payload['label'] as String?) ?? '',
      detail: (ev.payload['detail'] as String?) ?? '',
      detailParam: (ev.payload['detail_param'] as String?) ?? '',
      icon: (ev.payload['icon'] as String?) ?? 'tool',
      channel: (ev.payload['channel'] as String?) ?? 'chat',
      category: (ev.payload['category'] as String?) ?? 'action',
      group: (ev.payload['group'] as String?) ?? '',
      params: (ev.payload['params'] is Map)
          ? Map<String, dynamic>.from(ev.payload['params'] as Map)
          : const {},
    ));
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  ChatMessage? _assistantFor(String correlationId) {
    if (correlationId.isEmpty) return null;
    return timeline.firstWhere((m) =>
        m.role == MessageRole.assistant && m.correlationId == correlationId);
  }

  ChatMessage _ensureAssistant(EventEnvelope ev) {
    final existing = _assistantFor(ev.correlationId);
    if (existing != null) return existing;
    final seq = ev.authoritativeSeq;
    final msg = ChatMessage(
      id: 'a_${ev.correlationId.isEmpty ? ev.eventId : ev.correlationId}',
      role: MessageRole.assistant,
      correlationId:
          ev.correlationId.isEmpty ? null : ev.correlationId,
      daemonSeq: seq,
    );
    msg.setStreamingState(true);
    timeline.upsert(msg, seq: seq);
    return msg;
  }
}
