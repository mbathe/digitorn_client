import 'package:flutter/foundation.dart';

import '../widgets_v1/models.dart';

enum MessageRole { user, assistant, system }

// ─── Timeline content blocks ─────────────────────────────────────────────────
// Each block represents one element in the chronological message flow.

enum ContentBlockType {
  text,
  toolCall,
  /// Live placeholder while the LLM is composing a tool call's args
  /// JSON, BEFORE execution. Carries `callId`, `toolName`,
  /// `thinkingTokens` (per-call litellm count of args). Replaced by a
  /// real `toolCall` block when the matching `tool_start` event lands.
  toolCallStreaming,
  thinking,
  agentEvent,
  hookEvent,
  widget, // Inline Digitorn widget rendered in a chat bubble (Z1)
}

/// Payload for an inline widget rendered as part of an assistant
/// message. [paneSpec] holds the resolved widget tree (either from
/// a `ref:` lookup against `AppState.activeAppWidgets.inline[...]`
/// or inlined in the SSE event). [widgetId] is the unique id the
/// daemon assigned so follow-up `widget:update` / `widget:close`
/// events can target the right instance. [ctx] is the optional
/// initial binding context passed by the agent.
class InlineWidgetPayload {
  final String widgetId;
  final WidgetPaneSpec paneSpec;
  final Map<String, dynamic> ctx;
  final DateTime createdAt;

  InlineWidgetPayload({
    required this.widgetId,
    required this.paneSpec,
    this.ctx = const {},
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

class ContentBlock {
  final ContentBlockType type;

  // Text block
  String textContent;

  // Tool call block
  ToolCall? toolCall;

  // Tool-call-streaming placeholder
  String? streamingCallId;
  String? streamingToolName;

  // Thinking block
  bool thinkingActive;
  /// Per-block cumulative completion-token count, sourced from the
  /// daemon's SSE `thinking_delta`/`thinking` events `payload.count`.
  /// Each thinking block has its OWN counter — it does NOT accumulate
  /// across blocks or include the assistant's text-response tokens.
  /// Mutated post-construction via [ChatMessage.setActiveThinkingTokens].
  int thinkingTokens = 0;

  // Agent event block
  AgentEventData? agentEvent;

  // Hook event block
  HookEventData? hookEvent;

  // Inline widget block
  InlineWidgetPayload? widget;

  ContentBlock._({
    required this.type,
    this.textContent = '',
    this.toolCall,
    this.thinkingActive = false,
    this.streamingCallId,
    this.streamingToolName,
    this.agentEvent,
    this.hookEvent,
    this.widget,
  });

  factory ContentBlock.text(String text) =>
      ContentBlock._(type: ContentBlockType.text, textContent: text);

  factory ContentBlock.tool(ToolCall call) =>
      ContentBlock._(type: ContentBlockType.toolCall, toolCall: call);

  factory ContentBlock.toolCallStreaming({
    required String callId,
    required String toolName,
  }) =>
      ContentBlock._(
        type: ContentBlockType.toolCallStreaming,
        streamingCallId: callId,
        streamingToolName: toolName,
      );

  factory ContentBlock.thinking({String text = '', bool active = true}) =>
      ContentBlock._(
          type: ContentBlockType.thinking,
          textContent: text,
          thinkingActive: active);

  factory ContentBlock.agent(AgentEventData event) =>
      ContentBlock._(type: ContentBlockType.agentEvent, agentEvent: event);

  factory ContentBlock.hook(HookEventData event) =>
      ContentBlock._(type: ContentBlockType.hookEvent, hookEvent: event);

  factory ContentBlock.widget(InlineWidgetPayload payload) =>
      ContentBlock._(type: ContentBlockType.widget, widget: payload);
}

// ─── Data classes for rich events ────────────────────────────────────────────

/// Mirror of the daemon's `data.display` block (contract v2). Every
/// field is guaranteed present by the daemon — for old builds that
/// omit `display` entirely the [ToolCall] constructor synthesises a
/// safe default.
///
/// Canonical values (unknown values fall back to the safe defaults
/// noted in parentheses):
///   - icon    → file, folder, checklist, memory, terminal, search,
///               agent, web, database, git, tool, image, network,
///               edit, preview, workspace, diagnostics, shell (tool)
///   - channel → chat, tasks, memory, agents, workspace, terminal,
///               diagnostics, preview, none (chat)
///   - category → action, plumbing, memory, control_flow (action)
class ToolCall {
  final String id;
  final String name;
  final String label;  // Display verb from daemon (e.g. "Read", "Write", "Bash")
  final String detail; // Display detail from daemon (e.g. file path, command)
  /// Legacy / forward-compat alias: when the daemon points at a
  /// specific param via `display.detail_param`, use that param's
  /// value as the detail when [detail] itself is empty. Not part of
  /// the v2 contract (the v2 contract resolves [detail] server-side)
  /// but kept so experimental daemons that emit this field still
  /// work.
  final String detailParam;
  final String icon;   // Semantic icon: file, folder, edit, terminal, search, agent, web, database, tool
  final String channel; // Routing: chat, workspace, tasks, memory, terminal, none
  final String category; // action, plumbing, memory, control_flow
  final String group;  // Visual grouping: filesystem, workbench, etc.

  /// Contract v2 `display.hidden`. When true the bubble MUST NOT
  /// render in the chat (§Rendering rules, first branch). The daemon
  /// is authoritative; the client must not second-guess by parsing
  /// the tool name.
  final bool hidden;

  /// Contract v2 `display.visible_params`. Names of params the
  /// daemon considers user-facing — the rest of [params] should be
  /// treated as implementation detail and not rendered. null means
  /// the daemon couldn't introspect the schema; callers then render
  /// every param.
  final List<String>? visibleParams;

  final Map<String, dynamic> params;
  String status; // 'started' | 'completed' | 'failed'
  dynamic result;
  String? error;
  String? previousContent;
  String? newContent;
  /// Freeform textual output (filesystem glob/grep, shell stdout). For
  /// filesystem tools this is the ActionResult `output` field even when
  /// `result` is `null`.
  String? output;
  /// Structured side-channel returned by the daemon (bytes_written,
  /// matches, closest_matches, image_mime, …).
  Map<String, dynamic>? metadata;
  /// Short human-readable diff summary produced server-side
  /// (e.g. `Changes:\n  Line 9:\n    - …\n    + …`).
  String? diff;
  /// Standard unified diff (workspace.edit). Parseable.
  String? unifiedDiff;
  String? imageData;
  String? imageMime;

  /// Daemon envelope `ts` on the `tool_start` event — i.e. when
  /// the daemon started running this tool call. Populated from the
  /// Socket.IO envelope, NOT from any field in the result map.
  DateTime? startedAt;

  /// Daemon envelope `ts` on the `tool_call` event — i.e. when the
  /// result landed on the daemon. Pair with [startedAt] to get the
  /// observed execution duration (`completedAt - startedAt`).
  DateTime? completedAt;

  /// Observed execution duration (`completedAt - startedAt`). Null
  /// when either timestamp is missing.
  Duration? get observedDuration {
    if (startedAt == null || completedAt == null) return null;
    final d = completedAt!.difference(startedAt!);
    return d.isNegative ? null : d;
  }

  ToolCall({
    required this.id,
    required this.name,
    this.label = '',
    this.detail = '',
    this.detailParam = '',
    this.icon = '',
    this.channel = 'chat',
    this.category = 'action',
    this.group = '',
    this.hidden = false,
    this.visibleParams,
    required this.params,
    this.status = 'started',
    this.result,
    this.error,
    this.previousContent,
    this.newContent,
    this.output,
    this.metadata,
    this.diff,
    this.unifiedDiff,
    this.imageData,
    this.imageMime,
    this.startedAt,
    this.completedAt,
  });

  /// True if the `params` map should be filtered through
  /// [visibleParams] before rendering. False when the daemon didn't
  /// provide a visible-params list (no introspection available) —
  /// caller should render all params.
  bool get hasVisibleParamsHint =>
      visibleParams != null && visibleParams!.isNotEmpty;

  /// Returns a filtered copy of [params] honouring the daemon's
  /// `display.visible_params`. When no hint is available returns
  /// [params] unchanged.
  Map<String, dynamic> get visibleParamsMap {
    if (visibleParams == null) return params;
    final allowed = visibleParams!.toSet();
    return {
      for (final e in params.entries)
        if (allowed.contains(e.key)) e.key: e.value,
    };
  }

  bool get hasFullDiff => previousContent != null && newContent != null;

  /// Display verb — uses daemon-provided label, fallback to parsed name
  String get displayLabel {
    // Parallel: show count
    if (name == 'run_parallel' && result is Map && result['results'] is List) {
      final count = (result['results'] as List).length;
      return '$count Parallel actions';
    }
    // ask_user: show approved/denied status
    if (name.toLowerCase().contains('ask_user')) {
      if (result is Map) {
        final status = (result as Map)['status'] as String? ?? '';
        if (status == 'approved') return 'Asked user · approved';
        if (status == 'denied' || status == 'rejected') return 'Asked user · denied';
      }
      return 'Asked user';
    }
    if (label.isNotEmpty) return label;
    final segs = name
        .split(RegExp(r'[._\-/:]+'))
        .where((s) => s.isNotEmpty && s.toLowerCase() != 'mcp')
        .toList();
    if (segs.isEmpty) return name;
    final last = segs.last;
    return last[0].toUpperCase() + last.substring(1);
  }

  /// Truncate [v] smartly. File-like paths keep the last two segments
  /// (`…/folder/file.ext`); plain strings clip with an ellipsis.
  static String _truncateDetail(String v) {
    if (v.length <= 60) return v;
    if (v.contains('/') || v.contains('\\')) {
      final parts = v.replaceAll('\\', '/').split('/');
      return parts.length > 2
          ? '…/${parts.sublist(parts.length - 2).join('/')}'
          : v;
    }
    return '${v.substring(0, 59)}…';
  }

  /// Display detail — uses daemon-provided detail, falls back to
  /// the param key the daemon pointed at via `display.detail_param`,
  /// and as a last resort scans a heuristic shortlist. The param
  /// lookup is the daemon's authoritative choice — never override
  /// it with heuristics when [detailParam] is set.
  String get displayDetail {
    if (detail.isNotEmpty) return detail;

    // Daemon told us exactly which param is the "detail" — honour it.
    if (detailParam.isNotEmpty && params.containsKey(detailParam)) {
      final v = params[detailParam];
      if (v is String && v.isNotEmpty) return _truncateDetail(v);
      if (v != null) {
        final s = v.toString();
        if (s.isNotEmpty) return _truncateDetail(s);
      }
    }

    // ask_user: show the question as detail
    if (name.toLowerCase().contains('ask_user')) {
      final q = params['question'] as String? ?? '';
      if (q.isNotEmpty) return q.length > 60 ? '${q.substring(0, 60)}…' : q;
    }
    // Legacy heuristic — kept only for tools that don't yet send
    // `display.detail_param`. Walk the usual suspects.
    for (final k in ['path', 'file', 'filename', 'name', 'query', 'command', 'url', 'key']) {
      if (params.containsKey(k) && params[k] is String && (params[k] as String).isNotEmpty) {
        return _truncateDetail(params[k] as String);
      }
    }
    return '';
  }
}

class AgentEventData {
  final String agentId;
  final String status; // spawned | running | completed | failed | cancelled
  final String specialist;
  final String task;
  final double duration;
  final String preview;
  final int toolCallsCount;
  final String? resultSummary;
  final String? error;

  AgentEventData({
    required this.agentId,
    required this.status,
    this.specialist = '',
    this.task = '',
    this.duration = 0,
    this.preview = '',
    this.toolCallsCount = 0,
    this.resultSummary,
    this.error,
  });
}

class HookEventData {
  final String hookId;
  final String actionType;
  final String phase; // before | after
  final Map<String, dynamic> details;

  HookEventData({
    required this.hookId,
    required this.actionType,
    required this.phase,
    this.details = const {},
  });
}

// ─── ChatMessage ──────────────────────────────────────────────────────────────

class ChatMessage extends ChangeNotifier {
  final String id;
  final MessageRole role;
  final DateTime createdAt;

  /// Daemon-assigned sequence number for the event that spawned or
  /// now owns this bubble. `seq` is monotonic strict per-user on the
  /// daemon side (assigned atomically at publish time) and is the
  /// SOLE source of truth for chat ordering per the event-spec
  /// (§0 "La règle d'or — l'ordre vient du daemon, pas du client").
  ///
  /// Null for optimistic bubbles that have not yet been reconciled
  /// with a daemon echo. Once set via [updateSortKey] the bubble
  /// snaps to its authoritative seq position and never moves again
  /// (daemon seqs don't change).
  int? _daemonSeq;
  int? get daemonSeq => _daemonSeq;

  /// The highest daemon seq seen in the chat when this bubble was
  /// constructed. Used to anchor local-only bubbles (error banners,
  /// optimistic user messages, system notices) *just after* the
  /// already-rendered timeline so any future daemon event with a
  /// greater seq naturally sorts below them instead of teleporting
  /// above (the root cause of "new messages appear on top of the
  /// error bubble"). Zero when the caller didn't know the seq.
  final int _anchorSeq;

  /// Small monotonic counter assigned at construction — used as a
  /// tiebreaker between multiple local-only bubbles anchored to the
  /// same [_anchorSeq], so that their order of insertion is
  /// preserved. Stays in `[1, _seqScale)` so it never bleeds into
  /// the next seq slot.
  final int _provisionalKey;

  /// Multiplier that splits the sort-key integer into two axes:
  /// the high bits are the daemon-seq space, the low bits are the
  /// local-tick tiebreaker. One million local ticks per seq is
  /// plenty — a single turn generates a handful of local bubbles.
  static const int _seqScale = 1000000;

  /// Authoritative sort key. When the bubble has a daemon seq it
  /// occupies that seq's slot exactly (`seq * _seqScale`). While
  /// provisional, it sits *between* its anchor seq and the next
  /// real seq via the low-bits tiebreaker, so subsequent daemon
  /// events with a higher seq always render below it instead of
  /// above. The getter is cheap so it's safe to call every frame
  /// during sort.
  int get sortKey {
    final base = _daemonSeq ?? _anchorSeq;
    final tick = _daemonSeq != null ? 0 : _provisionalKey;
    return base * _seqScale + tick;
  }

  /// Server-assigned correlation id for the turn this bubble belongs
  /// to (fast-path `fp-...` or queue row id). Null until the POST
  /// response or the first `user_message`/`message_started` event
  /// brings it in.
  String? correlationId;

  /// Client-generated idempotency key passed to
  /// `POST /sessions/{sid}/messages` so the daemon's echoed
  /// `user_message` event can reconcile with the optimistic bubble
  /// without content guessing.
  String? clientMessageId;

  /// True while the user turn is accepted by the daemon but not yet
  /// picked by the agent loop (`user_message` with `pending: true`).
  /// Cleared on `message_started`. UIs render pending bubbles with a
  /// dimmed style so the user sees the message is queued — without
  /// having to cross-reference the queue chip.
  bool _pending = false;
  bool get pending => _pending;
  set pending(bool v) {
    if (_pending == v) return;
    _pending = v;
    notifyListeners();
  }

  /// Pin this bubble to the daemon's authoritative seq. Once set the
  /// [sortKey] switches from the optimistic provisional tick to the
  /// real seq — callers should re-sort their message list after this
  /// runs so the bubble slots into its canonical position.
  ///
  /// Daemon seqs only ever increase, so the "move" is bounded: the
  /// bubble can only slide from the tail (provisional tick sits
  /// above every seq) to its seq slot. It never jumps past a peer
  /// that already has a seq, because peer seqs are also fixed.
  void updateSortKey(int seq) {
    if (seq <= 0) return;
    if (_daemonSeq == seq) return;
    _daemonSeq = seq;
    notifyListeners();
  }

  // ── Chronological timeline of content blocks ────────────────────────────────
  final List<ContentBlock> _timeline = [];
  List<ContentBlock> get timeline => _timeline;

  // ── Computed getters (backward compatible) ──────────────────────────────────

  /// Full concatenated text from all text blocks, with paragraph
  /// separation preserved.
  ///
  /// When the timeline interleaves text with tool calls or thinking
  /// blocks, each text block is rendered as its own [MarkdownBody]
  /// (visually separated by the surrounding non-text widgets). For the
  /// copy / paste / external use cases that flatten the timeline back
  /// to a single string, we re-introduce a paragraph break (`\n\n`)
  /// between every non-empty text block so the result reads naturally
  /// instead of looking glued together (`"Before toolAfter tool"`).
  ///
  /// Each block is `trimRight`-ed before joining so a block already
  /// ending with newlines doesn't blow up to `\n\n\n\n` after joining.
  String get text {
    final parts = <String>[];
    for (final b in _timeline) {
      if (b.type == ContentBlockType.text && b.textContent.isNotEmpty) {
        parts.add(b.textContent.trimRight());
      }
    }
    return parts.join('\n\n');
  }

  /// All thinking text concatenated. Same logic as [text]: blocks are
  /// joined with a paragraph break so successive thinking sections
  /// stay readable.
  String get thinkingText {
    final parts = <String>[];
    for (final b in _timeline) {
      if (b.type == ContentBlockType.thinking && b.textContent.isNotEmpty) {
        parts.add(b.textContent.trimRight());
      }
    }
    return parts.join('\n\n');
  }

  bool get isThinking =>
      _timeline.any((b) => b.type == ContentBlockType.thinking && b.thinkingActive);

  // Streaming
  bool _isStreaming = false;
  bool get isStreaming => _isStreaming;

  /// All tool calls in order
  List<ToolCall> get toolCalls => _timeline
      .where((b) => b.type == ContentBlockType.toolCall && b.toolCall != null)
      .map((b) => b.toolCall!)
      .toList();

  /// True when the message contains at least one tool call still in
  /// `started` state. Used by the reconnect reconciler to detect
  /// tool spinners that will never complete (e.g. daemon crashed
  /// between `tool_start` and `tool_call`).
  bool get hasOpenToolStart =>
      toolCalls.any((t) => t.status == 'started');

  /// Flip every `started` tool call to `failed` with an
  /// "interrupted" error string. Called by the reconnect reconciler
  /// when the daemon says no turn is running but we still have a
  /// dangling tool_start.
  void markToolStartsInterrupted() {
    var changed = false;
    for (final t in toolCalls) {
      if (t.status == 'started') {
        t.status = 'failed';
        t.error ??= 'Interrupted — connection dropped before the tool '
            'could complete.';
        t.completedAt ??= DateTime.now();
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// All agent events in order
  List<AgentEventData> get agentEvents => _timeline
      .where((b) => b.type == ContentBlockType.agentEvent && b.agentEvent != null)
      .map((b) => b.agentEvent!)
      .toList();

  /// All hook events in order
  List<HookEventData> get hookEvents => _timeline
      .where((b) => b.type == ContentBlockType.hookEvent && b.hookEvent != null)
      .map((b) => b.hookEvent!)
      .toList();

  // Token counts
  int _outTokens = 0;
  int get outTokens => _outTokens;
  int _inTokens = 0;
  int get inTokens => _inTokens;

  ChatMessage({
    required this.id,
    required this.role,
    String initialText = '',
    DateTime? timestamp,
    int? daemonSeq,
    int anchorSeq = 0,
    this.correlationId,
    this.clientMessageId,
  })  : createdAt = timestamp ?? DateTime.now(),
        _daemonSeq = (daemonSeq != null && daemonSeq > 0) ? daemonSeq : null,
        _anchorSeq = anchorSeq > 0 ? anchorSeq : 0,
        _provisionalKey = _nextProvisional() {
    if (initialText.isNotEmpty) {
      _timeline.add(ContentBlock.text(initialText));
    }
  }

  /// Legacy alias — "is this bubble still waiting for a daemon
  /// echo?". Prefer `daemonSeq == null` at call sites; kept for
  /// backward-compat with existing tests that compare against the
  /// old integer threshold.
  static const int sentinelThreshold = 1 << 30;

  /// Monotonic per-process counter used as the local-tick tiebreaker
  /// between bubbles anchored to the same seq. Starts at 1 so we
  /// never produce sortKey == seq*scale (which would collide with
  /// the authoritative seq slot). Wraps inside [_seqScale] so two
  /// real seqs always contain a clean space for their local bubbles.
  static int _localCounter = 0;
  static int _nextProvisional() {
    _localCounter = (_localCounter + 1) % (_seqScale - 1);
    return _localCounter + 1;
  }

  // ─── Mutations ─────────────────────────────────────────────────────────────

  /// Append text delta. If the last block in the timeline is a text block,
  /// append to it directly. Otherwise, create a new text block.
  /// LLM tokens already include correct spacing — no smart spacing needed.
  void appendText(String delta) {
    if (delta.isEmpty) return;

    if (_timeline.isNotEmpty && _timeline.last.type == ContentBlockType.text) {
      // Append to existing trailing text block
      _timeline.last.textContent += delta;
    } else {
      // New text block after a non-text block (tool call, thinking, etc.)
      // The MarkdownBody handles each block separately, so no separator needed here
      _timeline.add(ContentBlock.text(delta));
    }
    notifyListeners();
  }

  /// Replace the trailing text block with [content] wholesale.
  /// Used by `assistant_stream_snapshot` at mid-turn rejoin: the
  /// daemon sends the full accumulated text streamed so far (NOT a
  /// delta), and we mirror it on the existing bubble so the user
  /// sees the partial response without waiting for fresh tokens.
  ///
  /// Non-text blocks (tool calls, thinking, agent events, widgets)
  /// are preserved as-is — only the trailing text segment is
  /// replaced so the snapshot doesn't wipe out structured blocks
  /// that already landed.
  void replaceText(String content) {
    for (int i = _timeline.length - 1; i >= 0; i--) {
      if (_timeline[i].type == ContentBlockType.text) {
        if (content.isEmpty) {
          _timeline.removeAt(i);
        } else {
          _timeline[i].textContent = content;
        }
        notifyListeners();
        return;
      }
    }
    if (content.isNotEmpty) {
      _timeline.add(ContentBlock.text(content));
      notifyListeners();
    }
  }

  /// Flip every thinking block except [keepActive] to inactive. Used
  /// when a new iteration starts — the daemon doesn't always emit a
  /// `stream_done` between reasoning steps, so the client has to
  /// infer that the prior thinking is done the moment a new block
  /// is born. Without this the UI keeps old blocks rendered as
  /// "active" and auto-opens every one of them on each new iteration.
  void _freezePriorThinking(ContentBlock keepActive) {
    for (final b in _timeline) {
      if (b.type == ContentBlockType.thinking && !identical(b, keepActive)) {
        b.thinkingActive = false;
      }
    }
  }

  /// Append streamed `thinking_delta` text. Reuses the current
  /// thinking block ONLY when it is the last item in the timeline
  /// AND is still marked active — i.e. the agent is still in the
  /// same reasoning step. If a tool_call, text, or any other block
  /// landed after the previous thinking (OR a `stream_done` flipped
  /// it to inactive), this starts a new thinking block at the end
  /// AND freezes every earlier thinking block to inactive so they
  /// render as "done" instead of "live".
  void appendThinking(String delta) {
    final last = _timeline.isNotEmpty ? _timeline.last : null;
    final continueExisting = last != null &&
        last.type == ContentBlockType.thinking &&
        last.thinkingActive;
    final ContentBlock block;
    if (continueExisting) {
      block = last;
    } else {
      block = ContentBlock.thinking(active: true);
      _timeline.add(block);
      _freezePriorThinking(block);
    }
    block.textContent += delta;
    notifyListeners();
  }

  /// Set the per-block cumulative thinking-token count from the
  /// daemon's `thinking_delta`/`thinking` event `payload.count`.
  /// Lands on the same block currently being filled by
  /// [appendThinking]/[setThinkingText] — never accumulates across
  /// blocks, never includes text-response tokens. Monotonically
  /// increasing — drops are ignored. If no active thinking block
  /// exists yet, the count is silently buffered onto a fresh block
  /// created right now (so the very first thinking_delta of a turn
  /// still gets a place to land before any text or thinking-final
  /// event has materialized one).
  void setActiveThinkingTokens(int count) {
    if (count <= 0) return;
    ContentBlock? target;
    for (final b in _timeline.reversed) {
      if (b.type == ContentBlockType.thinking && b.thinkingActive) {
        target = b;
        break;
      }
    }
    if (target == null) {
      target = ContentBlock.thinking(active: true);
      _timeline.add(target);
      _freezePriorThinking(target);
    }
    if (count <= target.thinkingTokens) return;
    target.thinkingTokens = count;
    notifyListeners();
  }

  /// Upsert a `toolCallStreaming` placeholder block (one per
  /// `callId`). Each `tool_call_streaming` SSE event from the daemon
  /// updates the same block via callId; the count is monotonically
  /// rising (litellm-tokenized server-side, never goes down). When
  /// the real `tool_start` arrives, [removeToolCallStreaming] swaps
  /// the placeholder for the real toolCall block.
  ///
  /// Reuses the existing [ContentBlock.thinkingTokens] field as the
  /// count storage to avoid adding a third token-count field — it's
  /// per-block and never mixed with thinking-blocks (different
  /// `type`).
  void upsertToolCallStreaming({
    required String callId,
    required String toolName,
    required int tokenCount,
  }) {
    if (callId.isEmpty) return;
    ContentBlock? target;
    for (var i = _timeline.length - 1; i >= 0; i--) {
      final b = _timeline[i];
      if (b.type == ContentBlockType.toolCallStreaming &&
          b.streamingCallId == callId) {
        target = b;
        break;
      }
    }
    if (target == null) {
      target = ContentBlock.toolCallStreaming(
        callId: callId,
        toolName: toolName,
      );
      _timeline.add(target);
    } else if (toolName.isNotEmpty &&
        (target.streamingToolName == null ||
            target.streamingToolName!.isEmpty)) {
      target.streamingToolName = toolName;
    }
    if (tokenCount > target.thinkingTokens) {
      target.thinkingTokens = tokenCount;
    }
    notifyListeners();
  }

  /// Drop the placeholder for a given callId. Called when the real
  /// `tool_start` event arrives — the proper tool card takes over.
  void removeToolCallStreaming(String callId) {
    if (callId.isEmpty) return;
    final before = _timeline.length;
    _timeline.removeWhere((b) =>
        b.type == ContentBlockType.toolCallStreaming &&
        b.streamingCallId == callId);
    if (_timeline.length != before) notifyListeners();
  }

  /// Replace the streaming placeholder for a given callId with the
  /// real toolCall block — atomically and in-place. Keeps the same
  /// timeline index so the UI doesn't jump when the chip swaps to
  /// the full card. Falls back to [addOrUpdateToolCall] (append) if
  /// no placeholder is found (e.g. the chip was filtered or never
  /// shown for this call).
  void replaceToolCallStreamingWithCall(ToolCall call) {
    final id = call.id;
    if (id.isEmpty) {
      addOrUpdateToolCall(call);
      return;
    }
    final idx = _timeline.indexWhere((b) =>
        b.type == ContentBlockType.toolCallStreaming &&
        b.streamingCallId == id);
    if (idx < 0) {
      addOrUpdateToolCall(call);
      return;
    }
    _timeline[idx] = ContentBlock.tool(call);
    notifyListeners();
  }

  /// Open a brand-new active thinking block at the end of the
  /// timeline, freezing every previous thinking block. Called on
  /// every `thinking_started` SSE event so multi-block turns (think →
  /// tool → think → tool → ...) get distinct, independently-counted
  /// thinking sections. Does nothing if the timeline already ends
  /// with an active thinking block (idempotent — duplicate
  /// `thinking_started` from a noisy provider doesn't multiply
  /// blocks).
  void beginThinkingBlock() {
    final last = _timeline.isNotEmpty ? _timeline.last : null;
    if (last != null &&
        last.type == ContentBlockType.thinking &&
        last.thinkingActive &&
        last.textContent.isEmpty &&
        last.thinkingTokens == 0) {
      return; // empty block already open — reuse it
    }
    final block = ContentBlock.thinking(active: true);
    _timeline.add(block);
    _freezePriorThinking(block);
    notifyListeners();
  }

  /// Apply a `thinking` snapshot (full text for the current reasoning
  /// step). Same rule as [appendThinking] — reuse the tail block only
  /// when it is itself an ACTIVE thinking block; otherwise open a new
  /// one so the snapshot lands in chronological order, AFTER the tool
  /// call or stream_done that closed the previous reasoning step.
  void setThinkingText(String text) {
    final last = _timeline.isNotEmpty ? _timeline.last : null;
    final continueExisting = last != null &&
        last.type == ContentBlockType.thinking &&
        last.thinkingActive;
    if (continueExisting) {
      last.textContent = text;
    } else {
      final block = ContentBlock.thinking(text: text, active: true);
      _timeline.add(block);
      _freezePriorThinking(block);
    }
    notifyListeners();
  }

  /// Retroactively strip a duplicated response block from the
  /// thinking text. Some daemon agents (scout-confirmed: the
  /// `digitorn-builder` coordinator) emit a final `thinking` snapshot
  /// that concatenates the response text directly onto the chain of
  /// thought — no newline, no separator, resulting in a fused blob
  /// like `"…offre d'aide.Bonjour ! 😊"` in the thinking block.
  ///
  /// Once `result.content` lands cleanly we know exactly what the
  /// response is — if that string is a contiguous suffix of our
  /// thinking buffer (or a long-enough prefix match to survive mid
  /// sentence truncation), we excise it. No-op when the thinking
  /// doesn't contain the response, so apps whose daemon already
  /// separates the two cleanly aren't affected.
  void stripThinkingOverlap(String response) {
    if (response.isEmpty) return;
    final block = _timeline.lastWhereOrNull(
      (b) => b.type == ContentBlockType.thinking,
    );
    if (block == null) return;
    final thinking = block.textContent;
    if (thinking.isEmpty) return;
    // Strategy 1 — full-response substring match.
    final idx = thinking.indexOf(response);
    if (idx >= 0) {
      block.textContent = thinking.substring(0, idx).trimRight();
      notifyListeners();
      return;
    }
    // Strategy 2 — progressive prefix match, in case the thinking
    // snapshot was truncated before the last few chars of the
    // response (scout showed "Que souhaitez-vous" in thinking vs
    // "Que souhaitez-vous faire ?" in result). Walk back from the
    // full response length in 10-char steps, stop at a prefix ≥ 60
    // chars, and require the match to sit in the tail third of the
    // thinking so we don't accidentally excise the middle of a
    // legitimate reasoning sentence.
    final minLen = 60;
    for (var len = response.length - 10; len >= minLen; len -= 10) {
      final prefix = response.substring(0, len);
      final pos = thinking.lastIndexOf(prefix);
      if (pos >= (thinking.length * 2) ~/ 3) {
        block.textContent = thinking.substring(0, pos).trimRight();
        notifyListeners();
        return;
      }
    }
  }

  /// [state]=true toggles ONLY the last (most recent) thinking block
  /// to active — previous thoughts from the same turn stay frozen so
  /// they don't re-trigger the UI's "this became live, auto-open me"
  /// logic. When no thinking block exists yet, creates one.
  ///
  /// [state]=false runs wholesale across every thinking block — it's
  /// the end-of-streaming marker (stream_done, turn_complete, abort)
  /// and all thoughts should read as final.
  void setThinkingState(bool state) {
    if (state) {
      ContentBlock? last;
      for (final b in _timeline.reversed) {
        if (b.type == ContentBlockType.thinking) {
          last = b;
          break;
        }
      }
      if (last != null) {
        last.thinkingActive = true;
      } else {
        _timeline.add(ContentBlock.thinking(active: true));
      }
    } else {
      for (final b in _timeline) {
        if (b.type == ContentBlockType.thinking) {
          b.thinkingActive = false;
        }
      }
    }
    notifyListeners();
  }

  void setStreamingState(bool state) {
    _isStreaming = state;
    notifyListeners();
  }

  /// Merge an incoming ToolCall update with the existing block for
  /// the same id. Preserves non-empty fields from the previous copy
  /// (so `tool_start`'s label/detail/params aren't clobbered by a
  /// later `tool_call` that doesn't re-send them) and refuses to
  /// regress the status (completed/failed never drop back to started
  /// even if events arrive out of order).
  void addOrUpdateToolCall(ToolCall call) {
    // First check for a streaming placeholder with this call_id —
    // if found, swap it in-place. Keeps the same timeline index so
    // the chip → real card transition has zero visual jump.
    final streamingIdx = _timeline.indexWhere((b) =>
        b.type == ContentBlockType.toolCallStreaming &&
        b.streamingCallId == call.id);
    if (streamingIdx >= 0) {
      _timeline[streamingIdx] = ContentBlock.tool(call);
      notifyListeners();
      return;
    }
    final i = _timeline.indexWhere(
      (b) =>
          b.type == ContentBlockType.toolCall &&
          b.toolCall != null &&
          b.toolCall!.id == call.id,
    );
    if (i == -1) {
      _timeline.add(ContentBlock.tool(call));
      notifyListeners();
      return;
    }
    final prev = _timeline[i].toolCall!;

    // Status precedence — higher wins and sticks.
    int rank(String s) => switch (s) {
          'failed' => 3,
          'completed' => 2,
          'started' => 1,
          _ => 0,
        };
    final newStatus =
        rank(call.status) >= rank(prev.status) ? call.status : prev.status;

    String pickString(String incoming, String existing) =>
        incoming.isNotEmpty ? incoming : existing;

    T? pickNullable<T>(T? incoming, T? existing) => incoming ?? existing;

    Map<String, dynamic> pickParams(
        Map<String, dynamic> incoming, Map<String, dynamic> existing) {
      if (incoming.isEmpty) return existing;
      if (existing.isEmpty) return incoming;
      return {...existing, ...incoming};
    }

    _timeline[i].toolCall = ToolCall(
      id: prev.id,
      name: pickString(call.name, prev.name),
      label: pickString(call.label, prev.label),
      detail: pickString(call.detail, prev.detail),
      detailParam: pickString(call.detailParam, prev.detailParam),
      icon: pickString(call.icon, prev.icon),
      channel: pickString(call.channel, prev.channel),
      category: pickString(call.category, prev.category),
      group: pickString(call.group, prev.group),
      // `hidden` is sticky-once-true: if either event marked the
      // call hidden, keep it hidden. Daemons that forget the flag
      // on a later event shouldn't revive an already-hidden bubble.
      hidden: call.hidden || prev.hidden,
      visibleParams: call.visibleParams ?? prev.visibleParams,
      params: pickParams(call.params, prev.params),
      status: newStatus,
      result: call.result ?? prev.result,
      error: pickNullable(call.error, prev.error),
      previousContent: pickNullable(call.previousContent, prev.previousContent),
      newContent: pickNullable(call.newContent, prev.newContent),
      output: pickNullable(call.output, prev.output),
      metadata: call.metadata ?? prev.metadata,
      diff: pickNullable(call.diff, prev.diff),
      unifiedDiff: pickNullable(call.unifiedDiff, prev.unifiedDiff),
      imageData: pickNullable(call.imageData, prev.imageData),
      imageMime: pickNullable(call.imageMime, prev.imageMime),
      // Preserve the earlier startedAt (set on tool_start) and the
      // later completedAt (set on tool_call). Merges never clobber
      // a known value with null.
      startedAt: prev.startedAt ?? call.startedAt,
      completedAt: call.completedAt ?? prev.completedAt,
    );
    notifyListeners();
  }

  /// Append an inline widget to the timeline, or update an existing
  /// one in place when the daemon re-sends the same widget_id (used
  /// for `widget:render` updates). Notifies listeners so the chat
  /// bubble rebuilds.
  void addOrUpdateWidget(InlineWidgetPayload payload) {
    final i = _timeline.indexWhere(
      (b) =>
          b.type == ContentBlockType.widget &&
          b.widget?.widgetId == payload.widgetId,
    );
    if (i != -1) {
      _timeline[i].widget = payload;
    } else {
      _timeline.add(ContentBlock.widget(payload));
    }
    notifyListeners();
  }

  /// Remove an inline widget by id. Called when a `widget:close`
  /// event arrives. No-op if no block matches.
  void removeWidget(String widgetId) {
    final before = _timeline.length;
    _timeline.removeWhere(
      (b) => b.type == ContentBlockType.widget && b.widget?.widgetId == widgetId,
    );
    if (_timeline.length != before) notifyListeners();
  }

  void addAgentEvent(AgentEventData event) {
    // Replace if same agentId exists
    final i = _timeline.indexWhere(
      (b) =>
          b.type == ContentBlockType.agentEvent &&
          b.agentEvent != null &&
          b.agentEvent!.agentId == event.agentId,
    );
    if (i != -1) {
      _timeline[i].agentEvent = event;
    } else {
      _timeline.add(ContentBlock.agent(event));
    }
    notifyListeners();
  }

  void addHookEvent(HookEventData event) {
    _timeline.add(ContentBlock.hook(event));
    notifyListeners();
  }

  void addTokens({int out = 0, int inT = 0}) {
    _outTokens += out;
    if (inT > 0) _inTokens = inT;
    notifyListeners();
  }

  /// Set the cumulative completion-token count from the daemon's
  /// streaming `token` event payload. Monotonically increasing — the
  /// daemon may emit the same value for several deltas in a row before
  /// the next litellm tick advances it. Only fires `notifyListeners`
  /// when the value actually changes, to avoid useless rebuilds.
  void setOutTokensCumulative(int count) {
    if (count <= _outTokens) return;
    _outTokens = count;
    notifyListeners();
  }

}

// ── Extension for lastWhereOrNull ────────────────────────────────────────────
extension _ListExt<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (int i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
