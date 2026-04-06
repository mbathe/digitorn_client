import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import '../../models/chat_message.dart';
import '../../models/app_summary.dart';
import '../../services/api_client.dart';
import '../../services/session_service.dart';
import '../../services/workspace_service.dart';
import '../../models/workspace_state.dart';
import '../../models/session_metrics.dart';
import '../../main.dart';
import 'chat_bubbles.dart';
import '../command_palette.dart';
import 'context_modal.dart';
import 'tools_modal.dart';
import 'tasks_modal.dart';
import 'slash_commands.dart';
import 'checkpoint_rail.dart';
import '../../services/notification_service.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../../theme/app_theme.dart';

// ─── Color tokens ────────────────────────────────────────────────────────────
// All colors now come from context.colors (AppColors theme extension).

class ApprovalRequest {
  final String id;
  final String toolName;
  final Map<String, dynamic> params;
  final String riskLevel;
  final String description;
  ApprovalRequest({
    required this.id,
    required this.toolName,
    required this.params,
    this.riskLevel = 'medium',
    this.description = '',
  });
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

  final List<ChatMessage> _messages = [];
  final Map<String, GlobalKey> _messageKeys = {};
  final List<ApprovalRequest> _pendingApprovals = [];

  StreamSubscription? _sseSub;
  StreamSubscription? _sessionChangeSub;
  ChatMessage? _currentMsg;
  bool _isSending = false;
  bool _hadTokens = false; // Track if any tokens were streamed this turn
  bool _showScrollDown = false;
  List<String> _suggestions = [];
  List<SlashCommand> _slashCommands = []; // Slash command menu

  // Token counters
  int _inTokens = 0;
  int _outTokens = 0;
  int _contextMax = 200000;

  // Daemon status phase (e.g. 'planning', 'executing', 'done')
  String _statusPhase = '';
  // SSE heartbeat — true while streaming, used for alive indicator
  bool _heartbeat = false;

  // Track current session to detect switches
  String? _currentSessionId;

  @override
  void initState() {
    super.initState();
    _sseSub = SessionService().events.listen(_onEvent);
    _sessionChangeSub = SessionService().onSessionChange.listen(_onSessionChange);
    _scroll.addListener(_onScroll);
    _ctrl.addListener(_onTextChanged);
    // Restore history if there's already an active session
    final active = SessionService().activeSession;
    if (active != null) {
      _currentSessionId = active.sessionId;
      _tryRestoreAndConnect(active.appId, active.sessionId);
    }
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    _sessionChangeSub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ─── Session switch ──────────────────────────────────────────────────────

  void _onSessionChange(String? newSessionId) {
    if (newSessionId == _currentSessionId) return;
    _currentSessionId = newSessionId;

    // Clean up workspace from previous session
    WorkspaceService().clearAll();
    WorkspaceState().onNewSession();
    SessionMetrics().reset();

    // Clear current state
    setState(() {
      _messages.clear();
      _messageKeys.clear();
      _pendingApprovals.clear();
      _currentMsg = null;
      _isSending = false;
      _statusPhase = '';
      _inTokens = 0;
      _outTokens = 0;
    });

    if (newSessionId == null) return;
    final session = SessionService().activeSession;
    if (session == null) return;

    // Always try to restore — _tryRestoreHistory handles both new and existing
    _tryRestoreAndConnect(session.appId, session.sessionId);
  }

  Future<void> _tryRestoreAndConnect(String appId, String sessionId) async {
    // Try loading full history (works for existing sessions, returns null/empty for new)
    final full = await SessionService().loadFullHistory(appId, sessionId);

    if (!mounted || _currentSessionId != sessionId) return;

    if (full != null) {
      final messages = full['messages'] ?? full['turns'] ?? [];
      final workspace = full['workspace'] as String? ?? '';
      final title = full['title'] as String? ?? '';

      if (messages is List && messages.isNotEmpty) {
        // Existing session — restore everything
        _restoreFromHistory(List<Map<String, dynamic>>.from(messages));

        if (title.isNotEmpty) {
          SessionService().updateSessionTitle(sessionId, title);
        }
        if (workspace.isNotEmpty && mounted) {
          context.read<AppState>().setWorkspace(workspace);
        }
        _restoreMemorySnapshot(full);
        _restoreWorkbenchSnapshot(full);

        final interrupted = full['interrupted'] as bool? ?? false;
        if (interrupted && mounted) {
          // Show interrupted state but don't auto-resume — wait for user message
          setState(() => _statusPhase = 'interrupted');
        }

        // Reconnect + resume
        _reconnectSession(appId, sessionId);
        return;
      } else if (workspace.isNotEmpty && mounted) {
        // Session exists on daemon but no messages yet — restore workspace
        context.read<AppState>().setWorkspace(workspace);
        return;
      }
    }

    // Truly new session — reset workspace
    if (mounted) context.read<AppState>().setWorkspace('');
  }

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

  void _restoreWorkbenchSnapshot(Map<String, dynamic> full) {
    final workbench = full['workbench_snapshot'] as Map<String, dynamic>?;
    if (workbench == null) return;
    final buffers = workbench['buffers'] as List<dynamic>?;
    if (buffers != null) {
      for (final buf in buffers) {
        if (buf is Map<String, dynamic>) {
          WorkspaceService().handleEvent('workbench_read', buf);
        }
      }
    }
  }

  Future<void> _reconnectSession(String appId, String sessionId) async {
    // Start metrics polling
    SessionMetrics().startPolling(appId, sessionId);
    // Check state + resume if interrupted (workspace already restored by _tryRestoreHistory)
    await SessionService().checkAndResume(appId, sessionId);
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
          ));
        } else if (role == 'assistant') {
          final msg = ChatMessage(
            id: 'hist-${restored.length}',
            role: MessageRole.assistant,
          );

          // Restore thinking (shows before tools/text)
          final thinking = turn['thinking'] as String?;
          if (thinking != null && thinking.isNotEmpty) {
            msg.setThinkingText(thinking);
          }

          // Restore tool calls with full detail
          final toolCalls = turn['toolCalls'] as List<dynamic>? ?? [];
          for (int i = 0; i < toolCalls.length; i++) {
            final tc = toolCalls[i];
            if (tc is Map<String, dynamic>) {
              // Skip silent/hidden tools in history too
              final name = tc['name'] as String? ?? '';
              if (_isHiddenTool(name)) continue;

              msg.addOrUpdateToolCall(ToolCall(
                id: tc['id'] as String? ?? 'tc-$i',
                name: name,
                label: tc['label'] as String? ?? '',
                detail: tc['detail'] as String? ?? '',
                params: Map<String, dynamic>.from(tc['params'] ?? {}),
                status: tc['status'] as String? ?? 'completed',
                result: tc['result'],
                error: tc['error'] as String?,
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
      _scrollToBottom();
    }
  }

  // ─── SSE handler (session event bus) ────────────────────────────────────
  // The daemon sends status events with phase: turn_start, requesting,
  // tool_use, responding, turn_end. Use these directly for the spinner.
  // memory_update and agent_event come as dedicated events — no need to
  // extract them from tool_call results.
  // workbench_*, terminal_output, diagnostics → workspace panel only.

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    final data = event['data'] as Map<String, dynamic>? ?? {};

    // ── Internal session metadata (from checkAndResume) ───────────────
    if (type == '_session_meta') {
      // Restore workspace path from daemon session
      final workspace = data['workspace'] as String? ?? '';
      if (workspace.isNotEmpty && mounted) {
        context.read<AppState>().setWorkspace(workspace);
      }
      return;
    }

    // ── Infrastructure events (no bubble) ────────────────────────────
    if (type == 'connected' || type == 'heartbeat') {
      if (type == 'heartbeat' && mounted) {
        setState(() => _heartbeat = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _heartbeat = false);
        });
      }
      return;
    }

    // ── Workspace-only events (not shown in chat) ────────────────────
    const wsOnly = {
      'workbench_read', 'workbench_write', 'workbench_edit',
      'terminal_output', 'diagnostics',
    };
    if (wsOnly.contains(type)) {
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
      final agentId = data['agent_id'] as String? ?? '';
      final status = data['status'] as String? ?? '';
      if (agentId.isNotEmpty) {
        WorkspaceState().updateAgent(SubAgent(
          id: agentId,
          specialist: data['specialist'] as String? ?? '',
          task: data['task'] as String? ?? '',
          status: switch (status) {
            'spawned'   => AgentStatus.spawned,
            'running'   => AgentStatus.running,
            'completed' => AgentStatus.completed,
            'failed'    => AgentStatus.failed,
            'cancelled' => AgentStatus.cancelled,
            _           => AgentStatus.running,
          },
          duration: (data['duration_seconds'] as num?)?.toDouble() ?? 0,
          preview: (data['preview'] as String?) ?? '',
          updatedAt: DateTime.now(),
        ));
      }
      // Also show in chat bubble
      _ensureBubble();
      if (_currentMsg != null) {
        DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
      }
      _scrollToBottom();
      return;
    }

    // ── Status → spinner + metrics ─────────────────────────────────────
    if (type == 'status') {
      final phase = data['phase'] as String? ?? '';
      if (phase.isNotEmpty && mounted) {
        setState(() => _statusPhase = phase);
      }
      // Metrics are polled from the API, not from SSE events
      if (phase == 'turn_start') {
        WorkspaceState().onTurnStart();
      }
      return;
    }

    // ── Ensure assistant bubble exists for remaining chat events ─────
    _ensureBubble();

    switch (type) {
      // ── Thinking ───────────────────────────────────────────────────
      case 'thinking_started':
        _currentMsg?.setThinkingState(true);
        _scrollToBottom();
        break;
      case 'thinking_delta':
        final delta = data['delta'] as String? ?? '';
        if (delta.isNotEmpty) _currentMsg?.appendThinking(delta);
        _scrollToBottom();
        break;
      case 'thinking':
        final text = data['text'] as String? ?? '';
        if (text.isNotEmpty) _currentMsg?.setThinkingText(text);
        _scrollToBottom();
        break;

      // ── Tool start ─────────────────────────────────────────────────
      case 'tool_start':
        final toolName = data['name'] as String? ?? 'tool';
        final display = data['display'] as Map<String, dynamic>?;
        final verb = display?['verb'] as String? ??
            data['label'] as String? ?? toolName;
        final silent = data['silent'] as bool? ?? false;

        final hideFromChat = silent || _isHiddenTool(toolName);

        // Spinner always updates
        final spinnerLabel = _friendlySpinnerLabel(toolName, verb);
        if (mounted) setState(() => _statusPhase = spinnerLabel);

        // Capture bash/shell command for terminal
        if (toolName.toLowerCase().contains('bash') ||
            toolName.toLowerCase().contains('shell')) {
          final params = data['params'] as Map<String, dynamic>? ?? {};
          final cmd = params['command'] as String? ?? params['cmd'] as String? ?? '';
          if (cmd.isNotEmpty) WorkspaceService().setPendingCommand(cmd);
        }

        if (!hideFromChat && _currentMsg != null) {
          DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
          _scrollToBottom();
        }
        break;

      // ── Tool complete ──────────────────────────────────────────────
      case 'tool_call':
        final toolName = data['name'] as String? ?? '';
        final silent = data['silent'] as bool? ?? false;
        if (mounted) setState(() => _statusPhase = 'responding');

        final hideFromChat = silent || _isHiddenTool(toolName);

        // Memory tools → always route to sidebar
        if (WorkspaceState.isMemoryTool(toolName)) {
          final action = toolName.split(RegExp(r'[.__]')).last;
          final result = data['result'];
          if (result is Map<String, dynamic>) {
            WorkspaceState().handleMemoryUpdate(action, result);
          }
        }

        if (!hideFromChat && _currentMsg != null) {
          DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
          _scrollToBottom();
        }

        // Synthesize workbench events from tool_call results
        _synthesizeWorkbench(toolName, data);
        break;

      // ── Text tokens (update spinner) ───────────────────────────────
      case 'token':
        _hadTokens = true;
        if (_statusPhase != 'responding' && mounted) {
          setState(() => _statusPhase = 'responding');
        }
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
        }
        _scrollToBottom();
        break;

      // ── Stream done ────────────────────────────────────────────────
      case 'stream_done':
        _currentMsg?.setThinkingState(false);
        break;

      // ── Token counts ───────────────────────────────────────────────
      case 'out_token':
        final count = data['count'] as int? ?? 0;
        if (count > 0 && mounted) setState(() => _outTokens += count);
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
        }
        break;
      case 'in_token':
        final count = data['count'] as int? ?? 0;
        if (count > 0 && mounted) setState(() => _inTokens = count);
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
        }
        break;

      // ── Hook (context_status for pressure meter) ───────────────────
      case 'hook':
        final actionType = data['action_type'] as String? ?? '';
        final phase = data['phase'] as String? ?? '';
        if (actionType == 'context_status' && phase == 'update') {
          final details = data['details'] as Map<String, dynamic>? ?? {};
          final estimated = details['estimated_tokens'] as int? ?? 0;
          final maxT = details['max_tokens'] as int? ?? 0;
          if (estimated > 0 && mounted) setState(() => _inTokens = estimated);
          if (maxT > 0 && mounted) setState(() => _contextMax = maxT);
          SessionMetrics().updateContext(details);
        }
        break;

      // ── Result → turn complete ─────────────────────────────────────
      case 'result':
        final content = data['content'] as String? ?? '';
        final resultError = data['error'] as String?;
        if (!_hadTokens && content.isNotEmpty && _currentMsg != null) {
          _currentMsg!.appendText(content);
        }
        _currentMsg?.setStreamingState(false);
        _currentMsg?.setThinkingState(false);
        // Desktop notification
        NotificationService().onTurnComplete(content: content, error: resultError);
        final usage = data['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          final inT = usage['input_tokens'] as int? ?? 0;
          if (inT > 0 && mounted) setState(() => _inTokens = inT);
        }
        final ctx = data['context'] as Map<String, dynamic>?;
        if (ctx != null) {
          final maxT = ctx['context_window'] as int? ?? ctx['max_tokens'] as int?;
          if (maxT != null && maxT > 0 && mounted) setState(() => _contextMax = maxT);
          SessionMetrics().updateContext(ctx);
        }
        final wsStatus = data['workspace_status'] as Map<String, dynamic>?;
        if (wsStatus != null) WorkspaceService().updateGitStatus(wsStatus);
        if (_currentMsg != null) {
          DigitornApiClient().handleStreamEvent(type, data, _currentMsg!);
        }
        _currentMsg = null;
        _hadTokens = false;
        if (mounted) {
          setState(() {
            _isSending = false;
            _statusPhase = '';
            _suggestions = _generateSuggestions(data, content);
          });
        }
        _scrollToBottom();
        break;

      // ── Error ──────────────────────────────────────────────────────
      case 'error':
        final errMsg = data['error'] as String? ?? 'Unknown error';
        if (_currentMsg != null) {
          _currentMsg!.appendText('\n\n**Error:** $errMsg');
          _currentMsg!.setStreamingState(false);
        } else {
          _messages.add(ChatMessage(
            id: 'err-${DateTime.now().millisecondsSinceEpoch}',
            role: MessageRole.assistant,
            initialText: '**Error:** $errMsg',
          ));
        }
        _currentMsg = null;
        _hadTokens = false;
        if (mounted) {
          setState(() {
            _isSending = false;
            _statusPhase = '';
          });
        }
        _scrollToBottom();
        break;

      // ── Abort (daemon confirmed abort) ────────────────────────────
      case 'abort':
        _handleAbortCleanup();
        break;

      // ── Approval request ───────────────────────────────────────────
      case 'approval_request':
        if (mounted) {
          setState(() => _pendingApprovals.add(ApprovalRequest(
            id: data['request_id'] as String? ?? DateTime.now().toString(),
            toolName: data['tool_name'] as String? ?? data['tool'] as String? ?? 'unknown',
            params: Map<String, dynamic>.from(data['tool_params'] ?? data['params'] ?? {}),
            riskLevel: data['risk_level'] as String? ?? 'medium',
            description: data['description'] as String? ?? '',
          )));
        }
        break;

      // ── Unhandled → ignore ─────────────────────────────────────────
      default:
        break;
    }
  }

  void _ensureBubble() {
    if (_currentMsg != null) return;
    final msg = ChatMessage(
      id: DateTime.now().toString(),
      role: MessageRole.assistant,
    );
    msg.setStreamingState(true);
    setState(() {
      _currentMsg = msg;
      _messages.add(msg);
    });
    _scrollToBottom();
  }

  // ─── Send (fire-and-forget via POST /messages, response via SSE) ────────

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _isSending) return;
    _isSending = true;

    final appState = context.read<AppState>();
    final activeApp = appState.activeApp;
    final workspace = appState.workspace;

    if (activeApp?.workspaceMode == 'required' && workspace.isEmpty) {
      _isSending = false;
      return;
    }

    final session = SessionService().activeSession;
    final appId = activeApp?.appId ?? DigitornApiClient().appId;

    if (session == null) {
      _isSending = false;
      return;
    }

    final userMsg = ChatMessage(
      id: DateTime.now().toString(),
      role: MessageRole.user,
      initialText: text,
    );

    // Auto-title: use first message as session title
    if (_messages.isEmpty && session.title.isEmpty) {
      final title = text.length > 60 ? '${text.substring(0, 60)}…' : text;
      SessionService().updateSessionTitle(session.sessionId, title);
    }

    _hadTokens = false;
    setState(() {
      _messages.add(userMsg);
      _ctrl.clear();
      _statusPhase = 'requesting';
      _suggestions = [];
      _outTokens = 0;
    });
    _scrollToBottom();
    _focus.requestFocus();

    // Invalidate cached history since we're adding new messages
    SessionService().invalidateHistory(session.sessionId);

    // Fire-and-forget — response arrives via session SSE (_onEvent)
    SessionService().reconnectSSE();
    // Start polling session metrics
    SessionMetrics().startPolling(appId, session.sessionId);

    final err = await SessionService().sendMessage(
      appId, session.sessionId, text,
      workspace: workspace.isEmpty ? null : workspace,
    );
    if (err != null) {
      final errMsg = ChatMessage(
        id: '${DateTime.now().millisecondsSinceEpoch}',
        role: MessageRole.assistant,
        initialText: '**Error:** $err',
      );
      setState(() {
        _messages.add(errMsg);
        _isSending = false;
      });
      _scrollToBottom();
    }
    // _isSending stays true — will be reset by _onEvent when 'result' arrives
  }

  // ─── Abort ────────────────────────────────────────────────────────────────

  Future<void> _abort() async {
    final session = SessionService().activeSession;
    final appId = context.read<AppState>().activeApp?.appId ?? DigitornApiClient().appId;
    if (session == null) return;

    // Show immediate visual feedback
    setState(() => _statusPhase = 'aborting');

    // Send abort to daemon — it will:
    // 1. Cancel the asyncio task
    // 2. Save state (messages, memory, tool calls)
    // 3. Mark session.interrupted = True
    // 4. Emit SSE {"type": "abort"} which _onEvent handles
    await SessionService().abortSession(appId, session.sessionId);

    // Fallback: if SSE abort event doesn't arrive within 3s, clean up locally
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isSending) {
        _handleAbortCleanup();
      }
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
    _hadTokens = false;
    if (mounted) {
      setState(() {
        _isSending = false;
        _statusPhase = '';
      });
    }
  }

  // ─── Approve ──────────────────────────────────────────────────────────────

  Future<void> _approve(ApprovalRequest req, bool approved) async {
    setState(() => _pendingApprovals.remove(req));
    final appId = context.read<AppState>().activeApp?.appId ?? DigitornApiClient().appId;
    await SessionService().approveRequest(
      appId: appId,
      requestId: req.id,
      approved: approved,
    );
    final msg = ChatMessage(
      id: DateTime.now().toString(),
      role: MessageRole.assistant,
      initialText: approved
          ? '✅ **Approved** — `${req.toolName}` will proceed.'
          : '❌ **Denied** — `${req.toolName}` was blocked.',
    );
    setState(() => _messages.add(msg));
    _scrollToBottom();
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
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
    final activeApp = context.watch<AppState>().activeApp;
    final workspace = context.watch<AppState>().workspace;
    final session = context.watch<SessionService>().activeSession;

    final workspaceRequired =
        activeApp?.workspaceMode == 'required' && workspace.isEmpty;

    return DropTarget(
      onDragDone: (details) {
        final paths = details.files.map((f) => f.path).join('\n');
        if (paths.isNotEmpty) {
          _ctrl.text = '${_ctrl.text}${_ctrl.text.isEmpty ? '' : '\n'}$paths';
          _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
          _focus.requestFocus();
        }
      },
      child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_isSending) _abort();
        },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
          final app = context.read<AppState>().activeApp;
          if (app != null) {
            SessionService().createAndSetSession(app.appId);
            if (context.mounted) showToast(context, 'New session created');
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          CommandPalette.show(context);
        },
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          setState(() {
            _messages.clear();
      _messageKeys.clear();
            _currentMsg = null;
          });
          if (context.mounted) showToast(context, 'Chat cleared');
        },
      },
      child: Focus(
        autofocus: true,
        child: Container(
      color: context.colors.bg,
      child: Column(
        children: [
          // ── Header (full width) ──────────────────────────────────────────
          _buildHeader(activeApp, session?.displayTitle),

          // ── Workspace warning banner ──────────────────────────────────────
          if (workspaceRequired)
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width < 600
                      ? double.infinity : 720,
                ),
                child: _WorkspaceBanner(appName: activeApp?.name ?? ''),
              ),
            ),

          // ── Approval banners — centered ───────────────────────────────────
          ..._pendingApprovals.map((r) => Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width < 600
                        ? double.infinity : 720,
                  ),
                  child: _ApprovalBanner(
                    request: r,
                    onApprove: () => _approve(r, true),
                    onDeny: () => _approve(r, false),
                  ),
                ),
              )),

          // ── Messages, empty state, or history skeleton ──────────────────
          Expanded(
            child: _messages.isEmpty && !context.watch<SessionService>().isLoadingHistory
                // Empty state: centered greeting + input
                ? _buildEmptyState(activeApp, workspace, workspaceRequired)
                // Messages or loading
                : _buildMessageArea(
                    activeApp: activeApp,
                    workspace: workspace,
                    workspaceRequired: workspaceRequired,
                    isLoadingHistory: context.watch<SessionService>().isLoadingHistory,
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
                        ? double.infinity : 720,
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
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width < 600
                      ? double.infinity : 720,
                ),
                child: _ChatInput(
                  controller: _ctrl,
                  focusNode: _focus,
                  isActive: _isSending,
                  disabled: workspaceRequired,
                  inTokens: _inTokens,
                  contextMax: _contextMax,
                  onSend: _send,
                  onAbort: _abort,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
    ),
    ),
    );
  }

  Widget _buildEmptyState(AppSummary? app, String workspace, bool workspaceRequired) {
    final isSmall = MediaQuery.of(context).size.width < 600;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 720),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: isSmall ? 16 : 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              // App icon
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: context.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.colors.border),
                ),
                child: Icon(Icons.hexagon_outlined,
                    color: context.colors.textDim, size: 22),
              ),
              const SizedBox(height: 16),
              // App name
              Text(
                app?.name ?? 'Digitorn',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: context.colors.textMuted,
                ),
              ),
              // Greeting
              if (app?.greeting.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  app!.greeting,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: context.colors.textDim,
                    height: 1.6,
                  ),
                ),
              ],
              // Workspace warning
              if (workspaceRequired) ...[
                const SizedBox(height: 14),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      final dir = await pickWorkspace(context);
                      if (dir != null && context.mounted) {
                        _saveRecentWorkspace(dir);
                        context.read<AppState>().setWorkspace(dir);
                      }
                    },
                    child: Builder(builder: (ctx) {
                      final c = ctx.colors;
                      return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.red.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_open_outlined,
                              size: 14, color: c.red),
                          const SizedBox(width: 8),
                          Text('Select Workspace...',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: c.red,
                            ),
                          ),
                        ],
                      ),
                    );
                    }),
                  ),
                ),
              ] else if (workspace.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_outlined, size: 11, color: context.colors.textDim),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(workspace,
                        style: GoogleFonts.firaCode(fontSize: 11, color: context.colors.borderHover),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 32),
              // Input bar — centered in the middle
              _ChatInput(
                controller: _ctrl,
                focusNode: _focus,
                isActive: _isSending,
                disabled: workspaceRequired,
                inTokens: _inTokens,
                contextMax: _contextMax,
                onSend: _send,
                onAbort: _abort,
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
    required bool isLoadingHistory,
  }) {
    final isSmall = MediaQuery.of(context).size.width < 600;
    final maxW = isSmall ? double.infinity : 720.0;
    final hPad = isSmall ? 8.0 : 0.0;

    // Loading skeleton while history loads
    if (isLoadingHistory && _messages.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: const _HistorySkeleton(),
          ),
        ),
      );
    }

    // Messages list with checkpoint rail
    final showRail = _messages.length > 3 && MediaQuery.of(context).size.width > 900;
    return Stack(
      children: [
        Row(
          children: [
            Expanded(
              child: SelectionArea(
                child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.only(top: 20, bottom: 8, left: hPad, right: hPad),
        itemCount: _messages.length,
        itemBuilder: (_, i) {
          final msg = _messages[i];
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
          // Ensure a GlobalKey exists for scroll-to navigation
          _messageKeys.putIfAbsent(msg.id, () => GlobalKey());
          final mKey = _messageKeys[msg.id]!;

          return TweenAnimationBuilder<double>(
            key: ValueKey(msg.id),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - v)),
                child: child,
              ),
            ),
            child: Center(
              key: mKey,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: ChatBubble(message: msg, onRetry: onRetry),
              ),
            ),
          );
        },
      ),
    ),
            ),
            // Checkpoint rail (only on wide screens with enough messages)
            if (showRail)
              CheckpointRail(
                messages: _messages,
                scrollController: _scroll,
                messageKeys: _messageKeys,
              ),
          ],
        ),
      // Scroll-to-bottom FAB
      if (_showScrollDown)
        Positioned(
          bottom: 12,
          right: 16,
          child: GestureDetector(
            onTap: _scrollToBottom,
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: context.colors.surfaceAlt,
                shape: BoxShape.circle,
                border: Border.all(color: context.colors.borderHover),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 2)),
                ],
              ),
              child: Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: context.colors.textMuted),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(AppSummary? app, String? sessionId) {
    final c = context.colors;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.chat_bubble_outline_rounded,
              color: c.textMuted, size: 13),
          const SizedBox(width: 10),
          Text(
            app?.name ?? 'Chat',
            style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.text),
          ),
          if (sessionId != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: context.colors.surfaceAlt,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colors.border),
              ),
              child: Text(
                sessionId,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: context.colors.textMuted),
              ),
            ),
          ],
          const Spacer(),
          // Export conversation
          if (_messages.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Export conversation',
              onSelected: (value) => _exportChat(value, app?.name),
              offset: const Offset(0, 36),
              color: c.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: c.border),
              ),
              padding: EdgeInsets.zero,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clipboard',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_rounded, size: 15, color: c.textMuted),
                      const SizedBox(width: 8),
                      Text('Copy to clipboard',
                          style: GoogleFonts.inter(fontSize: 12, color: c.text)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'markdown',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.save_alt_rounded, size: 15, color: c.textMuted),
                      const SizedBox(width: 8),
                      Text('Download as Markdown',
                          style: GoogleFonts.inter(fontSize: 12, color: c.text)),
                    ],
                  ),
                ),
              ],
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(Icons.download_rounded,
                    size: 15, color: c.textMuted),
              ),
            ),
          const SizedBox(width: 4),
          // Connection status
          _ConnectionDot(),
        ],
      ),
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
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 720),
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
    final edited = ws.buffers.where((b) => b.isEdited).toList();
    if (edited.isEmpty) return const SizedBox.shrink();

    final c = context.colors;
    final isSmall = MediaQuery.of(context).size.width < 600;

    // Calculate total insertions/deletions
    int totalIns = 0, totalDel = 0;
    for (final b in edited) {
      final stats = b.diffStats;
      totalIns += stats.insertions;
      totalDel += stats.deletions;
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 720),
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
                  '${edited.length} file${edited.length > 1 ? 's' : ''} changed',
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
                // File names (compact)
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

  Widget _buildSuggestions() {
    final c = context.colors;
    final isSmall = MediaQuery.of(context).size.width < 600;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSmall ? double.infinity : 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: _suggestions.map((s) => GestureDetector(
              onTap: () {
                _ctrl.text = s;
                _send();
                setState(() => _suggestions = []);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.border),
                ),
                child: Text(s,
                  style: GoogleFonts.inter(fontSize: 12, color: c.text)),
              ),
            )).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildSpinnerBar() {
    final m = context.watch<SessionMetrics>();
    final hasMetrics = m.totalTokens > 0 || m.toolCallsTotal > 0;

    // Nothing to show
    if (_statusPhase.isEmpty && !hasMetrics) return const SizedBox.shrink();

    // Phase → icon + color
    final c = context.colors;
    final (Color color, String label) = _statusPhase.isNotEmpty
        ? switch (_statusPhase) {
            'thinking'     => (c.purple, 'thinking'),
            'requesting'   => (c.textMuted, 'requesting'),
            'responding'   => (c.green, 'responding'),
            'turn_start'   => (c.textMuted, 'starting'),
            'turn_end'     => (c.green, 'done'),
            'tool_use'     => (c.blue, 'tool'),
            'rate_limited' => (c.orange, 'rate limited'),
            'resuming'     => (c.orange, 'resuming...'),
            'aborting'     => (c.red, 'aborting...'),
            'interrupted'  => (c.orange, 'interrupted — send a message to resume'),
            _              => (c.blue, _statusPhase),
          }
        : (c.textMuted, '');

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width < 600
              ? double.infinity : 720,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
              decoration: BoxDecoration(
                color: _statusPhase.isNotEmpty
                    ? color.withValues(alpha: 0.06)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
          child: Row(
            children: [
              // Spinner icon + label (only when active)
              if (_statusPhase.isNotEmpty) ...[
                _PulsingText(text: '', color: color),
                const SizedBox(width: 6),
                Text(label,
                  style: GoogleFonts.inter(
                    fontSize: 12, color: color, fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
              ],
              // Session stats (always visible when available)
              if (hasMetrics) ...[
                // Model
                if (m.model.isNotEmpty) ...[
                  Text(m.model,
                    style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  const SizedBox(width: 8),
                ],
                // Turn
                if (m.turnNumber > 0) ...[
                  Icon(Icons.replay_rounded, size: 10, color: c.textMuted),
                  const SizedBox(width: 2),
                  Text('${m.turnNumber}',
                    style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  const SizedBox(width: 8),
                ],
                // Tokens
                if (m.totalTokens > 0) ...[
                  Text('↑${m.fmt(m.promptTokens)}',
                    style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  const SizedBox(width: 4),
                  Text('↓${m.fmt(m.completionTokens)}',
                    style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  const SizedBox(width: 8),
                ],
                // Tools
                if (m.toolCallsTotal > 0) ...[
                  Icon(Icons.build_rounded, size: 10, color: c.textMuted),
                  const SizedBox(width: 2),
                  Text('${m.toolCallsTotal}',
                    style: GoogleFonts.firaCode(fontSize: 10, color: c.textMuted)),
                  if (m.toolCallsFailed > 0) ...[
                    Text(' (${m.toolCallsFailed}✗)',
                      style: GoogleFonts.firaCode(fontSize: 10, color: c.red)),
                  ],
                  const SizedBox(width: 8),
                ],
                // Context pressure
                if (m.contextPressure > 0) ...[
                  Text(m.pressurePercent,
                    style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: m.contextPressure < 0.6
                          ? c.textMuted
                          : m.contextPressure < 0.85
                              ? c.orange
                              : c.red,
                    )),
                  const SizedBox(width: 8),
                ],
                // Cost
                if (m.costUsd > 0) ...[
                  Text('\$${m.costUsd.toStringAsFixed(4)}',
                    style: GoogleFonts.firaCode(
                      fontSize: 10, color: c.textMuted)),
                ],
              ],
              const Spacer(),
              // Heartbeat dot
              if (_heartbeat)
                Container(
                  width: 5, height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.green,
                    boxShadow: [BoxShadow(
                      color: c.green.withValues(alpha: 0.4),
                      blurRadius: 5,
                    )],
                  ),
                ),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }

  /// Synthesize workbench events from tool_call results.
  /// When the daemon doesn't emit separate workbench_* events, we extract
  /// file content from tool_call results and open them in the workspace.
  void _synthesizeWorkbench(String toolName, Map<String, dynamic> data) {
    final lower = toolName.toLowerCase().split(RegExp(r'[.__]')).last;
    final result = data['result'];
    if (result is! Map) return;
    final r = result as Map<String, dynamic>;
    final path = r['path'] as String? ?? data['params']?['path'] as String? ?? '';
    if (path.isEmpty) return;

    final content = r['content'] as String? ?? '';
    final wsSvc = WorkspaceService();

    switch (lower) {
      case 'read':
      case 'glob':
      case 'find':
        if (content.isNotEmpty) {
          wsSvc.handleEvent('workbench_read', {
            'buffer': path,
            'content': content,
            'type': 'text',
          });
        }
        break;
      case 'write':
      case 'create':
        wsSvc.handleEvent('workbench_write', {
          'buffer': path,
          'content': content,
          'type': 'text',
        });
        break;
      case 'edit':
      case 'patch':
      case 'replace':
        final prev = r['previous_content'] as String? ?? '';
        wsSvc.handleEvent('workbench_edit', {
          'buffer': path,
          'content': content,
          'previous_content': prev,
          'type': 'text',
        });
        break;
    }

    // Auto-open workspace if a file was opened
    if (const {'read', 'write', 'create', 'edit', 'patch', 'replace'}.contains(lower)) {
      final appState = context.read<AppState>();
      if (!appState.isWorkspaceVisible) appState.showWorkspace();
    }
  }

  /// Tools hidden from chat — shown only in spinner/sidebar
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

  /// Convert internal tool names to user-friendly spinner labels
  static String _friendlySpinnerLabel(String shortName, String verb) {
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

  /// Generate smart follow-up suggestions based on the last turn
  static List<String> _generateSuggestions(Map<String, dynamic> data, String content) {
    final suggestions = <String>[];
    final tc = data['tool_calls_count'] as int? ?? 0;
    final error = data['error'] as String?;
    final lower = content.toLowerCase();

    if (error != null && error.isNotEmpty) {
      suggestions.add('Fix this error');
      suggestions.add('Explain what went wrong');
      return suggestions;
    }

    // Based on content patterns
    if (lower.contains('created') || lower.contains('wrote') || lower.contains('written')) {
      suggestions.add('Run the tests');
      suggestions.add('Review the changes');
    }
    if (lower.contains('error') || lower.contains('bug') || lower.contains('fix')) {
      suggestions.add('Run the tests again');
    }
    if (lower.contains('file') || lower.contains('read')) {
      suggestions.add('Edit this file');
      suggestions.add('Search for related files');
    }
    if (tc > 3) {
      suggestions.add('Summarize what you did');
    }
    if (lower.contains('test') || lower.contains('spec')) {
      suggestions.add('Run the test suite');
    }
    if (lower.contains('commit') || lower.contains('change')) {
      suggestions.add('Create a commit');
    }

    // Generic fallbacks
    if (suggestions.isEmpty) {
      suggestions.add('Continue');
      suggestions.add('Explain your approach');
    }

    return suggestions.take(3).toList();
  }

  static String _formatTokens(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

// ─── History loading skeleton ─────────────────────────────────────────────────

class _HistorySkeleton extends StatelessWidget {
  const _HistorySkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: context.colors.surfaceAlt,
      highlightColor: context.colors.borderHover,
      child: ListView(
        padding: const EdgeInsets.only(top: 28, bottom: 8),
        children: [
          _skelRow(right: true, widthFactor: 0.55),
          const SizedBox(height: 10),
          _skelRow(right: false, widthFactor: 0.75),
          const SizedBox(height: 4),
          _skelRow(right: false, widthFactor: 0.5),
          const SizedBox(height: 18),
          _skelRow(right: true, widthFactor: 0.4),
          const SizedBox(height: 10),
          _skelRow(right: false, widthFactor: 0.65),
          const SizedBox(height: 4),
          _skelRow(right: false, widthFactor: 0.45),
        ],
      ),
    );
  }

  Widget _skelRow({required bool right, required double widthFactor}) {
    return Padding(
      padding: right
          ? const EdgeInsets.fromLTRB(80, 2, 16, 2)
          : const EdgeInsets.fromLTRB(16, 2, 60, 2),
      child: Align(
        alignment: right ? Alignment.centerRight : Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widthFactor,
          child: Container(
            height: 13,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Empty / centered state (input embedded vertically centered) ──────────────
// Layout (Claude-style):
//
//   ┌──────────────────────────────────────────────────────────┐
//   │                                                          │
//   │                    ⬡  App name                          │
//   │               App greeting text here                     │
//   │                                                          │
//   │  ┌───────────────────────────────────────────────────┐   │
//   │  │  Message…                                         │   │
//   │  ├───────────────────────────────────────────────────┤   │
//   │  │  [+] [⎘]                              [↑ Send]    │   │
//   │  └───────────────────────────────────────────────────┘   │
//   │                                                          │
//   └──────────────────────────────────────────────────────────┘

class _EmptyCenteredState extends StatelessWidget {
  final AppSummary? app;
  final String workspace;
  const _EmptyCenteredState({
    required this.app,
    required this.workspace,
  });

  @override
  Widget build(BuildContext context) {
    final workspaceRequired = app?.workspaceMode == 'required';
    final missingWorkspace = workspaceRequired && workspace.isEmpty;
    final isSmall = MediaQuery.of(context).size.width < 600;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isSmall ? double.infinity : 720,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: isSmall ? 12 : 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),

              // ── App icon + name ──────────────────────────────────────────
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: context.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: context.colors.border),
                ),
                child: Icon(Icons.hexagon_outlined,
                    color: context.colors.textDim, size: 20),
              ),
              const SizedBox(height: 16),
              Text(
                app?.name ?? 'Digitorn',
                style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: context.colors.textMuted),
              ),
              if (app?.greeting.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(
                  app!.greeting,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 13,
                      color: context.colors.textDim,
                      height: 1.65),
                ),
              ],

              // ── Workspace missing warning ──────────────────────────────
              if (missingWorkspace) ...[
                const SizedBox(height: 14),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async {
                      final dir = await pickWorkspace(context);
                      if (dir != null && context.mounted) {
                        _saveRecentWorkspace(dir);
                        context.read<AppState>().setWorkspace(dir);
                      }
                    },
                    child: Builder(builder: (ctx) {
                      final c = ctx.colors;
                      return Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.red.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_open_outlined,
                              size: 14, color: c.red),
                          const SizedBox(width: 8),
                          Text(
                            'Select Workspace...',
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: c.red),
                          ),
                        ],
                      ),
                    );
                    }),
                  ),
                ),
              ] else if (workspace.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.folder_outlined,
                        size: 11, color: context.colors.textDim),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        workspace,
                        style: GoogleFonts.firaCode(
                            fontSize: 11, color: context.colors.borderHover),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Workspace missing banner ─────────────────────────────────────────────────

class _WorkspaceBanner extends StatelessWidget {
  final String appName;
  const _WorkspaceBanner({required this.appName});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: c.surfaceAlt,
      child: Row(
        children: [
          Icon(Icons.folder_off_outlined, size: 14, color: c.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$appName requires a workspace to operate properly.',
              style: GoogleFonts.inter(fontSize: 12, color: c.red),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () async {
                final dir = await pickWorkspace(context);
                if (dir != null && context.mounted) {
                  _saveRecentWorkspace(dir);
                  context.read<AppState>().setWorkspace(dir);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: c.red.withValues(alpha: 0.3)),
                ),
                child: Text('Select',
                    style: GoogleFonts.inter(fontSize: 11, color: c.red)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Approval banner ──────────────────────────────────────────────────────────

class _ApprovalBanner extends StatelessWidget {
  final ApprovalRequest request;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  const _ApprovalBanner(
      {required this.request, required this.onApprove, required this.onDeny});

  @override
  Widget build(BuildContext context) {
    final ac = context.colors;
    final riskColor = switch (request.riskLevel) {
      'high'   => ac.red,
      'medium' => ac.orange,
      _        => ac.green,
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ac.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ac.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.security_outlined, size: 13, color: riskColor),
              const SizedBox(width: 7),
              Text(
                'Approval Required',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: riskColor),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: riskColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(request.riskLevel,
                    style: GoogleFonts.inter(
                        fontSize: 10, color: riskColor)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Tool name
          Row(
            children: [
              Text('● ', style: TextStyle(color: riskColor, fontSize: 10)),
              Text(request.toolName,
                  style: GoogleFonts.firaCode(
                      fontSize: 13, color: context.colors.textBright)),
            ],
          ),
          // Description
          if (request.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(request.description,
                style: GoogleFonts.inter(
                    fontSize: 12, color: context.colors.textMuted,
                    height: 1.5)),
          ],
          // Params preview
          if (request.params.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: context.colors.bg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                request.params.entries
                    .take(4)
                    .map((e) => '${e.key}: ${e.value}')
                    .join('\n'),
                style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: context.colors.textMuted,
                    height: 1.5),
              ),
            ),
          ],
          const SizedBox(height: 10),
          // Buttons
          Row(
            children: [
              _ABtn(
                  label: 'Allow',
                  bg: ac.green.withValues(alpha: 0.1),
                  border: ac.green.withValues(alpha: 0.3),
                  fg: ac.green,
                  onTap: onApprove),
              const SizedBox(width: 8),
              _ABtn(
                  label: 'Deny',
                  bg: ac.red.withValues(alpha: 0.1),
                  border: ac.red.withValues(alpha: 0.3),
                  fg: ac.red,
                  onTap: onDeny),
            ],
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
                  ? widget.bg.withValues(alpha: 1.6)
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

// ─── Chat Input — main input bar ──────────────────────────────────────────────
// Layout (identical to old web client):
//   ┌─────────────────────────────────────────────────────────┐
//   │ textarea (auto-grow, max 200px)                         │
//   ├─────────────────────────────────────────────────────────┤
//   │ [+] [⎘]  [context ring]           [■ Stop] / [↑ Send]  │
//   └─────────────────────────────────────────────────────────┘

class _ChatInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isActive;
  final bool disabled;
  final int inTokens;
  final int contextMax;
  final VoidCallback onSend;
  final VoidCallback onAbort;

  const _ChatInput({
    required this.controller,
    required this.focusNode,
    required this.isActive,
    required this.disabled,
    required this.inTokens,
    required this.contextMax,
    required this.onSend,
    required this.onAbort,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Builder(builder: (context) {
      final c = context.colors;
      return Container(
        decoration: BoxDecoration(
          color: c.inputBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.inputBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 16,
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
                shortcuts: {
                  LogicalKeySet(LogicalKeyboardKey.enter): const _SendIntent(),
                },
                child: Actions(
                  actions: {
                    _SendIntent: CallbackAction<_SendIntent>(
                      onInvoke: (_) {
                        if (!isActive && !disabled) onSend();
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
                    // Shift+Enter inserts newline naturally via multiline
                    style: GoogleFonts.inter(
                        fontSize: 14, color: c.text, height: 1.55),
                    decoration: InputDecoration(
                      hintText: disabled
                          ? 'Select a workspace first'
                          : 'Message… (Enter to send, Shift+Enter for new line)',
                      hintStyle: GoogleFonts.inter(
                          fontSize: 14,
                          color: c.textMuted),
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
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  // New session button
                  _IconBtn(
                    icon: Icons.add,
                    tooltip: 'New session',
                    disabled: disabled,
                    onTap: () {
                      final app = context.read<AppState>().activeApp;
                      if (app != null) {
                        SessionService().createAndSetSession(app.appId);
                      }
                    },
                  ),
                  const SizedBox(width: 4),
                  // Paste
                  _IconBtn(
                    icon: Icons.content_paste_outlined,
                    tooltip: 'Paste clipboard',
                    disabled: disabled,
                    onTap: () async {
                      final data = await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        controller.text =
                            controller.text + data!.text!;
                        controller.selection =
                            TextSelection.collapsed(
                                offset: controller.text.length);
                      }
                    },
                  ),
                  const SizedBox(width: 4),
                  // Sessions (history)
                  _IconBtn(
                    icon: Icons.history_rounded,
                    tooltip: 'Sessions',
                    disabled: disabled,
                    onTap: () {
                      final state = context.read<AppState>();
                      state.setPanel(
                        state.panel == ActivePanel.sessions
                            ? ActivePanel.chat
                            : ActivePanel.sessions,
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  // Tools browser (modal)
                  _IconBtn(
                    icon: Icons.build_outlined,
                    tooltip: 'Tools',
                    disabled: disabled,
                    onTap: () {
                      final app = context.read<AppState>().activeApp;
                      if (app != null) {
                        ToolsModal.show(context, app.appId);
                      }
                    },
                  ),

                  const SizedBox(width: 4),
                  // Background tasks (modal)
                  _IconBtn(
                    icon: Icons.sync_rounded,
                    tooltip: 'Background tasks',
                    disabled: disabled,
                    onTap: () => TasksModal.show(context),
                  ),

                  // Context pressure ring
                  if (inTokens > 0) ...[
                    const SizedBox(width: 8),
                    _ContextRing(current: inTokens, max: contextMax),
                  ],

                  const Spacer(),

                  // Stop or Send
                  if (isActive)
                    _StopButton(onTap: onAbort)
                  else
                    _SendButton(disabled: disabled, onTap: onSend),
                ],
              ),
            ),
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
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _h = true),
          onExit: (_) => setState(() => _h = false),
          cursor: widget.disabled
              ? SystemMouseCursors.forbidden
              : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.disabled ? null : widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _h && !widget.disabled
                    ? context.colors.surfaceAlt
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                widget.icon,
                size: 15,
                color: widget.disabled
                    ? context.colors.borderHover
                    : (_h
                        ? context.colors.textMuted
                        : context.colors.textMuted),
              ),
            ),
          ),
        ),
      );
}

// ─── Context pressure ring ────────────────────────────────────────────────────
// SVG-style ring (like the old web client) — filled proportionally

class _ContextRing extends StatelessWidget {
  final int current;
  final int max;
  const _ContextRing({required this.current, required this.max});

  @override
  Widget build(BuildContext context) {
    final ratio = max > 0 ? (current / max).clamp(0.0, 1.5) : 0.0;
    final pct = (ratio * 100).round();

    final cc = context.colors;
    final color = ratio < 0.6
        ? cc.green
        : ratio < 0.85
            ? cc.orange
            : cc.red;

    return GestureDetector(
      onTap: () => ContextModal.show(context),
      child: Tooltip(
      message: 'Context: $pct% used — click for details',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size(18, 18),
            painter: _RingPainter(ratio: ratio.clamp(0.0, 1.0), color: color, trackColor: cc.borderHover),
          ),
          if (ratio >= 0.6) ...[
            const SizedBox(width: 4),
            Text(
              '$pct%',
              style: GoogleFonts.firaCode(fontSize: 10, color: color),
            ),
          ],
        ],
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

class _SendButton extends StatefulWidget {
  final bool disabled;
  final VoidCallback onTap;
  const _SendButton({required this.disabled, required this.onTap});

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.disabled ? null : widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: widget.disabled
                  ? context.colors.surfaceAlt
                  : _h
                      ? context.colors.textMuted
                      : context.colors.borderHover,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 14,
              color: widget.disabled
                  ? context.colors.borderHover
                  : context.colors.textBright,
            ),
          ),
        ),
      );
}

// ─── Stop button ──────────────────────────────────────────────────────────────

class _StopButton extends StatefulWidget {
  final VoidCallback onTap;
  const _StopButton({required this.onTap});

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _h
                  ? context.colors.red.withValues(alpha: 0.2)
                  : context.colors.red.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: context.colors.red.withValues(alpha: 0.3)),
            ),
            child: Icon(
              Icons.stop_rounded,
              size: 13,
              color: context.colors.red,
            ),
          ),
        ),
      );
}

// ─── Connection status dot ───────────────────────────────────────────────────

class _ConnectionDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final sseConnected = context.watch<SessionService>().activeSession != null;
    // Simple heuristic: if we have an active session, SSE should be connected
    final color = sseConnected
        ? context.colors.green
        : context.colors.textMuted;
    final label = sseConnected ? 'Connected' : 'Disconnected';

    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: sseConnected
                  ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 4)]
                  : [],
            ),
          ),
          const SizedBox(width: 5),
          Text(label,
            style: GoogleFonts.inter(fontSize: 10, color: context.colors.textMuted),
          ),
        ],
      ),
    );
  }
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

// ─── Workspace picker (desktop native picker, web text dialog) ───────────────

Future<String?> pickWorkspace(BuildContext context) async {
  if (!kIsWeb) {
    return getDirectoryPath(confirmButtonText: 'Select Workspace');
  }
  // Web: show dialog with text field + recent workspaces
  final prefs = await SharedPreferences.getInstance();
  final recents = prefs.getStringList('recent_workspaces') ?? [];
  final controller = TextEditingController();

  return showDialog<String>(
    context: context,
    builder: (ctx) {
      final c = ctx.colors;
      return Dialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Workspace Path',
                  style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w600, color: c.textBright)),
                const SizedBox(height: 4),
                Text('Enter the absolute path on the daemon server',
                  style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  style: GoogleFonts.firaCode(fontSize: 13, color: c.text),
                  decoration: InputDecoration(
                    hintText: '/home/user/project or C:\\Users\\...',
                    hintStyle: GoogleFonts.firaCode(fontSize: 13, color: c.textDim),
                    filled: true,
                    fillColor: c.bg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: c.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: c.blue),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
                  },
                ),
                if (recents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Recent',
                    style: GoogleFonts.inter(fontSize: 11, color: c.textMuted)),
                  const SizedBox(height: 6),
                  for (final r in recents.take(5))
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, r),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(r,
                          style: GoogleFonts.firaCode(fontSize: 12, color: c.text),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('Cancel', style: GoogleFonts.inter(color: c.textMuted)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final v = controller.text.trim();
                        if (v.isNotEmpty) Navigator.pop(ctx, v);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.blue,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Select'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Save workspace to recent list
Future<void> _saveRecentWorkspace(String path) async {
  final prefs = await SharedPreferences.getInstance();
  final recents = prefs.getStringList('recent_workspaces') ?? [];
  recents.remove(path);
  recents.insert(0, path);
  if (recents.length > 10) recents.removeRange(10, recents.length);
  await prefs.setStringList('recent_workspaces', recents);
}

// ─── Enter to send intent ────────────────────────────────────────────────────

class _SendIntent extends Intent {
  const _SendIntent();
}

// ─── Spinner icon (uses SpinKit) ─────────────────────────────────────────────

class _PulsingText extends StatelessWidget {
  final String text;
  final Color color;
  const _PulsingText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return SpinKitPulse(
      color: color,
      size: 16,
    );
  }
}
