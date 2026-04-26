import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../models/approval_request.dart';
import '../../models/chat_message.dart';
import '../../models/app_manifest.dart';
import '../../models/app_summary.dart';
import '../../models/queue_entry.dart';
import '../../services/api_client.dart';
import '../../services/queue_service.dart';
import '../../services/session_service.dart';
import '../../services/session_state_controller.dart';
import '../../services/recent_attachments_service.dart';
import '../../services/background_service.dart';
import '../../services/voice_input_service.dart';
import '../../services/workspace_snapshot_service.dart';
import '../../widgets_v1/models.dart' as widgets_models;
import '../../widgets_v1/service.dart' as widgets_service;
import '../../services/workspace_service.dart';
import '../../services/database_service.dart';
import '../../models/workspace_state.dart';
import '../../models/session_metrics.dart';
import '../../main.dart';
import 'chat_bubbles.dart';
import 'chat_panel_logic.dart' as logic;
import 'chat_timeline.dart';
import 'recording_overlay.dart';
import '../../models/credential_v2.dart';
import '../credentials/credential_gate.dart';
import '../credentials_v2/credential_picker_dialog.dart';
import 'context_modal.dart';
import 'smart_paste.dart';
import 'snippets_picker.dart';
import 'tools_modal.dart';
import 'tasks_modal.dart';
import 'slash_commands.dart';
import '../../services/notification_service.dart';
import '../../services/preview_store.dart';
import '../../services/workspace_module.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../theme/app_theme.dart';
import 'artifacts/artifact_detector.dart';
import 'artifacts/artifact_panel.dart';
import 'artifacts/artifact_service.dart';
import 'widgets/chat_empty_state.dart';
import '../workspace/workspace_picker.dart';
import 'chat_attach_bridge.dart';
import 'chat_export_bridge.dart';
import 'attach/attach_menu.dart';
import 'attach/attachments_bar.dart' as attach_bar;
import 'attach/attachment_helpers.dart' as attach_helpers;

// ─── Color tokens ────────────────────────────────────────────────────────────
// All colors now come from context.colors (AppColors theme extension).

// ─── Cached GoogleFonts styles ───────────────────────────────────────────────
// GoogleFonts.x() allocates a new TextStyle on every call. These singletons
// avoid GC pressure during AI streaming where the build() runs many times/sec.
// Color-dependent variants are NOT cached here (use copyWith for color).
final _kFiraCode11 = GoogleFonts.firaCode(fontSize: 11);
final _kInter125 = GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w500);
final _kInter11 = GoogleFonts.inter(fontSize: 11);

class DaemonError {
  final String error;
  final String code;
  final String category;
  final bool retry;
  final String? detail;

  const DaemonError({
    required this.error,
    this.code = 'internal_error',
    this.category = 'internal',
    this.retry = true,
    this.detail,
  });

  factory DaemonError.fromJson(Map<String, dynamic> j) => DaemonError(
    error: j['error'] as String? ?? 'Unknown error',
    code: j['code'] as String? ?? 'internal_error',
    category: j['category'] as String? ?? 'internal',
    retry: j['retry'] as bool? ?? true,
    detail: j['detail'] as String?,
  );
}

// ApprovalRequest moved to lib/models/approval_request.dart — imported
// at the top of this file — so the chat bubble renderer can reference
// it without a circular dep back into this panel.

/// Buffered copy of a `user_message` event received with
/// `pending: true` and no matching optimistic bubble. Held in
/// [_ChatPanelState._queuedUserMessages] until the daemon actually
/// starts the turn (`message_started` for the same correlation_id)
/// at which point we create the chat bubble. Keeping this off the
/// [ChatMessage] model means the chat timeline is never polluted
/// with pending-queue entries.
class _QueuedUserMessage {
  final String content;
  final String? clientMessageId;
  const _QueuedUserMessage({
    required this.content,
    required this.clientMessageId,
  });
}

/// Thin `List<ChatMessage>` adapter that routes every mutation through
/// a [ChatTimeline]. Reads return the timeline's sorted view; writes
/// call the matching timeline mutation. The class exists so the large
/// body of code in [_ChatPanelState] can keep using `_messages.add(m)`
/// / `_messages.clear()` / `_messages.remove(m)` / `_messages[i]` /
/// `_messages.length` exactly as before — without any call site ever
/// being able to violate the ordering invariant.
///
/// Mutations whose semantics don't map cleanly to an ordered index
/// (positional `insert(i, m)`, `[i] = m`) are forwarded to `upsert`:
/// the timeline picks the position, not the caller. Positional
/// assignment to a specific slot isn't meaningful under a (seq,
/// tick) ordering.
class _TimelineBackedMessageList with ListMixin<ChatMessage> {
  final ChatTimeline _t;
  _TimelineBackedMessageList(this._t);

  /// Integer ordering key for a [ChatMessage]. Uses the model's
  /// authoritative `sortKey`, which is already `seq*_seqScale + tick`
  /// — the exact scheme the pre-timeline code sorted on. Every
  /// bubble — daemon-originated or local-only — therefore lives in
  /// the same number range:
  ///
  ///   * daemon bubble, seq=100  → sortKey = 100 * 1e6          = 100_000_000
  ///   * local bubble,  anchor=100, tick=7 → sortKey = 100_000_007
  ///   * daemon bubble, seq=101  → sortKey = 101 * 1e6          = 101_000_000
  ///
  /// so the local bubble correctly slots between the two daemon
  /// bubbles instead of being pinned to a disjoint sentinel space.
  ///
  /// When a bubble has no daemon seq AND no anchor (sortKey falls
  /// to `provisional_tick` only, a small number) we return `null` so
  /// it lands at the timeline's tail sentinel — this matches test
  /// fixtures that create bare ChatMessages without context.
  static int? _keyOf(ChatMessage m) {
    final sk = m.sortKey;
    // sortKey < _seqScale means "no daemonSeq and no anchor" — treat
    // as optimistic tail. _seqScale = 1_000_000 in the model.
    return sk >= 1000000 ? sk : null;
  }

  @override
  int get length => _t.length;

  /// Only length==0 is honoured (maps to `clear`). Growing or shrinking
  /// to a non-zero length is unsupported because positions are owned
  /// by the timeline, not the caller.
  @override
  set length(int newLength) {
    if (newLength == 0) {
      // DEBUG: identify every code path that wipes the transcript.
      // Keep this on until the ghost-clear bug is nailed down.
      debugPrint(
          '[CLEAR] _messages cleared from:\n${StackTrace.current}');
      _t.clear();
      return;
    }
    throw UnsupportedError(
      'ChatTimeline-backed list: set length to 0 (clear) or use upsert/removeById',
    );
  }

  @override
  ChatMessage operator [](int index) => _t.messages[index];

  @override
  void operator []=(int index, ChatMessage value) {
    // Re-upsert: the timeline will replace by id and re-sort.
    _t.upsert(value, seq: _keyOf(value));
  }

  @override
  void add(ChatMessage value) {
    _t.upsert(value, seq: _keyOf(value));
  }

  @override
  void addAll(Iterable<ChatMessage> iterable) {
    for (final v in iterable) {
      _t.upsert(v, seq: _keyOf(v));
    }
  }

  @override
  bool remove(Object? value) {
    if (value is! ChatMessage) return false;
    if (_t.byId(value.id) == null) return false;
    _t.removeById(value.id);
    return true;
  }

  @override
  void removeWhere(bool Function(ChatMessage) test) {
    final ids = <String>[];
    for (final m in _t.messages) {
      if (test(m)) ids.add(m.id);
    }
    for (final id in ids) {
      _t.removeById(id);
    }
  }

  @override
  void retainWhere(bool Function(ChatMessage) test) {
    removeWhere((m) => !test(m));
  }

  @override
  ChatMessage removeAt(int index) {
    final m = _t.messages[index];
    _t.removeById(m.id);
    return m;
  }

  @override
  ChatMessage removeLast() {
    final m = _t.messages.last;
    _t.removeById(m.id);
    return m;
  }

  @override
  void removeRange(int start, int end) {
    final snap = _t.messages.sublist(start, end).map((m) => m.id).toList();
    for (final id in snap) {
      _t.removeById(id);
    }
  }

  @override
  void clear() {
    // DEBUG: identify every call to _messages.clear() during the
    // investigation of the "session flashes then reverts to empty"
    // bug. Remove once fixed.
    debugPrint('[CLEAR] _messages.clear() from:\n${StackTrace.current}');
    _t.clear();
  }

  @override
  void insert(int index, ChatMessage value) {
    _t.upsert(value, seq: _keyOf(value));
  }

  @override
  void insertAll(int index, Iterable<ChatMessage> iterable) {
    for (final v in iterable) {
      _t.upsert(v, seq: _keyOf(v));
    }
  }

  @override
  void sort([int Function(ChatMessage, ChatMessage)? compare]) {
    // No-op: the timeline is sorted by (seq, insertion-tick) at all
    // times by construction. Any caller calling `.sort` is historical.
  }
}

class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key});
  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final TextEditingController _ctrl = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  /// Single source of truth for chat bubble ordering. The timeline
  /// enforces the invariant "bubbles are always rendered in (seq,
  /// insertion-tick) order" by construction — no call site can
  /// violate it, because the backing `_messages` list below is a
  /// thin adapter that routes every mutation through `_timeline`.
  ///
  /// The daemon's `seq` on each event is the SOLE ordering authority
  /// (§0 of the event spec). Optimistic bubbles that haven't been
  /// echoed yet sit at the tail via a sentinel seq and get re-pinned
  /// to their canonical seq on the first daemon echo. On session
  /// switch or reconnect-backfill, the timeline is cleared and
  /// reseeded from `/history`; the insertion order is the server's
  /// canonical order.
  final ChatTimeline _timeline = ChatTimeline();
  late final _TimelineBackedMessageList _messages =
      _TimelineBackedMessageList(_timeline);
  final Map<String, GlobalKey> _messageKeys = {};
  final List<ApprovalRequest> _pendingApprovals = [];
  // Message-id -> approval request-id mapping. Populated when an
  // `approval_request` event creates its inline system marker so the
  // list item builder can render the interactive ``_ApprovalBanner``
  // in-flow (pinned to the marker's seq) instead of as a banner stuck
  // to the bottom of the pane. On resolve/timeout the request drops
  // out of ``_pendingApprovals`` and the builder falls back to the
  // plain text marker — the "Approval requested: …" / "Approval
  // granted|denied" pair reads naturally in history.
  final Map<String, String> _approvalMarkerReqId = {};

  StreamSubscription? _eventSub;
  StreamSubscription? _sessionChangeSub;
  StreamSubscription? _widgetChatSub;
  StreamSubscription? _widgetEventSub;
  ChatMessage? _currentMsg;
  bool _isSending = false;
  bool _hadTokens = false; // Track if any tokens were streamed this turn
  // Id of the in-progress compaction marker (set on ``compact_context:start``,
  // cleared when its matching ``:end`` upgrades the line to the final text).
  String? _pendingCompactionBubbleId;
  // Simple "agent is preparing the response" flag. Set to true the
  // moment the user hits Send on a non-queued message, set to false
  // the instant the agent shows ANY sign of responding (first token,
  // first thinking, first tool, error, done). Renders a dedicated
  // 3-bar skeleton ABOVE the input bar — independent of the bubble
  // machinery, so it can't get lost in a ghost-bubble race.
  bool _awaitingAgentResponse = false;
  Timer? _responseTimeout;
  DaemonError? _activeError;

  /// Strict spinner gate — used by the send-button ring instead of
  /// `_isSending` alone. The flag was set optimistically on send and
  /// cleared on the terminal event; an out-of-order `message_started`
  /// (socket reconnect, late event) could re-flip it `true` AFTER
  /// the terminal event landed and leave the ring spinning forever.
  ///
  /// The robust check: a turn is REALLY running iff
  ///   1. `_isSending` is true (intent to be in-flight) AND
  ///   2. either we're still waiting for the very first event
  ///      (`_awaitingAgentResponse`), OR at least one assistant
  ///      message is `isStreaming`, OR at least one tool call is in
  ///      the `started` state.
  ///
  /// If `_isSending` is true but none of the in-flight conditions
  /// hold, the spinner is OFF — the flag is ignored, period.
  ///
  /// Connection / error gates kill the spinner regardless of
  /// `_isSending`. The flag stays true semantically (the intent to
  /// be in-flight is preserved across a transient disconnect — the
  /// daemon may still finish the turn and replay events on reconnect)
  /// but the VISUAL spinner is off so the user doesn't see a UI
  /// element animating against a dead connection. Mirror of the
  /// typing-skeleton's gates on the trailing dots row.
  bool get _turnReallyRunning {
    if (!_isSending) return false;
    if (_statusPhase == 'disconnected') return false;
    if (_statusPhase == 'aborting') return false;
    if (_isInterrupted) return false;
    if (_activeError != null) return false;
    if (_awaitingAgentResponse) return true;
    for (final m in _messages) {
      if (m.role != MessageRole.assistant) continue;
      if (m.isStreaming) return true;
      if (m.hasOpenToolStart) return true;
    }
    return false;
  }
  String _lastUserText = '';
  int _credentialRetryCount = 0;
  String _credentialRetryKey = '';
  bool _showContextPanel = false;
  bool _showToolsPanel = false;
  bool _showTasksPanel = false;
  bool _showSnippetsPanel = false;
  bool _showScrollDown = false;
  List<SlashCommand> _slashCommands = []; // Slash command menu
  final List<({String name, String path, bool isImage})> _attachments = [];

  /// True while the user is dragging a file over the chat panel.
  /// Drives the "Drop to attach" overlay rendered on top of the
  /// composer & messages.
  bool _isDragOver = false;

  /// Snapshot of the composer text taken the moment voice recording
  /// starts. If recording / transcription fails, we roll the
  /// composer back to this value so leaked partial transcripts don't
  /// stick around waiting to be sent.
  String? _preDictateText;
  VoiceState _lastVoiceState = VoiceState.idle;

  // Local token counters removed — context display uses ContextState only.

  // Daemon status phase (e.g. 'planning', 'executing', 'done')
  String _statusPhase = '';
  // Heartbeat indicator removed together with the old spinner bar.

  // Track current session to detect switches
  String? _currentSessionId;

  /// Scrollbar is visible only while the user is actively engaging
  /// with the chat (hovered mouse, pointer down, or recent wheel).
  /// False during agent streaming if the user is looking elsewhere,
  /// which avoids the distracting thumb flash on every auto-scroll.
  /// Cleared to false 1.5 s after the last interaction.
  bool _scrollbarEngaged = false;
  Timer? _scrollbarIdleTimer;

  /// When non-null the next Send will overwrite the referenced tail
  /// queue entry via `queue_mode=replace_last` rather than enqueuing
  /// a fresh one. Set by the Edit action in [_QueuePanel].
  QueueEntry? _pendingReplaceLast;

  /// Highest `seq` we've seen on a persisted event in this session.
  /// Agent bubbles created from ephemeral streams (tokens) seed
  /// their provisional seq from this value so they sit right after
  /// the preceding daemon event; once the matching `message_started`
  /// or `token` arrives we pin them to the canonical seq.
  int _lastPersistedSeq = 0;

  /// Last envelope `ts` we observed, captured at the top of
  /// [_onEvent]. Bubbles spawned from ephemeral streams (like the
  /// first token that triggers an assistant bubble) read this so
  /// the bubble's displayed timestamp reflects the daemon's clock,
  /// not the client's. Cleared on session switch.
  DateTime? _lastEventTs;

  /// Set of `seq` values already applied to the chat. Mandated by
  /// the event-spec §0 ("dedup par seq") — Socket.IO can redeliver
  /// the same event on reconnect and the replay path can also
  /// re-feed historical events that already landed live. Every
  /// `_onEvent` entry point checks this set first and skips
  /// duplicates.
  final Set<int> _appliedSeqs = <int>{};

  /// User-message events received with `pending: true` that have
  /// no matching optimistic bubble in the chat. Per the product
  /// contract, queued messages must NOT appear in the chat
  /// timeline until the daemon actually starts executing them —
  /// they live only in the queue panel until then. We buffer the
  /// user_message payload here, keyed by correlation_id, and flush
  /// it into a chat bubble when the matching `message_started`
  /// fires. The chat bubble's sortKey then pins to the
  /// `message_started` seq so the message slots into the chat at
  /// the moment the daemon injected it into the conversation.
  final Map<String, _QueuedUserMessage> _queuedUserMessages = {};

  /// In-memory cache of messages per session id. Populated when
  /// switching away, restored when switching back. Guarantees the
  /// user never sees an empty chat after a round-trip, even if the
  /// daemon's history endpoint is empty/slow/broken.
  ///
  /// Capped at [_maxCachedSessions] with LRU eviction — otherwise a
  /// long session (hundreds of sessions switched) grows this map
  /// until it holds every ChatMessage the user has ever seen.
  final Map<String, List<ChatMessage>> _sessionMessageCache = {};
  static const int _maxCachedSessions = 8;

  /// Per-session "last known seq" companion to [_sessionMessageCache].
  /// Populated every time we ``_cacheSessionMessages`` so the cache-hit
  /// short-circuit in ``_tryRestoreAndConnectInner`` can ask the state
  /// envelope "has anything moved on the server since we saved this?"
  /// An equal (or lower) envelope seq = nothing new = skip the full
  /// history fetch entirely. Keyed identically to ``_sessionMessageCache``
  /// so LRU eviction stays in sync.
  final Map<String, int> _sessionSeqCache = {};

  /// IDs of messages that have already played their entrance animation.
  /// Only messages NOT in this set get the TweenAnimationBuilder fade-in.
  final Set<String> _animatedMessageIds = {};

  void _cacheSessionMessages(String sessionId, List<ChatMessage> messages) {
    // Touch: remove + re-insert so most-recent is at the end.
    _sessionMessageCache.remove(sessionId);
    _sessionMessageCache[sessionId] = List<ChatMessage>.from(messages);
    // Stamp the seq the envelope controller currently reports so a
    // later switch-back can compare. If no envelope (e.g. brand-new
    // session never observed), stamp 0 — the cache-hit path requires
    // seq > 0 so it'll fall through to the full fetch on next visit.
    final env = SessionStateController().envelopeFor(sessionId);
    _sessionSeqCache[sessionId] = env?.seq ?? 0;
    while (_sessionMessageCache.length > _maxCachedSessions) {
      // Drop the oldest entry (first key in insertion order).
      final oldest = _sessionMessageCache.keys.first;
      _sessionMessageCache.remove(oldest);
      _sessionSeqCache.remove(oldest);
    }
  }

  // ── Replay state ────────────────────────────────────────────────────
  /// True while we are rebuilding the chat from a historical event log.
  /// Guards side effects in [_onEvent] (notifications, message queue)
  /// so they don't fire as if they were live.
  bool _isReplaying = false;
  bool _isPreparingSession = false;
  bool _highlightWorkspaceChip = false;
  // True while _send() is in the middle of createAndSetSession — prevents
  // the resulting _onSessionChange from doing its normal destructive reset
  // (_messages.clear / _isSending=false / _tryRestoreAndConnect) since
  // _send() owns all that state for the duration of the send flow.
  bool _isCreatingSession = false;
  int _replayTotal = 0;
  int _replayDone = 0;

  /// Live events that arrived during a replay — held back until the
  /// replay finishes, then drained in order. Prevents interleaving of
  /// historical and live events (which would break tool-call id
  /// ordering, turn bookkeeping, and _currentMsg references).
  final List<Map<String, dynamic>> _liveBuffer = [];

  /// Monotonically increasing counter for unique ChatMessage ids.
  /// `DateTime.now()` collides when two bubbles are created in the
  /// same millisecond (agent reply + auto-splash widget, etc.).
  int _msgCounter = 0;
  String _nextMsgId(String prefix) =>
      '$prefix-${DateTime.now().millisecondsSinceEpoch}-${_msgCounter++}';

  /// Watchdog for a stuck spinner. If no chat event arrives for this
  /// long while `_isSending=true`, we reset the spinner so the user
  /// can send again. Turns can legitimately be slow, so pick a value
  /// larger than any reasonable daemon timeout (default 60s).
  Timer? _spinnerWatchdog;
  // Threshold chosen to comfortably exceed any single daemon-side
  // operation that legitimately runs without emitting token/status
  // events — e.g. a sub-agent spawn that does a long tool call. The
  // watchdog is the last-resort "daemon is truly silent" reset, not
  // an activity timer. The daemon's own operation timeout is 120 s
  // so 180 s guarantees we never pre-empt a legitimate long turn.
  static const _stuckSpinnerThreshold = Duration(seconds: 180);
  /// Throttles re-arming of [_spinnerWatchdog]. Re-creating a Timer
  /// on every token during a dense stream pins the GC; one re-arm
  /// every 2s is plenty to detect a real stall.
  DateTime? _lastWatchdogArm;

  // ── Find-in-chat (Ctrl+F / Cmd+F) ──────────────────────────────
  bool _showFind = false;
  String _findQuery = '';
  final TextEditingController _findCtrl = TextEditingController();
  final FocusNode _findFocus = FocusNode();

  /// Debounce timer for batching rapid setState calls from listeners
  /// (QueueService + SessionStateController can both fire in the same
  /// microtask; merging them into one frame avoids a double rebuild).
  Timer? _debouncedSetStateTimer;

  // ── Long-running tool tracker ──────────────────────────────────
  /// Name of the currently executing tool (from a `tool_use:…` phase)
  /// and when it started. Drives the lean tool bar that only appears
  /// for tools that run longer than 2 seconds, so short calls stay
  /// invisible.
  String? _activeToolName;
  DateTime? _activeToolStartedAt;
  Timer? _activeToolTicker;

  /// Set after a successful replay when the last event in the log was
  /// not a `turn_end`/`result` — the daemon was mid-turn when we last
  /// saw it. The Socket.IO join that follows will continue streaming
  /// the rest of the turn.
  bool _turnInProgress = false;

  /// Set when the daemon reports the session is interrupted. Shown as
  /// a red badge on the chat header with a retry affordance.
  bool _isInterrupted = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _ctrl.addListener(_onTextChanged);
    // Rebuild whenever the timeline order changes — covers the case
    // where a `rekey` / direct `ChatMessage.notifyListeners` happens
    // outside an enclosing `setState` (e.g. from a service callback).
    _timeline.addListener(_onTimelineChanged);

    // Check for a pending message from the dashboard BEFORE the first
    // build so the first frame shows the preparing screen, not the empty
    // state. Direct variable assignment is safe here — no setState needed
    // since the widget hasn't built yet.
    final pendingAppState = context.read<AppState>();
    final _pendingToSend = pendingAppState.pendingMessage;
    if (_pendingToSend != null && _pendingToSend.isNotEmpty) {
      pendingAppState.pendingMessage = null;
      _ctrl.text = _pendingToSend;
      _isPreparingSession = true;
    }
    // Rebuild when the daemon-persisted queue changes so the composer
    // badge + queue panel visibility stay in sync.
    QueueService().addListener(_onQueueChanged);
    // Rebuild when the session state envelope changes — authoritative
    // source for the animated send button + progress indicator. Keeps
    // the UI accurate even when individual events are lost / reordered
    // / delivered out of band (HTTP response state, reconnect snapshot,
    // resync after watchdog timeout all flow through this controller).
    SessionStateController().addListener(_onQueueChanged);
    // Expose _exportChat so the session drawer's ⋮ menu can trigger
    // an export of the currently-mounted conversation.
    ChatExportBridge().register(_exportChat);
    // Lets the Monaco editor header's "Add to chat" button push a
    // workspace file into the composer from outside this widget.
    ChatAttachBridge().register(_addAttachmentExternal);
    VoiceInputService().addListener(_onVoiceStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _eventSub = SessionService().events.listen(_onEvent);
      _sessionChangeSub =
          SessionService().onSessionChange.listen(_onSessionChange);
      _widgetEventSub =
          widgets_service.WidgetEventBus().stream.listen(_onWidgetEvent);
      final active = SessionService().activeSession;
      if (active != null) {
        _currentSessionId = active.sessionId;
        _tryRestoreAndConnect(active.appId, active.sessionId);
      }
      // If a pending message was loaded in initState (pre-build), fire
      // _send() now that all subscriptions are active so events from
      // session creation are properly caught.
      final appState = context.read<AppState>();
      if (_isPreparingSession && _ctrl.text.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _send();
        });
      }
      _widgetChatSub = appState.widgetChatStream.listen((msg) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _ctrl.text = msg;
          _send();
        });
      });
    });
  }

  // Called when the widget is reinserted via GlobalKey reuse (e.g. user
  // was on the dashboard, opens an app — the existing _ChatPanelState is
  // reattached without calling initState() again). We must mirror the
  // pendingMessage logic from initState() here so the bypass works on
  // every app open, not just the very first one.
  @override
  void activate() {
    super.activate();
    // GlobalKey preservation — when the user goes home and comes
    // back, this state object is reattached to the tree instead of
    // being recreated, so ``_currentSessionId`` and ``_messages``
    // still carry whatever session was open last time. Re-sync with
    // the authoritative ``SessionService.activeSession`` that
    // ``setApp`` may have cleared or swapped while we were off-tree
    // — otherwise clicking an app from the home page shows that
    // app's last session transcript instead of the empty welcome
    // state.
    final liveSessionId = SessionService().activeSession?.sessionId;
    if (liveSessionId != _currentSessionId) {
      _onSessionChange(liveSessionId);
    }
    final appState = context.read<AppState>();
    final pending = appState.pendingMessage;
    if (pending != null && pending.isNotEmpty) {
      appState.pendingMessage = null;
      _ctrl.text = pending;
      _isPreparingSession = true;
      // Subscriptions from initState() are still active — one frame is
      // enough before _send() fires.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _send();
      });
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _sessionChangeSub?.cancel();
    _widgetChatSub?.cancel();
    _widgetEventSub?.cancel();
    _responseTimeout?.cancel();
    _spinnerWatchdog?.cancel();
    _activeToolTicker?.cancel();
    _debouncedSetStateTimer?.cancel();
    _scrollbarIdleTimer?.cancel();
    QueueService().removeListener(_onQueueChanged);
    SessionStateController().removeListener(_onQueueChanged);
    VoiceInputService().removeListener(_onVoiceStateChanged);
    ChatExportBridge().unregister(_exportChat);
    ChatAttachBridge().unregister(_addAttachmentExternal);
    _timeline.removeListener(_onTimelineChanged);
    _timeline.dispose();
    _ctrl.dispose();
    _scroll.dispose();
    _focus.dispose();
    _findCtrl.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  /// Timeline mutation hook. Schedules a frame rebuild via `setState`,
  /// but only when no other `setState` is already in flight — the
  /// bulk of mutations happen inside `setState(() { _messages.add(…) })`
  /// blocks, and Flutter forbids a nested `setState`. Posting to the
  /// next frame when we're already inside `build` makes the listener
  /// safe in every call site.
  void _onTimelineChanged() {
    if (!mounted) return;
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    }
  }

  /// Stable sort by [ChatMessage.sortKey]. In the arrival-order
  /// model [ChatMessage.sortKey] is a microseconds-since-epoch tick
  /// assigned once at construction, so this is effectively a no-op
  /// (the list is always in insertion order already). Kept as a
  /// defensive guarantee in case anything ever constructs a bubble
  /// with an out-of-order explicit sortKey.
  // Throttle streaming artifact extraction — running the regex on
  // every token would be wasteful once the body gets long. We only
  // re-run when the text has grown past the last-seen length AND
  // the new content could plausibly have crossed a fence boundary.
  DateTime _lastArtifactScan = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastArtifactScanLen = 0;

  void _maybeExtractStreamingArtifacts(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return;
    final text = msg.text;
    if (text.isEmpty) return;
    // Fast path: no fence in the text yet → nothing to extract.
    if (!text.contains('```')) return;
    final now = DateTime.now();
    final grew = text.length > _lastArtifactScanLen + 32;
    final sinceLast = now.difference(_lastArtifactScan).inMilliseconds;
    if (!grew && sinceLast < 180) return;
    _lastArtifactScan = now;
    _lastArtifactScanLen = text.length;
    try {
      final extraction =
          ArtifactDetector.extractStreaming(messageId: msg.id, text: text);
      ArtifactService()
          .upsertForMessage(msg.id, extraction.artifacts);
    } catch (e) {
      debugPrint('streaming artifact extraction failed: $e');
    }
  }

  /// Legacy no-op. Ordering is now enforced by [ChatTimeline] on every
  /// mutation — the timeline is always sorted by (seq, insertion-tick)
  /// by construction, so a post-hoc re-sort is never needed. Kept as a
  /// no-op so the dozens of historical call sites still compile while
  /// we complete the migration; the next sweep removes it entirely.
  void _resortMessages() {}

  /// Pin a bubble to a canonical daemon seq. Updates the bubble's own
  /// `daemonSeq` AND the timeline's sort key in a single atomic step —
  /// forgetting the second half would leave the bubble orphaned at its
  /// optimistic tail position while the model reports the real seq.
  ///
  /// The timeline is rekeyed with the bubble's freshly-recomputed
  /// `sortKey` (not the raw seq), to stay in the same number range as
  /// every other bubble — see [_TimelineBackedMessageList._keyOf].
  void _pinBubbleSeq(ChatMessage msg, int seq) {
    if (seq <= 0) return;
    msg.updateSortKey(seq);
    _timeline.rekey(msg.id, seq: msg.sortKey);
  }

  /// Legacy anchor helper used by local-only bubbles (error banners,
  /// system notices, optimistic user messages). Timeline-backed
  /// bubbles don't need an anchor — they either carry a daemon seq
  /// or sit at the tail sentinel — but the returned value still feeds
  /// [ChatMessage] constructors whose `anchorSeq` field is part of
  /// the public model. The timeline ignores `anchorSeq`; it keys off
  /// `daemonSeq` (or null → tail).
  int _anchorForNewLocalBubble() {
    int best = _lastPersistedSeq;
    for (final m in _messages) {
      final s = m.daemonSeq;
      if (s != null && s > best) best = s;
    }
    return best;
  }

  /// Race-guard: if `_currentMsg` was spawned by an early event
  /// (e.g. `status: requesting`) BEFORE `user_message` arrived, its
  /// provisional anchor is below the user's just-pinned `envSeq` —
  /// so the assistant/thinking bubble would render ABOVE the user
  /// bubble once the user gets its canonical seq. Pin the orphan
  /// assistant to `envSeq + 1` as a transient floor; the next real
  /// `message_started` / `token` event overwrites this with the
  /// canonical seq via [ChatMessage.updateSortKey]. A daemon that
  /// emits events strictly in-order never hits this path — the pin
  /// is a no-op when `_currentMsg` already carries a daemon seq.
  ///
  /// Must be called inside the caller's `setState` so the post-pin
  /// [_resortMessages] picks up the new order in the same frame;
  /// caller is also responsible for that re-sort.
  void _pinOrphanAssistantAbove(int envSeq) {
    if (envSeq <= 0) return;
    final cur = _currentMsg;
    if (cur == null) return;
    if (cur.daemonSeq != null) return;
    _pinBubbleSeq(cur, envSeq + 1);
  }

  /// Parse an envelope-level `ts` (ISO-8601 UTC with a trailing Z)
  /// into a DateTime. The daemon stamps this at publish time —
  /// downstream bubbles use it for their displayed timestamp so
  /// the UI shows server-authoritative times (not the client's
  /// wall clock). Returns null for missing / malformed strings.
  DateTime? _parseEventTs(Map<String, dynamic> event) {
    final ts = event['ts'];
    if (ts is! String || ts.isEmpty) return null;
    return DateTime.tryParse(ts);
  }

  bool _hasLiveAgentActivity() =>
      logic.hasLiveAgentActivity(hadTokens: _hadTokens, phase: _statusPhase);

  /// Prime the composer to overwrite the given tail queued entry via
  /// `queue_mode=replace_last`. Next Send uses the same position /
  /// row id — the daemon rotates the correlation id and broadcasts
  /// `message_replaced`.
  void _editTailMessage(QueueEntry entry) {
    if (!mounted) return;
    setState(() {
      _pendingReplaceLast = entry;
      _ctrl.text = entry.message;
      _ctrl.selection = TextSelection.fromPosition(
          TextPosition(offset: entry.message.length));
    });
    _focus.requestFocus();
  }

  void _markScrollbarEngaged() {
    _scrollbarIdleTimer?.cancel();
    if (!_scrollbarEngaged && mounted) {
      setState(() => _scrollbarEngaged = true);
    }
    _scrollbarIdleTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _scrollbarEngaged = false);
    });
  }

  void _onQueueChanged() {
    if (!mounted) return;
    // One-shot toast on queue_full; consume so it doesn't re-fire.
    final full = QueueService().lastQueueFull;
    if (full != null && full.sessionId == _currentSessionId) {
      QueueService().consumeQueueFull();
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(SnackBar(
        content: Text(
          'Queue full (${full.depth}/${full.max}). Wait for a running '
          'turn to finish or clear pending messages first.',
        ),
        duration: const Duration(seconds: 4),
      ));
    }
    // Debounce: QueueService and SessionStateController can fire in the
    // same microtask. Batch them into a single frame instead of two.
    _debouncedSetStateTimer?.cancel();
    _debouncedSetStateTimer = Timer(Duration.zero, () {
      if (mounted) setState(() {});
    });
  }

  // ─── Session switch ──────────────────────────────────────────────────────

  void _onSessionChange(String? newSessionId) {
    debugPrint('[SESSION_CHG] _onSessionChange: new=$newSessionId '
        'current=$_currentSessionId '
        'activeSession=${SessionService().activeSession?.sessionId}');
    if (newSessionId == _currentSessionId) {
      debugPrint('[SESSION_CHG] skip — same as current');
      return;
    }

    // _send() is mid-flight creating this exact session. Let _send()
    // own all the UI state — only update the session ID so events
    // land in the right bucket. Skip the destructive reset and
    // _tryRestoreAndConnect (new session has no history to fetch).
    //
    // The flag is cleared HERE, not in _send(): the session-change
    // stream fires on a microtask AFTER ``await createAndSetSession``
    // resolves, so if _send() had flipped it false before returning
    // we'd race through the destructive branch below and wipe the
    // optimistic user bubble — producing the "empty state flashes
    // back" glitch. Clearing on the exact callback that the flag is
    // meant to gate is race-free by construction.
    if (_isCreatingSession) {
      debugPrint('[SESSION_CHG] skip destructive reset — send in flight');
      _isCreatingSession = false;
      if (mounted) setState(() => _currentSessionId = newSessionId);
      else _currentSessionId = newSessionId;
      return;
    }

    // Snapshot the outgoing session's messages so we can restore
    // them if the daemon's /history endpoint returns empty on the
    // way back in.
    final outgoing = _currentSessionId;
    if (outgoing != null && _messages.isNotEmpty) {
      _cacheSessionMessages(outgoing, _messages);
    }
    // ATOMIC cleanup — session id, bubble reference, and per-session
    // UI state must all flip together. Deferring any of this to a
    // post-frame callback opens a window where events for the new
    // session land in the old session's bubble (or vice versa).
    if (mounted) {
      setState(() {
        _currentSessionId = newSessionId;
        _currentMsg = null;
        _messages.clear();
        _messageKeys.clear();
        _animatedMessageIds.clear();
        _pendingApprovals.clear();
        _approvalMarkerReqId.clear();
        _liveBuffer.clear();
        _isSending = false;
        _hadTokens = false;
        _statusPhase = '';
        _activeError = null;
        _isInterrupted = false;
        _turnInProgress = false;
        _isReplaying = false;
        _replayTotal = 0;
        _replayDone = 0;
        _appliedSeqs.clear();
        _queuedUserMessages.clear();
        _lastPersistedSeq = 0;
        _lastEventTs = null;
        _pendingCompactionBubbleId = null;
        _awaitingAgentResponse = false;
      });
    } else {
      _currentSessionId = newSessionId;
      _currentMsg = null;
      _liveBuffer.clear();
      _appliedSeqs.clear();
      _queuedUserMessages.clear();
      _lastPersistedSeq = 0;
      _lastEventTs = null;
    }
    _responseTimeout?.cancel();
    _responseTimeout = null;
    _spinnerWatchdog?.cancel();
    _spinnerWatchdog = null;
    _activeToolTicker?.cancel();
    _activeToolTicker = null;
    _activeToolName = null;
    _activeToolStartedAt = null;

    // Global stores tied to the session context.
    WorkspaceService().clearAll();
    WorkspaceState().onNewSession();
    SessionMetrics().reset();
    ContextState().reset();
    PreviewStore().reset();
    WorkspaceModule().reset();
    WorkspaceSnapshotService().resetForNewSession();
    ArtifactService().clear();

    if (newSessionId == null) return;
    final session = SessionService().activeSession;
    if (session == null) return;
    _tryRestoreAndConnect(session.appId, session.sessionId);
  }

  Future<void> _tryRestoreAndConnect(String appId, String sessionId) async {
    debugPrint(
        '[RESTORE] _tryRestoreAndConnect START app=$appId sid=$sessionId');
    // Flag the replay window **before** the HTTP fetch starts. Any
    // live socket event arriving during the /history round-trip
    // (which can take several seconds on a session with thousands
    // of events) MUST go to ``_liveBuffer`` rather than taking the
    // fast path through ``_onEvent``. Otherwise those live events
    // populate ``_messages`` during the wait — and then
    // ``_replayEventLog`` wipes them when it starts, producing the
    // exact "history appears for a second then the chat goes back
    // to the empty welcome state" flash the user reported.
    if (mounted) {
      setState(() {
        _isReplaying = true;
      });
    } else {
      _isReplaying = true;
    }
    try {
      await _tryRestoreAndConnectInner(appId, sessionId);
    } finally {
      // Safety net — every non-replay return path above would otherwise
      // leave ``_isReplaying`` stuck at true, re-buffering every live
      // event forever. ``_replayEventLog`` resets it on the success
      // path; this finally covers all the others (legacy messages[]
      // fallback, workspace-only, cached hydrate, early returns).
      if (_isReplaying && mounted) {
        final buffered = List<Map<String, dynamic>>.from(_liveBuffer);
        _liveBuffer.clear();
        setState(() {
          _isReplaying = false;
        });
        for (final ev in buffered) {
          if (!mounted) break;
          _onEvent(ev);
        }
      } else if (_isReplaying) {
        _isReplaying = false;
        _liveBuffer.clear();
      }
    }
  }

  Future<void> _tryRestoreAndConnectInner(
      String appId, String sessionId) async {
    final cached = _sessionMessageCache[sessionId];
    final hadCached = cached != null && cached.isNotEmpty;

    // ── Cache-first: show cached messages immediately ─────────────────────
    // If we already have messages for this session in memory, render them
    // now so the user sees content instantly instead of a loading spinner.
    // We still fetch from the server below to pick up any new events, but
    // the visible delay goes from "blank screen → data" to "instant → maybe
    // a few new bubbles appear".
    if (hadCached && mounted) {
      setState(() {
        _messages.clear();
        _messageKeys.clear();
        _messages.addAll(cached);
        // Keep _isReplaying = true so live socket events stay buffered
        // during the HTTP fetch below. Setting it to false here would
        // let live events bypass the buffer and then get wiped when
        // _replayEventLog runs its initial _messages.clear() — that is
        // the exact sequence that produces the "flash to empty state" bug.
      });
      // Mark all cached messages as already animated so they don't fade in.
      for (final m in cached) {
        _animatedMessageIds.add(m.id);
      }
    }

    // ── Cache-hit short-circuit ───────────────────────────────────────────
    // When we have cached messages AND the session envelope from the
    // authoritative state controller says "no turn running, no queue
    // pending, seq matches ours", we KNOW nothing has changed since we
    // last looked. Skip the expensive ``/history`` HTTP fetch + event
    // replay — live Socket.IO events will catch us up from here.
    //
    // This is the main fix for "switching between recent sessions is
    // slow": previously we always paid the full fetch + replay even for
    // a session we looked at 2 seconds ago. Now it's literally one
    // frame: the cached widgets render, done.
    final envelope = SessionStateController().envelopeFor(sessionId);
    final cachedSeq = _sessionSeqCache[sessionId] ?? 0;
    final canSkipHistoryFetch = hadCached
        && envelope != null
        && !envelope.isTurnActive
        && envelope.queue.depth == 0
        && cachedSeq > 0
        && envelope.seq <= cachedSeq;
    if (canSkipHistoryFetch && mounted) {
      debugPrint('[RESTORE] cache-hit short-circuit '
          'sid=$sessionId cached_seq=$cachedSeq envelope_seq=${envelope.seq} '
          '— skipping loadFullHistory');
      setState(() {
        // Do NOT flip ``_isReplaying`` here — the outer
        // ``_tryRestoreAndConnect.finally`` block owns that transition
        // and drains ``_liveBuffer`` in order. Flipping it in two
        // places races with the drain and drops events.
        _turnInProgress = false;
        _isSending = false;
        _statusPhase = '';
      });
      _reconnectSession(appId, sessionId);
      return;
    }

    SessionService().markLoadingHistory(true);
    // Pagination — default 500 events, tightens to the seq-delta when
    // we have a cached view to revalidate on top of. This is the big
    // cold-start win: on a session with 5 000 events the old code
    // pulled 2+ Mo of JSON; the new code pulls ~20 Ko of the tail.
    final full = await SessionService()
        .loadFullHistory(
          appId, sessionId,
          // Never pass a since_seq when we don't have cached bubbles —
          // the daemon would skip early events and the chat panel
          // would render with missing turns at the top.
          sinceSeq: hadCached ? cachedSeq : null,
          eventsLimit: 500,
        )
        .whenComplete(() {
      if (SessionService().activeSession?.sessionId == sessionId) {
        SessionService().markLoadingHistory(false);
      }
    });

    debugPrint('[RESTORE] loadFullHistory done sid=$sessionId '
        'full=${full != null} mounted=$mounted '
        'currentSid=$_currentSessionId');
    if (!mounted || _currentSessionId != sessionId) {
      debugPrint('[RESTORE] early return — '
          'mounted=$mounted, currentSid=$_currentSessionId != $sessionId');
      return;
    }

    if (full != null) {
      final messages = full['messages'] ?? full['turns'] ?? [];
      final events = full['events'];
      final workspace = full['workspace'] as String? ?? '';
      final title = full['title'] as String? ?? '';
      final interrupted = full['interrupted'] as bool? ?? false;
      // Daemon-authoritative "a turn is running right now". Populated
      // by ``manager.is_turn_running`` on the server side (see
      // ``apps.py:get_session_history``). Replace the client-side
      // event-log heuristic that too often mistook trailing
      // hook/memory_update/compaction events for "still running"
      // and left a ghost spinner on reopen.
      final turnActive = full['turn_active'] as bool? ?? false;
      final hasEvents = events is List && events.isNotEmpty;

      // Apply snapshots BEFORE replaying events, so preview files,
      // memory goal/todos, and workbench buffers are already there
      // when events reference them.
      final previewSnap = full['preview_snapshot'] as Map<String, dynamic>?;
      if (previewSnap != null) {
        PreviewStore().applySnapshot(previewSnap);
      }
      _restoreMemorySnapshot(full);

      if (title.isNotEmpty) {
        SessionService().updateSessionTitle(sessionId, title);
      }
      if (workspace.isNotEmpty && mounted) {
        context.read<AppState>().setWorkspace(workspace);
      }
      final ctx = full['context'] as Map<String, dynamic>?;
      if (ctx != null) ContextState().updateFromJson(ctx);

      debugPrint(
          '[RESTORE] full loaded: messages.count='
          '${messages is List ? messages.length : "?"} '
          'events.count=${events is List ? events.length : 0}');

      // Preferred path — replay the full event log when the daemon
      // has one. This is lossless and reproduces tool calls, widgets,
      // agent events, hooks, approvals, etc. exactly as they ran.
      if (hasEvents) {
        await _replayEventLog(events,
            sessionInterrupted: interrupted, turnActive: turnActive);
        debugPrint(
            '[RESTORE] replay done — _messages.length=${_messages.length}');
        if (!mounted || _currentSessionId != sessionId) return;
        _cacheSessionMessages(sessionId, _messages);
        _reconnectSession(appId, sessionId);
        return;
      }

      if (messages is List && messages.isNotEmpty) {
        // Legacy sessions (pre event-log) fall back to turn-based
        // restoration — less granular but still correct for completed
        // conversations.
        _restoreFromHistory(List<Map<String, dynamic>>.from(messages));
        _cacheSessionMessages(sessionId, _messages);

        if (interrupted && mounted) {
          setState(() {
            _statusPhase = 'interrupted';
            _isInterrupted = true;
          });
        }
        // Same daemon-authoritative turn state on the legacy path —
        // without this, reopening a session that IS still running on
        // the server would miss its spinner until the next live event.
        if (mounted) {
          setState(() {
            _turnInProgress = turnActive;
            if (turnActive) {
              _isSending = true;
              if (_statusPhase.isEmpty) _statusPhase = 'responding';
            } else {
              _isSending = false;
              _statusPhase = '';
              _hadTokens = false;
            }
          });
        }

        // Reconnect + resume
        _reconnectSession(appId, sessionId);
        return;
      } else if (workspace.isNotEmpty && mounted) {
        // Session exists on daemon but no messages yet — restore workspace
        context.read<AppState>().setWorkspace(workspace);
        // Daemon has nothing — hydrate from our cache as fallback.
        if (hadCached) {
          setState(() {
            _messages.clear();
            _messageKeys.clear();
            _messages.addAll(cached);
          });
          _reconnectSession(appId, sessionId);
        }
        return;
      }
    }

    // Daemon returned nothing. Hydrate from cache if we have one so
    // the user never sees an empty chat after a round-trip.
    if (hadCached) {
      setState(() {
        _messages.clear();
        _messageKeys.clear();
        _messages.addAll(cached);
      });
      _reconnectSession(appId, sessionId);
      return;
    }
    // Truly new session — reset workspace
    if (mounted) context.read<AppState>().setWorkspace('');
  }

  /// Rebuild workspace files from tool calls in restored messages.
  /// Fallback when workbench_snapshot is not available from daemon.
  void _restoreMemorySnapshot(Map<String, dynamic> full) {
    final memory = full['memory_snapshot'] as Map<String, dynamic>?;
    if (memory == null) return;
    final goal = memory['goal'] as String? ?? '';
    if (goal.isNotEmpty) {
      WorkspaceState().handleMemoryUpdate('set_goal', {'goal': goal});
    }
    final todos = memory['todos'] as List<dynamic>?;
    if (todos != null && todos.isNotEmpty) {
      WorkspaceState().handleMemoryUpdate('update_todo', {'todos': todos, 'goal': goal});
    }
    final facts = memory['facts'] as List<dynamic>?;
    if (facts != null) {
      for (final f in facts) {
        final content = f is Map ? f['content'] as String? ?? '' : f.toString();
        if (content.isNotEmpty) {
          WorkspaceState().handleMemoryUpdate('remember', {'content': content});
        }
      }
    }
  }

  Future<void> _reconnectSession(String appId, String sessionId) async {
    // Start metrics polling
    SessionMetrics().startPolling(appId, sessionId);
    // Check state + resume if interrupted (workspace already restored by _tryRestoreHistory)
    await SessionService().checkAndResume(appId, sessionId);
    // Check for pending approvals (filtered by current session + timeout)
    try {
      final pending = await SessionService().loadPendingApprovals(appId);
      if (pending.isNotEmpty && mounted) {
        final now = DateTime.now().millisecondsSinceEpoch / 1000;
        setState(() {
          for (final p in pending) {
            // Filter by session
            final pSession = p['session_id'] as String? ?? '';
            if (pSession.isNotEmpty && pSession != sessionId) continue;

            // Skip expired approvals (> 5 min)
            final createdAt = (p['created_at'] as num?)?.toDouble() ?? 0;
            if (createdAt > 0 && (now - createdAt) > 300) continue;

            final req = ApprovalRequest(
              id: p['request_id'] as String? ?? '',
              agentId: p['agent_id'] as String? ?? '',
              toolName: p['tool_name'] as String? ?? p['tool'] as String? ?? 'unknown',
              params: Map<String, dynamic>.from(p['tool_params'] ?? p['params'] ?? {}),
              riskLevel: p['risk_level'] as String? ?? 'medium',
              description: p['description'] as String? ?? '',
              createdAt: createdAt > 0 ? createdAt : null,
            );
            if (req.id.isNotEmpty && !_pendingApprovals.any((a) => a.id == req.id)) {
              _pendingApprovals.add(req);
            }
          }
        });
      }
    } catch (e, st) {
      debugPrint('loadPendingApprovals failed: $e\n$st');
    }
  }

  /// Convert daemon history turns into ChatMessage objects
  void _restoreFromHistory(List<Map<String, dynamic>> turns) {
    final restored = <ChatMessage>[];
    for (final turn in turns) {
      try {
        final role = turn['role'] as String? ?? '';
        final content = turn['content'] as String? ?? '';

        if (role == 'user') {
          restored.add(ChatMessage(
            id: 'hist-${restored.length}',
            role: MessageRole.user,
            initialText: content,
            // Legacy turn format has no per-event seq. Assign a
            // synthetic monotonic seq so the restored history stays
            // ordered and sorts above any live event (which carries
            // the session's real, larger seq).
            daemonSeq: restored.length + 1,
          ));
        } else if (role == 'assistant') {
          final msg = ChatMessage(
            id: 'hist-${restored.length}',
            role: MessageRole.assistant,
            daemonSeq: restored.length + 1,
          );

          // Restore thinking (shows before tools/text)
          final thinking = turn['thinking'] as String?;
          if (thinking != null && thinking.isNotEmpty) {
            msg.setThinkingText(thinking);
          }

          // Restore tool calls with full detail
          final toolCalls = (turn['toolCalls'] as List<dynamic>?)
              ?? (turn['tool_calls'] as List<dynamic>?)
              ?? [];
          for (int i = 0; i < toolCalls.length; i++) {
            final tc = toolCalls[i];
            if (tc is Map<String, dynamic>) {
              final name = tc['name'] as String? ?? '';
              final display = tc['display'] as Map<String, dynamic>?;
              // Contract v2 — trust display.hidden when present.
              // Fall back to the legacy heuristic only for rows
              // restored from a daemon that predates the display
              // block.
              final hiddenFlag = display?['hidden'] as bool? ??
                  tc['silent'] as bool? ??
                  false;
              final skip = display != null
                  ? hiddenFlag
                  : (hiddenFlag || _isHiddenTool(name));
              if (skip) continue;

              final label = (display?['verb'] as String?)
                  ?? (tc['label'] as String?)
                  ?? '';
              final detail = (display?['detail'] as String?)
                  ?? (tc['detail'] as String?)
                  ?? '';
              final visibleParamsRaw = display?['visible_params'];

              final histResult = tc['result'];
              final histMeta = tc['metadata'];
              msg.addOrUpdateToolCall(ToolCall(
                id: tc['id'] as String? ?? 'tc-$i',
                name: name,
                label: label,
                detail: detail,
                detailParam: (display?['detail_param'] as String?) ??
                    (tc['detail_param'] as String?) ??
                    '',
                icon: (display?['icon'] as String?) ?? 'tool',
                channel: (display?['channel'] as String?) ?? 'chat',
                category: (display?['category'] as String?) ?? 'action',
                group: (display?['group'] as String?) ?? '',
                hidden: hiddenFlag,
                visibleParams: visibleParamsRaw is List
                    ? visibleParamsRaw.whereType<String>().toList()
                    : null,
                params: Map<String, dynamic>.from(tc['params'] ?? {}),
                status: tc['status'] as String? ?? 'completed',
                result: histResult,
                error: tc['error'] as String?,
                previousContent: tc['previous_content'] as String?,
                newContent: tc['new_content'] as String?,
                output: tc['output'] as String?,
                metadata: histMeta is Map
                    ? Map<String, dynamic>.from(histMeta)
                    : (histResult is Map && histResult['metadata'] is Map
                        ? Map<String, dynamic>.from(histResult['metadata'] as Map)
                        : null),
                diff: tc['diff'] as String?
                    ?? (histResult is Map ? histResult['diff'] as String? : null),
                unifiedDiff: tc['unified_diff'] as String?
                    ?? (histResult is Map ? histResult['unified_diff'] as String? : null),
                imageData: tc['image_data'] as String?
                    ?? (histResult is Map ? histResult['image_data'] as String? : null),
                imageMime: tc['image_mime'] as String?
                    ?? (histResult is Map ? histResult['image_mime'] as String? : null),
              ));
            }
          }

          // Restore agent events
          final agentEvents = turn['agent_events'] as List<dynamic>? ?? [];
          for (final ae in agentEvents) {
            if (ae is Map<String, dynamic>) {
              msg.addAgentEvent(AgentEventData(
                agentId: ae['agent_id'] as String? ?? '',
                status: ae['status'] as String? ?? 'completed',
                specialist: ae['specialist'] as String? ?? '',
                task: ae['task'] as String? ?? '',
                duration: (ae['duration_seconds'] as num?)?.toDouble() ?? 0,
                preview: ae['preview'] as String? ?? '',
              ));
            }
          }

          // Text content comes after tool calls
          if (content.isNotEmpty) {
            msg.appendText(content);
          }

          restored.add(msg);
        }
      } catch (e) {
        debugPrint('History restore error for turn: $e');
      }
    }

    if (mounted) {
      setState(() {
        _messages.clear();
      _messageKeys.clear();
        _messages.addAll(restored);
      });
      for (final m in restored) {
        _animatedMessageIds.add(m.id);
      }
      _scrollToBottom();
    }
  }

  // ─── Event-log replay (rebuild from stored events) ──────────────────────
  //
  // The daemon now keeps every event of a turn in SQLite. On session
  // reopen we replay them through the same `_onEvent` handler used for
  // live events, so history and live behave identically. `preview:*`
  // events go through [PreviewStore.applyHistoryEvent] (which the live
  // path uses via its Socket.IO stream).
  //
  // Guarantees:
  //   • Message list is rebuilt from scratch.
  //   • Dangling `tool_start` without matching `tool_call` stays in
  //     `status='started'` so the UI shows the running state.
  //   • Last event != `turn_end` → _turnInProgress is set, Socket.IO
  //     rejoin will keep streaming.
  //   • Session-level `interrupted` flag surfaces as a red banner.
  Future<void> _replayEventLog(
    List<dynamic> events, {
    required bool sessionInterrupted,
    required bool turnActive,
  }) async {
    // Per event-spec §0: seq is the sole authority. Sort by seq
    // (daemon-assigned, monotonic strict per user), NEVER by ts
    // (which is only informative and may drift). ts is used as a
    // tie-break for the rare case a legacy event has no seq.
    final sorted = events
        .whereType<Map>()
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
        .toList()
      ..sort((a, b) {
        final sa = (a['seq'] as num?)?.toInt() ?? 0;
        final sb = (b['seq'] as num?)?.toInt() ?? 0;
        if (sa != sb) return sa.compareTo(sb);
        final ta = (a['ts'] as num?)?.toDouble() ?? 0;
        final tb = (b['ts'] as num?)?.toDouble() ?? 0;
        return ta.compareTo(tb);
      });

    if (!mounted) return;
    // Mutate fields directly — no setState — so we don't trigger a rebuild
    // that shows an empty chat before the first replay events are processed.
    // Any cached messages that were already visible will stay on screen until
    // _onEvent's own setStates repopulate _messages during the replay loop.
    // Live socket events are gated by _isReplaying = true below, so they
    // stay buffered until the final drain at the end of this method.
    _messages.clear();
    _messageKeys.clear();
    _currentMsg = null;
    _isSending = false;
    _statusPhase = '';
    _isReplaying = true;
    _replayTotal = sorted.length;
    _replayDone = 0;

    int lastSeq = 0;
    int openTurn = -1;
    int closedTurn = -2;
    double lastTurnActivityTs = 0;

    for (var i = 0; i < sorted.length; i++) {
      if (!mounted) return;
      final event = sorted[i];
      final type = event['type'] as String? ?? '';
      if (type.isEmpty) continue;
      // Shape-normalisation. `GET /history` returns each event
      // with its body under `payload` (matches the daemon's
      // internal EventBuffer shape), while live socket events
      // come through `DigitornSocketService._handleBusEvent`
      // already rewrapped as `data`. Accept either so a
      // session-reopen replay actually populates tokens, tool
      // params, hooks, etc. — tested live on
      // `GET /api/apps/digitorn-builder/sessions/resume-a22188e8/history`.
      final data = (event['data'] as Map?)?.cast<String, dynamic>() ??
          (event['payload'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final seq = (event['seq'] as num?)?.toInt();
      final turn = (event['turn'] as num?)?.toInt();
      // Daemon's history stamps `ts` as an ISO-8601 string; socket
      // events use a string too. Keep this value a double so the
      // existing heuristics that expect an epoch-seconds number
      // don't crash — but parse ISO when possible so the "recent
      // activity" check still works after a reopen.
      final tsRaw = event['ts'];
      double ts = 0;
      if (tsRaw is num) {
        ts = tsRaw.toDouble();
      } else if (tsRaw is String && tsRaw.isNotEmpty) {
        final parsed = DateTime.tryParse(tsRaw);
        if (parsed != null) {
          ts = parsed.millisecondsSinceEpoch / 1000.0;
        }
      }
      if (seq != null && seq > lastSeq) lastSeq = seq;

      // Track turn balance — the ONLY reliable signal that a turn
      // is still running. Ancillary events (memory_update, hook,
      // preview:*, widget:*) don't count — they can legitimately
      // trail a completed turn (compaction, workspace cleanup…).
      if (turn != null) {
        if (type == 'turn_start') {
          openTurn = turn;
          lastTurnActivityTs = ts;
        }
        if (type == 'turn_end' ||
            type == 'result' ||
            type == 'turn_complete' ||
            type == 'error' ||
            type == 'abort') {
          closedTurn = turn;
        }
      }
      // Record ts for any "live" event type so we can tell how long
      // ago the daemon actually spoke. Infrastructure events don't
      // count as activity.
      const liveTypes = {
        'token', 'out_token', 'thinking', 'thinking_delta',
        'tool_start', 'tool_call', 'status', 'agent_event',
      };
      if (liveTypes.contains(type) && ts > lastTurnActivityTs) {
        lastTurnActivityTs = ts;
      }

      _dispatchReplayEvent(type, data, seq: seq);

      // Yield periodically so the progress bar updates and the UI
      // stays responsive even with thousands of events.
      if (i % 40 == 0 && i > 0) {
        if (mounted) setState(() => _replayDone = i);
        await Future.delayed(Duration.zero);
      }
    }

    // ``turnActive`` comes straight from the daemon
    // (``manager.is_turn_running``, bundled in the /history response)
    // — it's the authoritative signal and ALWAYS wins over our
    // local event-log heuristic. The heuristic below (unbalanced
    // turn_start / turn_end within 90 s) stays as a last-resort
    // fallback for the case where ``turnActive`` is null — e.g.
    // an older daemon that doesn't populate the field, or an
    // offline replay. This is what fixes the "phantom 3-dot
    // spinner on reopen" — the heuristic frequently armed it when
    // hook / memory_update / compaction events landed after the
    // final turn_end.
    final turnsUnbalanced = openTurn >= 0 && openTurn > closedTurn;
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final hasRecentActivity = lastTurnActivityTs > 0 &&
        (nowSec - lastTurnActivityTs) < 90;
    final heuristicRunning = turnsUnbalanced && hasRecentActivity;
    final stillRunning = turnActive;
    if (turnActive != heuristicRunning) {
      debugPrint('[RESTORE] turn_active authoritative=$turnActive '
          'heuristic=$heuristicRunning — trusting daemon');
    }

    if (!mounted) return;
    // Flip ``_isReplaying`` to false BEFORE draining the buffer.
    // The buffer drain below calls ``_onEvent`` directly — that
    // handler re-buffers any event that arrives while
    // ``_isReplaying`` is true, so if we drained with the flag
    // still set every buffered event would simply be re-added to
    // ``_liveBuffer`` and the loop would stall (eventually hitting
    // the safety cap after 50 no-op iterations). The previous
    // attempt to keep the flag true during the drain to preserve
    // arrival order had exactly this failure mode, which presented
    // to the user as "history appears briefly then the chat reverts
    // to the welcome/empty state" — the buffer never applied.
    //
    // Race note: new live events arriving DURING the drain now
    // take the fast path. In practice that's acceptable because
    // every event carries a ``seq`` and ``_appliedSeqs`` dedups,
    // so an out-of-order apply still produces a consistent
    // timeline after the final sort by seq.
    setState(() {
      _isReplaying = false;
      _replayDone = sorted.length;
      _replayTotal = 0;
      // The event log wins: if the last events show a turn still
      // running, the session is live — the top-level `interrupted`
      // flag was only true at some earlier point and is now stale.
      _turnInProgress = stillRunning;
      _isInterrupted = sessionInterrupted && !stillRunning;
      if (_turnInProgress) {
        _isSending = true;
        if (_statusPhase.isEmpty) _statusPhase = 'responding';
      } else {
        // Turn is finished — force-reset every spinner flag even if
        // a mid-replay `status: responding` armed them. Without
        // this the "phantom spinner on reopen" comes back every
        // time the daemon emitted a status event after the final
        // turn_end (compaction hook, memory_update, …).
        _isSending = false;
        _statusPhase = '';
        _hadTokens = false;
        _currentMsg?.setStreamingState(false);
        _currentMsg?.setThinkingState(false);
        _currentMsg = null;
      }
      // Kill the 3-dot shimmer on any assistant bubble replay may have
      // left in ``isStreaming=true`` with empty content (typical shape
      // when a replayed ``status: responding`` / ``assistant_stream_snapshot``
      // spawned a placeholder whose matching ``stream_done`` /
      // ``message_done`` lives further back in the event log but
      // never materialises because the orphan sits on an obsolete turn).
      // When the turn is genuinely running, the very next live token
      // re-opens a fresh streaming bubble via ``_ensureBubble``.
      _finalizeOrphanStreamingBubbles();
      // All replayed messages are already "seen" — no entrance animation.
      for (final m in _messages) {
        _animatedMessageIds.add(m.id);
      }
    });
    _spinnerWatchdog?.cancel();
    _spinnerWatchdog = null;

    if (lastSeq > 0) {
      final sid = _currentSessionId;
      if (sid != null && sid.isNotEmpty) {
        SessionService().setSeqFor(sid, lastSeq);
      }
    }

    // Drain any live events that were buffered while the replay was
    // running. Now that ``_isReplaying`` is false, ``_onEvent``
    // processes them through the normal path in arrival order.
    if (_liveBuffer.isNotEmpty) {
      final buffered = List<Map<String, dynamic>>.from(_liveBuffer);
      _liveBuffer.clear();
      for (var i = 0; i < buffered.length; i++) {
        if (!mounted) break;
        _onEvent(buffered[i]);
        if (i % 30 == 29) {
          await Future.delayed(Duration.zero);
        }
      }
    }

    // Post-drain reconciliation. If the daemon says no turn is
    // running but a buffered ``status: requesting`` / stray
    // ``assistant_stream_snapshot`` re-armed the spinner or spawned
    // an empty streaming bubble, snap back to the quiescent state
    // and kill any shimmer. The daemon's ``turn_active`` is the
    // source of truth — the live buffer is chatter.
    if (mounted && !turnActive) {
      setState(() {
        _isSending = false;
        _statusPhase = '';
        _turnInProgress = false;
        _hadTokens = false;
        _finalizeOrphanStreamingBubbles();
        _currentMsg?.setStreamingState(false);
        _currentMsg?.setThinkingState(false);
        _currentMsg = null;
      });
      _spinnerWatchdog?.cancel();
      _spinnerWatchdog = null;
    }

    if (mounted) _scrollToBottom();
  }

  /// Clear [_isInterrupted] when a live event proves the session is
  /// active again (status running, token, thinking, tool lifecycle).
  /// Also resets the stuck-spinner watchdog — we just got an event,
  /// so the daemon is alive.
  void _noteLiveActivity() {
    if (_isInterrupted && mounted) {
      setState(() => _isInterrupted = false);
    }
    _armSpinnerWatchdog();
  }

  /// Re-arm the stuck-spinner watchdog. Called whenever we see a
  /// chat-level event. If no event arrives for
  /// [_stuckSpinnerThreshold] while `_isSending=true`, we forcibly
  /// reset the spinner so the user isn't stuck. Throttled to at
  /// most one re-arm every 2 seconds so a dense token stream
  /// doesn't churn Timers.
  void _armSpinnerWatchdog() {
    if (!_isSending) {
      _spinnerWatchdog?.cancel();
      _spinnerWatchdog = null;
      _lastWatchdogArm = null;
      return;
    }
    final now = DateTime.now();
    if (_lastWatchdogArm != null &&
        now.difference(_lastWatchdogArm!) < const Duration(seconds: 2)) {
      return;
    }
    _lastWatchdogArm = now;
    _spinnerWatchdog?.cancel();
    _spinnerWatchdog = Timer(_stuckSpinnerThreshold, () {
      if (!mounted || !_isSending) return;
      debugPrint('ChatPanel: spinner watchdog fired — clearing stuck state');
      setState(() {
        _isSending = false;
        _statusPhase = '';
        _turnInProgress = false;
      });
      _currentMsg?.setStreamingState(false);
      _currentMsg?.setThinkingState(false);
    });
  }

  /// Dispatch a single historical event. `preview:*` goes straight to
  /// [PreviewStore]; `turn_start` spawns a user bubble (since there is
  /// no live counterpart); everything else reuses the live handler.
  void _dispatchReplayEvent(
    String type,
    Map<String, dynamic> data, {
    int? seq,
  }) {
    // preview:* events bypass _onEvent (which ignores them).
    if (type.startsWith('preview:')) {
      PreviewStore().applyHistoryEvent(type, data);
      return;
    }

    if (type == 'turn_start') {
      // Finalise any previous assistant bubble and create the user
      // bubble that triggered this turn. The live path never emits
      // `turn_start` — the user's outgoing POST creates the bubble —
      // so this branch only runs during replay.
      if (_currentMsg != null) {
        _currentMsg!.setStreamingState(false);
        _currentMsg!.setThinkingState(false);
        _currentMsg = null;
      }
      final message = data['message'] as String? ?? '';
      if (message.isNotEmpty) {
        final um = ChatMessage(
          id: 'u-${_messages.length}',
          role: MessageRole.user,
          initialText: message,
          daemonSeq: (seq != null && seq > 0) ? seq : null,
        );
        _messages.add(um);
      }
      return;
    }

    // Normalise the daemon's `turn_end` to the existing `turn_complete`
    // handler so we don't duplicate the finalisation logic. Forward
    // the original `seq` so dedup and sortKey assignment both work
    // from the daemon's authoritative ordering.
    if (type == 'turn_end') {
      _onEvent({
        'type': 'turn_complete',
        'data': data,
        'seq': ?seq,
      }, fromReplay: true);
      return;
    }

    _onEvent({
      'type': type,
      'data': data,
      'seq': ?seq,
    }, fromReplay: true);
  }

  // ─── Session event handler (Socket.IO → SessionService.events) ──────────
  // The daemon sends status events with phase: turn_start, requesting,
  // tool_use, responding, turn_end. Use these directly for the spinner.
  // memory_update and agent_event come as dedicated events — no need to
  // extract them from tool_call results.
  // workbench_*, terminal_output, diagnostics → workspace panel only.

  void _onEvent(Map<String, dynamic> event, {bool fromReplay = false}) {
    final type = event['type'] as String? ?? '';
    final data = event['data'] as Map<String, dynamic>? ?? {};
    // Seq is carried at the envelope root — same contract for every
    // event (user_message, message_*, token, tool_*, thinking_*, etc.).
    // Defensive fallback into payload is intentional paranoia in case
    // an older daemon or a history-replay path puts it there.
    final envSeq = (event['seq'] as num?)?.toInt() ??
        (data['seq'] as num?)?.toInt() ??
        0;

    // ── Buffer live events while we are still replaying history ──────
    // MUST run BEFORE the dedup. Otherwise a live event that arrives
    // during the /history fetch registers its seq in ``_appliedSeqs``
    // and then gets buffered — when the SAME seq later comes up in
    // the replay from /history, dedup drops it, and when the drain
    // re-calls _onEvent on the buffered copy, dedup drops it too.
    // The event is doubly lost (exactly the missing user_message
    // bubbles observed: user_message / message_started seqs fired
    // live, were buffered, then neither the replay nor the drain
    // could apply them). Keep meta/connection events flowing so the
    // UI still reflects socket state. ``fromReplay`` is set by
    // ``_dispatchReplayEvent`` so replay events bypass the gate.
    if (_isReplaying &&
        !fromReplay &&
        !type.startsWith('_') &&
        type != 'connected' &&
        type != 'heartbeat') {
      _liveBuffer.add(event);
      return;
    }

    // Dedup by seq (event-spec §0 & §7 "dedup par seq"). An event
    // can legitimately arrive twice — live over Socket.IO AND via
    // replay at rejoin, or twice via a socket reconnect handshake.
    // Ephemeral events (token, thinking_delta, status, preview:*)
    // don't carry a persisted seq and are allowed through every
    // time; everything with a real seq goes through the set.
    if (envSeq > 0 && !_appliedSeqs.add(envSeq)) {
      return;
    }

    if (envSeq > _lastPersistedSeq) _lastPersistedSeq = envSeq;
    // Capture the envelope's ts so bubbles spawned by this event
    // (ensureBubble for the first token, etc.) can use it for
    // their displayed timestamp.
    _lastEventTs = _parseEventTs(event);
    // Low-volume verify line — filters out token/thinking_delta spam.
    if (type != 'token' && type != 'thinking_delta') {
      debugPrint('ChatPanel event: seq=$envSeq type=$type');
    }

    // ── Session isolation: ignore events from other sessions ─────────
    //
    // The upstream filter in [SessionService.injectSocketEvent]
    // already drops cross-session events, but `_currentSessionId` in
    // this widget lags `SessionService.activeSession` for one
    // microtask during a switch — compare against the live value so
    // events for the newly-active session are never dropped.
    //
    // Control/meta types (heartbeat, _connection_*, _session_meta) are
    // legitimately session-less — let them through. Every other type
    // reaching _onEvent carries chat-timeline state and MUST have a
    // session_id: an untagged error/user_message/status is a daemon
    // bug and would otherwise bleed into the currently-visible session.
    final eventSessionId = event['session_id'] as String? ??
        data['session_id'] as String? ?? '';
    final liveSessionId = SessionService().activeSession?.sessionId;
    final isControlType = type.startsWith('_') || type == 'heartbeat';
    if (!isControlType && eventSessionId.isEmpty) {
      debugPrint(
          'ChatPanel: dropping untagged session-scoped event type=$type');
      return;
    }
    // When no session is active (freshly opened app, welcome state),
    // drop every session-scoped event unconditionally — otherwise a
    // turn still finishing on a previous session (even one belonging
    // to the same app) injects bubbles into the empty welcome pane
    // and the user lands in what looks like that old transcript.
    if (eventSessionId.isNotEmpty &&
        (liveSessionId == null || eventSessionId != liveSessionId)) {
      return;
    }
    // And if the chat-panel's cached current session id doesn't match
    // the live one, skip mutating widget state — we'll get the event
    // again after `_onSessionChange` re-syncs in the next microtask.
    if (!isControlType && _currentSessionId != liveSessionId) {
      return;
    }

    // ── Preview events → handled by PreviewWorkspaceProvider ──────────
    if (type.startsWith('preview:')) return;

    // ── Widget events → forward to global event bus ─────────────────
    if (type.startsWith('widget:')) {
      widgets_service.WidgetEventBus().publishRaw(type, data);
      return;
    }

    // ── Post-join snapshots ───────────────────────────────────────────
    // The daemon ships 5 snapshot types right after the event replay
    // on `join_session` (tested live — see conv.md §join tests). The
    // preview / queue ones are already absorbed upstream; here we
    // sync the chat-visible ones so a user who leaves mid-turn and
    // comes back sees the authoritative latest state.
    if (type == 'memory:snapshot') {
      // Reuse the history-path helper by wrapping the payload in the
      // shape it expects.
      _restoreMemorySnapshot({'memory_snapshot': data});
      return;
    }
    if (type == 'session:snapshot') {
      // Update the local AppSession with the daemon's truth so the
      // sidebar title + preview + cost all reflect the freshest state.
      final sid = data['session_id'] as String? ?? _currentSessionId ?? '';
      if (sid.isEmpty) return;
      final title = (data['title'] as String?)?.trim() ?? '';
      if (title.isNotEmpty) {
        SessionService().updateSessionTitle(sid, title);
      }
      final interrupted = data['interrupted'];
      if (interrupted is bool && mounted) {
        setState(() => _isInterrupted = interrupted);
      }
      final turnRunning = data['turn_running'] == true;
      if (!turnRunning && mounted && _isSending) {
        // Authoritative "no turn running" — clear any stale spinner
        // we armed during the history replay heuristic.
        setState(() {
          _isSending = false;
          _turnInProgress = false;
          _statusPhase = '';
          _currentMsg?.setStreamingState(false);
          _currentMsg?.setThinkingState(false);
          _currentMsg = null;
        });
      }
      return;
    }
    if (type == 'active_ops:snapshot') {
      // Let the OpRegistry / session router handle the heavy
      // reconciliation if it's wired; here we only clear the chat
      // panel's transient flags when the server says zero ops are
      // running. Prevents a phantom spinner after a reopen.
      final count = (data['count'] as num?)?.toInt() ?? 0;
      if (count == 0 && mounted && _isSending) {
        setState(() {
          _isSending = false;
          _turnInProgress = false;
          _statusPhase = '';
          _currentMsg?.setStreamingState(false);
          _currentMsg?.setThinkingState(false);
          _currentMsg = null;
        });
      }
      return;
    }

    // ── Credential required (top-level event from daemon) ────────────
    // The daemon emits `type: credential_required` when an agent turn
    // fails because of a missing/expired/invalid credential. We also
    // accept the legacy `credential_auth_required` shape in case the
    // daemon still emits the old form somewhere. Handle them both
    // through the same picker path.
    if (type == 'credential_required' ||
        type == 'credential_auth_required') {
      _handleCredentialAuthRequired({...data, 'code': type});
      return;
    }

    // ── Internal session metadata (from checkAndResume) ───────────────
    if (type == '_session_meta') {
      // Restore workspace path from daemon session
      final workspace = data['workspace'] as String? ?? '';
      if (workspace.isNotEmpty && mounted) {
        context.read<AppState>().setWorkspace(workspace);
      }
      // Restore context state from daemon session
      final ctx = data['context'] as Map<String, dynamic>?;
      if (ctx != null) ContextState().updateFromJson(ctx);

      // Orphan skeleton cleanup. `_BlinkCursor` (the 3-line shimmer
      // placeholder in the assistant bubble, chat_bubbles.dart:4566)
      // renders whenever `_currentMsg.isStreaming && text.isEmpty`.
      // The drain-after-replay path can leave such a bubble behind
      // when the replay buffer contains a `status: responding` /
      // `token` that fires `_ensureBubble` but no matching terminal
      // event (`turn_complete` / `error` / `abort`) ever lands — a
      // typical shape when the daemon wrote ancillary events (hook,
      // memory_update, compaction) after the turn closed. `_session_meta`
      // fires AFTER the drain, so it's the safe place to clear that
      // orphan. If the session is genuinely active the upcoming live
      // events will spawn a fresh bubble immediately.
      final cur = _currentMsg;
      if (mounted &&
          cur != null &&
          cur.role == MessageRole.assistant &&
          cur.text.isEmpty &&
          cur.isStreaming) {
        setState(() {
          cur.setStreamingState(false);
          cur.setThinkingState(false);
          _currentMsg = null;
        });
      }

      // Phantom-spinner guard. The replay heuristic at line ~1017
      // arms `_isSending`/`_turnInProgress` when it sees an
      // unbalanced `turn_start` within the last 90 s — often wrong
      // when the daemon appended hooks/memory_update/compaction
      // events after the turn actually closed. `_session_meta`
      // carries the daemon's authoritative `is_active`; trust it
      // when it says the session isn't running.
      final isActive = data['is_active'] as bool? ?? false;
      if (!isActive && mounted) {
        setState(() {
          _isSending = false;
          _statusPhase = '';
          _turnInProgress = false;
          _hadTokens = false;
        });
      }
      return;
    }

    // ── Connection lost/restored ───────────────────────────────────────
    if (type == '_connection_lost') {
      if (mounted) {
        setState(() {
          _statusPhase = 'disconnected';
          // Clear pending approvals — they can't be sent while offline.
          // The daemon will re-emit them on reconnect if still pending.
          _pendingApprovals.clear();
          // Hide the trailing typing-dots row instantly — no point
          // pretending the agent is "thinking" while we're offline.
          // `_isSending` and `_turnInProgress` are kept on purpose
          // (the daemon may still finish the turn and replay events
          // on reconnect); `_turnReallyRunning` will gate the input
          // spinner via the `disconnected` phase check.
          _awaitingAgentResponse = false;
        });
      }
      return;
    }
    if (type == '_connection_restored') {
      if (mounted && _statusPhase == 'disconnected') {
        setState(() => _statusPhase = _isSending ? 'requesting' : '');
      }
      return;
    }

    // ── Infrastructure events (no bubble) ────────────────────────────
    if (type == 'connected') {
      // Per event-spec §4: daemon sends `connected` at handshake
      // with `latest_seq`. If it's smaller than our last-applied
      // seq the daemon has restarted (its counter reset) — our
      // local cache is invalid and we must reload from scratch via
      // GET /history.
      final latest = (event['latest_seq'] as num?)?.toInt() ??
          (data['latest_seq'] as num?)?.toInt() ??
          0;
      if (latest > 0 &&
          _lastPersistedSeq > 0 &&
          latest < _lastPersistedSeq) {
        debugPrint(
            'ChatPanel: daemon restart detected (latest=$latest < last=$_lastPersistedSeq) — reloading history');
        final session = SessionService().activeSession;
        if (session != null) {
          setState(() {
            _messages.clear();
            _messageKeys.clear();
            _appliedSeqs.clear();
            _lastPersistedSeq = 0;
            _currentMsg = null;
          });
          _tryRestoreAndConnect(session.appId, session.sessionId);
        }
      }
      return;
    }
    if (type == 'heartbeat') {
      return;
    }

    // ── Background task updates → handled by BackgroundService ────────
    if (type == 'bg_task_update') return;

    // ── Workspace-only events (not shown in chat) ────────────────────
    if (type.startsWith('workbench_') ||
        type == 'terminal_output' ||
        type == 'diagnostics') {
      WorkspaceService().handleEvent(type, data);
      final appState = context.read<AppState>();
      // Auto-open workspace panel
      if (!appState.isWorkspaceVisible) appState.showWorkspace();
      // Focus: file events → files tab, terminal → terminal tab, diag → diag tab
      // (WorkspaceService.handleEvent already sets activeTab)
      return;
    }

    // ── Memory update → sidebar only ─────────────────────────────────
    if (type == 'memory_update') {
      final action = data['action'] as String? ?? '';
      final result = data['result'] as Map<String, dynamic>? ?? data;
      WorkspaceState().handleMemoryUpdate(action, result);
      return;
    }

    // ── Agent event → sidebar + chat ─────────────────────────────────
    if (type == 'agent_event') {
      // Daemon sends { action, name, result: {agent_id, status, ...} }
      // Accept fields at root or nested in result for compat.
      final result = data['result'] as Map<String, dynamic>? ?? {};
      final agentId = data['agent_id'] as String?
          ?? result['agent_id'] as String?
          ?? '';
      final status = data['status'] as String?
          ?? result['status'] as String?
          ?? '';
      final action = data['action'] as String?
          ?? data['name'] as String?
          ?? '';

      // Map action to status if status is empty
      final effectiveStatus = status.isNotEmpty ? status : switch (action) {
        'spawn_agent'    => 'spawned',
        'agent_result'   => 'completed',
        'agent_cancel'   => 'cancelled',
        'agent_wait' || 'agent_wait_all' => 'running',
        _ => 'running',
      };

      final specialist = data['specialist'] as String?
          ?? result['specialist'] as String?
          ?? data['name'] as String?
          ?? '';
      final task = data['task'] as String?
          ?? result['task'] as String?
          ?? '';
      final duration = (data['duration_seconds'] as num?)?.toDouble()
          ?? (result['duration_seconds'] as num?)?.toDouble()
          ?? 0;
      final preview = data['preview'] as String?
          ?? result['preview'] as String?
          ?? '';
      final toolCallsCount = (data['tool_calls_count'] as num?)?.toInt()
          ?? (result['tool_calls_count'] as num?)?.toInt()
          ?? 0;
      final resultSummary = data['result_summary'] as String?
          ?? result['result_summary'] as String?;
      final agentError = data['error'] as String?
          ?? result['error'] as String?;
      final reason = data['reason'] as String?
          ?? result['reason'] as String?;
      final parentAgent = data['parent_agent'] as String?
          ?? result['parent_agent'] as String?;
      final waitingForRaw = data['waiting_for'] ?? result['waiting_for'];
      final waitingFor = waitingForRaw is List
          ? waitingForRaw.cast<String>()
          : null;

      if (agentId.isNotEmpty) {
        WorkspaceState().updateAgent(SubAgent(
          id: agentId,
          specialist: specialist,
          task: task,
          status: switch (effectiveStatus) {
            'spawned'   => AgentStatus.spawned,
            'running'   => AgentStatus.running,
            'completed' => AgentStatus.completed,
            'failed'    => AgentStatus.failed,
            'cancelled' => AgentStatus.cancelled,
            _           => AgentStatus.running,
          },
          duration: duration,
          preview: preview,
          parentAgent: parentAgent,
          toolCallsCount: toolCallsCount,
          resultSummary: resultSummary,
          error: agentError,
          reason: reason,
          waitingFor: waitingFor,
          updatedAt: DateTime.now(),
        ));
      }
      // Also show in chat bubble
      _ensureBubble();
      if (_currentMsg != null) {
        _currentMsg!.addAgentEvent(AgentEventData(
          agentId: agentId,
          status: effectiveStatus,
          specialist: specialist,
          task: task,
          duration: duration,
          preview: preview,
          toolCallsCount: toolCallsCount,
          resultSummary: resultSummary,
          error: agentError,
        ));
      }
      _scrollToBottom();
      return;
    }

    // ── Status → spinner + metrics ─────────────────────────────────────
    if (type == 'status') {
      final phase = data['phase'] as String? ?? '';
      // The daemon is talking — cancel the 30 s response watchdog
      // and the spinner watchdog (they are both "silence" timers).
      _responseTimeout?.cancel();
      // Any of these phases means the agent is currently turning —
      // re-arm `_isSending` so the Stop button reappears even when
      // the user just navigated back to a session that started
      // running in their absence.
      const liveTurnPhases = {
        'requesting',
        'generating',
        'planning',
        'executing',
        'responding',
        'thinking',
        'tool_use',
        'waiting',
        'compacting',
      };
      if (liveTurnPhases.contains(phase)) {
        _noteLiveActivity();
        // Never spawn a placeholder bubble on a status ping alone:
        //
        //   1. On a fresh session, a stale `responding` event
        //      arriving right after SSE reconnect would yank the
        //      empty-state UI off screen and start the typing
        //      skeleton before the user has typed anything.
        //   2. During an active turn, a `status: requesting`
        //      sometimes lands BEFORE the echoed `user_message`
        //      event that carries the canonical seq. If we created
        //      the assistant bubble here it would anchor to
        //      `_lastPersistedSeq` — often lower than the seq the
        //      user bubble ends up pinned to — and render ABOVE the
        //      user message with a stuck skeleton (no token ever
        //      lands in it because the real bubble gets created
        //      later when the first token arrives).
        //
        // We only flip `_isSending` here so the Stop button
        // reappears after a background-tab turn resumes. The bubble
        // itself is spawned lazily by the first content-bearing
        // event (`token`, `thinking_delta`, `tool_start`,
        // `message_started`, …) further down in this method.
        final conversationStarted =
            _messages.isNotEmpty || _isReplaying;
        if (conversationStarted && !_isSending) {
          _isSending = true;
        }
      }
      if (phase.isNotEmpty && mounted) {
        // For tool_use and rate_limited, include extra info
        String display = phase;
        if (phase == 'tool_use') {
          final tool = data['tool_name'] as String? ?? data['tool'] as String? ?? '';
          final detail = data['detail'] as String? ?? '';
          if (tool.isNotEmpty) display = 'tool_use:$tool${detail.isNotEmpty ? ':$detail' : ''}';
          // Remember the tool + its start time so the lean
          // tool-progress bar can tick a duration for any call
          // that runs longer than ~2 s.
          _setActiveTool(tool.isNotEmpty ? tool : 'tool');
        } else if (phase == 'rate_limited') {
          final attempt = data['attempt'] ?? '';
          final max = data['max'] ?? '';
          if (attempt.toString().isNotEmpty) display = 'rate_limited:$attempt/$max';
          _clearActiveTool();
        } else {
          // Any other phase (responding, generating, thinking…)
          // means the tool finished — drop the tracker.
          _clearActiveTool();
        }
        setState(() => _statusPhase = display);
      }
      // Metrics are polled from the API, not from SSE events
      if (phase == 'turn_start') {
        WorkspaceState().onTurnStart();
      }
      return;
    }

    // ── Ensure assistant bubble exists for remaining chat events ─────
    //
    // Skip for event types that are NOT agent-content carriers:
    //   • user_message / message_* — queue + user turn metadata
    //   • queue_* — queue lifecycle
    //   • approval_request — handled inline
    //   • credential_* — picker flow
    //
    // Spawning an agent bubble on those would give it a sortKey
    // seeded from the current seq, and it would land ABOVE the user
    // bubble once the user_message handler updates sortKeys.
    // Product rule (user spec): the "agent is thinking" 3-bar skeleton
    // lives inside an empty streaming assistant bubble. It must be
    // visible ONLY while the user is waiting for the agent's reply
    // (``_isSending=true``) — no other state may spawn a placeholder
    // bubble.
    //
    // Concretely:
    //   * ``_send()`` flips ``_isSending=true`` right after the user
    //     clicks Send → any event arriving AFTER that (status,
    //     user_message echo, token, thinking, tool_start, …) sees
    //     ``_isSending=true`` and can safely call ``_ensureBubble()``
    //     to spawn the placeholder. The FIRST content-bearing event
    //     within the same build pass fills the bubble → skeleton
    //     disappears.
    //   * When ``_isSending=false`` (session reopen, background-only
    //     activity, post-turn trailing events) the placeholder is
    //     never created — no phantom shimmer on session reopen.
    //   * Content handlers still call ``_ensureBubble()`` unconditionally
    //     at their own site (token / thinking / tool_start / snapshot)
    //     so daemon-initiated streams (cron, activation) still render
    //     even without a user click.
    if (_isSending &&
        !fromReplay &&
        !type.startsWith('_') &&
        type != 'heartbeat' &&
        type != 'connected' &&
        !type.startsWith('preview:') &&
        !type.startsWith('widget:') &&
        type != 'user_message' &&
        type != 'message_queued' &&
        type != 'message_done' &&
        type != 'message_cancelled' &&
        type != 'queue_cleared' &&
        type != 'queue_full' &&
        type != 'queue:snapshot' &&
        type != 'session:snapshot' &&
        type != 'active_ops:snapshot' &&
        type != 'memory:snapshot' &&
        type != 'memory_update' &&
        type != 'token_usage' &&
        type != 'token_count' &&
        type != 'approval_request' &&
        type != 'credential_required' &&
        type != 'credential_auth_required' &&
        type != 'error' &&
        type != 'abort' &&
        type != 'turn_complete' &&
        type != 'result' &&
        type != 'message_merged' &&
        type != 'message_replaced' &&
        // Hooks (compact_context, context_status, lsp_diagnose, log, …)
        // are sidebar / toast signals — must never spawn a chat bubble.
        type != 'hook' &&
        type != 'hook_notification' &&
        type != 'context_status') {
      _ensureBubble();
    }
    _responseTimeout?.cancel(); // Response received — cancel timeout
    // Any stream-level event proves the session is alive: clear a
    // stale interrupted badge from an earlier crash.
    _noteLiveActivity();

    // The "agent is thinking" skeleton stays visible until the FIRST
    // concrete sign of a response. ``status: requesting`` / echo
    // events don't count — they fire before the model has produced
    // anything. Content, error, or terminal events close the window.
    if (_awaitingAgentResponse && !fromReplay) {
      const responseStartedEvents = {
        'token', 'out_token',
        'thinking', 'thinking_started', 'thinking_delta',
        'tool_start', 'tool_call',
        'assistant_stream_snapshot',
        'agent_event',
        'result', 'turn_complete',
        'error', 'abort',
        'message_done', 'message_cancelled',
      };
      if (responseStartedEvents.contains(type)) {
        setState(() => _awaitingAgentResponse = false);
      }
    }

    switch (type) {
      // ── Thinking ───────────────────────────────────────────────────
      case 'thinking_started':
        _ensureBubble();
        // Open a fresh thinking block. `setThinkingState(true)` only
        // reactivates the LAST thinking block — wrong for multi-block
        // turns where each `thinking_started` should start a NEW one
        // with its own per-block token counter.
        _currentMsg?.beginThinkingBlock();
        if (mounted) setState(() => _statusPhase = 'thinking');
        _scrollToBottom();
        break;
      case 'thinking_delta':
        final delta = data['delta'] as String? ?? '';
        if (delta.isNotEmpty) {
          _ensureBubble();
          _currentMsg?.appendThinking(delta);
        }
        // Per-block live token count from daemon (litellm-tokenized,
        // scoped to THIS thinking block — does not include the text
        // response). Lands on whichever thinking block is currently
        // active so each section keeps its own counter.
        final c = data['count'];
        if (c is int && c > 0) {
          _ensureBubble();
          _currentMsg?.setActiveThinkingTokens(c);
        }
        _scrollToBottom();
        break;
      case 'thinking':
        final text = data['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _ensureBubble();
          _currentMsg?.setThinkingText(text);
        }
        // Final per-block count from the snapshot event. Pin it on
        // the block before the snapshot freezes it.
        final fc = data['count'];
        if (fc is int && fc > 0) {
          _ensureBubble();
          _currentMsg?.setActiveThinkingTokens(fc);
        }
        _scrollToBottom();
        break;

      // ── Tool call streaming (LLM is composing args, pre-execution)
      case 'tool_call_streaming':
        final callId = data['call_id'] as String? ?? '';
        final tName = data['name'] as String? ?? '';
        final c = data['count'];
        final cnt = (c is int) ? c : 0;
        if (callId.isNotEmpty) {
          _ensureBubble();
          _currentMsg?.upsertToolCallStreaming(
            callId: callId,
            toolName: tName,
            tokenCount: cnt,
          );
          if (mounted) setState(() => _statusPhase = 'executing');
        }
        _scrollToBottom();
        break;

      // ── Tool start ─────────────────────────────────────────────────
      case 'tool_start':
        // The streaming placeholder (if any) is swapped in-place by
        // ChatMessage.addOrUpdateToolCall — same timeline index, no
        // UI shift between the chip and the full card.
        final toolName = data['name'] as String? ?? 'tool';
        final display = data['display'] as Map<String, dynamic>?;
        final verb = display?['verb'] as String? ??
            data['label'] as String? ?? toolName;
        // Contract v2 — trust `display.hidden` when the daemon
        // provides a display block. Fall back to the legacy
        // name-based heuristic only for old daemons that omit
        // `display` entirely (spec §Découverte dynamique).
        final hidden = display?['hidden'] as bool? ??
            data['silent'] as bool? ?? false;
        final hideFromChat = display != null
            ? hidden
            : (hidden || _isHiddenTool(toolName));

        // Spinner phase only flips for visible tools — a hidden
        // plumbing tool (search_tools, spawn_agent, …) shouldn't flash
        // its internal name at the user. The scout confirmed these
        // always arrive with display.hidden=true, so the check below
        // keeps the previous phase ("Thinking…", etc.) for them.
        if (!hideFromChat) {
          final spinnerLabel = _friendlySpinnerLabel(
              toolName, verb, hasDisplay: display != null);
          if (mounted) setState(() => _statusPhase = spinnerLabel);
        }

        // Capture bash/shell command for terminal
        if (toolName.toLowerCase().contains('bash') ||
            toolName.toLowerCase().contains('shell')) {
          final params = data['params'] as Map<String, dynamic>? ?? {};
          final cmd = params['command'] as String? ?? params['cmd'] as String? ?? '';
          if (cmd.isNotEmpty) WorkspaceService().setPendingCommand(cmd);
        }

        if (!hideFromChat) {
          _ensureBubble();
          if (_currentMsg != null) {
            DigitornApiClient().handleStreamEvent(
                type, data, _currentMsg!,
                envelopeTs: event['ts'] as String?);
            _scrollToBottom();
          }
        }
        break;

      // ── Tool complete ──────────────────────────────────────────────
      case 'tool_call':
        final toolName = data['name'] as String? ?? '';
        final display = data['display'] as Map<String, dynamic>?;
        // Contract v2 — `display.hidden` is authoritative. Legacy
        // daemons without a display block fall back to the name
        // heuristic, same as tool_start.
        final hidden = display?['hidden'] as bool? ??
            data['silent'] as bool? ?? false;
        final category = display?['category'] as String? ?? '';
        if (mounted) setState(() => _statusPhase = 'responding');

        // Database tool_calls → forward to the passive observer service
        if (DatabaseService.isDatabaseTool(toolName)) {
          DatabaseService().handleToolCall(data);
        }

        final hideFromChat = display != null
            ? hidden
            : (hidden || _isHiddenTool(toolName));

        // Memory tools → always route to sidebar
        if (WorkspaceState.isMemoryTool(toolName) || category == 'memory') {
          final action = toolName.split(RegExp(r'[.__]')).last;
          final result = data['result'];
          if (result is Map<String, dynamic>) {
            WorkspaceState().handleMemoryUpdate(action, result);
          }
        }

        // Filesystem + bash tools → bridge into the workspace pipeline.
        // Scout bilan:
        //   * fs-tester / prod-coding-assistant emit tool_call with
        //     rich `result` but never `preview:*` — synthesize a
        //     resource_set so the CodeExplorer lights up.
        //   * Bash emits tool_call with stdout/stderr/exit_code/cwd
        //     AND a follow-up `terminal_output` envelope that drops
        //     everything but stdout/stderr. We ingest the richer
        //     tool_call.result directly and dedupe the terminal_output.
        {
          final ok = data['success'] == true ||
              (data['error'] as String? ?? '').isEmpty;
          if (ok) {
            final rawParams = data['params'];
            final rawResult = data['result'];
            if (rawParams is Map<String, dynamic> &&
                rawResult is Map<String, dynamic>) {
              PreviewStore().ingestToolCall(
                toolName: toolName,
                params: rawParams,
                result: rawResult,
                display: display,
              );
              final channel = display?['channel'] as String? ?? '';
              final group = display?['group'] as String? ?? '';
              final lname = toolName.toLowerCase();
              final isBash = channel == 'terminal'
                  || group == 'shell'
                  || lname.contains('bash')
                  || lname.contains('shell');
              if (isBash) {
                WorkspaceService()
                    .ingestBashToolCall(rawParams, rawResult);
              }
            }
          }
        }

        if (!hideFromChat) {
          _ensureBubble();
          if (_currentMsg != null) {
            DigitornApiClient().handleStreamEvent(
                type, data, _currentMsg!,
                envelopeTs: event['ts'] as String?);
            _scrollToBottom();
          }
        }
        break;

      // ── Text tokens (update spinner) ───────────────────────────────
      case 'token':
        _hadTokens = true;
        if (mounted && !_statusPhase.startsWith('tool_use:') &&
            _statusPhase != 'thinking' &&
            _statusPhase != 'responding') {
          setState(() => _statusPhase = 'responding');
        }
        // Lazy-create the bubble for daemon-initiated streams (cron,
        // background triggers, post-reconnect mid-turn). For user
        // sends, the bubble already exists from ``_send()``.
        _ensureBubble();
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(
              type, data, _currentMsg!,
              envelopeTs: event['ts'] as String?);
          _maybeExtractStreamingArtifacts(_currentMsg!);
        }
        _scrollToBottom();
        break;

      // ── Stream done ────────────────────────────────────────────────
      case 'stream_done':
        _currentMsg?.setThinkingState(false);
        break;

      // ── Accumulated-content snapshot (persisted) ───────────────────
      // Per event-spec §3C: the daemon emits this for two purposes:
      //   * Replay — after rejoining a mid-turn session, to convey the
      //     full accumulated text so far in one shot.
      //   * Live streaming — the scout confirmed they land periodically
      //     (every ~50 ms of streaming, every ~100 chars) to persist
      //     progress server-side. Each snapshot is the FULL content at
      //     its seq, not a delta.
      //
      // Race: during live streaming, token deltas race with snapshots.
      // A snapshot at seq=X may arrive while the local bubble has
      // already accumulated tokens past X (wire reorder, batching).
      // Adopting a SHORTER snapshot would visibly shrink the bubble.
      // Guard with `length >= current` so replay always wins (empty
      // bubble) but live interleave never flickers.
      case 'assistant_stream_snapshot':
        _ensureBubble();
        final snapshotContent = data['content'] as String? ?? '';
        if (_currentMsg != null && snapshotContent.isNotEmpty) {
          if (snapshotContent.length >= _currentMsg!.text.length) {
            _currentMsg!.replaceText(snapshotContent);
          }
          _hadTokens = true;
        }
        break;

      // ── Token counts ───────────────────────────────────────────────
      case 'out_token':
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(
              type, data, _currentMsg!,
              envelopeTs: event['ts'] as String?);
        }
        break;
      case 'in_token':
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(
              type, data, _currentMsg!,
              envelopeTs: event['ts'] as String?);
        }
        break;

      // ── Hook (context_status, compaction) ─────────────────────────
      case 'hook':
        final actionType = data['action_type'] as String?
            ?? data['action'] as String?
            ?? data['event'] as String?
            ?? '';
        final phase = data['phase'] as String? ?? '';
        final details = data['details'] as Map<String, dynamic>? ?? {};
        // The envelope's authoritative seq — threaded to the
        // compaction bubble so it anchors at its canonical position
        // in the timeline instead of drifting to the current max
        // (scout-verified: a compaction hook can fire with ~1k
        // higher-seq envelopes still buffered behind it).
        final envSeq = (event['seq'] as num?)?.toInt();

        if (actionType == 'context_status') {
          ContextState().updateFromJson(details);
          SessionMetrics().updateContext(details);
        } else if (actionType == 'compact_context' && phase == 'start') {
          // Compaction started — show compacting spinner in status bar
          // AND an in-progress line in the chat so the user sees
          // exactly what's happening, not just a cryptic phase change.
          if (mounted) setState(() => _statusPhase = 'compacting');
          _onCompactionStarted(details, envelopeSeq: envSeq);
        } else if (actionType == 'compact_context' && phase == 'end') {
          _onCompactionCompleted(details,
              emergency: false, envelopeSeq: envSeq);
        } else if (actionType == 'emergency_compaction') {
          _onCompactionCompleted(details,
              emergency: true, envelopeSeq: envSeq);
        }
        break;

      // ── Result → turn complete ─────────────────────────────────────
      case 'result':
      case 'turn_complete':
        final content = data['content'] as String? ?? '';
        final resultError = data['error'] as String?;
        // Some providers don't stream — they emit the full reply as a
        // single ``result.content`` with no preceding ``token`` events.
        // During replay (and live on non-streaming providers), this is
        // the ONLY chance to materialise the assistant bubble, so
        // lazy-create it here when there's content and no current
        // bubble. Without this, history replay loses every non-streamed
        // assistant message.
        if (!_hadTokens && content.isNotEmpty) {
          _ensureBubble();
          _currentMsg?.appendText(content);
        }
        // Scout bilan: some agents (digitorn-builder coordinator)
        // ship a final `thinking` snapshot that concatenates the
        // response text onto the chain-of-thought. We excise it
        // here — `result.content` is the clean source of truth.
        if (content.isNotEmpty && _currentMsg != null) {
          _currentMsg!.stripThinkingOverlap(content);
        }
        _currentMsg?.setStreamingState(false);
        _currentMsg?.setThinkingState(false);
        // Desktop notification — skip during replay so old turns
        // don't trigger banners days after the fact.
        if (!_isReplaying) {
          NotificationService().onTurnComplete(content: content, error: resultError);
        }
        // Context state from daemon (try 'context' field, then inside 'usage').
        // `result.context` is the stable post-turn baseline — trust it
        // UNCONDITIONALLY via `authoritative: true` so it can overwrite
        // the noisy mid-turn hook pressures (the scout confirmed hook
        // events oscillate 0.02 → 0.44 → 0.02 within a single turn,
        // which would otherwise pin the ring at the spike).
        final ctx = data['context'] as Map<String, dynamic>?
            ?? (data['usage'] as Map<String, dynamic>?)?['context'] as Map<String, dynamic>?;
        if (ctx != null) {
          ContextState().updateFromJson(ctx, authoritative: true);
          SessionMetrics().updateContext(ctx);
        }
        // Fallback — a `usage` block carrying the full aggregate shape
        // (effective_max > 0) is treated as authoritative too. A
        // `usage` block with only `pressure` is a per-turn delta and
        // intentionally skipped; the scout confirmed those are mid-turn
        // noise and would blank the ring ("0 % after turn" regression).
        final usage = data['usage'] as Map<String, dynamic>?;
        if (ctx == null &&
            usage != null &&
            (usage['effective_max'] as num? ?? 0) > 0) {
          ContextState().updateFromJson(usage, authoritative: true);
        }
        final wsStatus = data['workspace_status'] as Map<String, dynamic>?;
        if (wsStatus != null) WorkspaceService().updateGitStatus(wsStatus);
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(
              type, data, _currentMsg!,
              envelopeTs: event['ts'] as String?);
        }
        if (_currentMsg != null &&
            _currentMsg!.role == MessageRole.assistant &&
            _currentMsg!.text.isNotEmpty) {
          try {
            final extraction = ArtifactDetector.extract(
              messageId: _currentMsg!.id,
              text: _currentMsg!.text,
            );
            ArtifactService()
                .upsertForMessage(_currentMsg!.id, extraction.artifacts);
          } catch (e, st) {
            debugPrint('artifact extraction failed: $e\n$st');
          }
        }
        _currentMsg = null;
        _hadTokens = false;
        _responseTimeout?.cancel();
        // Sweep any leftover empty-streaming assistant bubbles so
        // their typing skeletons stop animating at turn's end.
        _finalizeOrphanStreamingBubbles();
        // Mark all remaining active agents as completed
        WorkspaceState().finishAllAgents();
        // Keep `_isSending` armed if there's still work ahead in the
        // queue — the daemon will auto-dispatch the next message in
        // ~200 ms (fires `message_started`) and the ring should stay
        // lit through that gap instead of flickering off and on.
        final sidForTurn =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        // "More work ahead?" = is there a QUEUED message waiting to
        // be dispatched. We explicitly DON'T include the running
        // entry in this check — that's this very turn, which is
        // completing right now. If we did include it the spinner
        // would stay lit forever whenever there was no queued
        // follow-up (running never flips to null until
        // `message_done` lands, which is AFTER turn_complete).
        final hasMoreWork = sidForTurn.isNotEmpty &&
            QueueService().pendingCountFor(sidForTurn) > 0;
        if (mounted) {
          setState(() {
            if (!hasMoreWork) _isSending = false;
            _statusPhase = hasMoreWork ? 'requesting' : '';
          });
        }
        _clearActiveTool();
        _scrollToBottom();
        // Daemon picks the next queued message on its own; the
        // `message_started` event will drive our UI transition.
        break;

      // ── Error (structured from daemon) ────────────────────────────
      case 'error':
        debugPrint('[ERROR_EVENT] received payload=${data.toString().substring(0, (data.toString().length > 200 ? 200 : data.toString().length))}');
        _responseTimeout?.cancel();
        final code = data['code'] as String? ??
            data['error'] as String? ??
            '';
        // Special case: missing credential / grant. We don't surface
        // this as a red error — it's a normal first-use moment. Pop
        // the picker, buffer the original message, retry on success.
        if (code == 'credential_auth_required' ||
            code == 'credential_required') {
          _handleCredentialAuthRequired({...data, 'code': code});
          break;
        }
        final daemonErr = DaemonError.fromJson(data);
        _currentMsg?.setStreamingState(false);
        _currentMsg?.setThinkingState(false);
        _currentMsg = null;
        _hadTokens = false;
        _finalizeOrphanStreamingBubbles();
        // FULL SWEEP — same rationale as `message_done`. An error mid-
        // tool / mid-thinking can leave zombie active states unless we
        // clean them up here too. Mirror of the web full sweep.
        for (final m in _messages) {
          if (m.role != MessageRole.assistant) continue;
          if (m.isStreaming) m.setStreamingState(false);
          if (m.hasOpenToolStart) m.markToolStartsInterrupted();
        }
        WorkspaceState().finishAllAgents();
        // Persistent inline marker in the history so the error is
        // visible when the user scrolls back — the top banner is
        // transient and only shown for LIVE turns. The daemon never
        // re-sees this marker because it lives in the client's
        // ``_messages`` list, not in ``session.messages``.
        final errEnvSeq = (event['seq'] as num?)?.toInt();
        final errLabel = daemonErr.category.isNotEmpty
            ? '${daemonErr.category}: ${daemonErr.error}'
            : daemonErr.error;
        _addSystemMarker(
          idPrefix: 'error',
          text: 'Turn failed — $errLabel',
          envelopeSeq: errEnvSeq,
        );
        if (mounted) {
          setState(() {
            _isSending = false;
            _statusPhase = '';
            // Stop the typing-dots row in lockstep — `_awaitingAgentResponse`
            // outliving the error frame would have left the dots
            // bouncing under the red banner until the next user action.
            _awaitingAgentResponse = false;
            _turnInProgress = false;
            // Banner only for LIVE errors, not replay — replay would
            // pop a stale red banner on every session reopen.
            if (!fromReplay) _activeError = daemonErr;
          });
        }
        break;

      // ── Abort (daemon confirmed abort) ────────────────────────────
      case 'abort':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onAbort(sid, data);
        // Persistent inline marker — visible when scrolling history.
        final abortEnvSeq = (event['seq'] as num?)?.toInt();
        final reason = (data['reason'] as String? ?? '').trim();
        _addSystemMarker(
          idPrefix: 'abort',
          text: reason.isEmpty
              ? 'Turn interrupted by user'
              : 'Turn interrupted — $reason',
          envelopeSeq: abortEnvSeq,
        );
        // Soft abort (default): the daemon will emit `message_started`
        // for the next queued message within ~200 ms, so we only tear
        // down the spinner UI if the queue was explicitly purged OR
        // there's nothing pending to take over.
        final queuePurged = (data['queue_purged'] as num?)?.toInt() ?? 0;
        final hasPending = sid.isNotEmpty &&
            QueueService().pendingCountFor(sid) > 0;
        if (queuePurged > 0 || !hasPending) {
          _handleAbortCleanup();
        } else {
          // Keep spinner armed — but drop the stale assistant bubble
          // so the next message_started spawns a fresh one at the
          // bottom instead of streaming into the aborted turn's card.
          if (_currentMsg != null) {
            _currentMsg!.setStreamingState(false);
            _currentMsg!.setThinkingState(false);
            _currentMsg = null;
          }
          setState(() => _statusPhase = 'aborting');
        }
        break;

      // ── Authoritative user-message event ──────────────────────────
      //
      // Fires from the daemon the moment a user turn is appended to
      // session history (both fast-path and queue-drain) and on
      // replay after a reload. Our optimistic bubble carries the
      // matching `client_message_id`; on echo we pin its `sortKey`
      // to the daemon's `seq` and attach the `correlation_id`.
      case 'user_message':
        final content = data['content'] as String? ?? '';
        if (content.isEmpty) break;
        final envSeq = (event['seq'] as num?)?.toInt() ?? 0;
        if (envSeq > _lastPersistedSeq) _lastPersistedSeq = envSeq;
        final cmid = data['client_message_id'] as String?;
        final corrId = data['correlation_id'] as String?;
        final isPending = data['pending'] == true;

        final existing = logic.findUserBubbleToReconcile(
          _messages,
          clientMessageId: cmid,
          correlationId: corrId,
          content: content,
        );
        if (existing != null) {
          setState(() {
            existing.correlationId = corrId ?? existing.correlationId;
            existing.clientMessageId ??= cmid;
            existing.pending = isPending;
            // Reconciliation: pin the optimistic bubble to the
            // daemon's authoritative seq. sortKey flips from the
            // provisional micro-tick (tail) to `envSeq`, slotting
            // the bubble at its canonical chronological position.
            if (envSeq > 0) _pinBubbleSeq(existing, envSeq);
            _pinOrphanAssistantAbove(envSeq);
          });
          _scrollToBottom();
          break;
        }

        // No matching optimistic bubble.
        //
        // Branch on `pending`:
        //   * `pending: true`  → the daemon is queueing this message
        //     behind a running turn. Per product contract the chat
        //     timeline must stay clean — the message lives only in
        //     the queue panel until execution actually starts. We
        //     buffer the payload keyed by correlation_id and flush
        //     it into a bubble when the matching `message_started`
        //     event arrives.
        //   * `pending: false` → fast-path, cross-tab send, or
        //     replay. Create the bubble immediately at the daemon's
        //     authoritative seq.
        if (isPending && corrId != null && corrId.isNotEmpty) {
          _queuedUserMessages[corrId] = _QueuedUserMessage(
            content: content,
            clientMessageId: cmid,
          );
          break;
        }

        final userMsg = ChatMessage(
          id: _nextMsgId('u'),
          role: MessageRole.user,
          initialText: content,
          timestamp: _parseEventTs(event),
          correlationId: corrId,
          clientMessageId: cmid,
          daemonSeq: envSeq > 0 ? envSeq : null,
          anchorSeq: _anchorForNewLocalBubble(),
        );
        userMsg.pending = isPending;
        setState(() {
          _messages.add(userMsg);
          _pinOrphanAssistantAbove(envSeq);
          _resortMessages();
        });

        final session = SessionService().activeSession;
        final firstUser = _messages
                .where((m) => m.role == MessageRole.user)
                .length ==
            1;
        if (firstUser && session != null && session.title.isEmpty) {
          final title = content.length > 60
              ? '${content.substring(0, 60)}…'
              : content;
          SessionService().updateSessionTitle(session.sessionId, title);
        }
        _scrollToBottom();
        break;

      // ── Queue events (daemon-persisted message queue) ─────────────
      case 'message_queued':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onMessageQueued(sid, data);
        break;
      case 'message_merged':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onMessageMerged(sid, data);
        break;
      case 'message_replaced':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onMessageReplaced(sid, data);
        break;
      case 'message_started':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onMessageStarted(sid, data);
        final envSeq = (event['seq'] as num?)?.toInt() ?? 0;
        if (envSeq > _lastPersistedSeq) _lastPersistedSeq = envSeq;
        final corrId = data['correlation_id'] as String?;

        // Flush any queued user_message buffered for this
        // correlation_id — this is the moment the daemon actually
        // injects the message into the chat. Bubble is placed at
        // `envSeq` so it lands at the point in the timeline where
        // execution started, not where it was recorded.
        if (corrId != null && corrId.isNotEmpty) {
          final buffered = _queuedUserMessages.remove(corrId);
          if (buffered != null) {
            // Use the message_started envelope's ts for the bubble
            // timestamp — that's the moment the daemon actually
            // injected this message into the chat timeline (what
            // matches the bubble's visual position).
            final userMsg = ChatMessage(
              id: _nextMsgId('u'),
              role: MessageRole.user,
              initialText: buffered.content,
              timestamp: _parseEventTs(event),
              correlationId: corrId,
              clientMessageId: buffered.clientMessageId,
              daemonSeq: envSeq > 0 ? envSeq : null,
              anchorSeq: _anchorForNewLocalBubble(),
            );
            setState(() {
              _messages.add(userMsg);
              _resortMessages();
            });
            _scrollToBottom();
          }
        }

        // Un-dim any matching optimistic bubble (pending → active).
        // Wrap in setState so the UI actually rebuilds — without it
        // the bubble kept its dimmed look until the next unrelated
        // rebuild.
        if (corrId != null && corrId.isNotEmpty) {
          bool changed = false;
          for (final m in _messages) {
            if (m.role == MessageRole.user &&
                m.correlationId == corrId &&
                m.pending) {
              m.pending = false;
              changed = true;
              break;
            }
          }
          if (changed && mounted) {
            setState(() {});
          }
        }
        if (_currentMsg != null && envSeq > 0) {
          _pinBubbleSeq(_currentMsg!, envSeq);
        }
        if (mounted) {
          setState(() {
            _isSending = true;
            _activeError = null;
            if (_statusPhase.isEmpty) _statusPhase = 'requesting';
          });
          _armSpinnerWatchdog();
        }
        break;
      case 'message_done':
      // Alternative terminal event names some daemon variants emit —
      // route them through the same cleanup so an unknown name can't
      // leave the spinner zombieing.
      case 'agent_done':
      case 'message_complete':
      case 'chat_complete':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onMessageDone(sid, data);
        // FULL SWEEP — every assistant bubble's `isStreaming` is
        // forced false and every tool call still in `started` state
        // is force-completed. Strict mirror of the web full sweep.
        // Without this, a stale `isStreaming` flag (event lost on
        // reconnect / out-of-order delivery / unknown event name)
        // could keep `_turnReallyRunning` true forever and zombie
        // the send-button ring.
        for (final m in _messages) {
          if (m.role != MessageRole.assistant) continue;
          if (m.isStreaming) m.setStreamingState(false);
          if (m.hasOpenToolStart) m.markToolStartsInterrupted();
        }
        // Safety net: after the queue prunes the finished entry, if
        // the session is truly idle (no running turn, no queued
        // follow-up, no in-flight streaming bubble) and the spinner
        // is somehow still armed, clear it. Prevents the
        // "ring-keeps-spinning-after-last-turn" regression when
        // turn_complete misses the reset.
        if (sid.isNotEmpty &&
            _isSending &&
            _currentMsg == null &&
            QueueService().pendingCountFor(sid) == 0 &&
            QueueService().runningFor(sid) == null) {
          if (mounted) {
            setState(() {
              _isSending = false;
              _statusPhase = '';
            });
          }
        }
        break;
      case 'message_cancelled':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onMessageCancelled(sid, data);
        // Drop any buffered user_message for this corrId — it was
        // queued, aborted before the daemon could pick it up, and
        // therefore must never produce a chat bubble.
        final cancelledCorrId = data['correlation_id'] as String?;
        if (cancelledCorrId != null && cancelledCorrId.isNotEmpty) {
          _queuedUserMessages.remove(cancelledCorrId);
        }
        break;
      case 'queue_cleared':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onQueueCleared(sid);
        // Clear the whole buffer — the queue panel just had every
        // pending entry wiped by the user (or the daemon), so any
        // user_message we were holding back for them must die too.
        _queuedUserMessages.clear();
        break;
      case 'queue_full':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        if (sid.isNotEmpty) QueueService().onQueueFull(sid, data);
        break;

      // ── Queue snapshot (hydration + post-reconnect reconcile) ────
      //
      // Scout-verified: daemon emits this on `join_session` with the
      // authoritative state of the session's turn lifecycle:
      //   {is_active: bool, running_correlation_id: str?,
      //    depth: int,    entries: [queue entries...]}
      //
      // We use it to reconcile UI state after a reconnect / mid-turn
      // disconnect. If the daemon says "no turn running" but our
      // local state still has an in-flight assistant bubble or an
      // open tool_start without its tool_call echo, we finalize them
      // as interrupted so the user isn't staring at a stale spinner.
      case 'queue:snapshot':
        final sid =
            event['session_id'] as String? ?? _currentSessionId ?? '';
        final isActive = data['is_active'] == true;
        final runningCorr = data['running_correlation_id'] as String?;
        _onQueueSnapshot(sid, isActive: isActive, runningCorr: runningCorr);
        break;

      // ── Approval request ───────────────────────────────────────────
      case 'approval_request':
        if (mounted) {
          final reqId = data['request_id'] as String? ?? _nextMsgId('appr');
          // Skip if not for the current session
          final eventSessionId = data['session_id'] as String? ??
              event['session_id'] as String? ?? '';
          if (eventSessionId.isNotEmpty && eventSessionId != _currentSessionId) break;
          // Skip if already pending (duplicate event)
          if (_pendingApprovals.any((a) => a.id == reqId)) break;
          final req = ApprovalRequest(
            id: reqId,
            agentId: data['agent_id'] as String? ?? '',
            toolName: data['tool_name'] as String? ?? data['tool'] as String? ?? 'unknown',
            params: Map<String, dynamic>.from(data['tool_params'] ?? data['params'] ?? {}),
            riskLevel: data['risk_level'] as String? ?? 'medium',
            description: data['description'] as String? ?? '',
            createdAt: (data['created_at'] as num?)?.toDouble(),
          );
          setState(() => _pendingApprovals.add(req));
          // If ask_user with long content, open in workspace
          if (req.isAskUser && req.hasLongContent) {
            _openAskUserContent(req);
          }
          // Silent anchor marker — empty text, rendered as a zero-sized
          // SizedBox by ``_SystemMessage``. Exists solely so the item
          // builder can match its id against ``_approvalMarkerReqId``
          // and upgrade the row to the interactive banner while the
          // request is pending. Once resolved the row disappears from
          // the timeline (see ``approval_resolved`` below) — the user
          // asked for no "Approval requested / granted" text trail.
          final apprEnvSeq = (event['seq'] as num?)?.toInt();
          final markerId = _addSystemMarker(
            idPrefix: 'approval-req',
            text: '',
            envelopeSeq: apprEnvSeq,
          );
          if (markerId != null) {
            _approvalMarkerReqId[markerId] = reqId;
          }
        }
        break;

      // ── Approval resolved ─────────────────────────────────────────
      case 'approval_resolved':
      case 'approval_progress':
        final reqId = data['request_id'] as String? ??
            data['approval_id'] as String? ?? '';
        // Drop the resolved request from the pending list so the
        // inline card disappears (both live and at replay). Also
        // clean the silent marker row + its lookup entry so no
        // zero-height ghost stays in the timeline. No verdict text
        // marker is appended — the tool_call event that follows
        // carries the outcome already.
        if (reqId.isNotEmpty) {
          setState(() {
            _pendingApprovals.removeWhere((a) => a.id == reqId);
            final markerIds = _approvalMarkerReqId.entries
                .where((e) => e.value == reqId)
                .map((e) => e.key)
                .toList();
            for (final mid in markerIds) {
              _approvalMarkerReqId.remove(mid);
              _messages.removeWhere((m) => m.id == mid);
            }
          });
        }
        break;

      // ── Unhandled → ignore ─────────────────────────────────────────
      default:
        break;
    }
  }

  /// Handle an inbound widget event from the runtime bus. Only
  /// events with `zone: "inline"` (or no zone) are our concern —
  /// the others (chat_side, workspace, modal) route themselves
  /// through their own mounted hosts.
  void _onWidgetEvent(widgets_models.WidgetEvent event) {
    if (!mounted) return;
    final zone = event.zone;
    if (zone != null && zone != 'inline') return;

    final widgetId = event.widgetId;
    if (widgetId == null || widgetId.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (event.kind) {
        case 'render':
          _mountInlineWidget(event);
          break;
        case 'update':
          break;
        case 'close':
          setState(() {
            for (final m in _messages) {
              if (m.role == MessageRole.assistant) {
                m.removeWidget(widgetId);
              }
            }
          });
          break;
        case 'error':
          break;
      }
    });
  }

  /// Resolve a `widget:render` event into a [WidgetPaneSpec] and
  /// attach it to the current (or a newly-created) assistant bubble.
  ///
  /// Resolution order:
  ///   1. `tree:` inlined in the event → wrap in a [WidgetPaneSpec]
  ///   2. `ref:` → lookup `AppState.activeAppWidgets.inline[ref]`
  ///   3. otherwise, ignore (malformed)
  void _mountInlineWidget(widgets_models.WidgetEvent event) {
    final appState = context.read<AppState>();
    widgets_models.WidgetPaneSpec? pane;
    final inlineTree = event.tree;
    if (inlineTree != null) {
      pane = widgets_models.WidgetPaneSpec(tree: inlineTree);
    } else {
      final ref = event.ref;
      if (ref != null && ref.isNotEmpty) {
        pane = appState.activeAppWidgets.inline[ref];
      }
    }
    if (pane == null) return;

    final payload = InlineWidgetPayload(
      widgetId: event.widgetId!,
      paneSpec: pane,
      ctx: event.ctx ?? const {},
    );

    // Target the current in-progress assistant bubble when a turn
    // is streaming. Otherwise create a standalone bubble for the
    // widget (agent emitted it between turns).
    setState(() {
      final target = _currentMsg ??
          () {
            final msg = ChatMessage(
              id: 'w_${event.widgetId}_${DateTime.now().millisecondsSinceEpoch}',
              role: MessageRole.assistant,
              anchorSeq: _anchorForNewLocalBubble(),
            );
            _messages.add(msg);
            return msg;
          }();
      target.addOrUpdateWidget(payload);
    });
    _scrollToBottom();
  }

  /// Handle the daemon's `credential_auth_required` SSE error.
  /// Buffers the user's last message, opens the picker dialog, and
  /// resends the message on success so the second turn flows
  /// silently. Failures and dismissals just abort the current turn
  /// like a normal error would.
  Future<void> _handleCredentialAuthRequired(
      Map<String, dynamic> data) async {
    _responseTimeout?.cancel();
    _currentMsg?.setStreamingState(false);
    _currentMsg?.setThinkingState(false);
    // Drop the half-built assistant bubble — the picker is a
    // standalone modal, no chat trace needed.
    if (_currentMsg != null) {
      setState(() {
        _messages.remove(_currentMsg);
        _currentMsg = null;
      });
    }
    _hadTokens = false;
    WorkspaceState().finishAllAgents();
    if (mounted) {
      setState(() {
        _isSending = false;
        _statusPhase = '';
      });
    }

    // The daemon payload may omit `app_id` — if so, fall back to
    // the currently-active session's app. Without this the grant
    // would be stored with an empty app id and the daemon would
    // never match it back to the requesting app, re-emitting the
    // same credential_required event in a tight loop.
    final activeSession = SessionService().activeSession;
    final enrichedData = {
      ...data,
      if ((data['app_id'] as String?)?.trim().isEmpty ?? true)
        'app_id': activeSession?.appId ??
            context.read<AppState>().activeApp?.appId ??
            '',
    };
    final event = CredentialAuthRequiredEvent.fromJson(enrichedData);

    // Loop guard: if the daemon keeps re-emitting credential_required
    // for the same provider/app even though we successfully granted,
    // the daemon's turn-time credential lookup is broken. Break out
    // after 2 attempts and surface a clear error instead of opening
    // the picker a third time forever.
    final retryKey = '${event.provider}|${event.appId}';
    if (_credentialRetryKey == retryKey) {
      _credentialRetryCount++;
    } else {
      _credentialRetryKey = retryKey;
      _credentialRetryCount = 1;
    }
    if (_credentialRetryCount > 2) {
      debugPrint('[creds] loop detected for $retryKey — aborting');
      _credentialRetryCount = 0;
      _credentialRetryKey = '';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Credential granted but daemon keeps asking — this is a daemon-side bug. Check daemon logs.',
            ),
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
      return;
    }

    final activeSessionId = SessionService().activeSession?.sessionId;
    final pending = activeSessionId != null
        ? SessionService().pendingFor(activeSessionId)
        : null;
    final bufferedText = pending?.message ?? _lastUserText;
    if (!mounted) return;
    final ok = await CredentialPickerDialog.show(context, event: event);
    if (!mounted) return;
    if (!ok) {
      // User cancelled the picker. Surface a discreet toast so they
      // know why nothing happened and put the original text back in
      // the input so they can retry manually.
      if (bufferedText.isNotEmpty) {
        _ctrl.text = bufferedText;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Message not sent — ${event.providerLabel.isNotEmpty ? event.providerLabel : event.provider} credential required',
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Re-send the original message — same path as a normal user
    // submission so the spinner reappears, the SSE continues, etc.
    if (bufferedText.isNotEmpty) {
      _ctrl.text = bufferedText;
      unawaited(_send());
      // Clear the stashed pending once we've re-submitted; the new
      // send will overwrite it anyway, but belt-and-braces so a
      // second credential event doesn't accidentally resurrect it.
      if (activeSessionId != null) {
        SessionService().clearPending(activeSessionId);
      }
    }
  }

  /// True when [msg] is an assistant bubble that never got any
  /// content (no text, no thinking, no tool calls, no agent events,
  /// no inline widgets) but is still flagged as streaming. These are
  /// the orphans that would render a stuck typing-skeleton forever
  /// because tokens would land in a NEW bubble instead.
  ///
  /// Must mirror the `isEmptyStreaming` predicate used by the
  /// typing-skeleton renderer in `chat_bubbles.dart`: if either side
  /// diverges, we either leave skeletons animating on bubbles that
  /// won't get adopted, or we adopt bubbles that are actually showing
  /// a widget the user already sees (which would then grow a
  /// second render of the same content).
  bool _isOrphanStreamingAssistant(ChatMessage msg) {
    if (msg.role != MessageRole.assistant) return false;
    if (!msg.isStreaming) return false;
    if (msg.text.isNotEmpty) return false;
    if (msg.thinkingText.isNotEmpty) return false;
    if (msg.toolCalls.isNotEmpty) return false;
    if (msg.agentEvents.isNotEmpty) return false;
    for (final b in msg.timeline) {
      if (b.type == ContentBlockType.widget) return false;
    }
    return true;
  }

  /// Sweep every orphan streaming assistant bubble in [_messages] —
  /// flip `isStreaming` / `isThinking` to false so the typing skeleton
  /// stops animating. Called from every terminal turn handler
  /// (turn_complete, error, abort cleanup, session:snapshot with
  /// turn_running=false, etc.) as a safety net: the main path only
  /// finalises `_currentMsg`, so any bubble that escaped adoption
  /// stays stuck with the skeleton unless we explicitly finalise it
  /// here. Optionally excludes [keep] so a caller can exempt the
  /// bubble it's about to fill with content.
  void _finalizeOrphanStreamingBubbles({ChatMessage? keep}) {
    for (final m in _messages) {
      if (identical(m, keep)) continue;
      if (!_isOrphanStreamingAssistant(m)) continue;
      m.setStreamingState(false);
      m.setThinkingState(false);
    }
  }

  void _ensureBubble() {
    if (_currentMsg != null) return;
    // The daemon NO LONGER emits `turn_start` events (the event-log
    // is unified under kind='event' rows; the lifecycle is carried
    // by `user_message` + `message_started` + `assistant_stream_snapshot`
    // + `message_done`). Previously this guard short-circuited bubble
    // creation during replay, counting on a turn_start event that
    // never arrived — so sessions reopened with ONLY user bubbles
    // visible and no assistant replies at all, which is what the user
    // sees as "the session looks empty". Let the orphan-adoption
    // logic below run during replay too — _messages was just cleared,
    // so no orphan will be found and we'll mint a fresh assistant
    // bubble the first token/snapshot event can populate.

    // Orphan sweep + adoption.
    //
    // Two kinds of streaming-empty assistant bubbles may exist in the
    // list when we get here:
    //
    //   (a) "leftover from a previous turn" — its `sortKey` is
    //       anchored to a daemon seq that pre-dates the most recent
    //       user message. Adopting it would cause the incoming
    //       tokens to render ABOVE the user's question, which is
    //       visually broken. These must be FINALISED (stop the
    //       typing skeleton) but not reused.
    //
    //   (b) "current turn's placeholder" — sits AFTER the most
    //       recent user message in sort order. Adopting it is
    //       exactly the point: tokens land in the bubble the user
    //       is already seeing, and no duplicate appears. If several
    //       exist we pick the one with the highest sortKey (i.e.
    //       the most recently created) and silence the others.
    //
    // To classify each orphan we need the highest sortKey among user
    // messages — orphans below that threshold are (a), above are (b).
    int lastUserSortKey = -1;
    for (final m in _messages) {
      if (m.role == MessageRole.user) {
        final k = m.sortKey;
        if (k > lastUserSortKey) lastUserSortKey = k;
      }
    }

    ChatMessage? adopt;
    int adoptSortKey = -1;
    final stale = <ChatMessage>[];
    for (final m in _messages) {
      if (!_isOrphanStreamingAssistant(m)) continue;
      if (m.sortKey <= lastUserSortKey) {
        stale.add(m);
        continue;
      }
      if (adopt == null || m.sortKey > adoptSortKey) {
        if (adopt != null) stale.add(adopt);
        adopt = m;
        adoptSortKey = m.sortKey;
      } else {
        stale.add(m);
      }
    }

    // Silence every orphan we didn't adopt so their typing skeletons
    // stop animating.
    for (final s in stale) {
      s.setStreamingState(false);
      s.setThinkingState(false);
    }

    if (adopt != null) {
      _currentMsg = adopt;
      return;
    }

    // Seed the assistant bubble with the seq of the event that
    // triggered it (typically the first token/thinking/tool for the
    // turn — `_lastPersistedSeq` was just bumped at the top of
    // _onEvent from the envelope). A later `message_started` /
    // canonical event may call updateSortKey() to re-pin to the
    // exact seq; that's a no-op when the daemon is in order.
    final msg = ChatMessage(
      id: _nextMsgId('a'),
      role: MessageRole.assistant,
      // Use the ts from the event that triggered the bubble — it
      // was just stored on `_lastEventTs` at the top of _onEvent.
      // Falls back to `DateTime.now()` in the constructor when
      // null (ephemeral events don't always carry ts).
      timestamp: _lastEventTs,
      anchorSeq: _anchorForNewLocalBubble(),
    );
    msg.setStreamingState(true);
    // Reset streaming-artifact scan bookkeeping for the new bubble.
    _lastArtifactScan = DateTime.fromMillisecondsSinceEpoch(0);
    _lastArtifactScanLen = 0;
    setState(() {
      _currentMsg = msg;
      _messages.add(msg);
      _resortMessages();
    });
    // Scroll AFTER the bubble is in the tree — otherwise `animateTo`
    // targets the old `maxScrollExtent` and the new bubble slips
    // below the viewport until the next token forces a re-scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom();
    });
  }

  // ─── Send (fire-and-forget POST /messages, response via Socket.IO) ─────

  /// Single-button send/abort/queue dispatcher. The behaviour is
  /// Enqueue the composer text on the daemon's persistent queue.
  ///
  /// Behaviour by state:
  ///   * empty + no active turn → no-op (button is disabled visually)
  ///   * empty + active turn    → abort the running turn
  ///   * text                   → optimistic-add to the queue + fire
  ///                              POST. The daemon decides whether to
  ///                              dispatch the turn now or park it
  ///                              behind others. `message_started`
  ///                              events drive the spinner transition.
  Future<void> _send() async {
    final text = _ctrl.text.trim();

    if (text.isEmpty) {
      if (_isSending) await _abort();
      return;
    }

    final appState = context.read<AppState>();
    final activeApp = appState.activeApp;
    final workspace = appState.workspace;

    // Capture before any async work — determines whether we came from
    // the empty state (no messages yet) or from within an active chat.
    final wasEmpty = _messages.isEmpty;

    if (activeApp?.workspaceMode == 'required' && workspace.isEmpty) {
      // Same UX as web (sendMessage in stores/chat.ts): silently
      // bail and pulse the chip — flip the flag true now to trigger
      // `_WorkspaceChip.didUpdateWidget`'s shake, then back to false
      // after the 500ms animation so a second click can re-trigger.
      if (mounted) setState(() => _highlightWorkspaceChip = true);
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _highlightWorkspaceChip = false);
      });
      return;
    }

    var session = SessionService().activeSession;
    final appId = activeApp?.appId ?? DigitornApiClient().appId;

    // True when we're about to create a brand-new session — either
    // because the panel is empty OR because no session is active (e.g.
    // GlobalKey-preserved state from a previous visit still holds old
    // messages, but that session is gone). In both cases we want the
    // same optimistic path: clear any stale content and show the new
    // user bubble immediately.
    final startingFresh = wasEmpty || session == null;

    // ── Optimistic UI (new-session path) ─────────────────────────────
    // Add the user bubble and flip to active-chat layout immediately,
    // before the credentials + session-create round trips (2–5s total).
    // On any subsequent failure the bubble is removed and the input is
    // restored so the user can retry without losing their text.
    final String clientMessageId = QueueService.newCorrelationId();
    final String optimisticCid = QueueService.newCorrelationId();
    ChatMessage? optimisticUserMsg;
    if (startingFresh) {
      final userMsg = ChatMessage(
        id: _nextMsgId('u'),
        role: MessageRole.user,
        initialText: text,
        correlationId: optimisticCid,
        clientMessageId: clientMessageId,
        anchorSeq: _anchorForNewLocalBubble(),
      );
      _hadTokens = false;
      _lastUserText = text;
      setState(() {
        _messages.clear();
        _messageKeys.clear();
        _animatedMessageIds.clear();
        _messages.add(userMsg);
        _isPreparingSession = false;
        _ctrl.clear();
        _statusPhase = 'requesting';
        _activeError = null;
        _isSending = true;
        _awaitingAgentResponse = true;
      });
      _armSpinnerWatchdog();
      _scrollToBottom();
      _focus.requestFocus();
      optimisticUserMsg = userMsg;

      // Wait for the paint — NOT just a microtask. On Flutter Web +
      // mobile, ``setState`` schedules a rebuild but the next HTTP
      // await (ensureCredentials, createAndSetSession) can eat the
      // microtask queue before the frame ships to the raster thread,
      // leaving ``_buildEmptyState`` on screen for several frames
      // after the user pressed Enter. ``endOfFrame`` resolves AFTER
      // the browser/engine has actually painted the new bubble, so
      // the user sees the optimistic message before any network
      // traffic starts. Guarded on ``mounted`` because the user can
      // navigate away during the one-frame wait.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }

    if (!await ensureCredentials(
      context,
      appId: appId,
      appName: activeApp?.name ?? appId,
    )) {
      if (startingFresh && mounted) {
        setState(() {
          _messages.remove(optimisticUserMsg);
          _isSending = false;
          _statusPhase = '';
          _awaitingAgentResponse = false;
          _ctrl.text = text;
        });
      }
      return;
    }
    if (!mounted) return;

    // Starting fresh always requires a new session — guaranteed new
    // conversation. From an active chat, reuse the existing session.
    // New atomic contract: ``POST /sessions`` requires the first
    // ``message`` in the body, and the daemon dispatches it as part
    // of session creation. So we call ``createAndSetSession`` with
    // the message text and SKIP the standalone ``enqueueMessage``
    // call below for this first turn — the daemon already queued it.
    if (startingFresh) {
      _isCreatingSession = true;
      final ok = await SessionService().createAndSetSession(
        appId,
        message: text,
        workspacePath: workspace.isEmpty ? null : workspace,
        clientMessageId: clientMessageId,
        queueMode: 'async',
      );
      // NOTE: ``_isCreatingSession`` is deliberately NOT reset here.
      // The session-change stream fires on a microtask that runs
      // AFTER this await resolves, so clearing the flag on this
      // line re-opens the exact race it was meant to close. The
      // flag is cleared inside ``_onSessionChange`` itself — the
      // one callback that needs to observe it as true. A safety
      // reset below covers the ``ok=false`` failure path where no
      // session-change event will ever fire.
      session = SessionService().activeSession;
      if (!ok || session == null) {
        _isCreatingSession = false;
        if (mounted) {
          setState(() {
            _messages.remove(optimisticUserMsg);
            _isSending = false;
            _statusPhase = '';
            _awaitingAgentResponse = false;
            _ctrl.text = text;
            _messages.add(ChatMessage(
              id: _nextMsgId('err'),
              role: MessageRole.assistant,
              initialText:
                  '**Error:** Could not create session. Check daemon connection.',
              anchorSeq: _anchorForNewLocalBubble(),
            ));
            _resortMessages();
          });
        }
        return;
      }
    }

    // Drop any stale assistant bubble that may have been spawned by
    // late trailing events (memory_update / hook / agent_event) after
    // the previous turn_complete. Leaving it in place would push the
    // new user bubble below a pre-existing agent card, and the next
    // turn's tokens would stream into the stale bubble — which sits
    // ABOVE the user message in the transcript. This is what caused
    // the "agent replies appear above my message" regression.
    if (_currentMsg != null && !_isSending) {
      final stale = _currentMsg!;
      stale.setStreamingState(false);
      stale.setThinkingState(false);
      if (stale.text.isEmpty && stale.thinkingText.isEmpty) {
        _messages.remove(stale);
      }
      _currentMsg = null;
    }

    // Two parallel flows depending on whether the daemon is busy:
    //   • idle — the daemon dispatches the turn immediately. No need
    //     to show an optimistic row in the queue panel.
    //   • busy — the daemon parks the message in the queue. Add a
    //     QueueService entry so the panel shows it while we wait for
    //     the canonical `message_started`.
    //
    // In BOTH cases the user bubble is added to the chat right now
    // with a client-generated [clientMessageId] and a provisional
    // `sortKey`. When the `user_message` event echoes back, its
    // payload carries the same `client_message_id` → we reconcile
    // (attach correlation_id, pin sortKey to the daemon's `seq`)
    // and re-sort. Chronology is governed by `seq`, not by insertion
    // order, so a delayed event still lands the bubble in its
    // authoritative position after re-sort.
    final qsvc = QueueService();
    final sid = session.sessionId;
    final busy = logic.computeBusy(
      isSending: _isSending,
      sessionId: sid,
      queue: qsvc,
    );
    final replacing = _pendingReplaceLast;
    final String cid;
    if (startingFresh) {
      cid = optimisticCid;
    } else if (replacing != null) {
      cid = replacing.correlationId;
    } else if (busy) {
      final entry = qsvc.addOptimistic(sid, text);
      cid = entry.correlationId;
    } else {
      cid = QueueService.newCorrelationId();
    }

    // Idle path only: add the user bubble to chat right away for
    // snappy feedback. Busy path: the bubble lives in the queue
    // panel until the daemon picks it, then `user_message` creates
    // the chat bubble at its authoritative seq — that way the user
    // never sees the same message in two places.
    if (replacing == null && !busy) {
      if (!startingFresh) {
        final userMsg = ChatMessage(
          id: _nextMsgId('u'),
          role: MessageRole.user,
          initialText: text,
          correlationId: cid,
          clientMessageId: clientMessageId,
          anchorSeq: _anchorForNewLocalBubble(),
        );
        setState(() => _messages.add(userMsg));
      }

      final firstUser =
          _messages.where((m) => m.role == MessageRole.user).length == 1;
      if (firstUser && session.title.isEmpty) {
        final title = text.length > 60 ? '${text.substring(0, 60)}…' : text;
        SessionService().updateSessionTitle(session.sessionId, title);
      }
    }

    if (!startingFresh) {
      _hadTokens = false;
      _lastUserText = text;
      setState(() {
        _isPreparingSession = false;
        _ctrl.clear();
        _statusPhase = 'requesting';
        _activeError = null;
        _isSending = true;
      });
      _armSpinnerWatchdog();
    }

    // Product rule: dedicated "agent is thinking" indicator.
    // Activates the moment a non-queued message leaves — rendered as
    // a standalone 3-bar skeleton bar in the chat area. Independent
    // of any ChatMessage bubble; flipped off by the first response
    // signal in ``_onEvent`` (token / thinking / tool_start / result
    // / error / message_done / turn_complete).
    if (!busy && replacing == null && !startingFresh) {
      setState(() => _awaitingAgentResponse = true);
    }

    final images = _attachments
        .where((a) => a.isImage)
        .map((a) => a.path)
        .toList();
    final files = _attachments
        .where((a) => !a.isImage)
        .map((a) => a.path)
        .toList();
    // Snapshot the full attachment list so we can restore it if the
    // POST fails — otherwise the user's images/files vanish from the
    // composer with no way to retry without re-selecting each one.
    final attachmentsSnapshot = List.of(_attachments);
    setState(() => _attachments.clear());
    if (!startingFresh) {
      _scrollToBottom();
      _focus.requestFocus();
    }

    SessionService().invalidateHistory(session.sessionId);
    SessionService().rejoinSessionRoom();
    SessionMetrics().startPolling(appId, session.sessionId);

    // First-turn fast-path: ``createAndSetSession`` above already
    // posted the message atomically with the session creation, so
    // the daemon has it queued and is dispatching. Skip the
    // standalone ``enqueueMessage`` here — duplicating it would
    // either land a second user bubble or 422 on the
    // ``client_message_id`` collision. The expected events
    // (``user_message`` → ``message_started`` → tokens → …) flow
    // from the same correlation_id the daemon minted in the
    // creation response.
    var result = startingFresh
        ? EnqueueResult.accepted(correlationId: cid)
        : await SessionService().enqueueMessage(
            appId,
            session.sessionId,
            text,
            workspace: workspace.isEmpty ? null : workspace,
            images: images.isNotEmpty ? images : null,
            files: files.isNotEmpty ? files : null,
            correlationId: cid,
            clientMessageId: clientMessageId,
            queueMode: replacing != null ? 'replace_last' : 'async',
          );
    // Consume the replace-last intent whether the call succeeded or
    // failed — the user's action has been applied or rejected once.
    if (replacing != null) {
      setState(() => _pendingReplaceLast = null);
    }

    // Session not found → recreate session AND dispatch the message
    // atomically. The new contract folds both into one POST.
    if (!result.isOk &&
        (result.error ?? '').contains('Session not found')) {
      final ok = await SessionService().createAndSetSession(
        appId,
        message: text,
        workspacePath: workspace.isEmpty ? null : workspace,
        clientMessageId: clientMessageId,
        queueMode: 'async',
      );
      final newSession = SessionService().activeSession;
      if (ok && newSession != null) {
        _currentSessionId = newSession.sessionId;
        SessionService().rejoinSessionRoom();
        SessionMetrics().startPolling(appId, newSession.sessionId);
        // The first message was dispatched as part of session
        // creation — synthesize an "accepted" result so the rest of
        // ``_send`` reuses the standard success branch.
        result = EnqueueResult.accepted(correlationId: cid);
        if (result.isOk) {
          _messages.add(ChatMessage(
            id: _nextMsgId('sys'),
            role: MessageRole.system,
            initialText: 'Session recreated automatically',
            anchorSeq: _anchorForNewLocalBubble(),
          ));
          setState(_resortMessages);
        }
      }
    }

    if (!mounted) return;

    if (result.isOk) {
      // Pass the client-generated cid so reconcile can find the
      // optimistic entry even when the daemon minted a different
      // correlation_id for its canonical row.
      QueueService().reconcile(session.sessionId, result, tempCid: cid);
      // Arm the response timeout so a truly stuck POST surfaces an
      // error banner after 30s. "Stuck" here means: we're still in
      // the `requesting` phase, no tokens have arrived, no tool
      // phase, no thinking — the daemon never acknowledged our POST.
      // Long turns with heavy tool calls or compactions reset
      // `_hadTokens` at turn_complete, so we can't rely on that
      // flag alone — the status phase is the authoritative signal
      // that the daemon is doing something for us.
      _responseTimeout?.cancel();
      _responseTimeout = Timer(const Duration(seconds: 30), () {
        if (!mounted || !_isSending) return;
        if (_hasLiveAgentActivity()) return;
        setState(() {
          _messages.add(ChatMessage(
            id: 'timeout-${DateTime.now().millisecondsSinceEpoch}',
            role: MessageRole.assistant,
            initialText: '**Error:** No response received from the agent. '
                'This could be due to insufficient balance, rate limiting, '
                'or the daemon being unavailable. Check the daemon logs for details.',
            anchorSeq: _anchorForNewLocalBubble(),
          ));
          _resortMessages();
          _isSending = false;
          _statusPhase = '';
        });
        _scrollToBottom();
      });
      return;
    }

    // ── Error path ───────────────────────────────────────────────
    QueueService().removeOptimistic(session.sessionId, cid);
    // Drop the optimistic user bubble we added in _send — the send
    // never landed, so leaving it in the transcript is misleading.
    _messages.removeWhere((m) => m.clientMessageId == clientMessageId);
    _responseTimeout?.cancel();
    final err = result.error ?? 'send failed';
    setState(() {
      _messages.add(ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}',
        role: MessageRole.assistant,
        initialText: '**Error:** $err',
        anchorSeq: _anchorForNewLocalBubble(),
      ));
      _resortMessages();
      _isSending = false;
      _statusPhase = '';
      // Restore the attachments the user had picked — the POST
      // failed, they should be able to retry without re-selecting
      // every file. Also restore the composer text below if we
      // cleared it optimistically.
      if (_attachments.isEmpty && attachmentsSnapshot.isNotEmpty) {
        _attachments.addAll(attachmentsSnapshot);
      }
    });
    _scrollToBottom();
  }

  /// Start tracking a live tool execution so the lean tool bar can
  /// display `🔧 Bash · 4.2s` for calls that exceed the visibility
  /// threshold. The ticker rebuilds every 500 ms while the tool is
  /// running so the duration stays fresh.
  void _setActiveTool(String name) {
    _activeToolTicker?.cancel();
    _activeToolName = name;
    _activeToolStartedAt = DateTime.now();
    _activeToolTicker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (!mounted || _activeToolStartedAt == null) return;
        setState(() {}); // rerender duration
      },
    );
  }

  void _clearActiveTool() {
    _activeToolTicker?.cancel();
    _activeToolTicker = null;
    if (_activeToolName != null || _activeToolStartedAt != null) {
      if (mounted) {
        setState(() {
          _activeToolName = null;
          _activeToolStartedAt = null;
        });
      } else {
        _activeToolName = null;
        _activeToolStartedAt = null;
      }
    }
  }


  // ─── Recording ────────────────────────────────────────────────────────────

  /// Finalise a recording — pulls the transcript (live STT /
  /// server transcription) into the composer, or attaches the
  /// audio file if no transcript is available. Same logic as the
  /// mic button's toggle, but triggered by the overlay's Stop.
  /// Snap the pre-dictate composer text when recording starts, so
  /// we can restore it if the recording / transcription fails. Clear
  /// the snapshot once the recording leaves the listening state so
  /// a successful transcript doesn't get overwritten on the next
  /// mount / rebuild.
  void _onVoiceStateChanged() {
    final current = VoiceInputService().state;
    if (current == _lastVoiceState) return;
    if (_lastVoiceState != VoiceState.listening &&
        current == VoiceState.listening) {
      _preDictateText = _ctrl.text;
    }
    _lastVoiceState = current;
  }

  Future<void> _handleRecordingStop() async {
    final svc = VoiceInputService();
    // Snapshot the pre-dictate text — `_onVoiceStateChanged` captured
    // it at listening-start; we re-read here in case the listener
    // fired after a rebuild scrambled the reference.
    final preDictate = _preDictateText ?? '';
    final result = await svc.stop();
    if (!mounted) return;

    // Success path: a non-empty transcript lands in the composer.
    // We do NOT auto-send any more — the user reviews the text and
    // hits Send themselves. Auto-send mid-turn was too eager: a
    // noisy recording would fire messages the user never vetted.
    if (result != null && result.isNotEmpty) {
      _ctrl.value = _ctrl.value.copyWith(
        text: result,
        selection: TextSelection.collapsed(offset: result.length),
      );
      _focus.requestFocus();
      _preDictateText = null;
      return;
    }

    // Failure path — the service has a non-null `lastError` OR
    // produced no transcript and no audio. In both cases we roll the
    // composer back to whatever was there BEFORE the user hit the
    // mic. This fixes the "partial transcript leaked into the input
    // after failure" regression.
    final audio = svc.lastAudioPath;
    final err = svc.lastError;
    final hasAudio = audio != null && audio.isNotEmpty;

    // Restore the pre-dictate text — whether we fall through to
    // attaching an audio file or not, the STT partial transcripts
    // that may have streamed in should not be left behind waiting
    // to be sent.
    if (_ctrl.text != preDictate) {
      _ctrl.value = _ctrl.value.copyWith(
        text: preDictate,
        selection: TextSelection.collapsed(offset: preDictate.length),
      );
    }
    _preDictateText = null;

    // If we managed to capture audio (server-transcribe fallback,
    // pure-record mode), attach it so the user can still send it
    // as-is. No auto-send, no placeholder text — user intent drives
    // the actual dispatch.
    if (hasAudio) {
      final filename = audio.split(RegExp(r'[\\/]')).last;
      setState(() {
        _attachments.add((name: filename, path: audio, isImage: false));
      });
    }
    if (err != null && err.isNotEmpty && mounted) {
      final c = context.colors;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Row(children: [
            Icon(Icons.info_outline_rounded, size: 14, color: c.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(err,
                  style:
                      GoogleFonts.inter(fontSize: 12, color: c.text)),
            ),
          ]),
          backgroundColor: c.surfaceAlt,
          duration: const Duration(seconds: 6),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8)),
          margin: const EdgeInsets.all(16),
        ));
    }
  }

  // ─── Abort ────────────────────────────────────────────────────────────────

  /// Default abort = cancel the running turn but keep the queue. The
  /// daemon dispatches the next queued message within ~200 ms. Pass
  /// [purgeQueue] = true (long-press / secondary action) to also drop
  /// everything pending.
  Future<void> _abort({bool purgeQueue = false}) async {
    final session = SessionService().activeSession;
    final appId = context.read<AppState>().activeApp?.appId ?? DigitornApiClient().appId;
    if (session == null) return;

    setState(() => _statusPhase = 'aborting');

    await SessionService().abortSession(
      appId,
      session.sessionId,
      purgeQueue: purgeQueue,
    );

    // Fallback: if SSE abort event doesn't arrive within 3s, clean up
    // locally. Only runs when the queue would be empty anyway — a
    // soft abort expects `message_started` for the next pending row
    // to take over.
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted || !_isSending) return;
      final pending = QueueService().pendingCountFor(session.sessionId);
      if (purgeQueue || pending == 0) _handleAbortCleanup();
    });
  }

  void _handleAbortCleanup() {
    // Mark any running tool calls as cancelled
    if (_currentMsg != null) {
      for (final tc in _currentMsg!.toolCalls) {
        if (tc.status == 'started') {
          _currentMsg!.addOrUpdateToolCall(ToolCall(
            id: tc.id,
            name: tc.name,
            label: tc.label,
            detail: tc.detail,
            params: tc.params,
            status: 'failed',
            error: 'Aborted by user',
          ));
        }
      }
      _currentMsg!.setStreamingState(false);
      _currentMsg!.setThinkingState(false);
    }
    _currentMsg = null;
    _finalizeOrphanStreamingBubbles();
    WorkspaceState().finishAllAgents();
    _hadTokens = false;
    _responseTimeout?.cancel();
    if (mounted) {
      setState(() {
        _isSending = false;
        _statusPhase = '';
      });
    }
  }

  // ─── Approve / Deny ───────────────────────────────────────────────────────

  Future<void> _handleApproval(ApprovalRequest req, bool approved, String message) async {
    final appId = context.read<AppState>().activeApp?.appId ?? DigitornApiClient().appId;

    // Send to daemon FIRST, only remove from UI if successful
    final ok = await SessionService().approveRequest(
      appId: appId,
      requestId: req.id,
      approved: approved,
      message: message,
    );

    if (!ok) {
      // Request failed — show error, keep the approval banner visible
      if (mounted) {
        showToast(context, 'Failed to send approval. Retrying...');
        // Retry once after 2s
        await Future.delayed(const Duration(seconds: 2));
        final retryOk = await SessionService().approveRequest(
          appId: appId,
          requestId: req.id,
          approved: approved,
          message: message,
        );
        if (!retryOk && mounted) {
          showToast(context, 'Approval failed. Check connection.');
          return; // Keep banner visible so user can try again
        }
      } else {
        return;
      }
    }

    // Success — remove the banner. The daemon will send the real
    // tool_call event with the complete result — no need to inject
    // a fake ToolCall here (it would create a duplicate).
    if (mounted) {
      setState(() => _pendingApprovals.remove(req));
    }

    // Clean up preview buffers
    final wsSvc = WorkspaceService();
    for (final prefix in ['_approval/${req.id}', '_ask_user/${req.id}']) {
      for (final ext in ['.md', '.txt']) {
        wsSvc.closeBuffer('$prefix$ext');
      }
    }
    final path = req.params['path'] as String?
        ?? req.params['file'] as String?
        ?? req.params['file_path'] as String?
        ?? '';
    if (path.isNotEmpty) wsSvc.closeBuffer(path);
  }

  /// Insert a UI-only system marker into the chat timeline — these
  /// lines are rendered by [_SystemMessage] as a centered italic
  /// divider and are PURELY client-side. They persist across session
  /// reopens (because the source ``hook`` / ``error`` / ``abort`` event
  /// is in history_log and replays through [_onEvent]), but they NEVER
  /// reach the LLM because the daemon composes its prompt from
  /// ``session.messages`` (user/assistant/tool roles only).
  ///
  /// The id is keyed on the daemon envelope's ``seq`` so replay is
  /// idempotent — seeing the same event twice never duplicates the
  /// marker in the list.
  String? _addSystemMarker({
    required String idPrefix,
    required String text,
    int? envelopeSeq,
  }) {
    if (!mounted) {
      debugPrint('[MARKER] SKIP (not mounted) $idPrefix: $text');
      return null;
    }
    final id = envelopeSeq != null && envelopeSeq > 0
        ? '$idPrefix-$envelopeSeq'
        : '$idPrefix-${DateTime.now().microsecondsSinceEpoch}';
    if (_messages.any((m) => m.id == id)) {
      debugPrint('[MARKER] DEDUP $id (already present)');
      return id;
    }
    debugPrint('[MARKER] ADD id=$id seq=$envelopeSeq text="$text"');
    setState(() {
      _messages.add(ChatMessage(
        id: id,
        role: MessageRole.system,
        initialText: text,
        daemonSeq: envelopeSeq,
      ));
    });
    return id;
  }

  /// Phase=start of ``compact_context``. Drops an in-progress system
  /// line in the chat ("⟳ Compacting context…") that will be upgraded
  /// into the final "Context compacted: X → Y" line by the matching
  /// phase=end. Pinned to the hook envelope's ``daemonSeq`` so it
  /// slots in chronologically between the two turns and can't drift
  /// to the bottom.
  void _onCompactionStarted(Map<String, dynamic> details, {int? envelopeSeq}) {
    if (!mounted || _isReplaying) return;
    final strategy = details['strategy'] as String? ?? 'truncate';
    final strat = strategy == 'summarize' ? 'summary' : 'truncate';
    final id = envelopeSeq != null && envelopeSeq > 0
        ? 'compact-$envelopeSeq'
        : 'compact-pending-${DateTime.now().millisecondsSinceEpoch}';
    if (_messages.any((m) => m.id == id)) return;
    final msg = ChatMessage(
      id: id,
      role: MessageRole.system,
      initialText: 'Compacting context… ($strat)',
      daemonSeq: envelopeSeq,
    );
    msg.setStreamingState(true);
    setState(() {
      _messages.add(msg);
      _pendingCompactionBubbleId = id;
    });
  }

  void _onCompactionCompleted(Map<String, dynamic> details,
      {required bool emergency, int? envelopeSeq}) {
    final before = details['tokens_before'] as int? ?? 0;
    final after = details['tokens_after'] as int? ?? 0;
    final reduced = details['tokens_reduced'] as int? ?? (before - after);
    final strategy = details['strategy'] as String? ?? 'truncate';

    // Update context meter immediately — [afterCompaction: true]
    // bypasses the monotonic guard so the legitimate pressure drop
    // is accepted even though compact_context:end payloads don't
    // carry a `compactions` counter (scout-confirmed wire shape).
    //
    // Called unconditionally so the local compactions counter bumps
    // even when the hook omits `pressure`: that way the NEXT
    // `context_status` envelope (which carries the lower pressure)
    // also passes the monotonic guard.
    ContextState().updateFromJson(details, afterCompaction: true);
    SessionMetrics().updateContext(details);

    // Reset spinner phase
    if (mounted) setState(() => _statusPhase = _isSending ? 'requesting' : '');

    // Surface significant compactions as a persistent system line in
    // the chat timeline. Pinned via ``daemonSeq`` (the hook envelope's
    // authoritative seq) so it lands between the two turns where the
    // compaction actually happened — no more "figé en bas" drift.
    // Also emit a transient SnackBar for live notification when the
    // user is watching.
    if ((reduced > 5000 || emergency) && mounted) {
      final fmtBefore = ContextState().fmt(before);
      final fmtAfter = ContextState().fmt(after);
      final fmtReduced = ContextState().fmt(reduced);
      final icon = emergency ? 'Emergency compaction' : 'Context compacted';
      final strat = strategy == 'summarize' ? 'summary' : 'truncate';
      final text =
          '$icon: $fmtBefore → $fmtAfter tokens (-$fmtReduced, $strat)';

      // Upgrade the in-progress line if one exists (normal case:
      // compact_context:start created the placeholder). Otherwise
      // create a fresh line — covers emergency_compaction (which has
      // no start phase) and replay of a session whose :start event
      // was lost / filtered.
      ChatMessage? pending;
      if (_pendingCompactionBubbleId != null) {
        for (final m in _messages) {
          if (m.id == _pendingCompactionBubbleId) {
            pending = m;
            break;
          }
        }
      }

      if (pending != null) {
        setState(() {
          pending!.replaceText(text);
          pending.setStreamingState(false);
          _pendingCompactionBubbleId = null;
        });
      } else {
        final markerId = envelopeSeq != null && envelopeSeq > 0
            ? 'compact-$envelopeSeq'
            : 'compact-${DateTime.now().millisecondsSinceEpoch}';
        if (!_messages.any((m) => m.id == markerId)) {
          setState(() {
            _messages.add(ChatMessage(
              id: markerId,
              role: MessageRole.system,
              initialText: text,
              daemonSeq: envelopeSeq,
            ));
          });
        }
      }

      // Live toast — only when not replaying history, so reopening a
      // session doesn't pop a toast for every past compaction.
      if (!_isReplaying) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(SnackBar(
          content: Text(text, style: GoogleFonts.firaCode(fontSize: 12)),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  /// Reconcile local UI state with the daemon's authoritative view
  /// of the session after a reconnect / join_session.
  ///
  /// Called from the `queue:snapshot` handler. The snapshot carries
  /// `is_active` (any turn running) and `running_correlation_id`
  /// (which turn exactly). We cross-reference with our local
  /// `_currentMsg` / `_statusPhase` / open tool bubbles:
  ///
  ///   * daemon says INACTIVE → finalize any in-flight bubble as
  ///     "interrupted" and drop the busy spinner. Covers the
  ///     mid-tool crash case: daemon died after `tool_start` but
  ///     before `tool_call`; replay gives us the orphan tool_start;
  ///     queue:snapshot.is_active == false tells us it's never
  ///     completing.
  ///   * daemon says ACTIVE with a different correlation_id than
  ///     our local bubble → our bubble is stale (we missed the
  ///     previous turn's completion). Finalize it.
  ///   * daemon says ACTIVE with the same correlation_id → keep
  ///     the bubble, live events will resume the stream.
  void _onQueueSnapshot(String sid,
      {required bool isActive, String? runningCorr}) {
    if (!mounted) return;
    final active = SessionService().activeSession?.sessionId ?? '';
    if (sid.isNotEmpty && sid != active) return;
    debugPrint('ChatPanel: queue:snapshot is_active=$isActive '
        'runningCorr=$runningCorr currentMsg.corr='
        '${_currentMsg?.correlationId}');

    // ── Gate: only reconcile when we have REAL evidence of an
    //    orphaned bubble/tool. "is_active: false" is the NORMAL
    //    state when opening any app with no running turn — we
    //    must not touch the chat in that case or the user sees a
    //    stray "(interrupted — reconnect detected)" sticker that
    //    has nothing to reconcile.
    //
    // A bubble is considered orphaned ONLY when:
    //   • it has NO daemon-assigned seq yet (unacknowledged), AND
    //   • its text is still empty (nothing streamed in), AND
    //   • either no turn runs right now (!isActive) or a
    //     DIFFERENT turn is running (runningCorr mismatch).
    //
    // A tool is considered orphaned ONLY when the bubble carrying
    // it is the CURRENT in-flight bubble (_currentMsg) — never
    // historical rows, because a completed tool may legitimately
    // have transient states that look "started" during replay.
    final cur = _currentMsg;
    final curIsProvisional = cur != null &&
        cur.daemonSeq == null &&
        cur.text.isEmpty;
    final curBelongsToDifferentTurn = cur != null &&
        runningCorr != null &&
        cur.correlationId != null &&
        cur.correlationId != runningCorr;
    final shouldFinalizeCurrent =
        curIsProvisional && (!isActive || curBelongsToDifferentTurn);

    final activeToolInFlight =
        cur != null && cur.hasOpenToolStart && !isActive;

    if (!shouldFinalizeCurrent && !activeToolInFlight) return;

    _reconcileInterruptedState(
      reason: isActive ? 'stale' : 'interrupted',
      finalizeCurrent: shouldFinalizeCurrent,
      closeToolOn: activeToolInFlight ? cur : null,
    );
  }

  /// Narrow, evidence-driven reconciliation. Unlike the first pass,
  /// this does NOT iterate `_messages` — historical rows are
  /// left alone. Callers pass explicit flags so the function is
  /// a pure transform of state it was asked to touch.
  ///
  /// [reason] = `'stale'` (new turn took over) or `'interrupted'`
  /// (daemon is idle but we still think something's running).
  void _reconcileInterruptedState({
    required String reason,
    required bool finalizeCurrent,
    ChatMessage? closeToolOn,
  }) {
    if (!mounted) return;
    setState(() {
      if (finalizeCurrent) {
        final cur = _currentMsg;
        if (cur != null) {
          // No text injected — silent finalize. The previous
          // '(interrupted — reconnect detected)' marker was
          // noisy and fired on every app open.
          cur.pending = false;
          // CRITICAL: stop the streaming flag BEFORE dropping the
          // reference. Otherwise the bubble stays in ``_messages``
          // with ``isStreaming=true`` and ``text=""`` which is the
          // exact trigger for the 3-bar ``_TypingSkeleton`` —
          // animating forever on its own because no further event
          // will ever close it (we just severed the pointer). This
          // was the root cause of "ça s'anime seul alors que je n'ai
          // envoyé aucun message" on session open: the phantom
          // queue:snapshot -> _ensureBubble -> reconcile sequence
          // left an orphan streaming bubble every time.
          cur.setStreamingState(false);
          cur.setThinkingState(false);
          _currentMsg = null;
          _statusPhase = '';
          _hadTokens = false;
          if (_isSending) _isSending = false;
        }
      }
      // Close open tool_start ONLY on the passed-in in-flight
      // bubble. Historical tools stay untouched.
      closeToolOn?.markToolStartsInterrupted();
    });
  }

  void _openAskUserContent(ApprovalRequest req) {
    final md = req.content ?? '';
    if (md.isEmpty) return;
    // The inline approval card already renders the markdown; simply
    // surface the workspace panel for visibility.
    final appState = context.read<AppState>();
    if (!appState.isWorkspaceVisible) appState.showWorkspace();
  }

  void _onTextChanged() {
    final text = _ctrl.text;
    if (text.startsWith('/') && !text.contains(' ')) {
      final query = text.substring(1);
      final app = context.read<AppState>().activeApp;
      final cmds = getAvailableCommands(app, query);
      if (cmds.isNotEmpty && mounted) {
        setState(() => _slashCommands = cmds);
      }
    } else if (_slashCommands.isNotEmpty) {
      setState(() => _slashCommands = []);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 100;
    if (_showScrollDown == atBottom) {
      setState(() => _showScrollDown = !atBottom);
    }
  }

  /// Returns true when the scroll view is at (or within 160px of) the bottom.
  /// Used to decide whether a streaming auto-scroll should fire — if the user
  /// has scrolled up to read history we must not yank them back down on
  /// every token.
  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    return _scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 160;
  }

  /// Scroll to bottom. Respects the user's scroll position by default: if
  /// they've scrolled up, we leave them alone. Pass [force] when the caller
  /// knows the user should always end up at the bottom (e.g. just sent a
  /// message, tapped the scroll-down FAB, restored a session).
  void _scrollToBottom({bool force = false}) {
    if (!force && !_isNearBottom) return;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final activeApp = appState.activeApp;
    final session = context.watch<SessionService>().activeSession;

    return DropTarget(
      onDragEntered: (_) {
        if (!_isDragOver && mounted) {
          setState(() => _isDragOver = true);
        }
      },
      onDragExited: (_) {
        if (_isDragOver && mounted) {
          setState(() => _isDragOver = false);
        }
      },
      onDragDone: (details) {
        setState(() {
          _isDragOver = false;
          for (final f in details.files) {
            if (f.path.isEmpty) continue;
            final name = f.name.isNotEmpty
                ? f.name
                : f.path.split(RegExp(r'[\\/]')).last;
            final isImg = attach_helpers.isImagePath(f.path);
            _attachments.add((
              name: name,
              path: f.path,
              isImage: isImg,
            ));
            // Record for the Recents list — drop is a durable local
            // path, same as the file-picker flow.
            unawaited(RecentAttachmentsService()
                .record(name: name, path: f.path, isImage: isImg));
          }
        });
        _focus.requestFocus();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: CallbackShortcuts(
      bindings: {
        // ── Chat-only shortcuts ──
        // Generic navigation shortcuts (Ctrl+K, Ctrl+P, Ctrl+T,
        // Ctrl+/) are owned by `_GlobalShortcuts` in main.dart so
        // they fire from anywhere in the app. The bindings below
        // are the ones that only make sense inside an active chat
        // session.
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_showFind) {
            setState(() {
              _showFind = false;
              _findQuery = '';
              _findCtrl.clear();
            });
          } else if (_isSending) {
            _abort();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
          setState(() {
            _showFind = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _findFocus.requestFocus();
          });
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
          setState(() {
            _showFind = true;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _findFocus.requestFocus();
          });
        },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () async {
          final app = context.read<AppState>().activeApp;
          if (app != null) {
            // New session = clear the active one and let the user
            // type the first message — the daemon creates the row
            // atomically via ``createAndSetSession`` from ``_send``.
            SessionService().clearActiveSession();
            if (context.mounted) showToast(context, 'New session — type your first message');
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          setState(() {
            _messages.clear();
            _messageKeys.clear();
            _pendingApprovals.clear();
            _currentMsg = null;
            _isSending = false;
            _hadTokens = false;
            _statusPhase = '';
          });
          if (context.mounted) showToast(context, 'Chat cleared');
        },
        // Ctrl+↑ — edit the last user message when the input is
        // empty. Standard TUI affordance (also in ChatGPT). The
        // user can rephrase and resend without retyping.
        const SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
            () {
          if (_ctrl.text.isNotEmpty) return;
          for (var i = _messages.length - 1; i >= 0; i--) {
            final m = _messages[i];
            if (m.role == MessageRole.user && m.text.isNotEmpty) {
              _ctrl.text = m.text;
              _ctrl.selection = TextSelection.collapsed(
                  offset: _ctrl.text.length);
              _focus.requestFocus();
              break;
            }
          }
        },
      },
      child: FocusScope(
        autofocus: true,
        child: ListenableBuilder(
          listenable: ArtifactService(),
          builder: (ctxA, _) {
            final svc = ArtifactService();
            final panelOpen = svc.isOpen && svc.selected != null;
            final screen = MediaQuery.sizeOf(ctxA).width;
            // Artifact panel width is clamped so the chat keeps a
            // usable column next to it — never hides the chat.
            final panelW = screen < 720
                ? screen.clamp(320.0, screen * 0.5)
                : (screen * 0.42).clamp(420.0, 560.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      _buildChatStack(activeApp, session, appState),
                      _ArtifactsFloatingChip(),
                    ],
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.centerLeft,
                  child: panelOpen
                      ? SizedBox(
                          width: panelW,
                          child: ArtifactPanel(width: panelW),
                        )
                      : const SizedBox(width: 0),
                ),
              ],
            );
          },
        ),
      ),
      ),
          ),
          if (_isDragOver)
            const Positioned.fill(
              child: IgnorePointer(child: _DropOverlay()),
            ),
        ],
      ),
    );
  }

  /// The chat column itself — extracted so the layout above can wrap
  /// it in a Row without drowning in indentation. Everything between
  /// the header and the composer lives in here.
  Widget _buildChatStack(AppSummary? activeApp, AppSession? session, AppState appState) {
    final workspace = appState.workspace;
    final workspaceRequired =
        appState.manifest.workspaceMode == WorkspaceMode.required &&
            workspace.isEmpty;
    return Container(
      color: context.colors.bg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Replay / status strip ─────────────────────────────────
              _buildStatusStrip(),
          // ── Find bar (Ctrl+F) ───────────────────────────────────────────
          if (_showFind) _buildFindBar(),

          // ── Messages, empty state, or history skeleton ──────────────────
          // Keyed by session id so Flutter treats a session switch as
          // a widget swap: AnimatedSwitcher can cross-fade and the
          // inner message list is rebuilt cleanly instead of flashing.
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: KeyedSubtree(
                key: ValueKey(_currentSessionId ?? '__no_session__'),
                child: _messages.isEmpty
                    ? ((_isPreparingSession || _isSending)
                        ? _buildPreparingSession()
                        : (_isReplaying &&
                                (SessionService().activeSession?.messageCount ??
                                        0) >
                                    0
                            ? _buildHistoryLoading()
                            : _buildEmptyState(
                                activeApp, workspace, workspaceRequired)))
                    : _buildMessageArea(
                        activeApp: activeApp,
                        workspace: workspace,
                        workspaceRequired: workspaceRequired,
                      ),
              ),
            ),
          ),

          // ── Spinner + Goal/Todo inline + Input bar ──────────────────────
          if (_messages.isNotEmpty || _isSending) ...[
            _buildSpinnerBar(),
            _buildInlineWorkspace(),
            // Diff stats bar (files modified by agent)
            _buildDiffStatsBar(),
            // Slash command menu
            if (_slashCommands.isNotEmpty)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SlashCommandMenu(
                      commands: _slashCommands,
                      onSelect: (cmd) {
                        _ctrl.text = '${cmd.command} ';
                        _ctrl.selection = TextSelection.collapsed(
                            offset: _ctrl.text.length);
                        _focus.requestFocus();
                        setState(() => _slashCommands = []);
                      },
                    ),
                  ),
                ),
              ),
            // ── Error banner (highest priority) ────────────────────────
            if (_activeError != null)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: _ErrorBanner(
                    error: _activeError!,
                    onDismiss: () => setState(() {
                      _activeError = null;
                      _isSending = false;
                      _statusPhase = '';
                    }),
                    onRetry: _activeError!.retry ? () {
                      setState(() {
                        _activeError = null;
                        _isSending = false;
                        _statusPhase = '';
                      });
                      if (_lastUserText.isNotEmpty) {
                        _ctrl.text = _lastUserText;
                        _send();
                      }
                    } : null,
                  ),
                ),
              ),
            // Approval card is rendered inline in the message list —
            // see the itemBuilder branch that upgrades the
            // ``approval-req-…`` marker to the interactive banner.
            // ── Inline panels (above input, mutually exclusive) ────────
            if (_showContextPanel)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: ContextPanel(
                    onClose: () => setState(() => _showContextPanel = false),
                  ),
                ),
              ),
            if (_showToolsPanel)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: ToolsPanel(
                    appId: context.read<AppState>().activeApp?.appId ?? '',
                    onClose: () => setState(() => _showToolsPanel = false),
                  ),
                ),
              ),
            if (_showTasksPanel)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: TasksPanel(
                    onClose: () => setState(() => _showTasksPanel = false),
                  ),
                ),
              ),
            if (_showSnippetsPanel)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: SnippetsPanel(
                    onClose: () =>
                        setState(() => _showSnippetsPanel = false),
                    onInsert: (rendered) {
                      final sel = _ctrl.selection;
                      final start =
                          sel.start.clamp(0, _ctrl.text.length);
                      final end = sel.end.clamp(0, _ctrl.text.length);
                      _ctrl.value = _ctrl.value.copyWith(
                        text: _ctrl.text
                            .replaceRange(start, end, rendered),
                        selection: TextSelection.collapsed(
                            offset: start + rendered.length),
                      );
                      _focus.requestFocus();
                    },
                  ),
                ),
              ),
            // ── Attachments bar (above input) ──────────────────────
            if (_attachments.isNotEmpty)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 800,
                  ),
                  child: attach_bar.AttachmentsBar(
                    attachments: _attachments,
                    onRemove: (i) => setState(() => _attachments.removeAt(i)),
                  ),
                ),
              ),
            // ── Queue panel (fixed above input) ─────────────────────
            if (SessionService().activeSession != null)
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity
                        : 800,
                  ),
                  child: _QueuePanel(
                    appId: context.read<AppState>().activeApp?.appId ??
                        DigitornApiClient().appId,
                    sessionId:
                        SessionService().activeSession!.sessionId,
                    onEditTail: _editTailMessage,
                  ),
                ),
              ),
            // Recording overlay — sits above the composer while the
            // mic is listening. Handles Stop (consumes the output
            // via the same paths the mic button would) and Cancel.
            RecordingOverlay(
              onStop: () => _handleRecordingStop(),
              onCancel: () => VoiceInputService().cancel(),
            ),
            // Composer — background apps never reach this code path
            // (main.dart routes them to BackgroundDashboard), so no
            // special guard needed here.
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width < 600
                      ? double.infinity : 800,
                ),
                child: _ChatInput(
                  controller: _ctrl,
                  focusNode: _focus,
                  // `_turnReallyRunning` (derived from messages) instead
                  // of `_isSending` so a stale event can't keep the
                  // ring spinning after the turn actually ended.
                  isActive: _turnReallyRunning && _activeError == null,
                  disabled: false,
                  queuedCount: SessionService().activeSession == null
                      ? 0
                      : QueueService().pendingCountFor(
                          SessionService().activeSession!.sessionId),
                  onSend: _send,
                  onAbort: _abort,
                  onContextTap: () => setState(() {
                    _showContextPanel = !_showContextPanel;
                    _showToolsPanel = false;
                    _showTasksPanel = false;
                    _showSnippetsPanel = false;
                  }),
                  onToolsTap: () => setState(() {
                    _showToolsPanel = !_showToolsPanel;
                    _showContextPanel = false;
                    _showTasksPanel = false;
                    _showSnippetsPanel = false;
                  }),
                  onTasksTap: () => setState(() {
                    _showTasksPanel = !_showTasksPanel;
                    _showContextPanel = false;
                    _showToolsPanel = false;
                    _showSnippetsPanel = false;
                  }),
                  onSnippetsTap: () => setState(() {
                    _showSnippetsPanel = !_showSnippetsPanel;
                    _showContextPanel = false;
                    _showToolsPanel = false;
                    _showTasksPanel = false;
                  }),
                  onAttach: (name, path, isImage) => setState(() {
                    _attachments.add((name: name, path: path, isImage: isImage));
                  }),
                  onImagePaste: (name, path, isImage) => setState(() {
                    _attachments.add((name: name, path: path, isImage: isImage));
                  }),
                ),
              ),
            ),
            // ── Status line (workspace path + model) ────────────────────
            _buildStatusLine(appState.workspace),
          ],
            ],
          ),
          // ── Compact app-name dropdown (ChatGPT pattern) ──────────────
          // Replaces the previous full top header. Sits absolute over
          // the conversation in the top-left so it never consumes
          // layout space; click opens the session drawer. Hidden when
          // the drawer IS open — the drawer's header already carries
          // the app identity and the menu would be redundant chrome.
          if (appState.panel != ActivePanel.sessions)
            Positioned(
              top: 8,
              left: 12,
              child: _buildAppMenu(activeApp),
            ),
          // ── Compact workspace toggle (top-right) ──────────────────────
          // Same pattern as the app-name menu but on the right edge.
          // Visible only when the manifest allows a workspace AND the
          // workspace panel is currently CLOSED — once it's open the
          // panel's own close button takes over (parity with how the
          // app-name menu hides when the session drawer opens).
          if (appState.workspaceAvailable && !appState.isWorkspaceVisible)
            Positioned(
              top: 8,
              right: 12,
              child: _buildWorkspaceToggle(appState),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusLine(String workspace) {
    final m = context.watch<SessionMetrics>();
    final isSmall = MediaQuery.of(context).size.width < 600;

    if (workspace.isEmpty && m.model.isEmpty) return const SizedBox.shrink();

    // Shorten workspace path
    String shortPath = workspace;
    if (shortPath.length > 50) {
      final parts = shortPath.replaceAll('\\', '/').split('/');
      shortPath = parts.length > 2
          ? '~/${parts.sublist(parts.length - 2).join('/')}'
          : shortPath;
    }

    final c = context.colors;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isSmall ? double.infinity : 800,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
          child: Row(
            children: [
              if (workspace.isNotEmpty) ...[
                Icon(Icons.folder_outlined,
                    size: 11, color: c.textMuted),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    shortPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _kFiraCode11.copyWith(color: c.textMuted),
                  ),
                ),
              ] else
                const Spacer(),
              if (m.model.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(
                  m.model,
                  style: _kFiraCode11.copyWith(color: c.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreparingSession() {
    final c = context.colors;
    final appState = context.read<AppState>();
    final appName = appState.manifest.name.isNotEmpty
        ? appState.manifest.name
        : (appState.activeApp?.name ?? '');
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: c.textMuted,
              backgroundColor: c.border,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Starting session…',
            style: _kInter125.copyWith(color: c.textMuted),
          ),
          if (appName.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _kInter11.copyWith(color: c.textDim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryLoading() {
    final c = context.colors;
    final session = SessionService().activeSession;
    final total = _replayTotal;
    final done = _replayDone;
    final progress = (total > 0) ? (done / total).clamp(0.0, 1.0) : null;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress,
              color: c.textMuted,
              backgroundColor: c.border,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Loading conversation…',
            style: _kInter125.copyWith(color: c.textMuted),
          ),
          if (session?.title.isNotEmpty ?? false) ...[
            const SizedBox(height: 6),
            Text(
              session!.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _kInter11.copyWith(color: c.textDim),
            ),
          ],
          if (total > 0) ...[
            const SizedBox(height: 4),
            Text(
              '$done / $total events',
              style: GoogleFonts.firaCode(fontSize: 10, color: c.textDim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppSummary? app, String workspace, bool workspaceRequired) {
    final isSmall = MediaQuery.of(context).size.width < 600;
    final c = context.colors;
    final manifest = context.watch<AppState>().manifest;
    final accent = manifest.accent ?? c.accentPrimary;
    final name = manifest.name.isNotEmpty ? manifest.name : (app?.name ?? 'Digitorn');
    final greeting =
        manifest.greeting.isNotEmpty ? manifest.greeting : (app?.greeting ?? '');
    final emoji = manifest.icon.isNotEmpty ? manifest.icon : app?.icon ?? '';
    final tags = app?.tags ?? const <String>[];
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 760),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: isSmall ? 16 : 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              ChatEmptyStateHero(
                emoji: emoji,
                name: name,
                greeting: greeting,
                accent: accent,
                tags: tags,
              ),
              if (manifest.quickPrompts.isNotEmpty) ...[
                const SizedBox(height: 32),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final qp in manifest.quickPrompts)
                      ChatQuickPromptCard(
                        prompt: qp,
                        accent: accent,
                        onTap: () {
                          _ctrl.text = qp.message.endsWith(' ')
                              ? qp.message
                              : '${qp.message} ';
                          _ctrl.selection = TextSelection.collapsed(
                              offset: _ctrl.text.length);
                          _focus.requestFocus();
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              // Slash command menu (also in empty state)
              if (_slashCommands.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SlashCommandMenu(
                    commands: _slashCommands,
                    onSelect: (cmd) {
                      _ctrl.text = '${cmd.command} ';
                      _ctrl.selection = TextSelection.collapsed(
                          offset: _ctrl.text.length);
                      _focus.requestFocus();
                      setState(() => _slashCommands = []);
                    },
                  ),
                ),
              // Recording overlay (empty-state path). Same UX as
              // inside the conversation view.
              RecordingOverlay(
                onStop: () => _handleRecordingStop(),
                onCancel: () => VoiceInputService().cancel(),
              ),
              // Composer-side inline panels — shown here too so they
              // work BEFORE the first message is sent. Without this
              // branch, Tools / Tasks / Snippets / Context clicks
              // toggled the flag but rendered nothing until the
              // conversation had started.
              if (_showContextPanel)
                ContextPanel(
                  onClose: () => setState(() => _showContextPanel = false),
                ),
              if (_showToolsPanel)
                ToolsPanel(
                  appId: context.read<AppState>().activeApp?.appId ?? '',
                  onClose: () => setState(() => _showToolsPanel = false),
                ),
              if (_showTasksPanel)
                TasksPanel(
                  onClose: () => setState(() => _showTasksPanel = false),
                ),
              if (_showSnippetsPanel)
                SnippetsPanel(
                  onClose: () => setState(() => _showSnippetsPanel = false),
                  onInsert: (rendered) {
                    final sel = _ctrl.selection;
                    final start =
                        sel.start.clamp(0, _ctrl.text.length);
                    final end = sel.end.clamp(0, _ctrl.text.length);
                    _ctrl.value = _ctrl.value.copyWith(
                      text:
                          _ctrl.text.replaceRange(start, end, rendered),
                      selection: TextSelection.collapsed(
                          offset: start + rendered.length),
                    );
                    _focus.requestFocus();
                  },
                ),
              // Workspace chip — shown when app requires a workspace folder.
              // Centered horizontally so it sits in the same vertical stack as
              // the hero / tags / quick prompts / composer (web parity).
              // Chip only while the workspace is REQUIRED but still
              // EMPTY — once the user picks a folder, the path lives
              // in the StatusLine under the composer and the chip
              // would just duplicate it. Mirror of the web fix.
              if (manifest.workspaceMode == WorkspaceMode.required &&
                  workspace.isEmpty) ...[
                _WorkspaceChip(
                  workspace: workspace,
                  highlighted: _highlightWorkspaceChip,
                  onTap: () async {
                    final dir = await pickWorkspace(context);
                    if (dir != null && mounted) {
                      context.read<AppState>().setWorkspace(dir);
                    }
                  },
                ),
                const SizedBox(height: 4),
              ],
              // Input bar — wrapped in maxWidth(720) so the empty-state
              // composer ends up the SAME visible width as the active-
              // state composer (chat_panel.dart:4856 also uses 720).
              // Without this cap the column's 760-28*2=704 width would
              // stretch the input wider than in active mode, which the
              // user reads as "ce n'est pas la même boîte".
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: _ChatInput(
                  controller: _ctrl,
                  focusNode: _focus,
                  // Derived spinner state — see `_turnReallyRunning`
                  // doc for the rationale (stale events can't zombie
                  // the ring).
                  isActive: _turnReallyRunning,
                  disabled: workspaceRequired,
                  queuedCount: SessionService().activeSession == null
                        ? 0
                        : QueueService().pendingCountFor(
                            SessionService().activeSession!.sessionId),
                  onSend: _send,
                  onAbort: _abort,
                  onContextTap: () => setState(() {
                      _showContextPanel = !_showContextPanel;
                      _showToolsPanel = false;
                      _showTasksPanel = false;
                      _showSnippetsPanel = false;
                    }),
                  onToolsTap: () => setState(() {
                      _showToolsPanel = !_showToolsPanel;
                      _showContextPanel = false;
                      _showTasksPanel = false;
                      _showSnippetsPanel = false;
                    }),
                  onTasksTap: () => setState(() {
                      _showTasksPanel = !_showTasksPanel;
                      _showContextPanel = false;
                      _showToolsPanel = false;
                      _showSnippetsPanel = false;
                    }),
                  onSnippetsTap: () => setState(() {
                      _showSnippetsPanel = !_showSnippetsPanel;
                      _showContextPanel = false;
                      _showToolsPanel = false;
                      _showTasksPanel = false;
                    }),
                  onAttach: (name, path, isImage) => setState(() {
                      _attachments.add((name: name, path: path, isImage: isImage));
                    }),
                  onImagePaste: (name, path, isImage) => setState(() {
                      _attachments.add((name: name, path: path, isImage: isImage));
                    }),
                ),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageArea({
    required AppSummary? activeApp,
    required String workspace,
    required bool workspaceRequired,
  }) {
    final isSmall = MediaQuery.of(context).size.width < 600;
    final maxW = isSmall ? double.infinity : 800.0;
    final hPad = isSmall ? 8.0 : 0.0;

    // History loading indicator lives in the session drawer now —
    // deliberately no chat-area placeholder.

    // Messages list.
    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              child: SelectionArea(
                onSelectionChanged: (content) {
                  // Auto-copy selected text to clipboard (Flutter web workaround)
                  if (content != null && content.plainText.isNotEmpty) {
                    Clipboard.setData(ClipboardData(text: content.plainText));
                  }
                },
                child: MouseRegion(
                  onEnter: (_) => _markScrollbarEngaged(),
                  onHover: (_) => _markScrollbarEngaged(),
                  onExit: (_) {
                    _scrollbarIdleTimer?.cancel();
                    _scrollbarIdleTimer = Timer(
                      const Duration(milliseconds: 400), () {
                        if (mounted) setState(() => _scrollbarEngaged = false);
                      },
                    );
                  },
                  child: Listener(
                    onPointerDown: (_) => _markScrollbarEngaged(),
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) _markScrollbarEngaged();
                    },
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: _scrollbarEngaged,
                      interactive: true,
                      thickness: 8,
                      radius: const Radius.circular(4),
                      // Gate scroll notifications so programmatic
                      // auto-scroll (agent streaming) doesn't trigger
                      // the thumb's default fade-in. When the user is
                      // not engaged we swallow every notification —
                      // the scrollbar stays invisible. Hovering /
                      // pointer-down / wheel events flip the gate
                      // open via [_markScrollbarEngaged].
                      notificationPredicate: (_) => _scrollbarEngaged,
                  child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.only(top: 20, bottom: 24, left: hPad, right: hPad),
        // Strict gates on the typing-dots row — strict mirror of the
        // web (`chat-panel.tsx`). The flag alone wasn't enough: if a
        // request errored or the socket dropped, `_awaitingAgentResponse`
        // could linger and the dots stayed bouncing forever. Three
        // additional guards now hide it on:
        //   1. Lost connection (`_statusPhase == 'disconnected'`)
        //   2. Recorded daemon error (`_activeError != null`)
        //   3. Aborted / interrupted session
        itemCount: _messages.length +
            ((_awaitingAgentResponse &&
                    _statusPhase != 'disconnected' &&
                    _statusPhase != 'aborting' &&
                    !_isInterrupted &&
                    _activeError == null)
                ? 1
                : 0),
        itemBuilder: (_, i) {
          // Trailing "agent is thinking" row — shown only when the
          // user just sent a non-queued message and the first
          // response signal hasn't landed yet. Rendered as the dots
          // typing skeleton so it matches the in-bubble style.
          if (i == _messages.length) {
            return Center(
              child: SizedBox(
                width: maxW,
                child: const Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: _ChatTypingSkeleton(),
                ),
              ),
            );
          }
          final msg = _messages[i];

          // Inline approval card — if this row is an approval marker
          // whose request is still in ``_pendingApprovals``, replace
          // the text bubble with the interactive banner so the approve
          // / deny controls flow at their seq position instead of
          // sticking to the bottom of the pane. Once the request is
          // resolved (or timed out) it drops out of the pending list
          // and this same row falls back to the plain text marker.
          final approvalReqId = _approvalMarkerReqId[msg.id];
          if (approvalReqId != null) {
            ApprovalRequest? pendingReq;
            for (final p in _pendingApprovals) {
              if (p.id == approvalReqId) {
                pendingReq = p;
                break;
              }
            }
            if (pendingReq != null) {
              _messageKeys.putIfAbsent(msg.id, () => GlobalKey());
              final mKey = _messageKeys[msg.id]!;
              final req = pendingReq;
              return Center(
                key: mKey,
                child: SizedBox(
                  width: maxW,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _ApprovalBanner(
                      request: req,
                      onApprove: (m) => _handleApproval(req, true, m),
                      onDeny: (m) => _handleApproval(req, false, m),
                    ),
                  ),
                ),
              );
            }
          }

          // Retry: find the user message before this assistant error message
          VoidCallback? onRetry;
          if (msg.role == MessageRole.assistant &&
              msg.text.contains('**Error:**') &&
              i > 0 &&
              _messages[i - 1].role == MessageRole.user) {
            final userText = _messages[i - 1].text;
            onRetry = () {
              _ctrl.text = userText;
              _send();
            };
          }
          // Grouping: true when the previous rendered message has the
          // same role — used by ChatBubble to collapse the vertical
          // gap so consecutive same-role turns read as a thread.
          final isGroupedWithPrev =
              i > 0 && _messages[i - 1].role == msg.role;
          // Ensure a GlobalKey exists for scroll-to navigation
          _messageKeys.putIfAbsent(msg.id, () => GlobalKey());
          final mKey = _messageKeys[msg.id]!;

          final bubble = Center(
            key: mKey,
            child: SizedBox(
              width: maxW,
              child: ChatBubble(
                message: msg,
                onRetry: onRetry,
                isGroupedWithPrev: isGroupedWithPrev,
              ),
            ),
          );

          // Only animate the very first time a message appears.
          // Messages already seen (history replay, session switch) render
          // directly — no per-frame Opacity for the whole list.
          //
          // The previous version also added a +6 px Y translate that
          // settled to 0. Looked nice in isolation, but the trailing
          // typing-skeleton row (which has NO transform) appeared to
          // "descend" relative to the bubble during the 200 ms slide:
          // the bubble visually overlapped the skeleton's top by 6 px
          // at frame 0 then released as it slid up, which the eye read
          // as the skeleton sliding DOWN. Fade-only keeps both rows
          // anchored on screen — no perceived drift between them.
          final isNew = _animatedMessageIds.add(msg.id);
          if (!isNew) {
            return bubble;
          }
          return TweenAnimationBuilder<double>(
            key: ValueKey(msg.id),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: child,
            ),
            child: bubble,
          );
        },
      ),
                    ),
                  ),
                ),
    ),
            ),
          ],
        ),
      // Scroll-to-bottom FAB
      if (_showScrollDown)
        Positioned(
          bottom: 12,
          right: 16,
          child: Tooltip(
            message: 'chat.scroll_to_bottom'.tr(),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _scrollToBottom,
                child: Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: context.colors.surfaceAlt,
                    shape: BoxShape.circle,
                    border: Border.all(color: context.colors.borderHover),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 18, color: context.colors.textMuted),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Compact workspace toggle in the top-right of the chat panel.
  /// Mirror of [ChatWorkspaceToggle] on the web. Shows the current
  /// state with the icon (panel-open vs panel-close) and an accent
  /// colour when the workspace is open.
  Widget _buildWorkspaceToggle(AppState state) {
    final c = context.colors;
    return _AppMenuButton(
      name: 'Workspace',
      muted: c.textMuted,
      bright: state.isWorkspaceVisible ? c.accentPrimary : c.textBright,
      surfaceAlt: c.surfaceAlt,
      onTap: state.isWorkspaceVisible
          ? state.closeWorkspace
          : state.showWorkspace,
      leading: Icon(
        state.isWorkspaceVisible
            ? Icons.chevron_right_rounded
            : Icons.chevron_left_rounded,
        size: 16,
        color: state.isWorkspaceVisible ? c.accentPrimary : c.textMuted,
      ),
      hideChevron: true,
    );
  }

  /// Compact app-name dropdown shown absolute in the top-left of the
  /// chat panel. Replaces the previous full top header — a single
  /// "AppName ▾" affordance that opens the session drawer on tap,
  /// like ChatGPT. Doesn't consume any layout space; the conversation
  /// flows underneath.
  Widget _buildAppMenu(AppSummary? app) {
    final c = context.colors;
    final manifest = context.watch<AppState>().manifest;
    final name = manifest.name.isNotEmpty
        ? manifest.name
        : (app?.name ?? '');
    if (name.isEmpty) return const SizedBox.shrink();

    return _AppMenuButton(
      name: name,
      muted: c.textMuted,
      bright: c.textBright,
      surfaceAlt: c.surfaceAlt,
      onTap: () {
        final state = context.read<AppState>();
        state.setPanel(
          state.panel == ActivePanel.sessions
              ? ActivePanel.chat
              : ActivePanel.sessions,
        );
      },
    );
  }

  // ─── Chat export helpers ───────────────────────────────────────────────────

  String _buildMarkdownExport(String? sessionTitle) {
    final now = DateTime.now();
    final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final buf = StringBuffer();
    buf.writeln('# Chat Export');
    buf.writeln('**Date:** $date');
    buf.writeln('**Session:** ${sessionTitle ?? 'Untitled'}');
    buf.writeln();
    buf.writeln('---');
    buf.writeln();

    for (final m in _messages) {
      if (m.role == MessageRole.system) continue;
      final label = m.role == MessageRole.user ? 'You' : 'Assistant';
      buf.writeln('**$label:**');
      final text = m.text.trim();
      if (text.isNotEmpty) {
        buf.writeln(text);
      }
      for (final tc in m.toolCalls) {
        final detail = tc.displayDetail;
        buf.writeln();
        buf.writeln('> Tool: ${tc.displayLabel}${detail.isNotEmpty ? ' - $detail' : ''}');
      }
      buf.writeln();
      buf.writeln('---');
      buf.writeln();
    }

    return buf.toString();
  }

  /// Handler registered with [ChatAttachBridge] so widgets outside
  /// the chat (Monaco header "Add to chat" button, command palette,
  /// future drag-drop from explorer, …) can push a file into the
  /// composer without coupling to `_ChatPanelState` directly.
  ///
  /// Mirrors the normal `_attachments.add(...)` path: on send, the
  /// file is uploaded to the daemon like any other attachment. Shows
  /// a toast so the user knows it landed.
  void _addAttachmentExternal(attach_helpers.AttachmentEntry entry) {
    if (!mounted) return;
    setState(() {
      _attachments.add((
        name: entry.name,
        path: entry.path,
        isImage: entry.isImage,
      ));
    });
    showToast(context, 'Added to chat: ${entry.name}');
    // Pull focus into the composer so the user can type their prompt
    // right away without another click.
    _focus.requestFocus();
  }

  Future<void> _exportChat(String mode, String? sessionTitle) async {
    final markdown = _buildMarkdownExport(sessionTitle);

    if (mode == 'clipboard') {
      await Clipboard.setData(ClipboardData(text: markdown));
      if (mounted) showToast(context, 'Conversation copied to clipboard');
      return;
    }

    // mode == 'markdown' — save as .md file
    if (kIsWeb) {
      // Web: fall back to clipboard
      await Clipboard.setData(ClipboardData(text: markdown));
      if (mounted) showToast(context, 'Conversation copied to clipboard (web)');
      return;
    }

    // Desktop: use file_selector save dialog
    try {
      final now = DateTime.now();
      final defaultName =
          'chat-export-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.md';
      final location = await getSaveLocation(
        suggestedName: defaultName,
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Markdown', extensions: ['md']),
        ],
      );
      if (location == null) return; // user cancelled
      final bytes = utf8.encode(markdown);
      final xfile = XFile.fromData(
        bytes as dynamic,
        mimeType: 'text/markdown',
        name: defaultName,
      );
      await xfile.saveTo(location.path);
      if (mounted) showToast(context, 'Exported to ${location.path}');
    } catch (e) {
      // Fallback to clipboard if save dialog fails
      await Clipboard.setData(ClipboardData(text: markdown));
      if (mounted) showToast(context, 'Saved to clipboard (file save failed)');
    }
  }

  /// Spinner bar — shown above the input bar when agent is working
  /// Inline goal + todo + agents (replaces sidebar, above input)
  Widget _buildInlineWorkspace() {
    final ws = context.watch<WorkspaceState>();
    if (!ws.hasContent) return const SizedBox.shrink();

    final isSmall = MediaQuery.of(context).size.width < 600;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 800),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Goal
              if (ws.goal.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(Icons.flag_rounded, size: 13, color: context.colors.orange),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(ws.goal,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 12, color: context.colors.orange,
                            fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),

              // Todo progress + items
              if (ws.todos.isNotEmpty)
                _InlineTodoBar(ws: ws),

              // Active agents
              if (ws.agents.isNotEmpty)
                _InlineAgents(agents: ws.agents),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiffStatsBar() {
    final ws = context.watch<WorkspaceService>();

    final edited = ws.buffers.where((b) =>
        b.isEdited && !b.path.startsWith('_approval/') && !b.path.startsWith('_ask_user/')).toList();

    if (edited.isEmpty) return const SizedBox.shrink();

    final c = context.colors;
    final isSmall = MediaQuery.of(context).size.width < 600;

    // Totals use PENDING counters (delta vs last-approved baseline) so
    // the "+X -Y in N files" summary reflects every write since approve,
    // not the per-op delta of the last edit nor the session-wide total
    // which double-counts compensated changes.
    int totalIns = 0, totalDel = 0;
    for (final b in edited) {
      totalIns += b.pendingInsertions;
      totalDel += b.pendingDeletions;
    }
    final fileCount = edited.length;

    if (fileCount == 0 && totalIns == 0 && totalDel == 0) {
      return const SizedBox.shrink();
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 800),
        child: GestureDetector(
          onTap: () {
            final appState = context.read<AppState>();
            if (!appState.isWorkspaceVisible) appState.showWorkspace();
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(Icons.description_outlined, size: 14, color: c.textMuted),
                const SizedBox(width: 8),
                // File count
                Text(
                  '$fileCount file${fileCount > 1 ? 's' : ''} changed',
                  style: GoogleFonts.inter(
                    fontSize: 12, fontWeight: FontWeight.w500, color: c.text),
                ),
                const SizedBox(width: 10),
                // Insertions
                if (totalIns > 0)
                  Text('+$totalIns',
                    style: GoogleFonts.firaCode(
                      fontSize: 11, fontWeight: FontWeight.w600, color: c.green)),
                if (totalIns > 0 && totalDel > 0)
                  const SizedBox(width: 6),
                // Deletions
                if (totalDel > 0)
                  Text('-$totalDel',
                    style: GoogleFonts.firaCode(
                      fontSize: 11, fontWeight: FontWeight.w600, color: c.red)),
                const Spacer(),
                ...edited.take(3).map((b) => Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(b.filename,
                      style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  ),
                )),
                if (edited.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('+${edited.length - 3}',
                      style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  ),
                const SizedBox(width: 8),
                // Open workspace arrow
                Icon(Icons.open_in_new_rounded, size: 12, color: c.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Thin status strip rendered below the chat header. Shows replay
  /// progress while rebuilding from history, a connection pill (Live /
  /// Reconnecting), and an interrupted banner where applicable. Every
  /// piece disappears when there's nothing to say so the strip is
  /// invisible during normal live operation.
  Widget _buildStatusStrip() {
    final c = context.colors;
    final manifest = context.watch<AppState>().manifest;
    final accent = manifest.accent ?? c.accentPrimary;

    // Replay bar wins — it's transient and the most important.
    if (_isReplaying && _replayTotal > 0) {
      final progress = _replayTotal > 0
          ? (_replayDone / _replayTotal).clamp(0.0, 1.0)
          : 0.0;
      return Container(
        color: c.surface.withValues(alpha: 0.6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: c.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(accent),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation(c.textDim),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Loading history — $_replayDone / $_replayTotal events',
                    style: GoogleFonts.inter(
                        fontSize: 10.5, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final pills = <Widget>[];

    // A live/running turn always wins over "interrupted" — the
    // interrupted flag can be stale when the daemon recovered and
    // is already streaming again.
    final anyActivity = _isSending || _turnInProgress;

    if (anyActivity) {
      if (_turnInProgress && !_isSending) {
        pills.add(_StatusPill(
          label: 'chat.turn_in_progress'.tr(),
          icon: Icons.sync_rounded,
          fg: accent,
          bg: accent.withValues(alpha: 0.08),
          pulse: true,
        ));
      }
    } else if (_isInterrupted) {
      pills.add(_StatusPill(
        label: 'chat.session_interrupted'.tr(),
        icon: Icons.pause_circle_filled_rounded,
        fg: c.red,
        bg: c.red.withValues(alpha: 0.08),
        tooltip: 'chat.session_interrupted_hint'.tr(),
      ));
    }

    // Disconnected state is surfaced by the actionable phase bar
    // (_buildDisconnectedBar) under the header — adding a pill here
    // too would duplicate the info without adding value.

    // Context pressure bar removed from the status strip — the same
    // signal is already shown by ``_ContextRing`` in the composer
    // toolbar, which is more visible and offers click-to-details.
    // Displaying both duplicated chrome without adding information.

    // Tool activity bar — live view of what the agent is doing right now.
    Widget? toolBar;
    if (_activeToolName != null && _activeToolStartedAt != null) {
      final elapsed =
          DateTime.now().difference(_activeToolStartedAt!).inMilliseconds;
      toolBar = _ToolActivityBar(
        toolName: _activeToolName!,
        elapsedMs: elapsed,
        accent: accent,
        onAbort: _isSending ? _abort : null,
      );
    }

    if (pills.isEmpty && toolBar == null) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?toolBar,
        if (pills.isNotEmpty)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < pills.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  pills[i],
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// Compact find-in-chat bar. Counts how many messages contain the
  /// query (case-insensitive) so the user sees matches live as they
  /// type. Esc dismisses, empty query dismisses via the close button.
  Widget _buildFindBar() {
    final c = context.colors;
    final q = _findQuery.toLowerCase();
    int hits = 0;
    if (q.isNotEmpty) {
      for (final m in _messages) {
        if (m.text.toLowerCase().contains(q)) hits++;
      }
    }
    final isSmall = MediaQuery.of(context).size.width < 600;
    // Capped to the composer rail (800 px on desktop, full-width on
    // < 600 px) — was a full-width strip with `border-bottom` across
    // the screen. Now a centered chip with a full border for visual
    // cohesion with the rest of the chat. Mirror of the web fix.
    return Center(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: isSmall ? double.infinity : 800),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.border),
          ),
          child: Row(
        children: [
          Icon(Icons.search_rounded, size: 14, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _findCtrl,
              focusNode: _findFocus,
              onChanged: (v) => setState(() => _findQuery = v),
              style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'chat.find_in_conversation'.tr(),
                hintStyle:
                    GoogleFonts.firaCode(fontSize: 12, color: c.textMuted),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (q.isNotEmpty)
            Text(
              '$hits ${hits == 1 ? "match" : "matches"}',
              style: GoogleFonts.firaCode(fontSize: 10.5, color: c.textMuted),
            ),
          const SizedBox(width: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() {
                _showFind = false;
                _findQuery = '';
                _findCtrl.clear();
              }),
              child: Icon(Icons.close_rounded,
                  size: 14, color: c.textMuted),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  /// Minimalist status bar — replaces the old always-on "responding"
  /// spinner with a surgical, purpose-built bar.
  ///
  /// Visibility rules — the bar is **invisible** unless one of these
  /// is true:
  ///   * A tool has been running ≥ 2 s → show tool name + live duration.
  ///   * The status phase is unusual / actionable: `rate_limited`,
  ///     `compacting`, `interrupted`, `aborting`, `resuming`. Short-
  ///     lived phases like `requesting`/`responding`/`generating`
  ///     stay hidden — the send button's rotating ring already
  ///     communicates "loop in progress".
  ///
  /// Tokens and turn counters previously shown here have moved to
  /// the per-message token footer (on each completed assistant
  /// bubble) so the composer area stays quiet.
  Widget _buildSpinnerBar() {
    final c = context.colors;

    // ── 1. Long-running tool ─────────────────────────────────────
    final tool = _activeToolName;
    final startedAt = _activeToolStartedAt;
    if (tool != null && startedAt != null) {
      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed.inMilliseconds >= 1800) {
        return _buildToolBar(c, tool, elapsed);
      }
    }

    // ── 2. Disconnected — intentionally NOT shown here anymore.
    //       The top `_ConnectivityBanner` (main.dart) is the sole
    //       indicator now; doubling up above the composer was the
    //       loud strip the user asked us to remove.

    // ── 3. Actionable phases ─────────────────────────────────────
    if (_statusPhase.isNotEmpty) {
      final (color, label, icon) = _actionablePhase(c, _statusPhase);
      if (color != null) {
        return _buildPhaseBar(c, color, label, icon);
      }
    }

    // Nothing worth showing — stay invisible so the composer sits
    // flush against the messages.
    return const SizedBox.shrink();
  }

  /// Convert a status phase into UI intent, or return (null, '', …)
  /// for short-lived phases the send button already covers.
  (Color?, String, IconData) _actionablePhase(AppColors c, String phase) {
    if (phase.startsWith('rate_limited:')) {
      return (c.orange,
          'chat.rate_limited_with'.tr(namedArgs: {'reason': phase.substring(13)}),
          Icons.speed_rounded);
    }
    return switch (phase) {
      'rate_limited'  => (c.orange, 'chat.rate_limited'.tr(), Icons.speed_rounded),
      'compacting'    => (c.purple, 'chat.compacting_context'.tr(), Icons.compress_rounded),
      'interrupted'   => (c.orange, 'chat.interrupted_resume_hint'.tr(), Icons.pause_circle_outline_rounded),
      'aborting'      => (c.red, 'chat.aborting'.tr(), Icons.stop_circle_outlined),
      'resuming'      => (c.orange, 'chat.resuming'.tr(), Icons.play_circle_outline_rounded),
      // 'disconnected' is handled by _buildDisconnectedBar (actionable).
      // Everything else (requesting, responding, thinking, generating,
      // waiting, turn_start, tool_use…) is covered by the send-button
      // ring — no duplicate indicator.
      _ => (null, '', Icons.circle),
    };
  }

  Widget _buildToolBar(AppColors c, String tool, Duration elapsed) {
    final secs = elapsed.inMilliseconds / 1000.0;
    final pretty = secs < 60
        ? '${secs.toStringAsFixed(1)}s'
        : '${(secs / 60).floor()}m ${(secs % 60).floor()}s';
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width < 600
              ? double.infinity : 800,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.orange.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: c.orange.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Icon(Icons.build_rounded, size: 11, color: c.orange),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(tool,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: c.orange,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Text('·',
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.orange.withValues(alpha: 0.5))),
                const SizedBox(width: 8),
                Text(pretty,
                    style: GoogleFonts.firaCode(
                        fontSize: 11,
                        color: c.orange,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseBar(
      AppColors c, Color color, String label, IconData icon) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width < 600
              ? double.infinity : 800,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 11.5,
                          color: color,
                          fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Synthesize workbench events from tool_call results.
  /// When the daemon doesn't emit separate workbench_* events, we extract
  /// file content from tool_call results and open them in the workspace.
  static bool _isHiddenTool(String name) {
    final lower = name.toLowerCase();
    return _hiddenToolNames.contains(lower) ||
        lower.contains('memory') ||
        lower.contains('agent_wait') ||
        lower.contains('agent_spawn') ||
        lower.contains('spawn_agent') ||
        lower.contains('search_tools') ||
        lower.contains('list_categories') ||
        lower.contains('browse_category') ||
        lower.contains('get_tool');
  }

  static const _hiddenToolNames = {
    'setgoal', 'set_goal',
    'todoadd', 'add_todo',
    'todoupdate', 'update_todo',
    'remember', 'recall', 'forget',
    'agentwaitall', 'agent_wait_all', 'agent_wait',
    'spawn_agent', 'agent_spawn',
    'agent_result', 'agent_status', 'agent_cancel', 'agent_list',
    'search_tools', 'get_tool', 'list_categories', 'browse_category',
  };

  /// Convert internal tool names to user-friendly spinner labels.
  ///
  /// Priority order (most authoritative first):
  ///   1. `display.verb` from the daemon (when [hasDisplay] is true)
  ///      — the daemon's tool-contract v2 block carries curated copy
  ///      ("Read", "Search", …). We trust it verbatim.
  ///   2. Legacy hardcoded phrases for plumbing tool names — only
  ///      used when the daemon didn't ship a display block (old
  ///      daemons, custom apps).
  ///   3. Fallback to the raw verb / tool name.
  static String _friendlySpinnerLabel(String shortName, String verb,
      {bool hasDisplay = false}) {
    if (hasDisplay && verb.isNotEmpty) return verb;
    final lower = shortName.toLowerCase();
    if (lower == 'agentwaitall' || lower == 'agent_wait_all') return 'Waiting for agents…';
    if (lower == 'agent_wait') return 'Waiting for agent…';
    if (lower == 'spawn_agent' || lower == 'agent_spawn') return 'Spawning agent…';
    if (lower == 'search_tools' || lower == 'list_categories') return 'Discovering tools…';
    if (lower == 'browse_category' || lower == 'get_tool') return 'Browsing tools…';
    if (lower == 'run_parallel') return 'Running parallel…';
    if (lower.contains('recall')) return 'Recalling memory…';
    if (lower.contains('remember')) return 'Remembering…';
    if (lower.contains('set_goal') || lower == 'setgoal') return 'Setting goal…';
    if (lower.contains('add_todo') || lower == 'todoadd') return 'Adding task…';
    if (lower.contains('update_todo') || lower == 'todoupdate') return 'Updating task…';
    return verb;
  }

}

// ─── Workspace chip (empty-state, above composer) ────────────────────────────

/// Compact chip rendered above the composer when an app requires a workspace
/// folder. Orange-tinted when no workspace is set (clickable to pick one),
/// neutral when a folder is already active (clickable to change it).
/// When [highlighted] flips to true, plays a horizontal shake + glow to
/// draw attention after the user pressed Send without picking a folder.
class _WorkspaceChip extends StatefulWidget {
  final String workspace;
  final bool highlighted;
  final VoidCallback onTap;
  const _WorkspaceChip({
    required this.workspace,
    required this.highlighted,
    required this.onTap,
  });

  @override
  State<_WorkspaceChip> createState() => _WorkspaceChipState();
}

class _WorkspaceChipState extends State<_WorkspaceChip>
    with SingleTickerProviderStateMixin {
  bool _h = false;
  late final AnimationController _shake;
  late final Animation<double> _shakeAnim;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6, end: -5), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -5, end: 4), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 4, end: -2), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -2, end: 0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shake, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(_WorkspaceChip old) {
    super.didUpdateWidget(old);
    if (widget.highlighted && !old.highlighted) {
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  String _basename(String p) {
    final n = p.replaceAll('\\', '/');
    final i = n.lastIndexOf('/');
    return (i < 0 || i == n.length - 1) ? n : n.substring(i + 1);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final empty = widget.workspace.isEmpty;
    final label = empty ? 'Pick workspace' : _basename(widget.workspace);
    final chipColor = empty ? c.orange : c.textMuted;
    final isLit = widget.highlighted && empty;
    return AnimatedBuilder(
      animation: _shakeAnim,
      builder: (_, child) => Transform.translate(
        offset: Offset(_shakeAnim.value, 0),
        child: child,
      ),
      child: Align(
        alignment: Alignment.center,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _h = true),
          onExit: (_) => setState(() => _h = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: empty
                    ? c.orange.withValues(alpha: isLit ? 0.22 : (_h ? 0.14 : 0.08))
                    : (_h ? c.surfaceAlt : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: empty
                      ? c.orange.withValues(alpha: isLit ? 0.8 : (_h ? 0.5 : 0.3))
                      : (_h ? c.borderHover : c.border),
                  width: isLit ? 1.5 : 1.0,
                ),
                boxShadow: isLit
                    ? [
                        BoxShadow(
                          color: c.orange.withValues(alpha: 0.35),
                          blurRadius: 10,
                          spreadRadius: -2,
                        )
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    empty ? Icons.folder_open_outlined : Icons.folder_outlined,
                    size: 12,
                    color: chipColor,
                  ),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        color: chipColor,
                        fontWeight: empty ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (!empty) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.edit_outlined, size: 10, color: c.textDim),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// ─── Approval banner ──────────────────────────────────────────────────────────

class _ApprovalBanner extends StatefulWidget {
  final ApprovalRequest request;
  final void Function(String message) onApprove;
  final void Function(String message) onDeny;
  const _ApprovalBanner(
      {required this.request, required this.onApprove, required this.onDeny});

  @override
  State<_ApprovalBanner> createState() => _ApprovalBannerState();
}

class _ApprovalBannerState extends State<_ApprovalBanner>
    with SingleTickerProviderStateMixin {
  final TextEditingController _inputCtrl = TextEditingController();
  bool _showDenyInput = false;
  int _remainingSeconds = 300;
  Timer? _timer;
  Timer? _pulseStopTimer;
  late AnimationController _pulseCtrl;

  // ── Enhanced ask_user state ───────────────────────────────────────────
  final Set<String> _selectedChoices = {};
  final Map<String, dynamic> _formValues = {};
  bool _formSubmitted = false; // for validation display

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    // Always pulse — either continuously for high risk, or a short
    // 3-cycle attention grabber for medium/low. The daemon doesn't
    // emit a dedicated "new approval" sound, so the visual cue does
    // the work. Stops automatically after ~3.6s for non-critical.
    if (widget.request.riskLevel == 'high') {
      _pulseCtrl.repeat(reverse: true);
    } else {
      _pulseCtrl.repeat(reverse: true);
      _pulseStopTimer = Timer(const Duration(milliseconds: 3600), () {
        if (mounted) _pulseCtrl.stop();
      });
    }
    _updateRemaining();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateRemaining();
    });
  }

  void _updateRemaining() {
    final elapsed =
        DateTime.now().millisecondsSinceEpoch / 1000 - widget.request.createdAt;
    final remaining = (300 - elapsed).clamp(0, 300).toInt();
    if (remaining != _remainingSeconds) {
      setState(() => _remainingSeconds = remaining);
    }
    if (remaining <= 0) {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseStopTimer?.cancel();
    _pulseCtrl.dispose();
    _inputCtrl.dispose();
    super.dispose();
  }

  /// Find the "main" param key — the one most likely shown in description.
  static String? _mainParamKey(Map<String, dynamic> params) {
    for (final k in ['command', 'cmd', 'query', 'question', 'content',
                     'path', 'file_path', 'url', 'script']) {
      if (params.containsKey(k)) return k;
    }
    return null;
  }

  /// Strip module prefix from tool names for display.
  /// "shell.bash" → "Bash", "filesystem.write" → "Write",
  /// "workspace.ws_write" → "Write"
  static String _simplifyToolName(String name) {
    final segs = name
        .split(RegExp(r'[._\-/:]+'))
        .where((s) => s.isNotEmpty && s.toLowerCase() != 'mcp')
        .toList();
    if (segs.isEmpty) return name;
    var last = segs.last;
    // Strip ws_ prefix
    if (last.toLowerCase().startsWith('ws')) {
      last = last.substring(2);
      if (last.startsWith('_')) last = last.substring(1);
    }
    if (last.isEmpty) last = segs.last;
    return last[0].toUpperCase() + last.substring(1);
  }

  String get _timerText {
    final m = _remainingSeconds ~/ 60;
    final s = _remainingSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.colors;
    final isAsk = widget.request.isAskUser;

    final riskColor = switch (widget.request.riskLevel) {
      'high' => ac.red,
      'medium' => ac.orange,
      _ => ac.green,
    };

    final borderColor =
        widget.request.riskLevel == 'high' ? ac.red : ac.border;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: ac.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: borderColor,
            width: widget.request.riskLevel == 'high' ? 1.5 : 1,
          ),
        ),
        child: isAsk ? _buildAskUser(ac) : _buildToolApproval(ac, riskColor),
      ),
    );
  }

  // ── Tool approval layout ────────────────────────────────────────────────

  Widget _buildToolApproval(AppColors ac, Color riskColor) {
    final toolLabel = _simplifyToolName(widget.request.toolName);
    // Compute the effective description once: prefer the top-level
    // `request.description` (the daemon's canonical intent string),
    // fall back to `params.description` only if the top one is
    // empty. Never surface both — they're redundant by contract.
    final description = _effectiveDescription();
    // Pick the primary action block (command, query, file preview,
    // url…) based on tool type. Null when the tool has no "main"
    // param — then the description alone carries the intent.
    final primary = _buildPrimaryActionBlock(ac);
    // Params that should appear as a small secondary block. Excludes
    // description + every key already consumed by the primary block
    // so nothing appears twice.
    final secondary = _secondaryParams();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. META BAR — compact chrome: risk pill, tool, timer,
        //    close. Small so the description below can dominate.
        _buildApprovalMetaBar(ac, riskColor, toolLabel),

        // 2. INTENT DESCRIPTION — the most important line on the
        //    card. Big, readable, bright — this is what the user
        //    reads to decide Approve / Deny.
        if (description.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            description,
            style: GoogleFonts.inter(
              fontSize: 15,
              color: ac.textBright,
              height: 1.55,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
        ],

        // 3. PRIMARY ACTION — tool-specific. Bash = command in a
        //    code block, Read = path + small preview, Edit = path +
        //    diff, etc. Kept tight so tall previews don't shove the
        //    Allow / Deny buttons below the fold.
        if (primary != null) ...[
          const SizedBox(height: 12),
          primary,
        ],

        // 4. SECONDARY PARAMS — only the bits that didn't already
        //    land in the description or the primary block. Rendered
        //    as a calm key-value list.
        if (secondary.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildSecondaryParamsBlock(ac, secondary),
        ],
        const SizedBox(height: 14),
        // Buttons or deny-reason input
        if (_showDenyInput)
          _buildDenyInput(ac)
        else
          Row(
            children: [
              _ABtn(
                  label: 'chat.allow'.tr(),
                  bg: ac.green.withValues(alpha: 0.1),
                  border: ac.green.withValues(alpha: 0.3),
                  fg: ac.green,
                  onTap: () => widget.onApprove('')),
              const SizedBox(width: 8),
              _ABtn(
                  label: 'chat.deny'.tr(),
                  bg: ac.red.withValues(alpha: 0.1),
                  border: ac.red.withValues(alpha: 0.3),
                  fg: ac.red,
                  onTap: () => setState(() => _showDenyInput = true)),
            ],
          ),
      ],
    );
  }

  // ── Premium approval building blocks ────────────────────────────────────

  /// The canonical intent description shown at the top of the
  /// approval card. We prefer the top-level `request.description`
  /// (the daemon's explicit intent string) and only fall back to
  /// `params.description` when the top-level is empty. The two are
  /// never concatenated — that's how the "description appears twice"
  /// bug used to happen.
  String _effectiveDescription() {
    final topDesc = widget.request.description.trim();
    if (topDesc.isNotEmpty) return topDesc;
    final paramDesc =
        (widget.request.params['description'] as String? ?? '').trim();
    return paramDesc;
  }

  /// Compact meta bar: risk dot + tool name + risk badge + timer +
  /// close. Sits above the description so the description has the
  /// visual weight it deserves.
  Widget _buildApprovalMetaBar(
      AppColors ac, Color riskColor, String toolLabel) {
    return Row(
      children: [
        _riskDot(riskColor),
        const SizedBox(width: 8),
        Text(
          toolLabel,
          style: GoogleFonts.inter(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: ac.textBright,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: riskColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: riskColor.withValues(alpha: 0.4)),
          ),
          child: Text(
            widget.request.riskLevel.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 9.5,
              color: riskColor,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        const Spacer(),
        _timerBadge(ac),
      ],
    );
  }

  /// Build the tool-specific "primary action" block. For bash/shell
  /// this is the command rendered as a proper code block; for file
  /// ops it's the existing file preview / "View in workspace"
  /// affordance; for everything else it's the main param's value in
  /// a code block. Returns null when the tool has no main param —
  /// in which case the description alone carries the intent and we
  /// fall through to the secondary params section.
  Widget? _buildPrimaryActionBlock(AppColors ac) {
    // File operations keep their existing rich preview (path + content
    // or diff or "View in workspace" CTA). Unchanged behaviour so we
    // don't regress the edit/write/read cases.
    if (_isFileOp && _filePath != null) {
      return _buildFileOpBlock(ac);
    }

    final mainKey = _mainParamKey(widget.request.params);
    if (mainKey == null) return null;
    final rawVal = widget.request.params[mainKey];
    final valStr = rawVal?.toString().trim() ?? '';
    if (valStr.isEmpty) return null;

    // Detect shell-ish tools so we can prefix the command with "$"
    // and pick a "shell" language hint for eventual syntax
    // highlighting.
    final toolLower = widget.request.toolName.toLowerCase();
    final isShell = mainKey == 'command' ||
        mainKey == 'cmd' ||
        toolLower.contains('bash') ||
        toolLower.contains('shell') ||
        toolLower.contains('zsh');

    return _ApprovalCodeBlock(
      label: _labelForMainParam(mainKey),
      content: valStr,
      shellPrefix: isShell,
    );
  }

  /// Human label for the main-param block header. Keeps the UI
  /// grounded by naming what the block represents.
  String _labelForMainParam(String key) => switch (key) {
        'command' || 'cmd' => 'Command',
        'query' => 'Query',
        'question' => 'Question',
        'script' => 'Script',
        'sql' => 'SQL',
        'url' => 'URL',
        'content' => 'Content',
        'path' || 'file_path' => 'Path',
        _ => key,
      };

  /// File-op primary block — kept close to the legacy rendering so
  /// the edit/write/read flows stay familiar. The path and preview
  /// are surfaced together; large files route to the workspace.
  Widget _buildFileOpBlock(AppColors ac) {
    final path = _filePath!;
    final content = _fileContent ?? '';
    final isSmall = content.length <= 500;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: ac.codeBlockHeader,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ac.border),
          ),
          child: Row(
            children: [
              Icon(
                _isEditOp
                    ? Icons.edit_outlined
                    : Icons.add_circle_outline,
                size: 14,
                color: _isEditOp ? ac.orange : ac.green,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  path,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 12.5,
                    color: ac.textBright,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (content.isNotEmpty)
                Text(
                  '${content.split('\n').length} lines',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    color: ac.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
        if (isSmall && content.isNotEmpty) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ac.codeBlockBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ac.border),
              ),
              child: SingleChildScrollView(
                child: Text(
                  content,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 12,
                    color: ac.text,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ),
        ],
        if (!isSmall) ...[
          const SizedBox(height: 6),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: _openFileInWorkspace,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: ac.blue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: ac.blue.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isEditOp
                          ? Icons.compare_arrows_rounded
                          : Icons.visibility_outlined,
                      size: 14,
                      color: ac.blue,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isEditOp
                          ? 'View diff in workspace  →'
                          : 'Preview file in workspace  →',
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: ac.blue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Returns params that should appear in the secondary block —
  /// everything EXCEPT:
  ///   * `description` (already at the top)
  ///   * the `mainParamKey` (shown in the primary block)
  ///   * `path` / `file_path` (shown in the file op block)
  ///   * empty / null values
  Map<String, dynamic> _secondaryParams() {
    final original = widget.request.params;
    final mainKey = _mainParamKey(original);
    final out = <String, dynamic>{};
    for (final entry in original.entries) {
      final key = entry.key.toLowerCase();
      if (key == 'description') continue;
      if (_isFileOp && (key == 'path' || key == 'file_path')) continue;
      if (mainKey != null && entry.key == mainKey) continue;
      final v = entry.value;
      if (v == null) continue;
      if (v is String && v.trim().isEmpty) continue;
      out[entry.key] = v;
    }
    return out;
  }

  /// Compact secondary-param listing. Each entry renders a small
  /// label + value row — not a giant code block. Meant for things
  /// like `timeout: 30`, `max_results: 10`, `cwd: /tmp` that
  /// accompany the primary action without dominating it.
  Widget _buildSecondaryParamsBlock(
      AppColors ac, Map<String, dynamic> params) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ac.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ac.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in params.entries) ...[
            _secondaryParamRow(ac, e.key, e.value),
            if (e.key != params.keys.last) const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _secondaryParamRow(AppColors ac, String key, Object? value) {
    final str = value?.toString() ?? '';
    final isLong = str.length > 80;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            key,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: ac.textMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isLong ? '${str.substring(0, 77)}…' : str,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 12,
              color: ac.textBright,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  // ── Ask user layout — mode router ────────────────────────────────────────

  Widget _buildAskUser(AppColors ac) {
    final req = widget.request;
    if (req.isForm) return _buildFormMode(ac);
    if (req.isChoices) return _buildChoicesMode(ac);
    if (req.isContentReview) return _buildContentReviewMode(ac);
    return _buildSimpleQuestionMode(ac);
  }

  /// Header row shared by all ask_user modes.
  Widget _askHeader(AppColors ac) {
    return Row(
      children: [
        Icon(Icons.help_outline, size: 14, color: ac.blue),
        const SizedBox(width: 7),
        Text(
          'chat.agent_has_question'.tr(),
          style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ac.blue),
        ),
        const Spacer(),
        _timerBadge(ac),
      ],
    );
  }

  /// Scrollable question text shared by all modes.
  Widget _questionText(AppColors ac) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: SingleChildScrollView(
        child: ChatMarkdown(text: widget.request.question),
      ),
    );
  }

  // ── Mode 1: Simple Question ──────────────────────────────────────────

  Widget _buildSimpleQuestionMode(AppColors ac) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _askHeader(ac),
        const SizedBox(height: 8),
        _questionText(ac),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ac.border),
          ),
          child: TextField(
            controller: _inputCtrl,
            style: GoogleFonts.inter(fontSize: 13, color: ac.textBright),
            decoration: InputDecoration(
              hintText: 'chat.type_response_hint'.tr(),
              hintStyle: GoogleFonts.inter(fontSize: 13, color: ac.textDim),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            maxLines: 3,
            minLines: 1,
            onSubmitted: (_) => _submitResponse(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _ABtn(
                label: 'chat.respond'.tr(),
                bg: ac.green.withValues(alpha: 0.1),
                border: ac.green.withValues(alpha: 0.3),
                fg: ac.green,
                onTap: _submitResponse),
            const SizedBox(width: 8),
            _ABtn(
                label: 'chat.skip'.tr(),
                bg: ac.textDim.withValues(alpha: 0.1),
                border: ac.textDim.withValues(alpha: 0.3),
                fg: ac.textMuted,
                onTap: () => widget.onDeny('')),
          ],
        ),
      ],
    );
  }

  // ── Mode 2: Choices ──────────────────────────────────────────────────

  Widget _buildChoicesMode(AppColors ac) {
    final req = widget.request;
    final choices = req.choices!;
    final multi = req.allowMultiple;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _askHeader(ac),
        const SizedBox(height: 8),
        _questionText(ac),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: choices.map((choice) {
                final selected = _selectedChoices.contains(choice);
                return _ChoicePill(
                  label: choice,
                  selected: selected,
                  showCheckbox: multi,
                  colors: ac,
                  onTap: () {
                    if (multi) {
                      setState(() {
                        if (selected) {
                          _selectedChoices.remove(choice);
                        } else {
                          _selectedChoices.add(choice);
                        }
                      });
                    } else {
                      // Single select: immediately approve
                      widget.onApprove(choice);
                    }
                  },
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            if (multi)
              _ABtn(
                  label: 'chat.confirm_count'.tr(namedArgs: {'n': '${_selectedChoices.length}'}),
                  bg: _selectedChoices.isNotEmpty
                      ? ac.green.withValues(alpha: 0.1)
                      : ac.textDim.withValues(alpha: 0.05),
                  border: _selectedChoices.isNotEmpty
                      ? ac.green.withValues(alpha: 0.3)
                      : ac.border,
                  fg: _selectedChoices.isNotEmpty ? ac.green : ac.textDim,
                  onTap: _selectedChoices.isNotEmpty
                      ? () => widget.onApprove(_selectedChoices.join(','))
                      : () {}),
            if (multi) const SizedBox(width: 8),
            _ABtn(
                label: 'chat.skip'.tr(),
                bg: ac.textDim.withValues(alpha: 0.1),
                border: ac.textDim.withValues(alpha: 0.3),
                fg: ac.textMuted,
                onTap: () => widget.onDeny('')),
          ],
        ),
      ],
    );
  }

  // ── Mode 3: Content Review ───────────────────────────────────────────

  Widget _buildContentReviewMode(AppColors ac) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _askHeader(ac),
        const SizedBox(height: 8),
        _questionText(ac),
        const SizedBox(height: 6),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => _openGenericInWorkspace(),
            child: Text(
              'chat.view_in_panel'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 12,
                  color: ac.blue,
                  decoration: TextDecoration.underline,
                  decorationColor: ac.blue),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ac.border),
          ),
          child: TextField(
            controller: _inputCtrl,
            style: GoogleFonts.inter(fontSize: 13, color: ac.textBright),
            decoration: InputDecoration(
              hintText: 'chat.feedback_optional_hint'.tr(),
              hintStyle: GoogleFonts.inter(fontSize: 13, color: ac.textDim),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            maxLines: 3,
            minLines: 1,
            onSubmitted: (_) => widget.onApprove(_inputCtrl.text.trim()),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _ABtn(
                label: 'chat.approve'.tr(),
                bg: ac.green.withValues(alpha: 0.1),
                border: ac.green.withValues(alpha: 0.3),
                fg: ac.green,
                onTap: () => widget.onApprove(_inputCtrl.text.trim())),
            const SizedBox(width: 8),
            _ABtn(
                label: 'chat.reject'.tr(),
                bg: ac.red.withValues(alpha: 0.1),
                border: ac.red.withValues(alpha: 0.3),
                fg: ac.red,
                onTap: () => widget.onDeny(_inputCtrl.text.trim())),
          ],
        ),
      ],
    );
  }

  // ── Mode 4: Form ─────────────────────────────────────────────────────

  Widget _buildFormMode(AppColors ac) {
    final req = widget.request;
    final fields = req.formFields!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _askHeader(ac),
        const SizedBox(height: 8),
        _questionText(ac),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: fields.map((f) => _buildFormField(ac, f)).toList(),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _ABtn(
                label: 'chat.submit'.tr(),
                bg: ac.green.withValues(alpha: 0.1),
                border: ac.green.withValues(alpha: 0.3),
                fg: ac.green,
                onTap: () => _submitForm(fields)),
            const SizedBox(width: 8),
            _ABtn(
                label: 'chat.cancel'.tr(),
                bg: ac.textDim.withValues(alpha: 0.1),
                border: ac.textDim.withValues(alpha: 0.3),
                fg: ac.textMuted,
                onTap: () => widget.onDeny('')),
          ],
        ),
      ],
    );
  }

  Widget _buildFormField(AppColors ac, Map<String, dynamic> field) {
    final name = field['name'] as String? ?? '';
    final label = field['label'] as String? ?? name;
    final type = field['type'] as String? ?? 'text';
    final required_ = field['required'] as bool? ?? false;
    final options = (field['options'] as List?)?.cast<String>() ?? [];
    final hint = field['hint'] as String? ?? '';
    final showError = _formSubmitted && required_ && _isFieldEmpty(name, type);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              text: label,
              children: [
                if (required_)
                  TextSpan(
                      text: ' *',
                      style: TextStyle(color: ac.red)),
              ],
            ),
            style: GoogleFonts.inter(
                fontSize: 12, fontWeight: FontWeight.w500, color: ac.text),
          ),
          const SizedBox(height: 4),
          _buildFieldWidget(ac, name, type, options, hint),
          if (showError) ...[
            const SizedBox(height: 2),
            Text('chat.required_field'.tr(),
                style: GoogleFonts.inter(fontSize: 10, color: ac.red)),
          ],
        ],
      ),
    );
  }

  bool _isFieldEmpty(String name, String type) {
    final val = _formValues[name];
    if (val == null) return true;
    if (val is String && val.isEmpty) return true;
    if (val is List && val.isEmpty) return true;
    return false;
  }

  Widget _buildFieldWidget(
      AppColors ac, String name, String type, List<String> options, String hint) {
    switch (type) {
      case 'select':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ac.border),
          ),
          child: DropdownButton<String>(
            value: _formValues[name] as String?,
            isExpanded: true,
            dropdownColor: ac.surface,
            underline: const SizedBox.shrink(),
            hint: Text(hint.isNotEmpty ? hint : 'chat.select_hint'.tr(),
                style: GoogleFonts.inter(fontSize: 13, color: ac.textDim)),
            style: GoogleFonts.inter(fontSize: 13, color: ac.textBright),
            items: options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) => setState(() => _formValues[name] = v),
          ),
        );
      case 'textarea':
        return Container(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ac.border),
          ),
          child: TextField(
            style: GoogleFonts.inter(fontSize: 13, color: ac.textBright),
            decoration: InputDecoration(
              hintText: hint.isNotEmpty ? hint : 'Enter text...',
              hintStyle: GoogleFonts.inter(fontSize: 13, color: ac.textDim),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            maxLines: 3,
            minLines: 3,
            onChanged: (v) => _formValues[name] = v,
          ),
        );
      case 'checkbox':
        final selected =
            (_formValues[name] as List<String>?) ?? <String>[];
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: options.map((o) {
            final checked = selected.contains(o);
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    final list = List<String>.from(selected);
                    if (checked) {
                      list.remove(o);
                    } else {
                      list.add(o);
                    }
                    _formValues[name] = list;
                  });
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      checked
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 16,
                      color: checked ? ac.blue : ac.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(o,
                        style: GoogleFonts.inter(
                            fontSize: 12, color: ac.text)),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      case 'toggle':
        return Row(
          children: [
            Switch(
              value: _formValues[name] as bool? ?? false,
              onChanged: (v) => setState(() => _formValues[name] = v),
              activeTrackColor: ac.blue.withValues(alpha: 0.5),
              activeThumbColor: ac.blue,
            ),
          ],
        );
      case 'number':
        return Container(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ac.border),
          ),
          child: TextField(
            style: GoogleFonts.inter(fontSize: 13, color: ac.textBright),
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ],
            decoration: InputDecoration(
              hintText: hint.isNotEmpty ? hint : 'Enter number...',
              hintStyle: GoogleFonts.inter(fontSize: 13, color: ac.textDim),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            onChanged: (v) => _formValues[name] = v,
          ),
        );
      default: // 'text'
        return Container(
          decoration: BoxDecoration(
            color: ac.bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: ac.border),
          ),
          child: TextField(
            style: GoogleFonts.inter(fontSize: 13, color: ac.textBright),
            decoration: InputDecoration(
              hintText: hint.isNotEmpty ? hint : 'Enter text...',
              hintStyle: GoogleFonts.inter(fontSize: 13, color: ac.textDim),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            onChanged: (v) => _formValues[name] = v,
          ),
        );
    }
  }

  void _submitForm(List<Map<String, dynamic>> fields) {
    setState(() => _formSubmitted = true);
    // Validate required fields
    for (final f in fields) {
      final name = f['name'] as String? ?? '';
      final type = f['type'] as String? ?? 'text';
      final required_ = f['required'] as bool? ?? false;
      if (required_ && _isFieldEmpty(name, type)) return;
    }
    widget.onApprove(jsonEncode(_formValues));
  }

  /// Detect if tool is a file write/edit operation
  bool get _isFileOp {
    final lower = widget.request.toolName.toLowerCase();
    return lower.contains('write') || lower.contains('edit') ||
        lower.contains('create') || lower.contains('patch') ||
        lower.contains('replace');
  }

  bool get _isEditOp {
    final lower = widget.request.toolName.toLowerCase();
    return lower.contains('edit') || lower.contains('patch') || lower.contains('replace');
  }

  String? get _filePath {
    final p = widget.request.params;
    return p['path'] as String? ?? p['file'] as String? ?? p['file_path'] as String?;
  }

  String? get _fileContent {
    final p = widget.request.params;
    return p['content'] as String? ?? p['new_content'] as String? ?? p['new_string'] as String?;
  }

  /// Open file write/edit in workspace — with diff for edits
  void _openFileInWorkspace() {
    final path = _filePath;
    if (path == null) return;
    // Diff preview lives inline inside the approval card; just
    // surface the workspace panel for context.
    final appState = context.read<AppState>();
    if (!appState.isWorkspaceVisible) appState.showWorkspace();
  }

  /// Open generic content in workspace
  void _openGenericInWorkspace() {
    // Content is already displayed inline in the approval card;
    // this action just surfaces the workspace panel.
    final appState = context.read<AppState>();
    if (!appState.isWorkspaceVisible) appState.showWorkspace();
  }

  void _submitResponse() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    widget.onApprove(text);
  }

  // ── Deny reason input ───────────────────────────────────────────────────

  Widget _buildDenyInput(AppColors ac) {
    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: ac.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: ac.red.withValues(alpha: 0.3)),
            ),
            child: TextField(
              controller: _inputCtrl,
              autofocus: true,
              style: GoogleFonts.inter(fontSize: 12, color: ac.textBright),
              decoration: InputDecoration(
                hintText: 'chat.reason_optional_hint'.tr(),
                hintStyle: GoogleFonts.inter(fontSize: 12, color: ac.textDim),
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                isDense: true,
              ),
              onSubmitted: (_) => widget.onDeny(_inputCtrl.text.trim()),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _ABtn(
            label: 'chat.send_short'.tr(),
            bg: ac.red.withValues(alpha: 0.1),
            border: ac.red.withValues(alpha: 0.3),
            fg: ac.red,
            onTap: () => widget.onDeny(_inputCtrl.text.trim())),
        const SizedBox(width: 4),
        _ABtn(
            label: 'chat.cancel'.tr(),
            bg: ac.surface,
            border: ac.border,
            fg: ac.textMuted,
            onTap: () => setState(() {
                  _showDenyInput = false;
                  _inputCtrl.clear();
                })),
      ],
    );
  }

  // ── Risk dot (pulsing for high) ─────────────────────────────────────────

  Widget _riskDot(Color color) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
    if (widget.request.riskLevel == 'high') {
      return FadeTransition(
        opacity: Tween<double>(begin: 0.5, end: 1.0).animate(_pulseCtrl),
        child: dot,
      );
    }
    return dot;
  }

  // ── Timer badge ─────────────────────────────────────────────────────────

  Widget _timerBadge(AppColors ac) {
    final isLow = _remainingSeconds < 60;
    final color = isLow ? ac.red : ac.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('\u23F1 ',
            style: GoogleFonts.inter(fontSize: 11, color: color)),
        Text(_timerText,
            style: GoogleFonts.firaCode(
                fontSize: 11,
                color: color,
                fontWeight: isLow ? FontWeight.w600 : FontWeight.normal)),
      ],
    );
  }
}

/// Compact code block used inside the tool-approval card. Renders
/// the main-param value (command, query, script, …) in JetBrains
/// Mono with a subtle header (label + optional Copy) and a shell
/// prefix `$ ` when the param represents a shell command. Kept
/// lightweight — no syntax highlighting — so it loads instantly
/// in the approval overlay without competing with the chat's
/// regular code-block styling.
class _ApprovalCodeBlock extends StatefulWidget {
  final String label;
  final String content;
  final bool shellPrefix;

  const _ApprovalCodeBlock({
    required this.label,
    required this.content,
    this.shellPrefix = false,
  });

  @override
  State<_ApprovalCodeBlock> createState() => _ApprovalCodeBlockState();
}

class _ApprovalCodeBlockState extends State<_ApprovalCodeBlock> {
  bool _copied = false;
  Timer? _copyResetTimer;

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.content));
    setState(() => _copied = true);
    _copyResetTimer?.cancel();
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lines = widget.content.split('\n');
    final preview = widget.shellPrefix
        ? lines.map((l) => '\$ $l').join('\n')
        : widget.content;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.codeBlockBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Thin header — no traffic lights, just the param name + Copy.
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.codeBlockHeader,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(9),
                topRight: Radius.circular(9),
              ),
              border: Border(
                bottom:
                    BorderSide(color: c.border.withValues(alpha: 0.6)),
              ),
            ),
            child: Row(
              children: [
                Text(
                  widget.label.toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                  ),
                ),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: _copy,
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied
                              ? Icons.check_rounded
                              : Icons.copy_rounded,
                          size: 12,
                          color: _copied ? c.green : c.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? 'chat.copied_short'.tr() : 'chat.copy_short'.tr(),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: _copied ? c.green : c.textMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  preview,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 13,
                    color: c.textBright,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ABtn extends StatefulWidget {
  final String label;
  final Color bg, border, fg;
  final VoidCallback onTap;
  const _ABtn(
      {required this.label,
      required this.bg,
      required this.border,
      required this.fg,
      required this.onTap});

  @override
  State<_ABtn> createState() => _ABtnState();
}

class _ABtnState extends State<_ABtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: _h
                  ? widget.bg.withValues(alpha: 0.25)
                  : widget.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: widget.border),
            ),
            child: Text(widget.label,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: widget.fg)),
          ),
        ),
      );
}

// ─── Choice pill for ask_user choices mode ──────────────────────────────────

class _ChoicePill extends StatefulWidget {
  final String label;
  final bool selected;
  final bool showCheckbox;
  final AppColors colors;
  final VoidCallback onTap;
  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.showCheckbox,
    required this.colors,
    required this.onTap,
  });
  @override
  State<_ChoicePill> createState() => _ChoicePillState();
}

class _ChoicePillState extends State<_ChoicePill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ac = widget.colors;
    final isOn = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: isOn
                ? ac.blue.withValues(alpha: 0.15)
                : _hover
                    ? ac.textDim.withValues(alpha: 0.08)
                    : ac.bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isOn
                  ? ac.blue.withValues(alpha: 0.4)
                  : ac.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showCheckbox) ...[
                Icon(
                  isOn ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 14,
                  color: isOn ? ac.blue : ac.textMuted,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: isOn ? FontWeight.w600 : FontWeight.w400,
                  color: isOn ? ac.blue : ac.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Chat Input — main input bar ──────────────────────────────────────────────
// Layout (identical to old web client):
//   ┌─────────────────────────────────────────────────────────┐
//   │ textarea (auto-grow, max 200px)                         │
//   ├─────────────────────────────────────────────────────────┤
//   │ [+] [⎘]  [context ring]           [■ Stop] / [↑ Send]  │
//   └─────────────────────────────────────────────────────────┘

class _ChatInput extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isActive;
  final bool disabled;
  final int queuedCount;
  final VoidCallback onSend;
  final VoidCallback onAbort;
  final VoidCallback? onContextTap;
  final VoidCallback? onToolsTap;
  final VoidCallback? onTasksTap;
  final VoidCallback? onSnippetsTap;
  final void Function(String name, String path, bool isImage)? onAttach;
  /// Fired when the user pastes (Ctrl/Cmd+V) with an image on the
  /// clipboard. The PasteTextIntent handler writes the bytes to a
  /// tmp PNG and hands off the same (name, path, true) tuple as
  /// `onAttach` — the composer doesn't need to differentiate the
  /// source of the attachment.
  final void Function(String name, String path, bool isImage)? onImagePaste;

  const _ChatInput({
    required this.controller,
    required this.focusNode,
    required this.isActive,
    required this.disabled,
    required this.onSend,
    required this.onAbort,
    this.queuedCount = 0,
    this.onContextTap,
    this.onAttach,
    this.onToolsTap,
    this.onTasksTap,
    this.onSnippetsTap,
    this.onImagePaste,
  });

  @override
  State<_ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<_ChatInput> {
  @override
  void initState() {
    super.initState();
    // Rebuild when the text changes so the send button can flip
    // between enabled/disabled and between `Send` / `Abort` icons.
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_ChatInput old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  // Expose the widget's fields under the same names the existing
  // build method used so the 400-line body below doesn't need
  // wholesale rewrites.
  TextEditingController get controller => widget.controller;
  FocusNode get focusNode => widget.focusNode;
  bool get isActive => widget.isActive;
  bool get disabled => widget.disabled;
  int get queuedCount => widget.queuedCount;
  VoidCallback get onSend => widget.onSend;
  VoidCallback get onAbort => widget.onAbort;
  VoidCallback? get onContextTap => widget.onContextTap;
  VoidCallback? get onToolsTap => widget.onToolsTap;
  VoidCallback? get onTasksTap => widget.onTasksTap;
  VoidCallback? get onSnippetsTap => widget.onSnippetsTap;
  void Function(String, String, bool)? get onAttach => widget.onAttach;
  void Function(String, String, bool)? get onImagePaste =>
      widget.onImagePaste;

  /// True when the composer has content we could send or queue.
  bool get hasText => controller.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Builder(builder: (context) {
      final c = context.colors;
      final manifest = context.watch<AppState>().manifest;
      final accent = manifest.accent ?? c.accentPrimary;
      final focused = focusNode.hasFocus;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: c.inputBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused
                ? accent.withValues(alpha: 0.3)
                : c.inputBorder,
          ),
          boxShadow: [
            BoxShadow(
              color: focused
                  ? accent.withValues(alpha: 0.08)
                  : c.shadow.withValues(alpha: 0.35),
              blurRadius: focused ? 14 : 16,
              spreadRadius: -4,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            // ── Textarea (Enter=send, Shift+Enter=newline) ──────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                },
                child: Actions(
                  actions: {
                    _SendIntent: CallbackAction<_SendIntent>(
                      onInvoke: (_) {
                        // `onSend` handles queueing when a turn is
                        // running (see ChatPanel._send). Only block
                        // the hard `disabled` state — e.g. missing
                        // workspace — not the "busy" state.
                        if (!disabled) onSend();
                        return null;
                      },
                    ),
                    PasteTextIntent: CallbackAction<PasteTextIntent>(
                      onInvoke: (intent) {
                        // Paste priority:
                        //   1. Image on clipboard → attach as file
                        //      (covers Win+Shift+S / Cmd+Shift+4 → V).
                        //   2. Text → smart-paste (JSON / code wrapper).
                        () async {
                          final imagePath = await attach_helpers
                              .clipboardImageToTempFile();
                          if (imagePath != null) {
                            final name =
                                imagePath.split(RegExp(r'[\\/]')).last;
                            widget.onImagePaste?.call(name, imagePath, true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('chat.image_pasted_clipboard'.tr()),
                                  duration: const Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                            return;
                          }
                          final data = await Clipboard.getData('text/plain');
                          final raw = data?.text;
                          if (raw == null || raw.isEmpty) return;
                          final result = transformPaste(raw);
                          final selection = controller.selection;
                          final start =
                              selection.start.clamp(0, controller.text.length);
                          final end =
                              selection.end.clamp(0, controller.text.length);
                          controller.value = controller.value.copyWith(
                            text: controller.text.replaceRange(
                                start, end, result.text),
                            selection: TextSelection.collapsed(
                                offset: start + result.text.length),
                          );
                          if (result.hint != null && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('chat.smart_paste'
                                    .tr(namedArgs: {
                                  'hint': result.hint ?? ''
                                })),
                                backgroundColor:
                                    accent.withValues(alpha: 0.9),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        }();
                        return null;
                      },
                    ),
                  },
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    enabled: !disabled,
                    minLines: 1,
                    maxLines: 8,
                    maxLength: 32000,
                    keyboardType: TextInputType.multiline,
                    cursorColor: accent,
                    cursorWidth: 1.4,
                    cursorRadius: const Radius.circular(1),
                    style: GoogleFonts.inter(
                        fontSize: 14, color: c.text, height: 1.55),
                    decoration: InputDecoration(
                      hintText: disabled
                          ? 'chat.placeholder_no_workspace'.tr()
                          : 'chat.placeholder'.tr(),
                      hintStyle: GoogleFonts.inter(
                          fontSize: 14,
                          color: c.textDim),
                      border: InputBorder.none,
                      counterText: '',
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ),

            // ── Separator ─────────────────────────────────────────────────
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: c.border,
            ),

            // ── Bottom bar ────────────────────────────────────────────────
            // Every control here is conditional on the manifest's
            // feature flags. Apps that don't need tools / mic /
            // attachments hide them — the bar shrinks to just the
            // send button.
            Builder(builder: (ctx) {
              final features = ctx.watch<AppState>().manifest.features;
              // We still watch ContextState so the ring repaints when
              // data lands, but we no longer GATE the ring on it —
              // rendering it at 0% from turn zero keeps the
              // affordance clickable and lets the user inspect the
              // (already populated on session-create) context
              // straight away. Panel itself handles the "no data
              // yet" edge case gracefully.
              ctx.watch<ContextState>();
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    if (features.attachments) ...[
                      AttachMenuButton(
                        disabled: disabled,
                        controller: controller,
                        focusNode: focusNode,
                        onAttach: onAttach,
                      ),
                      const SizedBox(width: 4),
                    ],
                    // Browse-only affordances — always clickable, even
                    // before the session has a workspace / first send.
                    // The `disabled` flag here governs SENDING, not
                    // opening read-only panels.
                    if (features.toolsPanel && onToolsTap != null) ...[
                      _IconBtn(
                        icon: Icons.build_outlined,
                        tooltip: 'chat.tools_short'.tr(),
                        disabled: false,
                        onTap: onToolsTap!,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (features.snippets && onSnippetsTap != null) ...[
                      _IconBtn(
                        icon: Icons.bookmark_border_rounded,
                        tooltip: 'chat.snippets_short'.tr(),
                        disabled: false,
                        onTap: onSnippetsTap!,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (features.tasksPanel && onTasksTap != null)
                      _TasksButton(
                        disabled: false,
                        onTap: onTasksTap!,
                      ),
                    if (features.contextRing) ...[
                      const SizedBox(width: 8),
                      _ContextRing(onTap: onContextTap),
                    ],
                    const Spacer(),
                    if (features.voice) ...[
                      _MicButton(
                        disabled: disabled,
                        onTranscript: (text) {
                          controller.value = controller.value.copyWith(
                            text: text,
                            selection: TextSelection.collapsed(
                                offset: text.length),
                          );
                        },
                        onAudioRecorded: (path) {
                          onAttach?.call(
                              path.split(RegExp(r'[\\/]')).last, path, false);
                        },
                        onError: (err) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(
                              content: Text(err),
                              duration: const Duration(seconds: 3),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 6),
                    ],
                    _SendButton(
                      disabled: disabled,
                      isActive: isActive,
                      hasText: hasText,
                      isOneshot: ctx.watch<AppState>().manifest.isOneshot,
                      queuedCount: queuedCount,
                      onTap: onSend,
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      );
      }),
    );
  }
}

// ─── Icon button (bottom bar) ─────────────────────────────────────────────────

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool disabled;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon,
      required this.tooltip,
      required this.disabled,
      required this.onTap});

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        cursor: widget.disabled
            ? SystemMouseCursors.forbidden
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.disabled ? null : widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _h && !widget.disabled
                  ? c.surfaceAlt
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _h && !widget.disabled
                    ? c.borderHover
                    : Colors.transparent,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 18,
              color: widget.disabled
                  ? c.borderHover
                  : (_h ? c.textBright : c.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// Background-tasks button — same shape as [_IconBtn] plus a live
/// coral badge rendered on top-right when at least one background
/// task is running. The badge pulses gently so it catches the eye
/// when a task kicks off without being loud about it.
class _TasksButton extends StatefulWidget {
  final bool disabled;
  final VoidCallback onTap;
  const _TasksButton({required this.disabled, required this.onTap});

  @override
  State<_TasksButton> createState() => _TasksButtonState();
}

class _TasksButtonState extends State<_TasksButton>
    with SingleTickerProviderStateMixin {
  bool _h = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = context.watch<BackgroundService>();
    final running = bg.activeCount;
    final hasBadge = running > 0;
    return Tooltip(
      message: hasBadge
          ? 'chat.background_tasks_running'.tr(namedArgs: {'n': '$running'})
          : 'chat.background_tasks'.tr(),
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        cursor: widget.disabled
            ? SystemMouseCursors.forbidden
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.disabled ? null : widget.onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hasBadge
                        ? c.accentPrimary.withValues(alpha: _h ? 0.14 : 0.08)
                        : (_h && !widget.disabled
                            ? c.surfaceAlt
                            : Colors.transparent),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: hasBadge
                          ? c.accentPrimary.withValues(alpha: 0.35)
                          : (_h && !widget.disabled
                              ? c.borderHover
                              : Colors.transparent),
                    ),
                  ),
                  child: Icon(
                    Icons.sync_rounded,
                    size: 18,
                    color: widget.disabled
                        ? c.borderHover
                        : hasBadge
                            ? c.accentPrimary
                            : (_h ? c.textBright : c.text),
                  ),
                ),
                if (hasBadge)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (_, child) {
                        final glow = 0.5 + (0.4 * _pulse.value);
                        return Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: c.accentPrimary
                                    .withValues(alpha: glow * 0.55),
                                blurRadius: 8,
                                spreadRadius: 0,
                              ),
                            ],
                          ),
                          child: child,
                        );
                      },
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 16),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.accentPrimary,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: c.bg, width: 1.4),
                        ),
                        child: Text(
                          running > 99 ? '99+' : '$running',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.firaCode(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: c.onAccent,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Context pressure ring ────────────────────────────────────────────────────
// SVG-style ring (like the old web client) — filled proportionally

class _ContextRing extends StatefulWidget {
  final VoidCallback? onTap;
  const _ContextRing({this.onTap});

  @override
  State<_ContextRing> createState() => _ContextRingState();
}

class _ContextRingState extends State<_ContextRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  double _shownRatio = 0;
  Color? _shownColor;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.watch<ContextState>();
    final cc = context.colors;
    // Ring shows raw context usage (``used / limit``) — the
    // percentage a user intuitively reads as "how full is my
    // context". Threshold proximity still drives color / alert so
    // the ring goes orange / red / pulse before compaction triggers
    // even though the number itself never exceeds 100 %.
    final ratio = cs.pressure.clamp(0.0, 1.0);
    final pct = (ratio * 100).round();
    final proximity = cs.displayPressure;
    final color = proximity < 0.67
        ? cc.green
        : proximity < 0.85
            ? cc.orange
            : cc.red;
    final alert = proximity >= 0.90;
    _shownColor ??= color;
    final thrPct = (cs.threshold * 100).round();
    // Tween-animated ratio & color so a jump from 40% → 75% glides
    // smoothly instead of snapping (Material spec for status meters).
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Tooltip(
          message:
              'Context: $pct% of compaction threshold ($thrPct%)\n'
              '${cs.totalEstimatedTokens}/${cs.effectiveMax} tokens — click for details',
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) {
              final pulse =
                  alert ? 0.55 + (0.35 * _pulse.value) : 0.0;
              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 4),
                constraints: const BoxConstraints(minHeight: 28),
                decoration: alert
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: color.withValues(alpha: pulse * 0.5),
                            blurRadius: 14,
                            spreadRadius: 0,
                          ),
                        ],
                      )
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: _shownRatio,
                        end: ratio.clamp(0.0, 1.0),
                      ),
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      onEnd: () => _shownRatio = ratio.clamp(0.0, 1.0),
                      builder: (_, animRatio, _) {
                        return TweenAnimationBuilder<Color?>(
                          tween: ColorTween(
                            begin: _shownColor,
                            end: color,
                          ),
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOut,
                          onEnd: () => _shownColor = color,
                          builder: (_, animColor, _) {
                            return CustomPaint(
                              size: const Size(20, 20),
                              painter: _RingPainter(
                                ratio: animRatio,
                                color: animColor ?? color,
                                trackColor: cc.borderHover,
                              ),
                            );
                          },
                        );
                      },
                    ),
                    if (ratio >= 0.5) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$pct%',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 11.5,
                          color: color,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double ratio;
  final Color color;
  final Color trackColor;
  const _RingPainter({required this.ratio, required this.color, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = cx - 1.5;
    const strokeW = 2.0;

    // Track
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..color = trackColor,
    );

    // Fill arc
    if (ratio > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        -3.14159 / 2, // start at top
        2 * 3.14159 * ratio,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio || old.color != color || old.trackColor != trackColor;
}

// ─── Send button ──────────────────────────────────────────────────────────────

class _MicButton extends StatefulWidget {
  final bool disabled;
  /// Called with the transcribed text (live-STT path) whenever the
  /// voice service emits — partial results included so the input
  /// updates as the user speaks.
  final void Function(String transcript)? onTranscript;
  /// Called with the path to a locally recorded audio file on
  /// platforms where live STT isn't available. Consumer attaches
  /// the file to the next message.
  final void Function(String audioPath)? onAudioRecorded;
  /// User-facing error (permission denied, engine unavailable).
  final void Function(String error)? onError;
  const _MicButton({
    required this.disabled,
    this.onTranscript,
    this.onAudioRecorded,
    this.onError,
  });

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> {
  bool _h = false;
  StreamSubscription<String>? _transcriptSub;

  @override
  void initState() {
    super.initState();
    // Subscribe once — the service is a singleton and emits the
    // full transcript on each update.
    _transcriptSub =
        VoiceInputService().transcriptStream.listen((t) {
      widget.onTranscript?.call(t);
    });
    // Probe for voice support in the background so the tooltip /
    // disabled state is accurate by the time the user hovers.
    VoiceInputService().ensureInitialised();
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final svc = VoiceInputService();
    await svc.ensureInitialised();
    if (svc.mode == VoiceMode.unavailable) {
      widget.onError?.call(
          'Voice input is not available on this platform yet.');
      return;
    }
    if (svc.state == VoiceState.listening) {
      final result = await svc.stop();
      // Live STT / server transcribe both return the text directly.
      // For server mode, a null result with a non-null audio path
      // means the daemon refused — fall back to attaching the file.
      if (result != null && result.isNotEmpty) {
        widget.onTranscript?.call(result);
        return;
      }
      final audio = svc.lastAudioPath;
      if (audio != null && audio.isNotEmpty) {
        widget.onAudioRecorded?.call(audio);
      }
    } else {
      await svc.start();
      final err = svc.lastError;
      if (err != null) widget.onError?.call(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: VoiceInputService(),
      builder: (_, _) {
        final svc = VoiceInputService();
        final isRec = svc.state == VoiceState.listening;
        final isProcessing = svc.state == VoiceState.processing;
        final unavailable = svc.mode == VoiceMode.unavailable;
        final tooltip = isProcessing
            ? (svc.mode == VoiceMode.serverTranscribe
                ? 'chat.voice_transcribing'.tr()
                : 'chat.voice_processing'.tr())
            : isRec
                ? (svc.mode == VoiceMode.liveTranscribe
                    ? 'chat.voice_stop_dictation'.tr()
                    : 'chat.voice_stop_recording'.tr())
                : unavailable
                    ? 'chat.voice_unsupported'.tr()
                    : (svc.mode == VoiceMode.liveTranscribe
                        ? 'chat.voice_dictate'.tr()
                        : svc.mode == VoiceMode.serverTranscribe
                            ? 'chat.voice_dictate_server'.tr()
                            : 'chat.voice_record_audio'.tr());
        return Tooltip(
          message: tooltip,
          child: MouseRegion(
            onEnter: (_) {
              if (!_h && mounted) setState(() => _h = true);
            },
            onExit: (_) {
              if (_h && mounted) setState(() => _h = false);
            },
            cursor: (widget.disabled || unavailable)
                ? SystemMouseCursors.forbidden
                : SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: (widget.disabled || unavailable || isProcessing)
                  ? null
                  : _toggle,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isRec
                      ? c.red.withValues(alpha: 0.18)
                      : isProcessing
                          ? c.blue.withValues(alpha: 0.12)
                          : _h
                              ? c.surfaceAlt
                              : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isRec
                        ? c.red.withValues(alpha: 0.5)
                        : isProcessing
                            ? c.blue.withValues(alpha: 0.4)
                            : _h
                                ? c.borderHover
                                : Colors.transparent,
                  ),
                ),
                child: isProcessing
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                            strokeWidth: 1.8, color: c.blue),
                      )
                    : Icon(
                        isRec
                            ? Icons.stop_rounded
                            : Icons.mic_none_rounded,
                        size: 18,
                        color: (widget.disabled || unavailable)
                            ? c.textDim
                            : isRec
                                ? c.red
                                : (_h ? c.textBright : c.text),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Single send / abort / queue button. The entire composer UX uses
/// one affordance: you click it, something happens — the *what* is
/// decided by the current state.
///
///   * Idle + composer has text → send (↑).
///   * Idle + composer empty    → disabled.
///   * Turn running + text      → queue the text (still shows ↑,
///                                 the queue panel above the composer
///                                 announces the addition).
///   * Turn running + empty     → abort the current turn (✕).
///
/// During a running turn a rotating ring wraps the button so the
/// user sees activity without a second stop button. The ring is the
/// same colour family as the pulse pill in the header — visual echo.
class _SendButton extends StatefulWidget {
  final bool disabled;
  /// True iff the current app is in `oneshot` mode — label + icon
  /// switch to a ▶ Play.
  final bool isOneshot;
  /// True while a turn is running. Drives the animated ring and
  /// flips the icon to ✕ when the composer is empty.
  final bool isActive;
  /// Current composer text (trimmed). Used only to pick the right
  /// icon / cursor — the actual send logic lives in the caller.
  final bool hasText;
  /// Number of messages waiting after the running turn. Rendered as
  /// a badge so the user sees the queue depth.
  final int queuedCount;
  final VoidCallback onTap;
  const _SendButton({
    required this.disabled,
    required this.onTap,
    required this.isActive,
    required this.hasText,
    this.isOneshot = false,
    this.queuedCount = 0,
  });

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton>
    with SingleTickerProviderStateMixin {
  bool _h = false;
  late final AnimationController _ring;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isActive) _ring.repeat();
  }

  @override
  void didUpdateWidget(_SendButton old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !_ring.isAnimating) {
      _ring.repeat();
    } else if (!widget.isActive && _ring.isAnimating) {
      _ring.stop();
      _ring.value = 0;
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Effective disabled state — idle + empty composer = nothing to
    // do. The `disabled` prop (workspace-required, etc.) still wins
    // unconditionally.
    final inertIdle = !widget.isActive && !widget.hasText;
    final effectivelyDisabled = widget.disabled || inertIdle;

    // Icon selection:
    //   turn running + empty  → ✕ (abort)
    //   turn running + text   → ↑ (queue)
    //   idle + text           → ↑ (send) — or ▶ for oneshot
    //   idle + empty          → ↑ (disabled)
    // Use the SHARP (non-rounded) variants so the icon weight visually
    // matches the web Lucide `ArrowUp size={16} strokeWidth={2}` — the
    // rounded Material glyphs were heavier and read as "different
    // button" against the gradient.
    final showAbort = widget.isActive && !widget.hasText;
    final IconData icon;
    if (showAbort) {
      icon = Icons.close;
    } else if (widget.isOneshot && !widget.isActive) {
      icon = Icons.play_arrow;
    } else {
      icon = Icons.arrow_upward;
    }

    final tooltip = showAbort
        ? (widget.queuedCount > 0
            ? 'chat.abort_current_turn'.tr(namedArgs: {'n': '${widget.queuedCount}'})
            : 'chat.abort'.tr())
        : widget.isActive
            ? 'chat.send_will_queue'.tr()
            : widget.isOneshot
                ? 'chat.run'.tr()
                : 'chat.send'.tr();

    // The send button always pulls from the active theme palette
    // (Obsidian coral, Midnight cyan, OLED pink, …). We ignore any
    // per-app manifest accent here so the button signs "your theme"
    // rather than "this app's brand colour" — users asked for the
    // CTA to stay consistent with whatever palette they picked.
    final accent = c.accentPrimary;
    final Gradient? gradient;
    final Color bg;
    final Color fg;
    // Web parity (chat-composer.tsx:489 — `SendButton`):
    //   disabled  →  bg surface, fg textDim, 1px border
    //   abort     →  bg red @ 14% (22% on hover), fg red
    //   default   →  gradient 135° accentPrimary → mix(45/55) secondary,
    //                fg onAccent, soft accent halo
    // Same tones, just expressed via `Color.lerp` (linear RGB) instead
    // of CSS `color-mix(in oklab, …)`. Visually identical at the
    // default purple/blue palette; both stay close on coral / cyan
    // themes too.
    if (effectivelyDisabled) {
      bg = c.surface;
      fg = c.textDim;
      gradient = null;
    } else if (showAbort) {
      bg = _h ? c.red.withValues(alpha: 0.22) : c.red.withValues(alpha: 0.14);
      fg = c.red;
      gradient = null;
    } else {
      bg = Colors.transparent;
      fg = c.onAccent;
      gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          c.accentPrimary,
          Color.lerp(c.accentPrimary, c.accentSecondary, 0.55) ??
              c.accentPrimary,
        ],
      );
    }

    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        onEnter: (_) {
          if (!_h && mounted) setState(() => _h = true);
        },
        onExit: (_) {
          if (_h && mounted) setState(() => _h = false);
        },
        cursor: effectivelyDisabled
            ? SystemMouseCursors.forbidden
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: effectivelyDisabled ? null : widget.onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Rotating ring while a turn is running. Drawn
                // slightly larger than the button so it reads as a
                // halo rather than a border colour.
                if (widget.isActive)
                  AnimatedBuilder(
                    animation: _ring,
                    builder: (_, _) => Transform.rotate(
                      angle: _ring.value * 6.283185,
                      child: CustomPaint(
                        size: const Size(34, 34),
                        painter: _ActiveRingPainter(
                          color: showAbort ? c.red : accent,
                        ),
                      ),
                    ),
                  ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bg,
                    gradient: gradient,
                    shape: BoxShape.circle,
                    border: effectivelyDisabled
                        ? Border.all(color: c.border)
                        : null,
                    // Web: `0 4px 20px -2px / 0 2px 12px -2px` accent halo.
                    // Use the same blur/spread/offset and keep the alpha
                    // mild (0.35 / 0.6) so the button doesn't drag a
                    // dark "puddle" under itself like the previous
                    // 12-blur halo did.
                    boxShadow: gradient != null
                        ? [
                            BoxShadow(
                              color: accent
                                  .withValues(alpha: _h ? 0.6 : 0.35),
                              blurRadius: _h ? 20 : 12,
                              spreadRadius: -2,
                              offset: Offset(0, _h ? 4 : 2),
                            ),
                          ]
                        : null,
                  ),
                  // Icon 16px to match web `<ArrowUp size={16} strokeWidth={2}>`.
                  child: Icon(icon, size: 16, color: fg),
                ),
                if (widget.queuedCount > 0)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: c.bg, width: 1.6),
                      ),
                      constraints: const BoxConstraints(minWidth: 18),
                      child: Text(
                        '${widget.queuedCount}',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: c.onAccent,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Painter for the rotating activity ring around the send button.
/// Draws a 270° arc with a fading tail so it reads as motion.
class _ActiveRingPainter extends CustomPainter {
  final Color color;
  _ActiveRingPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.width / 2 - 1.5,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.2),
          color.withValues(alpha: 0.6),
          color,
        ],
        stops: const [0, 0.4, 0.8, 1],
      ).createShader(rect);
    canvas.drawArc(rect, -1.57, 4.7, false, paint);
  }

  @override
  bool shouldRepaint(covariant _ActiveRingPainter old) =>
      old.color != color;
}

// ─── Inline Todo Bar (compact, above input) ──────────────────────────────────

class _InlineTodoBar extends StatefulWidget {
  final WorkspaceState ws;
  const _InlineTodoBar({required this.ws});

  @override
  State<_InlineTodoBar> createState() => _InlineTodoBarState();
}

class _InlineTodoBarState extends State<_InlineTodoBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    final todos = ws.todosSorted;
    final pct = (ws.todoProgress * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Progress row (always visible)
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            children: [
              // Progress bar mini
              SizedBox(
                width: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: ws.todoProgress,
                    backgroundColor: context.colors.border,
                    valueColor: AlwaysStoppedAnimation(context.colors.green),
                    minHeight: 4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('${ws.todoDone}/${ws.todoTotal} ($pct%)',
                style: GoogleFonts.firaCode(fontSize: 10, color: context.colors.textMuted)),
              const SizedBox(width: 6),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 14, color: context.colors.textMuted,
              ),
            ],
          ),
        ),

        // Expanded todo list
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in todos.take(6))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              Text(
                                switch (t.status) {
                                  TodoStatus.done => '✓',
                                  TodoStatus.inProgress => '▶',
                                  TodoStatus.blocked => '■',
                                  _ => '▫',
                                },
                                style: TextStyle(
                                  fontSize: 10,
                                  color: switch (t.status) {
                                    TodoStatus.done => context.colors.textMuted,
                                    TodoStatus.inProgress => context.colors.orange,
                                    TodoStatus.blocked => context.colors.red,
                                    _ => context.colors.text,
                                  },
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(t.content,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    color: t.status == TodoStatus.done
                                        ? context.colors.textMuted
                                        : context.colors.text,
                                    decoration: t.status == TodoStatus.done
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (todos.length > 6)
                        Text('+${todos.length - 6} more',
                          style: GoogleFonts.inter(fontSize: 10, color: context.colors.textMuted)),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _InlineAgents extends StatelessWidget {
  final List<SubAgent> agents;
  const _InlineAgents({required this.agents});

  @override
  Widget build(BuildContext context) {
    final active = agents.where((a) =>
        a.status == AgentStatus.spawned || a.status == AgentStatus.running);
    if (active.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          for (final a in active.take(4)) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: context.colors.cyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colors.cyan.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('●', style: TextStyle(fontSize: 8, color: context.colors.cyan)),
                  const SizedBox(width: 4),
                  Text(
                    a.specialist.isNotEmpty ? a.specialist : a.id,
                    style: GoogleFonts.inter(fontSize: 10, color: context.colors.cyan),
                  ),
                ],
              ),
            ),
          ],
          if (active.length > 4)
            Text('+${active.length - 4}',
              style: GoogleFonts.firaCode(fontSize: 10, color: context.colors.textMuted)),
        ],
      ),
    );
  }
}

// ─── Enter to send intent ────────────────────────────────────────────────────

class _SendIntent extends Intent {
  const _SendIntent();
}

// ─── Spinner icon (uses SpinKit) ─────────────────────────────────────────────

// ─── Error Banner ────────────────────────────────────────────────────────────

class _ErrorBanner extends StatefulWidget {
  final DaemonError error;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;
  const _ErrorBanner({
    required this.error,
    required this.onDismiss,
    this.onRetry,
  });

  @override
  State<_ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<_ErrorBanner> {
  bool _showDetail = false;

  Color _catColor(AppColors c) => switch (widget.error.category) {
    'billing'    => c.orange,
    'auth'       => c.red,
    'rate_limit' => c.orange,
    'provider'   => c.red,
    'network'    => c.textMuted,
    'security'   => c.red,
    _ => c.red,
  };

  IconData _catIcon() => switch (widget.error.category) {
    'billing'    => Icons.credit_card_rounded,
    'auth'       => Icons.key_rounded,
    'rate_limit' => Icons.timer_rounded,
    'provider'   => Icons.cloud_off_rounded,
    'network'    => Icons.wifi_off_rounded,
    'security'   => Icons.lock_rounded,
    _ => Icons.warning_amber_rounded,
  };

  String _catTitle() => switch (widget.error.category) {
    'billing'    => 'chat.err_billing'.tr(),
    'auth'       => 'chat.err_auth'.tr(),
    'rate_limit' => 'chat.err_rate_limit'.tr(),
    'provider'   => 'chat.err_provider'.tr(),
    'network'    => 'chat.err_network'.tr(),
    'security'   => 'chat.err_security'.tr(),
    _ => 'chat.err_generic'.tr(),
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _catColor(c);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Icon(_catIcon(), size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_catTitle(),
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color)),
                ),
                if (widget.error.code.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(widget.error.code,
                      style: GoogleFonts.firaCode(fontSize: 9, color: color)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Error message
            Text(widget.error.error,
              style: GoogleFonts.inter(
                fontSize: 13, color: c.text, height: 1.5)),
            // Detail (expandable)
            if (widget.error.detail != null && widget.error.detail!.isNotEmpty) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => setState(() => _showDetail = !_showDetail),
                child: Text(
                  _showDetail ? 'chat.hide_details'.tr() : 'chat.show_details'.tr(),
                  style: GoogleFonts.inter(
                    fontSize: 11, color: c.textMuted,
                    decoration: TextDecoration.underline,
                    decorationColor: c.textMuted),
                ),
              ),
              if (_showDetail) ...[
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    widget.error.detail!,
                    style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted, height: 1.5),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 10),
            // Action buttons
            Row(
              children: [
                if (widget.onRetry != null)
                  _ABtn(
                    label: 'chat.retry'.tr(),
                    bg: c.blue.withValues(alpha: 0.1),
                    border: c.blue.withValues(alpha: 0.3),
                    fg: c.blue,
                    onTap: widget.onRetry!,
                  ),
                if (widget.onRetry != null) const SizedBox(width: 8),
                _ABtn(
                  label: 'chat.dismiss'.tr(),
                  bg: c.textDim.withValues(alpha: 0.1),
                  border: c.textDim.withValues(alpha: 0.3),
                  fg: c.textMuted,
                  onTap: widget.onDismiss,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Queue Panel (fixed above input) ────────────────────────────────────────

// ─── Attachments Bar ────────────────────────────────────────────────────────

// ─── Drop overlay shown when a file is being dragged over the chat ──────────

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.accentPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: c.accentPrimary.withValues(alpha: 0.55),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: c.accentPrimary.withValues(alpha: 0.25),
            blurRadius: 40,
            spreadRadius: -4,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accentPrimary.withValues(alpha: 0.18),
                border: Border.all(
                  color: c.accentPrimary.withValues(alpha: 0.45),
                ),
              ),
              child: Icon(
                Icons.file_download_outlined,
                size: 30,
                color: c.accentPrimary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'chat.drop_to_attach'.tr(),
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: c.accentPrimary,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'chat.drop_multiple_files_hint'.tr(),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: c.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Queue Panel ────────────────────────────────────────────────────────────
//
// Reactive view over [QueueService] for the currently-active session.
// Each pending row can be cancelled individually; "Clear all" purges
// every queued entry (leaves the running turn alone — use abort for
// that).

class _QueuePanel extends StatefulWidget {
  final String appId;
  final String sessionId;
  /// Invoked when the user taps the Edit icon on the tail queued
  /// entry — the caller should pre-fill the composer and set the
  /// "replace last" flag so the next Send overwrites this row.
  final void Function(QueueEntry entry)? onEditTail;
  const _QueuePanel({
    required this.appId,
    required this.sessionId,
    this.onEditTail,
  });

  @override
  State<_QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<_QueuePanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: QueueService(),
      builder: (context, _) {
        final c = context.colors;
        // Show ONLY pending entries. Once the daemon picks a
        // message (status → running), the chat bubble for that
        // turn lands via `message_started` and the queue chip
        // MUST disappear — having the same turn visible both in
        // the chat AND in the queue was the "stuck in queue after
        // dispatch" bug. If we ever want a progress glimpse of the
        // running turn, that belongs in the chat (spinner bar),
        // not here.
        final entries = QueueService().pendingFor(widget.sessionId);
        if (entries.isEmpty) return const SizedBox.shrink();

        final pendingCount = entries.length;
        // No running entries ever end up in [entries] now — fixed at 0
        // so the display logic stays simple.
        const runningCount = 0;

        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          decoration: BoxDecoration(
            color: c.green.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.green.withValues(alpha: 0.15)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  child: Row(
                    children: [
                      Icon(Icons.queue_rounded, size: 11, color: c.green),
                      const SizedBox(width: 5),
                      Text(
                        runningCount > 0 && pendingCount > 0
                            ? '$runningCount running · $pendingCount queued'
                            : runningCount > 0
                                ? '$runningCount running'
                                : '$pendingCount queued',
                        style: GoogleFonts.firaCode(
                            fontSize: 10,
                            color: c.green,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 6),
                      if (!_expanded)
                        Expanded(
                          child: Text(entries.first.message,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                  fontSize: 10, color: c.textMuted)),
                        ),
                      if (_expanded) const Spacer(),
                      if (_expanded && pendingCount > 0)
                        GestureDetector(
                          onTap: () => QueueService()
                              .clear(widget.appId, widget.sessionId),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Text('chat.clear_short'.tr(),
                                style: GoogleFonts.inter(
                                    fontSize: 9, color: c.textDim)),
                          ),
                        ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_up_rounded,
                        size: 14,
                        color: c.green,
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded)
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                    itemCount: entries.length,
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      final isRunning = e.status.isRunning;
                      final isTail = i == entries.length - 1;
                      final canEdit = isTail &&
                          !isRunning &&
                          !e.optimistic &&
                          widget.onEditTail != null;
                      return Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            Container(
                              width: 16,
                              height: 16,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: (isRunning ? c.orange : c.green)
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: isRunning
                                  ? SizedBox(
                                      width: 9,
                                      height: 9,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.2,
                                        valueColor: AlwaysStoppedAnimation(
                                            c.orange),
                                      ),
                                    )
                                  : Text('${i + 1}',
                                      style: GoogleFonts.firaCode(
                                          fontSize: 8, color: c.green)),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(e.message,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inter(
                                      fontSize: 11, color: c.text)),
                            ),
                            if (canEdit) ...[
                              const SizedBox(width: 2),
                              Tooltip(
                                message:
                                    'Edit — replace this queued message',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(3),
                                  onTap: () => widget.onEditTail!(e),
                                  child: const Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(Icons.edit_outlined,
                                        size: 11),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: 2),
                            // Cancel button is hidden for the running
                            // entry — use the composer's Stop button
                            // to abort an in-flight turn.
                            if (!isRunning)
                              InkWell(
                                borderRadius: BorderRadius.circular(3),
                                onTap: e.optimistic
                                    ? null
                                    : () => QueueService().cancel(
                                        widget.appId,
                                        widget.sessionId,
                                        e.id),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(Icons.close_rounded,
                                      size: 11,
                                      color: e.optimistic
                                          ? c.textDim
                                              .withValues(alpha: 0.4)
                                          : c.textDim),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Status pill (Reconnecting / Interrupted / Turn in progress) ───

class _StatusPill extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color fg;
  final Color bg;
  final String? tooltip;
  final bool pulse;
  const _StatusPill({
    required this.label,
    required this.icon,
    required this.fg,
    required this.bg,
    this.tooltip,
    this.pulse = false,
  });

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with TickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void initState() {
    super.initState();
    if (widget.pulse) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_StatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && _ctrl == null) {
      _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat(reverse: true);
    } else if (!widget.pulse && _ctrl != null) {
      _ctrl!.dispose();
      _ctrl = null;
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anim = _ctrl;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: widget.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: widget.fg.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          anim != null
              ? AnimatedBuilder(
                  animation: anim,
                  builder: (_, _) => Icon(
                    widget.icon,
                    size: 9,
                    color: widget.fg.withValues(alpha: 0.4 + 0.6 * anim.value),
                  ),
                )
              : Icon(widget.icon, size: 9, color: widget.fg),
          const SizedBox(width: 5),
          Text(
            widget.label,
            style: GoogleFonts.inter(
              fontSize: 10,
              color: widget.fg,
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: body);
    }
    return body;
  }
}

// ─── Header pieces ──────────────────────────────────────────────────────────

class _ToolActivityBar extends StatefulWidget {
  final String toolName;
  final int elapsedMs;
  final Color accent;
  final VoidCallback? onAbort;
  const _ToolActivityBar({
    required this.toolName,
    required this.elapsedMs,
    required this.accent,
    this.onAbort,
  });

  @override
  State<_ToolActivityBar> createState() => _ToolActivityBarState();
}

class _ToolActivityBarState extends State<_ToolActivityBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;
  bool _abortHover = false;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  String _formatTool(String raw) {
    final r = raw.replaceAll('tool_use:', '').trim();
    if (r.isEmpty) return 'Tool';
    return r;
  }

  String _formatElapsed(int ms) {
    final s = ms / 1000;
    if (s < 60) return '${s.toStringAsFixed(1)}s';
    final m = (s / 60).floor();
    final rest = (s % 60).floor();
    return '${m}m ${rest}s';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSmall = MediaQuery.of(context).size.width < 600;
    // Capped to the composer rail (800 px on desktop, full-width on
    // < 600 px) and rendered as a centered card with a full border
    // instead of an edge-to-edge strip with `border-bottom`.
    return Center(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: isSmall ? double.infinity : 800),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Color.lerp(c.surface, widget.accent, 0.04) ?? c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.accent.withValues(alpha: 0.22),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
          AnimatedBuilder(
            animation: _shimmer,
            builder: (_, _) {
              final t = _shimmer.value;
              return SizedBox(
                height: 2,
                child: Stack(
                  children: [
                    Container(
                        color:
                            widget.accent.withValues(alpha: 0.15)),
                    FractionallySizedBox(
                      widthFactor: 0.25,
                      alignment:
                          Alignment(-1 + (t * 2.5).clamp(-1, 1.5), 0),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              widget.accent.withValues(alpha: 0),
                              widget.accent,
                              widget.accent.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: widget.accent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Icon(Icons.bolt_rounded,
                      size: 11, color: widget.accent),
                ),
                const SizedBox(width: 9),
                Text(
                  'chat.running'.tr(),
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _formatTool(widget.toolName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                      fontSize: 12,
                      color: c.textBright,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _formatElapsed(widget.elapsedMs),
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: widget.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (widget.onAbort != null)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) =>
                        setState(() => _abortHover = true),
                    onExit: (_) =>
                        setState(() => _abortHover = false),
                    child: GestureDetector(
                      onTap: widget.onAbort,
                      child: AnimatedContainer(
                        duration:
                            const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: _abortHover
                              ? c.red.withValues(alpha: 0.16)
                              : c.red.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: c.red
                                .withValues(alpha: _abortHover ? 0.5 : 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.stop_rounded,
                                size: 11, color: c.red),
                            const SizedBox(width: 4),
                            Text(
                              'common.cancel'.tr(),
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: c.red,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}

/// Pill-shaped floating indicator that appears in the bottom-right
/// of the chat area when the side panel is closed but the turn
/// produced artifacts. Clicking opens the panel on the latest.
class _ArtifactsFloatingChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Positioned(
      bottom: 110,
      right: 20,
      child: ListenableBuilder(
        listenable: ArtifactService(),
        builder: (_, _) {
          final service = ArtifactService();
          if (service.isOpen || !service.hasAny) {
            return const SizedBox.shrink();
          }
          final count = service.artifacts.length;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: service.openFirst,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      c.accentPrimary,
                      Color.lerp(c.accentPrimary, c.accentSecondary, 0.5) ??
                          c.accentPrimary,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: c.accentPrimary.withValues(alpha: 0.4),
                      blurRadius: 24,
                      spreadRadius: -4,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      color: c.onAccent,
                      size: 14,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      count == 1
                          ? '1 artifact'
                          : '$count artifacts',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: c.onAccent,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Standalone 3-bar "agent is thinking" skeleton rendered at the
/// bottom of the chat list while we wait for the first response
/// signal. Independent of any ChatMessage — driven purely by
/// ``_awaitingAgentResponse``.
/// iMessage-style typing dots — three tiny circles that wave in
/// sequence while the agent is thinking. Mirror of the web
/// `ChatTypingSkeleton` in components/chat/chat-typing-skeleton.tsx.
///
/// Wave spec (intentionally low-key — "barely there" feel):
///   - 3 dots, 5 px Ø, gap 4 px
///   - Each dot pulses opacity 0.18 → 0.55 and translates Y -1.5 → 0
///   - Colour `c.textDim` (one step softer than textMuted)
///   - 1.2 s loop, 0.18 s stagger between dots
class _ChatTypingSkeleton extends StatefulWidget {
  const _ChatTypingSkeleton();

  @override
  State<_ChatTypingSkeleton> createState() => _ChatTypingSkeletonState();
}

class _ChatTypingSkeletonState extends State<_ChatTypingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _TypingDot(ctrl: _ctrl, delayFraction: 0.00, color: c.textDim),
          const SizedBox(width: 4),
          _TypingDot(ctrl: _ctrl, delayFraction: 0.15, color: c.textDim),
          const SizedBox(width: 4),
          _TypingDot(ctrl: _ctrl, delayFraction: 0.30, color: c.textDim),
        ],
      ),
    );
  }
}

class _TypingDot extends StatelessWidget {
  final AnimationController ctrl;
  final double delayFraction;
  final Color color;
  const _TypingDot({
    required this.ctrl,
    required this.delayFraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, _) {
        // Triangular wave matching the web `easeInOut` keyframes
        // [0.18 → 0.55 → 0.18] over the loop, with a phase offset per
        // dot so the three pulse one after another.
        double t = (ctrl.value - delayFraction) % 1.0;
        if (t < 0) t += 1.0;
        final pulse = t < 0.5 ? t * 2 : (1 - t) * 2;
        final opacity = 0.18 + 0.37 * pulse;
        final dy = -1.5 * pulse;
        return Transform.translate(
          offset: Offset(0, dy),
          child: Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: color.withValues(alpha: opacity),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

/// Compact pill button with optional leading icon and optional
/// trailing chevron — hover reveals a soft surface bg. Used by both
/// the top-left app-name menu and the top-right workspace toggle.
class _AppMenuButton extends StatefulWidget {
  final String name;
  final Color muted;
  final Color bright;
  final Color surfaceAlt;
  final VoidCallback onTap;
  final Widget? leading;
  final bool hideChevron;
  const _AppMenuButton({
    required this.name,
    required this.muted,
    required this.bright,
    required this.surfaceAlt,
    required this.onTap,
    this.leading,
    this.hideChevron = false,
  });

  @override
  State<_AppMenuButton> createState() => _AppMenuButtonState();
}

class _AppMenuButtonState extends State<_AppMenuButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _hover ? widget.surfaceAlt : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 5),
              ],
              Text(
                widget.name,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: widget.bright,
                  letterSpacing: -0.2,
                ),
              ),
              if (!widget.hideChevron) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: widget.muted.withValues(alpha: _hover ? 1.0 : 0.7),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

