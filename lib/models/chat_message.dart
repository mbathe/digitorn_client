import 'package:flutter/foundation.dart';

enum MessageRole { user, assistant, system }

// ─── Timeline content blocks ─────────────────────────────────────────────────
// Each block represents one element in the chronological message flow.

enum ContentBlockType { text, toolCall, thinking, agentEvent, hookEvent }

class ContentBlock {
  final ContentBlockType type;

  // Text block
  String textContent;

  // Tool call block
  ToolCall? toolCall;

  // Thinking block
  bool thinkingActive;

  // Agent event block
  AgentEventData? agentEvent;

  // Hook event block
  HookEventData? hookEvent;

  ContentBlock._({
    required this.type,
    this.textContent = '',
    this.toolCall,
    this.thinkingActive = false,
    this.agentEvent,
    this.hookEvent,
  });

  factory ContentBlock.text(String text) =>
      ContentBlock._(type: ContentBlockType.text, textContent: text);

  factory ContentBlock.tool(ToolCall call) =>
      ContentBlock._(type: ContentBlockType.toolCall, toolCall: call);

  factory ContentBlock.thinking({String text = '', bool active = true}) =>
      ContentBlock._(
          type: ContentBlockType.thinking,
          textContent: text,
          thinkingActive: active);

  factory ContentBlock.agent(AgentEventData event) =>
      ContentBlock._(type: ContentBlockType.agentEvent, agentEvent: event);

  factory ContentBlock.hook(HookEventData event) =>
      ContentBlock._(type: ContentBlockType.hookEvent, hookEvent: event);
}

// ─── Data classes for rich events ────────────────────────────────────────────

class ToolCall {
  final String id;
  final String name;
  final String label;  // Display verb from daemon (e.g. "Read", "Write", "Bash")
  final String detail; // Display detail from daemon (e.g. file path, command)
  final Map<String, dynamic> params;
  String status; // 'started' | 'completed' | 'failed'
  dynamic result;
  String? error;

  ToolCall({
    required this.id,
    required this.name,
    this.label = '',
    this.detail = '',
    required this.params,
    this.status = 'started',
    this.result,
    this.error,
  });

  /// Display verb — uses daemon-provided label, fallback to parsed name
  String get displayLabel {
    // Parallel: show count
    if (name == 'run_parallel' && result is Map && result['results'] is List) {
      final count = (result['results'] as List).length;
      return '$count Parallel actions';
    }
    if (label.isNotEmpty) return label;
    final segs = name.split(RegExp(r'[.__]'));
    final last = segs.last;
    return last.split('_').map((s) => s.isEmpty ? '' : s[0].toUpperCase() + s.substring(1)).join(' ');
  }

  /// Display detail — uses daemon-provided detail, fallback to params
  String get displayDetail {
    if (detail.isNotEmpty) return detail;
    for (final k in ['path', 'file', 'filename', 'name', 'query', 'command', 'url', 'key']) {
      if (params.containsKey(k) && params[k] is String && (params[k] as String).isNotEmpty) {
        final v = params[k] as String;
        if (v.length > 60) {
          final parts = v.replaceAll('\\', '/').split('/');
          return parts.length > 2 ? '…/${parts.sublist(parts.length - 2).join('/')}' : v;
        }
        return v;
      }
    }
    return '';
  }
}

class AgentEventData {
  final String agentId;
  final String status; // spawned | completed | failed | cancelled
  final String specialist;
  final String task;
  final double duration;
  final String preview;

  AgentEventData({
    required this.agentId,
    required this.status,
    this.specialist = '',
    this.task = '',
    this.duration = 0,
    this.preview = '',
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

  // ── Chronological timeline of content blocks ────────────────────────────────
  final List<ContentBlock> _timeline = [];
  List<ContentBlock> get timeline => _timeline;

  // ── Computed getters (backward compatible) ──────────────────────────────────

  /// Full concatenated text from all text blocks
  String get text {
    final buf = StringBuffer();
    for (final b in _timeline) {
      if (b.type == ContentBlockType.text) buf.write(b.textContent);
    }
    return buf.toString();
  }

  /// All thinking text concatenated
  String get thinkingText {
    final buf = StringBuffer();
    for (final b in _timeline) {
      if (b.type == ContentBlockType.thinking) buf.write(b.textContent);
    }
    return buf.toString();
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
  }) : createdAt = timestamp ?? DateTime.now() {
    if (initialText.isNotEmpty) {
      _timeline.add(ContentBlock.text(initialText));
    }
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

  void appendThinking(String delta) {
    final existing = _timeline.lastWhere(
      (b) => b.type == ContentBlockType.thinking,
      orElse: () {
        final block = ContentBlock.thinking(active: true);
        _timeline.add(block);
        return block;
      },
    );
    existing.textContent += delta;
    notifyListeners();
  }

  void setThinkingText(String text) {
    final existing = _timeline.lastWhereOrNull(
      (b) => b.type == ContentBlockType.thinking,
    );
    if (existing != null) {
      existing.textContent = text;
    } else {
      _timeline.add(ContentBlock.thinking(text: text, active: false));
    }
    notifyListeners();
  }

  void setThinkingState(bool state) {
    for (final b in _timeline) {
      if (b.type == ContentBlockType.thinking) {
        b.thinkingActive = state;
      }
    }
    // If starting thinking and no block exists, create one
    if (state && !_timeline.any((b) => b.type == ContentBlockType.thinking)) {
      _timeline.add(ContentBlock.thinking(active: true));
    }
    notifyListeners();
  }

  void setStreamingState(bool state) {
    _isStreaming = state;
    notifyListeners();
  }

  void addOrUpdateToolCall(ToolCall call) {
    // Find existing tool call block with same id & status 'started'
    final i = _timeline.indexWhere(
      (b) =>
          b.type == ContentBlockType.toolCall &&
          b.toolCall != null &&
          b.toolCall!.id == call.id &&
          b.toolCall!.status == 'started',
    );
    if (i != -1) {
      // Update in-place (keeps chronological position)
      _timeline[i].toolCall = call;
    } else {
      _timeline.add(ContentBlock.tool(call));
    }
    notifyListeners();
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
